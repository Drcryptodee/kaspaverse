#!/usr/bin/env bash
# who_cites.sh — every place a decision, lesson, law or phrase is restated, so a change to
# it can be propagated instead of discovered later.
#
#   tools/who_cites.sh D-125            every citation of D-125, file:line, both repos
#   tools/who_cites.sh "Silverscript-direct" "primary path"    several tokens, fixed strings
#   tools/who_cites.sh --count D-183    one line per file with a hit count
#
# Searches the public tree and the ops mirror (docs/, .claude/, CLAUDE.md, AGENTS.md — absent gate-allow:internal-path — this tool searches the record
# in a public clone, in which case only the public tree is searched). Fixed-string matching;
# session records and ledgers are included on purpose: a reader who follows an old citation
# lands on the old claim, so the wrap dispositions each hit (kept as dated history, or
# corrected in place) rather than assuming the ledger "knows".
# gate-allow:internal-path — this tool searches the record; that is its job
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
COUNT=0
[ "${1:-}" = "--count" ] && { COUNT=1; shift; }
[ $# -ge 1 ] || { echo "usage: tools/who_cites.sh [--count] <token> [token…]" >&2; exit 2; }
args=(); for t in "$@"; do args+=(-e "$t"); done
{
  git grep -nIF --untracked "${args[@]}" -- . ':!tools/who_cites.sh' 2>/dev/null
  if git ops rev-parse --git-dir >/dev/null 2>&1; then
    git ops grep -nIF "${args[@]}" -- CLAUDE.md AGENTS.md .claude docs 2>/dev/null  # gate-allow:internal-path — the ops-mirror half of the search
  fi
} | sort -u > /tmp/who_cites.$$ || true
if [ "$COUNT" = 1 ]; then cut -d: -f1 /tmp/who_cites.$$ | sort | uniq -c | sort -rn
else cat /tmp/who_cites.$$; fi
n=$(wc -l < /tmp/who_cites.$$); rm -f /tmp/who_cites.$$
echo "── $n citation(s) of: $*"
