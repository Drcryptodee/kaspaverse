#!/usr/bin/env bash
# Tagged-commit release build (P0.5 — INV-11: every released APK is signed,
# built from a tagged commit, published with checksums).
#
# Flow: clean-tree + exact-tag assert → flutter build apk --release →
# verify the APK's ACTUAL signer (config can lie; the artifact can't) →
# emit artifact + SHA-256 + build provenance into dist/ (gitignored).
#
# Releases are founder-owned: this script produces a release-shaped artifact;
# publishing it (and pushing the tag) happens from the founder's terminal.
# Setup (one-time keystore + key.properties): docs/RELEASE.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

die() { echo "release: $*" >&2; exit 1; }

# ── Preconditions ───────────────────────────────────────────────
[ -z "$(git status --porcelain)" ] \
  || die "working tree is dirty — a release builds a committed state only"
TAG="$(git describe --tags --exact-match HEAD 2>/dev/null)" \
  || die "HEAD is not tagged — tag the release commit first (git tag <tag>)"
COMMIT="$(git rev-parse --short HEAD)"
[ -f android/key.properties ] \
  || die "android/key.properties missing — see docs/RELEASE.md (the build would fall back to the unshippable debug key)"

# apksigner is a java wrapper, and on this machine the JDK lives in $HOME off
# PATH (no-sudo WSL2 install, environment.local.md) — discover it like gate.sh
# discovers the NDK.
if ! command -v java >/dev/null 2>&1; then
  if [ -z "${JAVA_HOME:-}" ]; then
    for d in "$HOME"/jdk-*/; do
      [ -x "${d}bin/java" ] && JAVA_HOME="${d%/}"
    done
  fi
  [ -n "${JAVA_HOME:-}" ] && export JAVA_HOME && PATH="$JAVA_HOME/bin:$PATH"
fi
command -v java >/dev/null 2>&1 || die "java not found (apksigner needs a JDK)"

# apksigner ships with SDK build-tools; discover like gate.sh discovers the NDK.
APKSIGNER="$(command -v apksigner || true)"
if [ -z "$APKSIGNER" ]; then
  for d in "$HOME"/Android/Sdk/build-tools/*/; do
    [ -x "${d}apksigner" ] && APKSIGNER="${d}apksigner"
  done
fi
[ -n "${APKSIGNER:-}" ] || die "apksigner not found (Android SDK build-tools)"

# ── Build ───────────────────────────────────────────────────────
echo "── release: building $TAG ($COMMIT) — arm64-v8a, release profile"
# Pin the platform set: flutter's release default is arm+arm64+x64, and
# cargokit compiles EVERY requested platform — abiFilters only governs
# packaging, it does not trim cargokit's build matrix. kaspa-hashes can't
# build x86_64-android at the pinned rev (L18/L25), so an unpinned release
# build dies mid-compile after minutes of wasted armv7 work.
flutter build apk --release --target-platform android-arm64

APK="build/app/outputs/flutter-apk/app-release.apk"
[ -f "$APK" ] || die "expected output missing: $APK"

# ── Verify the artifact's signer, not the config ────────────────
CERTS="$("$APKSIGNER" verify --print-certs "$APK")" \
  || die "apksigner rejected the APK (unsigned or invalid signature)"
echo "$CERTS" | grep -q "CN=Android Debug" \
  && die "APK is DEBUG-SIGNED — key.properties was not applied; see docs/RELEASE.md"

# ── Emit artifact + checksum + provenance ───────────────────────
mkdir -p dist
OUT="kaspaverse-$TAG-arm64-v8a.apk"
cp "$APK" "dist/$OUT"
(cd dist && sha256sum "$OUT" > "$OUT.sha256")
{
  echo "tag:     $TAG"
  echo "commit:  $(git rev-parse HEAD)"
  echo "flutter: $(flutter --version | head -1)"
  echo "rustc:   $(rustc -V)"
  echo "signer:"
  echo "$CERTS" | grep -E "certificate (DN|SHA-256)" | sed 's/^/  /'
} > "dist/$OUT.buildinfo"

echo
echo "══════════ RELEASE ARTIFACT ══════════"
cat "dist/$OUT.buildinfo"
echo "checksum: $(cat "dist/$OUT.sha256")"
echo "──────────────────────────────────────"
echo "verify:   (cd dist && sha256sum -c $OUT.sha256)"
echo "RELEASE: OK — dist/$OUT (publishing is founder-owned; nothing ships from here)"
