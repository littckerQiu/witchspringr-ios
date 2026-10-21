#!/usr/bin/env python3
"""One trip to the background and back, judged from the host's log (plan item 51; the criteria of upstream d2r-mobile's ios/tools/lifecycle.sh,
MIT, for this host's log lines). The log is a Mac run with DM_TEST_BG=<s>,<len> (host/front_mac.m) or an iPhone's Documents/boot.txt (scene events
or DM_TEST_BG, ios/Sources/front_ios.m); both write the same lines.

  lifecycle_check.py <log> [--after N]

Checks, in the first background → foreground pair:
  1 the background, then the return, in one log (the process was not started again)
  2 graphics suspended while away
  3 the time away is not game time: the guest clock at the background and at the return less than 1 s apart
  4 audio paused while away and resumed after the return (not "resume failed")
  5 the game goes on presenting: N timing lines (300 frames each, default 1) after the return, past the last frame before the background
  6 no kind of red line first seen after the background
The last line is LIFECYCLE OK or LIFECYCLE RED (exit 0 / 1). Checked by tools/tests/t_lifecycle_check.py.
"""
import re
import sys

EV = re.compile(r'front: (sceneDidEnterBackground|sceneWillEnterForeground) \(guest clock ([\d.]+) s')
TIMING = re.compile(r'\[nvn\] timing up to frame (\d+):')


def red_key(text):   # a red line without its numbers
    return re.sub(r'0x[0-9a-f]+|\d+', 'N', text)


def check(lines, after=1):
    """[(ok, text)] for the six checks."""
    bg = fg = None; cb = cf = None
    for i, l in enumerate(lines):
        m = EV.search(l)
        if not m:
            continue
        if m.group(1) == 'sceneDidEnterBackground' and bg is None:
            bg, cb = i, float(m.group(2))
        elif m.group(1) == 'sceneWillEnterForeground' and bg is not None and fg is None:
            fg, cf = i, float(m.group(2))
    res = [(bg is not None and fg is not None, f'the background (line {bg + 1 if bg is not None else "-"}), then the return (line {fg + 1 if fg is not None else "-"}), in one log')]
    if bg is None or fg is None:
        return res + [(False, 'the other checks need both')]
    away, post = lines[bg:fg], lines[fg:]
    res.append((any('graphics suspended' in l for l in away), 'graphics suspended while away'))
    res.append((abs(cf - cb) < 1.0, f'the time away is not game time: guest clock {cb:.3f} s at the background, {cf:.3f} s at the return'))
    paused = any('audio paused' in l for l in away); resumed = any('audio resumed' in l for l in post); failed = any('audio resume failed' in l for l in post)
    res.append((paused and resumed and not failed, f'audio paused while away ({"yes" if paused else "no"}) and resumed after ({"failed" if failed else "yes" if resumed else "no"})'))
    before = [int(m.group(1)) for l in lines[:bg] for m in [TIMING.search(l)] if m]
    later = [int(m.group(1)) for l in post for m in [TIMING.search(l)] if m]
    last = before[-1] if before else 0
    n_after = len([f for f in later if f > last])
    res.append((n_after >= after, f'presenting goes on: {n_after} timing lines after the return, past frame {last} (at least {after})'))
    early = {red_key(l) for l in lines[:bg] if '[red]' in l}
    new = []
    for l in lines[bg:]:
        if '[red]' in l and red_key(l) not in early and red_key(l) not in {red_key(x) for x in new}:
            new.append(l.strip())
    res.append((not new, 'no kind of red line first seen after the background' + ''.join('\n    ' + t[:200] for t in new)))
    return res


def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__); return 2
    after = 1
    if '--after' in argv:
        i = argv.index('--after'); after = int(argv[i + 1]); argv = argv[:i] + argv[i + 2:]
    with open(argv[0], errors='replace') as f:
        lines = f.readlines()
    res = check(lines, after)
    for ok, text in res:
        print(('✓ ' if ok else '✗ ') + text)
    ok = all(r[0] for r in res)
    print('LIFECYCLE OK' if ok else 'LIFECYCLE RED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
