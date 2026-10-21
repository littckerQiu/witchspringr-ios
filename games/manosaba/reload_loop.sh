#!/bin/bash
# Reload loop for memory tests on the Mac: start from a copy of a save, load its newest autosave from the title screen, then every 40 s open the
# phone menu → Load → Auto tab → slot A1 → confirm. Between loads A is pressed every 3 s, so the story moves on and the next load finds a new
# autosave; --stay leaves the presses out and the same scene is loaded again and again.
# Output in <run dir>: mem.tsv (host memory once a second, DM_MEMSTAT; tools/memstat_cycles.py prints one row per cycle), shots/s<frame>.png
# (59 s and 38 s into every cycle), log.txt.
# Usage: reload_loop.sh [--stay] <run dir> <save dir> <cycles> [host binary] [VAR=value ...]
#   <save dir>  a save directory of the game (the one that holds Saves_v1); it is copied, never written
#   <cycles>    at most 18, 48 with --stay: DM_KEYS takes at most 256 items (host/hle_hid.c KMAX)
#   host binary default host/dmhost (host/dmhost_m3 for the older-API build); copy it elsewhere first if you will rebuild the host meanwhile
#   VAR=value   passed to the host, e.g. DM_HEAP_CENSUS=… or DM_GUEST_ENV="GC_PRINT_STATS=1" DM_DBG=1
# The taps are normalized screen positions in manosaba 2.0.4b: title Load (0.1, 0.9), Auto tab (0.71, 0.94), slot A1 (0.18, 0.22), confirm
# (0.5, 0.5), phone menu (0.955, 0.07) and its Load (0.867, 0.236).
set -u
STAY=0; [ "${1:-}" = --stay ] && { STAY=1; shift; }
[ $# -ge 3 ] || { sed -n '2,13p' "$0"; exit 1; }
REPO=$(cd "$(dirname "$0")/../.." && pwd); W=${DM_ROOT:-$HOME/dm-work}
R=$1; SAVE=$2; CYC=$3; shift 3
BIN=$REPO/host/dmhost
if [ $# -gt 0 ] && [ "${1#*=}" = "$1" ]; then BIN=$1; shift; fi
case "$BIN" in /*) ;; *) BIN=$PWD/$BIN ;; esac
[ -x "$BIN" ] || { echo "no host binary $BIN (make -C host)"; exit 1; }
[ -d "$SAVE/Saves_v1" ] || { echo "$SAVE has no Saves_v1: not a save directory of the game"; exit 1; }
MAXC=$((STAY ? 48 : 18)); [ "$CYC" -ge 1 ] && [ "$CYC" -le $MAXC ] || { echo "cycles: 1 to $MAXC"; exit 1; }
rm -rf "$R"; mkdir -p "$R/save" "$R/temp" "$R/shots"; R=$(cd "$R" && pwd); cp -R "$SAVE/." "$R/save/"
K=$(python3 - "$CYC" "$STAY" <<'PY'
import sys
n, stay = int(sys.argv[1]), sys.argv[2] == '1'
k = ["T0.1:0.9@10+0.1", "T0.71:0.94@12.5+0.1", "T0.18:0.22@14.5+0.1", "T0.5:0.5@16.5+0.1"] + [f"A@{t}+0.1" for t in range(21, 57, 3)]
for c in range(n):
    s = 60 + 40 * c
    k += [f"T0.955:0.07@{s}+0.1", f"T0.867:0.236@{s+2}+0.1", f"T0.71:0.94@{s+4.5}+0.1", f"T0.18:0.22@{s+6.5}+0.1", f"T0.5:0.5@{s+8.5}+0.1"]
    if not stay: k += [f"A@{s+t}+0.1" for t in range(14, 38, 3)]
print(",".join(k))
PY
)
SHOTS=$(python3 -c "print(','.join(['3540'] + [str((60 + 40 * c + 38) * 60) for c in range($CYC)]))")
WATCH=$((60 + 40 * CYC + 5))
echo "run $R: $CYC cycles$([ $STAY = 1 ] && echo ' (--stay)'), ${WATCH} s, $BIN"
cd "$REPO/host" && env DM_ROOT="$W" DM_KEYS="$K" DM_SAVE="$R/save" DM_TEMP="$R/temp" DM_WATCH=$WATCH DM_MEMSTAT="$R/mem.tsv" \
  DM_NVN_SHOT="$SHOTS:$R/shots/s%d.png" "$@" "$BIN" > "$R/log.txt" 2>&1
RC=$?; [ $RC = 142 ] && { echo "done (DM_WATCH ended the run as planned)"; exit 0; }; echo "[red] host exit $RC (see $R/log.txt)"; exit $RC
