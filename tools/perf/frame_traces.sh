#!/usr/bin/env bash
# Frame traces on the device: the integration_test perf harness, run against
# the .dev package only.
#
# flutter drive resolves the app's package before it builds: from the APK at
# build/app/outputs/flutter-apk/app-profile.apk when one is there, else from
# the Gradle namespace, and either can be the funded package. Its first launch
# re-reads the package from the APK it built, but a failed launch is retried
# with the package resolved before the build, and when that reinstall fails,
# Flutter uninstalls the package it names (Flutter 3.41.5, drive_service.dart
# and android_device.dart installApp). An uninstall destroys the Keystore key
# the wallet is sealed to.
#
# So the harness is built first as the .dev package and copied where no other
# build writes; the copy's own package must read org.kaspaverse.app.dev, and
# drive is handed that copy, which fixes the package for every attempt.
# --keep-app-running keeps drive's teardown from uninstalling the app when the
# run ends. KV_DEV_INSTALL stays set for drive too, in case it rebuilds.
#
# Usage: tools/perf/frame_traces.sh <device-serial>
# Exit: drive's own status; 1 when the build fails, aapt2 is missing, or the
# APK is not the .dev package (nothing is installed then).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

device="${1:-}"
if [ -z "$device" ]; then
  echo "usage: tools/perf/frame_traces.sh <device-serial>"
  exit 1
fi
target=integration_test/perf_baseline_test.dart
want=org.kaspaverse.app.dev
built=build/app/outputs/flutter-apk/app-profile.apk
apk=build/perf_harness/perf-harness-dev.apk

aapt2=""
for d in "${ANDROID_HOME:-/nonexistent}"/build-tools/*/ \
         "${ANDROID_SDK_ROOT:-/nonexistent}"/build-tools/*/ \
         "$HOME"/Android/Sdk/build-tools/*/ \
         "$HOME"/sdk/android/build-tools/*/; do
  [ -x "${d}aapt2" ] && aapt2="${d}aapt2"
done
if [ -z "$aapt2" ]; then
  echo "frame_traces: aapt2 not found (Android SDK build-tools), so the APK's package cannot be read"
  exit 1
fi

KV_DEV_INSTALL=1 flutter build apk --profile --target-platform android-arm64 \
  --target="$target" || exit 1
mkdir -p "$(dirname "$apk")" && cp "$built" "$apk" || exit 1
pkg="$("$aapt2" dump packagename "$apk" 2>/dev/null)"
if [ "$pkg" != "$want" ]; then
  echo "frame_traces: the harness APK is ${pkg:-unreadable}, not $want; nothing was installed"
  exit 1
fi

KV_DEV_INSTALL=1 flutter drive --profile --no-dds --keep-app-running \
  --driver=test_driver/perf_driver.dart \
  --target="$target" \
  --use-application-binary="$apk" \
  -d "$device"
