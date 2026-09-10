#!/usr/bin/env python3
"""drift_census.py — do the repo's LIVING pointers still agree with the things they restate?

The record is discursive on purpose; what rots first is the small set of facts that are
restated where a session reads them at open: counts, ids, pointers, coverage claims. Each
check below is exact (a string against a derivation), offline, and cheap. Two modes:

  --gate      the strict subset: every check must hold; exit 1 with the failing rows
  (default)   advisory: the strict subset plus what has merely AGED, for preflight

Invoked by tools/drift_census.sh. Never touches the network. `--root DIR` points it at a
scratch copy of the tree (the selftest plants defects there, never in the repo).
"""
import datetime as _dt
import json
import os
import re
import sys

ROOT = os.getcwd()
GATE = False
for i, a in enumerate(sys.argv[1:]):
    if a == "--gate":
        GATE = True
    elif a == "--root" and i + 2 < len(sys.argv) + 1:
        ROOT = sys.argv[i + 2]
TODAY = _dt.date.today()

# Decision ids that were claimed twice BEFORE this census existed (2026-09-10). They are
# historical, cited as written, and left alone; the census forbids the NINTH.
HISTORICAL_DUPLICATE_D = {282, 283}
# Lanes the gate declares only in an else-branch (a tree without the workspace / the app);
# they never report in a full tree, so a full-tree "N/N" excludes them.
FALLBACK_LANES = {"rust workspace", "flutter app"}
STALE_DAYS = 21
RECORD_STALE_DAYS = 7
LESSON_DESTINATION_FROM = 206  # rows from this id on carry a destination that must cite the id

fails, notes = [], []


def p(*parts):
    return os.path.join(ROOT, *parts)


def read(*parts):
    try:
        with open(p(*parts), encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return None


def fail(msg):
    fails.append(msg)


def note(msg):
    notes.append(msg)


# ── C1 ledger ids: a number is claimed once ──────────────────────────────────────────────
def c1_ledger_ids():
    log = read("docs", "DECISION_LOG.md")
    if log is None:
        return note("C1 skipped: docs/DECISION_LOG.md absent (public clone)")  # gate-allow:internal-path — the census reads the record; naming its files is its job
    # A claim is a header `## D-NNN · date` (or the older `## D-NNN — date`); an addendum
    # header (`### D-NNN addendum · …`) extends an entry and claims nothing.
    ids = [int(m) for m in re.findall(r"^#{2,3} D-(\d+) [·—-] ", log, flags=re.M)]
    seen, dupes = set(), set()
    for n in ids:
        (dupes if n in seen else seen).add(n)
    new_dupes = sorted(dupes - HISTORICAL_DUPLICATE_D)
    if new_dupes:
        fail(f"C1 DECISION_LOG claims a D-number twice: {', '.join('D-%d' % n for n in new_dupes)} (two sittings wrote the same id — renumber the later one before it leaves the machine)")
    les = read("docs", "LESSONS.md")
    if les is not None:
        lids = [int(m) for m in re.findall(r"^\| L(\d+) ", les, flags=re.M)]
        ld = sorted({n for n in lids if lids.count(n) > 1})
        if ld:
            fail(f"C1 LESSONS claims an L-number twice: {', '.join('L%d' % n for n in ld)}")


# ── C2 FRESHNESS: one row per research doc ───────────────────────────────────────────────
def c2_freshness_coverage():
    fr = read("docs", "research", "FRESHNESS.md")
    d = p("docs", "research")
    if fr is None or not os.path.isdir(d):
        return note("C2 skipped: research corpus absent")
    missing = [f for f in sorted(os.listdir(d)) if f.endswith(".md") and f != "FRESHNESS.md" and f"`{f}`" not in fr]
    if missing:
        fail(f"C2 FRESHNESS has no row for: {', '.join(missing)} (its own rule is one row per file under docs/research/)")  # gate-allow:internal-path — the census reads the record; naming its files is its job


# ── C3 the gate count the next session is told to expect ─────────────────────────────────
def lane_count():
    gate = read("tools", "gate.sh")
    if gate is None:
        return None
    names = set(re.findall(r'expect_lane "([^"]+)"', gate))
    return len(names - FALLBACK_LANES)


def c3_next_session_gate_count():
    ns = read("docs", "sessions", "NEXT_SESSION.md")
    n = lane_count()
    if ns is None or n is None:
        return note("C3 skipped: NEXT_SESSION.md or tools/gate.sh absent")
    blk = ns.split("Expected state at open", 1)
    scope = blk[1] if len(blk) == 2 else ns
    m = re.search(r"gate[^\n]*?(\d+)/(\d+)", scope)
    if not m:
        return note("C3: NEXT_SESSION.md states no gate N/N — nothing to hold it to")
    a, b = int(m.group(1)), int(m.group(2))
    if b != n or a != n:
        fail(f"C3 NEXT_SESSION.md expects the gate at {a}/{b}; tools/gate.sh declares {n} lanes in a full tree (a stale count misdirects the next open)")


# ── C4 the router's playbook count ───────────────────────────────────────────────────────
def c4_playbook_count():
    cl, idx = read("CLAUDE.md"), read(".claude", "playbook", "INDEX.md")  # gate-allow:internal-path — the census reads the record; naming its files is its job
    if cl is None or idx is None:
        return note("C4 skipped: CLAUDE.md or the playbook index absent")  # gate-allow:internal-path — the census reads the record; naming its files is its job
    m = re.search(r"(\d+) always-on reasoning triggers", cl)
    n = len(re.findall(r"^- PB-", idx, flags=re.M))
    if m and int(m.group(1)) != n:
        fail(f"C4 CLAUDE.md says {m.group(1)} always-on triggers; .claude/playbook/INDEX.md lists {n}")  # gate-allow:internal-path — the census reads the record; naming its files is its job


# ── C5 one active phase, and the index names it ──────────────────────────────────────────
def c5_active_phase():
    d = p("docs", "phases")
    if not os.path.isdir(d):
        return note("C5 skipped: docs/phases absent")  # gate-allow:internal-path — the census reads the record; naming its files is its job
    act = [f for f in os.listdir(d) if f.endswith("_ACTIVE.md")]
    if len(act) != 1:
        return fail(f"C5 expected exactly one *_ACTIVE.md phase file, found {len(act)}: {', '.join(sorted(act)) or 'none'}")
    idx = read("docs", "phases", "PHASE_INDEX.md") or ""
    if act[0] not in idx:
        fail(f"C5 PHASE_INDEX.md does not name the active phase file {act[0]}")


# ── C6 a lesson's destination was actually built: the destination cites the lesson ───────
def c6_lesson_destinations():
    les = read("docs", "LESSONS.md")
    sk = p(".claude", "skills")
    if les is None or not os.path.isdir(sk):
        return note("C6 skipped: LESSONS.md or .claude/skills absent")  # gate-allow:internal-path — the census reads the record; naming its files is its job
    skills = {s for s in os.listdir(sk) if os.path.isdir(os.path.join(sk, s))}
    for line in les.splitlines():
        m = re.match(r"^\| L(\d+) \|(.*)\|(.*)\|\s*$", line)
        if not m or int(m.group(1)) < LESSON_DESTINATION_FROM:
            continue
        lid, dest = int(m.group(1)), m.group(3)
        # A destination is a skill the lesson lands in. A `distill` CANDIDATE is a proposal
        # to the playbook's only write path, not a destination: skip a name whose own
        # clause (split on `;`) says "candidate".
        for clause in dest.split(";"):
            if re.search(r"\bcandidate\b", clause):
                continue
            for name in set(re.findall(r"`([a-z][a-z0-9-]+)`", clause)):
                if name not in skills:
                    continue
                body = read(".claude", "skills", name, "SKILL.md") or ""
                if not re.search(rf"\bL{lid}\b", body):
                    fail(f"C6 L{lid} names `{name}` as a destination, but .claude/skills/{name}/SKILL.md never cites L{lid} (the destination is declared, not built)")  # gate-allow:internal-path — the census reads the record; naming its files is its job
        for tool in set(re.findall(r"`(tools/[A-Za-z0-9_./-]+\.(?:sh|py))`", dest)):
            if not os.path.exists(p(tool)):
                fail(f"C6 L{lid} names `{tool}` as a destination, and it does not exist")

# ── C7 the upstream record agrees with the manifest about our own pin ────────────────────
def c7_record_pin():
    rec, cargo = read("docs", "research", "UPSTREAM_REVS.json"), read("rust", "Cargo.toml")
    if rec is None or cargo is None:
        return note("C7 skipped: UPSTREAM_REVS.json or rust/Cargo.toml absent")
    try:
        d = json.loads(rec)
    except ValueError:
        return fail("C7 docs/research/UPSTREAM_REVS.json is not valid JSON")  # gate-allow:internal-path — the census reads the record; naming its files is its job
    m = re.search(r'rusty-kaspa\.git", rev = "([0-9a-f]{40})"', cargo)
    pin = m.group(1) if m else None
    rp = (d.get("our_pin") or {}).get("rusty_kaspa")
    if pin and rp and pin != rp:
        fail(f"C7 UPSTREAM_REVS.json records our pin as {rp[:7]} but rust/Cargo.toml pins {pin[:7]} — run tools/upstream_revs.sh --record after a pin move")
    return d


# ── C8 the baton points at a prompt that exists and names its model ──────────────────────
def c8_baton():
    ns = read("docs", "sessions", "NEXT_SESSION.md")
    if ns is None:
        return note("C8 skipped: NEXT_SESSION.md absent")
    m = re.search(r"## Paste this next\s+`([^`]+)`", ns)
    if not m:
        return fail("C8 NEXT_SESSION.md has no `Paste this next` pointer")
    if not os.path.exists(p(m.group(1))):
        fail(f"C8 NEXT_SESSION.md points at {m.group(1)}, which does not exist")
    if "Suggested model & effort" not in ns:
        fail("C8 NEXT_SESSION.md carries no `Suggested model & effort` line (update-context §10a)")


# ── Advisory: what has merely aged ───────────────────────────────────────────────────────
def a1_freshness_age():
    fr = read("docs", "research", "FRESHNESS.md")
    if fr is None:
        return
    newest = {}
    internal = set()
    for line in fr.splitlines():
        m = re.match(r"^\| `([^`]+\.md)` \|(.*)\|\s*$", line)
        if not m:
            continue
        doc, rest = m.group(1), m.group(2)
        if "INTERNAL" in rest or "MACHINE RECORD" in rest:
            internal.add(doc)
        dates = [_dt.date.fromisoformat(x) for x in re.findall(r"\b(20\d\d-\d\d-\d\d)\b", rest)]
        if dates:
            newest[doc] = max([newest.get(doc, _dt.date.min)] + dates)
    stale = sorted((doc, (TODAY - d).days) for doc, d in newest.items() if doc not in internal and (TODAY - d).days > STALE_DAYS)
    if stale:
        note("A1 FRESHNESS rows for external-describing docs older than %d days: %s" % (STALE_DAYS, ", ".join(f"{d} ({n}d)" for d, n in stale)))


def a2_pending_prompts():
    idx = read("docs", "sessions", "INDEX.md")
    if idx is None:
        return
    old = []
    for m in re.finditer(r"`(20\d\d-\d\d-\d\d)[a-z]_([A-Za-z0-9._-]+_PROMPT\.md)`[^\n]*\*\((?:PENDING|pending)", idx):
        d = _dt.date.fromisoformat(m.group(1))
        if d < TODAY:
            old.append(f"{m.group(2)} (stamped {m.group(1)}, {(TODAY - d).days}d ago)")
    if old:
        note("A2 prompts still marked pending in sessions/INDEX.md with a stamp in the past (rename at their run, or retire the marker): " + "; ".join(sorted(set(old))))


def a3_record_age(rec):
    if not isinstance(rec, dict):
        return
    try:
        at = _dt.datetime.strptime(rec.get("recorded_at_utc", ""), "%Y-%m-%dT%H:%M:%SZ").date()
    except ValueError:
        return
    age = (TODAY - at).days
    if age > RECORD_STALE_DAYS:
        note(f"A3 UPSTREAM_REVS.json was last recorded {age} days ago ({at}); a MOVED line has been ignored or the recorder has not run")


def a5_recent_supersessions():
    log = read("docs", "DECISION_LOG.md")
    if log is None:
        return
    entries = re.split(r"^(?=#{2,3} D-\d+ · )", log, flags=re.M)
    hits = []
    for e in entries[-12:]:
        m = re.match(r"#{2,3} (D-\d+) · (20\d\d-\d\d-\d\d)", e)
        if not m:
            continue
        d = _dt.date.fromisoformat(m.group(2))
        if (TODAY - d).days > 14:
            continue
        if re.search(r"\b(supersed|revers|amend|retire|struck|replaces)\w*", e, flags=re.I):
            hits.append(m.group(1))
    if hits:
        note("A5 recent decisions that supersede or amend something: " + ", ".join(hits) + " — each should carry a `Propagated to:` line and a `tools/who_cites.sh` pass over what it replaced")


def main():
    c1_ledger_ids(); c2_freshness_coverage(); c3_next_session_gate_count(); c4_playbook_count()
    c5_active_phase(); c6_lesson_destinations(); rec = c7_record_pin(); c8_baton()
    if not GATE:
        a1_freshness_age(); a2_pending_prompts(); a3_record_age(rec); a5_recent_supersessions()
    if fails:
        print(f"DRIFT {len(fails)} living pointer(s) disagree with what they restate:")
        for f in fails:
            print(f"  FAIL {f}")
    else:
        print(f"DRIFT clean: the living pointers agree ({8 - sum(1 for n in notes if n.startswith('C') and 'skipped' in n)} checks)")
    for n in notes:
        print(f"  {'skip' if 'skipped' in n else 'note'} {n}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
