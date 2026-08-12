#!/usr/bin/env bash
# The proof gate — the only arbiter of "done" (INV-10).
# Phase-aware: checks every component that exists; grows monotonically (checks are
# added at phase entry, never removed without a DECISION_LOG entry).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0; SKIP=0
declare -a RESULTS

run_check() { # name, command...
  local name="$1"; shift
  echo "── gate: $name"
  if "$@"; then RESULTS+=("PASS  $name"); PASS=$((PASS+1));
  else RESULTS+=("FAIL  $name"); FAIL=$((FAIL+1)); fi
}
skip_check() { RESULTS+=("SKIP  $1 ($2)"); SKIP=$((SKIP+1)); }

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
  mapfile -t dart_format_files < <(find lib test -name '*.dart' -not -path 'lib/src/rust/*' 2>/dev/null)
  if [ "${#dart_format_files[@]}" -gt 0 ]; then
    run_check "dart format" dart format --output=none --set-exit-if-changed "${dart_format_files[@]}"
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
    skip_check "codegen drift" "flutter_rust_bridge_codegen not installed"
  fi
fi

# ── Contract spine (P3+) ────────────────────────────────────────
if compgen -G "$ROOT/contracts/*/SPEC.md" >/dev/null 2>&1; then
  for c in "$ROOT"/contracts/*/; do
    name="$(basename "$c")"
    for artifact in SPEC.md STATES.md AUDIT.md; do
      [ -f "$c$artifact" ] || { RESULTS+=("FAIL  contract $name missing $artifact"); FAIL=$((FAIL+1)); }
    done
    [ -d "${c}vectors" ] || { RESULTS+=("FAIL  contract $name missing vectors/"); FAIL=$((FAIL+1)); }
  done
  # vectors execute inside `cargo test` (chain crate integration tests)
fi

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
  return 0
}
if [ -f "$ROOT/rust/rust-toolchain.toml" ] || [ -f "$ROOT/.github/workflows/gate.yml" ]; then
  run_check "toolchain pins (D-024)" toolchain_pins
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
    '*key.properties' '.env' '.env.*' 'id_rsa*' 'docs/environment.local.md')"
  if [ -n "$tracked" ]; then
    echo "   secret-shaped files are git-tracked:"; echo "$tracked" | sed 's/^/     /'
    bad=1
  fi
  # Same pinning as above — `git grep` searches an index, and a steered index is the
  # wrong index. All three git reads in this file are now unsteerable.
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
internal_record() {
  local tracked
  require_git_repo || { echo "   not a git repository — boundary unverifiable, failing closed"; return 1; }
  # --git-dir/--work-tree pinned, not `-C`: the ops mirror shares this working tree, so
  # an exported GIT_DIR in the environment would otherwise point this check at the ops
  # index and list all 400+ record files — a spurious RED, and a spuriously red check is
  # how a real check earns a `git rm` from the ledger.
  tracked="$(git --git-dir="$ROOT/.git" --work-tree="$ROOT" ls-files -- 'docs/' 'CLAUDE.md' '.claude/')"
  [ -z "$tracked" ] && return 0
  echo "   the engineering record is ops-mirror-only (D-102), but these are tracked here:"
  echo "$tracked" | sed 's/^/     /'
  echo "   fix: git rm -r --cached <path>   — the files stay on disk; 'git ops' tracks them"
  return 1
}
run_check "internal-record boundary (D-102)" internal_record

# ── Summary ─────────────────────────────────────────────────────
echo; echo "══════════ GATE SUMMARY ══════════"
printf '%s\n' "${RESULTS[@]:-"(no checks ran)"}"
echo "──────────────────────────────────"
echo "pass=$PASS fail=$FAIL skip=$SKIP"
if [ "$FAIL" -gt 0 ]; then echo "GATE: RED"; exit 1; fi
# Strict mode (CI, D-024): a SKIP means a tool is missing — on a runner that is a
# provisioning bug, not an acceptable gap, or CI reads green while checking less
# than the local gate does.
if [ "${GATE_STRICT:-0}" = "1" ] && [ "$SKIP" -gt 0 ]; then
  echo "GATE: RED (strict — $SKIP skipped check(s); provision the missing tool)"
  exit 1
fi
if [ "$PASS" -eq 0 ]; then echo "GATE: NOTHING TO CHECK (scaffold state)"; exit 0; fi
echo "GATE: GREEN"
