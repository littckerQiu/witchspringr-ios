#!/usr/bin/env python3
# Older-API build of project.yml: deployment target iOS 18 and the graphics backend without Metal 4 (DM_NVN_M3, gfx/nvn/nvn_mtl.m), built for A14.
# Usage: project_m3.py <in yml> <out yml>
import sys
src, dst = sys.argv[1:3]; s = open(src, encoding='utf-8').read()
def one(old, new):
    global s
    if s.count(old) != 1: sys.exit(f'project_m3.py: "{old[:40]}" should occur exactly once, found {s.count(old)}')
    s = s.replace(old, new)
one('    iOS: "26.0"', '    iOS: "18.0"')
one('OTHER_CFLAGS: $(inherited) -mcpu=apple-a18', 'OTHER_CFLAGS: $(inherited) -mcpu=apple-a14 -DDM_NVN_M3=1')
open(dst, 'w', encoding='utf-8').write(s)
