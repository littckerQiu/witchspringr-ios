#!/usr/bin/env python3
"""tools/rewriter_stamp.py: the stamp follows the rules' content (same bytes, same stamp; one byte changed, another), the rewriter's own source
(a stamp without rules differs from one with them), and is 16 hex digits, as host/Makefile and loader.c read it."""
import os, subprocess, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import rewriter_stamp as rs
fails = total = 0
def check(name, ok):
    global fails, total
    total += 1; fails += not ok; print(f'{name:<78} {"✓" if ok else "✗"}')
with tempfile.TemporaryDirectory() as td:
    a, b, c = (os.path.join(td, n) for n in ('a.py', 'b.py', 'c.py'))
    open(a, 'w').write('CUTS = {}\n'); open(b, 'w').write('CUTS = {}\n'); open(c, 'w').write('CUTS = {} \n')
    check('same rules bytes in two files: the same stamp', rs.stamp(a) == rs.stamp(b))
    check('one byte more in the rules: another stamp', rs.stamp(a) != rs.stamp(c))
    check('no rules: another stamp than with rules', rs.stamp(None) != rs.stamp(a))
    s = rs.stamp(a); check('16 lowercase hex digits', len(s) == 16 and all(ch in '0123456789abcdef' for ch in s))
    out = subprocess.run([sys.executable, '-I', os.path.join(os.path.dirname(rs.__file__), 'rewriter_stamp.py'), a], capture_output=True, text=True).stdout.strip()
    check('the command line prints the same stamp (host/Makefile uses it)', out == s)
print(f'== {total} checks, {fails} failed =='); sys.exit(fails != 0)
