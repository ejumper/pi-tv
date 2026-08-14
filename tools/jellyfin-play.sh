#!/bin/sh

YDOTOOL_BIN="/home/tv/pi-tv/tools/ydotool/build/ydotool"
YDOTOOL_SOCKET_PATH="/tmp/ydotoold.socket"
export YDOTOOL_SOCKET="$YDOTOOL_SOCKET_PATH"
sleep .05
"$YDOTOOL_BIN" mousemove --absolute 930 220
"$YDOTOOL_BIN" click 0xC0
sleep .05
"$YDOTOOL_BIN" mousemove --absolute 2000 1100
