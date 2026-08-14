#!/usr/bin/env bash
set -euo pipefail

CEC_DEV="/dev/cec1"
BRAVE_APP_ID="brave-browser"

detect_cec_dev() {
  local dev state
  for dev in /dev/cec*; do
    [ -e "$dev" ] || continue
    state=$(cec-ctl -d "$dev" --playback -t 0 --give-device-power-status 2>/dev/null \
      | awk '/pwr-state:/ {print $2; exit}')
    if [ -n "$state" ]; then
      printf '%s\n' "$dev"
      return 0
    fi
  done
  if [ -e /dev/cec1 ]; then
    printf '%s\n' /dev/cec1
    return 0
  fi
  if [ -e /dev/cec0 ]; then
    printf '%s\n' /dev/cec0
    return 0
  fi
  return 1
}

CEC_DEV="$(detect_cec_dev || printf '%s' "$CEC_DEV")"

pwr_state=$(cec-ctl -d "$CEC_DEV" --playback -t 0 --give-device-power-status 2>/dev/null \
  | awk '/pwr-state:/ {print $2; exit}')

# Roku: user-control power toggle
cec-ctl -d "$CEC_DEV" --playback -t 0 \
  --user-control-pressed ui-cmd=power \
  --user-control-released

# Direct CEC opcodes for TVs that ignore user-control (e.g. Chrome TV)
if [ "$pwr_state" = "on" ] || [ "$pwr_state" = "in-transition-standby-to-on" ]; then
  cec-ctl -d "$CEC_DEV" --playback -t 0 --standby
else
  cec-ctl -d "$CEC_DEV" --playback -t 0 --image-view-on
fi

count_brave_windows() {
  wlrctl toplevel list | awk -F':' '$1=="'"$BRAVE_APP_ID"'"{count++} END{print count+0}'
}

close_all_brave() {
  local count i
  count=$(count_brave_windows)
  for ((i=0; i<count; i++)); do
    wlrctl toplevel close "app_id:${BRAVE_APP_ID}" >/dev/null 2>&1 || true
    sleep 0.05
  done
}

brave_count=$(count_brave_windows)
if [ "$brave_count" -gt 1 ]; then
  close_all_brave
  brave_count=0
fi

if [ "$brave_count" -eq 0 ]; then
  brave-browser --new-window "about:blank" >/dev/null 2>&1 &
  for _ in {1..20}; do
    if wlrctl toplevel find "app_id:${BRAVE_APP_ID}" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
fi

if wlrctl toplevel find "app_id:${BRAVE_APP_ID}" >/dev/null 2>&1; then
  wlrctl toplevel focus "app_id:${BRAVE_APP_ID}"
  sleep 0.1
  wtype -M ctrl -M alt -M shift -k w -m shift -m alt -m ctrl
  wlrctl toplevel fullscreen "app_id:${BRAVE_APP_ID}"
  sleep 0.2
  wtype -M ctrl -k w
  sleep 0.15
  wtype -M ctrl -k w
  sleep 0.15
  wtype -M ctrl -k w
fi
