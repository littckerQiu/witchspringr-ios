#!/usr/bin/env python3
"""gfx/tools/c1_guard.py: which c1 reads are proven inside a shared bank's span, on MSL in the form the translator writes ((*spvDescriptorSet0.fp_c1)._m0[i]).
A 64-byte c1 has a span of 512 (256 rounded + the 256 gap): index 3 passes, 40 does not; `_5 & 3u` passes; `_1 + (_2 & 3u)` with _1 from an input, a mask
wider than the span, `min` without a lower bound, a reassigned loop counter and a compute shader's unbounded cp_c1 read are not proven; clamp, an
unsigned min, a ternary of constants and an unsigned % pass; no reflection (no span) is not proven. The old guard (any mask, min or clamp on the last
variable; vertex and pixel only; literals always) passes five of the unproven ones. Run with any Python 3."""
import json, os, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'gfx', 'tools'))
import c1_guard as g
fails = total = 0
def check(name, ok):
    global fails, total
    total += 1; fails += not ok; print(f'{name:<78} {"✓" if ok else "✗"}')
def fp(body, idx, stage='fp'):
    return f'fragment main0_out main0(main0_in in [[stage_in]]) {{\n{body}\n    float4 v = (*spvDescriptorSet0.{stage}_c1)._m0[{idx}];\n}}\n'
d = tempfile.mkdtemp(); jp = os.path.join(d, 'k_b.json'); json.dump({'c1': '00' * 64}, open(jp, 'w'))
span = g.c1_span(jp)
check(f'a 64-byte c1: span 512 ({span})', span == 512)
check('literal index 3 (16 * 4 = 64 <= 512) is proven', g.unproven(fp('', '3'), span) == 0)
check('literal index 40 (16 * 41 = 656 > 512) is not', g.unproven(fp('', '40'), span) == 1)
check('_5 & 3u is proven', g.unproven(fp('    int _5 = int(in.m0.x);', '_5 & 3u'), span) == 0)
check('_1 + (_2 & 3u) with _1 from an input is not', g.unproven(fp('    int _1 = int(in.m0.y);\n    int _2 = int(in.m0.x);', '_1 + (_2 & 3u)'), span) == 1)
check('_7 & 255 (16 * 256 > 512) is not', g.unproven(fp('    int _7 = int(in.m0.x);', '_7 & 255'), span) == 1)
check('min(_8, 10) with _8 signed and unbounded below is not', g.unproven(fp('    int _8 = int(in.m0.x);', 'min(_8, 10)'), span) == 1)
check('clamp(_8, 0, 10) is proven', g.unproven(fp('    int _8 = int(in.m0.x);', 'clamp(_8, 0, 10)'), span) == 0)
check('min(_9, 10u) with _9 unsigned is proven', g.unproven(fp('    uint _9 = uint(in.m0.x);', 'min(_9, 10u)'), span) == 0)
check('a loop counter assigned again is not', g.unproven(fp('    int _10 = 0;\n    _10 += 1;', '_10 & 3'), span) == 0 and g.unproven(fp('    int _10 = 0;\n    _10 += 1;', '_10'), span) == 1)
check('(_3 != 0) ? 2 : 5 is proven', g.unproven(fp('    int _3 = int(in.m0.x);', '(_3 != 0) ? 2 : 5'), span) == 0)
check('_6 % 4u with _6 unsigned is proven', g.unproven(fp('    uint _6 = uint(in.m0.x);', '_6 % 4u'), span) == 0)
check('a compute shader\'s cp_c1 read by an input is not', g.unproven(fp('    int _4 = int(gl_GlobalInvocationID.x);', '_4', 'cp'), span) == 1)
check('no reflection (no span) is not', g.unproven(fp('', '0'), g.c1_span(os.path.join(d, 'missing_b.json'))) == 1)
check('a shader without c1 reads has nothing to prove', g.unproven('fragment void main0() {}', None) == 0)
print(f'== {total} checks, {fails} failed =='); sys.exit(fails != 0)
