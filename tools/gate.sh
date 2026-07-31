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
  if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    for d in "$HOME"/android-ndk-r* "$HOME"/Android/Sdk/ndk/*; do
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
