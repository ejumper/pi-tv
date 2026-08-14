#!/bin/sh

YDOTOOL_BIN="/home/tv/pi-tv/tools/ydotool/build/ydotool"
YDOTOOL_SOCKET_PATH="/tmp/ydotoold.socket"
export YDOTOOL_SOCKET="$YDOTOOL_SOCKET_PATH"

"$YDOTOOL_BIN" mousemove --absolute 750 340
"$YDOTOOL_BIN" click 0xC0
sleep 0.1
"$YDOTOOL_BIN" mousemove --absolute 1910 1030
"$YDOTOOL_BIN" click 0xC0
