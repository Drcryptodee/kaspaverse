# Bundled faces — provenance and integrity

**Two faces, never three** (BG-30): Plus Jakarta Sans **speaks**, JetBrains Mono
**counts**, and they never trade jobs. Both are committed, never fetched at
runtime or at build time (BG-16, INV-8).

**This file is machine-checked.** `tools/gate.sh`'s `bundled fonts (INV-7)` lane
asserts, on every run, that each file below still hashes to the digest recorded
here, that `pubspec.yaml` declares exactly these families, that no other font
file has appeared beside them, and that `RevealActivity.kt`'s two hand-written
asset paths still name files that exist. A digest in prose cannot fail a build;
this one can.

| File | Family | sha256 | Bytes |
|:--|:--|:--|--:|
| `PlusJakartaSans-Variable.ttf` | `PlusJakartaSans` | `89b3fb38aa0d275d7a731d0d817a4f1622b316b4d7fbdedcf02ee9099ff68bc8` | 176288 |
| `JetBrainsMono-Variable.ttf` | `JetBrainsMono` | `48715a42ec242c21e9f02692891e147d022299a52e48d5e413e1a942193ffeda` | 187208 |

## Plus Jakarta Sans

- **Upstream:** [`tokotype/PlusJakartaSans`](https://github.com/tokotype/PlusJakartaSans),
  by Tokotype. Mirrored into
  [`google/fonts/ofl/plusjakartasans`](https://github.com/google/fonts/tree/main/ofl/plusjakartasans)
  (`METADATA.pb`: designer Tokotype, license OFL, `date_added` 2022-03-24).
- **Licence:** SIL Open Font License 1.1 — `OFL-PlusJakartaSans.txt`, verified to
  be the Plus Jakarta Sans text ("Copyright 2020 The Plus Jakarta Sans Project
  Authors"), not a copy of a neighbouring font's licence.
- **Variable axes**, re-parsed from the binary's own `fvar` table rather than
  read off a website: **one axis, `wght`, min 200 · default 400 · max 800**, 7
  named instances. §2 needs 400–800, so the range covers it. Every slot pins
  `FontVariation('wght')` and never `FontWeight` (L150).
- **Fetched 2026-09-03** from google/fonts **and** from the designer's own repo;
  the two downloads are **byte-identical**.

  **What that check is worth, stated precisely** (`dependency-steward`, D-252):
  the two sources are **not independent** — `google/fonts` `ofl/` is populated
  *from* tokotype, so tokotype is their common ancestor and a compromise at the
  origin would propagate to both and still show byte-identity. What the
  cross-check actually rules out is tampering **at the google/fonts end or in
  transport**. That is real and worth having; it is not "two independent
  attestations", and the record should not claim it is.

## JetBrains Mono

Bundled since P1.3, under the same OFL terms
(`OFL-JetBrainsMono.txt`, upstream [`JetBrains/JetBrainsMono`](https://github.com/JetBrains/JetBrainsMono)).
**Its digest was never pinned anywhere until this file existed** — a
pre-existing gap the Plus Jakarta Sans intake surfaced rather than created, and
the reason the lane covers both faces instead of only the new one.

## Adding or replacing a face

1. Establish provenance **before the file enters the tree**: fetch from upstream,
   confirm the licence text belongs to *this* font, and re-parse `fvar` from the
   binary for the axes the type ramp actually pins.
2. Record its digest here **in the same commit**, and update `pubspec.yaml`,
   `KvFont`, `RevealActivity.kt`'s asset path, and every `FontLoader` in `test/`
   (L139 — an unloaded face makes every preview and every text-measurement guard
   lie, and they stay green while doing it).
3. A new dependency needs its `D-` entry (INV-7) and a `dependency-steward` pass.
