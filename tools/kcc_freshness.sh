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
REV=54f4f9c2730f77ec5b1ee8bc746d7f94d83b8ee6   # kaspanet/kccs main @ 2026-09-02T11:06:54Z; re-pinned 2026-09-02 (trajectory audit; was ea5176a, read 2026-08-25)
PINNED='b17b9b81d55ea51dce633c9b992287cabcd85edf LICENSE.md
94d9965319f4bb2b26bdc7f5b8a91357f109e274 README.md
2866e9f7ee513a736d9ee1920547899078608832 kcc-0000.md
a1d3f1725d869f63b3b4304662dfe0b2c42e7dc0 kcc-0001.md
e6b1b5362b7ee54791799c9db410ce7370799102 kcc-0002.md
e6e96f39a15b0e8bf6a319152a8fa0e54b3c93ab kcc-0002/reference-code.md
58c359a393868789e82431d911065cd7c79db9d6 kcc-0020.md
8810f111ebeba86b276e0cced167df5712e6621d kcc-0020/borrowed-receive-authorization.md
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
