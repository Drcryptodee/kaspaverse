#!/usr/bin/env bash
# Was the shipped native library compiled by the pinned Rust toolchain? (INV-7)
#
# The library carries two witnesses of the compiler that built it:
#   1. its `.comment` section, where rustc records "rustc version X.Y.Z (hash date)";
#   2. the standard library's source paths, "/rustc/<commit>/library/...", which
#      hold the compiler's full 40-character commit hash.
# Both are compared against the toolchain rust/rust-toolchain.toml pins. The
# pinned side is resolved by rustup rather than spelled out here: the channel is
# read from the toolchain file, and `rustup run <channel> rustc -vV` reports its
# version string and commit.
#
# Usage: tools/shipped_toolchain.sh [APK]   check APK (default: the newest APK
#                                           under build/app/outputs)
#        tools/shipped_toolchain.sh --pin   print the pinned channel
# Exit:  0 every bridge library in the APK was built by the pin
#        1 a mismatch, or the APK or the pin cannot be read
#        3 no APK to check
#        4 a tool this check needs is missing (unzip, readelf, strings, rustup,
#          or the pinned toolchain itself)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN_FILE="$ROOT/rust/rust-toolchain.toml"
LIB="libkaspaverse_bridge.so"

# The channel line of the toolchain file, in either TOML string quoting. Exactly
# one channel, and an exact X.Y.Z version: anything else is not a pin.
pinned_channel() {
  local lines channel
  [ -f "$TOOLCHAIN_FILE" ] || { echo "no toolchain file at rust/rust-toolchain.toml" >&2; return 1; }
  lines="$(sed -n "s/^[[:space:]]*channel[[:space:]]*=[[:space:]]*[\"']\([^\"']*\)[\"'][[:space:]]*\(#.*\)\{0,1\}$/\1/p" "$TOOLCHAIN_FILE")"
  if [ "$(printf '%s' "$lines" | grep -c '')" -ne 1 ]; then
    echo "rust/rust-toolchain.toml: expected one readable channel line, found $(printf '%s' "$lines" | grep -c '')" >&2
    return 1
  fi
  channel="$lines"
  if ! printf '%s' "$channel" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "rust/rust-toolchain.toml: channel \"$channel\" is not an exact X.Y.Z version" >&2
    return 1
  fi
  printf '%s\n' "$channel"
}

if [ "${1:-}" = "--pin" ]; then
  pinned_channel || exit 1
  exit 0
fi

for tool in unzip readelf strings rustup sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "   $tool not found"; exit 4; }
done

channel="$(pinned_channel)" || exit 1
if ! vv="$(rustup run "$channel" rustc -vV 2>/dev/null)"; then
  echo "   the pinned toolchain $channel is not installed (rustup toolchain install $channel)"
  exit 4
fi
release="$(printf '%s\n' "$vv" | sed -n 's/^release: //p')"
commit="$(printf '%s\n' "$vv" | sed -n 's/^commit-hash: //p')"
version="$(printf '%s\n' "$vv" | sed -n '1s/^rustc //p')"
if [ "$release" != "$channel" ] || ! printf '%s' "$commit" | grep -Eq '^[0-9a-f]{40}$' || [ -z "$version" ]; then
  echo "   rustup's $channel reports release '$release', commit '$commit': cannot resolve the pin's identity"
  exit 1
fi
want_comment="rustc version $version"
want_path="/rustc/$commit/"

apk="${1:-}"
if [ -z "$apk" ]; then
  apk="$(find "$ROOT/build/app/outputs" -type f -name '*.apk' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -1 | cut -d' ' -f2-)"
  if [ -z "$apk" ]; then
    echo "   no APK under build/app/outputs"
    exit 3
  fi
fi
[ -f "$apk" ] || { echo "   $apk does not exist"; exit 1; }

echo "   apk:    ${apk#"$ROOT"/} ($(date -r "$apk" '+%Y-%m-%d %H:%M'), sha256 $(sha256sum "$apk" | cut -c1-16)…)"
echo "   pinned: $want_comment, std $want_path"

mapfile -t entries < <(unzip -Z1 "$apk" 2>/dev/null | grep -E "^lib/[^/]+/$LIB\$")
if [ "${#entries[@]}" -eq 0 ]; then
  echo "   no lib/*/$LIB inside the APK: nothing this check can read"
  exit 1
fi

tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT
rc=0
for entry in "${entries[@]}"; do
  so="$tmp/lib.so"
  if ! unzip -p "$apk" "$entry" > "$so" 2>/dev/null || [ ! -s "$so" ]; then
    echo "   $entry: could not be extracted"
    rc=1; continue
  fi
  # Witness 1: every rustc line in .comment is the pinned version string.
  mapfile -t comments < <(readelf -p .comment "$so" 2>/dev/null \
    | sed -n 's/.*\(rustc version [^)]*)\).*/\1/p' | sort -u)
  if [ "${#comments[@]}" -eq 0 ]; then
    echo "   $entry: .comment names no rustc, so the compiler cannot be read"
    rc=1
  else
    for c in "${comments[@]}"; do
      if [ "$c" = "$want_comment" ]; then
        echo "   $entry: .comment  $c"
      else
        echo "   $entry: .comment  $c   ← NOT the pinned toolchain"
        rc=1
      fi
    done
  fi
  # Witness 2: every standard-library source path names the pinned commit.
  mapfile -t paths < <(strings -a "$so" | grep -oE '/rustc/[0-9a-f]{40}/' | sort -u)
  if [ "${#paths[@]}" -eq 0 ]; then
    echo "   $entry: no /rustc/<commit>/ source path, so the commit cannot be read"
    rc=1
  else
    for p in "${paths[@]}"; do
      if [ "$p" = "$want_path" ]; then
        echo "   $entry: std path  $p"
      else
        echo "   $entry: std path  $p   ← NOT the pinned toolchain"
        rc=1
      fi
    done
  fi
done
exit "$rc"
