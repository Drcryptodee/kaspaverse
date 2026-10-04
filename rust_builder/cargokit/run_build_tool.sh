#!/usr/bin/env bash

set -e

BASEDIR=$(dirname "$0")

mkdir -p "$CARGOKIT_TOOL_TEMP_DIR"

cd "$CARGOKIT_TOOL_TEMP_DIR"

# Write a very simple bin package in temp folder that depends on build_tool package
# from Cargokit. This is done to ensure that we don't pollute Cargokit folder
# with .dart_tool contents.

BUILD_TOOL_PKG_DIR="$BASEDIR/build_tool"

if [[ -z $FLUTTER_ROOT ]]; then # not defined
  DART=dart
else
  DART="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
fi

cat << EOF > "pubspec.yaml"
name: build_tool_runner
version: 1.0.0
publish_to: none

environment:
  sdk: '>=3.0.0 <4.0.0'

dependencies:
  build_tool:
    path: "$BUILD_TOOL_PKG_DIR"
EOF

mkdir -p "bin"

cat << EOF > "bin/build_tool_runner.dart"
import 'package:build_tool/build_tool.dart' as build_tool;
void main(List<String> args) {
  build_tool.runMain(args);
}
EOF

# Create alias for `shasum` if it does not exist and `sha1sum` exists
if ! [ -x "$(command -v shasum)" ] && [ -x "$(command -v sha1sum)" ]; then
  shopt -s expand_aliases
  alias shasum="sha1sum"
fi

# Dart run will not cache any package that has a path dependency, which
# is the case for our build_tool_runner. So instead we precompile the package
# ourselves.
# To invalidate the cached kernel we use the hash of ls -LR of the build_tool
# package directory. This should be good enough, as the build_tool package
# itself is not meant to have any path dependencies.

if [[ "$OSTYPE" == "darwin"* ]]; then
  PACKAGE_HASH=$(ls -lTR "$BUILD_TOOL_PKG_DIR" | shasum)
else
  PACKAGE_HASH=$(ls -lR --full-time "$BUILD_TOOL_PKG_DIR" | shasum)
fi

PACKAGE_HASH_FILE=".package_hash"

if [ -f "$PACKAGE_HASH_FILE" ]; then
    EXISTING_HASH=$(cat "$PACKAGE_HASH_FILE")
    if [ "$PACKAGE_HASH" != "$EXISTING_HASH" ]; then
        rm "$PACKAGE_HASH_FILE"
    fi
fi

# KaspaVerse patch: the build tool runs on the dependencies its committed lock
# names, by name, version and content hash. Upstream gave this runner no lock, so
# a clean build directory or a new machine resolved the transitive versions fresh.
# The committed lock is copied in before `pub get`, which keeps its versions. Pub
# does not refuse a download whose hash differs from a lock (it records the new
# hash and carries on), so the check after it compares all three and stops the
# build, naming each entry that moved. `--enforce-lockfile` cannot be used: the
# runner's own lock records build_tool by its absolute path.
LOCKED="$BUILD_TOOL_PKG_DIR/pubspec.lock"
lock_entries() {
  awk '/^  [^ ]+:$/ { name = $1; sub(/:$/, "", name); sha = "" }
       /^      sha256: / { sha = $2; gsub(/"/, "", sha) }
       /^    version: / { v = $2; gsub(/"/, "", v); print name " " v " " sha }' "$1"
}
# Each runner entry the committed lock does not hold, or a line saying the two
# could not be compared. Empty means the runner is on the committed lock.
unlocked() {
  local have want rc=0
  if [ ! -f pubspec.lock ]; then echo "no runner lock"; return 0; fi
  have="$(lock_entries pubspec.lock | grep -v '^build_tool ' || true)"
  want="$(lock_entries "$LOCKED" || true)"
  if [ -z "$have" ] || [ -z "$want" ]; then echo "a lock could not be read"; return 0; fi
  printf '%s\n' "$have" | grep -vxF -f <(printf '%s\n' "$want") || rc=$?
  if [ "$rc" -gt 1 ]; then echo "the locks could not be compared"; fi
  return 0
}
resolve_locked() {
  local moved
  cp "$LOCKED" pubspec.lock
  "$DART" pub get --no-precompile || { echo "cargokit: pub get failed" >&2; exit 1; }
  moved="$(unlocked)"
  if [ -n "$moved" ]; then
    echo "cargokit: the build tool's dependencies left $LOCKED:" >&2
    echo "$moved" >&2
    exit 1
  fi
}
if [ -n "$(unlocked)" ]; then
    rm -f "$PACKAGE_HASH_FILE"
fi

# Run pub get if needed.
if [ ! -f "$PACKAGE_HASH_FILE" ]; then
    resolve_locked
    "$DART" compile kernel bin/build_tool_runner.dart
    echo "$PACKAGE_HASH" > "$PACKAGE_HASH_FILE"
fi

# Rebuild the tool if it was deleted by Android Studio
if [ ! -f "bin/build_tool_runner.dill" ]; then
  "$DART" compile kernel bin/build_tool_runner.dart
fi

set +e

"$DART" bin/build_tool_runner.dill "$@"

exit_code=$?

# 253 means invalid snapshot version.
if [ $exit_code == 253 ]; then
  resolve_locked
  "$DART" compile kernel bin/build_tool_runner.dart
  "$DART" bin/build_tool_runner.dill "$@"
  exit_code=$?
fi

exit $exit_code
