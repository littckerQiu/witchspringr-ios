#!/usr/bin/env python3
"""tools/memsnap.py on two synthetic snapshots in host/memsnap.c's format (16 KB pages; heap at 0x100000000, main.data at 0x200000000):
A has heap pages 0-2 and data page 0; B keeps heap page 0, changes page 1, drops page 2, adds pages 5-7 and data page 1. Summary bytes per range,
diff's new / gone / changed / same per range and its largest new run, and refs: aligned words pointing into [0x100004000, +0x40) found (the bound
excluded), an unaligned one not. Run with the workspace Python (numpy)."""
import os, struct, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import memsnap
PG, HEAP, DATA = 0x4000, 0x100000000, 0x200000000
fails = total = 0
def check(name, ok):
    global fails, total
    total += 1; fails += not ok; print(f'{name:<78} {"✓" if ok else "✗"}')
def write(path, frame, pages):
    """pages: {address: bytes of one page}; runs of adjacent pages go in one record, as memsnap.c writes them"""
    ranges = [(HEAP - 0x1000000, HEAP, b'stack'), (HEAP, HEAP + 0x1000000, b'heap'), (DATA, DATA + 0x10000, b'main.data')]
    with open(path, 'wb') as f:
        f.write(b'DMSNAP01' + struct.pack('<QII', frame, len(ranges), 0) + b''.join(struct.pack('<QQ16s', *r) for r in ranges))
        run = []
        for a in sorted(pages) + [None]:
            if run and (a is None or a != run[-1] + PG):
                f.write(struct.pack('<QQ', run[0], len(run) * PG) + b''.join(pages[p] for p in run)); run = []
            if a is not None: run.append(a)
def page(fill, words=()):
    b = bytearray([fill]) * PG
    for off, v in words: b[off:off + 8] = struct.pack('<Q', v)
    return bytes(b)
d = tempfile.mkdtemp()
A, B = os.path.join(d, 'a.bin'), os.path.join(d, 'b.bin')
write(A, 100, {HEAP: page(1), HEAP + PG: page(2), HEAP + 2 * PG: page(3), DATA: page(9)})
write(B, 900, {HEAP: page(1, [(0x18, HEAP + PG + 0x3f)]), HEAP + PG: page(2, [(0x20, HEAP + PG + 8)]), HEAP + 5 * PG: page(4), HEAP + 6 * PG: page(5, [(0x30, HEAP + PG + 0x40), (0x41, HEAP + PG)]),
               HEAP + 7 * PG: page(6), DATA: page(9, [(0, HEAP + PG)]), DATA + PG: page(7)})
a, b = memsnap.Snap(A), memsnap.Snap(B)
check('header: frames 100 and 900, ranges stack / heap / main.data', a.frame == 100 and b.frame == 900 and [r[2] for r in a.ranges] == ['stack', 'heap', 'main.data'])
s = memsnap.summary(a)
check(f'summary of A: heap 3 pages, main.data 1, stack 0 ({s})', s == {'stack': 0, 'heap': 3 * PG, 'main.data': PG})
dd, runs = memsnap.diff(a, b)
check(f'diff heap: 3 new, 1 gone, 2 changed (pages 0 and 1), 0 same ({dd.get("heap")})', dd.get('heap') == {'new': 3 * PG, 'gone': PG, 'changed': 2 * PG, 'same': 0})
check(f'diff main.data: 1 new, 1 changed ({dd.get("main.data")})', dd.get('main.data') == {'new': PG, 'gone': 0, 'changed': PG, 'same': 0})
check(f'largest new run: heap pages 5-7 ({runs[:1]})', runs[:1] == [(HEAP + 5 * PG, 3 * PG)])
r = sorted(memsnap.refs(b, HEAP + PG, 0x40))
want = sorted([(HEAP + 0x18, HEAP + PG + 0x3f), (HEAP + PG + 0x20, HEAP + PG + 8), (DATA, HEAP + PG)])
check(f'refs into [heap+0x4000, +0x40): 3 aligned words; the bound and the unaligned word left out', r == want)
check('memsnap.py diff runs from the command line', memsnap.main(['diff', A, B]) == 0)
print(f'== {total} checks, {fails} failed =='); sys.exit(fails != 0)
