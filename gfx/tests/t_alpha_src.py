#!/usr/bin/env python3
"""Writes the MSL t_alpha.m draws with: a fragment shader as the translator's output looks (colour 0 = (1, 0, 0, alpha from buffer 1), colour 1
green, an early return) passed through gfx/tools/dmsh_build.py's own alpha_test, taken from that file without running the build.
Usage: t_alpha_src.py <1: the shader exports colour 0's alpha | 0: it does not>"""
import ast, os, re, sys
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools', 'dmsh_build.py')).read()
tree = ast.parse(src)
ns = {'re': re}
exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'alpha_test'
                              or isinstance(n, ast.Assign) and any(getattr(t, 'id', '') == 'ALPHA_DECL' for t in n.targets)], type_ignores=[]), 'dmsh_build.py', 'exec'), ns)
shader = """#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; };
vertex VOut vertex0(uint n [[vertex_id]]) { float2 p = float2(float((n << 1) & 2), float(n & 2)); VOut o; o.pos = float4(p * 2.0 - 1.0, 0.25, 1.0); return o; }
struct main0_out { float4 m_10 [[color(0)]]; float4 m_11 [[color(1)]]; };
fragment main0_out main0(constant float& alpha [[buffer(1)]], constant uint& early [[buffer(2)]])
{
    main0_out out = {};
    out.m_10 = float4(1.0, 0.0, 0.0, alpha);
    out.m_11 = float4(0.0, 1.0, 0.0, 1.0);
    if (early != 0u)
        return out;
    out.m_11 = float4(0.0, 1.0, 0.0, 1.0);
    return out;
}
"""
sys.stdout.write(ns['alpha_test'](shader, sys.argv[1] == '1'))
