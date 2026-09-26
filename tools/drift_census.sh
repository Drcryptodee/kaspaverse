#!/usr/bin/env bash
# drift_census.sh — do the repo's LIVING pointers still agree with what they restate?
#
# The record is written for readers and stays discursive; what rots first is the handful
# of facts restated where a session reads them at open: ledger ids, the gate count in the
# baton, the playbook's index against its chunks, the freshness register's coverage, the active
# phase, a lesson's declared destination, the upstream record's idea of our own pin, the
# session index's row numbers. Each
# check is exact, offline and cheap (tools/drift_census.py holds them, one function each).
#
#   tools/drift_census.sh            advisory: the strict checks plus what has merely aged
#   tools/drift_census.sh --gate     the strict subset only; exit 1 on any disagreement
#   tools/drift_census.sh --selftest plant each defect in a scratch tree and demand red
#
# Runs at every session open from tools/preflight.sh, and as a gate lane in --gate mode
# (offline, so it is allowed there). The internal record lives in the ops mirror; in a
# public clone every docs-dependent check reports `skip`, never a false red.
# gate-allow:internal-path — this tool is the record's own drift probe and names its files
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/tools/drift_census.py"

selftest() {
  local work fails=0 rows=0
  work="$(mktemp -d)"
  scaffold() { # a minimal tree the census reads, copied from the real one
    local t=$1
    mkdir -p "$t/docs/research" "$t/docs/sessions" "$t/docs/phases" "$t/tools" "$t/rust" "$t/.claude/playbook" "$t/.claude/skills"
    cp "$ROOT/docs/DECISION_LOG.md" "$ROOT/docs/LESSONS.md" "$t/docs/"
    cp "$ROOT/docs/research/FRESHNESS.md" "$ROOT/docs/research/UPSTREAM_REVS.json" "$t/docs/research/"
    for f in "$ROOT"/docs/research/*.md; do : > "$t/docs/research/$(basename "$f")"; done
    cp "$ROOT/docs/research/FRESHNESS.md" "$t/docs/research/FRESHNESS.md"
    cp "$ROOT/docs/sessions/NEXT_SESSION.md" "$ROOT/docs/sessions/INDEX.md" "$t/docs/sessions/"
    cp "$ROOT"/docs/phases/*.md "$t/docs/phases/"
    cp "$ROOT"/tools/*.sh "$ROOT"/tools/*.py "$t/tools/" 2>/dev/null; cp "$ROOT/rust/Cargo.toml" "$t/rust/"
    cp "$ROOT/CLAUDE.md" "$ROOT/AGENTS.md" "$t/"; cp "$ROOT/.claude/playbook/INDEX.md" "$ROOT/.claude/playbook/PLAYBOOK.md" "$t/.claude/playbook/"
    for s in "$ROOT"/.claude/skills/*/; do mkdir -p "$t/.claude/skills/$(basename "$s")"; cp "$s/SKILL.md" "$t/.claude/skills/$(basename "$s")/"; done
    # the baton's target must exist in the scaffold (the pointer sits on the line after the heading)
    local target; target=$(python3 -c 'import re,sys; m=re.search(r"## Paste this next\s+`([^`]+)`", open(sys.argv[1]).read()); print(m.group(1) if m else "")' "$t/docs/sessions/NEXT_SESSION.md")
    [ -n "$target" ] && mkdir -p "$t/$(dirname "$target")" && : > "$t/$target"
  }
  run() { # label expected_regex expected_exit tree
    local label=$1 re=$2 want=$3 tree=$4 out rc; rows=$((rows+1))
    out=$(python3 "$PY" --gate --root "$tree" 2>&1); rc=$?
    if printf '%s\n' "$out" | grep -qE -- "$re" && [ "$rc" = "$want" ]; then printf '  ok   %s\n' "$label"
    else printf '  FAIL %s — expected /%s/ exit %s, got exit %s:\n' "$label" "$re" "$want" "$rc"; printf '%s\n' "$out" | sed 's/^/         /'; fails=$((fails+1)); fi
  }
  echo "drift census selftest:"
  scaffold "$work/clean";  run "clean scaffold is clean" 'DRIFT clean' 0 "$work/clean"
  scaffold "$work/c1";     printf '\n## D-9999 · 2026-01-01 · a\n\n## D-9999 · 2026-01-02 · b\n' >> "$work/c1/docs/DECISION_LOG.md"
  run "C1 a decision id claimed twice"                'C1 DECISION_LOG claims a D-number twice: D-9999' 1 "$work/c1"
  scaffold "$work/c1b";    printf '| L9999 | a | b |\n| L9999 | c | d |\n' >> "$work/c1b/docs/LESSONS.md"
  run "C1 a lesson id claimed twice"                  'C1 LESSONS claims an L-number twice: L9999' 1 "$work/c1b"
  scaffold "$work/c2";     : > "$work/c2/docs/research/zz_unstamped_doc.md"
  run "C2 a research doc with no freshness row"       'C2 FRESHNESS has no row for: zz_unstamped_doc.md' 1 "$work/c2"
  scaffold "$work/c3";     python3 - "$work/c3/docs/sessions/NEXT_SESSION.md" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read(); head, sep, tail = s.partition("Expected state at open")
tail = re.sub(r"(gate[^\n]*?)\d+/\d+", r"\g<1>1/1", tail, count=1)   # the block the census reads, not the narrative
open(p, "w").write(head + sep + tail)
PY
  run "C3 a stale gate count in the baton"            'C3 NEXT_SESSION.md expects the gate at 1/1' 1 "$work/c3"
  scaffold "$work/c4";     printf '\n%s always-on reasoning triggers\n7 always-on reasoning triggers\n' "$(grep -c '^### PB-' "$work/c4/.claude/playbook/PLAYBOOK.md")" >> "$work/c4/CLAUDE.md"
  run "C4 a wrong typed count behind a right one"     'C4 CLAUDE.md says 7;' 1 "$work/c4"  # gate-allow:internal-path — a planted count in the selftest names the file it is planted in
  scaffold "$work/c4b";    printf '\n7 always-on reasoning triggers\n' >> "$work/c4b/AGENTS.md"
  run "C4 a typed count in AGENTS.md disagrees"       'C4 AGENTS.md says 7;' 1 "$work/c4b"  # gate-allow:internal-path — a planted count in the selftest names the file it is planted in
  scaffold "$work/c4c";    printf '\n> these 7 lines\n' >> "$work/c4c/.claude/playbook/INDEX.md"
  run "C4 a typed count in the index header disagrees" 'C4 .claude/playbook/INDEX.md says 7;' 1 "$work/c4c"  # gate-allow:internal-path — a planted count in the selftest names the file it is planted in
  scaffold "$work/c4d";    sed -i '0,/^- PB-/{/^- PB-/d}' "$work/c4d/.claude/playbook/INDEX.md"
  run "C4 a pattern with no index line"               'C4 PB-001 has a chunk in PLAYBOOK.md and no line' 1 "$work/c4d"
  scaffold "$work/c4e";    printf -- '- PB-999 · a trigger → an action\n' >> "$work/c4e/.claude/playbook/INDEX.md"
  run "C4 an index line with no pattern"              'C4 PB-999 has a line in INDEX.md and no chunk' 1 "$work/c4e"
  scaffold "$work/c4f";    printf '\n### PB-001 · a second chunk under one id\n' >> "$work/c4f/.claude/playbook/PLAYBOOK.md"
  run "C4 one pattern id headed twice"                'C4 PLAYBOOK.md lists PB-001 twice' 1 "$work/c4f"
  scaffold "$work/c4g";    rm "$work/c4g/.claude/playbook/PLAYBOOK.md"
  run "C4 the chunks are missing, so it cannot look"  'C4 cannot look' 1 "$work/c4g"
  scaffold "$work/c5";     : > "$work/c5/docs/phases/P9_second_ACTIVE.md"
  run "C5 two active phases"                          'C5 expected exactly one \*_ACTIVE.md' 1 "$work/c5"
  scaffold "$work/c6";     printf '| L9998 | a lesson | **`update-context`** gains a step |\n' >> "$work/c6/docs/LESSONS.md"
  run "C6 a destination skill that never cites the lesson" 'C6 L9998 names `update-context` as a destination' 1 "$work/c6"
  scaffold "$work/c7";     sed -i -E '/"our_pin"/,/\}/ s/"rusty_kaspa": "[0-9a-f]{7}/"rusty_kaspa": "0000000/' "$work/c7/docs/research/UPSTREAM_REVS.json"  # our_pin only, any rev: a literal went stale at the v2.1.0 re-pin (D-324)
  run "C7 the record disagrees with the manifest pin" 'C7 UPSTREAM_REVS.json records our pin as 0000000' 1 "$work/c7"
  scaffold "$work/c8";     python3 - "$work/c8/docs/sessions/NEXT_SESSION.md" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(re.sub(r"(## Paste this next\s+`)[^`]+`", r"\g<1>docs/sessions/nope_PROMPT.md`", s, count=1))  # gate-allow:internal-path — gate-allow:dangling-path — a planted missing prompt in the census selftest, meant not to resolve
PY
  run "C8 the baton points at a missing prompt"       'C8 NEXT_SESSION.md points at docs/sessions/nope_PROMPT.md' 1 "$work/c8"  # gate-allow:internal-path — gate-allow:dangling-path — the planted missing prompt the row expects, meant not to resolve
  scaffold "$work/c9";     python3 - "$work/c9/docs/sessions/INDEX.md" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
rows = "| 9999 | 2026-01-01 | **ZZ-A** — first claim | a |\n| 9999 | 2026-01-02 | **ZZ-B** — second claim | b |\n\n"
open(p, "w").write(re.sub(r"^## §2 ", lambda m: rows + m.group(0), s, count=1, flags=re.M))
PY
  run "C9 two sittings claim the same index row"      'C9 sessions/INDEX.md claims row 9999 twice \(ZZ-A and ZZ-B\)' 1 "$work/c9"
  scaffold "$work/c9b";    python3 - "$work/c9b/docs/sessions/INDEX.md" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(re.sub(r"^## §2 ", lambda m: "| 5 | 2026-01-01 | **ZZ-C** — late and low | c |\n\n" + m.group(0), s, count=1, flags=re.M))
PY
  run "C9 an index row numbered below its predecessor" 'C9 sessions/INDEX.md rows are out of order at row 5' 1 "$work/c9b"
  rm -rf "$work"
  if [ "$fails" = 0 ]; then echo "drift census selftest: PASS ($rows rows)"; return 0; fi
  echo "drift census selftest: $fails of $rows FAILED"; return 1
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  --gate)     cd "$ROOT" && exec python3 "$PY" --gate ;;
  "")         cd "$ROOT" && exec python3 "$PY" ;;
  *)          echo "drift_census.sh: unknown argument '$1' (--gate | --selftest)" >&2; exit 2 ;;
esac
