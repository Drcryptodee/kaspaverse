#!/bin/bash
# Sum rx/tx bytes for org.kaspaverse.app across all idents/sets.
# The uid is resolved live — it changes on any uninstall/reinstall cycle.
# Usage: ./netstats_snap.sh <label>
#   appends "label epoch uid rx=<bytes> tx=<bytes>" to build/perf_baseline/netstats_log.txt
command -v adb >/dev/null || export PATH="${ANDROID_HOME:-/nonexistent}/platform-tools:$HOME/sdk/android/platform-tools:$HOME/Android/Sdk/platform-tools:$PATH"
UID_APP=$(adb shell dumpsys package org.kaspaverse.app | grep -m1 userId | grep -oE '[0-9]+' | head -1)
if [ -z "$UID_APP" ]; then echo "app uid not found"; exit 1; fi
mkdir -p build/perf_baseline
SNAP=$(adb shell dumpsys netstats detail full 2>/dev/null | awk -v uid="uid=$UID_APP " '
  index($0, uid) {inuid=1; next}
  /uid=/ {inuid=0}
  inuid && /st=/ {
    for (i=1;i<=NF;i++) {
      if ($i ~ /^rb=/) {sub(/rb=/,"",$i); rx+=$i}
      if ($i ~ /^tb=/) {sub(/tb=/,"",$i); tx+=$i}
    }
  }
  END {print "rx=" rx+0, "tx=" tx+0}')
echo "$1 $(date +%s) uid=$UID_APP $SNAP" >> build/perf_baseline/netstats_log.txt
tail -1 build/perf_baseline/netstats_log.txt
