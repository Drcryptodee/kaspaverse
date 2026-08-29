#!/usr/bin/env bash
# link_probe.sh — the standing instrument for the INTERMITTENT broken-v6 dial (L137, D-219).
#
# WHY THIS EXISTS. Every record on this lane called the broken-v6 path a standing property of
# the founder's link, because every probe that ever ran, ran while it was broken — not one
# negative control had ever been taken. On 2026-08-29 the same host answered over v6 in 265 ms
# that had timed out six hours earlier. The fault comes and goes on a timescale of HOURS, so it
# cannot be closed by a scheduled sitting; it needs an instrument already running when it
# returns. This is that instrument. Its job is to make the DUTY CYCLE knowable.
#
# Two properties it must have, because their absence is what made it necessary:
#   1. it records SUCCESSES as well as failures — a log of only outages cannot tell you what
#      fraction of the day is healthy, which is the whole L137 hole;
#   2. it probes the v6 LITERAL every round — so a v6 outage is always distinguishable from a
#      host-specific one at write time, never re-derived at read time.
#
# SCOPE. A dev instrument on the build host. NOT a product feature: nothing here goes in the
# app, nothing here touches rust/. INV-8 governs the product's runtime, not the workbench
# (the on-chain-audit precedent). It writes OUTSIDE the repo so a reading can never be
# committed.
#
#   ./tools/link_probe.sh              # one round, append one TSV line
#   ./tools/link_probe.sh --summary    # duty cycle over what has been recorded
#   ./tools/link_probe.sh --selftest   # prove the classifier and the probe can both see
#   ./tools/link_probe.sh --install    # install the every-5-minutes cron entry
#   ./tools/link_probe.sh --uninstall  # remove it
#
# IT RETIRES ITSELF. An instrument with no end condition is a cron job nobody remembers
# and everybody eventually distrusts, so this one carries its own stopping rule and
# executes it. After each round it asks whether the census is COMPLETE, and if it is, it
# removes its own crontab line, writes `RETIRED.md` beside the data and stops. Complete
# means BOTH of:
#   - CENSUS_ROUNDS rounds recorded (7 days at the 5-minute cadence), and
#   - both states actually observed — at least one `ok` round AND at least one fault
#     round. A census that only ever saw one state has not measured a duty cycle, it has
#     measured a constant, and stopping there would recreate the exact L137 hole this
#     instrument exists to close.
# Backstop: MAX_DAYS since the first row retires it regardless, and says in RETIRED.md
# that it stopped on time rather than on evidence — a run that cannot finish its census
# in a month is answering a different question than the one it was built for.
# `tools/preflight.sh` prints its state at every session open, so neither the running nor
# the retirement can go unnoticed. Retiring never deletes data.
#
# READING A ROW. The verdict column is the answer; the millisecond columns are the evidence.
# `X` means the probe did not connect inside CONNECT_TIMEOUT. The row to look for before
# taking a device measurement is `v6-hosts-dead` — that is the fault present, and it is D-216's
# deliberately NARROW claim (the v6 path to THESE hosts), not "IPv6 is broken", which the v6
# literal control refutes in the same row.
set -uo pipefail

SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
OUT_DIR="${KV_LINK_PROBE_DIR:-$HOME/kv-link-probe}"
TSV="$OUT_DIR/link_probe.tsv"
CONNECT_TIMEOUT=5           # a healthy connect to these hosts is 0.17-0.40 s (D-219)
MAX_TIME=8
CENSUS_ROUNDS=2016          # 7 days at one round per 5 minutes
MAX_DAYS=30                 # backstop, whatever the census says
RETIRED="$OUT_DIR/RETIRED.md"

# The three wRPC hosts are the EXACT hosts of D-219's table, so every row here is directly
# comparable to the recorded baseline rather than to a new set nobody has a good-day reading
# for. A retired host cannot fake the fault: the fault requires v4 UP and v6 DOWN, and a host
# that has gone away fails both families, which the verdict reports as `hosts-down`.
HOSTS=(lola.kaspa.blue ava.kaspa.stream luna.kaspa.blue)
# The literal controls. `2606:4700:4700::1111` is the one D-216 used to refuse the too-strong
# "IPv6 is broken link-wide" claim; `1.1.1.1` is its v4 twin and the control for the CONTROL —
# if both literals fail, this host is simply offline and NOTHING else in the row may be read
# as a fault (L106: prove the instrument can see before believing what it did not see).
LIT4=1.1.1.1
LIT6=2606:4700:4700::1111

HEADER=$'ts_utc\tepoch\tiface\tv6_iface\tlit4\tlit6\tlola4\tlola6\tava4\tava6\tluna4\tluna6\tverdict'

# One TCP+TLS connect on one family. Echoes milliseconds, or X if it did not connect.
# `time_connect` is the right measure: the fault D-217 vendored a dialer for is a
# `TcpStream::connect` to the AAAA that never completes, so the TCP handshake IS the subject.
probe() {
  local fam="$1" target="$2" t
  t=$(curl -s -o /dev/null "-$fam" --connect-timeout "$CONNECT_TIMEOUT" -m "$MAX_TIME" \
        -w '%{time_connect}' "https://${target}/" 2>/dev/null) || t=""
  if [ -z "$t" ] || [ "$t" = "0.000000" ]; then echo X
  else awk -v s="$t" 'BEGIN{ printf "%d", s*1000 }'; fi
}

# The verdict cascade, kept PURE so it can be proven without a network (--selftest). An
# instrument whose classifier is wrong runs for weeks and reports `ok` through the very outage
# it was built to catch, and nothing about it looks broken — so the classifier gets a prover,
# exactly as L136 demands of an induced fault.
#
# Order matters: a clause may only be reached once every clause that would INVALIDATE it has
# been ruled out. The INSTRUMENT's own health is judged before the link's, because a reading
# taken through a blind instrument is worse than no reading (L106).
classify() {
  local l4="$1" l6="$2" v6if="$3" v4bad="$4" v6bad="$5"
  if   [ "$l4" = X ] && [ "$l6" = X ]; then echo no-net          # this host is offline; read nothing else
  elif [ "$l4" = X ];                  then echo lit4-down       # v4 control gone: instrument suspect
  elif [ "$v6if" = no ];               then echo no-v6-iface     # no global v6 to fail with
  elif [ "$l6" = X ] && [ "$v6bad" = 3 ]; then echo v6-link-dead # v6 dead link-wide, literal included
  elif [ "$l6" = X ];                  then echo lit6-down       # literal dead but hosts fine: note it
  elif [ "$v4bad" = 3 ];               then echo hosts-down      # both families gone: not the v6 fault
  elif [ "$v6bad" = 3 ];               then echo v6-hosts-dead   # THE FAULT (D-216's narrow claim)
  elif [ "$v6bad" -gt 0 ];             then echo v6-partial
  else                                      echo ok
  fi
}

# Prove the instrument can SEE, in both directions, before any reading is trusted.
selftest() {
  local fails=0 got
  check() { # expected l4 l6 v6if v4bad v6bad
    got=$(classify "$2" "$3" "$4" "$5" "$6")
    if [ "$got" = "$1" ]; then printf '  ok   %-14s\n' "$1"
    else printf '  FAIL expected %-14s got %s\n' "$1" "$got"; fails=$((fails+1)); fi
  }
  echo "classifier:"
  #      expected        lit4  lit6  v6if  v4bad v6bad
  check  ok              120   30    yes   0     0
  check  v6-hosts-dead   120   30    yes   0     3      # <- the row a device sitting waits for
  check  v6-partial      120   30    yes   0     1
  check  v6-link-dead    120   X     yes   0     3
  check  lit6-down       120   X     yes   0     0
  check  hosts-down      120   30    yes   3     3      # both families gone: NOT the v6 fault
  check  no-v6-iface     120   30    no    0     3      # no global v6: says nothing about the fault
  check  no-net          X     X     yes   3     3
  check  lit4-down       X     30    yes   0     0
  # The classifier is only half of it: a probe that can never RETURN X would keep the
  # `v6-hosts-dead` row permanently unreachable while every unit above passed. So make the
  # probe actually fail, against RFC 6666's discard prefix, and make it actually succeed.
  echo "probe:"
  got=$(probe 6 "[0100::1]")
  if [ "$got" = X ]; then echo "  ok   probe returns X on a blackholed v6 literal"
  else echo "  FAIL probe returned '$got' for a discard-prefix address"; fails=$((fails+1)); fi
  got=$(probe 4 "$LIT4")
  if [ "$got" != X ]; then echo "  ok   probe returns ${got}ms on the live v4 literal"
  else echo "  FAIL probe could not reach $LIT4 — rerun on a working network"; fails=$((fails+1)); fi
  [ "$fails" = 0 ] && { echo "link probe selftest: PASS"; return 0; }
  echo "link probe selftest: $fails FAILED"; return 1
}

take_round() {
  local tmp; tmp=$(mktemp -d)
  # Every probe in parallel, so the row is an INSTANT rather than a 40 s smear across targets.
  probe 4 "$LIT4"                 > "$tmp/lit4" &
  probe 6 "[$LIT6]"               > "$tmp/lit6" &
  local i=0 h
  for h in "${HOSTS[@]}"; do
    probe 4 "$h" > "$tmp/h${i}_4" &
    probe 6 "$h" > "$tmp/h${i}_6" &
    i=$((i+1))
  done
  wait
  L4=$(cat "$tmp/lit4"); L6=$(cat "$tmp/lit6")
  H4=(); H6=()
  for i in 0 1 2; do H4+=("$(cat "$tmp/h${i}_4")"); H6+=("$(cat "$tmp/h${i}_6")"); done
  rm -rf "$tmp"

  IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}'); IFACE="${IFACE:-?}"
  # A global v6 address on the interface. Without one, a v6 failure says nothing about the
  # fault — the host simply has no v6 to fail with. ULAs (fd00::/8) are NOT global routing.
  if ip -6 addr show scope global 2>/dev/null | grep -qE 'inet6 (2|3)'; then V6IF=yes; else V6IF=no; fi

  local v6bad=0 v4bad=0
  for i in 0 1 2; do
    [ "${H6[$i]}" = X ] && v6bad=$((v6bad+1))
    [ "${H4[$i]}" = X ] && v4bad=$((v4bad+1))
  done

  VERDICT=$(classify "$L4" "$L6" "$V6IF" "$v4bad" "$v6bad")

  mkdir -p "$OUT_DIR"
  [ -s "$TSV" ] || printf '%s\n' "$HEADER" > "$TSV"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(date -u '+%s')" "$IFACE" "$V6IF" \
    "$L4" "$L6" "${H4[0]}" "${H6[0]}" "${H4[1]}" "${H6[1]}" "${H4[2]}" "${H6[2]}" \
    "$VERDICT" >> "$TSV"
  printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$VERDICT"
  retire_if_done
}

# Has the census run its course? Called after every round. Retiring removes the cron
# entry, writes the verdict beside the data, and leaves every row intact.
retire_if_done() {
  [ -s "$TSV" ] || return 0
  local n first_epoch days ok_n bad_n reason=""
  n=$(( $(wc -l < "$TSV") - 1 ))
  first_epoch=$(sed -n '2p' "$TSV" | cut -f2)
  days=$(( ( $(date -u '+%s') - ${first_epoch:-0} ) / 86400 ))
  ok_n=$(tail -n +2 "$TSV"  | awk -F'\t' '$13 == "ok" { n++ } END { print n+0 }')
  bad_n=$(tail -n +2 "$TSV" | awk -F'\t' '$13 == "v6-hosts-dead" || $13 == "v6-link-dead" { n++ } END { print n+0 }')

  if [ "$n" -ge "$CENSUS_ROUNDS" ] && [ "$ok_n" -gt 0 ] && [ "$bad_n" -gt 0 ]; then
    reason="census complete — ${n} rounds over ${days} day(s), and BOTH states were observed (${ok_n} clear, ${bad_n} faulted), so the duty cycle is measured rather than assumed"
  elif [ "$days" -ge "$MAX_DAYS" ]; then
    reason="backstop — ${days} days elapsed. The census did NOT complete on evidence: ${n} of ${CENSUS_ROUNDS} rounds, ${ok_n} clear, ${bad_n} faulted. Read the duty cycle below as provisional, and note WHICH state is missing if either count is zero: a run that only ever saw one state measured a constant, not a cycle"
  else
    return 0
  fi

  crontab -l 2>/dev/null | grep -vF "$SELF_PATH" | crontab - 2>/dev/null
  {
    echo "# link_probe — RETIRED $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    echo "**Why it stopped:** $reason"
    echo
    echo "The cron entry has been removed. Nothing was deleted: \`link_probe.tsv\` holds every"
    echo "round and \`--summary\` still reads it. Re-arm with \`--install\` if the question comes"
    echo "back (delete this file first, or it will retire again on the next round)."
    echo
    echo '```'
    summary
    echo '```'
  } > "$RETIRED"
  echo "link probe: RETIRED — $reason"
  echo "  wrote $RETIRED; cron entry removed; data kept."
}

summary() {
  [ -s "$TSV" ] || { echo "link probe: no readings yet at $TSV"; exit 0; }
  local n; n=$(( $(wc -l < "$TSV") - 1 ))
  echo "link probe: $n rounds recorded at $TSV"
  echo "  first: $(sed -n '2p' "$TSV" | cut -f1)    last: $(tail -1 "$TSV" | cut -f1)"
  echo "  verdict duty cycle —"
  tail -n +2 "$TSV" | awk -F'\t' '{c[$13]++; t++} END {
    for (v in c) printf "    %-14s %5d  %5.1f%%\n", v, c[v], 100*c[v]/t }' | sort -k2 -rn
  # The number the whole instrument exists to produce, stated as a fraction of rounds in
  # which the instrument could actually see (L106) — never of all rounds.
  tail -n +2 "$TSV" | awk -F'\t' '
    $13 == "no-net" || $13 == "lit4-down" || $13 == "no-v6-iface" { next }
    { seen++; if ($13 == "v6-hosts-dead" || $13 == "v6-link-dead") bad++ }
    END { if (seen) printf "  FAULT PRESENT in %d of %d readable rounds (%.1f%%)\n", bad+0, seen, 100*(bad+0)/seen }'
}

case "${1:-}" in
  --summary) summary ;;
  --selftest) selftest ;;
  --install)
    LINE="*/5 * * * * $SELF_PATH >> $OUT_DIR/cron.log 2>&1"
    ( crontab -l 2>/dev/null | grep -vF "$SELF_PATH"; echo "$LINE" ) | crontab -
    echo "link probe: installed — $LINE"; crontab -l | grep -F "$SELF_PATH" ;;
  --uninstall)
    crontab -l 2>/dev/null | grep -vF "$SELF_PATH" | crontab -
    echo "link probe: removed" ;;
  "")
    # Already retired: say so and do nothing. A retired instrument that quietly keeps
    # recording is worse than one that never stopped, because its own verdict is stale.
    if [ -f "$RETIRED" ]; then
      head -3 "$RETIRED"; echo "  (delete $RETIRED and --install to re-arm)"; exit 0
    fi
    take_round ;;
  *) echo "usage: $0 [--summary|--selftest|--install|--uninstall]" >&2; exit 2 ;;
esac
