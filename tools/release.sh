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

# Published-release trigger gate (D-091, founder-ratified 2026-07-30): some parked
# work is gated on "the first build that reaches people who aren't the founder".
# This script cannot judge whether an item was dispositioned, so it SURFACES them
# at the one moment the decision is actually being made. Not a hard failure — a
# release blocked by a doc grep would get overridden, and an overridden gate is
# worse than a visible one. Marker convention + count: tools/preflight.sh.
# Self-contained token, deliberately: an earlier version required the marker and the
# words "published-release gate" to co-occur, and grep is line-based — the two sat on
# different lines of the same entry, so the gate silently matched nothing.
# The record is ops-mirror-only (D-102), so in a public clone `docs/` is absent and this
# grep matches nothing — which reads EXACTLY like "no parked work", the fail-open class
# that L76 is about. The soft-gate reasoning above ("not a hard failure") governs what to
# do about triggers that are FOUND; being unable to look at all is a different thing, and
# a release script that cannot verify its own gate must not proceed quietly.
if [ ! -d docs ]; then
  echo "ERROR: docs/ is not present, so the published-release trigger gate cannot run."
  echo "       The engineering record is ops-mirror-only (D-102) — release from a"
  echo "       working tree where docs/ exists on disk, or the gate is vacuous."
  exit 1
fi
REL_TRIGGERS="$(grep -rn '\[TRIGGER:PUBLISHED\]' docs/ 2>/dev/null \
  | grep -v 'TRIGGER-FIRED' || true)"
if [ -n "$REL_TRIGGERS" ]; then
  echo
  echo "╔══ PUBLISHED-RELEASE TRIGGER GATE (D-091) ═══════════════════════════════"
  echo "║ Parked work whose firing condition is a build that reaches OTHER PEOPLE."
  echo "║ If this artifact is such a build, each item must be repaid — or knowingly"
  echo "║ re-deferred with a DECISION_LOG entry. Proof/founder-only builds: ignore."
  # The label is whatever follows the token ON THE SAME LINE — keep entry labels
  # on the marker's own line, since grep cannot see a label that wrapped.
  printf '%s\n' "$REL_TRIGGERS" \
    | sed -E 's|^docs/||; s/:([0-9]+):.*\[TRIGGER:PUBLISHED\]`?[[:space:]]*/ (L\1)  /' \
    | cut -c1-140 | sed 's/^/║   • /'
  echo "╚═════════════════════════════════════════════════════════════════════════"
  echo
fi

# apksigner is a java wrapper, so a JDK must be reachable. Under WSL2 that meant
# a no-sudo tarball under $HOME; on native Ubuntu the system JDK is on PATH and
# this whole block is a no-op. Both lanes stay — the discovery is what lets the
# script survive a machine move (2026-08-12), not the machine survive the script.
if ! command -v java >/dev/null 2>&1; then
  if [ -z "${JAVA_HOME:-}" ]; then
    for d in "$HOME"/jdk-*/ /usr/lib/jvm/*/; do
      [ -x "${d}bin/java" ] && JAVA_HOME="${d%/}"
    done
  fi
  [ -n "${JAVA_HOME:-}" ] && export JAVA_HOME && PATH="$JAVA_HOME/bin:$PATH"
fi
command -v java >/dev/null 2>&1 || die "java not found (apksigner needs a JDK)"

# apksigner ships with SDK build-tools, which are never on PATH. Discover like
# gate.sh discovers the NDK, across every SDK root this project has used: the
# release path must not die on a layout change the gate already tolerates.
APKSIGNER="$(command -v apksigner || true)"
if [ -z "$APKSIGNER" ]; then
  for d in "${ANDROID_HOME:-/nonexistent}"/build-tools/*/ \
           "${ANDROID_SDK_ROOT:-/nonexistent}"/build-tools/*/ \
           "$HOME"/Android/Sdk/build-tools/*/ \
           "$HOME"/sdk/android/build-tools/*/; do
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
# Pin the KaspaVerse upload cert (P0.5 sweep): any OTHER signer — not just the
# debug key — fails. The fingerprint is public by nature (it ships inside every
# APK); rotation = new keystore + this line + a DECISION_LOG entry + a public
# announcement. Verification runbook: docs/RELEASE.md "Verifying provenance".
EXPECTED_CERT_SHA256="ef7ac03d67e324f9b08f372fd1b1270ae77518ce31966fdf10fb36d95d94b696"
echo "$CERTS" | grep -qi "SHA-256 digest: $EXPECTED_CERT_SHA256" \
  || die "signer cert does not match the pinned KaspaVerse upload cert — wrong keystore?"

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
