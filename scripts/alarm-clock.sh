#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="${HOME}/pi-tv/scripts"
ALARM_DIR="${HOME}/.config/alarm-clock"
ALARM_TIME_FILE="${ALARM_DIR}/time"
ALARM_UNIT="alarm-clock"
CEC_DEV="/dev/cec1"
ALARM_SOUND="${HOME}/pi-tv/tools/alarm.m4a"
FEED_URL="https://www.democracynow.org/podcast-video.xml"
INVIDIOUS_BASE_URL="https://tube.halfab.net"
ALTFEED1_PLAYLIST_ID="PL39u5ZEfYDEO5PaNRWyqloGY6zzJ1fjBa"
ALTFEED2_PLAYLIST_ID="PLT5G3DTYh5urqnH5XWfqc_dTJnaddX9jm"
ALTFEED_MIN_LENGTH_SECONDS=2500
CACHE_DIR="${HOME}/.cache/alarm-clock"
PLAYER_HTML="${CACHE_DIR}/player.html"
WEATHER_CACHE_FILE="${CACHE_DIR}/weather"
YDOTOOL_BIN="${HOME}/pi-tv/tools/ydotool/build/ydotool"
YDOTOOL_SOCKET_PATH="/tmp/ydotoold.socket"
WEATHER_URL="https://wttr.in/76248?format=%t+%C&u"
ALARM_VIDEO_DELAY_SECONDS=21
ALARM_VIDEO_DELAY_MS=$((ALARM_VIDEO_DELAY_SECONDS * 1000))
ALARM_VIDEO_CLICK_DELAY_SECONDS=6
ALARM_POST_SOUND_DELAY_SECONDS=60
WIFI_FALLBACK_SSID="mesh-node"
WIFI_RECONNECT_TIMEOUT_SECONDS=45
WIFI_RECONNECT_POLL_SECONDS=2
VIDEO_READY=0

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

show_alarm_set() {
  local time="$1"
  local message="Alarm set for ${time}"
  if command -v timeout >/dev/null 2>&1; then
    printf '%s\n' "$message" | timeout 5s fuzzel --lines 1 --prompt "" "${FUZZEL_BASE_OPTS[@]}" >/dev/null 2>&1 || true
  else
    printf '%s\n' "$message" | fuzzel --lines 1 --prompt "" "${FUZZEL_BASE_OPTS[@]}" >/dev/null 2>&1 || true
  fi
}

cancel_alarm() {
  systemctl --user stop "${ALARM_UNIT}.timer" "${ALARM_UNIT}.service" >/dev/null 2>&1 || true
  rm -f "$ALARM_TIME_FILE"
}

schedule_alarm() {
  local time="$1"
  mkdir -p "$ALARM_DIR"
  printf '%s\n' "$time" >"$ALARM_TIME_FILE"
  systemctl --user stop "${ALARM_UNIT}.timer" "${ALARM_UNIT}.service" >/dev/null 2>&1 || true
  if ! systemd-run --user --unit="$ALARM_UNIT" \
    --on-calendar="*-*-* ${time}:00" \
    "$SCRIPTS_DIR/alarm-clock.sh" --trigger >/dev/null; then
    return 1
  fi
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

tv_is_on() {
  local state
  state=$(cec-ctl -d "$CEC_DEV" --playback -t 0 --give-device-power-status 2>/dev/null \
    | awk '/pwr-state:/ {print $2; exit}')
  case "$state" in
    on|to-on) return 0 ;;
    standby|to-standby) return 1 ;;
    *) return 0 ;;
  esac
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
  if [ -f "$ALARM_SOUND" ]; then
    ffplay -nodisp -autoexit -hide_banner -loglevel error "$ALARM_SOUND" >/dev/null 2>&1 &
    echo "$!"
  fi
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

fetch_media_from_rss() {
  local feed_url="${1:-}"
  python3 - "$feed_url" <<'PY'
import sys
import urllib.request
import xml.etree.ElementTree as ET
import json

feed_url = sys.argv[1]
if not feed_url:
    sys.exit(1)

with urllib.request.urlopen(feed_url, timeout=20) as resp:
    data = resp.read()

root = ET.fromstring(data)

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

fetch_media_from_invidious_playlist() {
  local playlist_id="${1:-}"
  local min_length_seconds="${2:-0}"
  python3 - "$INVIDIOUS_BASE_URL" "$playlist_id" "$min_length_seconds" <<'PY'
import json
import sys
import urllib.parse
import urllib.request

base_url = sys.argv[1].rstrip("/")
playlist_id = sys.argv[2]
min_length_seconds = int(sys.argv[3])

if not base_url or not playlist_id:
    sys.exit(1)

headers = {"User-Agent": "alarm-clock"}

def fetch_json(url):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))

def best_thumbnail(video):
    thumbs = video.get("videoThumbnails") or []
    if not thumbs:
        return ""
    return max(
        thumbs,
        key=lambda t: int(t.get("width") or 0) * int(t.get("height") or 0),
    ).get("url", "")

def stream_score(stream):
    label = stream.get("qualityLabel") or stream.get("quality") or ""
    digits = "".join(ch for ch in label if ch.isdigit())
    height = int(digits) if digits else 0
    container_bonus = 10000 if stream.get("container") == "mp4" else 0
    return container_bonus + height

playlist_url = f"{base_url}/api/v1/playlists/{urllib.parse.quote(playlist_id, safe='')}"
playlist = fetch_json(playlist_url)

for video in playlist.get("videos") or []:
    try:
        length_seconds = int(video.get("lengthSeconds") or 0)
    except (TypeError, ValueError):
        length_seconds = 0
    if length_seconds <= min_length_seconds:
        continue

    video_id = video.get("videoId")
    if not video_id:
        continue

    video_url = f"{base_url}/api/v1/videos/{urllib.parse.quote(video_id, safe='')}"
    details = fetch_json(video_url)
    if details.get("liveNow") or details.get("isUpcoming"):
        continue

    streams = [
        stream for stream in (details.get("formatStreams") or [])
        if stream.get("url")
    ]
    if not streams:
        continue

    stream = max(streams, key=stream_score)
    thumbnail = best_thumbnail(details) or best_thumbnail(video)
    print(json.dumps({
        "url": stream["url"],
        "is_audio": False,
        "thumbnail": thumbnail,
    }))
    break
else:
    sys.exit(1)
PY
}

fetch_weather() {
  python3 - "$WEATHER_URL" "$WEATHER_CACHE_FILE" <<'PY'
import html
import os
import sys
import time
import urllib.request

url = sys.argv[1]
cache_file = sys.argv[2]

def normalize(value):
    return " ".join(value.split())[:120]

def read_cached():
    try:
        with open(cache_file, "r", encoding="utf-8") as cached:
            return normalize(cached.read())
    except OSError:
        return ""

data = ""
for attempt in range(3):
    try:
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "alarm-clock",
                "Cache-Control": "no-cache",
            },
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            candidate = normalize(resp.read().decode("utf-8", "replace"))
        if candidate:
            data = candidate
            os.makedirs(os.path.dirname(cache_file), exist_ok=True)
            with open(cache_file, "w", encoding="utf-8") as cached:
                cached.write(data + "\n")
            break
    except Exception:
        if attempt < 2:
            time.sleep(1)

if not data:
    data = read_cached() or "Weather unavailable"

print(html.escape(data))
PY
}

prepare_latest_video() {
  local media_url media_json feed_to_use is_audio thumbnail media_url_js thumbnail_js weather_url_js
  local day_of_week
  VIDEO_READY=0

  day_of_week=$(date +%u)

  if [ "$day_of_week" -eq 6 ] && [ -n "$ALTFEED1_PLAYLIST_ID" ]; then
    media_json=$(fetch_media_from_invidious_playlist "$ALTFEED1_PLAYLIST_ID" "$ALTFEED_MIN_LENGTH_SECONDS" 2>/dev/null || true)
  elif [ "$day_of_week" -eq 7 ] && [ -n "$ALTFEED2_PLAYLIST_ID" ]; then
    media_json=$(fetch_media_from_invidious_playlist "$ALTFEED2_PLAYLIST_ID" "$ALTFEED_MIN_LENGTH_SECONDS" 2>/dev/null || true)
  else
    feed_to_use="$FEED_URL"
    media_json=$(fetch_media_from_rss "$feed_to_use" 2>/dev/null || true)
  fi

  if [ -z "$media_json" ]; then
    return 1
  fi

  media_url=$(printf '%s' "$media_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['url'])" 2>/dev/null || true)
  is_audio=$(printf '%s' "$media_json" | python3 -c "import sys, json; print(str(json.load(sys.stdin)['is_audio']).lower())" 2>/dev/null || echo "false")
  thumbnail=$(printf '%s' "$media_json" | python3 -c "import sys, json; print(json.load(sys.stdin)['thumbnail'])" 2>/dev/null || true)
  media_url_js=$(printf '%s' "$media_url" | python3 -c "import sys, json; print(json.dumps(sys.stdin.read()))")
  thumbnail_js=$(printf '%s' "$thumbnail" | python3 -c "import sys, json; print(json.dumps(sys.stdin.read()))")
  weather_url_js=$(printf '%s' "$WEATHER_URL" | python3 -c "import sys, json; print(json.dumps(sys.stdin.read()))")

  if [ -z "$media_url" ]; then
    return 1
  fi

  mkdir -p "$CACHE_DIR"
  if [ -f "$ALARM_SOUND" ]; then
    cp -f "$ALARM_SOUND" "$CACHE_DIR/alarm.m4a"
  fi
  local tts_files=()
  if [ -d "${HOME}/pi-tv/tools/tts" ]; then
    mapfile -t tts_files < <(find "${HOME}/pi-tv/tools/tts" -maxdepth 1 -type f -printf "%f\n" | sort -V)
    for tts_file in "${tts_files[@]}"; do
      cp -f "${HOME}/pi-tv/tools/tts/${tts_file}" "${CACHE_DIR}/${tts_file}"
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
#overlay {
  position: fixed;
  inset: 0;
  cursor: pointer;
  z-index: 2;
}
#splash {
  position: fixed;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  text-align: center;
  color: #fff;
  font: 64px/1.2 "Sans";
  background: #000;
  z-index: 1;
}
#hud {
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
<audio id="tts" preload="auto"></audio>
<div id="splash">Good Morning,<br>Time to get up!</div>
<div id="hud">
  <div id="time">--:--</div>
  <div id="date">----</div>
  <div id="weather">$weather</div>
</div>
<div id="interval-hud">
  <div id="interval-name">Interval</div>
  <div id="interval-time">00:00</div>
</div>
<div id="overlay" aria-label="play"></div>
<script>
const video = document.getElementById('player');
const audioContainer = document.getElementById('audio-container');
const audioPlayer = document.getElementById('audio-player');
const overlay = document.getElementById('overlay');
const timeEl = document.getElementById('time');
const dateEl = document.getElementById('date');
const weatherEl = document.getElementById('weather');
const splash = document.getElementById('splash');
const tts = document.getElementById('tts');
const intervalHud = document.getElementById('interval-hud');
const intervalNameEl = document.getElementById('interval-name');
const intervalTimeEl = document.getElementById('interval-time');
const mediaUrl = $media_url_js;
const isAudio = $is_audio;
const thumbnail = $thumbnail_js;
const weatherUrl = $weather_url_js;
const startDelayMs = ${ALARM_VIDEO_DELAY_MS};
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
    const weather = normalizeWeatherText(await response.text());
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

function startVideo() {
  if (isAudio) {
    if (audioPlayer.src) {
      return;
    }
    splash.style.display = 'none';
    audioContainer.style.display = 'block';
    if (thumbnail) {
      audioContainer.style.backgroundImage = 'url(' + thumbnail + ')';
    }
    audioPlayer.src = mediaUrl;
    audioPlayer.load();
    startIntervals();
  } else {
    if (video.src) {
      return;
    }
    splash.style.display = 'none';
    video.style.display = 'block';
    video.src = mediaUrl;
    video.load();
    startIntervals();
  }
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
  const resumeVideo = pauseVideoForAlert();
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

function startIntervals() {
  if (intervalsStarted || intervals.length === 0) {
    return;
  }
  intervalsStarted = true;
  intervalStart = performance.now();
  updateIntervalDisplay(intervals[0].seconds);
  announceInterval(0);
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

if (isAudio) {
  audioPlayer.addEventListener('loadedmetadata', () => {
    const rate = calculatePlaybackRate(audioPlayer.duration);
    audioPlayer.playbackRate = rate;
    audioPlayer.defaultPlaybackRate = rate;
    tryPlay();
  });
  audioPlayer.addEventListener('canplay', () => {
    tryPlay();
  });
} else {
  video.addEventListener('loadedmetadata', () => {
    const rate = calculatePlaybackRate(video.duration);
    video.playbackRate = rate;
    video.defaultPlaybackRate = rate;
    tryPlay();
  });
  video.addEventListener('canplay', () => {
    tryPlay();
  });
}

overlay.addEventListener('click', () => {
  const player = isAudio ? audioPlayer : video;
  if (player.paused) {
    tryPlay();
  }
  if (pendingTtsIndex !== null) {
    const idx = pendingTtsIndex;
    pendingTtsIndex = null;
    playTts(idx);
  }
});

document.addEventListener('keydown', (event) => {
  if (event.code === 'Space') {
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
setTimeout(startVideo, startDelayMs);
</script>
</body>
</html>
EOF

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

  VIDEO_READY=1
}

start_video_playback() {
  if [ "$VIDEO_READY" -ne 1 ]; then
    return 0
  fi

  if wlrctl toplevel find app_id:brave-browser >/dev/null 2>&1; then
    wlrctl toplevel focus app_id:brave-browser
    wlrctl toplevel fullscreen app_id:brave-browser
  fi

  if [ -x "$YDOTOOL_BIN" ]; then
    (
      export YDOTOOL_SOCKET="$YDOTOOL_SOCKET_PATH"
      sleep "$ALARM_VIDEO_DELAY_SECONDS"
      sleep "$ALARM_VIDEO_CLICK_DELAY_SECONDS"
      "$YDOTOOL_BIN" mousemove --absolute 517 312
      "$YDOTOOL_BIN" click 0xC0
    ) &
  fi
}

run_alarm() {
  ensure_wifi_connected || true
  CEC_DEV="$(detect_cec_dev || printf '%s' "$CEC_DEV")"
  if ! tv_is_on; then
    "$SCRIPTS_DIR/tv-toggle.sh"
    sleep 1
  fi
  set_volume_baseline
  local alarm_pid=""
  alarm_pid=$(start_alarm_sound || true)
  prepare_latest_video || true
  start_video_playback
  if [ -n "$alarm_pid" ]; then
    wait "$alarm_pid" 2>/dev/null || true
  fi
  sleep "$ALARM_POST_SOUND_DELAY_SECONDS"
}

if [ "${1:-}" = "--trigger" ]; then
  run_alarm
  exit 0
fi

if [ "${1:-}" = "--set" ]; then
  time_input="${2:-}"
  if ! alarm_time=$(parse_time "$time_input"); then
    echo "Failed to set alarm: invalid time (expected HHMM, e.g. 0900)" >&2
    exit 1
  fi
  if ! schedule_alarm "$alarm_time"; then
    echo "Failed to set alarm" >&2
    exit 1
  fi
  show_alarm_set "$alarm_time" >/dev/null 2>&1 &
  echo "Alarm set for $alarm_time"
  exit 0
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
  exit 0
fi

schedule_alarm "$alarm_time"
show_alarm_set "$alarm_time"
