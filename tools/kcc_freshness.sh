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
REV=3fbec524abfbc20e87652eb938db218f8c17db17   # kaspanet/kccs main @ 2026-10-07T20:38:08Z; re-pinned 2026-10-11 (kcc-rediff; was c0bb8f3, re-pinned 2026-09-24; 54f4f9c, 2026-09-02; before that ea5176a)
PINNED='b17b9b81d55ea51dce633c9b992287cabcd85edf LICENSE.md
be6e0c7dc04fd593db68963e7c870e4b39ba928f README.md
aeb1e37dce1efb2dd2588abe3e9551e8f0ee3e04 kcc-0000.md
9399895904c4f652ae544b855d4b3b660b6703e4 kcc-0001.md
c55d6a8dbce3c0191af97f1d43ae44a34c5a9df1 kcc-0001/vectors/conformance.json
b9e6e2706834b844fddcf91f3a450bc3055501ad kcc-0002.md
865bff52ecc43b420e0faf46c7725567d9767d0c kcc-0002/reference-code.md
6db2925ae5d54f1ab29dcc0f0c403e078d6bcafb kcc-0002/vectors/authority-schemes.json
9d6e5c1a7e0f4d17c226b71834d8f326a2b37930 kcc-0020.md
81430832a5075b259b463f22844c2b4bfe46300c kcc-0020/borrowed-receive-authorization.md
5432a8a060b70fec6e19a9b28f56dd93992ab60f kcc-0020/vectors/conformance.json
092c27277d16c2c10566701b80a5d3be95898e8a kcc-template.md'
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
