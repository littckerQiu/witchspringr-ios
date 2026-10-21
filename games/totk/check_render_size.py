#!/usr/bin/env python3
# Runs Tears of the Kingdom 1.4.3's scene render size stores (main 0x585e48-0x585e6c, in 0x585da0) in Unicorn, from the product and from the
# original main (rules.py CUTS + HOSTREFS, plan item 52): with the graphics parameter's size in w11 / w10 (1600x900) and the output size in w9 (1920),
# and 960x540 on the host page +16 / +20. The product stores the page's size at renderer +0xcc4 / +0xcc8; the original stores the parameter's
# (negative control) and ignores the page; both store the output size at +0xcc0 (w9 is left alone) and leave x3 and the argument registers as they
# were. Needs the venv's unicorn and lz4.
# Usage: check_render_size.py <product dir> <original main NSO>
import struct, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'verify'))
import nsoimg
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM
from unicorn.arm64_const import (UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2, UC_ARM64_REG_X3, UC_ARM64_REG_X4, UC_ARM64_REG_X5,
                                 UC_ARM64_REG_X6, UC_ARM64_REG_X7, UC_ARM64_REG_X8, UC_ARM64_REG_X9, UC_ARM64_REG_X10, UC_ARM64_REG_X11,
                                 UC_ARM64_REG_X19, UC_ARM64_REG_SP)

BASE, REND, OBJ, STACK = 0x10000000, 0x80000000, 0x80100000, 0x81000000
START, END = 0x585e48, 0x585e6c   # (0x585e6c: ldr x8, [x8, #0x150], the first instruction after the stores)
ARGS = (UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2, UC_ARM64_REG_X3, UC_ARM64_REG_X4, UC_ARM64_REG_X5, UC_ARM64_REG_X6, UC_ARM64_REG_X7)

def run(img, page_off, page_size):
    uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    size = (max(len(img), (page_off or 0) + 0x4000) + 0xFFFF) & ~0xFFFF
    uc.mem_map(BASE, size); uc.mem_write(BASE, bytes(img))
    for a in (REND, OBJ, STACK - 0x10000): uc.mem_map(a, 0x10000)
    if page_off: uc.mem_write(BASE + page_off + 16, struct.pack('<ff', *page_size))
    uc.mem_write(OBJ + 0x40, struct.pack('<i', 7))           # ldr w2, [x8, #0x40]
    uc.mem_write(REND + 0xc38, struct.pack('<Q', OBJ))       # ldr x8, [x19, #0xc38]
    uc.mem_write(REND + 0x9f0, struct.pack('<Q', 0x1234))    # ldr x0, [x19, #0x9f0]
    for i, r in enumerate(ARGS): uc.reg_write(r, 0xA0 + i)
    uc.reg_write(UC_ARM64_REG_X8, OBJ); uc.reg_write(UC_ARM64_REG_X19, REND); uc.reg_write(UC_ARM64_REG_SP, STACK - 0x100)
    uc.reg_write(UC_ARM64_REG_X11, 1600); uc.reg_write(UC_ARM64_REG_X10, 900); uc.reg_write(UC_ARM64_REG_X9, 1920)
    uc.emu_start(BASE + START, BASE + END)
    f = lambda o: struct.unpack('<f', uc.mem_read(REND + o, 4))[0]
    regs = [uc.reg_read(r) for r in ARGS]
    return (f(0xcc4), f(0xcc8), f(0xcc0)), regs, uc.reg_read(UC_ARM64_REG_X9)

n = fail = 0
def expect(what, want, got):
    global n, fail
    n += 1; ok = want == got; fail += not ok
    print(f'{what:<92} expected {want!s:<26} got {got!s:<26} {"✓" if ok else "✗"}')

fx = {l.split()[1]: int(l.split()[2], 0) for l in open(os.path.join(sys.argv[1], 'main.fixups.tsv')) if l.startswith('# ')}
prod = nsoimg.product_image(sys.argv[1], 'main')   # (its options applied: rules.py OPTIONS)
orig = nsoimg.load(sys.argv[2])
expect('the product has a host page after the key page', fx['KEY_PAGE_OFF'] + 0x4000, fx.get('HOST_PAGE_OFF'))
p, pr, p9 = run(prod, fx['HOST_PAGE_OFF'], (960.0, 540.0))
o, orr, o9 = run(orig, fx['HOST_PAGE_OFF'], (960.0, 540.0))
expect('product: the scene size from the host page (renderer +0xcc4 / +0xcc8)', (960.0, 540.0), p[:2])
expect('product: the output size from w9 at +0xcc0, as before', 1920.0, p[2])
expect('original (negative control): the parameter\'s size, the page ignored', (1600.0, 900.0), o[:2])
expect('original: the same output size', 1920.0, o[2])
expect('product: x9 left alone', 1920, p9)
expect('product: x3 and the other argument registers but x0 / x2 as the original leaves them (x0 / x2 are loaded there)',
       [r for i, r in enumerate(orr) if i not in (0, 2)], [r for i, r in enumerate(pr) if i not in (0, 2)])
p2, _, _ = run(prod, fx['HOST_PAGE_OFF'], (1280.0, 720.0))
expect('product: another size on the page is the size stored', (1280.0, 720.0), p2[:2])
print(f'== {n} checks, {fail} failed =='); sys.exit(fail != 0)
