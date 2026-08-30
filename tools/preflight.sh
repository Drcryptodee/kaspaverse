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
# The standing link prober (D-220). It RETIRES ITSELF once its census is complete, but a
# self-retiring cron job that nobody is told about is still a cron job nobody remembers —
# so its state is printed here, where every session starts. Three things can be true and
# all three matter: running (and how fresh), retired (and why), or armed-but-dead.
PROBE_DIR="${KV_LINK_PROBE_DIR:-$HOME/kv-link-probe}"
if [ -f "$PROBE_DIR/RETIRED.md" ]; then
  echo "• link prober: RETIRED — $(sed -n 's/^\*\*Why it stopped:\*\* //p' "$PROBE_DIR/RETIRED.md" | cut -c1-90)"
elif [ -s "$PROBE_DIR/link_probe.tsv" ]; then
  PROBE_N=$(( $(wc -l < "$PROBE_DIR/link_probe.tsv") - 1 ))
  PROBE_LAST=$(tail -1 "$PROBE_DIR/link_probe.tsv" | cut -f2)
  PROBE_AGE=$(( ( $(date -u +%s) - ${PROBE_LAST:-0} ) / 60 ))
  PROBE_FAULT=$(tail -n +2 "$PROBE_DIR/link_probe.tsv" | awk -F'\t' '
    $13=="no-net"||$13=="lit4-down"||$13=="no-v6-iface"{next}
    {seen++; if($13=="v6-hosts-dead"||$13=="v6-link-dead") bad++}
    END{ if(seen) printf "%.0f%% faulted", 100*(bad+0)/seen }')
  PROBE_NOTE=""
  # Armed but not writing is the failure mode that looks exactly like "no fault today".
  [ "$PROBE_AGE" -gt 30 ] && crontab -l 2>/dev/null | grep -q link_probe \
    && PROBE_NOTE="  ← STALE (${PROBE_AGE}m): cron armed but not writing"
  echo "• link prober: ${PROBE_N} rounds, ${PROBE_FAULT}, last ${PROBE_AGE}m ago (retires at 2016 rounds or 30d — tools/link_probe.sh --summary)${PROBE_NOTE}"
fi
# The REMOTE gate — the one D-094 actually gates a push on, and the one nothing in
# this ritual used to read. A lane can be green on this machine and red on a cold
# runner: the advisory-DB freshness check asserted its freshness from `.git/FETCH_HEAD`,
# which `git fetch` writes and `git clone` never does, so it passed here (an old clone,
# fetched since) and RED'd on CI (a fresh clone) — for six consecutive pushes across
# 21 hours, unnoticed, because the record lived only in GitHub (D-224).
#
# One API call, hard-timeouted, never fatal, and silent when `gh` is missing or
# unauthenticated so a public clone prints nothing odd. It reports the newest run and
# says plainly when that run is not the commit sitting in this tree.
if command -v gh >/dev/null 2>&1 && timeout 10 gh auth status >/dev/null 2>&1; then
  CI_RUN=$(timeout 15 gh run list --workflow=gate.yml --limit 1 \
             --json status,conclusion,headSha \
             --jq '.[0] | "\(.status)|\(.conclusion)|\(.headSha)"' 2>/dev/null)
  if [ -n "$CI_RUN" ]; then
    CI_STATUS=${CI_RUN%%|*}; CI_REST=${CI_RUN#*|}
    CI_CONC=${CI_REST%%|*}; CI_SHA=${CI_REST#*|}
    CI_WHERE=$([ "$CI_SHA" = "$(git rev-parse HEAD 2>/dev/null)" ] \
                 && echo "this HEAD" || echo "${CI_SHA%"${CI_SHA#???????}"} — NOT this HEAD")
    if [ "$CI_STATUS" != "completed" ]; then
      echo "• remote gate: $CI_STATUS on $CI_WHERE"
    elif [ "$CI_CONC" = "success" ]; then
      echo "• remote gate: GREEN on $CI_WHERE"
    else
      echo "• remote gate: $(echo "$CI_CONC" | tr '[:lower:]' '[:upper:]') on $CI_WHERE  <- investigate BEFORE building"
      echo "    gh run view --log-failed   (a red remote gate means a push went out on one — D-094 says green only)"
    fi
  fi
fi
# Disk headroom. Build caches here are pure REGENERABLE artifact — `rust/target` reached
# 62 GB and `build/` 24 GB by 2026-08-29, and a full clean of both returned 86 GB in 11 s —
# so running out of space is a self-inflicted wound, and it already cost one session
# (`cargo` failing `No space left on device` mid-sitting). This WARNS; it never deletes.
#
# Deliberately not a cron job. A `cargo clean` on a timer eventually fires DURING a build
# and corrupts it, and it taxes a random future session with a cold rebuild for no reason.
# Session open is the one moment nothing is compiling, which is why the check lives here
# and hands you the command instead of running it.
#
# The threshold is MEASURED (2026-08-29, from cold after the big clean): a fresh full build
# of both trees is 12.2 G (`rust/target` 12 G + `build` 176 M), and `debug/incremental` was
# separately observed at 19 G, so ~31 G is a legitimate working set rather than waste. 40 G
# warns with ~9 G of slack — early enough to act unhurried, not at the cliff. For scale, the
# cold gate that produced these numbers took 745 s while SHARING the machine with an
# unrelated container build, so a rebuild is minutes, not an afternoon: this warning is
# never a reason to postpone cleaning.
DISK_FREE_G=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "$DISK_FREE_G" ]; then
  if [ "$DISK_FREE_G" -lt 40 ]; then
    echo "• disk: ${DISK_FREE_G}G free  ← LOW. Reclaim (regenerable, ~11 s to clean):"
    echo "    flutter clean && cargo clean --manifest-path rust/Cargo.toml"
    # Half this machine's disk is NOT the project — /var/lib/containerd held 61 G on
    # 2026-08-29 — so say where to look before anyone cleans the wrong tree twice.
    echo "    if that is not enough, look OUTSIDE the repo too: du -xh --max-depth=1 /var/lib"
  else
    echo "• disk: ${DISK_FREE_G}G free"
  fi
fi
echo "═══════════════════════════════════════════"
if [ "$HAVE_DOCS" = 1 ]; then
  echo "Next: diff against expected-state in docs/sessions/NEXT_SESSION.md" # gate-allow:internal-path
else
  echo "Public clone: code, CI and tooling only. Build with tools/gate.sh; see CONTRIBUTING.md."
fi
