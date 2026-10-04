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

# KaspaVerse patch: the build tool runs on the dependency versions its committed
# lock names. Upstream gave this runner no lock, so a clean build directory or a
# new machine resolved the transitive versions fresh. The committed lock is copied
# in before `pub get`, which keeps its versions and checks each download against
# its sha256; a runner lock naming any other version is resolved again, and the
# build stops if pub still moves one. `--enforce-lockfile` cannot be used: the
# runner's own lock records build_tool by its absolute path.
LOCKED="$BUILD_TOOL_PKG_DIR/pubspec.lock"
lock_versions() {
  awk '/^  [^ ]+:$/ { name = $1; sub(/:$/, "", name) }
       /^    version: / { v = $2; gsub(/"/, "", v); print name " " v }' "$1"
}
unlocked() {
  if [ ! -f pubspec.lock ]; then echo "no runner lock"; return 0; fi
  lock_versions pubspec.lock | grep -v '^build_tool ' \
    | grep -vxF -f <(lock_versions "$LOCKED") || true
}
if [ -n "$(unlocked)" ]; then
    rm -f "$PACKAGE_HASH_FILE"
fi

# Run pub get if needed.
if [ ! -f "$PACKAGE_HASH_FILE" ]; then
    cp "$LOCKED" pubspec.lock
    "$DART" pub get --no-precompile
    MOVED="$(unlocked)"
    if [ -n "$MOVED" ]; then
        echo "cargokit: the build tool's dependencies left $LOCKED:" >&2
        echo "$MOVED" >&2
        exit 1
    fi
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
  "$DART" pub get --no-precompile
  "$DART" compile kernel bin/build_tool_runner.dart
  "$DART" bin/build_tool_runner.dill "$@"
  exit_code=$?
fi

exit $exit_code
