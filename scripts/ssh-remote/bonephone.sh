#!/usr/bin/env bash
set -euo pipefail

MAC="B1:30:A3:EF:AE:4A"
MAC_UNDER="${MAC//:/_}"

if bluetoothctl info "$MAC" 2>/dev/null | grep -q "Connected: yes"; then
    bluetoothctl disconnect "$MAC"
    hdmi_sink=$(pactl list sinks short 2>/dev/null | grep -i hdmi | awk '{print $2}' | head -1)
    [ -n "$hdmi_sink" ] && pactl set-default-sink "$hdmi_sink" && echo "Audio → $hdmi_sink"
    exit 0
fi

bluetoothctl connect "$MAC"

for _ in $(seq 1 20); do
    sink=$(pactl list sinks short 2>/dev/null | grep -i "$MAC_UNDER" | awk '{print $2}' | head -1)
    if [ -n "$sink" ]; then
        pactl set-default-sink "$sink"
        echo "Audio → $sink"
        exit 0
    fi
    sleep 0.5
done

echo "Connected but audio sink did not appear"
exit 1
