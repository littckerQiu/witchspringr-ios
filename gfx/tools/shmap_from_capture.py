#!/usr/bin/env python3
# Capture directory (<key>.ctl / <key>.data: the host's DM_SHDUMP or an engine extractor) → the shader stage map the host loads (DM_NVN_SHMAP):
# one "<key>\t<stage>" line per shader, stage = vs / ps / cs. Stage detection as in dmsh_build.py: data starting with the code area marker 78563412
# is graphics and its first SPH word (+0x30) gives vertex / pixel (type bits 0–4, shader type bits 10–13); anything else is compute.
# Key = the first 16 hex digits of sha256(control section + code area), the code area being the length at control +0x704 (as the host's shader_key
# in hle_nvn.c; the control section alone does not tell shaders apart).
# Usage: shmap_from_capture.py <capture dir> <output tsv>
import hashlib, os, struct, sys

cap, out = sys.argv[1:3]
rows = []
for fn in sorted(os.listdir(cap)):
    if not fn.endswith('.ctl'): continue
    key = fn[:-4]
    ctl = open(os.path.join(cap, fn), 'rb').read(); data = open(os.path.join(cap, key + '.data'), 'rb').read()
    n = struct.unpack_from('<I', ctl, 0x704)[0]
    if len(data) < n or hashlib.sha256(ctl + data[:n]).hexdigest()[:16] != key: sys.exit(f'[red] {key}: the hash of control section + code area does not match the name')
    if data[:4] == bytes.fromhex('78563412'):
        w0 = struct.unpack_from('<I', data, 0x30)[0]
        st = {(1, 1): 'vs', (2, 5): 'ps'}.get((w0 & 0x1f, (w0 >> 10) & 0xf))
        if not st: sys.exit(f'[red] {key}: first SPH word {w0:#x} is neither vertex nor pixel')
    else: st = 'cs'
    rows.append(f'{key}\t{st}')
os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
with open(out, 'w') as f:
    f.write(f'# shader stage map from {os.path.basename(os.path.abspath(cap))} (gfx/tools/shmap_from_capture.py): key, stage\n')
    f.write('\n'.join(rows) + '\n')
print(f'{len(rows)} shaders → {out}')
