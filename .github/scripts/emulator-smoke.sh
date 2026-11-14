#!/usr/bin/env bash
set -Eeuo pipefail

: "${FLIX_PACKAGE:=com.halluyapp.flix}"
mkdir -p artifacts/emulator artifacts/screenshots

logcat_pid=
cleanup() {
  status=$?
  trap - EXIT

  if [[ -n "$logcat_pid" ]]; then
    kill "$logcat_pid" 2>/dev/null || true
    wait "$logcat_pid" 2>/dev/null || true
  fi
  adb logcat -b crash -d -v time > artifacts/emulator/crash-buffer.txt 2>&1 || true
  adb shell dumpsys activity activities > artifacts/emulator/activities.txt 2>&1 || true
  adb shell dumpsys package "$FLIX_PACKAGE" > artifacts/emulator/package.txt 2>&1 || true
  exit "$status"
}
report_error() {
  status=$?
  printf 'Emulator smoke script failed at line %s (exit %s): %s\n' \
    "${BASH_LINENO[0]:-unknown}" "$status" "$BASH_COMMAND" >&2
}
trap report_error ERR
trap cleanup EXIT

adb devices -l | tee artifacts/emulator/adb-devices.txt
adb shell getprop ro.build.version.release > artifacts/emulator/android-version.txt
adb logcat -c
adb logcat -v threadtime > artifacts/emulator/logcat.txt 2>&1 &
logcat_pid=$!

echo 'Installing universal APK'
adb install -r artifacts/apk/app-release.apk
adb shell am force-stop "$FLIX_PACKAGE" || true
adb shell am start -W -n "$FLIX_PACKAGE/.MainActivity" | tee artifacts/emulator/launch.txt
sleep 4

if ! adb shell pidof "$FLIX_PACKAGE" > artifacts/emulator/app-pid.txt; then
  echo 'Flix process exited immediately after launch.' >&2
  exit 1
fi
adb exec-out screencap -p > artifacts/screenshots/flix-launch-emulator.png
test -s artifacts/screenshots/flix-launch-emulator.png

# Three default profiles wrap into rows on the Pixel 5. This point falls
# inside the first tile at common emulator screen sizes.
size=$(adb shell wm size | sed -n 's/.*Physical size: //p' | tr -d '\r')
if [[ "$size" != *x* ]]; then
  echo "Could not read emulator screen size: $size" >&2
  exit 1
fi
width=${size%x*}
height=${size#*x}

tap_window_text() {
  local label=$1
  local coordinates
  coordinates=$(python3 - "artifacts/emulator/startup-window.xml" "$label" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
label = sys.argv[2]
for node in root.iter():
    if node.get('text') != label:
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

# The emulator's Pixel Launcher has intermittently shown its own ANR dialog
# over the app. Dismiss it and explicitly choose the existing Kids profile.
main_screen_ready=false
for attempt in {1..30}; do
  adb shell uiautomator dump /sdcard/flix-startup-window.xml >/dev/null 2>&1 || true
  adb pull /sdcard/flix-startup-window.xml artifacts/emulator/startup-window.xml >/dev/null 2>&1 || true
  if grep -q "Pixel Launcher isn't responding" artifacts/emulator/startup-window.xml; then
    tap_window_text 'Wait' || true
    sleep 3
    continue
  fi
  if grep -q "Who's Watching" artifacts/emulator/startup-window.xml; then
    if ! tap_window_text 'Kids'; then
      adb shell input tap "$((width * 28 / 100))" "$((height * 46 / 100))"
    fi
    sleep 3
    continue
  fi
  if grep -q 'Tab 1 of 5' artifacts/emulator/startup-window.xml; then
    main_screen_ready=true
    break
  fi
  sleep 2
done

if ! adb shell pidof "$FLIX_PACKAGE" > artifacts/emulator/app-pid.txt; then
  echo 'Flix process exited during startup/profile selection.' >&2
  exit 1
fi
if [[ "$main_screen_ready" != true ]]; then
  echo 'Flix did not reach its main navigation after selecting the test profile.' >&2
  exit 1
fi
adb shell dumpsys activity activities | grep -q "$FLIX_PACKAGE/.MainActivity"
adb exec-out screencap -p > artifacts/screenshots/flix-android-emulator.png
test -s artifacts/screenshots/flix-android-emulator.png

home_catalogue_ready=false
for attempt in {1..30}; do
  adb shell uiautomator dump /sdcard/flix-home-window.xml >/dev/null 2>&1 || true
  adb pull /sdcard/flix-home-window.xml artifacts/emulator/home-window.xml >/dev/null 2>&1 || true
  if grep -q 'SUPABASE' artifacts/emulator/home-window.xml; then
    home_catalogue_ready=true
    break
  fi
  if grep -q "Pixel Launcher isn't responding" artifacts/emulator/home-window.xml; then
    cp artifacts/emulator/home-window.xml artifacts/emulator/launcher-anr-window.xml
    cp artifacts/emulator/home-window.xml artifacts/emulator/startup-window.xml
    tap_window_text 'Wait' || true
  fi
  sleep 2
done
if [[ "$home_catalogue_ready" == true ]]; then
  echo 'Home UI confirms a successful Supabase TMDB Edge Function response.'
else
  echo 'Home did not show the optional Supabase status badge before timeout; continuing to the direct media test.' >&2
fi

# Verify Clips can be selected without killing the app, then capture it
# separately from the Home screenshot used in the README.
adb shell input tap "$((width * 30 / 100))" "$((height * 93 / 100))"
sleep 4
adb shell pidof "$FLIX_PACKAGE" > artifacts/emulator/app-pid.txt
feed_source_confirmed=false
for attempt in {1..8}; do
  adb shell uiautomator dump /sdcard/flix-clips-window.xml >/dev/null
  adb pull /sdcard/flix-clips-window.xml artifacts/emulator/clips-window.xml >/dev/null
  if grep -q 'Clips catalogue source: DIRECT PROVIDER FALLBACK' artifacts/emulator/clips-window.xml; then
    feed_source_confirmed=true
    break
  fi
  sleep 2
done
if [[ "$feed_source_confirmed" != true ]]; then
  echo 'Clips did not report the active direct-provider fallback source.' >&2
  exit 1
fi
echo 'Clips UI confirms the active direct-provider fallback source.'
adb exec-out screencap -p > artifacts/screenshots/flix-clips-emulator.png
test -s artifacts/screenshots/flix-clips-emulator.png

# Exercise each deferred destination once, because the former IndexedStack
# constructed every data-heavy tab during Home startup and could overwhelm
# lower-memory Android devices.
for tab_x in 50 70 90; do
  adb shell input tap "$((width * tab_x / 100))" "$((height * 93 / 100))"
  sleep 3
  if ! adb shell pidof "$FLIX_PACKAGE" > artifacts/emulator/app-pid.txt; then
    echo "Flix process exited after opening bottom-navigation tab at ${tab_x}%." >&2
    exit 1
  fi
done

adb shell input tap "$((width * 10 / 100))" "$((height * 93 / 100))"
sleep 2
adb shell pidof "$FLIX_PACKAGE" >/dev/null

bash .github/scripts/media-smoke.sh

adb logcat -b crash -d -v time > artifacts/emulator/crash-buffer.txt

if grep -E 'FATAL EXCEPTION|Fatal signal' artifacts/emulator/crash-buffer.txt; then
  echo 'Android crash buffer contains a fatal exception.' >&2
  exit 1
fi
