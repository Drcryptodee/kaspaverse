#!/usr/bin/env bash
# kcc_freshness.sh — has kaspanet/kccs moved since we recorded it?
#
# MANUAL, run at session open (or before any KCC-derived decision). Deliberately NOT a
# tools/gate.sh lane: it needs the network, and a gate lane that reds on a plane is a gate
# lane people learn to mute. Offline / unreachable / rate-limited => prints SKIP, exits 0.
# Only real upstream drift exits 1, and even then the ruling is a human's.
# The full record lives in the internal research corpus (gate-allow:internal-path — this
# tool is the internal record's own freshness probe); the table is duplicated inline so the
# script still works in the public clone, which carries code and tooling only.
set -uo pipefail
REV=ea5176aa65b14b11be6ff4840ba0076893ada87e   # kaspanet/kccs main @ 2026-08-20T23:18:28Z; read 2026-08-25
PINNED='ce968e3a4941649c46d4b946c34ee8931f9f8a4a README.md
bcb00fbdafcc9582da62b52182c046196e5269c3 kcc-0001.md
4a87ff06eb4a8dfc9152b4423634ddf3e01defa3 kcc-0002.md
e6e96f39a15b0e8bf6a319152a8fa0e54b3c93ab kcc-0002/reference-code.md
2934142610bc43b7bcfb6b633c0c0518af13e906 kcc-0020.md
283f146e688a500bc8de79dad85f9343753c8f2d kcc-0020/borrowed-receive-authorization.md'
TREE=$(curl -fsS --max-time 12 -H 'Accept: application/vnd.github+json' \
  'https://api.github.com/repos/kaspanet/kccs/git/trees/main?recursive=1' 2>/dev/null) || {
  echo "KCC freshness: SKIP (network unreachable) — still pinned at ${REV:0:7}"; exit 0; }
LOOK='import sys,json;t=json.load(sys.stdin);p=sys.argv[1];print(next((e["sha"] for e in t["tree"] if e["path"]==p),"ABSENT"))'
NEWF='import sys,json;t=json.load(sys.stdin);k=set(sys.argv[1].split());print(" ".join(e["path"] for e in t["tree"] if e["type"]=="blob" and e["path"] not in k))'
printf '%s' "$TREE" | grep -q '"tree"' || { echo "KCC freshness: SKIP (unparseable API reply)"; exit 0; }
DRIFT=0
while read -r sha path; do
  live=$(printf '%s' "$TREE" | python3 -c "$LOOK" "$path")
  [ "$live" = "$sha" ] || { echo "KCC DRIFT  $path  pinned=${sha:0:10} live=${live:0:10}"; DRIFT=1; }
done <<< "$PINNED"
NEW=$(printf '%s' "$TREE" | python3 -c "$NEWF" "$(printf '%s\n' "$PINNED" | awk '{print $2}')")
[ -z "$NEW" ] || { echo "KCC NEW FILE(S)  $NEW"; DRIFT=1; }
[ "$DRIFT" = 0 ] && echo "KCC freshness: clean at ${REV:0:7}"
exit $DRIFT
