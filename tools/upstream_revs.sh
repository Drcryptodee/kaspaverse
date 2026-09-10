#!/usr/bin/env bash
# upstream_revs.sh — have the upstream repositories we build on moved since we recorded them?
#
# The five sources the covenant path depends on (D-243 item 6): kaspanet/rusty-kaspa (the
# consensus pin, INV-9), kaspanet/silverscript (the contract compiler), argent-lang/argent
# (+ -template, -playground; the actor language and runtime), kaspanet/kccs (the conventions).
# The forum is NOT polled — kas-smiths.org stays founder-curated (kas-smiths-intake §0a rule 5).
#
# MANUAL-class instrument in the kcc_freshness.sh family: preflight runs it READ-ONLY at every
# session open (default-on; KASPAVERSE_UPSTREAM=0 opts out). Deliberately NOT a tools/gate.sh
# lane — it needs the network, and a gate lane that reds on a plane is a lane people learn to
# mute. Offline / rate-limited / unparseable => SKIP, exit 0. A moved rev exits 1 and prints
# what moved; the ruling is a human's (the `upstream-rediff` skill), and only that skill runs
# `--record` after the re-diff. A recorder that auto-recorded would print a move once and
# read clean forever after, whether or not anyone looked — the failure this tool exists to end
# (L151, the 2026-09-06 addendum, and Silverscript v1.0.0 shipping unnoticed on 2026-09-09).
#
# The record lives in the internal research corpus (gate-allow:internal-path — this tool is
# the internal record's own upstream probe); in a public clone it prints NO RECORD and
# `--print` still shows the live observation. Parsing/comparison lives in upstream_revs.py.
#
#   tools/upstream_revs.sh                   compare live vs the record (read-only); 0 clean/SKIP, 1 MOVED
#   tools/upstream_revs.sh --record          compare, then write the record (the skill's closing act)
#   tools/upstream_revs.sh --sweep-table     the kas-smiths-intake §0a markdown table + trigger footer
#   tools/upstream_revs.sh --print           the live observation as JSON
#   tools/upstream_revs.sh --manifest-revs F rusty-kaspa / silverscript `rev =` pins from a Cargo.toml
#   tools/upstream_revs.sh --selftest        the mutation table, offline, from tools/fixtures/upstream_revs/
#   tools/upstream_revs.sh --from-fixture D  read API replies from D instead of the network
#   tools/upstream_revs.sh --capture-fixture D  observe live and write trimmed replies to D
#   env KASPAVERSE_UPSTREAM_RECORD=<path>    record path override (selftest uses temp copies)
#   env KASPAVERSE_UPSTREAM_PIN=<sha>        our-pin override for the T-A/T-D evaluators (selftest)
#   env GH_TOKEN / GITHUB_TOKEN              optional; raises the API ceiling, changes nothing else
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
PY="$ROOT/tools/upstream_revs.py"
API="https://api.github.com"
RECORD="${KASPAVERSE_UPSTREAM_RECORD:-$ROOT/docs/research/UPSTREAM_REVS.json}"  # gate-allow:internal-path — the record is a research-corpus file
FIXTURE_DEFAULT="$ROOT/tools/fixtures/upstream_revs"
MODE=compare; FIXTURE=""; CAPTURE=""

usage() { sed -n '20,31p' "$SELF"; }
manifest_revs() {
  PYTHONDONTWRITEBYTECODE=1 python3 - "$1" "$ROOT/tools" <<'PY'
import sys; sys.path.insert(0, sys.argv[2]); import upstream_revs as u
r = u.manifest_revs(open(sys.argv[1], encoding="utf-8").read())
print(f"rusty_kaspa={r['rusty_kaspa'] or 'none'} silverscript={r['silverscript'] or 'none'}")
PY
}

# Our own consensus pin, read where it is asserted (rust/Cargo.toml), never from a document.
PIN="${KASPAVERSE_UPSTREAM_PIN:-$(grep -m1 -oE 'rusty-kaspa\.git", rev = "[0-9a-f]{40}' "$ROOT/rust/Cargo.toml" 2>/dev/null | grep -oE '[0-9a-f]{40}' || true)}"

# ── the mutation table (L124 / PB-031): every way the comparison can be defeated, each shown red ──
selftest() {
  local fx="${FIXTURE:-$FIXTURE_DEFAULT}" fails=0 work rows=0
  [ -f "$fx/record.json" ] || { echo "upstream revs selftest: no fixture at $fx (run --capture-fixture first)"; return 1; }
  work="$(mktemp -d)"; cp -R "$fx" "$work/fx"
  plant() { # record-in record-out dotted.path value
    python3 - "$@" <<'PY'
import json, sys
src, dst, path, val = sys.argv[1:5]
d = json.load(open(src)); cur = d
parts = path.split(".")
for p in parts[:-1]:
    cur = cur.setdefault(p, {})
cur[parts[-1]] = (val == "true") if val in ("true", "false") else val
json.dump(d, open(dst, "w"), indent=1, sort_keys=True)
PY
  }
  run() { # label expected_regex expected_exit record fixture [args...]
    local label=$1 re=$2 want=$3 rec=$4 fxd=$5; shift 5
    local out rc; rows=$((rows+1))
    out=$(KASPAVERSE_UPSTREAM_RECORD="$rec" KASPAVERSE_UPSTREAM_PIN="${PIN_OVERRIDE:-$PIN}" bash "$SELF" --from-fixture "$fxd" "$@" 2>&1); rc=$?
    if printf '%s\n' "$out" | grep -qE -- "$re" && [ "$rc" = "$want" ]; then printf '  ok   %s\n' "$label"
    else printf '  FAIL %s — expected /%s/ exit %s, got exit %s:\n' "$label" "$re" "$want" "$rc"
         printf '%s\n' "$out" | sed 's/^/         /'; fails=$((fails+1)); fi
  }
  local R="$work/fx/record.json" Z=0000000000000000000000000000000000000000
  echo "upstream revs selftest (fixture $fx):"
  run "no-op: clean record reads clean"            'UPSTREAM clean \(6 sources' 0 "$R" "$work/fx"
  plant "$R" "$work/r2.json" sources.rusty-kaspa.head.sha "$Z"
  run "planted rusty-kaspa head"                    'UPSTREAM MOVED  rusty-kaspa  head\.sha 0000000→' 1 "$work/r2.json" "$work/fx"
  plant "$R" "$work/r3.json" sources.rusty-kaspa.top_release.tag v0.0.0-planted
  run "planted rusty-kaspa release tag"             'MOVED  rusty-kaspa  top_release\.tag v0\.0\.0-planted→' 1 "$work/r3.json" "$work/fx"
  plant "$R" "$work/r4.json" sources.silverscript.top_tag.name v0-planted
  run "planted silverscript top tag"                'MOVED  silverscript  top_tag\.name v0-planted→.*\(stable\)' 1 "$work/r4.json" "$work/fx"
  plant "$R" "$work/r5.json" sources.argent.manifest.silverscript "$Z"
  run "planted argent manifest pin (L151's case)"   'MOVED  argent  manifest\.silverscript 0000000→' 1 "$work/r5.json" "$work/fx"
  plant "$R" "$work/r6.json" sources.argent-template.branches.episode-01.sha "$Z"
  run "planted argent-template branch head"         'MOVED  argent-template  branches\.episode-01 0000000→' 1 "$work/r6.json" "$work/fx"
  plant "$R" "$work/r7.json" sources.argent-playground.head.sha "$Z"
  run "planted argent-playground head"              'MOVED  argent-playground  head\.sha 0000000→' 1 "$work/r7.json" "$work/fx"
  plant "$R" "$work/r8.json" sources.kccs.head.tree "$Z"
  run "planted kccs tree"                           'MOVED  kccs  head\.tree 0000000→' 1 "$work/r8.json" "$work/fx"
  PIN_OVERRIDE=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
  run "T-A evaluator (pin ≠ newest release)"        'UPSTREAM T-A FIRED: rusty-kaspa newest release .* ≠ pin deadbee' 0 "$R" "$work/fx"
  unset PIN_OVERRIDE
  run "T-D evaluator (live negative control)"       'UPSTREAM T-D FIRED: silverscript v[0-9.]+ \(stable\) pins rusty-kaspa [0-9a-f]{7} ≠ pin' 0 "$R" "$work/fx"
  run "offline"                                     'UPSTREAM SKIP \(network unreachable\)' 0 "$R" "/nonexistent/upstream-fixture"
  cp -R "$work/fx" "$work/fx-rl"; printf '{"resources":{"core":{"remaining":3,"limit":60,"reset":0}}}' > "$work/fx-rl/rate_limit.json"
  run "rate-limited"                                'UPSTREAM SKIP \(rate-limited: 3 remaining' 0 "$R" "$work/fx-rl"
  cp -R "$work/fx" "$work/fx-bad"; printf '<html>rate limit exceeded</html>' > "$work/fx-bad/argent.head.json"
  run "unparseable reply is a per-source SKIP"      'UPSTREAM SKIP argent \(unparseable API reply\)' 0 "$R" "$work/fx-bad"
  run "…and the headline says 5 of 6"               'UPSTREAM clean \(5 of 6 sources; argent SKIP' 0 "$R" "$work/fx-bad"
  run "no record (public clone / first run)"        'UPSTREAM NO RECORD' 0 "/nonexistent/UPSTREAM_REVS.json" "$work/fx"
  run "--record refuses a partial observation"      'UPSTREAM --record REFUSED: argent' 1 "$R" "$work/fx-bad" --record
  cp "$work/r2.json" "$work/rt.json"
  run "--record round-trip: writes"                 'UPSTREAM recorded 6 sources' 0 "$work/rt.json" "$work/fx" --record
  run "--record round-trip: then clean"             'UPSTREAM clean \(6 sources' 0 "$work/rt.json" "$work/fx"
  rows=$((rows+1))
  if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["sources"]["rusty-kaspa"]["previous"]["head.sha"]==sys.argv[2] else 1)' "$work/rt.json" "$Z"
  then echo "  ok   --record round-trip: previous kept the planted value"
  else echo "  FAIL --record round-trip: previous.head.sha missing or wrong"; fails=$((fails+1)); fi
  run "--sweep-table renders the §0a rows"          '^\| `kaspanet/silverscript` \| master' 0 "$R" "$work/fx" --sweep-table
  # consensus-auditor 2026-09-10: T-A is a STABLE tagged release we are not on; T-D reads the TAG's manifest.
  cp -R "$work/fx" "$work/fx-rc"
  python3 - "$work/fx-rc/rusty-kaspa.releases.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d[0] = {"tag_name": "v1.3.0-toc.5", "prerelease": True, "published_at": "2026-06-03T13:34:34Z"}; json.dump(d, open(p, "w"))
PY
  PIN_OVERRIDE=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
  run "T-A ignores a pre-release release"           'T-A not fired: rusty-kaspa newest release v1\.3\.0-toc\.5 is a pre-release' 1 "$R" "$work/fx-rc" --sweep-table
  cp -R "$work/fx" "$work/fx-rel"
  python3 - "$work/fx-rel/rusty-kaspa.releases.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d[0] = {"tag_name": "v2.0.0", "prerelease": False, "published_at": "2026-06-05T12:09:13Z"}; json.dump(d, open(p, "w"))
PY
  PIN_OVERRIDE=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
  run "T-A resolves a stable release below the top tag" 'T-A FIRED: rusty-kaspa newest release v2\.0\.0 @ 90dbf07 ≠ pin deadbee' 1 "$R" "$work/fx-rel" --sweep-table
  unset PIN_OVERRIDE
  cp -R "$work/fx" "$work/fx-tag"
  cp "$work/fx-tag/silverscript.manifest.toml" "$work/fx-tag/silverscript.tag.manifest.toml"
  sed -i 's/a41a333b08848f41bf737b72592e463a6011b8ac/1111111111111111111111111111111111111111/g' "$work/fx-tag/silverscript.manifest.toml"
  python3 - "$work/fx-tag/silverscript.head.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["sha"] = "0" * 40; json.dump(d, open(p, "w"))
PY
  run "T-D reads the tag's manifest when master moved past the tag" 'T-D FIRED: silverscript v1\.0\.0 \(stable\) pins rusty-kaspa a41a333 ≠ pin cfafeb4' 1 "$R" "$work/fx-tag"
  rm -rf "$work"
  if [ "$fails" = 0 ]; then echo "upstream revs selftest: PASS ($rows rows)"; return 0; fi
  echo "upstream revs selftest: $fails of $rows FAILED"; return 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --record) MODE=record ;;
    --sweep-table) MODE=sweep ;;
    --print) MODE=print ;;
    --manifest-revs) shift; manifest_revs "$1"; exit $? ;;
    --from-fixture) shift; FIXTURE="$1" ;;
    --capture-fixture) shift; CAPTURE="$1" ;;
    --selftest) selftest; exit $? ;;
    -h|--help) usage; exit 0 ;;
    *) echo "upstream_revs.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[ -f "$PY" ] || { echo "UPSTREAM SKIP (tools/upstream_revs.py missing)"; exit 0; }

# ── transport: one function, curl or fixture; hard-timeouted; a token only raises the ceiling ──
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -z "$TOKEN" ] && [ -z "$FIXTURE" ] && command -v gh >/dev/null 2>&1; then
  TOKEN="$(timeout 5 gh auth token 2>/dev/null || true)"
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fetch() { # name url → 0 when a body was stored under $TMP/name
  local name=$1 url=$2
  if [ -n "$FIXTURE" ]; then [ -f "$FIXTURE/$name" ] && cp "$FIXTURE/$name" "$TMP/$name"; return; fi
  curl -fsS --max-time 12 -H 'Accept: application/vnd.github+json' \
    ${TOKEN:+-H "Authorization: Bearer $TOKEN"} -o "$TMP/$name" "$url" 2>/dev/null
}
rec_stamp() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("recorded_at_utc","?"))' "$RECORD" 2>/dev/null || echo none; }

# The first call is the cheapest way to fail fast once instead of fourteen times, and it is
# how a near-exhausted unauthenticated hour is refused before a half-observed run.
if ! fetch rate_limit.json "$API/rate_limit"; then
  echo "UPSTREAM SKIP (network unreachable) — record $(rec_stamp) stands"; exit 0; fi
REMAIN=$(python3 -c 'import json,sys;print(int(json.load(open(sys.argv[1]))["resources"]["core"]["remaining"]))' "$TMP/rate_limit.json" 2>/dev/null || true)
[ -n "$REMAIN" ] || { echo "UPSTREAM SKIP (unparseable API reply from /rate_limit)"; exit 0; }
if [ "$REMAIN" -lt 15 ]; then
  RESET=$(python3 -c 'import json,sys,datetime as d;print(d.datetime.fromtimestamp(json.load(open(sys.argv[1]))["resources"]["core"]["reset"],d.timezone.utc).strftime("%H:%MZ"))' "$TMP/rate_limit.json" 2>/dev/null || echo "?")
  echo "UPSTREAM SKIP (rate-limited: $REMAIN remaining, resets $RESET) — record $(rec_stamp) stands"; exit 0
fi

# ── the sources (the parse side of this list is SOURCES in upstream_revs.py — keep them aligned) ──
SOURCES='rusty-kaspa kaspanet/rusty-kaspa master tags,releases
silverscript kaspanet/silverscript master tags,releases,manifest
argent argent-lang/argent master tags,releases,manifest
argent-template argent-lang/argent-template master manifest,branch=episode-01
argent-playground argent-lang/argent-playground master -
kccs kaspanet/kccs main -'
while read -r name repo branch feats; do
  fetch "$name.head.json" "$API/repos/$repo/commits/$branch" || continue
  case ",$feats," in *,tags,*)     fetch "$name.tags.json"     "$API/repos/$repo/tags?per_page=100" ;; esac
  case ",$feats," in *,releases,*) fetch "$name.releases.json" "$API/repos/$repo/releases?per_page=5" ;; esac
  case ",$feats," in *,manifest,*)
    sha=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sha"])' "$TMP/$name.head.json" 2>/dev/null || true)
    # Raw content at the sha just observed: no race with a push, and not an API call.
    [ -n "$sha" ] && fetch "$name.manifest.toml" "https://raw.githubusercontent.com/$repo/$sha/Cargo.toml"
    # T-D reads what the RELEASE pins: when master has moved past the top tag, fetch the tag's
    # manifest too (consensus-auditor, 2026-09-10). The natural-sort top tag is the .py's call.
    if [ -f "$TMP/$name.tags.json" ]; then
      tsha=$(PYTHONDONTWRITEBYTECODE=1 python3 -c 'import json,sys; sys.path.insert(0, sys.argv[2]); import upstream_revs as u; t = u.top_tag(json.load(open(sys.argv[1]))); print(t["sha"] if t and t.get("sha") else "")' "$TMP/$name.tags.json" "$ROOT/tools" 2>/dev/null || true)
      [ -n "$tsha" ] && [ "$tsha" != "$sha" ] && fetch "$name.tag.manifest.toml" "https://raw.githubusercontent.com/$repo/$tsha/Cargo.toml"
    fi ;;
  esac
  case ",$feats," in *,branch=*) b=${feats##*branch=}; b=${b%%,*}; fetch "$name.$b.json" "$API/repos/$repo/commits/$b" ;; esac
done <<< "$SOURCES"

# kccs blobs are compared in exactly one place — the pinned table in tools/kcc_freshness.sh.
KCC_LINE="(fixture mode — probe not run)"; KCC_EXIT=0
if [ -z "$FIXTURE" ] && [ -x "$ROOT/tools/kcc_freshness.sh" ]; then
  KCC_OUT=$(bash "$ROOT/tools/kcc_freshness.sh" 2>/dev/null); KCC_EXIT=$?
  KCC_LINE=$(printf '%s' "$KCC_OUT" | tr '\n' '|' | sed 's/|$//')
fi

python3 "$PY" "$MODE" "$TMP" "$RECORD" "$PIN" "$CAPTURE" "$KCC_LINE" "$KCC_EXIT"
