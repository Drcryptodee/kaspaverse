#!/bin/bash
# Cold-start timing ×N on the installed build: force-stop -> am start -W.
# Reports ActivityTaskManager's TotalTime (process cold start -> first frame).
command -v adb >/dev/null || export PATH="${ANDROID_HOME:-/nonexistent}/platform-tools:$HOME/sdk/android/platform-tools:$HOME/Android/Sdk/platform-tools:$PATH"
N=${1:-3}
for i in $(seq 1 $N); do
  adb shell am force-stop org.kaspaverse.app
  sleep 4
  adb shell am start -W -n org.kaspaverse.app/.MainActivity 2>/dev/null | grep -E "ThisTime|TotalTime|WaitTime"
  echo "--- run $i done"
  sleep 3
done
