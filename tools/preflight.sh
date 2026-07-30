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
# Reasoning playbook (ops-layer; absent in public clones — conditional on purpose).
[ -f .claude/playbook/INDEX.md ] && echo "• playbook: $(grep -c '^- PB-' .claude/playbook/INDEX.md) reasoning patterns — read .claude/playbook/INDEX.md before building"
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
# Armed repayment triggers (D-091): a parked decision names its firing condition and
# marks it `[TRIGGER]`, or `[TRIGGER:PUBLISHED]` when the condition is "the first build
# that reaches people who aren't the founder" (tools/release.sh surfaces that subset at
# build time). Repaying one flips its marker to `[TRIGGER-FIRED]`. Surfaced here because
# a trigger nobody reads is not a trigger — the register is the docs themselves.
#
# KNOWN FALSE POSITIVE, diagnose it in ten seconds before you go hunting: any PROSE that
# spells the bracketed marker gets counted as one, because grep cannot tell a commitment
# from a sentence about commitments. It has happened three times in two sessions —
# D-091's own entry, RELEASE.md's checklist step, NEXT_SESSION's P3 note (D-092 ruling 7)
# — so if the count is one high, run the grep below and look for a line that TALKS about
# the marker instead of carrying one. The counter is deliberately left over-counting
# rather than narrowed to the three owner files (DECISION_LOG / IDEAS_BACKLOG /
# PERFORMANCE_BUDGET): a noisy count costs a minute, a MISSED armed trigger is a park
# silently becoming a loss, which is the whole failure this exists to prevent.
TRIG_LINES="$(grep -rnE '\[TRIGGER(\]|:)' docs/ 2>/dev/null | grep -v 'TRIGGER-FIRED' || true)"
TRIG_N="$(printf '%s\n' "$TRIG_LINES" | grep -c . || true)"
TRIG_BY="$(printf '%s\n' "$TRIG_LINES" | grep . | sed -E 's|^docs/(([^/:]*/)*)([^:]*):.*|\3|' \
    | sed 's/\.md$//' | sort | uniq -c | awk '{printf "%s %s · ", $2, $1}' | sed 's/ · $//')"
echo "• armed triggers: ${TRIG_N}${TRIG_BY:+  ($TRIG_BY)} — grep -rnE '\[TRIGGER(\]|:)' docs/"
echo "═══════════════════════════════════════════"
echo "Next: diff against expected-state in docs/sessions/NEXT_SESSION.md"
