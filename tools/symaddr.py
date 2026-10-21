#!/usr/bin/env python3
# Map module offsets to the nearest preceding dynamic symbol (demangled), optionally with disassembly around them.
# Usage: symaddr.py <NSO file> <offset hex>... [--dis N]
import struct, subprocess, sys
import lz4.block

def load(path):
    d = open(path, 'rb').read()
    flags = struct.unpack_from('<I', d, 0xC)[0]
    segs = [struct.unpack_from('<III', d, 0x10 + i * 0x10) for i in range(3)]
    csz = struct.unpack_from('<III', d, 0x60)
    img = bytearray(segs[2][1] + segs[2][2] + struct.unpack_from('<I', d, 0x3C)[0])
    for i, (fo, mo, sz) in enumerate(segs):
        raw = d[fo:fo + csz[i]]
        img[mo:mo + sz] = lz4.block.decompress(raw, uncompressed_size=sz) if flags >> i & 1 else raw
    return bytes(img)

def symbols(img):
    m0 = struct.unpack_from('<I', img, 4)[0]; dyn = m0 + struct.unpack_from('<i', img, m0 + 4)[0]; tags = {}
    while True:
        t, v = struct.unpack_from('<qQ', img, dyn); dyn += 16
        if t == 0: break
        tags.setdefault(t, v)
    out = []
    for i in range(1, (tags[5] - tags[6]) // 24):
        name, info, other, shndx, value, size = struct.unpack_from('<IBBHQQ', img, tags[6] + i * 24)
        if shndx and info & 0xF == 2: out.append((value, size, img[tags[5] + name:img.index(b'\0', tags[5] + name)].decode()))
    return sorted(out)

def main():
    args = [a for a in sys.argv[2:] if not a.startswith('--')]
    ndis = int(sys.argv[sys.argv.index('--dis') + 1]) if '--dis' in sys.argv else 0
    if ndis: args = [a for a in args if a != str(ndis)]
    img = load(sys.argv[1]); syms = symbols(img)
    names = subprocess.run(['c++filt'], input='\n'.join(s[2] for s in syms), capture_output=True, text=True).stdout.split('\n')
    for a in args:
        off = int(a, 16); best = None
        for k, (v, sz, n) in enumerate(syms):
            if v <= off: best = k
            else: break
        if best is None: print(f'{off:#x}: no symbol'); continue
        v, sz, n = syms[best]
        print(f'{off:#x}: {names[best]} +{off - v:#x}' + ('' if not sz or off < v + sz else f'  (past its size {sz:#x})'))
        if ndis:
            from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
            for ins in Cs(CS_ARCH_ARM64, CS_MODE_ARM).disasm(img[off - 4 * ndis:off + 4 * ndis], off - 4 * ndis):
                print(f'   {"=>" if ins.address == off else "  "} {ins.address:#x}  {ins.mnemonic} {ins.op_str}')

if __name__ == '__main__':
    main()
