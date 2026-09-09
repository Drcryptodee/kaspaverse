#!/usr/bin/env python3
"""upstream_revs.py — the parse/compare/render half of tools/upstream_revs.sh.

The shell half owns the transport (curl, fixtures, timeouts) and the CLI; this half
owns everything that reads a reply: which fields are recorded, how tags are ordered,
how the manifests are parsed, what "moved" means, and how the result is rendered.
It never touches the network. Invoked only by upstream_revs.sh — not a CLI of its own.

Usage (internal): upstream_revs.py MODE REPLY_DIR RECORD_PATH OUR_PIN CAPTURE_DIR KCC_LINE KCC_EXIT
  MODE ∈ compare | record | sweep | print
Exit: 0 clean / SKIP / NO RECORD · 1 if anything MOVED (or --record refused).
"""
import datetime as _dt
import json
import os
import re
import sys

MODE, REPLY_DIR, RECORD_PATH, OUR_PIN, CAPTURE_DIR, KCC_LINE, KCC_EXIT = (sys.argv + [""] * 8)[1:8]
NOW = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# One row per tracked source. `branches` are extra heads recorded beside master; `tags` and
# `releases` are the top-of-list facts; `manifest` means "parse rusty-kaspa/silverscript rev ="
# from the repo's Cargo.toml at the observed head; `tree` records the commit's tree sha (kccs,
# whose blob-level comparison stays with tools/kcc_freshness.sh — one place compares blobs).
SOURCES = [
    ("rusty-kaspa", "kaspanet/rusty-kaspa", "master", dict(tags=True, releases=True)),
    ("silverscript", "kaspanet/silverscript", "master", dict(tags=True, releases=True, manifest=True)),
    ("argent", "argent-lang/argent", "master", dict(tags=True, releases=True, manifest=True)),
    ("argent-template", "argent-lang/argent-template", "master", dict(manifest=True, branches=["episode-01"])),
    ("argent-playground", "argent-lang/argent-playground", "master", dict()),
    ("kccs", "kaspanet/kccs", "main", dict(tree=True)),
]
COMPARED = ("head.sha", "head.tree", "top_tag.name", "top_tag.sha", "top_release.tag",
            "top_release.prerelease", "manifest.rusty_kaspa", "manifest.silverscript")
REV_RE = re.compile(r'github\.com/kaspanet/(rusty-kaspa|silverscript)(?:\.git)?"\s*,\s*rev\s*=\s*"([0-9a-f]{7,40})"')
TAG_RE = re.compile(r"^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-(.+))?$")


def short(s):
    """Abbreviate a full git sha to 7; leave tag names, flags and everything else whole."""
    if isinstance(s, bool):
        return str(s).lower()
    if isinstance(s, str) and re.fullmatch(r"[0-9a-f]{40}", s):
        return s[:7]
    return "" if s is None else str(s)


def load(name):
    """A reply file → parsed JSON, or None when absent / not JSON (the caller renders SKIP)."""
    p = os.path.join(REPLY_DIR, name)
    if not os.path.isfile(p):
        return None
    try:
        with open(p, encoding="utf-8") as fh:
            return json.load(fh)
    except (ValueError, OSError):
        return None


def tag_key(name):
    m = TAG_RE.match(name or "")
    if not m:
        return None
    major, minor, patch, suffix = m.groups()
    return (int(major), int(minor or 0), int(patch or 0), 0 if suffix else 1, suffix or "")


def top_tag(tags):
    best = None
    for t in tags or []:
        k = tag_key(t.get("name"))
        if k and (best is None or k > best[0]):
            best = (k, t)
    if not best:
        return None
    k, t = best
    return {"name": t["name"], "sha": t.get("commit", {}).get("sha"), "stable": k[3] == 1,
            "tags_page_full": len(tags) >= 100}


def manifest_revs(text):
    found = {"rusty_kaspa": None, "silverscript": None}
    seen = {"rusty-kaspa": set(), "silverscript": set()}
    for repo, rev in REV_RE.findall(text or ""):
        seen[repo].add(rev)
    for repo, key in (("rusty-kaspa", "rusty_kaspa"), ("silverscript", "silverscript")):
        if len(seen[repo]) == 1:
            found[key] = next(iter(seen[repo]))
        elif len(seen[repo]) > 1:
            found[key] = "MIXED(" + ",".join(sorted(short(x) for x in seen[repo])) + ")"
    return found


def observe():
    obs = {}
    for name, repo, branch, opts in SOURCES:
        src = {"repo": repo, "observed_at_utc": NOW}
        head = load(f"{name}.head.json")
        if not isinstance(head, dict) or "sha" not in head:
            src["skip"] = "unparseable API reply" if os.path.isfile(os.path.join(REPLY_DIR, f"{name}.head.json")) else "unreachable"
            obs[name] = src
            continue
        commit = head.get("commit", {})
        src["head"] = {"branch": branch, "sha": head["sha"], "date": commit.get("committer", {}).get("date")}
        if opts.get("tree"):
            src["head"]["tree"] = commit.get("tree", {}).get("sha")
        if opts.get("tags"):
            tags = load(f"{name}.tags.json")
            src["top_tag"] = top_tag(tags) if isinstance(tags, list) else None
        if opts.get("releases"):
            rel = load(f"{name}.releases.json")
            r0 = rel[0] if isinstance(rel, list) and rel else None
            src["top_release"] = ({"tag": r0.get("tag_name"), "sha": None, "prerelease": bool(r0.get("prerelease")),
                                   "published_at": r0.get("published_at")} if r0 else None)
            if src["top_release"] and src.get("top_tag") and src["top_tag"]["name"] == src["top_release"]["tag"]:
                src["top_release"]["sha"] = src["top_tag"]["sha"]
        if opts.get("branches"):
            src["branches"] = {}
            for b in opts["branches"]:
                bh = load(f"{name}.{b}.json")
                src["branches"][b] = ({"sha": bh["sha"], "date": bh.get("commit", {}).get("committer", {}).get("date")}
                                      if isinstance(bh, dict) and "sha" in bh else None)
        if opts.get("manifest"):
            p = os.path.join(REPLY_DIR, f"{name}.manifest.toml")
            text = open(p, encoding="utf-8").read() if os.path.isfile(p) else ""
            src["manifest"] = {"path": "Cargo.toml", "at": head["sha"], **manifest_revs(text)}
        if name == "kccs":
            src["blobs"] = {"probe": "tools/kcc_freshness.sh", "last_line": KCC_LINE or "(probe not run)",
                            "drift": KCC_EXIT not in ("", "0")}
        obs[name] = src
    return obs


def get(d, path):
    for part in path.split("."):
        if not isinstance(d, dict):
            return None
        d = d.get(part)
    return d


def compare(record, obs):
    moved = {}  # source → [(field, old, new)]
    for name, src in obs.items():
        if "skip" in src:
            continue
        rec = (record or {}).get("sources", {}).get(name, {})
        rows = []
        for f in COMPARED:
            old, new = get(rec, f), get(src, f)
            if f in ("top_tag.sha",) and old is None and new is None:
                continue
            if old != new and not (old is None and new is None):
                rows.append((f, old, new))
        for b, bh in (src.get("branches") or {}).items():
            old = get(rec, f"branches.{b}.sha")
            new = (bh or {}).get("sha")
            if old != new:
                rows.append((f"branches.{b}", old, new))
        if name == "kccs" and src.get("blobs", {}).get("drift"):
            rows.append(("blobs", "clean", "DRIFT (probe)"))
        if rows:
            moved[name] = rows
    return moved


def triggers(obs, record):
    """D-183 T-A / T-D, evaluated mechanically. Returns [(name, fired, line)]."""
    out = []
    rk = obs.get("rusty-kaspa", {})
    rel = rk.get("top_release") or {}
    if rel.get("sha") and OUR_PIN:
        fired = rel["sha"] != OUR_PIN
        cond = f"{rel.get('tag')}:{short(rel.get('sha'))}"
        out.append(("T-A", fired, cond,
                    f"rusty-kaspa newest release {rel.get('tag')} @ {short(rel.get('sha'))} ≠ pin {short(OUR_PIN)} — D-183: steward + consensus packet; the bump is the founder's"
                    if fired else f"rusty-kaspa newest release {rel.get('tag')} = pin"))
    ss = obs.get("silverscript", {})
    tag, man = ss.get("top_tag") or {}, ss.get("manifest") or {}
    if tag.get("name") and man.get("rusty_kaspa") and OUR_PIN:
        fired = bool(tag.get("stable")) and man["rusty_kaspa"] != OUR_PIN
        cond = f"{tag.get('name')}:{short(man.get('rusty_kaspa'))}"
        out.append(("T-D", fired, cond,
                    f"silverscript {tag['name']} (stable) pins rusty-kaspa {short(man['rusty_kaspa'])} ≠ pin {short(OUR_PIN)} — D-183 T-D packet; the bump is the founder's"
                    if fired else f"silverscript {tag['name']} ({'stable' if tag.get('stable') else 'pre-release'}) pins rusty-kaspa {short(man['rusty_kaspa'])}"))
    ack = ((record or {}).get("triggers") or {})
    lines = []
    for name, fired, cond, text in out:
        a = ack.get(name) or {}
        if fired and a.get("acknowledged") and a.get("condition") == cond:
            lines.append((name, False, f"UPSTREAM {name} fired, acknowledged ({a['acknowledged']}) — {text.split(' — ')[0]}"))
        elif fired:
            lines.append((name, True, f"UPSTREAM {name} FIRED: {text}"))
        else:
            lines.append((name, False, f"UPSTREAM {name} not fired: {text}"))
    return lines, {n: c for n, _f, c, _t in out}


def describe(src):
    if "skip" in src:
        return f"SKIP ({src['skip']})"
    h = src["head"]
    parts = [f"{h['branch']} `{short(h['sha'])}` {str(h.get('date') or '')[:10]}"]
    if src.get("top_tag"):
        t = src["top_tag"]
        parts.append(f"top tag `{t['name']}` = `{short(t['sha'])}`" + ("" if t["stable"] else " (pre-release)"))
    elif "top_tag" in src:
        parts.append("0 tags")
    if src.get("top_release"):
        r = src["top_release"]
        parts.append(f"newest release `{r['tag']}`, `prerelease={str(r['prerelease']).lower()}`")
    if src.get("branches"):
        parts.append(" · ".join(f"`{b}` `{short((bh or {}).get('sha'))}`" for b, bh in src["branches"].items()))
    if h.get("tree"):
        parts.append(f"tree `{short(h['tree'])}`")
    if src.get("blobs"):
        parts.append(src["blobs"]["last_line"])
    return " · ".join(parts)


def main():
    obs = observe()
    if CAPTURE_DIR:
        os.makedirs(CAPTURE_DIR, exist_ok=True)
        for fn in os.listdir(REPLY_DIR):
            src, dst = os.path.join(REPLY_DIR, fn), os.path.join(CAPTURE_DIR, fn)
            data = load(fn) if fn.endswith(".json") else None
            if fn.endswith(".json") and data is not None:
                data = trim(fn, data)
                with open(dst, "w", encoding="utf-8") as fh:
                    json.dump(data, fh, indent=1, sort_keys=True)
            else:
                with open(src, "rb") as a, open(dst, "wb") as b:
                    b.write(a.read())
    record = None
    if os.path.isfile(RECORD_PATH):
        try:
            record = json.load(open(RECORD_PATH, encoding="utf-8"))
        except ValueError:
            print(f"UPSTREAM SKIP (record {RECORD_PATH} is not JSON — fix it by hand)")
            return 0
    skipped = [n for n, s in obs.items() if "skip" in s]
    ok = [n for n in obs if n not in skipped]
    trig_lines, trig_conds = triggers(obs, record)

    if MODE == "print":
        print(json.dumps({"observed_at_utc": NOW, "our_pin": OUR_PIN, "sources": obs}, indent=1, sort_keys=True))
        return 0

    fresh = record is None
    if fresh and MODE != "record":
        print(f"UPSTREAM NO RECORD ({RECORD_PATH} absent — public clone or first run; observed {len(ok)} of {len(obs)} sources, nothing to compare; --print shows them)")
        for _n, _f, line in trig_lines:
            if _f:
                print(line)
        return 0
    record = record or {"sources": {}}
    moved = {} if fresh else compare(record, obs)
    rec_at = record.get("recorded_at_utc", "none")

    if MODE == "sweep":
        print(f"**Sweep {NOW[:10]} {NOW[11:16]} UTC — generated by `tools/upstream_revs.sh --sweep-table` against the record of {rec_at[:10]} {rec_at[11:16]} UTC:**")
        print()
        print("| Source | Rev / state read | Moved since the record? | rusty-kaspa rev | silverscript rev |")
        print("|:--|:--|:--|:--|:--|")
        for name, _repo, _br, _o in SOURCES:
            src = obs[name]
            mv = moved.get(name)
            if "skip" in src:
                movedcell = f"not re-checked ({src['skip']})"
            elif mv:
                movedcell = "**YES** — " + " · ".join(f"{f} {short(o)}→{short(n)}" for f, o, n in mv)
            else:
                movedcell = "No"
            man = src.get("manifest") or {}
            rk = f"`{short(man.get('rusty_kaspa'))}` (manifest)" if man.get("rusty_kaspa") else "—"
            sil = f"`{short(man.get('silverscript'))}` (manifest)" if man.get("silverscript") else ("via `../argent`" if name == "argent-playground" else "—")
            print(f"| `{src['repo']}` | {describe(src)} | {movedcell} | {rk} | {sil} |")
        print("| kas-smiths.org | not polled — founder-curated (D-243 item 6, `kas-smiths-intake` §0a rule 5) | — | — | — |")
        print()
        print(" · ".join(l.replace("UPSTREAM ", "") for _n, _f, l in trig_lines) or "no trigger evaluated")
        return 1 if moved else 0

    # compare / record
    exit_code = 0
    if moved:
        exit_code = 1
        print(f"UPSTREAM {len(moved)} MOVED ({', '.join(moved)}) at {NOW} vs record {rec_at} → run the upstream-rediff skill")
        for name, rows in moved.items():
            print(f"UPSTREAM MOVED  {name}  " + " · ".join(f"{f} {short(o)}→{short(n)}" + (" (stable)" if f == "top_tag.name" and get(obs[name], 'top_tag.stable') else "") for f, o, n in rows))
    for name in skipped:
        print(f"UPSTREAM SKIP {name} ({obs[name]['skip']})")
    for _n, _f, line in trig_lines:
        if _f or MODE == "record":
            print(line)
    if "kccs" in ok and obs["kccs"].get("blobs"):
        print(f"UPSTREAM kccs blobs: {obs['kccs']['blobs']['last_line']}")
    if not moved:
        n = f"{len(ok)} of {len(obs)} sources; {', '.join(skipped)} SKIP" if skipped else f"{len(obs)} sources"
        print(f"UPSTREAM clean ({n} at {NOW}; record {rec_at})")

    if MODE == "record":
        if skipped:
            print(f"UPSTREAM --record REFUSED: {', '.join(skipped)} could not be observed; a record must be whole")
            return 1
        new = {"schema": 1, "recorded_at_utc": NOW, "recorded_by": "tools/upstream_revs.sh --record",
               "our_pin": {"rusty_kaspa": OUR_PIN, "read_from": "rust/Cargo.toml"},
               "not_polled": record.get("not_polled") or ["kas-smiths.org — founder-curated (D-243 item 6; kas-smiths-intake §0a rule 5)"],
               "triggers": {}, "sources": {}}
        old_trig = record.get("triggers") or {}
        for tname, cond in trig_conds.items():
            fired = any(n == tname and f for n, f, _l in trig_lines) or (old_trig.get(tname, {}).get("condition") == cond and old_trig.get(tname, {}).get("acknowledged"))
            if fired:
                prev = old_trig.get(tname) or {}
                new["triggers"][tname] = {"fired_at": prev.get("fired_at") if prev.get("condition") == cond else NOW, "condition": cond,
                                          **({"acknowledged": prev["acknowledged"]} if prev.get("condition") == cond and prev.get("acknowledged") else {})}
        for name, src in obs.items():
            entry = {k: v for k, v in src.items() if k != "skip"}
            if name in moved:
                entry["previous"] = {"recorded_at_utc": rec_at, **{f: o for f, o, _n in moved[name]}}
            new["sources"][name] = entry
        os.makedirs(os.path.dirname(RECORD_PATH) or ".", exist_ok=True)
        with open(RECORD_PATH, "w", encoding="utf-8") as fh:
            json.dump(new, fh, indent=1, sort_keys=True)
            fh.write("\n")
        print(f"UPSTREAM recorded {len(obs)} sources at {NOW} → {RECORD_PATH}")
        return 0
    return exit_code


def trim(fn, data):
    """Keep only the fields observe() reads, so a fixture stays small and honest."""
    if fn == "rate_limit.json":
        core = (data.get("resources") or {}).get("core") or {}
        return {"resources": {"core": {"remaining": core.get("remaining"), "limit": core.get("limit"), "reset": core.get("reset")}}}
    if fn.endswith(".tags.json") and isinstance(data, list):
        return [{"name": t.get("name"), "commit": {"sha": (t.get("commit") or {}).get("sha")}} for t in data]
    if fn.endswith(".releases.json") and isinstance(data, list):
        return [{"tag_name": r.get("tag_name"), "prerelease": r.get("prerelease"), "published_at": r.get("published_at")} for r in data]
    if isinstance(data, dict) and "sha" in data:
        c = data.get("commit") or {}
        return {"sha": data["sha"], "commit": {"committer": {"date": (c.get("committer") or {}).get("date")},
                                                "tree": {"sha": (c.get("tree") or {}).get("sha")}}}
    return data


if __name__ == "__main__":
    sys.exit(main())
