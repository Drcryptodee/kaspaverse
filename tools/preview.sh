#!/usr/bin/env bash
# Tier 2 of the review ladder: render every catalogued surface to a PNG with no
# device, and build a contact sheet to look at (D-228).
#
# The loop this exists to enable: propose -> render -> LOOK -> approve or
# redirect -> only then write code. Discovering a bad design call on the Android
# build is the expensive place to discover it: minutes per iteration, a phone in
# hand, and a wallet to unlock. This is seconds, and needs neither.
#
#   tools/preview.sh --baseline   # freeze the current look as "before"
#   tools/preview.sh              # render "after" and build the sheet
#   tools/preview.sh --open       # ... and open it
#
# What it CANNOT do, stated here so the sheet is never mistaken for proof:
#   - it cannot judge motion (still frames; use the frame strips, then glass)
#   - it cannot judge the panel (true black, refresh, brightness)
#   - it is not the gate. A green sheet is a design opinion, not a passing build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="build/preview"
BASE="$OUT/baseline"
SHEET="$OUT/index.html"
OPEN=0

for arg in "$@"; do
  case "$arg" in
    --baseline)
      # Freeze the CURRENT renders as the "before" column. Run this before
      # making changes; without it the sheet shows only the new state, which
      # is the half that cannot tell you whether anything improved.
      if [ ! -d "$OUT" ] || [ -z "$(ls -A "$OUT"/*.png 2>/dev/null || true)" ]; then
        echo "no renders yet — running one pass first so there is something to freeze"
        KV_PREVIEW=1 flutter test test/preview --update-goldens >/dev/null
      fi
      rm -rf "$BASE"; mkdir -p "$BASE"
      cp "$OUT"/*.png "$BASE"/ 2>/dev/null || true
      echo "baseline frozen: $(ls -1 "$BASE" | wc -l) surfaces"
      exit 0
      ;;
    --open) OPEN=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

echo "── rendering surfaces (no device) ──"
KV_PREVIEW=1 flutter test test/preview --update-goldens

python3 - "$OUT" "$SHEET" <<'PY'
import os, sys, html, datetime
out, sheet = sys.argv[1], sys.argv[2]
base = os.path.join(out, "baseline")
shots = sorted(f for f in os.listdir(out) if f.endswith(".png"))

# Group by surface name; the geometry is the second half of the filename.
surfaces = {}
for f in shots:
    stem = f[:-4]
    # Surface names contain "__" themselves, so split from the RIGHT: the
    # geometry is always the last segment.
    name, _, size = stem.rpartition("__")
    surfaces.setdefault(name, []).append((size, f))

rows = []
for name in sorted(surfaces):
    cells = []
    for size, f in sorted(surfaces[name]):
        before = os.path.join(base, f)
        has_before = os.path.exists(before)
        pair = []
        if has_before:
            pair.append(
                f'<figure><img src="baseline/{html.escape(f)}" loading="lazy">'
                f'<figcaption>before</figcaption></figure>')
        pair.append(
            f'<figure><img src="{html.escape(f)}" loading="lazy">'
            f'<figcaption>{"after" if has_before else "current"}</figcaption></figure>')
        cells.append(
            f'<div class="geo"><h3>{html.escape(size.replace("_"," "))}</h3>'
            f'<div class="pair">{"".join(pair)}</div></div>')
    rows.append(
        f'<section><h2>{html.escape(name.replace("__"," · "))}</h2>'
        f'<div class="geos">{"".join(cells)}</div></section>')

stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
doc = f"""<!doctype html><meta charset="utf-8">
<title>KaspaVerse — surface previews</title>
<style>
 :root{{color-scheme:dark}}
 body{{background:#050505;color:#ededed;font:14px/1.5 system-ui,sans-serif;margin:0;padding:32px}}
 h1{{font-size:20px;margin:0 0 4px}}
 .meta{{color:#8a8a8a;margin-bottom:8px}}
 .warn{{color:#e8b552;border:1px solid #3a2f16;background:#161206;padding:12px 14px;
        border-radius:8px;max-width:70ch;margin:0 0 28px}}
 section{{margin:0 0 40px}}
 h2{{font-size:15px;font-weight:600;color:#fff;border-bottom:1px solid #1c1c1c;
     padding-bottom:8px;margin:0 0 16px}}
 .geos{{display:flex;gap:32px;flex-wrap:wrap}}
 h3{{font-size:11px;font-weight:500;color:#8a8a8a;text-transform:uppercase;
     letter-spacing:.08em;margin:0 0 8px}}
 .pair{{display:flex;gap:12px}}
 figure{{margin:0}}
 img{{border:1px solid #222;border-radius:6px;display:block;max-height:74vh;width:auto}}
 figcaption{{color:#6a6a6a;font-size:11px;margin-top:6px;text-align:center}}
</style>
<h1>Surface previews</h1>
<div class="meta">{len(shots)} renders · {stamp} · rendered from the real widget tree, fixture data only</div>
<p class="warn"><b>What this cannot tell you.</b> These are still frames from a
headless render. They cannot judge <b>motion</b> (use the frame strips, then the
device), and they cannot judge <b>the panel</b> — true black, refresh rate and
brightness are settled on glass. A preview that is mistaken for proof is worse
than no preview.</p>
{"".join(rows)}
"""
with open(sheet, "w") as fh:
    fh.write(doc)
print(f"contact sheet: {sheet}  ({len(shots)} renders, "
      f"{'with' if os.path.isdir(base) else 'no'} baseline)")
PY

if [ "$OPEN" = "1" ]; then
  xdg-open "$SHEET" >/dev/null 2>&1 || echo "open it manually: $SHEET"
fi
