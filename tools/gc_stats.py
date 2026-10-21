#!/usr/bin/env python3
# IL2CPP garbage collector statistics from a host log: run with DM_GUEST_ENV="GC_PRINT_STATS=1" DM_DBG=1, then this prints the collections
# (at most about 30 rows, evenly spaced, and the last): MiB freed, heap size, and the share and size of the heap in use after the collection.
# Usage: gc_stats.py <log>
import re, sys

gc = []; cur = None
for line in open(sys.argv[1], errors='replace'):
    m = re.search(r'GC #(\d+) freed (-?\d+) bytes, heap (\d+) KiB', line)
    if m: cur = [int(m[1]), int(int(m[2]) / (1 << 20)), int(m[3]) >> 10, None, None]; gc.append(cur); continue   # the log has negative freed counts too
    m = re.search(r'In-use heap: (\d+)% \((\d+) KiB pointers \+ (\d+) KiB other\)', line)
    if m and cur and cur[3] is None: cur[3] = int(m[1]); cur[4] = (int(m[2]) + int(m[3])) >> 10
print(f'{len(gc)} collections')
if gc:
    step = max(1, len(gc) // 30)
    print('   GC#  freed MiB  heap MiB  in-use %  in-use MiB')
    for g in gc[::step] + ([gc[-1]] if (len(gc) - 1) % step else []):
        print(f'{g[0]:>6} {g[1]:>10} {g[2]:>9} {str(g[3]):>9} {str(g[4]):>11}')
