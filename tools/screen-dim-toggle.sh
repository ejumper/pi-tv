#!/bin/sh
set -eu

SCRIPT="/home/tv/pi-tv/tools/screen-dim-overlay.py"
TOGGLE_SCRIPT="/home/tv/pi-tv/tools/screen-dim-toggle.sh"
USER_NAME="tv"
USER_UID="1000"

ACTION="${1-}"
case "$ACTION" in
  --on|--off|--toggle) ;;
  "" ) ACTION="--toggle" ;;
  * ) ACTION="--toggle" ;;
esac

if [ "$(id -u)" -eq 0 ]; then
  RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$USER_UID}"
  WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
  export RUNTIME_DIR WAYLAND_DISPLAY
  exec su -s /bin/sh "$USER_NAME" -c "XDG_RUNTIME_DIR=\"$RUNTIME_DIR\" WAYLAND_DISPLAY=\"$WAYLAND_DISPLAY\" \"$TOGGLE_SCRIPT\" \"$ACTION\""
fi

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR WAYLAND_DISPLAY

PID_FILE="$RUNTIME_DIR/screen-dim-overlay.pid"

is_running() {
  [ -f "$PID_FILE" ] || return 1
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null
}

stop_overlay() {
  if is_running; then
    kill "$PID"
  fi
  rm -f "$PID_FILE"
}

start_overlay() {
  if is_running; then
    return 0
  fi
  "$SCRIPT" >/dev/null 2>&1 &
  echo $! > "$PID_FILE"
}

case "$ACTION" in
  --on)
    start_overlay
    ;;
  --off)
    stop_overlay
    ;;
  --toggle)
    if is_running; then
      stop_overlay
    else
      start_overlay
    fi
    ;;
esac
