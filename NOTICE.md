# NOTICE

This file records **who owns what** in this repository. It is an attribution aid; the
binding terms are the licence files it names.

## The original KaspaVerse work

Copyright (c) 2026 Drcryptodee. Licensed under the **ISC License** — see `LICENSE`.

That covers the code, tests, tooling and configuration written for this project: the
Flutter app under `lib/`, the Rust crates under `rust/core`, `rust/chain`, `rust/bridge`
and `rust/covenant`, the Android custody layer under `android/app/src/main/kotlin`, the
proof gate and scripts under `tools/`, the test suites, and the covenant artifacts under
`contracts/`.

`lib/src/rust/` is **generated** from this project's own Rust API by
`flutter_rust_bridge_codegen` and is committed for reviewability. It is derived from the
original work above and carries the same copyright and licence.

## Third-party material — not covered by the ISC License above

The following is **not** original KaspaVerse work. It is redistributed under its own
terms, its own copyright statements are unchanged, and nothing here relicenses any of it.

| Material | Where | Copyright | Terms |
|:--|:--|:--|:--|
| `tokio-tungstenite` 0.23.1, vendored | `rust/vendor/tokio-tungstenite/` | Daniel Abramov; Alexey Galakhov | MIT — `rust/vendor/tokio-tungstenite/LICENSE` |
| Cargokit (build tooling) | `rust_builder/cargokit/` | Matej Knopp | MIT and Apache-2.0 — `rust_builder/cargokit/LICENSE` |
| Plus Jakarta Sans (variable) | `assets/fonts/PlusJakartaSans-Variable.ttf` | The Plus Jakarta Sans Project Authors | SIL OFL 1.1 — `assets/fonts/OFL-PlusJakartaSans.txt` |
| JetBrains Mono (variable) | `assets/fonts/JetBrainsMono-Variable.ttf` | The JetBrains Mono Project Authors | SIL OFL 1.1 — `assets/fonts/OFL-JetBrainsMono.txt` |
| Gradle wrapper | `android/gradlew`, `android/gradlew.bat`, `android/gradle/wrapper/gradle-wrapper.jar` | the original authors, 2015-2021 | Apache-2.0 — headers in the scripts |
| BIP-39 English wordlist | `assets/bip39/english.txt` | the BIP-39 authors | see **Wordlist** below |
| Icon geometry transcribed from Lucide | `lib/src/ui/widgets/kv_glyph.dart` | Lucide Icons and Contributors; Feather icons, Cole Bemis | ISC (Lucide); MIT for the Feather-derived subset |
| Code of Conduct text | `CODE_OF_CONDUCT.md` | the Contributor Covenant authors | adapted from Contributor Covenant 2.1; attribution retained in the file. Its own terms are **unsettled** — see below |

The vendored copy of `tokio-tungstenite` is the crates.io tarball verbatim save for one
patched function; `rust/vendor/PROVENANCE.md` records the file-level digests and the gate
checks them on every run. Font digests and upstream sources are recorded in
`assets/fonts/PROVENANCE.md`, likewise machine-checked.

**Wordlist.** `assets/bip39/english.txt` is the canonical BIP-39 English wordlist (2048
words, sha256 `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`),
reproduced unmodified as specification data. It is included because a BIP-39 wallet must
use exactly this list; no claim of authorship over it is made here. The BIP-39 document's
own preamble declares the BIP MIT-licensed; the wordlist file carries no separate licence
statement upstream.

**Code of Conduct.** `CODE_OF_CONDUCT.md` is adapted from Contributor Covenant 2.1 and
retains the attribution that text asks for. The licence of the Covenant *text* could not be
established: neither the canonical 2.1 page nor the project FAQ states one, and the upstream
repository's own `LICENSE.md` is the Hippocratic License 3.0 — which covers the site's source
and is not stated to reach the Covenant document. Recorded so the next reader does not repeat
the search.

**Icons.** No icon package is a dependency. The glyph outlines in
`lib/src/ui/widgets/kv_glyph.dart` are transcribed from Lucide's path data and each one
names the Lucide icon it came from. Lucide is ISC-licensed and its Feather-derived icons
are MIT-licensed; both are separate from, and unaffected by, this project's own ISC
licence.

## Dependencies

Rust and Dart dependencies are **not** vendored into this repository (the two exceptions
above aside). They are resolved from `rust/Cargo.lock` and `pubspec.lock` and remain under
their own licences. `rust/deny.toml` carries an explicit SPDX allow-list, enforced by
`cargo deny` on every gate run, and names the three scoped copyleft exceptions that exist:
`malachite-base` and `malachite-nz` (LGPL-3.0-only) and `option-ext` (MPL-2.0).

**`malachite-base` / `malachite-nz` are LGPL-3.0-only and are statically linked** into the
Android library the app ships, reaching it through `kaspa-math`'s bignum arithmetic at the
pinned revision. They are named here because a statically linked LGPL component is the one
dependency whose terms attach to the **binary** rather than only to this tree. Their
copyright and terms are their own; nothing here relicenses them.

`rusty-kaspa` is pinned by immutable revision and consumed as a dependency: **no upstream
source file is copied into this tree**, though several modules mirror upstream constructions
under the project's consensus-provenance rule and some tests use upstream's own vectors, each
cited at its call site.

## Project scaffolding

Parts of the Android and Flutter project scaffolding originated from Flutter's own project
templates and carry Flutter's permissive licence rather than being authored here. They are
configuration, contain no application logic, and are noted for completeness.

## What this file does not yet cover

**Attribution inside the shipped binary is incomplete, and this is the honest statement of
it.** The app's About screen names the app's own ISC licence and opens Flutter's licence
page, which enumerates the **Dart package graph**. That list does not include the bundled OFL
faces, and it cannot include the Rust crates compiled into the native library, because those
are `cargo` dependencies rather than `pubspec` ones. Several of those terms — MIT's "included
in all copies", Apache-2.0 §4, OFL §2, LGPL-3.0 §4(a)/(b) — attach to a binary distribution.
This file is complete for the repository; the in-app surface is owed, and is tracked against
the first signed public release.

## Trademarks

Software licensing and trademark rights are separate. The ISC License covers the code and
grants no rights in the KaspaVerse name, logo or other project branding — see
`TRADEMARK.md`.
