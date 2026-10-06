#!/usr/bin/env bash
set -euo pipefail

MAC="00:25:D1:4F:C5:B0"   # MAJOR V
NAME="MAJOR V"

# wpctl status sink id for a device, matched on its description (e.g. "80.")
sink_id_by_name() {
    wpctl status | awk -v name="$1" '
        /Sinks:/ {s=1}
        /Sources:|Filters:|Streams:/ {s=0}
        s && index($0, name) {
            for (i=1; i<=NF; i++)
                if ($i ~ /^[0-9]+\.$/) { sub(/\.$/, "", $i); print $i; exit }
        }'
}

if bluetoothctl info "$MAC" 2>/dev/null | grep -q "Connected: yes"; then
    bluetoothctl disconnect "$MAC"
    hdmi=$(sink_id_by_name "HDMI")
    [ -n "$hdmi" ] && wpctl set-default "$hdmi" && echo "Audio → HDMI"
    exit 0
fi

# || true: headphones may be off; the wait loop below reports the failure
bluetoothctl connect "$MAC" || true

for _ in $(seq 1 20); do
    sink=$(sink_id_by_name "$NAME")
    if [ -n "$sink" ]; then
        wpctl set-default "$sink"
        echo "Audio → $NAME"
        exit 0
    fi
    sleep 0.5
done

echo "Connected but audio sink did not appear"
exit 1
