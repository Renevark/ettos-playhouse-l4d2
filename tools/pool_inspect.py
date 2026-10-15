"""pool_inspect.py <slot model basename> <label=vpk path> [...]  - compare weapon-variant models for the variant pool.

e.g.  pool_inspect.py desert_rifle STOCK=stock SCARAB=<...>/775712456.vpk K2=<...>/1649731007.vpk
For v_<slot>.mdl and w_<slot>.mdl (under models/v_models/ and models/w_models/weapons/) per source:
activities provided (and which are missing vs stock), attachments, sound events per sequence, cdmaterials,
plus every sound/ file the VPK ships. Read-only.
"""
import os, sys, struct, re, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from conflict_scan import index, read, G


def s(b, o):
    return b[o:b.index(b'\0', o)].decode('latin1')


def mdl(b):
    nseq, iseq = struct.unpack_from('<ii', b, 0xBC)
    seqs = []
    for i in range(nseq):
        o = iseq + 212 * i
        base, lab, act, flags, actv, wt, nev, iev = struct.unpack_from('<iiiiiiii', b, o)
        evs = []
        for e in range(nev):
            eo = o + iev + 80 * e
            cyc, ev, typ = struct.unpack_from('<fii', b, eo)
            opt = b[eo + 12:eo + 76].split(b'\0')[0].decode('latin1')
            szi, = struct.unpack_from('<i', b, eo + 76)
            evs.append((s(b, eo + szi) if szi else str(ev), round(cyc, 2), opt))
        seqs.append((s(b, o + lab), s(b, o + act) if act else '', evs))
    nat, iat = struct.unpack_from('<ii', b, 0xF0)
    atts = [s(b, iat + 92 * i + struct.unpack_from('<i', b, iat + 92 * i)[0]) for i in range(nat)]
    ncd, icd = struct.unpack_from('<ii', b, 0xD4)
    cds = [s(b, struct.unpack_from('<i', b, icd + 4 * i)[0]) for i in range(ncd)]
    ninc, iinc = struct.unpack_from('<ii', b, 0x150)
    incs = [s(b, iinc + 8 * i + struct.unpack_from('<i', b, iinc + 8 * i + 4)[0]) for i in range(ninc)]
    return {'name': s(b, 12), 'seqs': seqs, 'atts': atts, 'cds': cds, 'incs': incs}


if __name__ == '__main__':
    slot = sys.argv[1]
    stock = {}
    for p in ('left4dead2', 'left4dead2_dlc1', 'left4dead2_dlc2', 'left4dead2_dlc3', 'update'):
        stock.update(index(G + '/' + p + '/pak01_dir.vpk'))
    srcs = []
    for spec in sys.argv[2:]:
        lab, path = spec.split('=', 1)
        srcs.append((lab, stock if path == 'stock' else index(path)))
    stock_acts = None
    for kind, key in (('VIEW', 'models/v_models/v_%s.mdl' % slot), ('WORLD', 'models/w_models/weapons/w_%s.mdl' % slot)):
        print('\n' + '=' * 30, kind, key)
        for lab, ix in srcs:
            if key not in ix:
                print('-- %s: (not shipped)' % lab); continue
            m = mdl(read(ix[key]))
            acts = collections.OrderedDict()
            for sq, act, evs in m['seqs']:
                if act:
                    acts.setdefault(act, []).append(sq)
            if kind == 'VIEW' and lab == 'STOCK':
                stock_acts = set(acts)
            print('-- %s: internal name %s | %d seqs | includemodels %s' % (lab, m['name'], len(m['seqs']), m['incs']))
            print('   attachments: %s' % m['atts'])
            print('   cdmaterials: %s' % m['cds'])
            if kind == 'VIEW':
                print('   activities: %s' % sorted(acts))
                if stock_acts is not None and lab != 'STOCK':
                    print('   MISSING vs stock: %s' % sorted(stock_acts - set(acts)))
                snd = sorted({opt for sq, act, evs in m['seqs'] for ev, cyc, opt in evs if ev in ('5004', 'AE_CL_PLAYSOUND', '5005', 'AE_SV_PLAYSOUND') or ev.startswith('AE_') and 'SOUND' in ev})
                print('   sound events: %s' % snd)
    for lab, ix in srcs:
        if ix is stock:
            continue
        snds = sorted(k for k in ix if k.startswith('sound/'))
        scripts = sorted(k for k in ix if k.startswith('scripts/'))
        print('\n-- %s ships %d sound files: %s' % (lab, len(snds), snds[:14]))
        if scripts:
            print('   and scripts: %s' % scripts)
