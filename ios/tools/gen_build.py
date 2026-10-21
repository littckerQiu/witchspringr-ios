#!/usr/bin/env python3
# Build inputs of the iOS app, taken from the host's own compile command (make -n -B dmhost GAME=<game>), so the app follows host/Makefile:
#   Gen/src/<flat name>   symlinks to the host sources (not main.c and not *_mac.* sources; main.c goes to Gen/main/main.c, built with -Dmain=dm_main)
#   stdout               xcconfig lines: HEADER_SEARCH_PATHS (the -I directories and every source directory), OTHER_CFLAGS (-D), DM_FRAMEWORKS
# Usage: gen_build.py <host dir> <Gen dir> <game>
import os, shlex, subprocess, sys
host, gen, game = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2]), sys.argv[3]
subprocess.run(['make', '-s', '-C', host, 'profile', f'GAME={game}'], check=True)   # the generated profile source must exist (make -n only prints)
cmd = subprocess.run(['make', '-s', '-n', '-B', '-C', host, 'dmhost', f'GAME={game}'], capture_output=True, text=True, check=True).stdout
toks = shlex.split(next(l for l in cmd.splitlines() if l.lstrip().startswith('clang')))
srcs, incs, defs, fws = [], [], [], []
i = 0
while i < len(toks):
    t = toks[i]
    if t == '-framework': fws.append(toks[i + 1]); i += 2; continue
    if t.startswith('-I'): incs.append(os.path.normpath(os.path.join(host, t[2:])))
    elif t.startswith('-D'): defs.append(t)
    elif t.endswith(('.c', '.m', '.S')): srcs.append(os.path.normpath(os.path.join(host, t)))
    i += 1
assert srcs, 'no sources in the host compile command'
dup = sorted({s for s in srcs if srcs.count(s) > 1})
if dup: sys.exit('sources listed twice in the host compile command: ' + ' '.join(dup))
os.makedirs(f'{gen}/src'); os.makedirs(f'{gen}/main')
dirs = []
for s in srcs:
    d = os.path.dirname(s)
    if d not in dirs: dirs.append(d)
    b = os.path.basename(s)
    if os.path.splitext(b)[0].endswith('_mac'): continue   # Mac-only sources (front_mac.m, app_mac.m); ios/Sources implements front.h
    if s == os.path.join(host, 'main.c'): os.symlink(s, f'{gen}/main/main.c'); continue
    flat = os.path.relpath(s, os.path.dirname(host)).replace('/', '__').replace('..', '_')   # same names in different directories do not collide
    os.symlink(s, f'{gen}/src/{flat}')
print('HEADER_SEARCH_PATHS = $(inherited) ' + ' '.join(f'"{d}"' for d in incs + dirs))
print('OTHER_CFLAGS = $(inherited) ' + ' '.join(defs))
print('DM_FRAMEWORKS = ' + ' '.join(f'-framework {f}' for f in fws if f != 'Cocoa'))
