#!/usr/bin/env bash
# next_id.sh — the next free decision, lesson or session-index number, read from the record, not remembered.
#
#   tools/next_id.sh D      → D-317   (the live log and every archive volume it names)
#   tools/next_id.sh L      → L213
#   tools/next_id.sh S      → row 102     (the chronology table of the session index)
#
# Two sessions can share one working tree, so a number claimed at write time can be claimed
# again by a sibling before either wraps; the drift census (gate lane) catches the collision
# and the later writer renumbers. Re-run this at the wrap, not only when the entry is drafted.
# gate-allow:internal-path — reads the ledgers, which live in the record
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  D) f="$ROOT/docs/DECISION_LOG.md"; re='^(#{2,3} |- \*\*)D-([0-9]+) [·—-] '; pfx="D-" ;;   # an `addendum` header claims nothing
  L) f="$ROOT/docs/LESSONS.md";      re='^\| L([0-9]+) ';      pfx="L"  ;;
  S) f="$ROOT/docs/sessions/INDEX.md"; re='^\| [0-9]+ \| ';   pfx="row " ;;   # the chronology table; two wraps in one tree both write N+1 (C9 catches it)
  *) echo "usage: tools/next_id.sh D|L|S" >&2; exit 2 ;;
esac
[ -f "$f" ] || { echo "next_id: $f absent (public clone has no record)" >&2; exit 1; }
# The decision log's closed eras live in archive volumes its header names. An id is
# claimed once across all of them, so every named volume is read, and a named one missing
# is a refusal: the max of the live tail alone could hand out a number a volume holds.
files=("$f")
if [ "$1" = D ]; then
  for v in $(grep -oE '`docs/archive/DECISION_LOG_[A-Za-z0-9_-]+\.md`' "$f" | tr -d '`' | sort -u); do  # gate-allow:internal-path — reads the decision volumes the log's header names
    [ -f "$ROOT/$v" ] || { echo "next_id: $v is named in the log's header and absent" >&2; exit 1; }
    files+=("$ROOT/$v")
  done
fi
ids=$(cat "${files[@]}" | grep -oE "$re" | grep -oE 'D?-?[0-9]+ ' | grep -oE '[0-9]+')
[ "$1" = D ] || ids=$(grep -oE "$re" "$f" | grep -oE '[0-9]+')
max=$(printf '%s\n' "$ids" | sort -n | tail -1)
dups=$(printf '%s\n' "$ids" | sort | uniq -d | tr '\n' ' ')
echo "${pfx}$((max + 1))"
[ -z "$dups" ] || echo "note: already claimed twice in the record: $dups(historical ids are allowlisted by the census; a new one is a red)" >&2
