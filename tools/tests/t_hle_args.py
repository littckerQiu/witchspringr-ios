#!/usr/bin/env python3
"""tools/hle_args.py: host functions the guest calls take every argument in a register (host/hstack.S runs them on the host stack). Synthetic
sources: 8 integer + 8 floating-point parameters pass; a 9th of either, "...", a struct passed by value and a vtable slot with 9 parameters are
found, also with a comment inside the vtable; a commented-out definition is not counted; this repository's sources have no finding."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import hle_args
fails = total = 0
def check(name, ok):
    global fails, total
    total += 1; fails += not ok; print(f'{name:<78} {"✓" if ok else "✗"}')
P8 = ', '.join(f'uint64_t a{i}' for i in range(8)); D8 = ', '.join(f'double d{i}' for i in range(8))
def run(src): return hle_args.check_source('t.c', src)
n, f = run(f'HLE("x", int, h_x, {P8}, {D8}) {{ return 0; }}\n')
check('8 integer and 8 floating-point parameters pass', n == 1 and not f)
n, f = run(f'HLE_FORCE("x", "why, with a comma (and parentheses)", int, h_x, {P8}, int a8) {{ return 0; }}\n')
check(f'a 9th integer parameter is found ({f[0] if f else ""})', n == 1 and len(f) == 1 and '9 integer' in f[0])
n, f = run(f'HLE_FORCE_OPT("x", "why", void, h_x, {D8}, float f8) {{ }}\n')
check('a 9th floating-point parameter is found', len(f) == 1 and '9 floating-point' in f[0])
n, f = run('HLE("x", int, h_x, const char *fmt, ...) { return 0; }\n')
check('a variadic function is found', len(f) == 1 and 'variadic' in f[0])
n, f = run('HLE("x", int, h_x, struct timespan t) { return 0; }\n')
check('a struct passed by value is found', len(f) == 1 and 'struct timespan' in f[0])
n, f = run('NVN_NOPROTO(nvnFoo, void, NVNcommandBuffer *c, NVNshaderStage s, int a, float x) { }\n')
check('NVN_NOPROTO with pointers, an NVN enum, int and float passes', n == 1 and not f)
src = ('static void a(void *s) { }\nstatic int b(void *s, ' + P8 + ') { return 0; }\n'
       'static void *const g_t_vt[2] = {   // slot order of the guest\'s vtable\n    a, b,\n};\n')
n, f = run(src)
check(f'a vtable slot with 9 parameters is found, past a comment ({f[0] if f else ""})', n == 2 and len(f) == 1 and 'b (g_t_vt)' in f[0])
n, f = run('// HLE("x", int, h_x, const char *fmt, ...) { return 0; }\n/* HLE("y", int, h_y, ...) */\n')
check('commented-out definitions are not counted', n == 0 and not f)
r = hle_args.main(['hle_args.py'])
check('this repository: no finding', r == 0)
print(f'== {total} checks, {fails} failed =='); sys.exit(fails != 0)
