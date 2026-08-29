#!/usr/bin/env bash
# beacon_floor.sh — is the PNN resolver beacon fleet still above the floor?
#
# MANUAL, like tools/kcc_freshness.sh, and for the same reason: it needs the network, and
# a gate lane that reds on a plane is a gate lane people learn to mute. NEVER add this to
# tools/gate.sh — the gate is offline and must stay that way. tools/preflight.sh prints a
# STALENESS reminder and re-runs the floor test offline against the stamped numbers, so a
# missed reading and a recorded breach both surface at session open.
#
# Cadence: every 30 days, and ALWAYS before a pin decision (D-183 trigger T-C).
# Owner: the session agent at open, when preflight says stale.
# Runtime ~60 s (the hung beacons each burn the sampler's 10 s cap).
#
#   ./tools/beacon_floor.sh            # take a reading, print the verdict
#   ./tools/beacon_floor.sh --record   # ...and stamp it into this file
#   ./tools/beacon_floor.sh --stamp    # print "DATE YIELDING HUNG TOTAL" (used by preflight)
#
# WHAT IS COUNTED, and why it is not "HTTP 200":
# The pinned resolver's fetch() (rusty-kaspa cfafeb4c, rpc/wrpc/client/src/resolver.rs:155-167)
# shuffles all 16 beacons and walks them SEQUENTIALLY, returning the first that yields a
# NodeDescriptor. Its success test is workflow-http 0.18.0 (native.rs:66-79):
# `status.is_success()` AND `serde_json::from_str`. So a 2xx with an empty or unparseable
# body is a FAILURE to the resolver, and `NodeDescriptor` (node.rs:13-20) has `uid` and
# `url` as REQUIRED fields, so a partial body fails too. A beacon answering 204 No Content
# is reachable and useless. We count NODE-YIELDING beacons — 200 with a real uid parsed —
# and deliberately reject the sampler's `parse-err` and `?` placeholders, which are exactly
# the 2xx-without-a-NodeDescriptor class this tool exists to stop miscounting.
#
# THE TEST IS A RATIO, NOT A COUNT (consensus-auditor, items 21-23):
# reqwest carries no per-request timeout (link.rs:81-91), so our only bound is
# RESOLVER_FETCH_TIMEOUT = 5 s on the WHOLE walk. A beacon that completes TLS and then never
# answers consumes that entire budget by itself; a beacon that fails FAST costs almost
# nothing. So one walk succeeds iff a node-yielding beacon precedes every HUNG beacon in the
# shuffle -> P = y/(y+b), and a race round fires RACE_FETCHES = 5 independent shuffles ->
# P(round) = 1 - (b/(y+b))^5. Requiring a cold start to resolve at least one candidate to
# probe, in ONE round, with >=90% probability gives the breach test used below:
#
#     breach  <=>  (b/(y+b))^5 > 0.10  <=>  10*b^5 > (y+b)^5      (integer, no bc)
#
# THE EXPONENT IS RACE_FETCHES AND IT MOVED AT LINK-P2 (3 -> 5, dag_monitor.rs). It is the
# only term in this derivation the app controls: the beacon list is frozen in the pinned crate
# and the budget is what a USER waits, so fan-out is the one lever that buys robustness for
# free. Keep this file's exponent equal to that constant — a floor computed from a stale
# exponent is not conservative, it is simply wrong, and it is wrong in the silent direction
# (too strict here, so it cries breach on a fleet that is fine). tools/preflight.sh carries
# the same expression for its offline re-run and moves with it.
#
# At today's shape (2 fast failures, so y+b = 14) that threshold sits at y = 6, which is
# where the headline FLOOR below comes from — but the COUNT is only a summary of the ratio.
# Asserting the count alone is wrong in both directions: y=6 with b=11 is a real breach that
# a count test passes (10*11^5 = 1610510 > 17^5 = 1419857, P = 0.887), and y=5 with b=2 is
# fine (P = 0.9981) but a count test fails it. The ratio is the thing that was derived, so
# the ratio is the thing asserted. (Both examples are arithmetic under THIS file's exponent —
# recompute them if it ever moves again; the previous pair was left behind by the 3 -> 5 move
# and asserted a breach the tool does not call.)
#
# Scope: this governs the COLD start only. PANTRY_DIALS = 3 plus the cached endpoint make
# the common warm reconnect resolver-free (link.rs:449-456) — the resolver is an
# accelerator, not a dependency. And it bounds RESOLUTION, not binding: a resolved candidate
# still has to pass candidate_url_is_clean, not be demoted, and win a probe within
# PROBE_TIMEOUT = 4 s. Note also that yielding beacons front FEWER distinct nodes than their
# count suggests (9 beacons fronted 6 distinct nodes on 2026-08-26), so this is an upper
# bound on the diversity actually available.
#
# THE FLEET SHAPE IS STABLE AND THE MARGIN IS NOW THREE, NOT ONE. Four samples on 2026-08-26
# read 9, 9, 9, 8 (mike.kaspa.red flaps between 200 and 500, so the count is 8 on a bad sample
# and 9 on a good one). An independent reading on 2026-08-29 reproduced the shape EXACTLY —
# y=9, b=5, 2 fast-fail, same five hung hosts — so the fleet is not drifting, it is just thin.
# What changed is our side: at RACE_FETCHES=3 the floor was y>=8 and D-201 recorded the
# standing correction that "9 is ample" was wrong, the margin being one host on a good sample
# and zero on a bad one. At 5 the floor is y>=6 and the margin is three. The fleet did not
# improve; the wallet stopped depending on it so tightly.
# Treat a single sub-floor reading as noise and re-run; treat a sustained one as the trigger.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
SELF="$ROOT/tools/beacon_floor.sh"

# Headline floor: the value the ratio test resolves to at today's fleet shape. Documentation
# and preflight's summary line — the assertion below is the ratio, not this number.
FLOOR=6
# Last reading — update via --record. Read by tools/preflight.sh for the staleness nudge
# and for its own offline re-run of the breach test.
LAST_READING=2026-08-29
LAST_YIELDING=9
LAST_HUNG=5
LAST_TOTAL=16

[ "${1:-}" = "--stamp" ] && { echo "$LAST_READING $LAST_YIELDING $LAST_HUNG $LAST_TOTAL"; exit 0; }

CSV=$(bash tools/perf/resolver_sample.sh 2>/dev/null) || {
  echo "beacon floor: SKIP (sampler failed to run)"; exit 0; }
BODY=$(printf '%s\n' "$CSV" | tail -n +2)
TOTAL=$(printf '%s\n' "$BODY" | grep -c ',')
[ "$TOTAL" -gt 0 ] || { echo "beacon floor: SKIP (no rows sampled)"; exit 0; }

# node-yielding: 200 AND a real uid. `parse-err` and a leading `?` are the sampler's
# placeholders for a body serde would reject — they are NOT nodes.
YIELD=$(printf '%s\n' "$BODY" | awk -F, '$2 == "200" && $3+0 < 5 && $4 != "" && $4 !~ /^parse-err/ && $4 !~ /^\?/ { n++ } END { print n+0 }')
# hung: no response AND it actually burned the budget. A host that fails to connect in
# milliseconds is a FAST failure — the opposite input to the derivation above.
HUNG=$(printf '%s\n'  "$BODY" | awk -F, '$3+0 >= 5 { n++ } END { print n+0 }')
FAST=$((TOTAL - YIELD - HUNG))
# The model is exact only while the walk can AFFORD its fast failures: a shuffle that meets
# every fast failure and then the slowest yielder must still land inside the 5 s budget.
# Printed and warned on, never fatal — it bounds the model's accuracy, not the fleet's health.
BUDGET=$(printf '%s\n' "$BODY" | awk -F, '
  $3+0 >= 5 { next }
  $2 == "200" && $4 != "" && $4 !~ /^parse-err/ && $4 !~ /^\?/ { if ($3+0 > slow) slow = $3+0; next }
  { fast += $3+0 }
  END { printf "%.2f %.2f %d", fast+0, slow+0, (fast+slow >= 5 ? 1 : 0) }')
FAST_SECS="${BUDGET%% *}"; BUDGET_TIGHT="${BUDGET##* }"; SLOW_YIELD="$(printf '%s' "$BUDGET" | cut -d' ' -f2)"

echo "beacon floor: ${YIELD}/${TOTAL} node-yielding · ${FAST} fast-fail · ${HUNG} hung   (headline floor ${FLOOR}, last ${LAST_READING}: ${LAST_YIELDING})"
echo "    walk budget: ${FAST_SECS}s of fast failures + ${SLOW_YIELD}s slowest yielder, against RESOLVER_FETCH_TIMEOUT 5s"
printf '%s\n' "$BODY" | awk -F, '{ printf "    %-28s %-4s %6.2fs %s\n", $1, $2, $3, ($4=="" ? "(no node)" : $4) }'

# Not one node in the whole fleet is far more likely to be OUR network than theirs — a
# captive portal answers 2xx HTML for all 16 and a dead link answers nothing. Same judgment
# link.rs makes about a race round before convicting any endpoint (phone_fault_in_round).
# Keyed on YIELD alone, not on the failure shape: a real total fleet death still survives
# the re-run this tool demands. Never cry wolf on a plane, and never stamp a fiction.
if [ "$YIELD" = 0 ]; then
  echo "beacon floor: SKIP (0 of ${TOTAL} yielded a node — almost certainly link blackout or a"
  echo "  captive portal, not fleet death). Nothing recorded. Re-run on a known-good network."
  exit 0
fi

# The derived test. Integer arithmetic only: breach iff 10*b^5 > (y+b)^5. The exponent is
# RACE_FETCHES (dag_monitor.rs) — see the derivation above; 16^5*10 is far inside 64-bit.
DEN=$((YIELD + HUNG))
BREACH=0
[ $((10 * HUNG * HUNG * HUNG * HUNG * HUNG)) -gt $((DEN * DEN * DEN * DEN * DEN)) ] && BREACH=1

if [ "${1:-}" = "--record" ]; then
  TODAY=$(date -u '+%Y-%m-%d')
  if sed -i "s/^LAST_READING=.*/LAST_READING=${TODAY}/; s/^LAST_YIELDING=.*/LAST_YIELDING=${YIELD}/; s/^LAST_HUNG=.*/LAST_HUNG=${HUNG}/; s/^LAST_TOTAL=.*/LAST_TOTAL=${TOTAL}/" "$SELF"; then
    echo "beacon floor: recorded y=${YIELD} b=${HUNG} of ${TOTAL} at ${TODAY} — also append the row to the external-reference register (D-201)"
  else
    echo "beacon floor: WARNING — could not stamp ${SELF}; record the reading by hand"
  fi
fi

if [ "$BREACH" = 1 ]; then
  echo "beacon floor: BREACH — y=${YIELD} b=${HUNG} gives P(round) < 0.90. D-183 trigger T-C has FIRED."
  echo "  RE-RUN BEFORE ACTING: hosts flap (mike.kaspa.red was seen at both 200 and 500"
  echo "  within one hour on 2026-08-26), and one sample of a flapping fleet is noise."
  echo "  The beacon list is frozen in the pinned crate rev, so only a re-pin refreshes it."
  echo "  This is a FINDING to report, not permission to bump: the pin is the founder's call."
  exit 1
fi
[ "$BUDGET_TIGHT" = 1 ] && echo "beacon floor: WARNING — fast failures plus the slowest yielder now exceed the 5 s walk
  budget, so the ratio model understates the risk. The fleet test below is no longer conservative."
echo "beacon floor: OK — y=${YIELD} b=${HUNG}, P(round) >= 0.90. T-C not fired."
exit 0
