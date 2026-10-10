#!/bin/sh
# jellyfin-fav-shuffle.sh — start shuffled favorites music on the TV.
#
# Opens the marked Jellyfin favorites URL in a new TV browser tab; the
# Tampermonkey userscript (jellyfin-fav-shuffle.user.js, installed TV-side)
# clicks the list's Shuffle button and hops the tab to the now-playing
# queue view. Plain Brave tab — fits the kiosk tab model.
#
# Usage: jellyfin-fav-shuffle.sh          (from the TV, or `ssh tv` from desktop)
#
# Note: each run opens a NEW tab and starts a new shuffle; the previous
# tab's playback is not stopped yet (overlaps until that tab is closed).

JF_URL="https://media.halfab.net/web/#/list?serverId=ca51be806e1245acaeb85fb6cc174783&type=Audio&IsFavorite=true&autoshuffle=1"

export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

nohup brave-browser "$JF_URL" >/dev/null 2>&1 < /dev/null &
