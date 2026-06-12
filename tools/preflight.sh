#!/usr/bin/env bash
# Executed session orientation (governance upgrade U5): the new session RUNS this and
# diffs the output against the expected-state block in docs/sessions/NEXT_SESSION.md.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
echo "═════════ PREFLIGHT — kaspa-verse ═════════"
echo "• date:    $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "• branch:  $(git branch --show-current 2>/dev/null || echo 'NO GIT')"
echo "• dirty:   $(git status --porcelain 2>/dev/null | wc -l) uncommitted paths"
echo "• last 5 commits:"
git log --oneline -5 2>/dev/null | sed 's/^/    /' || echo "    (none)"
echo "• active phase: $(ls docs/phases/*_ACTIVE.md 2>/dev/null | xargs -n1 basename 2>/dev/null || echo 'NONE — check PHASE_INDEX')"
echo "• rust workspace: $([ -f rust/Cargo.toml ] && echo present || echo absent)"
if [ -f rust/Cargo.toml ]; then
  echo "    rusty-kaspa pin: $(grep -m1 -E 'rusty-kaspa|kaspa-wrpc-client' rust/Cargo.toml rust/*/Cargo.toml 2>/dev/null | head -1 || echo 'not found')"
fi
echo "• flutter app: $([ -f pubspec.yaml ] && echo present || echo absent)"
echo "• contracts: $(ls -d contracts/*/ 2>/dev/null | wc -l) defined"
echo "• toolchain: rustc=$(rustc --version 2>/dev/null | cut -d' ' -f2 || echo missing)" \
     "flutter=$(flutter --version 2>/dev/null | head -1 | cut -d' ' -f2 || echo missing)" \
     "cargo-ndk=$(command -v cargo-ndk >/dev/null && echo yes || echo no)" \
     "cargo-deny=$(command -v cargo-deny >/dev/null && echo yes || echo no)"
# adb lives in the local SDK install (P0.3), not on PATH in fresh shells.
command -v adb >/dev/null || PATH="$PATH:$HOME/Android/Sdk/platform-tools"
echo "• android device: $(command -v adb >/dev/null && adb devices 2>/dev/null | sed -n '2p' | awk '{print $1" "$2}' || echo 'adb missing')"
echo "═══════════════════════════════════════════"
echo "Next: diff against expected-state in docs/sessions/NEXT_SESSION.md"
