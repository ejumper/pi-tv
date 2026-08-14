#!/usr/bin/env bash
set -euo pipefail

CEC_DEV="/dev/cec1"

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

cec-ctl -d "$CEC_DEV" --playback -t 0 \
  --user-control-pressed ui-cmd=mute \
  --user-control-released
