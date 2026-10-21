# Local device and signing settings (never committed), sourced by the scripts: the first of $DM_LOCAL_ENV, ios/local.env,
# ~/.config/dm-ios/local.env that exists (the last one can be shared by several working trees). See local.env.example.
# local_env_need <variable...>: reports every missing one and returns non-zero.
_le_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for _le_f in "${DM_LOCAL_ENV:-}" "$_le_dir/local.env" "$HOME/.config/dm-ios/local.env"; do
  [ -n "$_le_f" ] && [ -f "$_le_f" ] && { set -a; source "$_le_f"; set +a; DM_LOCAL_ENV_FILE=$_le_f; break; }
done
local_env_need() {
  local v miss=
  for v in "$@"; do [ -n "${!v:-}" ] || miss="$miss $v"; done
  [ -z "$miss" ] || { echo "[red] missing local settings:${miss} (copy ios/local.env.example to ios/local.env and fill it in; read: ${DM_LOCAL_ENV_FILE:-no settings file found})" >&2; return 1; }
}
