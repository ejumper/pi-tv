#!/usr/bin/env bash
set -euo pipefail

# --- CEC helpers -------------------------------------------------------------
# The TV is wired to the Pi's HDMI0 port (/dev/cec0). /dev/cec1 is the second
# HDMI port: the device node always exists but nothing is attached to it, and
# cec-ctl will happily "transmit" to it and report success. It must never win a
# fallback, and it must not be the hardcoded default.
CEC_DEV="${CEC_DEV:-/dev/cec0}"
BRAVE_APP_ID="brave-browser"

cec_phys_addr() {
  cec-ctl -d "$1" -x 2>/dev/null \
    | awk -F': *' '/Physical Address/ { gsub(/ /, "", $2); print $2; exit }'
}

# Usable means the adapter is wired to something the TV assigned an address to.
# f.f.f.f (15.15.15.15) means "no topology / nothing connected".
cec_usable() {
  local pa
  pa="$(cec_phys_addr "$1")"
  [ -n "$pa" ] && [ "$pa" != "f.f.f.f" ] && [ "$pa" != "15.15.15.15" ]
}

detect_cec_dev() {
  local dev
  for dev in /dev/cec0 /dev/cec1; do
    [ -e "$dev" ] || continue
    if cec_usable "$dev"; then
      printf '%s\n' "$dev"
      return 0
    fi
  done
  return 1
}

cec_power_state() {
  cec-ctl -d "$CEC_DEV" --playback -t 0 --give-device-power-status 2>/dev/null \
    | awk '/pwr-state:/ {print $2; exit}'
}

# One read, retried: an empty answer (boot window, bus contention) is not data.
cec_power_state_retry() {
  local i s
  for i in 1 2 3; do
    s="$(cec_power_state)"
    if [ -n "$s" ]; then
      printf '%s\n' "$s"
      return 0
    fi
    sleep 0.5
  done
  return 1
}

CEC_DEV="$(detect_cec_dev || printf '%s' "$CEC_DEV")"

claim_tv_input() {
  local pa
  pa="$(cec_phys_addr "$CEC_DEV")"
  [ -n "$pa" ] || pa="1.0.0.0"
  # <Set Stream Path> is what actually drags the TV off whatever input it is on
  # (the Roku, in this house). <Image View On> alone usually leaves it there.
  cec-ctl -d "$CEC_DEV" --set-stream-path "phys-addr=${pa}" >/dev/null 2>&1 || true
  cec-ctl -d "$CEC_DEV" --active-source "phys-addr=${pa}" >/dev/null 2>&1 || true
}

pwr_state="$(cec_power_state_retry || true)"

if [ "$pwr_state" = "on" ] || [ "$pwr_state" = "in-transition-standby-to-on" ]; then
  cec-ctl -d "$CEC_DEV" --playback -t 0 --standby >/dev/null 2>&1 || true
else
  # Deliberately no user-control power *toggle* here: with the state unknown a
  # toggle flips an already-on TV off. <Image View On> is one-directional.
  cec-ctl -d "$CEC_DEV" --playback -t 0 --image-view-on >/dev/null 2>&1 || true

  # TVs stop answering CEC for a few seconds while the panel boots, so a single
  # unanswered read must not be trusted as "not on".
  on_confirmed=0
  for _ in {1..12}; do
    sleep 2
    if state="$(cec_power_state_retry)" && [ "$state" = "on" ]; then
      on_confirmed=1
      break
    fi
  done

  if [ "$on_confirmed" -ne 1 ]; then
    echo "TV did not report power-on after <Image View On> on ${CEC_DEV}" >&2
  fi

  # Send it twice: many TVs only honour the input change once the panel is up.
  claim_tv_input
  sleep 2
  claim_tv_input
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
