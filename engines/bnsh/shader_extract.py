#!/usr/bin/env python3
# Games that ship their shaders as NVN BNSH files (Nintendo's own engines; checked on Tears of the Kingdom 1.4.3): extract every vertex / pixel /
# compute shader statically into a capture directory (<key>.ctl = 0x880-byte control section, <key>.data = code area), the same format as the host's
# DM_SHDUMP, for gfx/tools/shmap_from_capture.py and gfx/tools/dmsh_build.py capture mode. Which files and the BNSH layout follow MacNativeGames'
# prepare_shader_seed.py (ly05010419/MacNativeGames, MIT, 41e1e0caf43d58c4af3c478ca2d1bafd9dba7093); the code is our own.
# Sources (RomFS paths): Pack/Bootup.Nin_NX_NVN.pack.zs, Lib/**.zs + Lib/**.bnsh, Shader/**.zs, and the effect sets Effect/**.esetb.byml.zs (not in
# MacNativeGames' set: of the 3793 shaders Tears of the Kingdom used at run time in the title and the prologue, 2910 are not in the others; with the
# effect sets 3451 are found, byte-identical). A .zs file is a zstd frame; a frame with a dictionary ID takes that dictionary from Pack/ZsDic.pack.zs
# (a SARC of dictionaries, itself without one). SARCs are walked recursively; a BFSHA (FSHA) holds complete BNSH files, each addressed from its own
# start, found by their 8-byte magic "BNSH\0\0\0\0"; an effect set is a BYML whose VFXB carries two (GRSN graphics, GRSC compute).
# The agl / gsys / Terrain / application shader archives (*.sharcb inside those SARCs, magic BAHS, version 9) keep their control sections in front and
# every code area in one pool (u32 @0x1c its offset, u32 @0x18 its length). In front of the pool, a 16-byte binary entry per shader: the code area's u64
# offset from the pool (0x100-aligned), the control section's u32 size and the i32 distance from the entry to its control section. Programs share
# control sections but point at different code (Tears of the Kingdom's agl_technique_pfx, agl_technique_shdw, agl_common, agl_technique_lght, ...),
# so every entry is read: entries are found anywhere below the pool and taken only where the control magic, the sizes and the code area's stage
# agree (after seedds/nxnative's shader_split.py bahs_shaders, MIT; reading only the entry right before each control section, 0x60 bytes back,
# missed the shaders sharing it). Which program pairs which shaders is not read, so these add no pairs. Not covered: shaders built into main (32
# control sections, code elsewhere), which come from run-time captures.
# BNSH (little-endian, offsets from the BNSH's start): "BNSH" @0, byte order mark ff fe @12, size u32 @28, "grsc" @96, variation count u32 @124,
#   variation table u64 @128 (64-byte records; program record u64 at +16). Program record (56 bytes): stage records u64 at +8 vertex, +40 pixel,
#   +48 compute (0 = none; the other slots are not read). Stage record: control section u64 @+8, code area u64 @+16, code size u32 @+24, control size
#   u32 @+28. A 0x88c-byte control section is the 0x880 bytes the game passes plus a 12-byte tail; other sizes (0x7d1 bytes in
#   TextureShader.bnsh, an older layout) are skipped and listed.
# Checks per shader: control magic 34127698; control +0x714 (NVN stage: 0 vertex, 1 pixel, 5 compute) matches the program slot; the code area marker
# and first SPH word say the same stage (as shmap_from_capture.py); 0 <= control +0x700 <= length (control +0x704) <= code size. The code area kept is
# that length, so the key is the host's shader_key (hle_nvn.c: sha256(control section + code area)[:8]).
# Also writes bnsh_index.tsv (key, stage, source; one row per source when several archives carry a key) and pairs.tsv (vertex key, pixel key of every
# program record that has both: the pairs dmsh_build.py pads vertex shaders for; the 2272 run-time pairs whose shaders are found are all among them).
# The output may be an existing capture directory (the host's DM_SHDUMP): shaders already there are kept (they must be byte-identical up to the code
# area's length: DM_SHDUMP also writes what follows it in memory) and pairs.tsv gets only the pairs it lacks.
# Usage: shader_extract.py <RomFS dir> <output dir>
import collections, compression.zstd as zstd, hashlib, os, struct, sys

romfs = out = None   # main(): the command line
CTL_MAGIC, CODE_MAGIC = bytes.fromhex('34127698'), bytes.fromhex('78563412')
recs = {}                                   # key → (stage, control, code)
src = collections.defaultdict(list)         # key → [source]
pairs = set()
skipped = collections.Counter()

def rng(d, o, n, where):
    if o < 0 or n < 0 or o + n > len(d): sys.exit(f'[red] {where}: range {o:#x}+{n:#x} outside {len(d):#x} bytes')
    return d[o:o + n]

def sarc(d, where):
    if d[:4] != b'SARC': sys.exit(f'[red] {where}: not a SARC')
    e = '<' if d[6:8] == b'\xff\xfe' else '>'
    hl, size, start = struct.unpack_from(e + 'HxxII', d, 4)
    if size != len(d) or rng(d, hl, 4, where) != b'SFAT': sys.exit(f'[red] {where}: bad SARC header')
    n = struct.unpack_from(e + 'H', d, hl + 6)[0]; names = hl + 12 + n * 16
    if rng(d, names, 4, where) != b'SFNT': sys.exit(f'[red] {where}: no SARC name table')
    names += 8; res = {}
    for i in range(n):
        _, attr, lo, hi = struct.unpack_from(e + '4I', rng(d, hl + 12 + i * 16, 16, where))
        if attr >> 24 != 1 or hi < lo: sys.exit(f'[red] {where}: SARC member {i} without a name or with a negative size')
        p = names + (attr & 0xffffff) * 4; nm = d[p:d.index(0, p, start)].decode()
        if nm in res: sys.exit(f'[red] {where}: SARC member {nm} twice')
        res[nm] = rng(d, start + lo, hi - lo, where)
    return res

def stage_of(code):
    if code[:4] != CODE_MAGIC: return 'cs'
    w0 = struct.unpack_from('<I', code, 0x30)[0]
    return {(1, 1): 'vs', (2, 5): 'ps'}.get((w0 & 0x1f, (w0 >> 10) & 0xf), f'sph{w0:#x}')

def add(st, ctl, code, where):
    key = hashlib.sha256(ctl + code).hexdigest()[:16]   # control section + code area, as the host's shader_key (hle_nvn.c)
    if key in recs and recs[key][1:] != (ctl, code): sys.exit(f'[red] {where}: key {key} already has a different control section or code area')
    if key not in recs: recs[key] = (st, ctl, code)
    if where not in src[key]: src[key].append(where)
    return key

def sharcb(d, where):
    ver, rsz, pool = struct.unpack_from('<I', rng(d, 4, 4, where))[0], *struct.unpack_from('<II', rng(d, 0x18, 8, where))
    if ver != 9 or not 0x20 <= pool <= len(d) or pool + rsz > len(d): skipped[f'sharcb version {ver} (pool {pool:#x} +{rsz:#x}) in {where}'] += 1; return
    for a in range(0, pool - 16, 4):
        off, cn, rel = struct.unpack_from('<QIi', d, a)
        if cn not in (0x880, 0x88c) or off % 0x100 or off >= rsz: continue
        c = a + rel
        if c < 0 or c + cn > pool or d[c:c + 4] != CTL_MAGIC: continue
        ctl = d[c:c + 0x880]   # a 0x88c record is the 0x880 bytes plus a 12-byte tail, as in BNSH
        c1, ln = struct.unpack_from('<II', ctl, 0x700); nvn = struct.unpack_from('<I', ctl, 0x714)[0]; st = {0: 'vs', 1: 'ps', 5: 'cs'}.get(nvn)
        if not st or not 0 <= c1 <= ln or not 0 < ln < 1 << 24 or off + ln > rsz: skipped[f'entry-like words with a bad control section in {where}'] += 1; continue
        code = d[pool + off:pool + off + ln]
        if stage_of(code) != st: skipped[f'entry-like words whose code area says another stage in {where}'] += 1; continue
        add(st, ctl, code, where)

def bnsh(d, where):
    if d[:4] != b'BNSH' or rng(d, 12, 2, where) != b'\xff\xfe' or rng(d, 96, 4, where) != b'grsc': sys.exit(f'[red] {where}: unsupported BNSH header')
    d = rng(d, 0, struct.unpack_from('<I', d, 28)[0], where)
    n, var = struct.unpack_from('<IQ', d, 124); rng(d, var, n * 64, where)
    for i in range(n):
        prog = struct.unpack_from('<Q', d, var + i * 64 + 16)[0]; rng(d, prog, 56, where)
        keys = {}
        for st, rel, nvn in (('vs', 8, 0), ('ps', 40, 1), ('cs', 48, 5)):
            o = struct.unpack_from('<Q', d, prog + rel)[0]
            if not o: continue
            co, do, dn, cn = struct.unpack_from('<QQII', rng(d, o + 8, 24, where))
            ctl, code = rng(d, co, cn, where), rng(d, do, dn, where)
            if cn == 0x88c: ctl = ctl[:0x880]   # 0x880 + a 12-byte tail (Shader/cave_quadmesh: 30 vertex shader records, 21 distinct, all found at run time under the first 0x880 bytes)
            elif cn != 0x880: skipped[f'control section of {cn:#x} bytes ({st}) in {where.split("@")[0]}'] += 1; continue
            c1, ln = struct.unpack_from('<II', ctl, 0x700)
            if ctl[:4] != CTL_MAGIC or struct.unpack_from('<I', ctl, 0x714)[0] != nvn or not 0 <= c1 <= ln <= dn or not 0 < ln < 1 << 24:
                sys.exit(f'[red] {where}: variation {i} {st}: bad control section (magic {ctl[:4].hex()}, stage {struct.unpack_from("<I", ctl, 0x714)[0]}, {c1:#x} / {ln:#x} / {dn:#x})')
            code = code[:ln]
            if stage_of(code) != st: sys.exit(f'[red] {where}: variation {i}: program slot {st}, but the code area says {stage_of(code)}')
            keys[st] = add(st, ctl, code, where)
        if 'vs' in keys and 'ps' in keys: pairs.add((keys['vs'], keys['ps']))

def visit(d, where):
    if d[:4] == b'SARC':
        for nm, m in sarc(d, where).items(): visit(m, where + '/' + nm)
    elif d[:4] == b'BAHS': sharcb(d, where)
    elif d[:4] in (b'FSHA', b'BNSH') or d[:2] == b'YB' and where.endswith('.esetb.byml.zs'):
        p = 0
        while (p := d.find(b'BNSH\0\0\0\0', p)) >= 0:
            n = struct.unpack_from('<I', rng(d, p + 28, 4, where))[0]
            bnsh(rng(d, p, n, where), f'{where}@{p:#x}'); p += n

def read(rel):
    with open(os.path.join(romfs, rel), 'rb') as f: return f.read()
dicts = {}   # zstd dictionaries of Pack/ZsDic.pack.zs (main)
def unzs(raw, where):
    fi = zstd.get_frame_info(raw)
    if fi.decompressed_size is None or fi.decompressed_size > 512 << 20: sys.exit(f'[red] {where}: zstd frame without a size or over 512 MB')
    if fi.dictionary_id and fi.dictionary_id not in dicts: sys.exit(f'[red] {where}: dictionary {fi.dictionary_id:#x} is not in Pack/ZsDic.pack.zs')
    return zstd.decompress(raw, zstd_dict=dicts[fi.dictionary_id] if fi.dictionary_id else None)


def main():
    global romfs, out
    romfs, out = sys.argv[1:3]
    for raw in sarc(zstd.decompress(read('Pack/ZsDic.pack.zs')), 'Pack/ZsDic.pack.zs').values():
        zd = zstd.ZstdDict(raw); dicts[zd.dict_id] = zd
    names = ['Pack/Bootup.Nin_NX_NVN.pack.zs']
    for dp, _, fns in os.walk(os.path.join(romfs, 'Lib')):
        names += [os.path.relpath(os.path.join(dp, fn), romfs) for fn in fns if fn.endswith(('.zs', '.bnsh'))]
    for dp, _, fns in os.walk(os.path.join(romfs, 'Shader')):
        names += [os.path.relpath(os.path.join(dp, fn), romfs) for fn in fns if fn.endswith('.zs')]
    for dp, _, fns in os.walk(os.path.join(romfs, 'Effect')):
        names += [os.path.relpath(os.path.join(dp, fn), romfs) for fn in fns if fn.endswith('.esetb.byml.zs')]
    for rel in sorted(set(names)):
        if not os.path.exists(os.path.join(romfs, rel)): sys.exit(f'[red] {rel} is not in {romfs}')
        raw = read(rel); visit(unzs(raw, rel) if rel.endswith('.zs') else raw, rel)
        if not rel.startswith('Effect/'): print(f'{len(recs)} shaders after {rel}', flush=True)

    os.makedirs(out, exist_ok=True)
    new = 0
    for key, (st, ctl, code) in recs.items():
        pc, pd = os.path.join(out, key + '.ctl'), os.path.join(out, key + '.data')
        if os.path.exists(pc):
            with open(pc, 'rb') as f: c0 = f.read()
            with open(pd, 'rb') as f: d0 = f.read(len(code))
            if c0 != ctl or d0 != code: sys.exit(f'[red] {key}: {out} already has a different control section or code area')
            continue
        with open(pc, 'wb') as f: f.write(ctl)
        with open(pd, 'wb') as f: f.write(code)
        new += 1
    with open(os.path.join(out, 'bnsh_index.tsv'), 'w') as f:
        f.write('# key\tstage\tsource (engines/bnsh/shader_extract.py)\n')
        for key in sorted(recs): f.writelines(f'{key}\t{recs[key][0]}\t{s}\n' for s in src[key])
    pp = os.path.join(out, 'pairs.tsv'); have = set()
    if os.path.exists(pp): have = {tuple(ln.split()[:2]) for ln in open(pp) if ln.strip() and not ln.startswith('#')}
    newpairs = sorted(pairs - have)
    with open(pp, 'a') as f:
        if not have: f.write('# vertex key\tpixel key of each BNSH program record (engines/bnsh/shader_extract.py)\n')
        f.writelines(f'{v}\t{p}\n' for v, p in newpairs)
    c = collections.Counter(st for st, _, _ in recs.values())
    print(f'{len(recs)} shaders ({", ".join(f"{k} {c[k]}" for k in ("vs", "ps", "cs"))}), {new} new in {out}; {len(pairs)} vertex / pixel pairs, {len(newpairs)} new')
    for k, v in sorted(skipped.items()): print(f'  skipped: {k} × {v}')

if __name__ == '__main__':
    main()
