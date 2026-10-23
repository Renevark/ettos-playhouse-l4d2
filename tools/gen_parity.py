"""Regenerate manifest.json's optional "parity" list, "loadOrder" and "localPack" hashes from Etto's local L4D2 client.

Run from the repo root:  python -I tools/gen_parity.py
- parity    = every ENABLED Workshop add-on in addonlist.txt that is not required, not loadFirst, not knownBad/retired.
- loadOrder = every enabled Workshop add-on in addonlist.txt, in order (the sync script copies it with -Parity),
              with the loadFirstAll items moved to the front in their manifest order.
Titles and sizes come from Steam's public GetPublishedFileDetails API. Local (non-Workshop) add-ons are not in
parity/loadOrder; the ones named in manifest.json's localPack get their bytes/sha256 refreshed from Etto's addons folder.
"""
import json, os, re, sys, urllib.request, urllib.parse, datetime
sys.stdout.reconfigure(encoding='utf-8')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDONLIST = r'C:/Program Files (x86)/Steam/steamapps/common/Left 4 Dead 2/left4dead2/addonlist.txt'

m = json.load(open(os.path.join(ROOT, 'manifest.json'), encoding='utf-8'))
entries = re.findall(r'"workshop[\\/](\d+)\.vpk"\s*"([01])"', open(ADDONLIST, encoding='utf-8').read())
enabled = [i for i, on in entries if on == '1']
skip = {x['id'] for sec in ('required', 'retired', 'knownBad') for x in m.get(sec, [])} | {m.get('loadFirst')} | set(m.get('loadFirstAll', []))
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
tops = list(m.get('loadFirstAll') or ([m['loadFirst']] if m.get('loadFirst') else []))
m['loadOrder'] = tops + [i for i in enabled if i not in tops]   # the sync script always puts these on top
m['latestScript'] = 6
# localPack (script v4+): Etto's non-Workshop add-ons, handed to friends personally as EttosPlayhouse_LocalPack.zip.
# Only names, sizes and SHA-256s go in the public manifest. Refreshed from Etto's addons folder on every run.
LOCAL = os.path.join(os.path.dirname(ADDONLIST), 'addons')
lp = m.get('localPack')
if lp:
    import hashlib
    for f in lp['files']:
        b = open(os.path.join(LOCAL, f['name']), 'rb').read()
        f['bytes'], f['sha256'] = len(b), hashlib.sha256(b).hexdigest()
    lp['updated'] = datetime.date.today().isoformat()
m['updated'] = datetime.date.today().isoformat()
json.dump(m, open(os.path.join(ROOT, 'manifest.json'), 'w', encoding='utf-8', newline='\n'), indent=2, ensure_ascii=False)
open(os.path.join(ROOT, 'manifest.json'), 'a', encoding='utf-8', newline='\n').write('\n')
print('parity items: %d, %.1f GB; loadOrder: %d' % (len(parity), sum(p['mb'] for p in parity) / 1024, len(enabled)))
for p in parity:
    print('  %-11s %6.1f MB  %s' % (p['id'], p['mb'], p['label']))
