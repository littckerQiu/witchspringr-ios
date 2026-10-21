#!/usr/bin/env python3
# Unity games: extract every Switch shader statically into a capture directory (<key>.ctl = 0x880-byte control section, <key>.data = code area),
# the same format as the host's DM_SHDUMP, for gfx/tools/shmap_from_capture.py and gfx/tools/dmsh_build.py capture mode.
# Three sources (checked on manosaba 2.0.4b: all 75 keys captured at run time come from these, code areas byte-identical):
#   1. Shader objects (Addressables bundles, *.assets, Resources/unity*): m_ParsedForm, every pass, every prog*, m_PlayerSubPrograms[*][*].m_BlobIndex
#      → the LZ4 blob of platform 19 (UnityPy ShaderCompilerPlatform.kShaderCompPlatformSwitch) → subprogram entry (version 202012090: version, type, 16 bytes of stats,
#      keyword string array, m_ProgramCode byte array).
#   2. ComputeShader objects: variants[*].kernels[*].uniqueVariants[*].code, same format as m_ProgramCode.
#   3. Embedded in the main executable (the engine's own copy / clear etc.): at the control section magic 34127698, code area immediately after the control section.
# m_ProgramCode format: 0x60-byte header = 4 groups × 6 u32 (index = NVN shader stage: 0 vertex, 1 fragment, 2 geometry, 3 tess control, 4 tess evaluation, 5 compute; −1 = none),
#   group 2 = record offset relative to the end of the header, group 3 = control section length (always 0x880), group 4 = code area length (= control +0x704); record = control section + code area. Group 1 is unused.
# Stage detection as in shmap_from_capture.py (code area marker 78563412 + first SPH word); only vertex / fragment / compute are kept, other stages (unsupported by the translator) are skipped and listed.
# Also writes index.tsv: key, stage, source file, shader / kernel name, pass, keywords (one row per source when a key has several).
# Usage (needs UnityPy and lz4): shader_extract.py <RomFS Data dir> <main NSO> <output dir>
import collections, hashlib, os, struct, sys
import lz4.block, UnityPy
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../verify')); import nsoimg

romfs, main_nso, out = sys.argv[1:4]
CTL_MAGIC, CODE_MAGIC, SUB_VER, SWITCH = bytes.fromhex('34127698'), bytes.fromhex('78563412'), 202012090, 19
recs = {}                                   # key → (stage, control, code)
src = collections.defaultdict(list)         # key → [source rows]
skipped = collections.Counter()

def stage_of(code):
    if code[:4] != CODE_MAGIC: return 'cs'
    w0 = struct.unpack_from('<I', code, 0x30)[0]
    return {(1, 1): 'vs', (2, 5): 'ps'}.get((w0 & 0x1f, (w0 >> 10) & 0xf), f'sph{w0:#x}')

def add(ctl, code, nvn_stage, where, kws=''):
    if len(ctl) != 0x880 or ctl[:4] != CTL_MAGIC: sys.exit(f'[red] {where}: bad control section (length {len(ctl):#x})')
    if struct.unpack_from('<I', ctl, 0x704)[0] != len(code): sys.exit(f'[red] {where}: control section +0x704 does not match the code area length {len(code):#x}')
    st = stage_of(code)
    if {'vs': 0, 'ps': 1, 'cs': 5}.get(st) != nvn_stage:
        if nvn_stage in (0, 1, 5): sys.exit(f'[red] {where}: header stage {nvn_stage}, but the code area says {st}')
        skipped[f'stage {nvn_stage} ({st})'] += 1; return
    key = hashlib.sha256(ctl + code).hexdigest()[:16]   # control section + code area, as the host's shader_key (hle_nvn.c)
    if key in recs and recs[key][2] != code: sys.exit(f'[red] {where}: key {key} already has a different code area')
    recs[key] = (st, ctl, code); src[key].append(f'{where}\t{nvn_stage}\t{kws}')

def program_code(pc, where, kws):
    if len(pc) < 0x60: sys.exit(f'[red] {where}: program code is only {len(pc):#x} bytes')
    g = [struct.unpack_from('<6i', pc, 24 * i) for i in range(4)]
    end = 0x60
    for s in range(6):
        if g[1][s] < 0:
            if g[2][s] >= 0 or g[3][s] >= 0: sys.exit(f'[red] {where}: inconsistent header for stage {s}: {g}')
            continue
        r = 0x60 + g[1][s]; c = r + g[2][s]; e = c + g[3][s]
        if e > len(pc): sys.exit(f'[red] {where}: stage {s} record out of bounds')
        add(pc[r:c], pc[c:e], s, where, kws); end = max(end, e)
    if end != len(pc): sys.exit(f'[red] {where}: program code is {len(pc):#x} bytes, records end at {end:#x}')

def subprogram(blob, off, ln, want_type, where):
    ver, typ = struct.unpack_from('<2i', blob, off)
    if ver != SUB_VER or typ != want_type: sys.exit(f'[red] {where}: subprogram version / type {ver} / {typ} (expected {SUB_VER} / {want_type})')
    p = off + 24; kws = []
    n = struct.unpack_from('<i', blob, p)[0]; p += 4
    for _ in range(n):
        sl = struct.unpack_from('<i', blob, p)[0]; kws.append(blob[p + 4:p + 4 + sl].decode()); p = (p + 4 + sl + 3) & ~3
    pl = struct.unpack_from('<i', blob, p)[0]; p += 4
    if p + pl > off + ln: sys.exit(f'[red] {where}: program code runs past the entry')
    return blob[p:p + pl], kws

def shader(tt, rel):
    name = tt['m_ParsedForm']['m_Name']
    if SWITCH not in tt['platforms']: skipped['shader without a Switch platform'] += 1; return
    i = tt['platforms'].index(SWITCH); cb = bytes(tt['compressedBlob'])
    segs = [lz4.block.decompress(cb[o:o + c], uncompressed_size=d)
            for o, c, d in zip(tt['offsets'][i], tt['compressedLengths'][i], tt['decompressedLengths'][i])]
    blob = segs[0]; n = struct.unpack_from('<i', blob, 0)[0]
    ents = [struct.unpack_from('<3i', blob, 4 + 12 * k) for k in range(n)]
    for si, ss in enumerate(tt['m_ParsedForm']['m_SubShaders']):
        for pi, ps in enumerate(ss['m_Passes']):
            for pk, nvn in (('progVertex', 0), ('progFragment', 1), ('progGeometry', 2), ('progHull', 3),
                            ('progDomain', 4), ('progRayTracing', 5)):
                prog = ps.get(pk)
                if not prog: continue
                where = f'{rel}\t{name}\t{si}.{pi} {ps["m_Name"]} {pk}'
                if 'm_PlayerSubPrograms' in prog:          # Unity 2021+ (manosaba): tiers of subprograms
                    for tier in prog['m_PlayerSubPrograms']:
                        for sp in tier:
                            off, ln, seg = ents[sp['m_BlobIndex']]
                            pc, kws = subprogram(segs[seg], off, ln, sp['m_GpuProgramType'], where)
                            program_code(pc, where, ' '.join(kws))
                elif 'm_SubPrograms' in prog:              # Unity 2019/2020 (witchspringr, subprogram version
                    for sp in prog['m_SubPrograms']:       # 201806140): one flat list; a record holds the pass's
                        off, ln, seg = ents[sp['m_BlobIndex']]   # stages one after another (pixel then vertex),
                        rec = segs[seg][off:off + ln]            # each a control section plus its code area
                        p = rec.find(CTL_MAGIC)
                        while p >= 0:
                            ctl = rec[p:p + 0x880]
                            if len(ctl) == 0x880 and ctl[:4] == CTL_MAGIC:
                                code_len = struct.unpack_from('<I', ctl, 0x704)[0]
                                code = rec[p + 0x880:p + 0x880 + code_len]
                                if len(code) == code_len:
                                    add(ctl, code, {'vs': 0, 'ps': 1, 'cs': 5}.get(stage_of(code), -1), where)
                                else:
                                    skipped['truncated control section (+0x704)'] += 1
                            p = rec.find(CTL_MAGIC, p + 0x880)

def compute(tt, rel):
    if tt['variants'] and 'uniqueVariants' not in tt['variants'][0]['kernels'][0]:
        skipped['compute shader without uniqueVariants (Unity 2019/2020 layout)'] += 1; return
    for v in tt['variants']:
        for k in v['kernels']:
            for ui, u in enumerate(k['uniqueVariants']):
                kw = ' '.join(n for n, idx in k['variantIndices'] if idx == ui and n)
                program_code(bytes(u['code']), f'{rel}\t{tt["m_Name"]}\t{k["name"]} r{v["targetRenderer"]}', kw)

nfile = 0
for dp, dns, fns in os.walk(romfs, followlinks=True):
    dns.sort()
    for fn in sorted(fns):
        if not (fn.endswith(('.bundle', '.assets', '.unity3d')) or fn in ('unity default resources', 'unity_builtin_extra', 'globalgamemanagers') or fn.startswith('level')): continue
        p = os.path.join(dp, fn); rel = os.path.relpath(p, romfs); nfile += 1
        for o in UnityPy.load(p).objects:
            if o.type.name == 'Shader': shader(o.read_typetree(), rel)
            elif o.type.name == 'ComputeShader': compute(o.read_typetree(), rel)

img = nsoimg.load(main_nso); i = 0; nmain = 0
while (i := img.find(CTL_MAGIC, i)) >= 0:
    total = struct.unpack_from('<I', img, i + 0x704)[0]
    add(img[i:i + 0x880], img[i + 0x880:i + 0x880 + total], {'vs': 0, 'ps': 1, 'cs': 5}.get(stage_of(img[i + 0x880:i + 0x880 + total]), -1),
        f'main@{i:#x}\t-\t-'); nmain += 1; i += 0x880

os.makedirs(out, exist_ok=True)
for key, (st, ctl, code) in recs.items():
    open(os.path.join(out, key + '.ctl'), 'wb').write(ctl); open(os.path.join(out, key + '.data'), 'wb').write(code)
with open(os.path.join(out, 'index.tsv'), 'w') as f:
    f.write('# key\tstage\tsource\tname\tpass / kernel\tNVN stage\tkeywords\n')
    for key in sorted(recs):
        for w in src[key]: f.write(f'{key}\t{recs[key][0]}\t{w}\n')
c = collections.Counter(st for st, _, _ in recs.values())
print(f'{nfile} files and {nmain} embedded in main scanned; {len(recs)} distinct shaders (vertex {c["vs"]}, fragment {c["ps"]}, compute {c["cs"]}) → {out}')
for k, n in skipped.items(): print(f'  skipped {k}: {n}')
