#!/bin/bash
# Rewrite the game's modules for the host: build_product.sh [output directory] → <output>/<module>.patched.bin plus its tables (tools/patch_nso.py).
# The game is DM_GAME (games/<id>/game.json, default manosaba): the modules come from "modules", the NSO files from workspace.exefs, the rules from
# games/<id>/rules.py when it exists; the output defaults to workspace.product. All workspace paths are relative to DM_ROOT.
# Python: DM_PY (default $DM_ROOT/build/cache/dm/venv/bin/python; needs capstone and lz4). Each module's rewriter output goes to <output>/<module>.patch.log.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); DM=$HERE/..; ROOT=${DM_ROOT:-$HOME/dm-work}
GAME=${DM_GAME:-manosaba}; GJ=$DM/games/$GAME/game.json
[ -f "$GJ" ] || { echo "[red] no game profile $GJ"; exit 2; }
get() { python3 "$HERE/gen_game.py" "$GJ" --get "$1"; }
PY=${DM_PY:-$ROOT/build/cache/dm/venv/bin/python}
EXEFS=$ROOT/$(get workspace.exefs)
OUT=${1:-$ROOT/$(get workspace.product)}
RULES=$DM/games/$GAME/rules.py; [ -f "$RULES" ] || RULES=
mkdir -p "$OUT"
for m in $(get modules); do
  [ -f "$EXEFS/$m" ] || { echo "[red] no module $EXEFS/$m"; exit 2; }
  "$PY" "$HERE/patch_nso.py" "$EXEFS/$m" "$OUT" "$m" ${RULES:+--rules "$RULES"} > "$OUT/$m.patch.log" 2>&1 \
    || { echo "[red] rewriting $m failed, see $OUT/$m.patch.log"; exit 2; }
  tail -1 "$OUT/$m.patch.log"
done
echo "product: $OUT"
