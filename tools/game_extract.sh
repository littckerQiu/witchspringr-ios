#!/bin/bash
# Your game package → the workspace's ExeFS and RomFS: builds tools/game_extract (C#, LibHac) into $DM_ROOT/build/tools/game_extract when
# its sources changed, then runs it with the arguments given.
# Usage: game_extract.sh <prod.keys> <out dir> <package>... [--title-keys <title.keys>] [--program <id>]
#   Packages: .nsp / .xci (base game, updates), or the folder of an over-4 GiB file as nxdumptool writes it to the SD card.
#   Out dir, e.g. $DM_ROOT/data/switch/<id>-<version>; it must not exist yet. Then: tools/new_game.py <id> <out dir>/ExeFS <out dir>/RomFS.
# Needs the .NET SDK (brew install dotnet); DM_ROOT defaults to ~/dm-work.
set -euo pipefail
[ $# -ge 3 ] || { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
SRC=$(cd "$(dirname "$0")/game_extract" && pwd)
OUT=${DM_ROOT:-$HOME/dm-work}/build/tools/game_extract
export DOTNET_ROOT=${DOTNET_ROOT:-$(brew --prefix dotnet)/libexec}
if [ ! -f "$OUT/game_extract.dll" ] || [ -n "$(find "$SRC" -maxdepth 1 -newer "$OUT/game_extract.dll" \( -name '*.cs' -o -name '*.csproj' -o -name '*.json' \))" ]; then
  dotnet build -c Release --nologo -v q "$SRC/game_extract.csproj" -o "$OUT" >&2
fi
exec dotnet "$OUT/game_extract.dll" "$@"
