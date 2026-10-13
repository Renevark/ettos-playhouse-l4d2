"""Regenerate manifest.json's optional "parity" list and "loadOrder" from Etto's local L4D2 client.

Run from the repo root:  python -I tools/gen_parity.py
- parity    = every ENABLED Workshop add-on in addonlist.txt that is not required, not loadFirst, not knownBad/retired.
- loadOrder = every enabled Workshop add-on in addonlist.txt, in order (the sync script copies it with -Parity).
Titles and sizes come from Steam's public GetPublishedFileDetails API. Local (non-Workshop) add-ons are skipped.
"""
import json, os, re, sys, urllib.request, urllib.parse, datetime
sys.stdout.reconfigure(encoding='utf-8')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDONLIST = r'C:/Program Files (x86)/Steam/steamapps/common/Left 4 Dead 2/left4dead2/addonlist.txt'

m = json.load(open(os.path.join(ROOT, 'manifest.json'), encoding='utf-8'))
entries = re.findall(r'"workshop[\\/](\d+)\.vpk"\s*"([01])"', open(ADDONLIST, encoding='utf-8').read())
enabled = [i for i, on in entries if on == '1']
skip = {x['id'] for sec in ('required', 'retired', 'knownBad') for x in m.get(sec, [])} | {m.get('loadFirst')}
bad = {x['id'] for sec in ('retired', 'knownBad') for x in m.get(sec, [])}
assert not (set(enabled) & bad), 'a retired/known-bad item is enabled locally: %s' % (set(enabled) & bad)
parity_ids = [i for i in enabled if i not in skip]

data = urllib.parse.urlencode([('itemcount', len(parity_ids))] + [('publishedfileids[%d]' % n, i) for n, i in enumerate(parity_ids)]).encode()
resp = json.load(urllib.request.urlopen('https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/', data))
info = {x['publishedfileid']: x for x in resp['response']['publishedfiledetails']}
parity = []
for i in parity_ids:
    x = info.get(i, {})
    parity.append({'id': i, 'label': (x.get('title') or '(untitled)').strip(), 'mb': round(int(x.get('file_size') or 0) / 1048576, 1)})

m['parity'] = parity
m['loadOrder'] = enabled
m['latestScript'] = 2
m['updated'] = datetime.date.today().isoformat()
json.dump(m, open(os.path.join(ROOT, 'manifest.json'), 'w', encoding='utf-8'), indent=2, ensure_ascii=False)
open(os.path.join(ROOT, 'manifest.json'), 'a', encoding='utf-8').write('\n')
print('parity items: %d, %.1f GB; loadOrder: %d' % (len(parity), sum(p['mb'] for p in parity) / 1024, len(enabled)))
for p in parity:
    print('  %-11s %6.1f MB  %s' % (p['id'], p['mb'], p['label']))
