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
adb shell input tap "$((width * 28 / 100))" "$((height * 46 / 100))"
sleep 15

if ! adb shell pidof "$FLIX_PACKAGE" > artifacts/emulator/app-pid.txt; then
  echo 'Flix process exited after profile selection.' >&2
  exit 1
fi
adb shell dumpsys activity activities | grep -q "$FLIX_PACKAGE/.MainActivity"
adb exec-out screencap -p > artifacts/screenshots/flix-android-emulator.png
test -s artifacts/screenshots/flix-android-emulator.png

# Verify Clips can be selected without killing the app, then capture it
# separately from the Home screenshot used in the README.
adb shell input tap "$((width * 30 / 100))" "$((height * 93 / 100))"
sleep 4
adb shell pidof "$FLIX_PACKAGE" > artifacts/emulator/app-pid.txt
adb exec-out screencap -p > artifacts/screenshots/flix-clips-emulator.png
test -s artifacts/screenshots/flix-clips-emulator.png
adb shell input tap "$((width * 10 / 100))" "$((height * 93 / 100))"
sleep 2
adb shell pidof "$FLIX_PACKAGE" >/dev/null
adb logcat -b crash -d -v time > artifacts/emulator/crash-buffer.txt

if grep -E 'FATAL EXCEPTION|Fatal signal' artifacts/emulator/crash-buffer.txt; then
  echo 'Android crash buffer contains a fatal exception.' >&2
  exit 1
fi
