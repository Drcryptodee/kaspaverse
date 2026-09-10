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
WATCH_KINDS = {"pull": "pulls", "issue": "issues"}

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
        tags = load(f"{name}.tags.json") if (opts.get("tags") or opts.get("releases")) else None
        if opts.get("tags"):
            src["top_tag"] = top_tag(tags) if isinstance(tags, list) else None
        if opts.get("releases"):
            rel = load(f"{name}.releases.json")
            r0 = rel[0] if isinstance(rel, list) and rel else None
            if r0:
                # The release's sha is looked up by tag NAME across the tags page, not only when it
                # happens to be the natural-sort top tag: a stable v2.0.2 beneath a v2.1.0-rc1 tag
                # must still resolve (consensus-auditor, 2026-09-10). `stable` = no suffix.
                tag_name = r0.get("tag_name")
                by_name = {t.get("name"): (t.get("commit") or {}).get("sha") for t in (tags if isinstance(tags, list) else [])}
                k = tag_key(tag_name)
                src["top_release"] = {"tag": tag_name, "sha": by_name.get(tag_name), "prerelease": bool(r0.get("prerelease")),
                                      "stable": bool(k and k[3] == 1), "published_at": r0.get("published_at")}
            else:
                src["top_release"] = None
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
            # T-D is about what the RELEASE pins (D-183: "the toolchain releases pinned to a rev"), so
            # when master has moved past the top tag the tag's own manifest is read, not master's
            # (consensus-auditor, 2026-09-10). The shell half fetches it as <name>.tag.manifest.toml.
            tt = src.get("top_tag")
            if tt and tt.get("sha"):
                if tt["sha"] == head["sha"]:
                    tt["manifest"] = {"at": head["sha"], "same_as_head": True, **manifest_revs(text)}
                else:
                    tp = os.path.join(REPLY_DIR, f"{name}.tag.manifest.toml")
                    ttext = open(tp, encoding="utf-8").read() if os.path.isfile(tp) else ""
                    tt["manifest"] = ({"at": tt["sha"], "same_as_head": False, **manifest_revs(ttext)} if ttext else None)
        if name == "kccs":
            src["blobs"] = {"probe": "tools/kcc_freshness.sh", "last_line": KCC_LINE or "(probe not run)",
                            "drift": KCC_EXIT not in ("", "0")}
        obs[name] = src
    return obs


def slug(repo):
    return repo.replace("/", "__")


def watch_items(record):
    """[(repo, number, kind, entry)] from the record's `watch` map — the upstream PRs and
    issues our own triggers name. Extended by `--watch-add`, never by editing JSON by hand."""
    out = []
    for repo, items in ((record or {}).get("watch") or {}).items():
        for num, entry in (items or {}).items():
            out.append((repo, str(num), (entry or {}).get("kind", "pull"), entry or {}))
    return sorted(out)


def observe_watch(record):
    obs = {}
    for repo, num, kind, entry in watch_items(record):
        reply = load(f"watch.{slug(repo)}.{num}.json")
        cur = {"kind": kind, "title": entry.get("title"), "url": entry.get("url")}
        if isinstance(reply, dict) and "state" in reply:
            cur["state"] = "merged" if reply.get("merged_at") else reply.get("state")
            cur["title"] = reply.get("title") or cur["title"]
            cur["url"] = reply.get("html_url") or cur["url"]
            cur["observed_at_utc"] = NOW
        else:
            cur["state"] = None  # unobserved this run (unreachable / unparseable)
        obs.setdefault(repo, {})[num] = cur
    return obs


def compare_watch(record, wobs):
    moved = []
    for repo, num, kind, entry in watch_items(record):
        cur = wobs.get(repo, {}).get(num) or {}
        if cur.get("state") is None:
            continue
        old = entry.get("state")
        if old is not None and old != cur["state"]:
            moved.append((repo, num, old, cur["state"], cur.get("title") or ""))
    return moved


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
    # T-A (D-183): a TAGGED STABLE release we are not on — pre-releases (rusty-kaspa publishes rcs
    # as GitHub releases) never fire it; an unresolvable release tag is said, not skipped.
    rk = obs.get("rusty-kaspa", {})
    rel = rk.get("top_release") or {}
    if rel.get("tag") and OUR_PIN:
        if rel.get("prerelease") or not rel.get("stable"):
            out.append(("T-A", False, f"{rel['tag']}:pre",
                        f"rusty-kaspa newest release {rel['tag']} is a pre-release — D-183 T-A waits for a stable tag"))
        elif not rel.get("sha"):
            out.append(("T-A", False, f"{rel['tag']}:unresolved",
                        f"rusty-kaspa newest release {rel['tag']} has no matching tag in the first 100 tags — T-A unevaluated"))
        else:
            fired = rel["sha"] != OUR_PIN
            cond = f"{rel['tag']}:{short(rel['sha'])}"
            out.append(("T-A", fired, cond,
                        f"rusty-kaspa newest release {rel['tag']} @ {short(rel['sha'])} ≠ pin {short(OUR_PIN)} — D-183: steward + consensus packet; the bump is the founder's"
                        if fired else f"rusty-kaspa newest release {rel['tag']} = pin"))
    # T-D (D-183): the canonical toolchain RELEASES pinned to a rev — read at the tag, never at master.
    ss = obs.get("silverscript", {})
    tag = ss.get("top_tag") or {}
    tm = tag.get("manifest")
    if tag.get("name") and OUR_PIN:
        if tm is None and tag.get("sha") and (ss.get("head") or {}).get("sha") != tag.get("sha"):
            out.append(("T-D", False, f"{tag['name']}:unresolved",
                        f"silverscript {tag['name']}'s manifest at the tag was not fetched — T-D unevaluated"))
        else:
            man = tm or ss.get("manifest") or {}
            if man.get("rusty_kaspa"):
                fired = bool(tag.get("stable")) and man["rusty_kaspa"] != OUR_PIN
                cond = f"{tag['name']}:{short(man['rusty_kaspa'])}"
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


def special_modes():
    """`--plan`, `--watch-plan RECORD`, `--watch-add RECORD REPO N KIND` — the shell half's
    single source for what to fetch, so the source list lives in exactly one file."""
    if MODE == "--plan":
        for name, repo, branch, opts in SOURCES:
            feats = [k for k in ("tags", "releases", "manifest", "tree") if opts.get(k)]
            feats += [f"branch={b}" for b in opts.get("branches", [])]
            print(name, repo, branch, ",".join(feats) or "-")
        return 0
    if MODE == "--watch-plan":
        path = sys.argv[2] if len(sys.argv) > 2 else ""
        try:
            rec = json.load(open(path, encoding="utf-8"))
        except (OSError, ValueError):
            return 0
        for repo, num, kind, _e in watch_items(rec):
            print(repo, WATCH_KINDS.get(kind, "pulls"), num)
        return 0
    if MODE == "--watch-add":
        path, repo, num, kind = (sys.argv + [""] * 6)[2:6]
        if kind not in WATCH_KINDS or not num.isdigit() or "/" not in repo:
            print("usage: --watch-add RECORD owner/repo NUMBER pull|issue", file=sys.stderr)
            return 2
        rec = json.load(open(path, encoding="utf-8"))
        rec.setdefault("watch", {}).setdefault(repo, {})[num] = {"kind": kind, "state": None, "added_at_utc": NOW}
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(rec, fh, indent=1, sort_keys=True)
            fh.write("\n")
        print(f"UPSTREAM watch added {repo}#{num} ({kind}); state is read at the next run")
        return 0
    return None


def main():
    rc = special_modes()
    if rc is not None:
        return rc
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
    wobs = observe_watch(record)
    wmoved = [] if fresh else compare_watch(record, wobs)
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
        wl = [f"{repo}#{num} {cur.get('state') or 'unobserved'}" + (" **(moved)**" if any(m[0] == repo and m[1] == num for m in wmoved) else "")
              for repo, items in sorted(wobs.items()) for num, cur in sorted(items.items(), key=lambda kv: int(kv[0]))]
        if wl:
            print("Watched: " + " · ".join(wl))
        return 1 if (moved or wmoved) else 0

    # compare / record
    exit_code = 0
    if moved or wmoved:
        exit_code = 1
        what = list(moved) + [f"{r}#{n}" for r, n, _o, _s, _t in wmoved]
        print(f"UPSTREAM {len(what)} MOVED ({', '.join(what)}) at {NOW} vs record {rec_at} → run the upstream-rediff skill")
        for name, rows in moved.items():
            print(f"UPSTREAM MOVED  {name}  " + " · ".join(f"{f} {short(o)}→{short(n)}" + (" (stable)" if f == "top_tag.name" and get(obs[name], 'top_tag.stable') else "") for f, o, n in rows))
        for repo, num, old, new, title in wmoved:
            print(f"UPSTREAM WATCH  {repo}#{num} {old}→{new}  {title}".rstrip())
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
        new["watch"] = {}
        for repo, num, kind, entry in watch_items(record):
            cur = wobs.get(repo, {}).get(num) or {}
            keep = dict(entry)
            if cur.get("state") is not None:
                keep.update({"kind": kind, "state": cur["state"], "title": cur.get("title"), "url": cur.get("url"), "observed_at_utc": NOW})
                if entry.get("state") not in (None, cur["state"]):
                    keep["previous"] = {"state": entry.get("state"), "recorded_at_utc": rec_at}
            new["watch"].setdefault(repo, {})[num] = keep
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
    if fn.startswith("watch.") and isinstance(data, dict):
        return {k: data.get(k) for k in ("number", "state", "merged_at", "title", "html_url")}
    if isinstance(data, dict) and "sha" in data:
        c = data.get("commit") or {}
        return {"sha": data["sha"], "commit": {"committer": {"date": (c.get("committer") or {}).get("date")},
                                                "tree": {"sha": (c.get("tree") or {}).get("sha")}}}
    return data


if __name__ == "__main__":
    sys.exit(main())
