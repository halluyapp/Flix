#!/usr/bin/env bash
set -Eeuo pipefail

: "${FLIX_PACKAGE:=com.halluyapp.flix}"
mkdir -p artifacts/emulator artifacts/screenshots

size=$(adb shell wm size | sed -n 's/.*Physical size: //p' | tr -d '\r')
width=${size%x*}
height=${size#*x}
ui_file=artifacts/emulator/media-window.xml

tap_text_in_xml() {
  local path=$1 label=$2 coordinates
  coordinates=$(python3 - "$path" "$label" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
for node in root.iter():
    if node.get('text') != sys.argv[2]:
        continue
    m = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', node.get('bounds', ''))
    if m:
        x1, y1, x2, y2 = map(int, m.groups())
        print((x1 + x2) // 2, (y1 + y2) // 2)
        raise SystemExit(0)
raise SystemExit(1)
PY
) || return 1
  read -r x y <<<"$coordinates"
  adb shell input tap "$x" "$y"
}

dump_ui() {
  local destination=${1:-$ui_file}
  for _ in 1 2 3; do
    adb shell uiautomator dump /sdcard/flix-media-window.xml >/dev/null 2>&1
    adb pull /sdcard/flix-media-window.xml "$destination" >/dev/null 2>&1
    if ! grep -Fq "Pixel Launcher isn't responding" "$destination"; then
      return 0
    fi
    cp "$destination" artifacts/emulator/launcher-anr-window.xml
    if ! tap_text_in_xml "$destination" 'Wait'; then
      echo 'Pixel Launcher ANR dialog is visible but its Wait button was not found.' >&2
      return 1
    fi
    sleep 3
  done
  echo 'Pixel Launcher ANR dialog did not dismiss after three attempts.' >&2
  return 1
}

tap_label() {
  local label=$1
  local coordinates
  dump_ui
  coordinates=$(python3 - "$ui_file" "$label" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

path, label = sys.argv[1:]
root = ET.parse(path).getroot()
matches = []
for node in root.iter():
    if node.get('text') != label and node.get('content-desc') != label:
        continue
    bounds = node.get('bounds', '')
    m = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', bounds)
    if not m:
        continue
    x1, y1, x2, y2 = map(int, m.groups())
    if x2 <= x1 or y2 <= y1:
        continue
    matches.append((node.get('clickable') == 'true', (x1 + x2) // 2, (y1 + y2) // 2))
if not matches:
    raise SystemExit(1)
clickable = [m for m in matches if m[0]]
_, x, y = (clickable or matches)[0]
print(x, y)
PY
) || {
    echo "Could not find visible UI label: $label" >&2
    return 1
  }
  read -r x y <<<"$coordinates"
  adb shell input tap "$x" "$y"
}

tap_search_field() {
  local coordinates
  coordinates=$(python3 - "$ui_file" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
for node in root.iter():
    if node.get('class') != 'android.widget.EditText':
        continue
    m = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', node.get('bounds', ''))
    if m:
        x1, y1, x2, y2 = map(int, m.groups())
        print((x1 + x2) // 2, (y1 + y2) // 2)
        raise SystemExit(0)
raise SystemExit(1)
PY
) || {
    echo 'Could not find the Search text field.' >&2
    return 1
  }
  read -r x y <<<"$coordinates"
  adb shell input tap "$x" "$y"
}

second_result_coordinates() {
  python3 - "$ui_file" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
images = []
for node in root.iter():
    if node.get('class') != 'android.widget.ImageView' or node.get('clickable') != 'true':
        continue
    m = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', node.get('bounds', ''))
    if not m:
        continue
    x1, y1, x2, y2 = map(int, m.groups())
    if x2 - x1 >= 100 and y2 - y1 >= 100:
        images.append(((x1 + x2) // 2, (y1 + y2) // 2))
images.sort(key=lambda p: (p[1], p[0]))
if len(images) >= 2:
    print(*images[1])
else:
    bounds = root.get('bounds') or next(
        (node.get('bounds', '') for node in root.iter() if node.get('bounds')),
        '',
    )
    m = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', bounds)
    if not m:
        raise SystemExit(1)
    x1, y1, x2, y2 = map(int, m.groups())
    print((x1 + x2) // 2, y1 + (y2 - y1) * 26 // 100)
PY
}

wait_for_label() {
  local label=$1
  local attempts=${2:-60}
  for _ in $(seq 1 "$attempts"); do
    dump_ui
    if grep -Fq "$label" "$ui_file"; then return 0; fi
    sleep 2
  done
  echo "Timed out waiting for UI label: $label" >&2
  cp "$ui_file" artifacts/emulator/media-timeout-window.xml || true
  return 1
}

wait_for_active_player() {
  local expected_title=$1
  local attempts=${2:-60}
  for _ in $(seq 1 "$attempts"); do
    dump_ui
    if grep -Eq 'Playback could not start|temporarily unavailable|offline copy could not be opened|Playback was interrupted' "$ui_file"; then
      echo 'Player displayed an unrecoverable media error.' >&2
      cp "$ui_file" artifacts/emulator/media-player-error.xml || true
      return 1
    fi
    if grep -Fq "$expected_title" "$ui_file" && grep -Eq '[0-9]{2,}:[0-9]{2}' "$ui_file"; then
      return 0
    fi
    sleep 2
  done
  echo 'Timed out waiting for the movie player to initialize.' >&2
  cp "$ui_file" artifacts/emulator/media-player-timeout.xml || true
  return 1
}

# Search Flix's TMDB catalogue. TMDB returns the 2024 remake first and the
# 1922 public-domain film second for this query.
dump_ui
adb shell input tap "$((width * 70 / 100))" "$((height * 93 / 100))"
sleep 2
dump_ui
tap_search_field
dump_ui
adb shell input text 'Nosferatu'
adb shell input keyevent KEYCODE_BACK
sleep 10
dump_ui
cp "$ui_file" artifacts/emulator/movie-search-window.xml
adb exec-out screencap -p > artifacts/screenshots/flix-movie-search.png

coordinates=$(second_result_coordinates) || {
  echo 'Could not identify the second Nosferatu search result in Flix.' >&2
  exit 1
}
read -r result_x result_y <<<"$coordinates"
adb shell input tap "$result_x" "$result_y"
sleep 5
dump_ui artifacts/emulator/movie-detail-window.xml
if ! grep -q '1922' artifacts/emulator/movie-detail-window.xml; then
  echo 'The second Nosferatu result did not open the 1922 film.' >&2
  exit 1
fi
echo 'Flix opened Nosferatu (1922) from Search.'

# Start playback and require the actual player title/time UI, not just a route push.
tap_label 'Play'
sleep 2
wait_for_active_player 'Nosferatu' 60
adb exec-out screencap -p > artifacts/screenshots/flix-movie-player.png
echo 'Flix initialized movie playback.'
adb shell input keyevent KEYCODE_BACK
sleep 4
dump_ui

# Resolve the same title again through the Download options sheet, save only the
# English caption sidecar, and wait for Android DownloadManager to finish.
tap_label 'Download'
wait_for_label 'Download in Flix' 90
if grep -q 'No downloadable video is available' "$ui_file"; then
  echo 'The app did not expose a downloadable MP4 for Nosferatu (1922).' >&2
  exit 1
fi
tap_label 'None'
sleep 1
tap_label 'English'
sleep 1
tap_label 'Download in Flix'
for _ in $(seq 1 90); do
  dump_ui
  if grep -Fq 'Starting download' "$ui_file"; then
    sleep 2
    continue
  fi
  if ! grep -Fq 'Download in Flix' "$ui_file"; then
    break
  fi
  sleep 2
done
if grep -Fq 'Download in Flix' "$ui_file"; then
  echo 'The in-app download did not leave its options sheet.' >&2
  exit 1
fi
adb shell input keyevent KEYCODE_BACK
sleep 3
adb shell input tap "$((width * 90 / 100))" "$((height * 93 / 100))"
sleep 3
tap_label 'Downloads'
sleep 3

complete=false
for attempt in $(seq 1 180); do
  dump_ui
  if grep -Fq 'Play offline' "$ui_file"; then
    complete=true
    break
  fi
  if grep -q 'Download interrupted' "$ui_file"; then
    echo 'Android DownloadManager reported a failed movie transfer.' >&2
    cp "$ui_file" artifacts/emulator/movie-download-failed.xml || true
    exit 1
  fi
  if ! adb shell pidof "$FLIX_PACKAGE" >/dev/null; then
    echo 'Flix exited while the movie download was in progress.' >&2
    exit 1
  fi
  sleep 4
done
if [[ "$complete" != true ]]; then
  echo 'Timed out waiting for Nosferatu to finish downloading inside Flix.' >&2
  cp "$ui_file" artifacts/emulator/movie-download-timeout.xml || true
  exit 1
fi
if ! grep -q '1 subtitle' "$ui_file"; then
  echo 'The completed offline movie does not show its English subtitle sidecar.' >&2
  exit 1
fi
adb exec-out screencap -p > artifacts/screenshots/flix-download-complete.png
echo 'Flix completed the MP4 download and saved one English subtitle track.'

# Turn off emulator networking before opening the app-private offline file.
adb shell svc wifi disable || true
adb shell svc data disable || true
sleep 2
tap_label 'Play offline'
sleep 2
wait_for_active_player 'Nosferatu' 20
adb exec-out screencap -p > artifacts/screenshots/flix-offline-player.png
echo 'Flix played the saved movie with networking disabled.'
adb shell svc wifi enable || true
adb shell svc data enable || true
