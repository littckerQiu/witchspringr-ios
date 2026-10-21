#!/usr/bin/env python3
"""tools/lifecycle_check.py on logs written by hand: a good trip (background, suspended, the same guest clock back, audio paused and resumed,
timing lines on, an old kind of red line seen again) passes; each check fails on its own on a log that breaks it: no return, no suspend, 30 s
of game time while away, audio not resumed or failing to, no timing line after the return, a new kind of red line after the background.
Negative control: T_LC_BROKEN=1 (the guest clock not compared) passes the log with 30 s of game time away."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import lifecycle_check as lc
if os.environ.get('T_LC_BROKEN'):
    real = lc.check
    def check(lines, after=1):
        return [(True, t) if 'not game time' in t else (ok, t) for ok, t in real(lines, after)]
    lc.check = check
fails = total = 0
def expect(name, ok):
    global fails, total
    total += 1; fails += not ok; print(f'{name:<92} {"✓" if ok else "✗"}')
def log(clock_back=40.2, suspend=True, resumed='resumed (foreground / interruption ended)', after=2, new_red=False, back=True):
    l = ['[dm] [nvn-mtl] [red] texture type mismatch: serial 12 (first case)\n']
    l += [f'[dm] [nvn] timing up to frame {300 * i}: frame time p50 33.5 / p95 40 / max 50 ms (300 frames);\n' for i in range(1, 5)]
    l += ['[dm] front: DM_TEST_BG enter background\n', '[dm] front: sceneWillResignActive (guest clock 40.100 s, audio callbacks 0)\n',
          '[dm] front: sceneDidEnterBackground (guest clock 40.110 s, audio callbacks 0)\n', '[dm] audio paused (background / interruption)\n']
    if suspend: l.append('[dm] [nvn] graphics suspended: in-flight GPU work drained\n')
    if back:
        l += ['[dm] front: DM_TEST_BG return\n', f'[dm] front: sceneWillEnterForeground (guest clock {clock_back:.3f} s, audio callbacks 0)\n', '[dm] [nvn] graphics resumed\n']
        if resumed: l.append(f'[dm] audio {resumed}\n')
        l.append('[dm] front: sceneDidBecomeActive (guest clock 40.300 s, audio callbacks 0)\n')
        l.append('[dm] [nvn-mtl] [red] texture type mismatch: serial 99 (first case)\n')
        l += [f'[dm] [nvn] timing up to frame {1200 + 300 * i}: frame time p50 33.5 / p95 40 / max 50 ms (300 frames);\n' for i in range(1, after + 1)]
        if new_red: l.append('[dm] [red] command buffer error in a part of submission 812\n')
    return l
def fails_only(lines, k, after=1):   # check k fails and the others pass
    r = lc.check(lines, after); return len(r) == 6 and not r[k][0] and all(ok for i, (ok, _) in enumerate(r) if i != k)
r = lc.check(log())
expect('a good trip: all six pass (an old kind of red line seen again is not new)', len(r) == 6 and all(ok for ok, _ in r))
r = lc.check(log(back=False))
expect('no return: the first check fails, the rest cannot be judged', not r[0][0] and not r[1][0] and len(r) == 2)
expect('graphics not suspended: check 2 alone', fails_only(log(suspend=False), 1))
expect('30 s of game time while away: check 3 alone', fails_only(log(clock_back=70.2), 2))
expect('audio not resumed: check 4 alone', fails_only(log(resumed=None), 3))
expect('audio resume failed: check 4 alone', fails_only(log(resumed='resume failed'), 3))
expect('no timing line after the return: check 5 alone', fails_only(log(after=0), 4))
expect('two timing lines asked, one there: check 5 alone', fails_only(log(after=1), 4, after=2))
expect('a new kind of red line after the background: check 6 alone', fails_only(log(new_red=True), 5))
import tempfile
with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as f:
    f.writelines(log()); p = f.name
expect('the command line: exit 0 and LIFECYCLE OK on a good log', lc.main([p]) == 0)
os.unlink(p)
print(f'== {total} checks, {fails} failed =='); sys.exit(fails != 0)
