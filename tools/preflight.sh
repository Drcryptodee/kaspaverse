#!/usr/bin/env bash
# Executed session orientation (governance upgrade U5): the new session RUNS this and
# diffs the output against the expected-state block in the next-session baton.
# The marked lines below reach into the ops-mirror record on purpose: this script
# IS the internal session ritual, and every read degrades when the tree is
# absent. The marker is PER LINE (the gate's filter is line-scoped) — a new line
# here naming an internal file needs its own. gate-allow:internal-path
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
echo "═════════ PREFLIGHT — kaspa-verse ═════════"
echo "• date:    $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "• branch:  $(git branch --show-current 2>/dev/null || echo 'NO GIT')"
echo "• dirty:   $(git status --porcelain 2>/dev/null | wc -l) uncommitted paths"
echo "• last 5 commits:"
git log --oneline -5 2>/dev/null | sed 's/^/    /' || echo "    (none)"
# The engineering record went ops-mirror-only at D-102, so `docs/` is simply ABSENT in a
# public clone. Guard every docs-dependent line the same way the playbook line below is
# guarded, rather than printing instructions nobody can follow ("check PHASE_INDEX",
# "diff against NEXT_SESSION.md") against files that are not there.
HAVE_DOCS=0; [ -d docs ] && HAVE_DOCS=1
if [ "$HAVE_DOCS" = 1 ]; then
  echo "• active phase: $(ls docs/phases/*_ACTIVE.md 2>/dev/null | xargs -n1 basename 2>/dev/null || echo 'NONE — check PHASE_INDEX')" # gate-allow:internal-path
else
  echo "• active phase: (docs/ not present — engineering record is ops-mirror-only, D-102)"
fi
# Reasoning playbook (ops-layer; absent in public clones — conditional on purpose).
[ -f .claude/playbook/INDEX.md ] && echo "• playbook: $(grep -c '^- PB-' .claude/playbook/INDEX.md) reasoning patterns — read .claude/playbook/INDEX.md before building" # gate-allow:internal-path
echo "• rust workspace: $([ -f rust/Cargo.toml ] && echo present || echo absent)"
if [ -f rust/Cargo.toml ]; then
  echo "    rusty-kaspa pin: $(grep -m1 -E 'rusty-kaspa|kaspa-wrpc-client' rust/Cargo.toml rust/*/Cargo.toml 2>/dev/null | head -1 || echo 'not found')"
fi
echo "• flutter app: $([ -f pubspec.yaml ] && echo present || echo absent)"
echo "• contracts: $(ls -d contracts/*/ 2>/dev/null | wc -l) defined"
# rustc is probed from rust/, NOT the repo root: rust-toolchain.toml governs that
# subtree only, so a root-level `rustc --version` reports whatever the default stable
# happens to be and hides a missing pin — this line printed 1.97.1 on a machine whose
# builds all used 1.94.0 (L84). frb-codegen is listed because the gate silently drops
# the codegen-drift check without it; the inventory must name every tool the gate needs.
# Captured into vars first, then defaulted: `cmd | cut ... || echo missing` can never
# report missing, because the pipeline's exit status is CUT's and cut succeeds on empty
# input. Same masking bug as piping a build through `tail`.
RUSTC_V="$( (cd "$ROOT/rust" 2>/dev/null && rustc --version 2>/dev/null) | cut -d' ' -f2)"
FLUTTER_V="$(flutter --version 2>/dev/null | head -1 | cut -d' ' -f2)"
echo "• toolchain: rustc=${RUSTC_V:-missing}" \
     "flutter=${FLUTTER_V:-missing}" \
     "cargo-ndk=$(command -v cargo-ndk >/dev/null && echo yes || echo no)" \
     "cargo-deny=$(command -v cargo-deny >/dev/null && echo yes || echo no)" \
     "frb-codegen=$(command -v flutter_rust_bridge_codegen >/dev/null && echo yes || echo no)"
# adb lives in the local SDK install (P0.3), not on PATH in fresh shells.
# Env var first, then both SDK roots this project has used — see gate.sh's NDK
# discovery for why a single hardcoded root is not enough (2026-08-12 migration).
command -v adb >/dev/null || PATH="$PATH:${ANDROID_HOME:-/nonexistent}/platform-tools:$HOME/sdk/android/platform-tools:$HOME/Android/Sdk/platform-tools"
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
if [ "$HAVE_DOCS" = 1 ]; then
  TRIG_LINES="$(grep -rnE '\[TRIGGER(\]|:)' docs/ 2>/dev/null | grep -v 'TRIGGER-FIRED' || true)"
  TRIG_N="$(printf '%s\n' "$TRIG_LINES" | grep -c . || true)"
  TRIG_BY="$(printf '%s\n' "$TRIG_LINES" | grep . | sed -E 's|^docs/(([^/:]*/)*)([^:]*):.*|\3|' \
      | sed 's/\.md$//' | sort | uniq -c | awk '{printf "%s %s · ", $2, $1}' | sed 's/ · $//')"
  echo "• armed triggers: ${TRIG_N}${TRIG_BY:+  ($TRIG_BY)} — grep -rnE '\[TRIGGER(\]|:)' docs/"
fi
# PNN beacon floor (D-201 / D-183 trigger T-C). The reading itself needs the network and
# stays MANUAL in tools/beacon_floor.sh; this line is offline by construction — it only
# compares the date that tool stamped into itself against today. T-C is the one re-pin
# trigger with no instrument until now, and a manual instrument nobody is told to run is
# how it got that way, so the nudge lives here rather than in anyone's memory.
if [ -x tools/beacon_floor.sh ]; then
  BEACON_DATE=""; BEACON_Y=0; BEACON_B=0; BEACON_TOT=0
  read -r BEACON_DATE BEACON_Y BEACON_B BEACON_TOT <<< "$(bash tools/beacon_floor.sh --stamp 2>/dev/null || true)"
  if [ -n "$BEACON_DATE" ]; then
    BEACON_AGE=$(( ( $(date -u +%s) - $(date -u -d "$BEACON_DATE" +%s 2>/dev/null || echo 0) ) / 86400 ))
    BEACON_NOTE=""
    [ "$BEACON_AGE" -gt 30 ] && BEACON_NOTE="  ← STALE (>30d): run tools/beacon_floor.sh --record"
    # Re-run the DERIVED test on the stamped numbers, offline: breach iff 10*b^5 > (y+b)^5.
    # The exponent is RACE_FETCHES (dag_monitor.rs), 5 since LINK-P2; it must track that
    # constant and tools/beacon_floor.sh's copy of the same derivation.
    # Staleness alone is not the alarm — a fresh reading that is BELOW the floor would
    # otherwise print as current and unremarkable, which is the exact failure D-201 exists
    # to stop one layer down.
    BEACON_DEN=$((BEACON_Y + BEACON_B))
    if [ "$BEACON_DEN" -gt 0 ] && [ $((10 * BEACON_B * BEACON_B * BEACON_B * BEACON_B * BEACON_B)) -gt $((BEACON_DEN * BEACON_DEN * BEACON_DEN * BEACON_DEN * BEACON_DEN)) ]; then
      BEACON_NOTE="${BEACON_NOTE}  ← BELOW FLOOR: D-183 trigger T-C has FIRED (re-run to confirm, then report)"
    fi
    echo "• beacon floor: ${BEACON_Y}/${BEACON_TOT} node-yielding, ${BEACON_B} hung, at ${BEACON_DATE} (${BEACON_AGE}d ago)${BEACON_NOTE}"
  fi
fi
echo "═══════════════════════════════════════════"
if [ "$HAVE_DOCS" = 1 ]; then
  echo "Next: diff against expected-state in docs/sessions/NEXT_SESSION.md" # gate-allow:internal-path
else
  echo "Public clone: code, CI and tooling only. Build with tools/gate.sh; see CONTRIBUTING.md."
fi
