"""conflict_scan.py <new id> [<new id> ...]  - check newly installed L4D2 add-ons against stock content and every enabled add-on.

Read-only. Reports, per new add-on:
  - risky file types (survivor/infected animation, weapon scripts, population/soundmixers/particle manifest, stock vscript names)
  - files that override STOCK content (grouped by top folder) and files that collide with OTHER enabled add-ons (who wins)
  - replacement .wav files shorter than the stock file they replace (the engine caches stock lengths -> garbage audio)
  - missions/*.txt "Name" values and any clash with another add-on's mission Name
Load order: addonlist.txt order, top wins (local addons\\*.vpk are listed first and win over workshop items).
"""
import os, re, sys, struct, collections

G = os.environ.get('L4D2_DIR', r'C:/Program Files (x86)/Steam/steamapps/common/Left 4 Dead 2').replace('\\', '/')
W = G + '/left4dead2'


def cstr(f):
    b = b''
    while True:
        c = f.read(1)
        if c in (b'\x00', b''):
            return b.decode('utf-8', 'replace')
        b += c


def index(path):
    out = {}
    with open(path, 'rb') as f:
        sig, ver, tree = struct.unpack('<III', f.read(12))
        if ver == 2:
            f.read(16)
        base = f.tell() + tree
        while True:
            ext = cstr(f)
            if not ext:
                break
            while True:
                d = cstr(f)
                if not d:
                    break
                while True:
                    n = cstr(f)
                    if not n:
                        break
                    crc, pre, arc, off, ln, term = struct.unpack('<IHHIIH', f.read(18))
                    pd = f.read(pre)
                    out[(((d.strip() + '/') if d.strip() else '') + n + '.' + ext).lower()] = (arc, off, ln, pd, base, path)
    return out


def read(e):
    arc, off, ln, pd, base, path = e
    fn, o = (path, base + off) if arc == 0x7fff else (path.replace('_dir.vpk', '_%03d.vpk' % arc), off)
    with open(fn, 'rb') as f:
        f.seek(o)
        return pd + f.read(ln)


def wav_data_len(b):
    i = 12
    while i < len(b) - 8:
        cid, sz = b[i:i + 4], struct.unpack_from('<I', b, i + 4)[0]
        if cid == b'data':
            return sz
        i += 8 + sz + (sz & 1)
    return None


RISKY = [(r'^models/survivors/anim_', 'SURVIVOR ANIMATION (crash class)'), (r'^models/infected/anim_', 'infected animation'),
         (r'^scripts/weapon_', 'weapon script'), (r'^scripts/population\.txt$', 'GLOBAL population.txt'),
         (r'^scripts/soundmixers\.txt$', 'soundmixers'), (r'^particles/particles_manifest\.txt$', 'particle manifest'),
         (r'^scripts/vscripts/(coop|scriptedmode|mapspawn|sm_utilities|sm_spawn|director_base|response_testbed)\.nut$', 'STOCK vscript override'),
         (r'^scripts/(game_sounds|soundscapes)_?\w*\.txt$', 'sound/soundscape script'), (r'^resource/', 'UI resource'), (r'^cfg/', 'cfg file')]


def main():
    new = [a for a in sys.argv[1:]]
    stock = {}
    for p in ('left4dead2', 'left4dead2_dlc1', 'left4dead2_dlc2', 'left4dead2_dlc3', 'update'):
        stock.update(index(G + '/' + p + '/pak01_dir.vpk'))
    loose_stock = set()
    for root, _, files in os.walk(W + '/sound'):
        for fn in files:
            loose_stock.add(os.path.relpath(os.path.join(root, fn), W).replace('\\', '/').lower())
    rows = re.findall(r'"([^"]+\.vpk)"\s*"([01])"', open(W + '/addonlist.txt', encoding='utf-8').read())
    order, idx = [], {}
    for name, on in rows:
        p = W + '/addons/' + name.replace('\\', '/')
        if on == '1' and os.path.exists(p):
            order.append(name)
            idx[name] = {k: v for k, v in index(p).items() if not re.match(r'(addoninfo\.txt|addonimage\.\w+|addonimage_\w+\.\w+)$', k)}
    owners = collections.defaultdict(list)
    for name in order:
        for k in idx[name]:
            owners[k].append(name)
    names = {}
    for name in order:
        for k in idx[name]:
            if k.startswith('missions/') and k.endswith('.txt'):
                m = re.search(rb'"Name"\s+"([^"]+)"', read(idx[name][k]))
                if m:
                    names.setdefault(m.group(1).decode('latin1').lower(), []).append((name, k))
    for wid in new:
        name = 'workshop\\%s.vpk' % wid
        if name not in idx:
            print('\n### %s: NOT INSTALLED/ENABLED yet' % wid)
            continue
        ix = idx[name]
        size = sum(e[2] + len(e[3]) for e in ix.values())
        print('\n' + '#' * 90 + '\n### %s  (%d files, %.0f MB, load position %d of %d)' % (wid, len(ix), size / 1e6, order.index(name) + 1, len(order)))
        for k in sorted(ix):
            for pat, why in RISKY:
                if re.search(pat, k):
                    print('  !! %-30s %s' % (why, k))
        so = collections.Counter('/'.join(k.split('/')[:2]) for k in ix if k in stock or k in loose_stock)
        if so:
            print('  overrides STOCK:', dict(so.most_common(12)))
        coll = [(k, owners[k]) for k in sorted(ix) if len(owners[k]) > 1]
        if coll:
            by = collections.defaultdict(list)
            for k, own in coll:
                others = tuple(o for o in own if o != name)
                by[(others, own[0] == name)].append(k)
            for (others, wins), ks in sorted(by.items(), key=lambda t: -len(t[1])):
                print('  collides with %s (%d files, %s): %s' % (', '.join(others), len(ks), 'NEW WINS' if wins else 'new loses', ks[:4]))
        for k in sorted(ix):
            if k.endswith('.wav') and (k in stock or k in loose_stock):
                try:
                    nb = read(ix[k])
                    sb = read(stock[k]) if k in stock else open(os.path.join(W, k), 'rb').read()
                    nl, sl = wav_data_len(nb), wav_data_len(sb)
                    if nl is not None and sl is not None and nl < sl:
                        print('  !! SHORTER WAV than stock: %s (%d < %d bytes of audio)' % (k, nl, sl))
                except Exception as e:
                    print('  wav check failed for %s: %s' % (k, e))
        for k in sorted(ix):
            if k.startswith('missions/') and k.endswith('.txt'):
                t = read(ix[k])
                nm = re.search(rb'"Name"\s+"([^"]+)"', t)
                ss = re.findall(rb'"survivor_set"\s+"(\d)"', t)
                n = nm.group(1).decode('latin1') if nm else '?'
                clash = [o for o in names.get(n.lower(), []) if o[0] != name]
                print('  mission %-34s Name=%-24s survivor_set=%s%s' % (k, n, ','.join(x.decode() for x in ss) or '-', ('  !! NAME CLASH with ' + str(clash)) if clash else ''))


if __name__ == '__main__':
    main()
