#!/usr/bin/env bash
# The proof gate — the only arbiter of "done" (INV-10).
# Phase-aware: checks every component that exists; grows monotonically (checks are
# added at phase entry, never removed without a DECISION_LOG entry).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
else
  expect_lane "rust workspace"
fi
if [ -f "$ROOT/pubspec.yaml" ]; then
  expect_lane "dart format"; expect_lane "flutter analyze"; expect_lane "flutter test"
else
  expect_lane "flutter app"
fi
[ -f "$ROOT/android/build.gradle.kts" ] && expect_lane "kotlin compile (custody platform layer)"
[ -f "$ROOT/android/gradle/wrapper/gradle-wrapper.properties" ] && expect_lane "gradle wrapper (INV-7)"
[ -f "$ROOT/flutter_rust_bridge.yaml" ] && expect_lane "codegen drift (lib/src/rust/ + frb_generated.rs)"
expect_lane "contract spine"
# Mirrors this lane's own guard exactly. A roster entry that is stricter than the
# lane it names is not extra rigour — it is a spurious RED in a scaffold tree, and
# a spuriously red check is how a real check earns a `git rm` from the ledger.
{ [ -f "$ROOT/rust/rust-toolchain.toml" ] || [ -f "$ROOT/.github/workflows/gate.yml" ]; } \
  && expect_lane "toolchain pins (D-024)"
expect_lane "public-repo hygiene (no tracked secrets)"
expect_lane "internal-record boundary (D-102)"
expect_lane "internal-record pointers (D-102 / L88)"

# ── Rust workspace ──────────────────────────────────────────────
if [ -f "$ROOT/rust/Cargo.toml" ]; then
  cd "$ROOT/rust"
  run_check "cargo fmt"    cargo fmt --all --check
  run_check "cargo clippy" cargo clippy --workspace --all-targets -- -D warnings
  run_check "cargo test"   cargo test --workspace
  if command -v cargo-deny >/dev/null 2>&1; then
    run_check "cargo deny (INV-7)" cargo deny check
  else
    skip_check "cargo deny (INV-7)" "cargo-deny not installed — REQUIRED from P0-D4"
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
  elif [ -z "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ] && [ ! -f "$ROOT/android/local.properties" ]; then
    skip_check "kotlin compile (custody platform layer)" \
      "no Android SDK (ANDROID_HOME / local.properties)"
  else
    kotlin_compiles() {
      (cd "$ROOT/android" && ./gradlew :app:compileDebugKotlin --console=plain -q)
    }
    run_check "kotlin compile (custody platform layer)" kotlin_compiles
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
  # Same pinning as above — `git grep` searches an index, and a steered index is the
  # wrong index. All three git reads in this file are now unsteerable.
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
