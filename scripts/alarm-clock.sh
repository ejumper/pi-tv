#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="${HOME}/pi-tv/scripts"
ALARM_DIR="${HOME}/.config/alarm-clock"
ALARM_TIME_FILE="${ALARM_DIR}/time"
ALARM_UNIT="alarm-clock"
# The TV is wired to the Pi's HDMI0 port. /dev/cec1 is the second HDMI port:
# its device node always exists but nothing is attached, and cec-ctl reports
# success when transmitting to it, so it must never be the default or a fallback.
CEC_DEV="${CEC_DEV:-/dev/cec0}"
ALARM_SOUND="${HOME}/pi-tv/tools/alarm.m4a"
# Which voice reads the morning announcements, per day (1=Mon .. 7=Sun). Each
# name is a subdir of ~/pi-tv/tools/tts/voices/ holding that voice's rendered
# 1.wav-5.wav. A set only wins when it is complete (at least as many files as
# the default set); an incomplete or unknown voice falls back to the default
# files in tools/tts/ for the whole morning.
TTS_VOICE_MON="emma"
TTS_VOICE_TUE="kirsten"
TTS_VOICE_WED="natalie"
TTS_VOICE_THU="myhala"
TTS_VOICE_FRI="aimee"
TTS_VOICE_SAT="elle"
TTS_VOICE_SUN="keira"
FEED_URL="https://www.democracynow.org/podcast-video.xml"
# Same episode, audio only (~28 MB MP3 against the 264 MB 360p MP4). Used as the
# player page's fallback when the video resolves but cannot start on a bad link,
# and as the weekday primary when the video feed itself is unreachable.
AUDIO_FEED_URL="https://www.democracynow.org/podcast.xml"
INVIDIOUS_BASE_URL="https://tube.halfab.net"
ALTFEED1_PLAYLIST_ID="PL39u5ZEfYDEO5PaNRWyqloGY6zzJ1fjBa"
ALTFEED2_PLAYLIST_ID="PLT5G3DTYh5urqnH5XWfqc_dTJnaddX9jm"
ALTFEED_MIN_LENGTH_SECONDS=2500
ALTFEED_MAX_CANDIDATES=5
CACHE_DIR="${HOME}/.cache/alarm-clock"
PLAYER_HTML="${CACHE_DIR}/player.html"
WEATHER_CACHE_FILE="${CACHE_DIR}/weather"
YDOTOOL_BIN="${HOME}/pi-tv/tools/ydotool/build/ydotool"
YDOTOOL_SOCKET_PATH="/tmp/ydotoold.socket"
# Open-Meteo rather than wttr.in: wttr.in does not send Access-Control-Allow-Origin
# to browsers, so the page could never refresh the weather from a file:// origin
# (only the script's copy worked). Open-Meteo sends ACAO:* and needs no key.
WEATHER_LAT="33.5657"
WEATHER_LON="-97.1801"
WEATHER_URL="https://api.open-meteo.com/v1/forecast?latitude=${WEATHER_LAT}&longitude=${WEATHER_LON}&current=temperature_2m,weather_code&temperature_unit=fahrenheit&timezone=America%2FChicago"
# The page preloads media the moment it opens (the alarm sound is already
# playing by then). ALARM_CLICK1_DELAY_SECONDS later a scripted click gives the
# document user activation for TTS; playback itself is sequenced by the page:
# jingle -> good morning voice -> media.
ALARM_CLICK1_DELAY_SECONDS=3
ALARM_POST_SOUND_DELAY_SECONDS=60
# Media resolution runs in the background while the TV wakes and the alarm sound
# plays, so retries cost nothing the user is standing there waiting for. This is
# the wall-clock budget for the whole ladder (video feed, then audio feed).
ALARM_MEDIA_BUDGET_SECONDS=120
# Feed fetch budgets. Monday's video died on one python socket timeout with a
# stalled mesh link: no timeout survives a dead wifi node, so retries cover that
# case while a generous --max-time keeps a slow-but-alive link transferring.
# Worst case per feed ~49s (4 attempts x 10s connect + 3 x 3s backoff).
FETCH_CONNECT_TIMEOUT_SECONDS=10
FETCH_MAX_TIME_SECONDS=60
FETCH_RETRIES=3
FETCH_RETRY_DELAY_SECONDS=3
# Page-side watchdog: once playback is actually attempted, a video that has
# not started rendering this long is swapped for the same episode's audio-only
# enclosure.
ALARM_MEDIA_FALLBACK_MS=45000
# Weekend equivalent. The embed iframe is inserted the moment the page opens,
# so it has the whole jingle+voice window to load; if it still has no load
# event this long after playback was attempted, the page drops to the
# audio-only stream. A cross-origin embed only exposes one honest signal to
# the parent page - whether the frame finished loading - so a player that
# loads and then stalls remains undetectable (a real limit, not an oversight).
EMBED_LOAD_GRACE_MS=5000
# Set to 1 to run weekend playlists as audio only (the instance still picks the
# video, we take its audio-only stream). Roughly a fortieth of the data, and it
# gains the 1.0-1.7x speed-up that embeds cannot have. Use it when the link or
# the instance cannot carry video.
WEEKEND_AUDIO_ONLY="${WEEKEND_AUDIO_ONLY:-0}"
# Testing knob: pretend to be another day of the week (1=Mon .. 7=Sun) so the
# weekend playlist path can be exercised on any day.
ALARM_DAY_OVERRIDE="${ALARM_DAY_OVERRIDE:-}"
# The timer fires this many seconds EARLY. Inside the window: TV wake, input
# claim, volume baseline, media pick-up and page build; the script then idles
# out the remainder so the alarm sound starts at the exact set time. Tune here
# if the TV speed changes.
ALARM_LEAD_SECONDS=90

# --- Video pre-download ------------------------------------------------------
# A second transient timer fires PREDOWNLOAD_MINUTES before the alarm and
# pulls the weekday video onto the SD card, so morning playback reads from disk
# instead of racing the network. The Democracy Now podcast feed exposes exactly
# ONE video rendition (640x360 h264, ~230MB; every -hd/-720/-1080 variant on
# the CDN 404s, verified 2026-10-08), so that file is the reasonable quality
# choice: it is the same stream that used to play live at 9am. If a better
# feed ever exists, point PREDOWNLOAD_FEED_URL at it. Whenever no fresh
# download is waiting at trigger time, the alarm streams exactly as before.
PREDOWNLOAD_UNIT="alarm-predownload"
PREDOWNLOAD_ENABLED="${PREDOWNLOAD_ENABLED:-1}"
PREDOWNLOAD_MINUTES=30
PREDOWNLOAD_DIR="${CACHE_DIR}/predownload"
PREDOWNLOAD_FILE="${PREDOWNLOAD_DIR}/today.mp4"
PREDOWNLOAD_STATE="${PREDOWNLOAD_DIR}/state.json"
PREDOWNLOAD_FEED_URL="$FEED_URL"
# Feed unchanged (same episode as the last download)? Recheck this often until
# the alarm time; if no new episode ever appears, the alarm streams instead.
PREDOWNLOAD_RECHECK_SECONDS=600
# Per-cycle curl budget: the hard cap is the alarm time itself (see the
# timeout wrapper below); this is the per-attempt ceiling.
PREDOWNLOAD_CONNECT_TIMEOUT_SECONDS=10
PREDOWNLOAD_MAX_TIME_SECONDS=1500
# Abort a transfer crawling under 10KB/s for a full minute: a stalled link
# must not burn the whole budget doing nothing.
PREDOWNLOAD_STALL_SPEED_BYTES=10240
PREDOWNLOAD_STALL_SECONDS=60
# Fresh downloads get curl's internal retries; RESUME attempts deliberately
# get none - curl's retry+resume combination re-truncates the .part on this
# CDN chain (verified 2026-10-08: it ate a 209MB partial), while a single
# ranged continuation lands a clean 206.
PREDOWNLOAD_RETRIES=3
# Never start a download with less runway than this before the alarm.
PREDOWNLOAD_MIN_RUNWAY_SECONDS=300
# Sanity cap on a completed download.
PREDOWNLOAD_MAX_BYTES=$((800 * 1024 * 1024))
WIFI_FALLBACK_SSID="mesh-node"
WIFI_RECONNECT_TIMEOUT_SECONDS=45
WIFI_RECONNECT_POLL_SECONDS=2
VIDEO_READY=0
EMBED_MODE=0
MEDIA_RESOLVE_JSON=""
MEDIA_RESOLVE_PID=""
MEDIA_RESOLVE_FILE="${CACHE_DIR}/media-resolve.json"
MEDIA_RESOLVE_DONE="${CACHE_DIR}/media-resolve.done"

FUZZEL_BASE_OPTS=(
  --dmenu
  --layer=overlay
  --anchor=center
  --font "Sans:size=36"
  --width 12
  --background-color "000000ff"
  --text-color "ffffffff"
  --prompt-color "ffffffff"
  --placeholder-color "ffffffff"
  --input-color "ffffffff"
  --selection-color "222222ff"
  --selection-text-color "ffffffff"
  --border-width 0
)

show_message() {
  local message="$1"
  if command -v timeout >/dev/null 2>&1; then
    printf '%s\n' "$message" | timeout 5s fuzzel --lines 1 --prompt "" "${FUZZEL_BASE_OPTS[@]}" >/dev/null 2>&1 || true
  else
    printf '%s\n' "$message" | fuzzel --lines 1 --prompt "" "${FUZZEL_BASE_OPTS[@]}" >/dev/null 2>&1 || true
  fi
}

show_alarm_set() {
  show_message "Alarm set for $1"
}

cancel_alarm() {
  systemctl --user stop "${ALARM_UNIT}.timer" "${ALARM_UNIT}.service" \
    "${PREDOWNLOAD_UNIT}.timer" "${PREDOWNLOAD_UNIT}.service" >/dev/null 2>&1 || true
  rm -f "$ALARM_TIME_FILE"
}

# Schedule (or replace) one transient daily timer. Each timer owns its
# recovery: the previous OnCalendar is read back before stopping, and a failed
# creation puts it back, so one bad --set can never silently disarm what was
# armed.
schedule_transient_timer() {
  local unit="$1" fire_time="$2"; shift 2
  local previous_calendar="" error transient_timer
  # Read the calendar back from the transient unit file when it exists: it holds
  # the exact string, whereas "systemctl show -p TimersCalendar" pads it with a
  # next_elapse field, and the space inside "*-*-* 13:53:42" is significant.
  transient_timer="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/systemd/transient/${unit}.timer"
  if [ -r "$transient_timer" ]; then
    previous_calendar=$(sed -n 's/^OnCalendar=//p' "$transient_timer" | head -1)
  fi
  if [ -z "$previous_calendar" ]; then
    previous_calendar=$(systemctl --user show "${unit}.timer" -p TimersCalendar --value 2>/dev/null \
      | sed -n 's/.*OnCalendar=\(.*[^[:space:]]\)[[:space:]]*;.*$/\1/p')
  fi

  systemctl --user stop "${unit}.timer" "${unit}.service" >/dev/null 2>&1 || true
  # A FAILED transient unit stays loaded indefinitely and systemd-run then refuses
  # to reuse the name ("already loaded or has a fragment file"), while stopping it
  # is not enough to unload it. Without this, one failed morning jams every later
  # --set: exactly how the alarm got silently stuck disarmed on 2026-08-31.
  systemctl --user reset-failed "${unit}.service" "${unit}.timer" >/dev/null 2>&1 || true

  if ! error=$(systemd-run --user --unit="$unit" \
    --on-calendar="*-*-* ${fire_time}" \
    "$@" 2>&1); then
    echo "could not create ${unit}.timer: ${error}" >&2
    if [ -n "$previous_calendar" ] && systemd-run --user --unit="$unit" \
      --on-calendar="$previous_calendar" \
      "$@" >/dev/null 2>&1; then
      echo "restored the previous ${unit} schedule (${previous_calendar})" >&2
    else
      echo "WARNING: ${unit} is NOT armed" >&2
    fi
    return 1
  fi
}

schedule_alarm() {
  local time="$1"
  local fire_time predownload_time
  # The alarm trigger fires ALARM_LEAD_SECONDS early: TV wake, input claim and
  # the volume baseline run inside that window, and the script then idles until
  # the exact set time to start the alarm sound. A daily calendar spec with
  # seconds handles the midnight wrap for free ("--set 0001" fires 23:59:30).
  fire_time=$(date -d "${time} ${ALARM_LEAD_SECONDS} seconds ago" +%H:%M:%S) || return 1
  # The pre-download timer fires PREDOWNLOAD_MINUTES before the alarm
  # ("--set 0001" pre-downloads at 23:31). If that moment already passed
  # today, the daily calendar simply first fires tomorrow - the alarm's stream
  # fallback covers the skipped morning.
  predownload_time=$(date -d "${time} $((PREDOWNLOAD_MINUTES * 60)) seconds ago" +%H:%M:%S) || return 1

  # Best effort: a missed pre-download only costs bandwidth at trigger time
  # (the alarm streams instead), so it must never block arming the alarm.
  if ! schedule_transient_timer "$PREDOWNLOAD_UNIT" "$predownload_time" \
    "$SCRIPTS_DIR/alarm-clock.sh" --pre-download; then
    echo "continuing without the pre-download timer" >&2
  fi

  # The alarm timer is the one that matters; its helper restores the previous
  # schedule itself when creation fails.
  if ! schedule_transient_timer "$ALARM_UNIT" "$fire_time" \
    "$SCRIPTS_DIR/alarm-clock.sh" --trigger; then
    return 1
  fi

  # Only record the time once the alarm timer really exists, so the file the restore
  # unit reads at login can never claim an alarm that is not scheduled.
  mkdir -p "$ALARM_DIR"
  printf '%s\n' "$time" >"$ALARM_TIME_FILE"
  echo "trigger scheduled for ${fire_time} (${ALARM_LEAD_SECONDS}s before ${time})" >&2
  echo "pre-download scheduled for ${predownload_time} (${PREDOWNLOAD_MINUTES}min before ${time})" >&2
}

parse_time() {
  local raw="$1"
  local digits="${raw//[^0-9]/}"
  if [ "${#digits}" -ne 4 ]; then
    return 1
  fi
  local hh="${digits:0:2}"
  local mm="${digits:2:2}"
  if ((10#$hh > 23 || 10#$mm > 59)); then
    return 1
  fi
  printf '%02d:%02d' "$((10#$hh))" "$((10#$mm))"
}

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

tv_is_on() {
  local state attempt
  for attempt in 1 2 3; do
    state="$(cec_power_state)"
    case "$state" in
      on|to-on) return 0 ;;
      standby|to-standby) return 1 ;;
    esac
    sleep 0.5
  done
  # No usable answer: report OFF so the alarm attempts the power-on. Treating
  # "could not read the state" as "already on" silently skipped waking the TV.
  echo "CEC power status unreadable on ${CEC_DEV}; assuming the TV is off" >&2
  return 1
}

set_volume_baseline() {
  local i
  for i in {1..15}; do
    cec-ctl -d "$CEC_DEV" --playback -t 0 \
      --user-control-pressed ui-cmd=volume-down --user-control-released >/dev/null 2>&1 || true
    sleep 0.1
  done
  for i in {1..10}; do
    cec-ctl -d "$CEC_DEV" --playback -t 0 \
      --user-control-pressed ui-cmd=volume-up --user-control-released >/dev/null 2>&1 || true
    sleep 0.1
  done
}

start_alarm_sound() {
  if [ ! -f "$ALARM_SOUND" ]; then
    echo "alarm sound missing at ${ALARM_SOUND}; there will be no audio alarm" >&2
    return 1
  fi

  # ffplay's stderr used to go to /dev/null, so a silent alarm (audio server not
  # up, device gone) was indistinguishable from success. Report anything that
  # fails on its own; a timeout/stop kill still looks like exit 143 and stays
  # quiet because that is the alarm being dismissed.
  (
    local ff_log="${CACHE_DIR}/sound-error.log"
    rm -f "$ff_log"
    ffplay -nodisp -autoexit -hide_banner -loglevel error "$ALARM_SOUND" >/dev/null 2>"$ff_log"
    local ff_rc=$?
    # ffplay exits 0 even when it could not decode the file at all (verified: a
    # corrupt m4a gives rc=0 with the error only on stderr), so at -loglevel error
    # any stderr output at all is the signal. The success line is here because
    # "did the alarm actually sound this morning?" was previously unanswerable.
    if [ -s "$ff_log" ]; then
      echo "alarm sound problem (exit ${ff_rc}): $(head -c 200 "$ff_log" | tr '\n' ' ')" >&2
    else
      echo "alarm sound finished (exit ${ff_rc})" >&2
    fi
    rm -f "$ff_log"
  ) &
  echo $!
}

wifi_connected() {
  local ssid
  ssid=$(iwgetid -r 2>/dev/null || true)
  if [ -n "$ssid" ]; then
    return 0
  fi

  if ! command -v nmcli >/dev/null 2>&1; then
    return 1
  fi

  nmcli -t -f TYPE,STATE device status 2>/dev/null \
    | awk -F: '$1 == "wifi" && $2 == "connected" { found = 1 } END { exit found ? 0 : 1 }'
}

wait_for_wifi() {
  local timeout="${1:-$WIFI_RECONNECT_TIMEOUT_SECONDS}"
  local deadline=$((SECONDS + timeout))

  while [ "$SECONDS" -lt "$deadline" ]; do
    if wifi_connected; then
      return 0
    fi
    sleep "$WIFI_RECONNECT_POLL_SECONDS"
  done

  wifi_connected
}

last_used_wifi_connection() {
  nmcli -t -f NAME,TYPE,TIMESTAMP connection show 2>/dev/null \
    | awk -F: '
        $2 == "802-11-wireless" {
          timestamp = $3 + 0
          if (timestamp > best_timestamp) {
            best_timestamp = timestamp
            best_name = $1
          }
        }
        END {
          if (best_name != "") {
            print best_name
          }
        }
      '
}

wifi_connection_for_ssid() {
  local target_ssid="$1"
  local name type ssid

  while IFS=: read -r name type; do
    [ "$type" = "802-11-wireless" ] || continue
    if [ "$name" = "$target_ssid" ]; then
      printf '%s\n' "$name"
      return 0
    fi

    ssid=$(nmcli -g 802-11-wireless.ssid connection show "$name" 2>/dev/null || true)
    if [ "$ssid" = "$target_ssid" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)
}

ensure_wifi_connected() {
  local connection fallback_connection

  if wifi_connected; then
    return 0
  fi

  if ! command -v nmcli >/dev/null 2>&1; then
    echo "Wi-Fi appears disconnected and nmcli is unavailable." >&2
    return 1
  fi

  echo "Wi-Fi appears disconnected; attempting reconnect." >&2
  rfkill unblock wifi >/dev/null 2>&1 || true
  nmcli radio wifi on >/dev/null 2>&1 || true

  connection=$(last_used_wifi_connection || true)
  if [ -n "$connection" ]; then
    nmcli connection up "$connection" >/dev/null 2>&1 || true
    if wait_for_wifi 20; then
      return 0
    fi
  fi

  fallback_connection=$(wifi_connection_for_ssid "$WIFI_FALLBACK_SSID" || true)
  if [ -n "$fallback_connection" ] && [ "$fallback_connection" != "$connection" ]; then
    nmcli connection up "$fallback_connection" >/dev/null 2>&1 || true
    if wait_for_wifi 20; then
      return 0
    fi
  fi

  nmcli device wifi rescan >/dev/null 2>&1 || true
  nmcli device wifi connect "$WIFI_FALLBACK_SSID" >/dev/null 2>&1 || true
  if wait_for_wifi 15; then
    return 0
  fi

  echo "Wi-Fi reconnect did not complete; continuing alarm startup." >&2
  return 1
}

# One place for network policy: a short connect budget so a dead link fails
# fast, a long total transfer budget so a slow link still finishes, and retries
# because a wifi node that is down needs waiting, not a longer single attempt.
# (--retry-all-errors needs curl >= 7.71; the Pi has 8.14.)
fetch_url() {
  local url="${1:-}"
  [ -n "$url" ] || return 1
  curl -fsSL \
    --connect-timeout "$FETCH_CONNECT_TIMEOUT_SECONDS" \
    --max-time "$FETCH_MAX_TIME_SECONDS" \
    --retry "$FETCH_RETRIES" \
    --retry-delay "$FETCH_RETRY_DELAY_SECONDS" \
    --retry-all-errors \
    -A alarm-clock \
    "$url"
}

# curl owns the network, python only parses. The feed is kept on disk afterwards
# because "why is there no video" is much easier to answer with the last fetched
# feed available to look at.
fetch_media_from_rss() {
  local feed_url="${1:-}"
  local feed_xml
  [ -n "$feed_url" ] || return 1

  mkdir -p "$CACHE_DIR"
  feed_xml="${CACHE_DIR}/feed-latest.xml"
  if ! fetch_url "$feed_url" >"$feed_xml"; then
    echo "rss: fetch failed for ${feed_url}" >&2
    return 1
  fi

  python3 - "$feed_xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
import json

try:
    with open(sys.argv[1], "rb") as handle:
        root = ET.fromstring(handle.read())
except (OSError, ET.ParseError) as err:
    print(f"rss: could not parse feed: {err}", file=sys.stderr)
    sys.exit(1)

# Find channel-level image for podcasts
channel_image = ""
for img in root.findall(".//{http://www.itunes.com/dtds/podcast-1.0.dtd}image"):
    href = img.get("href")
    if href:
        channel_image = href
        break
if not channel_image:
    for img in root.findall(".//channel/image/url"):
        if img.text:
            channel_image = img.text
            break

# Find first item with enclosure
for item in root.findall(".//item"):
    enc = item.find("enclosure")
    if enc is None or not enc.get("url"):
        continue

    media_url = enc.get("url")
    media_type = enc.get("type", "")

    # Detect if audio or video
    is_audio = media_type.startswith("audio/")

    # Try to find item-specific image
    item_image = ""
    for img in item.findall("{http://www.itunes.com/dtds/podcast-1.0.dtd}image"):
        href = img.get("href")
        if href:
            item_image = href
            break

    # Use item image if available, else channel image
    thumbnail = item_image if item_image else channel_image

    # Output as JSON: media_url|is_audio|thumbnail
    result = {
        "url": media_url,
        "is_audio": is_audio,
        "thumbnail": thumbnail
    }
    print(json.dumps(result))
    break
PY
}

# Resolves a playlist video to an Invidious video id and hands the id to the
# player page, which embeds Invidious' own watch page. The embed resolves its own
# streams, so this no longer depends on formatStreams/adaptiveFormats — YouTube
# removed formatStreams entirely on 2026-08-30, which had silently killed the
# old stream-extraction approach. Candidate scanning is capped so a broken or
# slow instance can't stall the alarm, and every failure reports on stderr.
fetch_media_from_invidious_playlist() {
  local playlist_id="${1:-}"
  local min_length_seconds="${2:-0}"
  python3 - "$INVIDIOUS_BASE_URL" "$playlist_id" "$min_length_seconds" "$ALTFEED_MAX_CANDIDATES" <<'PY'
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

base_url = sys.argv[1].rstrip("/")
playlist_id = sys.argv[2]
min_length_seconds = int(sys.argv[3])
max_candidates = int(sys.argv[4])

if not base_url or not playlist_id:
    print("invidious: missing base url or playlist id", file=sys.stderr)
    sys.exit(1)

headers = {"User-Agent": "alarm-clock"}

def log(message):
    print(f"invidious[{playlist_id[:10]}]: {message}", file=sys.stderr)

def fetch_json(url):
    # Retry here as well as in curl: this resolver makes several calls per run
    # and one stalled response should skip a candidate, not end the alarm.
    last_error = None
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode("utf-8", "replace"))
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as err:
            last_error = err
            if attempt < 3:
                time.sleep(3)
    raise RuntimeError(f"{url}: {last_error}")

def fix_instance_url(url):
    # The instance advertises its own URLs on the internal :3000, which nothing
    # outside that host can reach (a thumbnail fetched from it just fails). Put
    # them back on the public origin we actually talked to.
    if not url:
        return ""
    try:
        parts = urllib.parse.urlsplit(url)
        if parts.port == 3000 and parts.hostname:
            return urllib.parse.urlunsplit(parts._replace(netloc=parts.hostname))
    except ValueError:
        pass
    return url


def best_audio_url(details):
    # adaptiveFormats survives; formatStreams did not (YouTube removed them on
    # 2026-08-30), and the surviving entries are split, so audio-only is the one
    # thing we can hand straight to an <audio> element. Prefer AAC/m4a, then Opus.
    # local=true is deliberately NOT used: it rewrites these URLs onto the
    # instance's internal :3000, which nothing outside that host can reach.
    order = {"140": 0, "251": 1, "139": 2, "171": 3}
    candidates = [
        f for f in (details.get("adaptiveFormats") or [])
        if str(f.get("itag")) in order and f.get("url")
    ]
    if not candidates:
        return ""
    candidates.sort(key=lambda f: (order[str(f.get("itag"))], -int(f.get("bitrate") or 0)))
    return candidates[0]["url"]


def best_thumbnail(video):
    thumbs = video.get("videoThumbnails") or []
    if not thumbs:
        return ""
    return max(
        thumbs,
        key=lambda t: int(t.get("width") or 0) * int(t.get("height") or 0),
    ).get("url", "")

playlist_url = f"{base_url}/api/v1/playlists/{urllib.parse.quote(playlist_id, safe='')}"
try:
    playlist = fetch_json(playlist_url)
except (urllib.error.URLError, TimeoutError, ValueError, OSError, RuntimeError) as err:
    log(f"playlist fetch FAILED: {err}")
    sys.exit(1)

videos = playlist.get("videos") or []
long_enough = 0

for video in videos:
    try:
        length_seconds = int(video.get("lengthSeconds") or 0)
    except (TypeError, ValueError):
        length_seconds = 0
    if length_seconds <= min_length_seconds:
        continue

    video_id = video.get("videoId")
    if not video_id:
        continue

    long_enough += 1
    if long_enough > max_candidates:
        log(f"gave up after {max_candidates} candidates ({len(videos)} videos in playlist)")
        break

    video_url = f"{base_url}/api/v1/videos/{urllib.parse.quote(video_id, safe='')}"
    try:
        details = fetch_json(video_url)
    except (urllib.error.URLError, TimeoutError, ValueError, OSError, RuntimeError) as err:
        log(f"detail fetch failed for {video_id}, skipping: {err}")
        continue

    if details.get("liveNow") or details.get("isUpcoming"):
        log(f"skipping {video_id}: live or upcoming")
        continue

    thumbnail = fix_instance_url(best_thumbnail(details) or best_thumbnail(video))
    audio_url = best_audio_url(details)
    log(f"selected {video_id} (audio-only fallback {'found' if audio_url else 'NOT found'})")
    print(json.dumps({
        "url": "",
        "embed_id": video_id,
        "is_audio": False,
        "thumbnail": thumbnail,
        "audio_url": audio_url,
    }))
    break
else:
    log(f"no usable video: {len(videos)} videos, {long_enough} over {min_length_seconds}s")
    sys.exit(1)
PY
}

fetch_weather() {
  local weather_json="${CACHE_DIR}/weather-latest.json"
  local text=""
  # Weather is cosmetic: tight budget, one retry, and the cache as a net. It must
  # never delay the player page opening. curl writes straight to a file because a
  # heredoc program owns python's stdin.
  mkdir -p "$CACHE_DIR"
  if curl -fsS --connect-timeout 5 --max-time 10 --retry 1 --retry-delay 1 \
    -A alarm-clock -o "$weather_json" "$WEATHER_URL" 2>/dev/null; then
    text=$(python3 - "$weather_json" <<'PY'
import json
import sys

# WMO weather interpretation codes, same wording as the page's table so the
# baked-in value and a later in-page refresh look identical.
CONDITIONS = {
    0: "Clear", 1: "Mainly clear", 2: "Partly cloudy", 3: "Overcast",
    45: "Fog", 48: "Fog", 51: "Drizzle", 53: "Drizzle", 55: "Drizzle",
    56: "Freezing drizzle", 57: "Freezing drizzle", 61: "Rain", 63: "Rain",
    65: "Heavy rain", 66: "Freezing rain", 67: "Freezing rain", 71: "Snow",
    73: "Snow", 75: "Heavy snow", 77: "Snow grains", 80: "Rain showers",
    81: "Rain showers", 82: "Heavy showers", 85: "Snow showers",
    86: "Snow showers", 95: "Thunderstorm", 96: "Thunderstorm",
    99: "Thunderstorm",
}

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        current = json.load(handle).get("current") or {}
    degrees = float(current["temperature_2m"])
except Exception:
    raise SystemExit(1)

print(f"{round(degrees)}\u00b0F {CONDITIONS.get(current.get('weather_code'), 'Unknown')}")
PY
    )
  fi
  if [ -n "$text" ]; then
    mkdir -p "$CACHE_DIR"
    printf '%s\n' "$text" >"$WEATHER_CACHE_FILE"
  elif [ -r "$WEATHER_CACHE_FILE" ]; then
    text=$(head -c 120 "$WEATHER_CACHE_FILE" | tr -d '\r\n')
  fi
  printf '%s\n' "${text:-Weather unavailable}"
}

# Pre-download today's weekday video so the alarm plays from disk instead of
# racing the network. Runs from its own transient timer
# (PREDOWNLOAD_MINUTES before the alarm). The rules:
#   - yesterday's file is deleted BEFORE anything is attempted: only one
#     download is ever kept, and a broken download must not leave a rerun
#     behind that could pass for today's episode;
#   - "same episode as the last one downloaded" is detected by comparing the
#     feed's enclosure URL against the state file and rechecked every
#     PREDOWNLOAD_RECHECK_SECONDS until the alarm; if no new episode ever
#     appears, this gives up and the alarm streams instead;
#   - downloads land in a .part file and are renamed into place only when
#     complete, so the resolver can trust any file it finds;
#   - the state file records which alarm date a download was FOR, which is
#     what the resolver checks at trigger time (a midnight alarm downloads
#     the evening before, and the dates still line up).
run_pre_download() {
  local day_of_week alarm_time alarm_epoch deadline last_url url thumb size media_json

  if [ "$PREDOWNLOAD_ENABLED" != "1" ]; then
    echo "pre-download: disabled (PREDOWNLOAD_ENABLED=0)" >&2
    return 0
  fi

  day_of_week="${ALARM_DAY_OVERRIDE:-$(date +%u)}"
  if [ "$day_of_week" -eq 6 ] || [ "$day_of_week" -eq 7 ]; then
    echo "pre-download: weekend; the Invidious embed path cannot be pre-downloaded" >&2
    return 0
  fi

  if [ ! -r "$ALARM_TIME_FILE" ]; then
    echo "pre-download: no alarm time file; cannot compute the deadline" >&2
    return 1
  fi
  alarm_time=$(cat "$ALARM_TIME_FILE" 2>/dev/null || true)
  if ! alarm_time=$(parse_time "$alarm_time"); then
    echo "pre-download: invalid alarm time '${alarm_time}'; not downloading" >&2
    return 1
  fi

  alarm_epoch=$(date -d "today ${alarm_time}" +%s)
  if [ "$alarm_epoch" -le "$(date +%s)" ]; then
    # Midnight wrap: a 00:15 alarm pre-downloads at 23:45 the evening before.
    alarm_epoch=$(date -d "tomorrow ${alarm_time}" +%s)
  fi
  deadline="$alarm_epoch"

  mkdir -p "$PREDOWNLOAD_DIR"

  # Today's video is already on disk for this exact alarm (e.g. a manual rerun
  # of this mode): keep it, deleting it would only cost a re-download.
  if [ -s "$PREDOWNLOAD_FILE" ] \
    && [ "$(json_field "$(cat "$PREDOWNLOAD_STATE" 2>/dev/null || true)" alarm_date)" = "$(date -d "@${alarm_epoch}" +%F)" ]; then
    echo "pre-download: this alarm's video is already on disk" >&2
    return 0
  fi

  # Yesterday's bytes go NOW, before any network work: even a dead morning
  # must not leave a stale episode the alarm could mistake for fresh.
  rm -f "$PREDOWNLOAD_FILE" "$PREDOWNLOAD_DIR"/*.part

  last_url=$(json_field "$(cat "$PREDOWNLOAD_STATE" 2>/dev/null || true)" url)
  while [ "$(date +%s)" -lt "$deadline" ]; do
    media_json=$(fetch_media_from_rss "$PREDOWNLOAD_FEED_URL" || true)
    url=$(json_field "$media_json" url)
    if [ -z "$url" ] || [ "$(json_field "$media_json" is_audio false)" = "true" ]; then
      echo "pre-download: feed unusable this cycle; recheck in ${PREDOWNLOAD_RECHECK_SECONDS}s" >&2
    elif [ "$url" = "$last_url" ]; then
      echo "pre-download: feed still shows the episode already downloaded; recheck in ${PREDOWNLOAD_RECHECK_SECONDS}s" >&2
    else
      if [ "$((deadline - $(date +%s)))" -lt "$PREDOWNLOAD_MIN_RUNWAY_SECONDS" ]; then
        echo "pre-download: a new episode appeared but it is too close to the alarm; giving up (the alarm will stream)" >&2
        break
      fi
      thumb=$(json_field "$media_json" thumbnail)
      # The .part name carries a hash of the URL, so a resume can never glue
      # together bytes of two different episodes if the feed changes mid-window.
      url_hash=$(printf '%s' "$url" | md5sum | cut -c1-8)
      part_file="${PREDOWNLOAD_DIR}/today.${url_hash}.part"
      echo "pre-download: new episode, downloading $(basename "$url")" >&2
      local range_args=() retries="$PREDOWNLOAD_RETRIES"
      if [ -s "$part_file" ]; then
        # Ranged continuation of the previous attempt's bytes. No internal
        # retries here (see the knobs comment); a failed resume keeps the
        # .part for the next cycle. A 33 means the server ignored the range:
        # the partial is worthless, drop it.
        range_args=(-C -)
        retries=0
        echo "pre-download: resuming from $(stat -c %s "$part_file") bytes" >&2
      fi
      # Bounded by the deadline (plus a minute of grace): a late attempt must
      # not still be pulling bytes while the alarm is trying to stream or play.
      local attempt_budget=$((deadline - $(date +%s) + 60))
      local rc=0
      timeout --kill-after=10 "$attempt_budget" curl -fsSL \
        --connect-timeout "$PREDOWNLOAD_CONNECT_TIMEOUT_SECONDS" \
        --max-time "$PREDOWNLOAD_MAX_TIME_SECONDS" \
        --speed-limit "$PREDOWNLOAD_STALL_SPEED_BYTES" \
        --speed-time "$PREDOWNLOAD_STALL_SECONDS" \
        --retry "$retries" \
        --retry-delay 5 \
        --retry-all-errors \
        "${range_args[@]}" \
        -A alarm-clock \
        -o "$part_file" "$url" || rc=$?
      if [ "$rc" -eq 0 ]; then
        size=$(stat -c %s "$part_file" 2>/dev/null || echo 0)
        if [ "$size" -gt 0 ] && [ "$size" -le "$PREDOWNLOAD_MAX_BYTES" ]; then
          mv -f "$part_file" "$PREDOWNLOAD_FILE"
          python3 - "$url" "$thumb" "$(date -d "@${alarm_epoch}" +%F)" >"$PREDOWNLOAD_STATE" <<'PY'
import json
import sys

print(json.dumps({"url": sys.argv[1], "thumbnail": sys.argv[2], "alarm_date": sys.argv[3]}))
PY
          echo "pre-download: complete ($((size / 1024 / 1024))MB) for the $(date -d "@${alarm_epoch}" +%F) alarm" >&2
          return 0
        fi
        echo "pre-download: downloaded file failed the size check ($size bytes); removing" >&2
        rm -f "$part_file"
      elif [ "$rc" -eq 33 ]; then
        echo "pre-download: server ignored the resume range; discarding the partial" >&2
        rm -f "$part_file"
      else
        echo "pre-download: download attempt failed (rc=${rc}); the partial is kept for the next cycle in ${PREDOWNLOAD_RECHECK_SECONDS}s" >&2
      fi
    fi
    sleep "$PREDOWNLOAD_RECHECK_SECONDS"
  done

  echo "pre-download: no new episode before the alarm; the alarm will stream" >&2
  return 0
}

# resolve_media_json prints one JSON object describing this morning's media:
#   {url, embed_id, is_audio, thumbnail, audio_fallback_url, source}
# It is also a standalone mode ("--resolve-media") so run_alarm can run it in the
# background under a wall-clock budget, and so it can be tested on its own.
# Weekday ladder: video feed -> audio-only feed (same episode, ~9x less data).
# Exits non-zero when nothing usable was found, but still prints the JSON so the
# caller can tell "nothing" apart from "crashed".
resolve_media_json() {
  local day_of_week media_json="" audio_json="" source=""

  day_of_week="${ALARM_DAY_OVERRIDE:-$(date +%u)}"

  if [ "$day_of_week" -eq 6 ] && [ -n "$ALTFEED1_PLAYLIST_ID" ]; then
    source="altfeed1 (${ALTFEED1_PLAYLIST_ID:0:12})"
    media_json=$(fetch_media_from_invidious_playlist "$ALTFEED1_PLAYLIST_ID" "$ALTFEED_MIN_LENGTH_SECONDS" || true)
  elif [ "$day_of_week" -eq 7 ] && [ -n "$ALTFEED2_PLAYLIST_ID" ]; then
    source="altfeed2 (${ALTFEED2_PLAYLIST_ID:0:12})"
    media_json=$(fetch_media_from_invidious_playlist "$ALTFEED2_PLAYLIST_ID" "$ALTFEED_MIN_LENGTH_SECONDS" || true)
  else
    # A fresh pre-downloaded file beats any streaming: zero trigger-time
    # network dependence for the video itself. Valid means it was downloaded
    # FOR this morning's alarm (the state file says which alarm date a
    # download was for), so a missed pre-download day can never serve a rerun
    # from disk. The url is relative to the player page's directory, which
    # keeps a 230MB copy out of the cache dir.
    local pd_state="" pd_date=""
    pd_state=$(cat "$PREDOWNLOAD_STATE" 2>/dev/null || true)
    pd_date=$(json_field "$pd_state" alarm_date)
    if [ -s "$PREDOWNLOAD_FILE" ] && [ "$pd_date" = "$(date +%F)" ]; then
      source="pre-downloaded file ($(json_field "$pd_state" url))"
      media_json=$(printf '{"url":"predownload/%s","is_audio":false,"thumbnail":%s}' \
        "$(basename "$PREDOWNLOAD_FILE")" \
        "$(printf '%s' "$(json_field "$pd_state" thumbnail)" | python3 -c 'import sys, json; sys.stdout.write(json.dumps(sys.stdin.read()))')")
    else
      source="$FEED_URL"
      media_json=$(fetch_media_from_rss "$FEED_URL" || true)
    fi
    # Small and cheap, so fetch it either way: the player page uses it to drop a
    # video that never starts (dead or very slow link) to audio only.
    audio_json=$(fetch_media_from_rss "$AUDIO_FEED_URL" || true)
    if [ -z "$media_json" ] && [ -n "$audio_json" ]; then
      echo "rss: video feed unusable; falling back to the audio-only feed" >&2
      media_json="$audio_json"
      audio_json=""
    fi
  fi

  python3 - "$media_json" "$audio_json" "$source" "$WEEKEND_AUDIO_ONLY" <<'PY'
import json
import sys

def load(raw):
    try:
        return json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        return {}

media = load(sys.argv[1])
audio = load(sys.argv[2])
weekend_audio_only = sys.argv[4] == "1"

url = media.get("url", "")
embed_id = media.get("embed_id", "")
is_audio = bool(media.get("is_audio", False))
fallback = ""

if embed_id:
    # The embed is the only way to get weekend video with sound (no muxed format
    # survived the 2026-08-30 change), but its audio-only stream is a way out if
    # the frame never loads - or the whole plan, with WEEKEND_AUDIO_ONLY=1.
    fallback = media.get("audio_url", "")
    if weekend_audio_only and fallback:
        url, embed_id, is_audio, fallback = fallback, "", True, ""
else:
    # Direct stream: is_audio already came from the enclosure MIME type, and only
    # a video stream has something to downgrade from.
    fallback = "" if is_audio else audio.get("url", "")

result = {
    "url": url,
    "embed_id": embed_id,
    "is_audio": is_audio,
    "thumbnail": media.get("thumbnail", ""),
    "audio_fallback_url": fallback,
    "source": sys.argv[3],
}
print(json.dumps(result))
sys.exit(0 if result["url"] or result["embed_id"] else 1)
PY
}

# Starts the resolver in the background. The script re-invokes itself under
# `timeout` so one budget bounds the whole ladder and nothing can outlive the
# alarm (timeout kills the process group, curl included). stdout lands in a file
# the alarm reads back; stderr keeps going to the journal.
start_media_resolution() {
  mkdir -p "$CACHE_DIR"
  rm -f "$MEDIA_RESOLVE_FILE" "$MEDIA_RESOLVE_DONE"
  (
    set +e
    timeout --kill-after=10 "$ALARM_MEDIA_BUDGET_SECONDS" \
      "$SCRIPTS_DIR/alarm-clock.sh" --resolve-media >"$MEDIA_RESOLVE_FILE"
    printf '%s\n' "$?" >"$MEDIA_RESOLVE_DONE"
  ) &
  MEDIA_RESOLVE_PID=$!
}

# Blocks until the background resolver reports, up to `limit` seconds (default:
# its own budget plus slack). Returns non-zero when nothing was resolved; the
# caller then still opens the page, which runs the clock and the interval
# announcements without media.
wait_for_media_resolution() {
  local waited=0
  local limit="${1:-$((ALARM_MEDIA_BUDGET_SECONDS + 20))}"
  MEDIA_RESOLVE_JSON=""

  if [ -z "$MEDIA_RESOLVE_PID" ]; then
    echo "media resolution was never started" >&2
    return 1
  fi

  while [ ! -e "$MEDIA_RESOLVE_DONE" ] && [ "$waited" -lt "$limit" ]; do
    sleep 2
    waited=$((waited + 2))
  done

  if [ ! -e "$MEDIA_RESOLVE_DONE" ]; then
    echo "media resolution did not report within ${limit}s; running without media" >&2
    kill -9 "$MEDIA_RESOLVE_PID" 2>/dev/null || true
    return 1
  fi

  wait "$MEDIA_RESOLVE_PID" 2>/dev/null || true
  if [ ! -s "$MEDIA_RESOLVE_FILE" ]; then
    echo "media resolution produced no result" >&2
    return 1
  fi
  MEDIA_RESOLVE_JSON=$(cat "$MEDIA_RESOLVE_FILE")
  return 0
}

json_field() {
  local json="${1:-}" key="${2:-}" default="${3:-}"
  printf '%s' "$json" | python3 -c '
import json
import sys

key, default = sys.argv[1], sys.argv[2]
try:
    value = json.load(sys.stdin).get(key)
except Exception:
    sys.stdout.write(default)
    raise SystemExit(0)
if value is None or value == "":
    sys.stdout.write(default)
elif isinstance(value, bool):
    sys.stdout.write("true" if value else "false")
else:
    sys.stdout.write(str(value))
' "$key" "$default" 2>/dev/null
}

js_string() {
  printf '%s' "${1:-}" | python3 -c "import sys, json; sys.stdout.write(json.dumps(sys.stdin.read()))"
}

# Builds the player page from whatever the resolver produced. This always
# succeeds: with no media at all the page still runs the clock, the interval
# countdown and the TTS announcements, which is the part of the alarm that
# matters most when the network is down.
prepare_player_page() {
  local media_json="${MEDIA_RESOLVE_JSON:-}"
  local media_url embed_id is_audio thumbnail audio_fallback_url feed_label
  local media_url_js embed_id_js thumbnail_js audio_fallback_url_js weather_url_js
  VIDEO_READY=0
  EMBED_MODE=0

  # The page sequences sound -> voice -> media, so it needs the alarm sound's
  # real duration, and the scripted clicks need the first voice's. Measured off
  # the files at build time (27.3s + 2.4s on 2026-10-08) with static fallbacks
  # in case ffprobe or a file goes missing.
  local jingle_s tts0_s tts0_file jingle_delay_ms
  jingle_s=3
  if [ -r "$ALARM_SOUND" ]; then
    jingle_s=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$ALARM_SOUND" 2>/dev/null || echo 3)
  fi
  # Which voice reads this morning: the per-day variable picks a subdir of
  # tools/tts/voices/, and it wins only when it holds a complete set (at least
  # as many files as the default) - otherwise the default files read the whole
  # morning. Half a morning in one voice and half in another would be worse
  # than all of it in the default.
  local day_of_week tts_dir voice_name="" voice_count=0 default_count=0
  day_of_week="${ALARM_DAY_OVERRIDE:-$(date +%u)}"
  case "$day_of_week" in
    1) voice_name="$TTS_VOICE_MON" ;;
    2) voice_name="$TTS_VOICE_TUE" ;;
    3) voice_name="$TTS_VOICE_WED" ;;
    4) voice_name="$TTS_VOICE_THU" ;;
    5) voice_name="$TTS_VOICE_FRI" ;;
    6) voice_name="$TTS_VOICE_SAT" ;;
    7) voice_name="$TTS_VOICE_SUN" ;;
  esac
  tts_dir="${HOME}/pi-tv/tools/tts"
  default_count=$(find "$tts_dir" -maxdepth 1 -name '*.wav' -type f 2>/dev/null | wc -l)
  if [ -n "$voice_name" ] && [ -d "${tts_dir}/voices/${voice_name}" ]; then
    voice_count=$(find "${tts_dir}/voices/${voice_name}" -maxdepth 1 -name '*.wav' -type f 2>/dev/null | wc -l)
  fi
  if [ "$voice_count" -gt 0 ] && [ "$voice_count" -ge "$default_count" ]; then
    tts_dir="${tts_dir}/voices/${voice_name}"
    echo "announcements voice: ${voice_name}" >&2
  else
    echo "announcements voice: default ('${voice_name}' missing or incomplete)" >&2
  fi
  tts0_s=0
  tts0_file=""
  if [ -d "$tts_dir" ]; then
    tts0_file=$(find "$tts_dir" -maxdepth 1 -type f -printf "%f\n" | sort -V | head -1)
  fi
  if [ -n "$tts0_file" ] && [ -r "${tts_dir}/${tts0_file}" ]; then
    tts0_s=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "${tts_dir}/${tts0_file}" 2>/dev/null || echo 0)
  fi
  # The page loads ~1.5s after the sound starts (brave tab spin-up), so the
  # good morning voice fires jingle_len - 1.5s after the page appears: close
  # enough to the true end of the jingle that they never meaningfully overlap,
  # and never before it. The clamp keeps a missing/odd probe from firing the
  # voice instantly.
  jingle_delay_ms=$(awk -v j="$jingle_s" 'BEGIN { d = int(j * 1000) - 1500; if (d < 3000) d = 3000; print d }')
  # Click 2 (embed only) lands just after the voice should end, measured from
  # the clicks subshell starting (~1s after page open): jingle + voice + 1.5s.
  CLICK2_DELAY_SECONDS=$(awk -v j="$jingle_s" -v t="$tts0_s" 'BEGIN { d = int(j + t + 1.5); if (d < 6) d = 6; print d }')
  echo "page timing: jingle ${jingle_s}s, first voice ${tts0_s}s, click1 at ${ALARM_CLICK1_DELAY_SECONDS}s, click2 at ${CLICK2_DELAY_SECONDS}s" >&2

  media_url=$(json_field "$media_json" url)
  embed_id=$(json_field "$media_json" embed_id)
  is_audio=$(json_field "$media_json" is_audio false)
  thumbnail=$(json_field "$media_json" thumbnail)
  audio_fallback_url=$(json_field "$media_json" audio_fallback_url)
  feed_label=$(json_field "$media_json" source "no feed")

  if [ -n "$embed_id" ]; then
    EMBED_MODE=1
    VIDEO_READY=1
    echo "media ready: embedding ${INVIDIOUS_BASE_URL}/embed/${embed_id} (${feed_label})" >&2
  elif [ -n "$media_url" ]; then
    VIDEO_READY=1
    if [ "$is_audio" = "true" ]; then
      echo "media ready: audio-only stream from ${feed_label}" >&2
    else
      echo "media ready: video from ${feed_label}" >&2
      if [ -n "$audio_fallback_url" ]; then
        echo "audio-only fallback armed in case the video cannot start" >&2
      fi
    fi
  else
    audio_fallback_url=""
    echo "no media resolved (${feed_label}); page will run the clock and announcements only" >&2
  fi

  media_url_js=$(js_string "$media_url")
  embed_id_js=$(js_string "$embed_id")
  thumbnail_js=$(js_string "$thumbnail")
  audio_fallback_url_js=$(js_string "$audio_fallback_url")
  weather_url_js=$(js_string "$WEATHER_URL")

  mkdir -p "$CACHE_DIR"
  if [ -f "$ALARM_SOUND" ]; then
    cp -f "$ALARM_SOUND" "$CACHE_DIR/alarm.m4a"
  fi
  local tts_files=()
  if [ -d "$tts_dir" ]; then
    # Clear last morning's copies first so a stale default file can never
    # survive next to a differently-shaped voice set.
    rm -f "${CACHE_DIR}"/*.wav
    mapfile -t tts_files < <(find "$tts_dir" -maxdepth 1 -type f -printf "%f\n" | sort -V)
    for tts_file in "${tts_files[@]}"; do
      cp -f "${tts_dir}/${tts_file}" "${CACHE_DIR}/${tts_file}"
    done
  fi
  local tts_js="[]"
  if [ "${#tts_files[@]}" -gt 0 ]; then
    tts_js="$(printf '"%s",' "${tts_files[@]}")"
    tts_js="[${tts_js%,}]"
  fi
  local weather
  weather=$(fetch_weather)
  cat >"$PLAYER_HTML" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Alarm Player</title>
<style>
html, body {
  margin: 0;
  width: 100%;
  height: 100%;
  background: #000;
}
video, audio {
  width: 100%;
  height: 100%;
  object-fit: contain;
  background: #000;
  display: none;
}
#audio-container {
  width: 100%;
  height: 100%;
  display: none;
  background-size: cover;
  background-position: center;
  background-repeat: no-repeat;
  position: relative;
}
#audio-container audio {
  position: absolute;
  bottom: 20px;
  left: 50%;
  transform: translateX(-50%);
  width: 80%;
  max-width: 600px;
  display: block;
}
#embed-container {
  position: fixed;
  inset: 0;
  display: none;
  background: #000;
  z-index: 1;
}
#embed-container iframe {
  width: 100%;
  height: 100%;
  border: 0;
  display: block;
}
#overlay {
  position: fixed;
  inset: 0;
  cursor: pointer;
  z-index: 2;
}
#media-note {
  position: fixed;
  bottom: 24px;
  left: 24px;
  color: #fff;
  font: 28px/1.2 "Sans";
  text-shadow: 0 2px 8px rgba(0, 0, 0, 0.8);
  background: rgba(0, 0, 0, 0.45);
  padding: 10px 16px;
  border-radius: 10px;
  z-index: 3;
  display: none;
  pointer-events: none;
}
#media-note {
  position: fixed;
  position: fixed;
  top: 24px;
  left: 24px;
  color: #fff;
  font: 38px/1.2 "Sans";
  text-shadow: 0 2px 8px rgba(0, 0, 0, 0.8);
  background: rgba(0, 0, 0, 0.45);
  padding: 14px 19px;
  border-radius: 12px;
  z-index: 3;
  pointer-events: none;
}
#hud #time {
  font-size: 53px;
  letter-spacing: 1px;
}
#interval-hud {
  position: fixed;
  top: 24px;
  right: 24px;
  color: #fff;
  font: 34px/1.2 "Sans";
  text-shadow: 0 2px 8px rgba(0, 0, 0, 0.8);
  background: rgba(0, 0, 0, 0.45);
  padding: 14px 19px;
  border-radius: 12px;
  z-index: 4;
  pointer-events: none;
  min-width: 312px;
}
#interval-hud #interval-name {
  font-size: 38px;
  margin-bottom: 7px;
}
#interval-hud #interval-time {
  font-size: 48px;
  letter-spacing: 1px;
}
</style>
</head>
<body>
<video id="player" controls controlslist="nodownload noplaybackrate" playsinline preload="auto"></video>
<div id="audio-container">
  <audio id="audio-player" controls controlslist="nodownload noplaybackrate" preload="auto"></audio>
</div>
<div id="embed-container"></div>
<audio id="tts" preload="auto"></audio>
<div id="hud">
  <div id="time">--:--</div>
  <div id="date">----</div>
  <div id="weather">$weather</div>
</div>
<div id="interval-hud">
  <div id="interval-name">Interval</div>
  <div id="interval-time">00:00</div>
</div>
<div id="media-note"></div>
<div id="overlay" aria-label="play"></div>
<script>
const video = document.getElementById('player');
const audioContainer = document.getElementById('audio-container');
const audioPlayer = document.getElementById('audio-player');
const overlay = document.getElementById('overlay');
const embedContainer = document.getElementById('embed-container');
const mediaNote = document.getElementById('media-note');
const timeEl = document.getElementById('time');
const dateEl = document.getElementById('date');
const weatherEl = document.getElementById('weather');
const tts = document.getElementById('tts');
const intervalHud = document.getElementById('interval-hud');
const intervalNameEl = document.getElementById('interval-name');
const intervalTimeEl = document.getElementById('interval-time');
// mediaUrl and isAudio are mutable: a video that never starts gets swapped for
// the same episode's audio-only enclosure (see fallbackToAudio).
let mediaUrl = $media_url_js;
const embedId = $embed_id_js;
// No autoplay param on purpose: Brave does not honour allow="autoplay"
// delegation from a file:// parent (user activation does not propagate into
// cross-origin iframes), so the embed always loads paused with its play button
// up, and the scripted second click starts it with a real in-frame gesture.
const embedPlayerUrl = embedId
  ? '${INVIDIOUS_BASE_URL}/embed/' + encodeURIComponent(embedId)
  : '';
let isAudio = $is_audio;
const thumbnail = $thumbnail_js;
// Same episode, audio only: the way out of a video that cannot start on a bad
// link. Empty when the day's media is already audio or a cross-origin embed.
const audioFallbackUrl = $audio_fallback_url_js;
const mediaStartFallbackMs = ${ALARM_MEDIA_FALLBACK_MS};
const hasMedia = Boolean(embedId || mediaUrl);
const weatherUrl = $weather_url_js;
// The script starts the alarm sound and opens this page in the same breath;
// this is the sound's remaining life once the page has loaded, after which the
// good morning voice speaks and only then does media start.
const jingleDelayMs = $jingle_delay_ms;
const embedLoadGraceMs = ${EMBED_LOAD_GRACE_MS};
const WEATHER_REFRESH_MS = 60 * 60 * 1000;
const WEATHER_RETRY_MS = 5 * 60 * 1000;
const WEATHER_TIMEOUT_MS = 10000;
const TARGET_DURATION_MINUTES = 40;
const MIN_PLAYBACK_RATE = 1.0;
const MAX_PLAYBACK_RATE = 1.7;
let mouseTimer = null;
const ttsFiles = ${tts_js};
const intervals = [
  { name: "wakeup", seconds: 600 },
  { name: "brush, shave and moisturize", seconds: 600 },
  { name: "dress", seconds: 600 },
  { name: "pullups/pushups", seconds: 600 },
  { name: "go run", seconds: 60 },
];
let intervalIndex = 0;
let intervalStart = 0;
let intervalTimer = null;
let intervalsStarted = false;
const ALERT_FALLBACK_MS = 15000;
const AUDIO_BUFFER_MS = 250;
let pendingTtsIndex = null;
let weatherRetryTimer = null;
function tryPlay() {
  const player = isAudio ? audioPlayer : video;
  const p = player.play();
  if (p && typeof p.catch === 'function') {
    p.catch(() => {});
  }
}

function calculatePlaybackRate(durationSeconds) {
  if (!Number.isFinite(durationSeconds) || durationSeconds <= 0) {
    return MIN_PLAYBACK_RATE;
  }
  const durationMinutes = durationSeconds / 60;
  const targetRate = durationMinutes / TARGET_DURATION_MINUTES;
  return Math.max(MIN_PLAYBACK_RATE, Math.min(MAX_PLAYBACK_RATE, targetRate));
}

function updateClock() {
  const now = new Date();
  const hh = String(now.getHours()).padStart(2, '0');
  const mm = String(now.getMinutes()).padStart(2, '0');
  const weekday = now.toLocaleDateString('en-US', { weekday: 'long' });
  const month = String(now.getMonth() + 1).padStart(2, '0');
  const day = String(now.getDate()).padStart(2, '0');
  timeEl.textContent = hh + ':' + mm;
  dateEl.textContent = weekday + ', ' + month + '/' + day;
}

function normalizeWeatherText(value) {
  return value.replace(/\s+/g, ' ').trim().slice(0, 120);
}

// WMO weather interpretation codes. Mirrors the table in fetch_weather() so the
// value baked into the page and a later refresh read identically.
const WMO_CONDITIONS = {
  0: 'Clear', 1: 'Mainly clear', 2: 'Partly cloudy', 3: 'Overcast',
  45: 'Fog', 48: 'Fog', 51: 'Drizzle', 53: 'Drizzle', 55: 'Drizzle',
  56: 'Freezing drizzle', 57: 'Freezing drizzle', 61: 'Rain', 63: 'Rain',
  65: 'Heavy rain', 66: 'Freezing rain', 67: 'Freezing rain', 71: 'Snow',
  73: 'Snow', 75: 'Heavy snow', 77: 'Snow grains', 80: 'Rain showers',
  81: 'Rain showers', 82: 'Heavy showers', 85: 'Snow showers',
  86: 'Snow showers', 95: 'Thunderstorm', 96: 'Thunderstorm',
  99: 'Thunderstorm',
};

function formatWeather(payload) {
  const current = payload && payload.current;
  if (!current || typeof current.temperature_2m !== 'number') {
    throw new Error('unexpected weather payload');
  }
  const degrees = Math.round(current.temperature_2m);
  const condition = WMO_CONDITIONS[current.weather_code] || 'Unknown';
  return degrees + '°F ' + condition;
}

async function refreshWeather() {
  if (weatherRetryTimer) {
    clearTimeout(weatherRetryTimer);
    weatherRetryTimer = null;
  }
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), WEATHER_TIMEOUT_MS);
  const separator = weatherUrl.includes('?') ? '&' : '?';

  try {
    const response = await fetch(weatherUrl + separator + '_=' + Date.now(), {
      cache: 'no-store',
      signal: controller.signal,
    });
    if (!response.ok) {
      throw new Error('weather request failed');
    }
    const weather = normalizeWeatherText(formatWeather(await response.json()));
    if (!weather) {
      throw new Error('empty weather response');
    }
    weatherEl.textContent = weather;
    try {
      localStorage.setItem('alarm-clock-weather', weather);
    } catch (error) {}
  } catch (error) {
    let cached = '';
    try {
      cached = normalizeWeatherText(localStorage.getItem('alarm-clock-weather') || '');
    } catch (storageError) {}
    if (cached && weatherEl.textContent === 'Weather unavailable') {
      weatherEl.textContent = cached;
    }
    weatherRetryTimer = setTimeout(refreshWeather, WEATHER_RETRY_MS);
  } finally {
    clearTimeout(timeout);
  }
}

function showCursor() {
  document.body.style.cursor = 'default';
  if (mouseTimer) {
    clearTimeout(mouseTimer);
  }
  mouseTimer = setTimeout(() => {
    document.body.style.cursor = 'none';
  }, 3000);
}

// The iframe is inserted the moment the page opens (hidden) so it loads
// during the jingle and the good morning voice instead of after them.
function insertEmbedFrame() {
  if (embedContainer.childElementCount > 0) {
    return;
  }
  // allow="autoplay" delegates the autoplay permission into the frame, so the
  // embedded player starts with sound once clicked and needs no delegation.
  const frame = document.createElement('iframe');
  frame.src = embedPlayerUrl;
  frame.allow = 'autoplay; fullscreen; picture-in-picture; encrypted-media';
  frame.setAttribute('allowfullscreen', '');
  frame.setAttribute('title', 'Alarm video');
  frame.addEventListener('load', () => {
    embedFrameLoaded = true;
    // Late load: arrived after startEmbed decided to wait, before the grace
    // timeout gave up - reveal it as soon as the sequence reaches media.
    if (intervalsStarted && !isAudio && embedContainer.childElementCount > 0) {
      embedContainer.style.display = 'block';
    }
  });
  embedContainer.appendChild(frame);
}

function startEmbed() {
  if (embedFrameLoaded) {
    embedContainer.style.display = 'block';
    startIntervals(true);
    return;
  }
  // The frame had the whole jingle+voice window and still no load event: a
  // short grace, then the audio-only way out. The only thing this page can
  // honestly observe about a cross-origin embed is whether the frame loaded at
  // all, so a player that loads and then stalls remains undetectable.
  setTimeout(() => {
    if (embedFrameLoaded && embedContainer.childElementCount > 0) {
      embedContainer.style.display = 'block';
    } else {
      fallbackToAudio();
    }
    startIntervals(true);
  }, embedLoadGraceMs);
}

let mediaFallbackTimer = null;
let mediaStarted = false;
let embedFrameLoaded = false;

function stopMediaFallback() {
  if (mediaFallbackTimer) {
    clearTimeout(mediaFallbackTimer);
    mediaFallbackTimer = null;
  }
}

function showMediaNote(text) {
  mediaNote.textContent = text;
  mediaNote.style.display = 'block';
}

function startAudioMode(url, isRecovery) {
  audioContainer.style.display = 'block';
  if (thumbnail) {
    audioContainer.style.backgroundImage = 'url(' + thumbnail + ')';
  }
  if (isRecovery) {
    // The playback wiring further down was built for the video element, so the
    // audio element needs the same speed-up and play nudge now that it is live.
    audioPlayer.addEventListener('loadedmetadata', () => {
      const rate = calculatePlaybackRate(audioPlayer.duration);
      audioPlayer.playbackRate = rate;
      audioPlayer.defaultPlaybackRate = rate;
    }, { once: true });
  }
  audioPlayer.src = url;
  audioPlayer.load();
  if (isRecovery) {
    tryPlay();
  }
}

// No media is a supported state, not an error: the clock, the interval countdown
// and the announcements are all wall-clock based, so an alarm whose feeds are
// unreachable still runs and still talks.
function startMedia() {
  if (!hasMedia) {
    showMediaNote('no video this morning (network down?), clock and announcements only');
    startIntervals(true);
    return;
  }

  if (embedId) {
    startEmbed();
    return;
  }
  if (audioFallbackUrl) {
    // Playback is actually being attempted now, so a video that cannot start
    // (dead or very slow link) has this long to prove itself before the page
    // drops to the audio-only enclosure, which needs a ninth of the data.
    mediaFallbackTimer = setTimeout(fallbackToAudio, mediaStartFallbackMs);
  }
  tryPlay();
  startIntervals(true);
}

function fallbackToAudio() {
  mediaFallbackTimer = null;
  if (mediaStarted || !audioFallbackUrl) {
    return;
  }
  isAudio = true;
  try {
    video.pause();
    video.removeAttribute('src');
    video.load();
  } catch (error) {}
  video.style.display = 'none';
  // A frame that will not load has to be removed, not hidden: it keeps pulling
  // segments (and can keep taking audio) behind whatever we show next.
  if (embedContainer.childElementCount > 0) {
    embedContainer.replaceChildren();
    embedContainer.style.display = 'none';
  }
  showMediaNote('video could not start on this connection, playing audio only');
  startAudioMode(audioFallbackUrl, true);
}

function pauseVideoForAlert() {
  const player = isAudio ? audioPlayer : video;
  if (player.paused) {
    return () => {};
  }
  player.pause();
  let resumed = false;
  return () => {
    if (resumed) {
      return;
    }
    resumed = true;
    tryPlay();
  };
}

function playAudioWithFallback(audioEl, src, onPlayFail, onPlayStart) {
  return new Promise((resolve) => {
    let finished = false;
    let durationMs = null;
    let hasStarted = false;
    let resumeTimer = null;
    let fallbackTimer = setTimeout(finish, ALERT_FALLBACK_MS);

    function cleanup() {
      audioEl.removeEventListener('ended', finish);
      audioEl.removeEventListener('error', finish);
      audioEl.removeEventListener('loadedmetadata', onLoaded);
      audioEl.removeEventListener('playing', onPlaying);
      if (resumeTimer) {
        clearTimeout(resumeTimer);
      }
      if (fallbackTimer) {
        clearTimeout(fallbackTimer);
      }
    }

    function finish() {
      if (finished) {
        return;
      }
      finished = true;
      try {
        audioEl.pause();
      } catch (e) {}
      cleanup();
      resolve();
    }

    function onLoaded() {
      if (Number.isFinite(audioEl.duration) && audioEl.duration > 0) {
        durationMs = Math.ceil(audioEl.duration * 1000) + AUDIO_BUFFER_MS;
        if (hasStarted) {
          if (fallbackTimer) {
            clearTimeout(fallbackTimer);
            fallbackTimer = null;
          }
          resumeTimer = setTimeout(finish, durationMs);
        }
      }
    }

    function onPlaying() {
      hasStarted = true;
      if (onPlayStart) {
        onPlayStart();
      }
      if (durationMs === null && Number.isFinite(audioEl.duration) && audioEl.duration > 0) {
        durationMs = Math.ceil(audioEl.duration * 1000) + AUDIO_BUFFER_MS;
      }
      if (durationMs !== null) {
        if (fallbackTimer) {
          clearTimeout(fallbackTimer);
          fallbackTimer = null;
        }
        resumeTimer = setTimeout(finish, durationMs);
      }
    }

    audioEl.addEventListener('ended', finish, { once: true });
    audioEl.addEventListener('error', finish, { once: true });
    audioEl.addEventListener('loadedmetadata', onLoaded, { once: true });
    audioEl.addEventListener('playing', onPlaying, { once: true });

    if (src) {
      audioEl.src = src;
    }
    try {
      audioEl.currentTime = 0;
    } catch (e) {
      finish();
      return;
    }
    const p = audioEl.play();
    if (p && typeof p.then === 'function') {
      p.then(() => {
        if (onPlayStart && !hasStarted) {
          onPlayStart();
        }
      }).catch(() => {
        if (onPlayFail) {
          onPlayFail();
        }
      });
    }
  });
}

function playTts(index) {
  const file = ttsFiles[index];
  if (!file) {
    return Promise.resolve();
  }
  return playAudioWithFallback(
    tts,
    file,
    () => {
      pendingTtsIndex = index;
    },
    () => {
      pendingTtsIndex = null;
    }
  );
}

function announceInterval(index) {
  const interval = intervals[index];
  if (!interval) {
    return;
  }
  // A cross-origin embed cannot be paused or resumed from here, so the
  // announcement simply plays over the video.
  const resumeVideo = embedId ? () => {} : pauseVideoForAlert();
  playTts(index).then(resumeVideo, resumeVideo);
}

function formatRemaining(seconds) {
  const m = Math.floor(seconds / 60);
  const s = Math.max(0, Math.floor(seconds % 60));
  return String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
}

function updateIntervalDisplay(secondsLeft) {
  const current = intervals[intervalIndex];
  if (!current) {
    intervalHud.style.display = 'none';
    return;
  }
  intervalNameEl.textContent = current.name;
  intervalTimeEl.textContent = formatRemaining(secondsLeft);
}

function startIntervals(skipFirstAnnounce) {
  if (intervalsStarted || intervals.length === 0) {
    return;
  }
  intervalsStarted = true;
  intervalStart = performance.now();
  updateIntervalDisplay(intervals[0].seconds);
  // The good morning voice is spoken by the wakeup sequence before media
  // starts, so the first interval is normally counted, not announced again.
  if (skipFirstAnnounce !== true) {
    announceInterval(0);
  }
  intervalTimer = setInterval(tickIntervals, 250);
}

function tickIntervals() {
  const current = intervals[intervalIndex];
  if (!current) {
    clearInterval(intervalTimer);
    intervalHud.style.display = 'none';
    return;
  }
  const elapsed = (performance.now() - intervalStart) / 1000;
  const remaining = current.seconds - elapsed;
  if (remaining <= 0) {
    const ended = current;
    intervalIndex += 1;
    const next = intervals[intervalIndex];
    if (!next) {
      clearInterval(intervalTimer);
      intervalHud.style.display = 'none';
      return;
    }
    intervalStart = performance.now();
    updateIntervalDisplay(next.seconds);
    announceInterval(intervalIndex);
    return;
  }
  updateIntervalDisplay(remaining);
}

// Preload the media now so it is ready the moment the wakeup sequence ends.
// Nothing plays here: the elements stay paused until the jingle and the good
// morning voice have finished - playback is sequenced from jingleDelayMs.
let preloadPlayer = null;
if (embedId) {
  insertEmbedFrame();
} else if (hasMedia) {
  if (isAudio) {
    audioContainer.style.display = 'block';
    if (thumbnail) {
      audioContainer.style.backgroundImage = 'url(' + thumbnail + ')';
    }
    audioPlayer.src = mediaUrl;
    audioPlayer.load();
    preloadPlayer = audioPlayer;
  } else {
    video.style.display = 'block';
    video.src = mediaUrl;
    video.load();
    preloadPlayer = video;
  }
  preloadPlayer.addEventListener('loadedmetadata', () => {
    const rate = calculatePlaybackRate(preloadPlayer.duration);
    preloadPlayer.playbackRate = rate;
    preloadPlayer.defaultPlaybackRate = rate;
  });
}

overlay.addEventListener('click', () => {
  // Click 1 exists purely to give this document user activation (the TTS
  // element needs it) and to drop the overlay so the player's own controls
  // become reachable. It deliberately does NOT start playback: that is
  // sequenced after the jingle and the good morning voice.
  overlay.style.display = 'none';
  if (pendingTtsIndex !== null) {
    const idx = pendingTtsIndex;
    pendingTtsIndex = null;
    playTts(idx);
  }
});

document.addEventListener('keydown', (event) => {
  if (event.code === 'Space' && !embedId) {
    event.preventDefault();
    const player = isAudio ? audioPlayer : video;
    if (player.paused) {
      tryPlay();
    } else {
      player.pause();
    }
  }
});

document.addEventListener('mousemove', showCursor);
showCursor();
updateClock();
setInterval(updateClock, 1000);
refreshWeather();
setInterval(refreshWeather, WEATHER_REFRESH_MS);
// A video that reaches "playing" is off the fallback list; one that never gets
// there is exactly what the audio-only fallback is for.
video.addEventListener('playing', () => {
  mediaStarted = true;
  stopMediaFallback();
});

// Wakeup sequence: when the alarm sound has finished, the good morning voice
// speaks (it gets parked for the activation click if that has not landed yet),
// and media starts when the voice resolves - ended, failed, or timed out.
function beginWakeupSequence() {
  playTts(0).then(startMedia, startMedia);
}
setTimeout(beginWakeupSequence, jingleDelayMs);
</script>
</body>
</html>
EOF

}

# Opening the page is separate from building it because it happens even when no
# media was resolved: the clock, interval countdown and announcements all live in
# this page, and they are the part of the alarm a dead network must not silence.
open_player_page() {
  if wlrctl toplevel find app_id:brave-browser >/dev/null 2>&1; then
    brave-browser --new-tab "file://$PLAYER_HTML" >/dev/null 2>&1 &
  else
    brave-browser --new-window "file://$PLAYER_HTML" >/dev/null 2>&1 &
  fi
  sleep 1
  if wlrctl toplevel find app_id:brave-browser >/dev/null 2>&1; then
    wlrctl toplevel focus app_id:brave-browser
    wlrctl toplevel fullscreen app_id:brave-browser
  fi
}

# Click 1 always fires, media or not: landing on the page overlay is what gives
# the document the user activation the TTS element needs (Brave will not unlock
# audio for a page nobody has interacted with). It must not start playback -
# the page sequences that itself. Click 2 is embed-only and timed to land just
# after the good morning voice ends, on the embed's big play button -
# Invidious' player style puts it at the top-left, (55,34) at 1080p, verified
# via CDP - starting playback with a real in-frame gesture, because the embed
# is deliberately loaded WITHOUT autoplay (Brave ignores allow="autoplay"
# delegation from a file:// parent). Direct streams are started by the page.
start_scripted_clicks() {
  if [ ! -x "$YDOTOOL_BIN" ]; then
    echo "ydotool missing at ${YDOTOOL_BIN}; nothing will click to start playback/unlock TTS" >&2
    return 0
  fi

  (
    export YDOTOOL_SOCKET="$YDOTOOL_SOCKET_PATH"
    sleep "$ALARM_CLICK1_DELAY_SECONDS"
    "$YDOTOOL_BIN" mousemove --absolute 517 312
    "$YDOTOOL_BIN" click 0xC0
    if [ "$EMBED_MODE" -eq 1 ]; then
      local remain=$((CLICK2_DELAY_SECONDS - ALARM_CLICK1_DELAY_SECONDS))
      [ "$remain" -lt 1 ] && remain=1
      sleep "$remain"
      "$YDOTOOL_BIN" mousemove --absolute 55 34
      "$YDOTOOL_BIN" click 0xC0
    fi
  ) &
}

run_alarm() {
  local set_epoch now_epoch wait_limit delta
  ensure_wifi_connected || true
  CEC_DEV="$(detect_cec_dev || printf '%s' "$CEC_DEV")"
  # Resolve media first, in the background. With a pre-downloaded video this
  # finishes in seconds (it never touches the video feed); otherwise the TV
  # wake window gives the network ~90s of cover, so retries are free and a
  # stalled wifi node costs a late video instead of no video.
  start_media_resolution
  if ! tv_is_on; then
    echo "TV off or state unknown; running tv-toggle.sh on ${CEC_DEV}" >&2
    "$SCRIPTS_DIR/tv-toggle.sh" || echo "tv-toggle.sh exited nonzero; continuing the alarm anyway" >&2
    sleep 1
    if tv_is_on; then
      echo "TV is on" >&2
    else
      echo "WARNING: TV still not reporting power-on after tv-toggle.sh" >&2
    fi
  fi
  set_volume_baseline
  # Media resolution gets whatever is left of the lead window. Whatever has not
  # resolved by the set time is dropped: the sound and the page start on time,
  # and a media-less page still runs the clock and announcements (the floor).
  set_epoch=$(date -d "today $(cat "$ALARM_TIME_FILE" 2>/dev/null || true)" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  wait_limit=$((set_epoch - now_epoch - 5))
  if [ "$wait_limit" -lt 0 ]; then
    wait_limit=0
  fi
  if [ "$wait_limit" -gt "$((ALARM_MEDIA_BUDGET_SECONDS + 20))" ]; then
    wait_limit=$((ALARM_MEDIA_BUDGET_SECONDS + 20))
  fi
  local media_failed=0
  wait_for_media_resolution "$wait_limit" || media_failed=1
  # Both of these run regardless of the result: the page carries the clock, the
  # interval countdown and the announcements, which is what still works when the
  # feeds are unreachable.
  prepare_player_page
  # Idle out the rest of the lead window: the alarm sound belongs at the set
  # time, not whenever the wake-up work happened to finish.
  now_epoch=$(date +%s)
  delta=$((set_epoch - now_epoch))
  if [ "$delta" -gt 0 ]; then
    if [ "$delta" -gt 300 ]; then
      # Defensive cap: the timer should never fire this early.
      delta=300
    fi
    echo "waiting ${delta}s for the set time" >&2
    sleep "$delta"
  fi
  local alarm_pid=""
  alarm_pid=$(start_alarm_sound || true)
  open_player_page
  start_scripted_clicks
  if [ -n "$alarm_pid" ]; then
    wait "$alarm_pid" 2>/dev/null || true
  fi
  sleep "$ALARM_POST_SOUND_DELAY_SECONDS"
  if [ "$media_failed" -ne 0 ]; then
    echo "alarm completed WITHOUT media but WITH clock and announcements: resolution failed (see messages above)" >&2
    return 1
  fi
}

if [ "${1:-}" = "--resolve-media" ]; then
  resolve_media_json || exit 1
  exit 0
fi

if [ "${1:-}" = "--pre-download" ]; then
  run_pre_download || exit 1
  exit 0
fi

if [ "${1:-}" = "--trigger" ]; then
  run_alarm || exit 1
  exit 0
fi

if [ "${1:-}" = "--set" ]; then
  time_input="${2:-}"
  if ! alarm_time=$(parse_time "$time_input"); then
    echo "Failed to set alarm: invalid time (expected HHMM, e.g. 0900)" >&2
    exit 1
  fi
  if ! schedule_alarm "$alarm_time"; then
    echo "Failed to set alarm for ${alarm_time} (reason above)" >&2
    exit 1
  fi
  show_alarm_set "$alarm_time" >/dev/null 2>&1 &
  echo "Alarm set for $alarm_time"
  exit 0
fi

if [ "${1:-}" = "--restore" ]; then
  # The transient alarm-clock.timer does not survive a reboot; this file does.
  # Called by alarm-restore.service at boot to re-arm from the saved time.
  if [ ! -f "$ALARM_TIME_FILE" ]; then
    echo "alarm-restore: no saved alarm time; nothing to re-arm" >&2
    exit 0
  fi
  saved_time=$(cat "$ALARM_TIME_FILE" 2>/dev/null || true)
  if ! alarm_time=$(parse_time "$saved_time"); then
    echo "alarm-restore: invalid saved time '${saved_time}'; not scheduling" >&2
    exit 1
  fi
  if systemctl --user is-active --quiet "${ALARM_UNIT}.timer"; then
    echo "alarm-restore: ${ALARM_UNIT}.timer already active" >&2
    exit 0
  fi
  if schedule_alarm "$alarm_time"; then
    echo "alarm-restore: re-armed ${ALARM_UNIT}.timer for ${alarm_time}" >&2
    exit 0
  fi
  echo "alarm-restore: failed to schedule ${alarm_time}" >&2
  exit 1
fi

placeholder="--:--"
if [ -f "$ALARM_TIME_FILE" ]; then
  saved_time=$(cat "$ALARM_TIME_FILE" 2>/dev/null || true)
  if [[ "$saved_time" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
    placeholder="$saved_time"
  fi
fi

options=(
  "[set alarm]"
  "[off]"
)

choice=$(printf '%s\n' "${options[@]}" | fuzzel --lines 2 --prompt "" --placeholder "$placeholder" "${FUZZEL_BASE_OPTS[@]}")

if [ -z "$choice" ]; then
  exit 0
fi

if [ "$choice" = "[off]" ]; then
  cancel_alarm
  exit 0
fi

time_input="$choice"
if [ "$choice" = "[set alarm]" ]; then
  time_input=$(fuzzel --prompt-only "" --placeholder "$placeholder" "${FUZZEL_BASE_OPTS[@]}" || true)
fi

if [ -z "$time_input" ]; then
  exit 0
fi

alarm_time=$(parse_time "$time_input" || true)
if [ -z "$alarm_time" ]; then
  # The menu used to swallow bad input with no feedback at all.
  show_message "Use 4 digits, e.g. 0900"
  exit 0
fi

if schedule_alarm "$alarm_time"; then
  show_alarm_set "$alarm_time"
else
  show_message "ALARM NOT SET - see journal"
  exit 1
fi
