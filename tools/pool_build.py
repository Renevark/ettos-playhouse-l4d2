"""pool_build.py <out_dir>  - build the weapon-variant pool tree (local add-on etto_pool.vpk) from the POOL table below.

Per variant (a Workshop gun mod for a slot, kept DISABLED in addonlist so it can't override the stock paths):
  - v_/w_ model files (.mdl .vvd .vtx .phy ...) copied to models/v_models/etto_pool/v_<slot>_<var>.* and
    models/w_models/weapons/etto_pool/w_<slot>_<var>.*, with the .mdl internal name patched to match
  - viewmodel sound events (AE_CL_PLAYSOUND, inline char[64] option) rewritten from the class soundscript name to a raw
    wave path of that variant's own copy (sound/etto_pool/<var>/...), when the variant ships that wave
  - gunfire waves copied to sound/etto_pool/<var>/ for the server plugin to emit
  - all materials under the model's cdmaterials folders copied (the source add-on is disabled, so nothing else mounts
    them); uncompressed textures re-encoded to DXT like etto_lite (lens/scope/glass kept original)
  - refuses if a copied material path is also shipped by any ENABLED add-on (would silently change another gun)
Writes <out_dir>/pool_spec.json (variant -> model paths, sound map, missing activities) for the server plugin.
Deterministic: same inputs -> byte-identical outputs. LOCAL ONLY (built from each machine's own subscribed copies).
"""
import os, re, sys, json, struct, tempfile, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from conflict_scan import index, read, G
from lite_vtf import convert as dxt_convert
from pool_inspect import mdl as parse_mdl

W = G + '/left4dead2'
WS = W + '/addons/workshop'
# pool.json (next to this script): { "<slot>": { "<variant>": "<workshop id>", ... }, ... }  e.g. {"desert_rifle": {"k2": "1649731007"}}
_cfg = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pool.json'), encoding='utf-8'))
POOL = {slot: {'variants': v} for slot, v in _cfg.items() if not slot.startswith('_')}
LENS = re.compile(r'(lens|scope|glass|optic|reticle)|/warp\.vtf$', re.I)
TEXCONV_OK = os.path.exists(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'bin', 'texconv.exe'))
if not TEXCONV_OK:
    print('note: tools/bin/texconv.exe not found - textures are copied without DXT conversion (models are unaffected)')
out = sys.argv[1]


def stock_index():
    st = {}
    for p in ('left4dead2', 'left4dead2_dlc1', 'left4dead2_dlc2', 'left4dead2_dlc3', 'update'):
        st.update(index(G + '/' + p + '/pak01_dir.vpk'))
    return st


stock = stock_index()
sndtxt = read(stock['scripts/game_sounds_weapons.txt']).decode('latin1')


def soundscript_wave(name):
    m = re.search(r'"%s"\s*\{(.*?)\n\}' % re.escape(name), sndtxt, re.I | re.S)
    if not m:
        return None
    w = re.search(r'"wave"\s+"[)^*#@<>!?]*([^"]+)"', m.group(1))
    return w.group(1).lower().replace('\\', '/') if w else None


# what enabled add-ons ship (to refuse material collisions)
al = open(W + '/addonlist.txt', encoding='utf-8').read()
enabled_files = {}
for n, on in re.findall(r'"([^"]+\.vpk)"\s*"([01])"', al):
    p = W + '/addons/' + n.replace('\\', '/')
    pool_sources = {'workshop\\%s.vpk' % w for c in POOL.values() for w in c['variants'].values()}
    if on == '1' and os.path.exists(p) and not n.lower().startswith(('etto_pool', 'etto_lite')) and n not in pool_sources:
        for k in index(p):
            enabled_files.setdefault(k, n)


def put(rel, data):
    path = os.path.join(out, rel.replace('/', os.sep))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, 'wb').write(data)


spec, tmp = {}, tempfile.mkdtemp(prefix='poolbuild_')
try:
    for slot, cfg in POOL.items():
        spec[slot] = {}
        for var, wid in cfg['variants'].items():
            src = WS + '/%s.vpk' % wid
            if not os.path.exists(src):
                raise SystemExit('%s/%s: %s not found - subscribe to Workshop item %s, launch L4D2 once so it downloads, then disable it in the add-on list' % (slot, var, src, wid))
            ix = index(src)
            entry = {'workshop_id': wid, 'source': os.path.basename(src)}
            vkey, wkey = 'models/v_models/v_%s.mdl' % slot, 'models/w_models/weapons/w_%s.mdl' % slot
            cds = set()
            for kind, key, newdir, newbase in (('view', vkey, 'models/v_models/etto_pool/', 'v_%s_%s' % (slot, var)),
                                               ('world', wkey, 'models/w_models/weapons/etto_pool/', 'w_%s_%s' % (slot, var))):
                if key not in ix:
                    raise SystemExit('%s/%s: %s missing' % (slot, var, key))
                stem = key[:-4]
                b = bytearray(read(ix[key]))
                m = parse_mdl(bytes(b))
                cds.update(c.lower().replace('\\', '/') for c in m['cds'] if c)
                internal = (newdir[len('models/'):] + newbase + '.mdl').replace('/', '\\')
                assert len(internal) < 64
                b[12:76] = internal.encode('latin1').ljust(64, b'\0')
                sndmap = {}
                if kind == 'view':
                    nseq, iseq = struct.unpack_from('<ii', b, 0xBC)
                    for i in range(nseq):
                        o = iseq + 212 * i
                        nev, iev = struct.unpack_from('<ii', b, o + 24)
                        for e in range(nev):
                            eo = o + iev + 80 * e
                            ev, = struct.unpack_from('<i', b, eo + 4)
                            szi, = struct.unpack_from('<i', b, eo + 76)
                            evname = parse_mdl.__globals__['s'](bytes(b), eo + szi) if szi else ''
                            if ev != 5004 and evname != 'AE_CL_PLAYSOUND':
                                continue
                            opt = bytes(b[eo + 12:eo + 76]).split(b'\0')[0].decode('latin1')
                            wave = soundscript_wave(opt)
                            if not wave or ('sound/' + wave) not in ix:
                                continue
                            newwave = 'etto_pool/%s/%s' % (var, wave.rsplit('/', 1)[-1])
                            if len(newwave) > 63:
                                continue
                            b[eo + 12:eo + 76] = newwave.encode('latin1').ljust(64, b'\0')
                            sndmap[opt] = newwave
                            put('sound/' + newwave, read(ix['sound/' + wave]))
                    entry['sound_events'] = sndmap
                    acts = {act for sq, act, evs in m['seqs'] if act}
                    stock_acts = {act for sq, act, evs in parse_mdl(read(stock[vkey]))['seqs'] if act}
                    entry['missing_activities'] = sorted(stock_acts - acts)
                put(newdir + newbase + '.mdl', bytes(b))
                for k in ix:
                    if k.startswith(stem + '.') and k != key:
                        put(newdir + newbase + k[len(stem):], read(ix[k]))
                entry[kind + '_model'] = newdir + newbase + '.mdl'
            gun = sorted(k for k in ix if k.startswith('sound/weapons/rifle_desert/gunfire/') or (k.startswith('sound/') and '/gunfire/' in k))
            entry['fire_sounds'] = []
            for k in gun:
                nw = 'etto_pool/%s/%s' % (var, k.rsplit('/', 1)[-1])
                put('sound/' + nw, read(ix[k]))
                entry['fire_sounds'].append(nw)
            mats, saved = 0, 0
            for k in sorted(ix):
                if not k.startswith('materials/') or not any(k.startswith('materials/' + c) for c in cds):
                    continue
                if k in enabled_files:
                    raise SystemExit('%s/%s: material %s collides with enabled %s' % (slot, var, k, enabled_files[k]))
                data = read(ix[k])
                if TEXCONV_OK and k.endswith('.vtf') and not LENS.search(k):
                    conv, _ = dxt_convert(data, k, tmp, False)
                    if conv is not None:
                        saved += len(data) - len(conv); data = conv
                put(k, data); mats += 1
            entry['materials'] = mats
            entry['material_dirs'] = sorted(cds)
            spec[slot][var] = entry
            print('%s/%s (%s): view %s | world %s | %d sound events remapped | %d fire sounds | %d material files (DXT saved %.1f MB) | missing acts %d'
                  % (slot, var, wid, entry['view_model'], entry['world_model'], len(entry['sound_events']), len(entry['fire_sounds']), mats, saved / 2**20, len(entry['missing_activities'])))
finally:
    shutil.rmtree(tmp, ignore_errors=True)
json.dump(spec, open(os.path.join(out, 'pool_spec.json'), 'w'), indent=1, sort_keys=True)
