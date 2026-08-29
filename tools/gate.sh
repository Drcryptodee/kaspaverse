#!/usr/bin/env bash
# The proof gate — the only arbiter of "done" (INV-10).
# Phase-aware: checks every component that exists; grows monotonically (checks are
# added at phase entry, never removed without a DECISION_LOG entry).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Defined HERE, not beside its first user: TWO lanes now read the ops index — the
# secret-shaped-path half of `public-repo hygiene` (L96 rider 2) and `repo-path
# resolution` — and `set -u` turns a definition that sits below its first reader into
# an unbound-variable abort mid-run, which is a gate that stops rather than reports.
OPS_GIT_DIR="${KASPAVERSE_OPS_GIT_DIR:-$HOME/.kaspaverse-ops.git}"
PASS=0; FAIL=0; SKIP=0; WARN=0
declare -a RESULTS
# Every lane that emitted a row, by name. The summary asserts this against the
# roster below: the gate proves what ran by SUMMING what ran, so a lane that
# produces no row at all reads as agreement rather than as a hole.
declare -A SEEN=()
declare -a EXPECTED=()
expect_lane() { EXPECTED+=("$1"); }

# Every non-zero exit is a FAIL. No exceptions here — see run_check_warnable.
run_check() { # name, command...
  local name="$1"; shift
  SEEN["$name"]=1
  echo "── gate: $name"
  if "$@"; then RESULTS+=("PASS  $name"); PASS=$((PASS+1));
  else RESULTS+=("FAIL  $name"); FAIL=$((FAIL+1)); fi
}

# The WARN tier, opt-in per check. Exit 2 = WARN (the check appended its own row
# and explained itself); everything else behaves like run_check.
#
# It exists because there wasn't one: `toolchain_pins` appended a WARN row and
# then `return 0`, so run_check appended a PASS row too and incremented PASS —
# the machine-readable verdict, the line INV-10 makes the proof artifact,
# counted a drifted toolchain as a passed check (product-audit run 1, F17).
#
# **Opt-in, never inferred from the exit code**, and this is the whole point:
# exit 2 is not a private signal. `cargo deny check` returns a BITFLAG, one bit
# per failing check — a bans-only failure is exactly 2, and `[bans] wildcards`
# is the machine half of L23 (a git dep whose missing `version` reads as `*`).
# Applied to every check, this tier would have turned that INV-7 failure into
# GATE: GREEN with exit 0. clap exits 2 on any usage error too, so a future typo
# in a gate flag would have gone the same way. Only a check that KNOWS what its
# own 2 means may use this (dependency-steward, run-1 fix wave).
run_check_warnable() { # name, command...
  local name="$1"; shift
  local rc
  # Recorded here, not per-branch: on the WARN path the check appends a row under
  # its OWN wording, so keying the roster off the printed row would miss it.
  SEEN["$name"]=1
  echo "── gate: $name"
  if "$@"; then rc=0; else rc=$?; fi
  case "$rc" in
    0) RESULTS+=("PASS  $name"); PASS=$((PASS+1)) ;;
    2) WARN=$((WARN+1)) ;; # the check appended its own WARN row
    *) RESULTS+=("FAIL  $name"); FAIL=$((FAIL+1)) ;;
  esac
}
skip_check() { SEEN["$1"]=1; RESULTS+=("SKIP  $1 ($2)"); SKIP=$((SKIP+1)); }

# ── The expected-lane roster (product-audit run 2: F2/F9/S4-11/S4-54) ──
# Four separate findings, one shape. `GATE_STRICT` reds on SKIP > 0 — so it
# catches a lane that ran and reported "I could not run", and is blind to a lane
# that never reported at all. Every one of the four evaded it the same way, by
# failing BEFORE it could emit a row:
#
#   kotlin compile  — its skip_check sat INSIDE `if [ -f android/gradlew ]`, and
#                     the wrapper was gitignored. CI ran pass=13, and `grep -c
#                     kotlin` over the whole 845 KB job log returned 0. The lane
#                     added because GREEN had never been evidence about the
#                     custody platform layer had never run in CI either.
#   contract spine  — guarded by `contracts/*/SPEC.md`, the artifact it exists to
#                     require, and appended no row on success. Deleting STATES.md
#                     gave FAIL=1; deleting SPEC.md TOO gave FAIL=0.
#   dart format     — enumerated `lib test` only, and emitted nothing when the
#                     list came back empty.
#   internal-record — its pathspec was hand-written, so a file added beside the
#                     root router sits outside the boundary it claims to enforce.
#
# The roster is the general fix: name the lanes this tree must produce a row for,
# and let the summary FAIL on any that produced none. Absence becomes a finding.
#
# Predicates here read TRACKED ARTIFACTS ONLY, never tool presence — that is the
# whole point. A missing tool must produce a SKIP row (visible, RED in strict
# mode); a missing tool must never be able to delete the lane from the roster,
# or the roster inherits the bug it was written to catch.
if [ -f "$ROOT/rust/Cargo.toml" ]; then
  expect_lane "cargo fmt";           expect_lane "cargo clippy"
  expect_lane "cargo test";          expect_lane "cargo deny (INV-7)"
  expect_lane "android cross-compile"
  # Guarded on the vendored manifest, a TRACKED artifact — the lane must appear
  # the day the vendored dialer does and vanish the day it is deleted (D-217's
  # deletion trigger), never because a tool is missing.
  [ -f "$ROOT/rust/vendor/tokio-tungstenite/Cargo.toml" ] && expect_lane "vendored dialer (D-217)"
else
  expect_lane "rust workspace"
fi
if [ -f "$ROOT/pubspec.yaml" ]; then
  expect_lane "dart format"; expect_lane "flutter analyze"; expect_lane "flutter test"
else
  expect_lane "flutter app"
fi
[ -f "$ROOT/android/build.gradle.kts" ] && expect_lane "kotlin compile (custody platform layer)"
[ -f "$ROOT/android/build.gradle.kts" ] && expect_lane "android lint (NewApi — custody platform layer)"
[ -f "$ROOT/android/gradle/wrapper/gradle-wrapper.properties" ] && expect_lane "gradle wrapper (INV-7)"
# Guarded on build.gradle.kts, NOT on verification-metadata.xml: guarding a lane on
# the artifact it asserts is how the lane disappears exactly when that artifact does
# (F9's shape, and the wrapper lane's own comment says the same). A deleted
# verification file must RED, not vanish.
[ -f "$ROOT/android/build.gradle.kts" ] && expect_lane "gradle dependency verification (INV-7)"
[ -f "$ROOT/flutter_rust_bridge.yaml" ] && expect_lane "codegen drift (lib/src/rust/ + frb_generated.rs)"
expect_lane "contract spine"
expect_lane "race fan-out exponent (L135)"
# Mirrors this lane's own guard exactly. A roster entry that is stricter than the
# lane it names is not extra rigour — it is a spurious RED in a scaffold tree, and
# a spuriously red check is how a real check earns a `git rm` from the ledger.
{ [ -f "$ROOT/rust/rust-toolchain.toml" ] || [ -f "$ROOT/.github/workflows/gate.yml" ]; } \
  && expect_lane "toolchain pins (D-024)"
expect_lane "public-repo hygiene (no tracked secrets)"
expect_lane "internal-record boundary (D-102)"
expect_lane "internal-record pointers (D-102 / L88)"
expect_lane "repo-path resolution (L88 / F48)"

# ── Rust workspace ──────────────────────────────────────────────
if [ -f "$ROOT/rust/Cargo.toml" ]; then
  cd "$ROOT/rust"
  run_check "cargo fmt"    cargo fmt --all --check
  run_check "cargo clippy" cargo clippy --workspace --all-targets -- -D warnings
  # BOUNDED, and the bound is the check (F47, product-audit run 3 fix wave).
  # `cargo test` has no per-test timeout: a test that blocks forever blocks the
  # gate forever, and the gate is the only arbiter of "done" — so a hang is not a
  # slow run, it is an INV-10 proof that can never arrive. It happened: the chain
  # crate's suite blocked on an unbounded teardown in a test whose own subject
  # spins a re-dial every ~175 ms, reproducibly, but ONLY under the full parallel
  # load of the whole binary. Three orphaned test binaries were found alive on the
  # dev box, aged 4h46m and 18h32m, each parked on a futex.
  #
  # This does not weaken a check — it converts an infinite wait into a RED. The
  # whole workspace runs in well under a minute today (the chain crate alone: 0.72 s
  # after the F47 fix), so 600 s is roughly a 60x headroom: it cannot red a merely
  # slow machine, and it cannot fail to red a hang.
  cargo_tests() { timeout 600 cargo test --workspace; }
  run_check "cargo test"   cargo_tests
  # ── The vendored dialer (D-217) ────────────────────────────────────────────
  # It is deliberately NOT a workspace member (see rust/Cargo.toml's `exclude`),
  # so EVERY other Rust lane is blind to it: `cargo test --workspace` does not run
  # its tests and `clippy --workspace` does not read it. A patch to the one
  # function the wallet's only path to consensus goes through cannot also be the
  # one piece of code nothing checks.
  #
  # Runs AFTER `cargo deny` on purpose: the advisory tripwire below reads the
  # RustSec database that cargo-deny fetches, so on a cold CI machine this lane
  # must not be the one to look for it first.
  #
  # What it does NOT claim: this is not cargo-deny for the vendored crate.
  # `cargo deny check advisories` cannot see a `[patch.crates-io]` path crate at
  # all (measured — an identical crate at an identical version reports its
  # advisories from the registry and reports `advisories ok` behind a path
  # patch), so vendoring removed tokio-tungstenite from the advisory sweep. The
  # tripwire is the compensation, and it is deliberately blunt: any advisory file
  # for the crate reds the gate and a human checks it against 0.23.1.
  #
  # CARGO_TARGET_DIR is forced out of the vendored tree — a target/ directory
  # nested there would be committed into the copy whose whole value is being
  # verbatim (L24).
  if [ -f "$ROOT/rust/vendor/tokio-tungstenite/Cargo.toml" ]; then
    vendored_dialer() {
      local dir="$ROOT/rust/vendor/tokio-tungstenite"
      local rec="$ROOT/rust/vendor/PROVENANCE.md"
      local rc=0 checked=0 want file marker got
      # (a) every VERBATIM file still matches the published crate. Fail CLOSED: a
      #     manifest that cannot be read, or reads short, is a finding (PB-029).
      while read -r want file marker; do
        [ -n "$marker" ] && continue   # the two files D-217 deliberately patched
        got="$(sha256sum "$dir/$file" 2>/dev/null | cut -d' ' -f1)"
        if [ "$got" != "$want" ]; then
          echo "   DRIFT: $file no longer matches the published crate"
          rc=1
        fi
        checked=$((checked+1))
      done < <(grep -E '^[0-9a-f]{64}  ' "$rec")
      if [ "$checked" -ne 20 ]; then
        echo "   PROVENANCE.md listed $checked verbatim files, expected 20 — the record moved"
        rc=1
      fi
      # (b) our OWN two files still hash to what the record says they do.
      while read -r _tag want file; do
        got="$(sha256sum "$dir/$file" 2>/dev/null | cut -d' ' -f1)"
        if [ "$got" != "$want" ]; then
          echo "   DRIFT: $file changed without its PROVENANCE.md anchor being updated"
          rc=1
        fi
      done < <(grep -E '^PATCHED  [0-9a-f]{64}  ' "$rec")
      # (c) NOTHING WAS ADDED. Hashing only what the record lists cannot see a new
      #     file, and cargo auto-detects and EXECUTES a build.rs that upstream
      #     0.23.1 does not have — so "verbatim" has to mean the file set too.
      local listed actual
      listed="$(awk '/^[0-9a-f]{64}  /{print $2}' "$rec" | sort)"
      actual="$(cd "$dir" && find . -type f -not -path './target/*' | sed 's|^\./||' | sort)"
      if [ "$listed" != "$actual" ]; then
        echo "   FILE-SET DRIFT: the vendored tree is not the tarball's 22 files"
        diff <(echo "$listed") <(echo "$actual") | sed 's/^/     /'
        rc=1
      fi
      # (d) advisory tripwire, with a control — a zero from a lookup that cannot
      #     look is not evidence of absence (L106).
      local db
      db="$(ls -d "$HOME"/.cargo/advisory-dbs/*/crates 2>/dev/null | head -1)"
      if [ -z "$db" ]; then
        echo "   advisory DB absent — cannot check the vendored crate; cargo-deny never ran"
        rc=1
      elif [ ! -d "$db/atty" ]; then
        echo "   advisory DB present but the control crate (atty) is missing — lookup broken, not clean"
        rc=1
      elif [ -d "$db/tokio-tungstenite" ]; then
        echo "   ADVISORY against the vendored crate: $(ls "$db/tokio-tungstenite" | tr '\n' ' ')"
        echo "   cargo-deny cannot see path-patched crates — check it against 0.23.1 BY HAND"
        rc=1
      else
        # A readable DB is not a CURRENT one, and "no advisory" from a stale DB is
        # the same false comfort the control above exists to prevent. cargo-deny
        # has a skip_check branch (not installed), and on that path nothing
        # refreshes this — so freshness is asserted, not assumed from ordering.
        # DERIVED from $db, never globbed independently: advisory-dbs/ holds one
        # clone per DB URL, so two independent `head -1` picks can land on
        # different clones and let a fresh sibling vouch for the stale DB that was
        # actually queried — the very "lookup that cannot look" this lane's
        # control exists to prevent.
        local fh
        fh="$(dirname "$db")/.git/FETCH_HEAD"
        if [ ! -f "$fh" ]; then
          echo "   advisory DB has no FETCH_HEAD — its freshness cannot be established"
          rc=1
        elif [ -n "$(find "$fh" -mtime +7 2>/dev/null)" ]; then
          echo "   advisory DB last fetched $(date -r "$fh" '+%Y-%m-%d') — >7 days stale;"
          echo "   its silence about tokio-tungstenite is not evidence. Run: cargo deny check advisories"
          rc=1
        fi
      fi
      [ "$rc" -eq 0 ] || return 1
      CARGO_TARGET_DIR="$ROOT/rust/target/vendor-tests" \
        timeout 300 cargo test --locked --lib --manifest-path "$dir/Cargo.toml"
    }
  fi
  if command -v cargo-deny >/dev/null 2>&1; then
    run_check "cargo deny (INV-7)" cargo deny check
  else
    skip_check "cargo deny (INV-7)" "cargo-deny not installed — REQUIRED from P0-D4"
  fi
  # Ordered after cargo deny: lane (d) reads the DB cargo-deny fetches.
  if [ -f "$ROOT/rust/vendor/tokio-tungstenite/Cargo.toml" ]; then
    run_check "vendored dialer (D-217)" vendored_dialer
  fi
  # cargo-ndk needs an NDK; discover a local install when the env var is unset.
  # Layout-agnostic on purpose. This list used to name two paths from one machine,
  # and when the SDK root moved (WSL2 `~/Android/Sdk` → native `~/sdk/android`,
  # 2026-08-12) the cross-compile check did not go RED — it went SKIP, which reads
  # as "fine" on a local run. A discovery list that only knows the last machine
  # converts a real check into silence; prefer the env vars the SDK itself sets.
  if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    for d in "$HOME"/android-ndk-r* \
             "${ANDROID_HOME:-/nonexistent}"/ndk/* \
             "${ANDROID_SDK_ROOT:-/nonexistent}"/ndk/* \
             "$HOME"/Android/Sdk/ndk/* \
             "$HOME"/sdk/android/ndk/*; do
      [ -d "$d" ] && export ANDROID_NDK_HOME="$d"
    done
  fi
  if command -v cargo-ndk >/dev/null 2>&1; then
    run_check "android cross-compile" cargo ndk -t arm64-v8a build --workspace
  else
    skip_check "android cross-compile" "cargo-ndk not installed — REQUIRED from P0-D1"
  fi
  cd "$ROOT"
else
  skip_check "rust workspace" "rust/Cargo.toml absent (pre-P0-D1 scaffold state)"
fi

# ── Flutter app ─────────────────────────────────────────────────
if [ -f "$ROOT/pubspec.yaml" ]; then
  cd "$ROOT"
  # Hand-written Dart only — generated bindings (lib/src/rust/) are formatted
  # by FRB codegen and vendored cargokit is excluded like in analysis_options.
  # Enumerated by find, not a hardcoded dir list: a future lib/ subdir must not
  # silently escape the check (P0-close audit, 2026-06-12).
  #
  # The dir list was the hardcoding (S4-11). `find lib test` honoured the letter
  # of that intent and missed two tracked, hand-written files that live beside
  # them — `integration_test/perf_baseline_test.dart` and
  # `test_driver/perf_driver.dart`, BOTH of which were in fact unformatted when
  # this was measured. Enumerate the tree and subtract what is generated,
  # vendored, or built, so a new top-level Dart dir is covered on the day it
  # appears rather than the day someone remembers to add it here.
  mapfile -t dart_format_files < <(cd "$ROOT" && find . -name '*.dart' \
    -not -path './lib/src/rust/*' \
    -not -path './rust_builder/cargokit/*' \
    -not -path './build/*' \
    -not -path './.dart_tool/*' \
    -not -path './android/*' \
    -not -path './ios/*' \
    -not -path './linux/*' \
    -not -path './macos/*' \
    -not -path './windows/*' \
    -not -path './web/*' \
    2>/dev/null | sed 's|^\./||' | sort)
  if [ "${#dart_format_files[@]}" -gt 0 ]; then
    run_check "dart format" dart format --output=none --set-exit-if-changed "${dart_format_files[@]}"
  else
    # A row, not silence: an empty list in a tree with a pubspec.yaml means the
    # enumeration broke, which is exactly the absence the roster exists to catch.
    skip_check "dart format" "no hand-written Dart found — enumeration suspect"
  fi
  run_check "flutter analyze" flutter analyze
  if [ -d "$ROOT/test" ] && [ -n "$(ls -A "$ROOT/test" 2>/dev/null)" ]; then
    run_check "flutter test" flutter test
  else
    skip_check "flutter test" "no tests yet"
  fi
else
  skip_check "flutter app" "pubspec.yaml absent (pre-P0-D1 scaffold state)"
fi

# ── The wrapper jar itself (INV-7) ──────────────────────────────
# Tracking the wrapper made the lane above runnable from a clean clone, and put a
# binary on the build path in exchange. This is the other half of that trade: the
# jar is pinned to the checksum Gradle publishes for this exact version, so the
# blob in the tree is an asserted artifact rather than a trusted one.
#
# Both constants together, deliberately. The jar found here in run 2 was genuine
# Gradle 2.10 (it matches Gradle's own gradle-2.10-wrapper.jar.sha256) bootstrapping
# an 8.14 distribution — a 2015 artifact left by the Flutter scaffold while the
# distribution pin moved on without it. Nothing was tampered with and the
# `distributionSha256Sum` pin was genuinely honoured; the jar was simply never
# chosen by anyone. Pinning the jar's checksum ALONE would let that recur silently,
# so the lane also asserts the distribution still names the version this checksum
# belongs to. Bumping Gradle now has to move both lines, in one edit, on purpose.
#
# Re-derive after a bump with the published value, which anyone can check:
#   curl -sSL https://services.gradle.org/distributions/gradle-<version>-wrapper.jar.sha256
GRADLE_PINNED_VERSION="8.14"
GRADLE_WRAPPER_JAR_SHA256="7d3a4ac4de1c32b59bc6a4eb8ecb8e612ccd0cf1ae1e99f66902da64df296172"
# The pin on what actually EXECUTES. The jar is 44 KB of bootstrapper; this is the
# ~200 MB that compiles KeystoreVault.kt. Asserting the bootstrapper and leaving the
# payload's pin to a comment would guard the smaller half (dependency-steward, Wave A).
GRADLE_DIST_SHA256="efe9a3d147d948d7528a9887fa35abcf24ca1a43ad06439996490f77569b02d1"
# The launcher scripts, pinned for the same reason as the jar and initially missed:
# D-153's rule is "a binary on the build path is asserted, not trusted", and `gradlew`
# is what actually INVOKES that binary — for this lane and for every `flutter build
# apk`. It is 0755 and it is plain shell, so a one-line edit is both more powerful and
# far easier to slip past review than a 44 KB jar (ffi-leak-auditor, Wave A). Verified
# against gradle/gradle@v8.14.0: `gradlew` differs by one line (`DEFAULT_JVM_OPTS`
# without `-Dfile.encoding=UTF-8`, Gradle's own repo-local variant) and `gradlew.bat`
# is identical modulo CRLF.
GRADLE_GRADLEW_SHA256="b187b4c52e749f5760afdd6fadc31b2a98ad35fb249bf0dff03b72650f320409"
GRADLE_GRADLEW_BAT_SHA256="1d297e00bd21de3ace22b4d7f2de1f9dfa858883d66bbf7c1ccbecccec8f4f3b"
gradle_wrapper_jar() {
  local jar="$ROOT/android/gradle/wrapper/gradle-wrapper.jar"
  local props="$ROOT/android/gradle/wrapper/gradle-wrapper.properties"
  local got bad=0 sha f want
  # Guarded on the tool, like every other lane: a red wall for a missing coreutils
  # is how a real check earns a `git rm`. macOS ships `shasum -a 256`, not sha256sum.
  if command -v sha256sum >/dev/null 2>&1; then sha="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then sha="shasum -a 256"
  else
    echo "   no sha256sum/shasum — the wrapper jar's integrity is unverifiable here"
    return 1
  fi
  if [ ! -f "$jar" ]; then
    echo "   android/gradle/wrapper/gradle-wrapper.jar is missing — it is TRACKED (F2/D-153),"
    echo "   so a clean clone has it. A tree without it cannot build the custody layer."
    return 1
  fi
  got="$($sha "$jar" | cut -d' ' -f1)"
  if [ "$got" != "$GRADLE_WRAPPER_JAR_SHA256" ]; then
    echo "   wrapper jar does not match the pinned checksum:"
    echo "     expected $GRADLE_WRAPPER_JAR_SHA256"
    echo "     actual   $got"
    echo "   This binary executes on every Android build. Do not re-pin to make it"
    echo "   pass — establish what the jar IS first (its checksum against"
    echo "   services.gradle.org/distributions/gradle-<v>-wrapper.jar.sha256)."
    bad=1
  fi
  # ANCHORED to the assignment, and the dot escaped. An unanchored grep matched the
  # PROSE in this file's own header — the comment added alongside this lane names
  # `gradle-8.14-all.zip` while explaining the pin, so a bump of distributionUrl to
  # 9.0 left the check passing on its own documentation. Caught by dependency-steward
  # before merge and proven by execution: exactly the 2.10-jar-under-8.14-distribution
  # state this lane exists to prevent, recreated by the lane that prevents it.
  if ! grep -qE "^distributionUrl=.*gradle-${GRADLE_PINNED_VERSION//./\\.}-" "$props" 2>/dev/null; then
    echo "   distributionUrl no longer names Gradle $GRADLE_PINNED_VERSION, but the wrapper"
    echo "   jar is still pinned to that version's checksum — regenerate the wrapper"
    echo "   ('gradle wrapper --gradle-version <v> --distribution-type all') and move"
    echo "   ALL THREE constants in tools/gate.sh together."
    bad=1
  fi
  if ! grep -qE "^distributionSha256Sum=${GRADLE_DIST_SHA256}$" "$props" 2>/dev/null; then
    echo "   distributionSha256Sum is missing or is not the pinned distribution digest."
    echo "   That line is the only thing standing between this build and an unverified"
    echo "   200 MB download; the wrapper honours it, so an absent line fails OPEN."
    echo "   Expected: $GRADLE_DIST_SHA256"
    bad=1
  fi
  # The launcher scripts. Same assertion, same reason — see the constants above.
  for f in gradlew gradlew.bat; do
    case "$f" in
      gradlew)     want="$GRADLE_GRADLEW_SHA256" ;;
      gradlew.bat) want="$GRADLE_GRADLEW_BAT_SHA256" ;;
    esac
    if [ ! -f "$ROOT/android/$f" ]; then
      echo "   android/$f is missing — it is TRACKED (D-153); a clean clone has it"
      bad=1; continue
    fi
    got="$($sha "$ROOT/android/$f" | cut -d' ' -f1)"
    if [ "$got" != "$want" ]; then
      echo "   android/$f does not match its pinned checksum:"
      echo "     expected $want"
      echo "     actual   $got"
      echo "   This script launches every Android build. Establish what it IS before re-pinning."
      bad=1
    fi
  done
  return $bad
}
# Guarded on the PROPERTIES, not on the jar. Guarding on the jar would have made this
# lane vanish — from the roster and the call site both — exactly when the jar it
# asserts went missing: F9's own shape, reproduced inside the wave that fixed F9. The
# properties file is tracked, and is not the artifact under assertion.
if [ -f "$ROOT/android/gradle/wrapper/gradle-wrapper.properties" ]; then
  run_check "gradle wrapper (INV-7)" gradle_wrapper_jar
fi

# ── Gradle dependency verification (INV-7) ──────────────────────
# The third ecosystem finally gets an integrity check. Cargo has Cargo.lock +
# `cargo deny`; pub has pubspec.lock; Gradle had a version STRING, which is a
# request and not an assertion, while AGP + Kotlin are the largest bodies of
# third-party code the Android build downloads and executes.
# android/gradle/verification-metadata.xml pins 690 components / 1261 artifacts
# by sha256 (D-204). The two lanes BELOW (kotlin compile, android lint) enforce
# it on every run: adoption needed no new lane and no new network call, because
# those two already resolve from the network. CI is cold on every push (it
# caches cargo and Flutter, never ~/.gradle), so CI verifies all 1261 freshly
# fetched artifacts — that is where this mechanism has its teeth.
#
# What THIS lane adds is the part the generator cannot keep honest by itself.
# `gradle --write-verification-metadata sha256` has a blind spot: it never
# records what is resolved at SETTINGS time for the dev.flutter.flutter-plugin-
# loader included build (settings.gradle.kts:20), whose artifacts come from
# gradlePluginPortal — declared once, in pluginManagement. Proven by four runs:
# a file generated warm fails cold; generating ON a cold cache still omits them;
# and a clean regeneration over a cache that had ALREADY fetched them still
# omits them. Regeneration does not converge. The two kotlin-gradle-plugins-bom
# 1.9.20 entries are therefore HAND-ADDED — and the documented fix for any
# verification failure (regenerate) silently DROPS them, turning a green local
# tree into a red cold CI run at settings evaluation. This lane is what stands
# between that and a mystery.
#
# Deliberately NOT a whole-file digest pin: that would red on every legitimate
# dependency change and become a constant people bump on reflex, which is the
# ritual this mechanism exists to avoid. It asserts the fragile part only.
#
# Re-derive after a Flutter SDK change (the blind-spot set can move):
#   rm -rf "${GRADLE_USER_HOME:-$HOME/.gradle}/caches/modules-2" && ./gradlew :app:compileDebugKotlin
# (GRADLE_USER_HOME is normally UNSET — the bare form expands to /caches/modules-2,
# wipes nothing, and the blind spot then fails to reproduce against a warm cache,
# which is the exact wrong inference this lane exists to prevent.)
# then hand-add whatever it names, hashed from the cache with sha256sum.
GRADLE_VERIFY_BOM_MODULE_SHA256="7720f845cfe319aa1a6e5b23387e6920a35e99ae4218ca0f6f6e07fd1713093c"
GRADLE_VERIFY_BOM_POM_SHA256="6f3ba42a3e981700284c956146ef4d716b89adbe5d803ab92553dec216344330"
gradle_dep_verification() {
  local f="$ROOT/android/gradle/verification-metadata.xml" bad=0 pair ext want hit
  if [ ! -f "$f" ]; then
    echo "   android/gradle/verification-metadata.xml is missing — it is TRACKED (D-204)."
    echo "   Without it Gradle verifies NOTHING: AGP, Kotlin and 688 further components"
    echo "   download and execute unasserted on every build. Restore it; do not make this"
    echo "   pass by deleting the lane."
    return 1
  fi
  # Present on disk is not the assertion — CI's checkout only ever sees TRACKED files,
  # so an unstaged file passes locally and reds cold in CI, breaking D-024's "same
  # checks locally and in CI". Same scar as F2, where the kotlin lane's guard had to
  # move off `gradlew` precisely because it was gitignored. Pinned --git-dir/--work-tree
  # for the same reason repo_hygiene() pins them: the ops mirror shares this working
  # tree and an inherited GIT_DIR must not be able to steer the answer.
  if git --git-dir="$ROOT/.git" --work-tree="$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if ! git --git-dir="$ROOT/.git" --work-tree="$ROOT" \
         ls-files --error-unmatch -- android/gradle/verification-metadata.xml >/dev/null 2>&1; then
      echo "   verification-metadata.xml exists but is NOT git-tracked. CI clones only tracked"
      echo "   files, so this tree is green and the next cold CI run is red. git add it."
      bad=1
    fi
  else
    echo "   not a git repository — trackedness unverifiable, failing closed"
    bad=1
  fi
  # A present file with verification switched off is the fail-open state: the tree
  # LOOKS pinned, the diff LOOKS clean, and nothing whatsoever is checked.
  if ! grep -q "<verify-metadata>true</verify-metadata>" "$f"; then
    echo "   verification-metadata.xml no longer declares <verify-metadata>true</verify-metadata>."
    echo "   The file is present but inert. That fails OPEN, which is worse than absent,"
    echo "   because the file reads as proof."
    bad=1
  fi
  # The OTHER inert states, and the reason this block exists: all four T3 auditors
  # independently mutated the file into a green-but-verifying-nothing state that the
  # verify-metadata check above does not see. A single
  #   <trusted-artifacts><trust group=".*" regex="true"/></trusted-artifacts>
  # exempts EVERY artifact while all 1261 hashes stay in place; <also-trust> adds a
  # second accepted digest to a pinned entry; and md5/sha1 assertions are forgeable.
  # <trust*> is Gradle's own documented escape hatch when verification fails, which
  # makes it the reflex fix — so it is asserted ABSENT. Adopting PGP or a narrow
  # exemption later should be a ledgered change, not a silent one.
  for pair in "trusted-artifacts:<trusted-artifacts" "trust-entry:<trust " \
              "also-trust:<also-trust" "trusted-keys:<trusted-key" \
              "ignored-keys:<ignored-keys" "md5:<md5 " "sha1:<sha1 "; do
    ext="${pair%%:*}"; want="${pair#*:}"
    if grep -qF "$want" "$f"; then
      echo "   verification-metadata.xml carries a '$ext' construct ($want)."
      echo "   Matching artifacts are exempt, or asserted with a forgeable digest, while the"
      echo "   file still reads as proof — the same fail-open as verify-metadata=false."
      bad=1
    fi
  done
  # Off-switches that live OUTSIDE the file. Verification can be killed by a build
  # script call, a properties line, or a CLI flag, none of which touch the XML — so a
  # future "unblock the red CI" edit would leave every check above green and the
  # mechanism dead. None are present today; this asserts that they stay absent.
  # The [i] brackets are load-bearing: without them this pattern matches its OWN
  # source here and the lane reds on a clean tree — the same self-match the wrapper
  # lane's comment records, reproduced by the lane written after reading it.
  hit="$(grep -rlE 'disableDependencyVerif[i]cation|org\.gradle\.dependency\.verif[i]cation|--dependency-verif[i]cation' \
        "$ROOT/android" "$ROOT/tools/gate.sh" "$ROOT/.github/workflows" 2>/dev/null \
        | grep -v 'verification-metadata\.xml$')"
  if [ -n "$hit" ]; then
    echo "   a dependency-verification off-switch appears outside the metadata file:"
    echo "$hit" | sed 's/^/     /'
    echo "   These disable verification while the XML still reads as proof. Remove it, or"
    echo "   ledger the exemption with its repayment trigger."
    bad=1
  fi
  for pair in "module:$GRADLE_VERIFY_BOM_MODULE_SHA256" "pom:$GRADLE_VERIFY_BOM_POM_SHA256"; do
    ext="${pair%%:*}"; want="${pair#*:}"
    if ! grep -A2 "kotlin-gradle-plugins-bom-1\.9\.20\.$ext" "$f" 2>/dev/null | grep -q "$want"; then
      echo "   the hand-added kotlin-gradle-plugins-bom:1.9.20 .$ext entry is gone or changed."
      echo "   Regenerating the file drops it every time — the generator cannot see"
      echo "   settings-time pluginManagement resolution — so this is exactly what a blind"
      echo "   regeneration looks like locally. Cold CI fails at settings.gradle.kts:20."
      echo "   Re-add it with sha256 $want"
      bad=1
    fi
  done
  return $bad
}
if [ -f "$ROOT/android/build.gradle.kts" ]; then
  run_check "gradle dependency verification (INV-7)" gradle_dep_verification
fi

# ── Android/Kotlin compile (the custody platform layer) ─────────
# The gate ran 13 checks and NONE of them read a line of Kotlin — while
# `KeystoreVault` and `RevealActivity` hold the Keystore lanes and the seed
# reveal, i.e. two of the three worst findings product-audit run 1 produced.
# "GATE: GREEN" was therefore never evidence about the custody platform layer,
# and both `ffi-leak-auditor` and `wallet-security-auditor` said so independently
# in the same wave. Compile-proven is not test-proven — there is still no Kotlin
# test source set (the run-1 Destinations propose one) — but it is the difference
# between a claim and nothing at all.
#
# Guarded, not assumed: an outside contributor without an Android SDK gets a SKIP
# with the reason, exactly like cargo-ndk, rather than a red wall.
#
# The guard is `build.gradle.kts` — TRACKED — and no longer `gradlew`, which was
# gitignored (F2). Nesting the skip inside a test for the wrapper meant a tree
# without one produced no row rather than a SKIP, and strict mode counts SKIPs.
# Every branch below reports; the outer condition names an artifact that is in
# the repo, so on a clean clone this lane always speaks.
if [ -f "$ROOT/android/build.gradle.kts" ]; then
  if [ ! -f "$ROOT/android/gradlew" ]; then
    skip_check "kotlin compile (custody platform layer)" \
      "android/gradlew absent — the wrapper is tracked since F2, so a clean clone has it"
    skip_check "android lint (NewApi — custody platform layer)" \
      "android/gradlew absent — the wrapper is tracked since F2, so a clean clone has it"
  elif [ -z "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ] && [ ! -f "$ROOT/android/local.properties" ]; then
    skip_check "kotlin compile (custody platform layer)" \
      "no Android SDK (ANDROID_HOME / local.properties)"
    skip_check "android lint (NewApi — custody platform layer)" \
      "no Android SDK (ANDROID_HOME / local.properties)"
  else
    kotlin_compiles() {
      (cd "$ROOT/android" && ./gradlew :app:compileDebugKotlin --console=plain -q)
    }
    run_check "kotlin compile (custody platform layer)" kotlin_compiles

    # ── android lint: the NewApi lane (product-audit run 3, F10) ──
    # Compiling proves the Kotlin is well-formed against compileSdk. It says
    # NOTHING about whether a call exists on minSdk — and that gap shipped a
    # crash: `KeyGenParameterSpec.Builder.setIsStrongBoxBacked` is API 28, minSdk
    # is 26, so biometric enrolment raised NoSuchMethodError (a java.lang.Error,
    # which DartMessenger forwards to the uncaught handler = process death) on
    # the last beat of the create/restore ceremony. `NewApi` is the lint check
    # that exists for exactly this, and it had never been run on this code.
    #
    # Mutation-proven both ways before this lane was added: with the guard
    # removed, `lintDebug` exits 1 and prints
    #   KeystoreVault.kt: Error: Call requires API level 28 (current min is 26):
    #   ...#setIsStrongBoxBacked [NewApi]
    # with it, exit 0 and 0 errors. Lint's default `abortOnError` makes errors —
    # not warnings — the verdict, so this lane reds on NewApi and stays quiet
    # about the warning tier.
    #
    # The 32 warnings it does NOT red on, tallied rather than characterised
    # (dependency-steward caught an earlier "all cosmetic" gloss here that was
    # wrong for six of them):
    #
    #   grep -o 'id="[^"]*"' build/app/reports/lint-results-debug.xml \
    #     | sed 's/id="//;s/"//' | sort | uniq -c | sort -rn
    #   18 SetTextI18n · 8 UseKtx · 1 ObsoleteSdkInt · 1 LockedOrientationActivity
    #    1 DiscouragedApi · 1 ClickableViewAccessibility · 1 ChromeOsAbiSupport
    #    1 AndroidGradlePluginVersion
    #
    # Two of the six are not cosmetic and are live, not theoretical:
    # `AndroidGradlePluginVersion` is a toolchain-currency signal (dependency-
    # steward's law), and `ClickableViewAccessibility` at RevealActivity.kt:260
    # is an accessibility defect one step from D-178's TalkBack call. Left as
    # warnings deliberately — promoting them is a separate decision with its own
    # owner — but named here so "warnings" is never read as "nothing".
    #
    # The `-x` is load-bearing, not a convenience: `lintDebug` otherwise pulls in
    # cargokit's native build, which for a raw `./gradlew` invocation resolves to
    # every ABI including x86_64-android — and kaspa-hashes at the pinned rev
    # panics "Unsupported OS" there (the same constraint D-022 and the arm64-only
    # abiFilters already record). Lint analyses JVM sources; it needs no .so.
    # Excluding it also keeps the lane at ~1 min instead of a full cross-compile.
    kotlin_lints() {
      (cd "$ROOT/android" && ./gradlew :app:lintDebug --console=plain -q \
        -x :kaspaverse_bridge:cargokitCargoBuildKaspaverse_bridgeDebug)
    }
    run_check "android lint (NewApi — custody platform layer)" kotlin_lints
  fi
fi

# ── FRB codegen drift (stale committed bindings = silent runtime breakage) ──
if [ -f "$ROOT/flutter_rust_bridge.yaml" ]; then
  if command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
    codegen_drift() {
      flutter_rust_bridge_codegen generate >/dev/null 2>&1 || return 1
      # BOTH generated trees: the Dart bindings AND the Rust side. gate.sh
      # regenerates before cargo builds, so a stale committed frb_generated.rs
      # is invisible to every earlier check — only this diff can see it (L61).
      # Pinned like the other git reads: a steered index does not track lib/src/rust/,
      # so an inherited GIT_DIR would make this diff vacuously clean — a drift check
      # that passes because it looked in the wrong place (L76).
      git --git-dir="$ROOT/.git" --work-tree="$ROOT" diff --exit-code --quiet -- lib/src/rust/ rust/bridge/src/frb_generated.rs || {
        echo "   generated bindings differ from the index — after an API change,"
        echo "   stage BOTH generated trees ('git add lib/src/rust/ rust/bridge/src/frb_generated.rs')"
        echo "   before gating (L20/L61)"
        return 1
      }
    }
    run_check "codegen drift (lib/src/rust/ + frb_generated.rs)" codegen_drift
  else
    skip_check "codegen drift (lib/src/rust/ + frb_generated.rs)" \
      "flutter_rust_bridge_codegen not installed"
  fi
fi

# ── Contract spine (P3+) ────────────────────────────────────────
# The guard used to be `compgen -G contracts/*/SPEC.md` — the block was gated on
# the presence of an artifact it exists to REQUIRE, so the one deletion it most
# needed to catch was the one that switched it off (F9). Proven under bash on the
# real tree: full spine → 0 rows emitted at all; STATES.md deleted → FAIL=1;
# SPEC.md deleted TOO → guard false, whole block skipped, FAIL=0. Deleting more
# made the gate happier.
#
# Now unconditional and routed through run_check, so it reports on every run —
# including the success case, which previously appended nothing and was therefore
# indistinguishable from not having run.
#
# The empty-directory case is explicit because `gate.sh` never sets `nullglob`:
# with an empty `contracts/`, `for c in "$ROOT"/contracts/*/` iterates ONCE over
# the literal unexpanded pattern and would report a contract named `*` missing
# everything. My first pass at this fix had exactly that hole and a refuter caught
# it — the `[ -d "$c" ]` test is what closes it (L95: a diagnosis and its remedy
# are two claims, and the remedy needs its own proof).
#
# The contracts themselves are ROSTERED, for the same reason the lanes are.
# Checking "every directory under contracts/ is complete" left F9's shape alive one
# level up: deleting `contracts/duel_ad/` wholesale passed, because a tree with no
# contracts has no incomplete contract in it. "Deleting more makes the gate happier",
# at coarser granularity (consensus-auditor, Wave A). Naming them closes it — and the
# printed count is now ASSERTED against this list rather than merely reported, since a
# figure a check prints without asserting is a figure nobody is holding to anything.
CONTRACTS_EXPECTED=(duel_ad)
contract_spine() {
  local bad=0 found=0 c name artifact want
  if [ ! -d "$ROOT/contracts" ]; then
    if [ "${#CONTRACTS_EXPECTED[@]}" -gt 0 ]; then
      echo "   contracts/ is absent, but the roster names: ${CONTRACTS_EXPECTED[*]}"
      return 1
    fi
    echo "   no contracts/ directory yet (pre-P3) — nothing to verify"
    return 0
  fi
  for want in "${CONTRACTS_EXPECTED[@]}"; do
    [ -d "$ROOT/contracts/$want" ] || {
      echo "   rostered contract '$want' has no directory under contracts/"; bad=1; }
  done
  for c in "$ROOT"/contracts/*/; do
    [ -d "$c" ] || continue # unexpanded glob: contracts/ exists but is empty
    found=$((found+1))
    name="$(basename "$c")"
    for artifact in SPEC.md STATES.md AUDIT.md; do
      [ -f "$c$artifact" ] || { echo "   contract $name missing $artifact"; bad=1; }
    done
    # Non-empty, not merely present: an emptied vectors/ is a contract with no
    # vectors, and only duel_ad's model test happens to catch that today.
    if [ ! -d "${c}vectors" ]; then
      echo "   contract $name missing vectors/"; bad=1
    elif [ -z "$(ls -A "${c}vectors" 2>/dev/null)" ]; then
      echo "   contract $name has an EMPTY vectors/ — nothing would execute"; bad=1
    fi
  done
  if [ "$found" -lt "${#CONTRACTS_EXPECTED[@]}" ]; then
    echo "   found $found contract(s), roster names ${#CONTRACTS_EXPECTED[@]}"
    bad=1
  elif [ "$found" -eq 0 ]; then
    echo "   contracts/ is empty and none are rostered — nothing to verify"
  else
    echo "   $found contract(s) checked for SPEC.md + STATES.md + AUDIT.md + non-empty vectors/"
  fi
  return $bad
}
# vectors execute inside `cargo test` (chain crate integration tests)
run_check "contract spine" contract_spine

# ── The race fan-out exponent (L135 shape — LINK-P2) ────────────────────────
# `RACE_FETCHES` is not just a count, it is the EXPONENT in the PNN beacon-floor
# derivation: a walk fails when a hung beacon precedes every yielding one, and a
# round fires RACE_FETCHES independent shuffles, so P(round fails) =
# (b/(y+b))^RACE_FETCHES. That derivation is hand-copied into two shell tools,
# and the floor they assert is WRONG the moment the constant moves without them
# — wrong in the silent direction, since a stale-low exponent cries breach on a
# fleet that is fine and a stale-high one blesses one that is not.
#
# This is exactly L135's shape: a constant with watchers keyed to its old value.
# The lesson there was that naming the drift in a comment is not a mechanism, so
# this lane is the mechanism. It reads the constant from the Rust source and
# asserts both shell copies raise `b` and `(y+b)` to that same power, by counting
# the factors in the integer breach test each one actually evaluates.
race_fan_out_exponent() {
  local n rust_src bad=0 f got
  rust_src="$ROOT/rust/chain/src/dag_monitor.rs"
  [ -f "$rust_src" ] || { echo "   dag_monitor.rs missing — unverifiable, failing closed"; return 1; }
  n="$(sed -n 's/^const RACE_FETCHES: usize = \([0-9]\+\);.*/\1/p' "$rust_src" | head -1)"
  [ -n "$n" ] || { echo "   could not read RACE_FETCHES from dag_monitor.rs — failing closed"; return 1; }
  for f in tools/beacon_floor.sh tools/preflight.sh; do
    [ -f "$ROOT/$f" ] || continue
    # Count the repetitions of the hung-count variable inside the `10 * b*b*…`
    # product of that file's breach test — that IS the exponent it evaluates.
    got="$(grep -oE '10 \* (HUNG|BEACON_B)( \* (HUNG|BEACON_B))*' "$ROOT/$f" | head -1 \
           | grep -oE '(HUNG|BEACON_B)' | grep -c .)"
    if [ "$got" != "$n" ]; then
      echo "   $f evaluates the breach test at exponent ${got:-0}, but RACE_FETCHES is $n"
      bad=1
    fi
  done
  [ "$bad" = 0 ] && echo "   RACE_FETCHES=$n — both beacon-floor copies raise to the same power"
  return $bad
}
run_check "race fan-out exponent (L135)" race_fan_out_exponent

# ── Toolchain pins vs the pin files (D-131 / L84) ───────────────
# `preflight.sh` PRINTS these versions; until 2026-08-12 nothing FAILED on drift,
# which is how the repo sat on Flutter 3.44.9 against a 3.41.5 pin — and that drift
# was live, not cosmetic: 3.44.9 reddens `flutter analyze`. D-024 requires local and
# CI to compile with the same tools, so a mismatch is a defect.
#
# Asymmetric on purpose. Under GATE_STRICT=1 (CI) a mismatch is RED, because a runner
# that provisioned the wrong version is a provisioning bug. Locally it prints a loud
# block and passes, so an outside contributor's first `gate.sh` is not a red wall for
# a pin they never agreed to. The local path must stay LOUD, never a quiet warning —
# a warning nobody reads is the exact L84 sin this check exists to end.
pins_expected() { # file, sed-expression
  [ -f "$1" ] && sed -n "$2" "$1" 2>/dev/null | head -1
}
toolchain_pins() {
  local drift=0 want got
  local TT="$ROOT/rust/rust-toolchain.toml" WF="$ROOT/.github/workflows/gate.yml"
  _pin_cmp() { # label, want, got
    # An unreadable pin is reported, never silently treated as agreement.
    if [ -z "$2" ]; then
      printf '   %-30s PIN UNREADABLE (skipped)\n' "$1"; return 0
    fi
    if [ "$2" != "${3:-}" ]; then
      printf '   %-30s pinned %-12s installed %s\n' "$1" "$2" "${3:-MISSING}"
      drift=$((drift+1))
    fi
  }
  want="$(pins_expected "$TT" 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p')"
  got="$( (cd "$ROOT/rust" 2>/dev/null && rustc --version 2>/dev/null) | cut -d' ' -f2)"
  _pin_cmp "rustc (rust-toolchain.toml)" "$want" "$got"

  want="$(pins_expected "$WF" 's/.*flutter-version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p')"
  got="$(flutter --version 2>/dev/null | head -1 | cut -d' ' -f2)"
  _pin_cmp "flutter (gate.yml)" "$want" "$got"

  want="$(pins_expected "$WF" 's/.*cargo install cargo-deny --version \([0-9][0-9.]*\).*/\1/p')"
  got="$(cargo-deny --version 2>/dev/null | awk '{print $2}')"
  _pin_cmp "cargo-deny (gate.yml)" "$want" "$got"

  want="$(pins_expected "$WF" 's/.*cargo install cargo-ndk --version \([0-9][0-9.]*\).*/\1/p')"
  got="$(cargo ndk --version 2>/dev/null | awk '{print $2}')"
  _pin_cmp "cargo-ndk (gate.yml)" "$want" "$got"

  want="$(pins_expected "$WF" 's/.*cargo install flutter_rust_bridge_codegen --version \([0-9][0-9.]*\).*/\1/p')"
  got="$(flutter_rust_bridge_codegen --version 2>/dev/null | awk '{print $2}')"
  _pin_cmp "frb_codegen (gate.yml)" "$want" "$got"

  # The `kotlin compile` lane's compiler. MAJOR version only: the workflow pins
  # a track ('21') and runners move the patch level under us, so comparing the
  # full string would make this a permanent false alarm — and a warning that is
  # always on is the L84 sin this whole check exists to end.
  want="$(pins_expected "$WF" "s/.*java-version:[[:space:]]*'\([0-9][0-9.]*\)'.*/\1/p")"
  got="$(java -version 2>&1 | head -1 | sed -n 's/.*version "\([0-9]*\).*/\1/p')"
  _pin_cmp "jdk (gate.yml)" "$want" "$got"

  [ "$drift" -eq 0 ] && return 0
  if [ "${GATE_STRICT:-0}" = "1" ]; then
    echo "   $drift toolchain pin(s) drifted — local and CI must match (D-024)"
    return 1
  fi
  echo "   ╔═══════════════════════════════════════════════════════════════════════"
  echo "   ║ TOOLCHAIN DRIFT — $drift pin(s) above. The gate you just ran is NOT the"
  echo "   ║ gate CI runs (D-024). Fix before trusting a green, or CI will disagree."
  echo "   ║ This is RED under GATE_STRICT=1."
  echo "   ╚═══════════════════════════════════════════════════════════════════════"
  RESULTS+=("WARN  toolchain pins ($drift drifted — RED under GATE_STRICT=1)")
  return 2 # WARN, not PASS — see run_check
}
if [ -f "$ROOT/rust/rust-toolchain.toml" ] || [ -f "$ROOT/.github/workflows/gate.yml" ]; then
  run_check_warnable "toolchain pins (D-024)" toolchain_pins
fi

# ── Public-repo hygiene (always runs — the repo is public, D-011/D-019) ──
# Both this and internal_record() decide from `git ls-files` output, and an empty
# result is ambiguous: it means "nothing tracked" OR "git could not answer" (no repo,
# git absent, source tarball). Reading the second as a pass is a check that reports
# GREEN precisely when it did not run — the failure mode GATE_STRICT exists to stop
# (D-024). Assert the repo first so the emptiness is evidence, not silence.
require_git_repo() {
  git --git-dir="$ROOT/.git" --work-tree="$ROOT" rev-parse --git-dir >/dev/null 2>&1
}
repo_hygiene() {
  local bad=0
  local tracked
  require_git_repo || { echo "   not a git repository — hygiene unverifiable, failing closed"; return 1; }
  # Pinned --git-dir/--work-tree, same reason as internal_record(): the ops mirror shares
  # this working tree, so an inherited GIT_DIR must not be able to steer this check.
  tracked="$(git --git-dir="$ROOT/.git" --work-tree="$ROOT" ls-files -- \
    '*.keystore' '*.jks' '*.p12' '*.pem' \
    '*key.properties' '.env' '.env.*' 'id_rsa*' \
    'docs/environment.local.md')" # gate-allow:internal-path — asserted ABSENT, not offered
  if [ -n "$tracked" ]; then
    echo "   secret-shaped files are git-tracked:"; echo "$tracked" | sed 's/^/     /'
    bad=1
  fi
  # THE OPS INDEX TOO — L96's named destination, built 2026-08-25 after the scar recurred.
  #
  # L96 was earned when the internal record's local-environment file (keystore + password
  # references, a LAN
  # address) was found sitting in the ops index despite months of wrap commands excluding it
  # by pathspec: `:!pathspec` stops a file being ADDED and does nothing about one already in
  # the index. It was untracked at `bd08b15` — and it RE-ENTERED at `36d2b54`, because the
  # fix was a one-time `git rm --cached` plus a ritual instruction to re-grep at each wrap,
  # and a ritual step is a check nobody runs. That is L22 exactly: an unbuilt destination is
  # an unenforced law. L96's own rider named this lane as where it belonged.
  #
  # The general shape, and the reason this is four lines rather than a checklist item:
  # **an exclusion asserts a property of the NEXT COMMIT; assert the property of the
  # REPOSITORY instead.** Same pathspec list as the public half — one list, both indexes, so
  # the two halves cannot drift into disagreeing about what counts as secret-shaped.
  if [ -d "$OPS_GIT_DIR" ] && \
     git --git-dir="$OPS_GIT_DIR" --work-tree="$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    local ops_tracked
    ops_tracked="$(git --git-dir="$OPS_GIT_DIR" --work-tree="$ROOT" ls-files -- \
      '*.keystore' '*.jks' '*.p12' '*.pem' \
      '*key.properties' '.env' '.env.*' 'id_rsa*' \
      'docs/environment.local.md')" # gate-allow:internal-path — asserted ABSENT from the ops index too
    if [ -n "$ops_tracked" ]; then
      echo "   secret-shaped files are tracked in the INTERNAL RECORD (ops mirror):"
      echo "$ops_tracked" | sed 's/^/     /'
      echo "   The wrap's ':!pathspec' exclusion cannot fix this — it only stops a file being"
      echo "   ADDED. Untrack it: git ops rm --cached <path>   (L96; the blobs already in ops"
      echo "   history stay there, and purging those is a rewrite, which is founder-owned.)"
      bad=1
    fi
  fi
  # Same pinning as above — `git grep` searches an index, and a steered index is the
  # wrong index. All three git reads in this file are now unsteerable.
  # gate-allow:dangling-path android/key.properties — gitignored by design (INV-11): every clone creates it by hand from the committed .template, so it is absent here and on CI
  # Tracking is not the only way a secret leaks. `android/key.properties` holds both
  # keystore passwords AND the path to the keystore, and it is created by hand — so it
  # inherits the shell's umask, which on this machine is 002. It sat at 0644 while the
  # keystore beside it was 0600: the wave that hardened the key left the file that
  # unlocks it world-readable, and a green gate said nothing because this check only
  # ever asked whether the file was COMMITTED (wallet-security-auditor, Wave A).
  # Untracked by design, so `git ls-files` can never see it — stat it directly.
  local secret_file mode
  for secret_file in "$ROOT/android/key.properties"; do
    [ -f "$secret_file" ] || continue
    mode="$(stat -c '%a' "$secret_file" 2>/dev/null || stat -f '%Lp' "$secret_file" 2>/dev/null)"
    case "$mode" in
      600|400) ;;
      "") echo "   could not stat ${secret_file#"$ROOT/"} — permissions unverifiable"; bad=1 ;;
      *)
        echo "   ${secret_file#"$ROOT/"} is mode $mode — it holds the keystore passwords."
        echo "   fix: chmod 600 ${secret_file#"$ROOT/"}"
        bad=1 ;;
    esac
  done
  if git --git-dir="$ROOT/.git" --work-tree="$ROOT" grep -lI -e "BEGIN .*PRIVATE KEY" -- ':!tools/gate.sh' >/dev/null 2>&1; then
    echo "   a tracked file contains PEM private-key material:"
    git --git-dir="$ROOT/.git" --work-tree="$ROOT" grep -lI -e "BEGIN .*PRIVATE KEY" -- ':!tools/gate.sh' | sed 's/^/     /'
    bad=1
  fi
  return $bad
}
run_check "public-repo hygiene (no tracked secrets)" repo_hygiene

# ── Internal-record boundary (D-102 — the record is ops-mirror-only) ──
# `.gitignore` states the rule; this enforces it. A single `git add -f` would
# otherwise put a doc back in the public tree silently, and the whole reason
# D-102 replaced D-047's per-file taxonomy is that a boundary nobody checks
# gets crossed. Directories are checkable — so check them.
#
# Deliberately NOT extended to commit authorship: the companion exposure was a
# personal email on every commit, but a check for it would have to name the
# address inside this public file, and pinning the author to one identity would
# fail the gate on any outside contributor's PR.
# The boundary is READ from the file that declares it, never hand-copied here
# (S4-54). Entries are validated before use: this list becomes both a git pathspec
# and a grep alternation, so a malformed line must stop the check rather than
# quietly change what it matches.
internal_record_paths() {
  local line
  sed -n '/# gate:internal-record-begin/,/# gate:internal-record-end/p' "$ROOT/.gitignore" 2>/dev/null \
  | grep -vE '^[[:space:]]*(#|$)' \
  | while IFS= read -r line; do
      case "$line" in
        # A malformed entry STOPS the check. It must not be skipped: skipping
        # silently narrows the boundary while the entry count stays non-zero, so
        # both callers would pass on a shorter list than .gitignore declares —
        # a boundary check quietly enforcing less than it advertises. Emitting
        # the sentinel makes the callers fail closed instead (dependency-steward,
        # Wave A: the comment claimed this and the code did the opposite).
        # `..` is rejected even though every character in it is "plain": as a git
        # pathspec an outside-the-repo path makes `ls-files` ERROR, leaving the
        # result empty — and empty is the same string this check reads as "nothing
        # internal is tracked". It would pass vacuously, the exact fail-open the
        # require_git_repo assertion above exists to prevent.
        *..*) printf '%s\n' "!MALFORMED:$line"; return ;;
        *[!A-Za-z0-9_./-]*) printf '%s\n' "!MALFORMED:$line"; return ;;
        '') continue ;;
        *) printf '%s\n' "$line" ;;
      esac
    done
}

# Shared by both D-102 halves: resolve the declared boundary or fail closed.
internal_record_load() { # name-of-caller ; sets `paths`
  mapfile -t paths < <(internal_record_paths)
  if [ "${#paths[@]}" -eq 0 ]; then
    echo "   could not read the declared boundary from .gitignore (gate:internal-record markers)"
    echo "   — the boundary is unverifiable, failing closed rather than passing vacuously"
    return 1
  fi
  case "${paths[*]}" in
    *'!MALFORMED:'*)
      echo "   .gitignore's declared boundary contains an entry that is not a plain path:"
      printf '     %s\n' "${paths[@]}" | sed 's/!MALFORMED://'
      echo "   Refusing to guess what it matches — fix the entry or the markers."
      return 1 ;;
  esac
  return 0
}

internal_record() {
  local tracked
  local -a paths
  require_git_repo || { echo "   not a git repository — boundary unverifiable, failing closed"; return 1; }
  internal_record_load || return 1
  # --git-dir/--work-tree pinned, not `-C`: the ops mirror shares this working tree, so
  # an exported GIT_DIR in the environment would otherwise point this check at the ops
  # index and list all 400+ record files — a spurious RED, and a spuriously red check is
  # how a real check earns a `git rm` from the ledger.
  tracked="$(git --git-dir="$ROOT/.git" --work-tree="$ROOT" ls-files -- "${paths[@]}")"
  [ -z "$tracked" ] && return 0
  echo "   the engineering record is ops-mirror-only (D-102), but these are tracked here:"
  echo "$tracked" | sed 's/^/     /'
  echo "   fix: git rm -r --cached <path>   — the files stay on disk; 'git ops' tracks them"
  return 1
}
run_check "internal-record boundary (D-102)" internal_record

# ── Internal-record POINTERS (L88 — the other half of D-102) ──
# `internal_record` proves the record is not tracked here. This proves nothing
# tracked here POINTS AT it. Both halves are needed: a public contributor whose
# clone has no `docs/` was being sent there by build files, a key template and
# four `die` messages — "Setup: <the release runbook>" — and by provenance comments in
# Rust and Dart. Product-audit run 1 planted exactly this as its control, and the
# run missed it because the audit brief enumerated the public surface BY HAND
# (L88). A hand-written scope list is the defect; a mechanical check is the fix.
#
# Deliberately NARROWER than "every repo-relative path resolves". That general
# form was measured against this tree before this check was written:
#
#   git grep -nIoE '[A-Za-z0-9_][A-Za-z0-9_.+-]*/[A-Za-z0-9_./+-]*\.(md|dart|rs|sh)' \
#     -- $(git ls-files) | sort -u | wc -l
#
# Measured on THIS tree, 2026-08-13, at the end of the run-1 fix wave: 552
# matches, 172 unique tokens, of which 157 do not resolve from the repo root
# (drop `-n` and add `-h`, `sort -u`, then diff against `git ls-files`). They are
# Dart package URIs, imports relative to their own file, citations into the
# PINNED rusty-kaspa crates (INV-9 provenance, and correct), and the vendored
# cargokit tree. Separating those needs a heuristic tower, and a check with a
# heuristic tower is a check that gets silenced. This one is decidable: `docs/`
# and `.claude/` are internal by D-102.
#
# (The first draft of this comment cited 621/~190 — numbers taken before the
# wave removed its own `docs/` pointers, pasted beside a command that no longer
# produced them. Item 13 / L77 recurring at the exact site meant to close it.)
#
# Residual, stated rather than papered over (dependency-steward, this wave): a
# bare `docs/` with no filename, and case variants, are not matched. Adding
# those costs more false positives than the class is worth — but they are gaps,
# not absences, and the next reader should know it. `--untracked` is on because
# the gate runs BEFORE `git add`, which is exactly when a new file's pointers
# would otherwise be invisible.
#
# `.gitignore` is exempt structurally — a gitignore line naming an internal path
# is that file doing its job. Everything else opts out per line, at the site,
# with `gate-allow:internal-path` and a reason.
internal_pointers() {
  local hits entry dir_alt="" file_alt="" esc target
  local -a paths
  require_git_repo || { echo "   not a git repository — unverifiable, failing closed"; return 1; }
  # Same declared list as internal_record (S4-54) — the two halves of D-102 must
  # not be able to disagree about what "internal" means. Directory entries match
  # as path prefixes; bare filenames match as names, since a pointer to one is
  # just as dangling for a reader whose clone does not have it. (Naming an actual
  # entry here would trip this very check — which is the check working.)
  internal_record_load || return 1
  for entry in "${paths[@]}"; do
    esc="$(printf '%s' "${entry%/}" | sed 's/[.]/\\./g')"
    case "$entry" in
      */) dir_alt="${dir_alt:+$dir_alt|}$esc" ;;
      *)  file_alt="${file_alt:+$file_alt|}$esc" ;;
    esac
  done
  # The optional relative prefix catches the dot-slash forms the boundary
  # would otherwise swallow. NOT by dropping `/` from that class — that would
  # false-positive on every github.com/…/docs/… URL.
  target=""
  [ -n "$dir_alt" ]  && target="($dir_alt)/[A-Za-z0-9_.-]+"
  [ -n "$file_alt" ] && target="${target:+$target|}($file_alt)"
  hits="$(git --git-dir="$ROOT/.git" --work-tree="$ROOT" grep --untracked -nIE \
      "(^|[^A-Za-z0-9_./-])(\.\.?/)?($target)" \
      -- ':!.gitignore' 2>/dev/null | grep -v 'gate-allow:internal-path')" || true
  [ -z "$hits" ] && return 0
  echo "   public-tracked files point into the internal record (D-102 / L88):"
  echo "$hits" | sed 's/^/     /'
  # Named from the derived list, not hand-written: a message that recites a stale
  # list beside a check that reads a live one is the same drift in miniature.
  echo "   A reader who clones this repo has none of [$(printf '%s ' "${paths[@]}" | sed 's/ $//')] —"
  echo "   a path into them is an instruction they cannot follow. Fix: say what they need"
  echo "   inline, or cite the decision (D-nnn / L-nn) instead of a file path."
  echo "   A tool that legitimately operates on the internal tree marks the line"
  echo "   'gate-allow:internal-path' with its reason."
  return 1
}
run_check "internal-record pointers (D-102 / L88)" internal_pointers

# ── Repo-path resolution (L88 / F48 — every internal pointer must land) ──
# `internal_record` proves the record is not tracked here; `internal_pointers` proves
# nothing public POINTS at it. Neither asks the simplest question about the other 460
# files: does the path a sentence sends you to EXIST?
#
# It has been answered "no" twice, and both times by hand:
#   F48  — the one `_ACTIVE` phase file cited a summary that had never existed. The
#          reader who followed it had no way to tell a missing file from a wrong name.
#   run 2 — a public-tracked file carried a path into the private record. That half is
#          `internal_pointers`; this is the other half of the same defect class.
# Nothing verified either. 225 record docs, 156 of them session archives, all of them
# navigated BY PATH, and the only check on any of it was somebody reading carefully.
#
# BOTH indexes, because the record lives in the second one. The public index is
# authoritative for a clean clone; the ops mirror (D-102) is added when it is readable.
# When it is NOT readable but `docs/` is sitting in the working tree, this lane fails
# CLOSED — half the corpus unchecked is not a pass, it is a lane that did not run.
# On a clean public clone there is no record on disk and no half to miss, so CI is green
# for the honest reason rather than the vacuous one.
#
# WHAT IS IN SCOPE, and how the scope was chosen. The general form — "every token with a
# slash resolves" — was measured on this tree first: 10 081 path-shaped tokens, 6 342 of
# them unresolved, and essentially all of the 6 342 were Dart package URIs, imports
# relative to their own file, bare basenames in prose, and citations into the PINNED
# rusty-kaspa crates (INV-9 provenance, and correct). That check is a heuristic tower,
# and a check with a heuristic tower is a check that gets silenced. So the scope is the
# part that is DECIDABLE from this repo alone:
#
#   * ROOT-ANCHORED — the first segment is a directory this repo actually tracks. The
#     anchor set is derived from both indexes at run time, never written down here: a
#     new top-level directory is covered on the day it appears (L88 — the tool that owns
#     the surface enumerates it, not a list in a comment).
#   * A CONCRETE FILE — the last segment ends in a source/config extension. That is what
#     took the count from 6 342 to 66.
#
# Residuals, stated rather than papered over (they are gaps, not absences):
#   - directory references (`contracts/duel_rps/`) are OUT. In prose the shape is
#     dominated by alternation — "contracts/deps", "test/tooling", "lib/screens" all
#     read as a slash meaning "or" — and both real incidents were file pointers.
#   - cwd-relative paths (`./gradlew`, `./check.sh`) are OUT: prose does not carry the
#     cwd, so the lane cannot decide them without guessing.
#   - bare root-file names with no directory (`README.md`) are OUT — not a path.
#   - a `file:line` citation is checked for the FILE. A line number that has since
#     drifted onto unrelated content is a real defect this lane does not see.
#
# TWO HATCHES, both requiring a reason. Inline, at the site, is the primary one and
# matches `gate-allow:internal-path`'s shape:
#     gate-allow:dangling-path — <why this path is meant not to resolve>       (this line)
#     gate-allow:dangling-path <target> — <why>            (that ONE target, this file)
# It cannot be used on a line that must stay VERBATIM — pasted tool output is INV-10
# evidence, and editing evidence to please a checker is the failure the gate exists to
# prevent — nor in a tree whose owner is not the editor. Those go in the register, which
# is asserted LIVE: an entry matching nothing FAILS, so it can only shrink or be
# re-justified. The register is excluded from its own scan; it is a list of paths
# declared not to resolve, and reading it as a source would be circular.
DANGLING_REGISTER=".claude/gate/dangling-allow.txt" # gate-allow:internal-path — the register this lane READS; ops-mirror-only by D-102, absent on a public clone
REPO_PATH_EXTS="md|rs|dart|sh|toml|yaml|yml|json|kts|kt|java|gradle|properties|xml|txt|lock|proto|sil|podspec|py|so|jar"

repo_path_targets() {
  local ops=0 bad=0 anchors="" d esc re hit f n rest tok text reason marker i matched
  local checked=0 shown=0
  local -a dirs=() reg_src=() reg_tgt=() reg_hit=() ops_scope=()
  require_git_repo || { echo "   not a git repository — pointers unverifiable, failing closed"; return 1; }

  if [ -d "$OPS_GIT_DIR" ] && \
     git --git-dir="$OPS_GIT_DIR" --work-tree="$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    ops=1
    # Derived, never named (L88): the ops index's own tracked top-level entries are
    # exactly the internal record, and nothing else. Used as the pathspec that bounds
    # the untracked sweep below.
    mapfile -t ops_scope < <(
      git --git-dir="$OPS_GIT_DIR" --work-tree="$ROOT" ls-files 2>/dev/null |
        sed -E 's|/.*||' | sort -u )
    if [ "${#ops_scope[@]}" -eq 0 ]; then
      echo "   the internal record's index is readable but names no paths — the untracked"
      echo "   sweep below would be unbounded. Failing closed."
      return 1
    fi
  elif [ -d "$ROOT/docs" ]; then
    echo "   the internal record is on disk but its index is not readable"
    echo "   (KASPAVERSE_OPS_GIT_DIR, default \$HOME/.kaspaverse-ops.git) — that is most of"
    echo "   the corpus. Failing closed rather than passing on the half this can see."
    return 1
  fi

  # The anchor set, derived — never hand-written (L88).
  mapfile -t dirs < <(
    { git --git-dir="$ROOT/.git" --work-tree="$ROOT" ls-files
      [ "$ops" = 1 ] && git --git-dir="$OPS_GIT_DIR" --work-tree="$ROOT" ls-files
    } 2>/dev/null | grep '/' | cut -d/ -f1 | sort -u )
  if [ "${#dirs[@]}" -eq 0 ]; then
    echo "   no tracked directory found — the anchor set is empty, so this lane would"
    echo "   match nothing and pass vacuously. Failing closed."
    return 1
  fi
  for d in "${dirs[@]}"; do
    case "$d" in
      *[!A-Za-z0-9_.-]*)
        echo "   tracked top-level entry '$d' is not a plain name — refusing to guess"
        echo "   what it matches as a regex. Failing closed."; return 1 ;;
    esac
    esc="$(printf '%s' "$d" | sed 's/[.]/\\./g')"
    anchors="${anchors:+$anchors|}$esc"
  done
  # `:` is in the boundary class so a package URI is not read as a repo path:
  # `package:integration_test/integration_test.dart` collides with the tracked
  # `integration_test/` directory and is a pub package, not a file in this tree.
  re="(^|[^A-Za-z0-9_./+:-])(\\./)?($anchors)/[A-Za-z0-9_./+-]*\\.($REPO_PATH_EXTS)\\b"

  # L106, encoded into the lane instead of trusted at review time. `checked` below is a
  # COUNT, and the whole F2/F9 class is a check whose count silently becomes zero: if the
  # regex, REPO_PATH_EXTS, the anchor escaping or `git grep -o`'s output shape ever stops
  # matching, every loop body is skipped, `bad` stays 0, and this lane prints
  # "0 repo-path reference(s) ... resolve" and PASSES — reporting agreement where it has
  # in fact stopped looking. So: prove the matcher can SEE a reference before believing
  # any zero it reports. The probe is built from the derived anchor set, never a literal,
  # so it cannot drift away from what the lane actually searches for.
  # (consensus-auditor, grounding pass 2026-08-25, C1.)
  local probe="see ${dirs[0]}/__gate_probe__.md for the rest"
  if ! printf '%s\n' "$probe" | grep -qE "$re"; then
    echo "   the repo-path matcher failed its own control: it did not match"
    echo "     $probe"
    echo "   built from the derived anchor set. The pattern, REPO_PATH_EXTS or the anchor"
    echo "   escaping is broken, so a zero from this lane would mean 'stopped looking',"
    echo "   not 'nothing dangles'. Failing closed."
    return 1
  fi

  # The register. Validated before use, like the D-102 boundary: a malformed entry STOPS
  # the check rather than being skipped, or the lane silently enforces less than the file
  # advertises while the entry count stays non-zero.
  if [ -f "$ROOT/$DANGLING_REGISTER" ]; then
    while IFS= read -r hit || [ -n "$hit" ]; do
      case "$hit" in ''|'#'*) continue ;; esac
      f="${hit%%|*}"; rest="${hit#*|}"
      [ "$rest" = "$hit" ] && { echo "   register entry has no '|': $hit"; return 1; }
      tok="${rest%%|*}"; reason="${rest#*|}"
      if [ "$reason" = "$rest" ] || [ -z "$f" ] || [ -z "$tok" ] || [ "${#reason}" -lt 10 ]; then
        echo "   malformed register entry — need 'source|target|reason' with a reason of"
        echo "   at least 10 characters. An exemption without a stated reason is not an"
        echo "   exemption, it is a silenced check:"
        echo "     $hit"; return 1
      fi
      case "$f$tok" in
        *..*) echo "   register entry uses '..', which escapes the repo: $hit"; return 1 ;;
      esac
      reg_src+=("$f"); reg_tgt+=("$tok"); reg_hit+=(0)
    done < "$ROOT/$DANGLING_REGISTER"
  fi

  # `--untracked` on the public index: the gate runs BEFORE `git add`, which is exactly
  # when a new file's pointers would otherwise be invisible (same reason as L20/L61).
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    f="${hit%%:*}"; rest="${hit#*:}"; n="${rest%%:*}"; tok="${rest#*:}"
    tok="${tok#"${tok%%[A-Za-z0-9_.]*}"}"   # drop the leading word-boundary byte
    tok="${tok#./}"
    case "$tok" in *...*) continue ;; esac   # `android/.../Foo.kt` — an ellipsis, not a path
    checked=$((checked+1))
    [ -e "$ROOT/$tok" ] && continue

    if [ ! -f "$ROOT/$f" ]; then
      echo "   could not re-read $f to check for an exemption marker — failing closed"
      bad=1; continue
    fi
    text="$(sed -n "${n}p" "$ROOT/$f" 2>/dev/null)"
    case "$text" in
      *gate-allow:dangling-path*)
        reason="${text#*gate-allow:dangling-path}"
        reason="$(printf '%s' "$reason" | sed 's/^[[:space:]:—–-]*//')"
        if [ "${#reason}" -ge 10 ]; then continue; fi
        echo "   $f:$n  'gate-allow:dangling-path' with no stated reason."
        echo "     Write why the path is meant not to resolve, after the marker."
        bad=1; continue ;;
    esac

    # File-scoped form: 'gate-allow:dangling-path <target> — <reason>' anywhere in the
    # file exempts that ONE target throughout it. It exists because the line-scoped form
    # cannot be paid for everywhere: `android/key.properties` is named twelve times
    # across the signing config, its template, the release script and this file — it is
    # gitignored by design (INV-11), created by hand from the committed template, so it
    # is absent from every clean clone and present on the founder's box. That asymmetry
    # is precisely the local-green/CI-red shape D-024 exists to stop, and the fix must
    # not be twelve markers threaded through release-signing code and user-facing error
    # strings. Scoped to a NAMED target, never to the whole file: a second broken path
    # in the same file is still a finding.
    marker="$(grep -m1 -F "gate-allow:dangling-path $tok" "$ROOT/$f" 2>/dev/null || true)"
    if [ -n "$marker" ]; then
      reason="${marker#*gate-allow:dangling-path $tok}"
      reason="$(printf '%s' "$reason" | sed 's/^[[:space:]:—–-]*//')"
      if [ "${#reason}" -ge 10 ]; then continue; fi
      echo "   $f  file-scoped 'gate-allow:dangling-path $tok' with no stated reason."
      echo "     Write why the path is meant not to resolve, after the target."
      bad=1; continue
    fi

    matched=0
    for i in "${!reg_src[@]}"; do
      # shellcheck disable=SC2254 — the register entries ARE globs, deliberately
      case "$f" in ${reg_src[$i]}) ;; *) continue ;; esac
      case "$tok" in ${reg_tgt[$i]}) ;; *) continue ;; esac
      reg_hit[$i]=1; matched=1; break
    done
    [ "$matched" = 1 ] && continue

    if [ "$shown" -eq 0 ]; then
      echo "   these tracked files point at repo paths that do not exist:"
    fi
    shown=$((shown+1))
    [ "$shown" -le 40 ] && echo "     $f:$n  ->  $tok"
    bad=1
  # `cd "$ROOT"` inside the subshell, and it is load-bearing: `git grep` walks from the
  # CURRENT DIRECTORY, and with a cwd outside the work tree it silently answers from the
  # INDEX instead of the working tree — a lane that cannot see the edit in front of it,
  # reporting green. Caught by the clean-clone control, which is the only place the two
  # ever differed. Every other git read here is index-only, so only this one cares.
  done < <(
    cd "$ROOT" || exit 0
    git --git-dir="$ROOT/.git" --work-tree="$ROOT" grep --untracked -nIoE "$re" \
        -- ":!$DANGLING_REGISTER" 2>/dev/null
    # The ops half needs `--untracked` for the SAME reason the public half does, and it
    # needs it harder: the wrap ritual's own output IS new record files (a session prompt,
    # a summary, NEXT_SESSION.md), written and gated BEFORE `git ops add` — and F48, the
    # incident this lane exists for, was a phase file citing a summary that had never
    # existed. Without this the lane is blind at exactly the moment it matters.
    #
    # `--no-exclude-standard` is required and is not a loosening: the ops mirror's
    # info/exclude is literally `*` (which is why the wrap uses `git ops add -f`), and
    # `git grep --untracked` honours standard excludes — so the plain form returns ZERO
    # from the internal record, indistinguishable from "nothing to find". Scoped to the
    # ops index's OWN tracked top-level entries, derived not hand-written, so turning
    # excludes off cannot pull in rust/target/, build/ or .dart_tool/: those are not in
    # that index, so they are not in the pathspec. (consensus-auditor 2026-08-25, C2.)
    [ "$ops" = 1 ] && git --git-dir="$OPS_GIT_DIR" --work-tree="$ROOT" \
        grep --untracked --no-exclude-standard -nIoE "$re" \
        -- "${ops_scope[@]}" ":!$DANGLING_REGISTER" 2>/dev/null
  )

  [ "$shown" -gt 40 ] && echo "     ... and $((shown-40)) more"
  if [ "$shown" -gt 0 ]; then
    echo "   A path in a sentence is an instruction. Fix: retarget it to where the file"
    echo "   actually is, drop the reference if the target is genuinely gone, or — if it"
    echo "   is MEANT not to resolve (a template, a rejected path, another project's"
    echo "   tree) — say so, either inline with 'gate-allow:dangling-path — <reason>' or"
    echo "   as a 'source|target|reason' line in the register this lane reads."
  fi

  # Liveness. An exemption that matches nothing is a stale excuse, and a register of
  # stale excuses is how this lane would rot into decoration (F9's shape: deleting more
  # must never make the gate happier).
  for i in "${!reg_src[@]}"; do
    [ "${reg_hit[$i]}" = 1 ] && continue
    echo "   STALE exemption — it matches no dangling pointer any more:"
    echo "     ${reg_src[$i]}|${reg_tgt[$i]}"
    echo "   The reference was fixed, moved, or now resolves. Delete the line."
    bad=1
  done

  # The second half of C1. The probe above proves the PATTERN works; this proves the
  # SCAN ran. A repo whose tracked corpus cites no repo path at all is not a state this
  # project can reach — this repo's own router is a routing table of them — so `checked == 0`
  # means the git-grep invocation produced nothing, not that there was nothing to find.
  if [ "$checked" -eq 0 ]; then
    echo "   the scan examined ZERO repo-path references, in a tree whose own router is a"
    echo "   table of them. The matcher passed its control, so the grep invocation itself"
    echo "   returned nothing — a lane that has stopped looking, not a clean tree."
    echo "   Failing closed rather than reporting a vacuous pass."
    return 1
  fi

  if [ "$bad" -eq 0 ]; then
    if [ "$ops" = 1 ]; then
      echo "   $checked repo-path reference(s) across both indexes resolve; ${#reg_src[@]} live exemption(s)"
    else
      echo "   $checked repo-path reference(s) in the public index resolve (no internal record on disk)"
    fi
  fi
  return $bad
}
run_check "repo-path resolution (L88 / F48)" repo_path_targets

# ── Roster assertion (the fix for the whole F2/F9/S4-11/S4-54 class) ──
# Everything above reports what it DID. This reports what nothing did. A lane on
# the roster that emitted no row did not "not apply" — it failed before it could
# say so, and that is precisely the state four separate findings hid in.
for lane in "${EXPECTED[@]}"; do
  [ -n "${SEEN[$lane]:-}" ] && continue
  RESULTS+=("FAIL  $lane (no row — the lane never reported; see the roster in this file)")
  FAIL=$((FAIL+1))
done
# And the reverse. The roster matches lanes BY NAME, so a lane renamed at its
# call site without its roster entry would raise a phantom failure for the old
# name while the new one passed unnoticed — the roster drifting into fiction, one
# rename at a time. This caught its own first instance on the wave that added it:
# `codegen drift` was rostered short and emitted long, and the forward loop alone
# reported it as a lane that never ran. Checking both directions turns a name
# mismatch into a message that says so.
for lane in "${!SEEN[@]}"; do
  for expected in "${EXPECTED[@]}"; do
    [ "$lane" = "$expected" ] && continue 2
  done
  RESULTS+=("FAIL  $lane (reported, but no roster entry — roster and call site disagree)")
  FAIL=$((FAIL+1))
done

# ── Summary ─────────────────────────────────────────────────────
echo; echo "══════════ GATE SUMMARY ══════════"
printf '%s\n' "${RESULTS[@]:-"(no checks ran)"}"
echo "──────────────────────────────────"
echo "pass=$PASS fail=$FAIL skip=$SKIP warn=$WARN"
if [ "$FAIL" -gt 0 ]; then echo "GATE: RED"; exit 1; fi
# Strict mode (CI, D-024): a SKIP means a tool is missing — on a runner that is a
# provisioning bug, not an acceptable gap, or CI reads green while checking less
# than the local gate does.
if [ "${GATE_STRICT:-0}" = "1" ] && [ "$SKIP" -gt 0 ]; then
  echo "GATE: RED (strict — $SKIP skipped check(s); provision the missing tool)"
  exit 1
fi
if [ "$PASS" -eq 0 ]; then echo "GATE: NOTHING TO CHECK (scaffold state)"; exit 0; fi
# A warning rides IN the verdict line, so a pasted proof carries it (INV-10) —
# a warning printed 40 lines above the verdict is a warning nobody reads (L84).
if [ "$WARN" -gt 0 ]; then echo "GATE: GREEN ($WARN warning(s) — read them)"; exit 0; fi
echo "GATE: GREEN"
