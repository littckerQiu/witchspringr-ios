#!/usr/bin/env python3
"""engines/bnsh/shader_extract.py sharcb: a synthetic BAHS archive (version 9) whose two binary entries share one pixel shader control section but point
at different code areas in the pool, one entry right before the control section (0x60 back) and one elsewhere; a third entry-like word group points at
no control section. Both shaders are found with different keys (the old reader took only the entry 0x60 before each control section: one), and the
stray words are not taken. Run with Python 3.14 (compression.zstd)."""
import os, struct, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'engines', 'bnsh'))
import shader_extract as se
fails = total = 0
def check(name, ok):
    global fails, total
    total += 1; fails += not ok; print(f'{name:<74} {"✓" if ok else "✗"}')
CTL, POOL, LN = 0x200, 0x1000, 0x80
d = bytearray(POOL + 0x200)
d[0:4] = b'BAHS'; struct.pack_into('<I', d, 4, 9); struct.pack_into('<II', d, 0x18, 0x200, POOL)   # code region length, pool offset
ctl = bytearray(0x880); ctl[0:4] = se.CTL_MAGIC; struct.pack_into('<II', ctl, 0x700, LN, LN); struct.pack_into('<I', ctl, 0x714, 1)   # pixel shader
d[CTL:CTL + 0x880] = ctl
struct.pack_into('<QIi', d, CTL - 0x60, 0x000, 0x880, 0x60)        # the entry right before the control section
struct.pack_into('<QIi', d, 0x40, 0x100, 0x880, CTL - 0x40)       # another entry sharing it, different code
struct.pack_into('<QIi', d, 0x80, 0x100, 0x880, 0x10)             # entry-like words pointing at no control section
for off, fill in ((0, 0x11), (0x100, 0x22)):
    code = bytearray([fill]) * LN; code[0:4] = se.CODE_MAGIC; struct.pack_into('<I', code, 0x30, 2 | 5 << 10)   # SPH: pixel
    d[POOL + off:POOL + off + LN] = code
se.recs.clear(); se.src.clear(); se.skipped.clear()
se.sharcb(bytes(d), 'synthetic.sharcb')
keys = sorted(se.recs)
check(f'two shaders found ({len(keys)})', len(keys) == 2)
check('both pixel shaders on the shared control section', all(se.recs[k][0] == 'ps' and se.recs[k][1] == bytes(ctl) for k in keys))
check('their code areas are the two pool entries', sorted(se.recs[k][2][4] for k in keys) == [0x11, 0x22])
check('the stray entry-like words are not taken', len(keys) == 2 and not any(se.recs[k][2][4] == 0 for k in keys))
print(f'== {total} checks, {fails} failed =='); sys.exit(fails != 0)
