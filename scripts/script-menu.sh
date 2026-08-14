#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="${HOME}/scripts"

FUZZEL_OPTS=(
  --dmenu
  --layer=overlay
  --anchor=center
  --font "Sans:size=36"
  --prompt ""
  --background-color "000000ff"
  --text-color "ffffffff"
  --prompt-color "ffffffff"
  --input-color "ffffffff"
  --selection-color "222222ff"
  --selection-text-color "ffffffff"
  --border-width 0
)

mapfile -t scripts < <(
  find "$SCRIPTS_DIR" -maxdepth 1 -type f ! -name "script-menu.sh" ! -name "*.save" -printf "%f\n" | sort
)

if [ "${#scripts[@]}" -eq 0 ]; then
  exit 0
fi

lines="${#scripts[@]}"
if [ "$lines" -gt 12 ]; then
  lines=12
fi

choice=$(printf '%s\n' "${scripts[@]}" | fuzzel --lines "$lines" "${FUZZEL_OPTS[@]}")

if [ -z "$choice" ]; then
  exit 0
fi

if [ -x "$SCRIPTS_DIR/$choice" ]; then
  exec "$SCRIPTS_DIR/$choice"
fi

exec bash "$SCRIPTS_DIR/$choice"
