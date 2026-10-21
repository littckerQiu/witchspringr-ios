#!/usr/bin/env python3
"""Soak and fixed-scene measurement (plan item 50, after MacNativeGames' mac_v143_soak.py / mac_v143_smoke.py, MIT; written for this host).

  soak.py run --out DIR --minutes M [--shots K] [--env NAME=VALUE ...] -- <host command ...>
      Runs the host headless for M minutes and reports what drifts: memory after the boot (phys_footprint and Metal, a straight line through the
      samples after the warm-up, MB an hour), frame time and GPU time early against late, red lines first seen after the warm-up. K screenshots
      are taken on the way through the command channel (DM_CMD), which also ends the run with "quit".
  soak.py window --out DIR --frames A-B [--repeat N] [--clean DIR ...] [--env ...] -- <host command ...>
      Runs the host N times up to frame B and gives each run's frame time and GPU time over frames A-B (the "[nvn] timing" lines of the 300
      frames ending in that window), and their spread: the noise an A/B comparison of a fixed scene has to beat. --clean empties a directory
      (the save, for the same start every time) before each run; run takes it too.
  soak.py report DIR
      Reads a run's files again (log.txt, mem.tsv) and prints its report.

The host gets DM_MEMSTAT=DIR/mem.tsv, DM_CMD=DIR/cmd.txt and a DM_WATCH backstop; its stderr goes to DIR/log.txt (DIR/run<i>/ for window).
Examples (the paths as for any run of the host; see host/README.md):
  DM_GAME=totk DM_ROOT=$PWD/work DM_SAVE=... tools/soak.py run --out /tmp/soak1 --minutes 20 -- host/dmhost
  tools/soak.py window --out /tmp/win1 --frames 1800-3300 --repeat 3 --env DM_GAME=totk ... -- host/dmhost
Checked by tools/tests/t_soak.py.
"""
import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time

WARMUP_FRACTION = 0.25   # the first quarter of a run (at least WARMUP_MIN_S) is the boot and the first loads, not steady state
WARMUP_MIN_S = 120
GROWS_MB_H = 50          # a steady climb of more than this is reported as growth

TIMING = re.compile(r'\[nvn\] timing up to frame (\d+): frame time p50 ([\d.]+) / p95 ([\d.]+) / max ([\d.]+) ms(?:.*?GPU p50 ([\d.]+) / p95 ([\d.]+))?')


def read_memstat(path):
    """[(s, footprint MiB, metal MiB, frame)] from a DM_MEMSTAT file (a # comment line, a header, then a row a second)."""
    rows, head = [], None
    with open(path, errors='replace') as f:
        for line in f:
            if line.startswith('#'):
                continue
            cols = line.rstrip('\n').split('\t')
            if head is None:
                head = {k: i for i, k in enumerate(cols)}
                continue
            try:
                rows.append((float(cols[head['s']]), int(cols[head['phys_footprint']]), int(cols[head['metal_alloc']]),
                             int(cols[head['frame']]) if 'frame' in head and len(cols) > head['frame'] else -1))
            except (ValueError, IndexError, KeyError):
                continue   # (a line cut short when the process ended)
    return rows


def read_log(path):
    """The timing lines [(frame, p50, p95, max, gpu p50, gpu p95)] and the red lines [(frame of the last timing line before it, text)]."""
    timing, red, frame = [], [], 0
    with open(path, errors='replace') as f:
        for line in f:
            m = TIMING.search(line)
            if m:
                frame = int(m.group(1))
                timing.append((frame, *(float(m.group(i)) if m.group(i) else -1.0 for i in range(2, 7))))   # (-1: no GPU time in the line)
            elif '[red]' in line:
                red.append((frame, line.strip()))
    return timing, red


def slope_mb_h(samples):
    """Least-squares slope of [(s, MiB)] in MiB an hour (0 for fewer than two)."""
    if len(samples) < 2:
        return 0.0
    n = len(samples); mx = sum(s for s, _ in samples) / n; my = sum(v for _, v in samples) / n
    sxx = sum((s - mx) ** 2 for s, _ in samples)
    return 0.0 if not sxx else sum((s - mx) * (v - my) for s, v in samples) / sxx * 3600


def warmup_s(duration):
    return max(WARMUP_MIN_S, duration * WARMUP_FRACTION)


def red_key(text):   # a red line without its numbers: the same kind of line is one kind
    return re.sub(r'0x[0-9a-f]+|\d+', 'N', text)


def soak_report(mem, timing, red):
    """What drifts in a run: a dict (and its lines in 'lines')."""
    r = {'lines': []}
    if mem:
        dur = mem[-1][0] - mem[0][0]; cut = mem[0][0] + warmup_s(dur)
        steady = [m for m in mem if m[0] >= cut]
        r['duration_s'] = dur
        r['footprint_mb'] = [mem[0][1], max(m[1] for m in mem), mem[-1][1]]
        r['footprint_mb_h'] = slope_mb_h([(m[0], m[1]) for m in steady])
        r['metal_mb_h'] = slope_mb_h([(m[0], m[2]) for m in steady])
        r['memory'] = 'grows' if r['footprint_mb_h'] > GROWS_MB_H or r['metal_mb_h'] > GROWS_MB_H else 'flat'
        warm_frame = next((m[3] for m in mem if m[0] >= cut and m[3] >= 0), 0)
        r['lines'].append(f"memory after the first {cut - mem[0][0]:.0f} s: footprint {r['footprint_mb_h']:+.0f} MB/h, Metal {r['metal_mb_h']:+.0f} MB/h "
                          f"({r['memory']}; footprint {r['footprint_mb'][0]} → max {r['footprint_mb'][1]} → {r['footprint_mb'][2]} MB over {dur / 60:.1f} min)")
    else:
        warm_frame = 0
    if len(timing) >= 4:
        q = max(1, len(timing) // 4); early, late = timing[:q], timing[-q:]
        med = lambda rows, i: statistics.median(t[i] for t in rows)
        r['frame_p50_ms'] = [med(early, 1), med(late, 1)]; r['gpu_p50_ms'] = [med(early, 4), med(late, 4)]
        r['lines'].append(f"frame time p50 {r['frame_p50_ms'][0]:.2f} → {r['frame_p50_ms'][1]:.2f} ms, GPU p50 {r['gpu_p50_ms'][0]:.2f} → {r['gpu_p50_ms'][1]:.2f} ms "
                          f"(first and last quarter of {len(timing)} windows of 300 frames)")
    early_kinds = {red_key(t) for f, t in red if f <= warm_frame}
    late = []
    for f, t in red:
        k = red_key(t)
        if f > warm_frame and k not in early_kinds and k not in {red_key(x) for x in late}:
            late.append(t)
    r['late_red'] = late
    r['lines'].append(f"red lines: {len({red_key(t) for _, t in red})} kinds, {len(late)} first seen after the warm-up" + ''.join('\n  ' + t[:200] for t in late))
    return r


def window_stats(timing, a, b):
    """Mean frame time p50 and GPU p50 of the timing lines whose 300 frames end in (a, b]; None if there are none."""
    rows = [t for t in timing if a < t[0] <= b]
    if not rows:
        return None
    return {'windows': len(rows), 'frame_p50_ms': statistics.mean(t[1] for t in rows), 'frame_p95_ms': statistics.mean(t[2] for t in rows),
            'gpu_p50_ms': statistics.mean(t[4] for t in rows)}


def spread(runs, key):
    v = [r[key] for r in runs if r]
    return {'min': min(v), 'median': statistics.median(v), 'max': max(v)} if v else None


def schedule(minutes, shots, shot_dir):
    """The command channel's lines for a soak: a screenshot every minutes/shots, then quit (sleep in ms; the last shot is taken at the next
    present, so a few frames are waited for before quitting)"""
    lines, step = [], minutes * 60000 / max(shots, 1)
    for i in range(shots):
        lines += [f'sleep {int(step)}', f'shot {shot_dir}/soak{i + 1}.png']
    if not shots:
        lines.append(f'sleep {int(minutes * 60000)}')
    lines += ['wait 3', 'quit']
    return lines


def clean(dirs):
    for d in dirs or []:
        shutil.rmtree(d, ignore_errors=True); os.makedirs(d, exist_ok=True)


def launch(cmd, out, env_extra, cmd_lines, watch_s):
    os.makedirs(out, exist_ok=True)
    env = dict(os.environ); env.update(env_extra)
    env['DM_MEMSTAT'] = os.path.join(out, 'mem.tsv'); env['DM_CMD'] = os.path.join(out, 'cmd.txt')
    env.setdefault('DM_WATCH', str(int(watch_s)))
    with open(env['DM_CMD'], 'w') as f:
        f.write(''.join(l + '\n' for l in cmd_lines))
    with open(os.path.join(out, 'log.txt'), 'w') as log:
        t0 = time.time(); rc = subprocess.call(cmd, env=env, stdout=log, stderr=subprocess.STDOUT)
    return rc, time.time() - t0


def env_pairs(items):
    out = {}
    for e in items or []:
        k, _, v = e.partition('=')
        out[k] = v
    return out


def main(argv):
    ap = argparse.ArgumentParser(description='Soak and fixed-scene measurement of the host')
    sub = ap.add_subparsers(dest='mode', required=True)
    r = sub.add_parser('run'); r.add_argument('--out', required=True); r.add_argument('--minutes', type=float, required=True)
    r.add_argument('--shots', type=int, default=4); r.add_argument('--env', action='append'); r.add_argument('--clean', action='append'); r.add_argument('cmd', nargs='+')
    w = sub.add_parser('window'); w.add_argument('--out', required=True); w.add_argument('--frames', required=True)
    w.add_argument('--repeat', type=int, default=3); w.add_argument('--env', action='append'); w.add_argument('--clean', action='append'); w.add_argument('cmd', nargs='+')
    p = sub.add_parser('report'); p.add_argument('dir')
    a = ap.parse_args(argv)
    if a.mode == 'report' or a.mode == 'run':
        d = a.dir if a.mode == 'report' else a.out
        if a.mode == 'run':
            os.makedirs(d, exist_ok=True); clean(a.clean)
            rc, wall = launch(a.cmd, d, env_pairs(a.env), schedule(a.minutes, a.shots, os.path.abspath(d)), a.minutes * 60 + 600)
            print(f'host exit {rc} after {wall / 60:.1f} min')
        mem = read_memstat(os.path.join(d, 'mem.tsv')) if os.path.exists(os.path.join(d, 'mem.tsv')) else []
        timing, red = read_log(os.path.join(d, 'log.txt'))
        rep = soak_report(mem, timing, red)
        print('\n'.join(rep.pop('lines')))
        with open(os.path.join(d, 'soak.json'), 'w') as f:
            json.dump(rep, f, indent=1)
        return 0
    fa, fb = (int(x) for x in a.frames.split('-'))
    runs = []
    for i in range(a.repeat):
        d = os.path.join(a.out, f'run{i + 1}'); clean(a.clean)
        rc, wall = launch(a.cmd, d, env_pairs(a.env), [f'wait {fb}', 'quit'], 1800)
        timing, _ = read_log(os.path.join(d, 'log.txt'))
        s = window_stats(timing, fa, fb); runs.append(s)
        print(f'run {i + 1}: exit {rc}, {wall:.0f} s; ' + (f"frames {fa}-{fb}: frame time p50 {s['frame_p50_ms']:.2f} / p95 {s['frame_p95_ms']:.2f} ms, GPU p50 {s['gpu_p50_ms']:.2f} ms "
                                                          f"({s['windows']} windows)" if s else 'no timing line in the window'))
    res = {'frames': [fa, fb], 'runs': runs, 'frame_p50_ms': spread(runs, 'frame_p50_ms'), 'gpu_p50_ms': spread(runs, 'gpu_p50_ms')}
    for k in ('frame_p50_ms', 'gpu_p50_ms'):
        if res[k]:
            print(f"{k}: {res[k]['min']:.2f} / {res[k]['median']:.2f} / {res[k]['max']:.2f} (min / median / max of {a.repeat} runs)")
    with open(os.path.join(a.out, 'window.json'), 'w') as f:
        json.dump(res, f, indent=1)
    return 0 if all(runs) else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
