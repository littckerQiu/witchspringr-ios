# All-thread sampling (DM_SAMPLE=ms:*) summary: for a time window and an optional thread, reports each thread's running share and the self / inclusive hotspots of game functions (eh_frame starts).
# Usage: sampagg.py <log> <start s> <end s> [thread handle 0x...]   Reads the game's original main / sdk NSO from workspace.exefs (under DM_ROOT) of
#   games/$DM_GAME/game.json (default manosaba) and decompresses them with verify/nsoimg.py into the original memory images (functions resolved by offset)
#   No thread given: lists each thread's sample count, running share and top 3 self hotspots
#   Thread given: that thread's self hotspots among running samples, host frames, and inclusive hotspots (waiting samples = innermost frame is in a system wait function, not counted as running)
import sys, re, bisect, subprocess, collections, os, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'verify'))
import nsoimg, gen_game
DM_ROOT = os.environ.get('DM_ROOT') or os.path.expanduser('~/dm-work')   # Workspace root (game files, build outputs and run artifacts are all under it)
log, lo, hi = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]); thr = int(sys.argv[4], 16) if len(sys.argv) > 4 else None
GAME = os.environ.get('DM_GAME') or 'manosaba'
EXEFS = os.path.join(DM_ROOT, gen_game.load(os.path.join(HERE, '..', 'games', GAME, 'game.json'))['workspace']['exefs'])
SDIS = os.path.join(HERE, 'sdis.py')
st = {}
for m in ('main', 'sdk'):
    with tempfile.TemporaryDirectory() as td:   # sdis.py reads its image from a file: hand it the decompressed NSO (the <module>.orig.bin that tools/nso.py writes)
        p = os.path.join(td, f'{m}.orig.bin')
        with open(p, 'wb') as f: f.write(nsoimg.load(os.path.join(EXEFS, m)))
        sys.argv = ['x', p, '--find', 'x']; g = {}
        exec(open(SDIS).read().split("if sys.argv[2] == '--sym'")[0], g); st[m] = (g['fn_starts'](), g['name'])
WAIT = ('mach_wait_until', '__psynch_cvwait', '__semwait_signal', 'nanosleep', 'mach_msg2_trap', 'swtch_pri', '__psynch_mutexwait', 'block_inner', '__ulock_wait')
lines = open(log, encoding='utf-8', errors='replace').read().split('\n')
def fnof(f):
    mm = re.match(r'(main|sdk)\+0x([0-9a-f]+)', f)
    if not mm: return None
    s, _ = st[mm.group(1)]; off = int(mm.group(2), 16); return f'{mm.group(1)}+{s[bisect.bisect_right(s, off) - 1]:#x}'
def dm(fn):
    mod, a = fn.split('+'); r = st[mod][1](int(a, 16))
    return subprocess.run(['xcrun', 'c++filt', r], capture_output=True, text=True).stdout.strip()[:70]
per = collections.defaultdict(lambda: [0, 0, collections.Counter()]); selfc = collections.Counter(); incl = collections.Counter(); host = collections.Counter(); waitat = collections.Counter(); n = 0
for i, l in enumerate(lines):
    m = re.match(r'\[dm\] SAMPLE #\d+ \[([\d.]+)s\] thr=(0x[0-9a-f]+) pc=(\S+)', l)
    if not m or not (lo <= float(m.group(1)) <= hi): continue
    h = int(m.group(2), 16); pc = m.group(3); p = per[h]
    bt = lines[i + 1].split('bt:')[1].split() if i + 1 < len(lines) and 'bt:' in lines[i + 1] else []
    if any(pc.startswith(w) for w in WAIT):
        p[1] += 1
        if thr is not None and h == thr:                 # Wait point: the first game function in the backtrace (when it contains an sdk synchronization primitive, look one more level out for a main function)
            fs = [fnof(f) for f in bt if fnof(f)]; mf = next((f for f in fs if f.startswith('main')), None)
            waitat[(fs[0] if fs else '?') + ' ← ' + (mf or '?')] += 1
        continue
    p[0] += 1; frames = [pc] + bt
    first = next((fnof(f) for f in frames if fnof(f)), None)
    p[2][first or '(host) ' + pc.split('+')[0]] += 1
    if thr is None or h != thr: continue
    n += 1
    if not fnof(pc): host[pc.split('+')[0]] += 1
    if first: selfc[first] += 1
    seen = set()
    for f in frames:
        fn = fnof(f)
        if fn and fn not in seen: incl[fn] += 1; seen.add(fn)
if thr is None:
    for h, (run, wait, c) in sorted(per.items(), key=lambda x: -x[1][0]):
        tot = run + wait
        if tot: print(f'{h:#x} samples {tot:5d} running {100 * run / tot:5.1f}%  hotspots: ' + '; '.join(f'{fn} {k}' for fn, k in c.most_common(3)))
    sys.exit(0)
run, wait, _ = per[thr]
print(f'thread {thr:#x} window [{lo}, {hi}]: samples {run + wait}, running {run} ({100 * run / max(1, run + wait):.1f}%)')
print('== self (innermost game function, share of running samples)'); [print(f'{c:4d} {100 * c / max(1, n):5.1f}% {fn} {dm(fn)}') for fn, c in selfc.most_common(12)]
print('== host frames (innermost non-game)'); [print(f'{c:4d} {h}') for h, c in host.most_common(6)]
print('== inclusive (with callees)'); [print(f'{c:4d} {100 * c / max(1, n):5.1f}% {fn} {dm(fn)}') for fn, c in incl.most_common(20)]
print('== wait points (waiting samples: innermost game function ← innermost main function)'); [print(f'{c:4d} {k}') for k, c in waitat.most_common(8)]
