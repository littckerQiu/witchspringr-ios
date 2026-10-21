#!/bin/bash
# Standing rewrite-equivalence regression: structural check (structck) + per-site Unicorn equivalence (equiv) + host gate function (gatefn), all modules
# in one command, in seconds.
# Usage: verify/regress.sh [--fresh] [--struct-only] [--fuzz] [build output dir] [module...]
#   The game is DM_GAME (games/<id>/game.json, default manosaba): default dir = workspace.product, default modules = "modules", NSO files from workspace.exefs
#   --struct-only: run only structck + gatefn (no equiv)
#   --fuzz: also run the function-level differential fuzzer (fnfuzz.py, about 20 s per module)
#   --fresh: first regenerate with this worktree's tools/build_product.sh into run/verify/dm/fresh/, verify that, and compare it file by file with the
#            given dir (shows whether the shared build output is stale)
# Environment: DM_ROOT, DM_PY (default $DM_ROOT/build/cache/dm/venv/bin/python), DM_NSO_DIR, SEED, JOBS, LLVM_BIN
# Final summary: per module one STRUCT and one EQUIV (and FNFUZZ) line with denominators and coverage, plus GATEFN; any failure gives exit code 1.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); DM=$HERE/..; ROOT=${DM_ROOT:-$HOME/dm-work}
GAME=${DM_GAME:-manosaba}; GJ=$DM/games/$GAME/game.json
[ -f "$GJ" ] || { echo "[red] no game profile $GJ"; exit 2; }
get() { python3 "$DM/tools/gen_game.py" "$GJ" --get "$1"; }
PY=${DM_PY:-$ROOT/build/cache/dm/venv/bin/python}
NSO_DIR=${DM_NSO_DIR:-$ROOT/$(get workspace.exefs)}
RUN=$ROOT/run/verify/dm
FRESH=0; STRUCT_ONLY=0; FUZZ=0
while [ $# -gt 0 ]; do
  case $1 in --fresh) FRESH=1; shift ;; --struct-only) STRUCT_ONLY=1; shift ;; --fuzz) FUZZ=1; shift ;; *) break ;; esac
done
OUT=${1:-$ROOT/$(get workspace.product)}; [ $# -gt 0 ] && shift
MODS=${*:-$(get modules)}
mkdir -p "$RUN"
TS=$(date +%m%d_%H%M%S)_$$
LOG=$RUN/regress_$TS.log
echo "# regress $TS game=$GAME out=$OUT mods=$MODS fresh=$FRESH struct_only=$STRUCT_ONLY fuzz=$FUZZ seed=${SEED:-1} git=$(git -C "$HERE" rev-parse --short HEAD) uncommitted=$(git -C "$HERE" status --porcelain -- . ../tools | wc -l | tr -d ' ')" | tee "$LOG"

if [ $FRESH = 1 ]; then
  F=$RUN/fresh; rm -rf "$F"; mkdir -p "$F"
  DM_GAME=$GAME DM_ROOT=$ROOT DM_PY=$PY bash "$DM/tools/build_product.sh" "$F" >> "$LOG" 2>&1 || { echo "FAIL build_product" | tee -a "$LOG"; exit 1; }
  for m in $MODS; do
    for e in patched.bin fixups.tsv gates.tsv sites.tsv cuts.tsv obs.tsv params.tsv; do
      if [ ! -e "$OUT/$m.$e" ]; then r=missing; elif cmp -s "$F/$m.$e" "$OUT/$m.$e"; then r=same; else r=different; fi
      echo "FRESH $m.$e vs $OUT: $r" | tee -a "$LOG"
    done
  done
  OUT=$F
fi

rc=0
for m in $MODS; do
  "$PY" "$HERE/structck.py" "$OUT" "$m" "$NSO_DIR/$m" >> "$LOG" 2>&1 || rc=1
  [ $STRUCT_ONLY = 1 ] || "$PY" "$HERE/equiv.py" "$OUT" "$m" "$NSO_DIR/$m" --seed "${SEED:-1}" ${JOBS:+--jobs $JOBS} --tsv "$RUN/eq_${m}_$TS.tsv" >> "$LOG" 2>&1 || rc=1
  [ $FUZZ = 0 ] || "$PY" "$HERE/fnfuzz.py" "$OUT" "$m" "$NSO_DIR/$m" --seed "${SEED:-1}" ${JOBS:+--jobs $JOBS} --tsv "$RUN/fz_${m}_$TS.tsv" >> "$LOG" 2>&1 || rc=1
done
# Gate function regression: build a test bench on the spot from the host's current entry.S and run _dm_gate gate by gate to check the write-back contract
GT=$RUN/gate_test_$TS
if cc -O1 -I "$DM/host" -o "$GT" "$HERE/gatefn/gate_test.c" "$HERE/gatefn/gate_tramp.S" "$DM/host/entry.S" "$DM/host/hstack.S" "$DM/host/hstack.c" >> "$LOG" 2>&1; then   # (entry.S calls through the host stack switch since item 40)
  G=(); for m in $MODS; do [ -s "$OUT/$m.gates.tsv" ] && G+=("$OUT/$m.gates.tsv"); done
  "$GT" "${G[@]}" >> "$LOG" 2>&1 || rc=1; rm -f "$GT"
else echo "FAIL gate test bench did not compile" >> "$LOG"; rc=1; fi
echo "---- summary ($LOG)"
grep -E '^(FRESH|STRUCT|EQUIV|FNFUZZ|GATEFN|FAIL|DIFF|NOEFF|MUTMISS)' "$LOG" | grep -v '^FRESH.*: same$'
[ $rc = 0 ] && echo "REGRESS OK $(basename "$OUT")" || echo "REGRESS FAIL $(basename "$OUT")"
exit $rc
