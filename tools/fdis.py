#!/usr/bin/env python3
# Disassemble a function of an NSO module with call / branch targets named (local symbols, and PLT stubs by their JUMP_SLOT import).
# Usage: fdis.py <NSO file> <symbol | offset hex> [max instructions]
import struct, subprocess, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
import symaddr

def plt_names(img):
    m0 = struct.unpack_from('<I', img, 4)[0]; dyn = m0 + struct.unpack_from('<i', img, m0 + 4)[0]; t = {}
    while True:
        a, v = struct.unpack_from('<qQ', img, dyn); dyn += 16
        if a == 0: break
        t.setdefault(a, v)
    got = {}
    for i in range(0, t.get(2, 0), 24):
        off, info, _ = struct.unpack_from('<QQq', img, t[23] + i)
        nm = struct.unpack_from('<I', img, t[6] + (info >> 32) * 24)[0]
        got[off] = img[t[5] + nm:img.index(b'\0', t[5] + nm)].decode()
    return got

def main():
    img = symaddr.load(sys.argv[1]); syms = symaddr.symbols(img); got = plt_names(img)
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = True
    byaddr = {}
    for v, sz, n in syms: byaddr.setdefault(v, (n, sz))
    def target(a):
        if a in byaddr: return byaddr[a][0]
        ins = list(md.disasm(img[a:a + 8], a))
        if len(ins) == 2 and ins[0].mnemonic == 'adrp' and ins[1].mnemonic == 'ldr':
            return 'PLT ' + got.get(ins[0].operands[1].imm + ins[1].operands[1].mem.disp, '?')
        return ''
    arg = sys.argv[2]
    hit = [(v, sz) for v, sz, n in syms if n == arg]
    start, size = hit[0] if hit else (int(arg, 16), 0x200)
    limit = int(sys.argv[3]) if len(sys.argv) > 3 else 200
    lines, names = [], []
    for k, ins in enumerate(md.disasm(img[start:start + max(size, 4)], start)):
        if k >= limit: break
        t = ''
        if ins.mnemonic in ('bl', 'b') and ins.op_str.startswith('#'): t = target(int(ins.op_str[1:], 16))
        lines.append((ins, t)); names.append(t.replace('PLT ', ''))
    dem = subprocess.run(['c++filt'], input='\n'.join(names), capture_output=True, text=True).stdout.split('\n')
    for (ins, t), d in zip(lines, dem):
        print(f'{ins.address:#x}  {ins.mnemonic} {ins.op_str}' + (f'   ; {"PLT " if t.startswith("PLT ") else ""}{d}' if t else ''))

if __name__ == '__main__':
    main()
