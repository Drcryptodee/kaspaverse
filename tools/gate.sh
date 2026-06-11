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
      git -C "$ROOT" diff --exit-code --quiet -- lib/src/rust/ || {
        echo "   generated bindings differ from committed ones — run codegen and commit"
        return 1
      }
    }
    run_check "codegen drift (lib/src/rust/)" codegen_drift
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
repo_hygiene() {
  local bad=0
  local tracked
  tracked="$(git -C "$ROOT" ls-files -- '*.keystore' '*.jks' '*.p12' '*.pem' \
    '*key.properties' '.env' '.env.*' 'id_rsa*' 'docs/environment.local.md')"
  if [ -n "$tracked" ]; then
    echo "   secret-shaped files are git-tracked:"; echo "$tracked" | sed 's/^/     /'
    bad=1
  fi
  if git -C "$ROOT" grep -lI -e "BEGIN .*PRIVATE KEY" -- ':!tools/gate.sh' >/dev/null 2>&1; then
    echo "   a tracked file contains PEM private-key material:"
    git -C "$ROOT" grep -lI -e "BEGIN .*PRIVATE KEY" -- ':!tools/gate.sh' | sed 's/^/     /'
    bad=1
  fi
  return $bad
}
run_check "public-repo hygiene (no tracked secrets)" repo_hygiene

# ── Summary ─────────────────────────────────────────────────────
echo; echo "══════════ GATE SUMMARY ══════════"
printf '%s\n' "${RESULTS[@]:-"(no checks ran)"}"
echo "──────────────────────────────────"
echo "pass=$PASS fail=$FAIL skip=$SKIP"
if [ "$FAIL" -gt 0 ]; then echo "GATE: RED"; exit 1; fi
if [ "$PASS" -eq 0 ]; then echo "GATE: NOTHING TO CHECK (scaffold state)"; exit 0; fi
echo "GATE: GREEN"
