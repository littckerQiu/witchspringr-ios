#!/usr/bin/env python3
# One row per load cycle of the host's memory accounting (DM_MEMSTAT tsv): footprint, Metal, and the charged MiB of the guest's alias region,
# stack region and heap, all guest memory and malloc. Made for games/manosaba/reload_loop.sh: the row before the loop is at <first> − 5 s, cycle c at
# <first> + <period> × c + <at> s.
# Usage: memstat_cycles.py <mem.tsv> [--first 60] [--period 40] [--at 37]
import argparse

ap = argparse.ArgumentParser()
ap.add_argument('tsv'); ap.add_argument('--first', type=float, default=60); ap.add_argument('--period', type=float, default=40)
ap.add_argument('--at', type=float, default=37)
a = ap.parse_args()
rows = [l.rstrip('\n').split('\t') for l in open(a.tsv) if not l.startswith('#')]
head, rows = rows[0], rows[1:]
ix = {k: i for i, k in enumerate(head)}

def charged(r, k):   # class columns are virtual/resident/charged
    return int(r[ix[k]].split('/')[2]) if k in ix else -1

cols = ['g_alias', 'g_stack', 'g_heap', 'guest', 'malloc']
print(f"{'cycle':>5} {'s':>5} {'footprint':>9} {'metal':>6} " + ' '.join(f'{k:>7}' for k in cols) + f" {'alias_mapped':>12}")
c = -1
while True:
    s = a.first - 5 if c < 0 else a.first + a.period * c + a.at
    near = [r for r in rows if abs(float(r[0]) - s) <= 1]
    if not near: break
    r = near[0]
    print(f"{c:>5} {r[0]:>5} {r[ix['phys_footprint']]:>9} {r[ix['metal_alloc']]:>6} " + ' '.join(f'{charged(r, k):>7}' for k in cols)
          + f" {r[ix['alias_mapped']]:>12}")
    c += 1
