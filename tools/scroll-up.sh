#!/bin/sh

YDOTOOL_BIN="/home/tv/pi-tv/tools/ydotool/build/ydotool"
YDOTOOL_SOCKET_PATH="/tmp/ydotoold.socket"

if [ ! -x "$YDOTOOL_BIN" ]; then
  exit 1
fi

export YDOTOOL_SOCKET="$YDOTOOL_SOCKET_PATH"

"$YDOTOOL_BIN" mousemove -w -x 0 -y -1
