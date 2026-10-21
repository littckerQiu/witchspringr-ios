#!/usr/bin/env python3
"""tools/soak.py on files written by hand: a DM_MEMSTAT file (comment, header, a row a second) whose footprint climbs 2 GB in the first minutes and
then stays flat with noise reads as flat, the same with 120 MB an hour of climb reads as growth near that rate; Metal climbing alone is growth
too. Timing lines (with and without GPU time) give early and late medians; a red line first seen after the warm-up is reported, one seen before
it (with other numbers) is not. A frame window takes the timing lines ending in it; the spread of runs; the command channel's schedule.
The host itself is run with --host: a 10-frame window of the real host is not part of this test (it needs the game's files).
Negative control: T_SOAK_BROKEN=1 counts the warm-up in the slope (WARMUP_FRACTION 0, WARMUP_MIN_S 0): the flat run reads as growth."""
import os, random, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import soak
if os.environ.get('T_SOAK_BROKEN'):
    soak.WARMUP_FRACTION = 0; soak.WARMUP_MIN_S = 0
fails = total = 0
def check(name, ok):
    global fails, total
    total += 1; fails += not ok; print(f'{name:<96} {"✓" if ok else "✗"}')
HEAD = ('# MiB; kernel ledgers ...\ns\tphys_footprint\tavailable\tmetal_alloc\tinternal\tcompressed\tgraphics\theadroom\tguest\tcode\tmalloc\tgpu\tstack\tfile\tother'
        '\tg_alias\tg_stack\tg_heap\tcharged_total\tunattributed\talias_mapped\talias_hostpages\tframe\n')
def memfile(d, name, fp, metal=lambda t: 500, secs=1800):
    p = os.path.join(d, name); rnd = random.Random(7)
    with open(p, 'w') as f:
        f.write(HEAD)
        for t in range(secs):
            f.write(f'{t}\t{int(fp(t) + rnd.uniform(-40, 40))}\t0\t{int(metal(t))}\t0\t0\t0\t0' + '\t1/1/1' * 10 + f'\t0\t0\t0\t0\t{t * 30}\n')
        f.write('1800\t12')   # a line cut short when the process ended
    return p
ramp = lambda t: min(t, 180) / 180 * 2000 + 1000
with tempfile.TemporaryDirectory() as d:
    flat = soak.read_memstat(memfile(d, 'flat.tsv', ramp))
    check(f'the file: 1,800 rows, the cut line left out, footprint and frame read ({len(flat)})', len(flat) == 1800 and flat[600][3] == 18000 and abs(flat[600][1] - 3000) <= 40)
    r = soak.soak_report(flat, [], [])
    check(f"a 2 GB climb in the first 3 minutes, then flat: flat ({r['footprint_mb_h']:+.0f} MB/h)", r['memory'] == 'flat' and abs(r['footprint_mb_h']) < 20)
    grow = soak.read_memstat(memfile(d, 'grow.tsv', lambda t: ramp(t) + t / 3600 * 120))
    r = soak.soak_report(grow, [], [])
    check(f"... with 120 MB an hour on top: growth near that rate ({r['footprint_mb_h']:+.0f} MB/h)", r['memory'] == 'grows' and 100 < r['footprint_mb_h'] < 140)
    r = soak.soak_report(soak.read_memstat(memfile(d, 'metal.tsv', ramp, metal=lambda t: 500 + t / 3600 * 200)), [], [])
    check(f"Metal climbing 200 MB an hour alone: growth ({r['metal_mb_h']:+.0f} MB/h)", r['memory'] == 'grows' and 180 < r['metal_mb_h'] < 220)
    log = os.path.join(d, 'log.txt')
    with open(log, 'w') as f:
        f.write('[dm] [red] texture type mismatch: serial 12 at 0x1234\n')
        for i in range(1, 13):
            gpu = f' GPU p50 {6 + i * 0.1:.2f} / p95 9.0 / max 12 ms (300 frames);' if i != 5 else ''
            f.write(f'[dm] [nvn] timing up to frame {i * 300}: frame time p50 {33 + (i > 6)}.50 / p95 45.0 / max 50.0 ms (300 frames); frame work p50 1 / p95 2 / max 3 ms;{gpu}\n')
            if i == 2: f.write('[dm] [red] texture type mismatch: serial 99 at 0xabcd\n')
            if i == 9: f.write('[dm] [nvn-mtl] [red] a new kind of failure 7\n')
    timing, red = soak.read_log(log)
    check(f'timing lines: 12, the one without GPU time read with -1 ({len(timing)})', len(timing) == 12 and timing[4][4] == -1 and timing[0][0] == 300 and timing[0][1] == 33.5)
    check('red lines with the frame of the timing line before them', [f for f, _ in red] == [0, 600, 2700])
    mem_short = [(t, 1000, 500, t * 10) for t in range(400)]   # 10 frames a second: the warm-up (120 s) ends at frame 1,200
    r = soak.soak_report(mem_short, timing, red)
    check(f"frame time early → late: 33.5 → 34.5 ms; GPU early → late ({r['frame_p50_ms']}, {r['gpu_p50_ms']})", r['frame_p50_ms'] == [33.5, 34.5] and r['gpu_p50_ms'][1] > r['gpu_p50_ms'][0])
    check(f"a red line first seen after the warm-up is reported, the early kind again with other numbers is not ({len(r['late_red'])})",
          len(r['late_red']) == 1 and 'new kind' in r['late_red'][0])
    w = soak.window_stats(timing, 1800, 3300)
    check(f"frames 1800-3300: the 5 timing lines ending in it (2100-3300), mean p50 ({w and w['windows']}, {w and round(w['frame_p50_ms'], 2)})",
          w and w['windows'] == 5 and abs(w['frame_p50_ms'] - 34.5) < 1e-9)
    check('a window with no timing line in it: none', soak.window_stats(timing, 9000, 9300) is None)
    s = soak.spread([{'gpu_p50_ms': 7.0}, None, {'gpu_p50_ms': 6.0}, {'gpu_p50_ms': 9.0}], 'gpu_p50_ms')
    check('the spread of three runs (one without a window left out): 6 / 7 / 9', s == {'min': 6.0, 'median': 7.0, 'max': 9.0})
    sc = soak.schedule(20, 4, '/out')
    check(f'20 minutes, 4 shots: sleep 300,000 ms and a shot four times, three frames for the last shot, then quit ({len(sc)} lines)',
          sc == ['sleep 300000', 'shot /out/soak1.png'] + ['sleep 300000', 'shot /out/soak2.png', 'sleep 300000', 'shot /out/soak3.png', 'sleep 300000', 'shot /out/soak4.png', 'wait 3', 'quit'])
    check('no shots: one sleep, then quit', soak.schedule(1, 0, '/o') == ['sleep 60000', 'wait 3', 'quit'])
print(f'== {total} checks, {fails} failed =='); sys.exit(fails != 0)
