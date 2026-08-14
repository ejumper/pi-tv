#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="${HOME}/scripts"
SLEEP_UNIT="tv-sleep-timer"

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

cancel_timer() {
  systemctl --user stop "${SLEEP_UNIT}.timer" "${SLEEP_UNIT}.service" >/dev/null 2>&1 || true
}

schedule_timer() {
  local delay="$1"
  cancel_timer
  systemd-run --user --unit="$SLEEP_UNIT" --on-active="$delay" "$SCRIPTS_DIR/tv-toggle.sh" >/dev/null
}

options=(
  "Power off in: 10 minutes"
  "Power off in: 30 minutes"
  "Power off in: 1 hour"
  "Power off in: 2 hours"
  "off"
)

choice=$(printf '%s\n' "${options[@]}" | fuzzel --lines 5 "${FUZZEL_OPTS[@]}")

case "$choice" in
  "Power off in: 10 minutes") schedule_timer "10m" ;;
  "Power off in: 30 minutes") schedule_timer "30m" ;;
  "Power off in: 1 hour") schedule_timer "1h" ;;
  "Power off in: 2 hours") schedule_timer "2h" ;;
  "off") cancel_timer ;;
  *) exit 0 ;;
esac
