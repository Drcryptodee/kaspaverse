# Contributing to KaspaVerse

Thanks for looking. KaspaVerse custodies strangers' money on an unpatchable ledger, so the
bar is unusual: **nothing is "done" until it is proven** (a green gate cited as evidence),
and a change that touches keys, the language boundary, or on-chain logic gets adversarial
review before it merges. This guide is how to clear that bar.

Development runs on an internal AI-assisted process. This repo carries the product — the
code, the CI, the tooling, and a proof gate you can run from a clean clone. The
engineering record behind it (constitution, decision ledger, research corpus, phase plans,
session journal) is private. If you're working on the code or auditing it, ask and you'll
get the whole thing.

## The one rule

> **Done = proven.** A claim without a green [`tools/gate.sh`](tools/gate.sh) is drift
> (INV-10). Run the gate; paste the result in your PR.

## Build from a clean clone

KaspaVerse is **Android-first** and currently **arm64-only** — upstream `kaspa-hashes` has no
x86_64-android assembly path, so x86_64 emulators won't run it. **Use a physical device.**

You need:

| Tool | Version | Why |
|:--|:--|:--|
| Flutter | 3.41.5 | the app + the `flutter`/`dart` toolchain |
| Rust | 1.94.0 (pinned in `rust/rust-toolchain.toml`) | the core/chain/bridge crates |
| `cargo-ndk` | for `aarch64-linux-android` | Android cross-compile |
| `cargo-deny` | latest | the supply-chain gate (INV-7) |
| JDK | 17 | the Android/Gradle build + `apksigner` |

Then:

```bash
flutter pub get                 # Dart deps
tools/preflight.sh              # orient: branch, toolchain, active phase
# build + run on a connected arm64 device:
flutter build apk --debug --target-platform android-arm64
flutter install
```

After editing any `rust/bridge` API types, regenerate the bindings (never hand-edit
`lib/src/rust/`):

```bash
flutter_rust_bridge_codegen generate
```

## The proof gate

[`tools/gate.sh`](tools/gate.sh) is the only arbiter of "done". It runs, in strict mode
(the same checks locally and in CI):

`cargo fmt` · `cargo clippy -D warnings` · `cargo test` · `cargo deny` (INV-7) · android
arm64 cross-compile · `dart format` · `flutter analyze` · `flutter test` · codegen-drift
(generated bindings match the Rust API) · public-repo hygiene (no tracked secrets) ·
internal-record boundary (the private engineering record can't drift into this repo).

**Never weaken a check to go green.** A failing gate is fixed at the cause; a check is removed
only via a decision-ledger entry. If your environment can't run a check, say so in the
PR — an honest partial beats a fake pass.

## Risk tiers + the auditor ritual

Every change is tagged **T0–T3** (in the commit message), and the tier selects mandatory
reviewers. The tier of a change is the highest tier of anything it touches.

| Tier | Touches | Mandatory review before merge |
|:--|:--|:--|
| T0 | UI, copy, theme | UX review |
| T1 | chain reads, indexer calls | consensus review |
| T2 | tx construction, fees, mass, broadcast | consensus + wallet-security |
| T3 | keys, vault, FFI surface, contracts, deps | FFI-leak + wallet-security + consensus + dependency-steward |

Reviews issue **PASS / CONCERNS / BLOCK** verdicts citing invariant (`INV-`) and
design-law (`BG-`) numbers — run against five internal domain-audit checklists
(consensus, wallet-security, FFI-leak, dependency-steward, UX). An absent mandated verdict
blocks the merge.

## How decisions are made (the epistemic order)

When sources conflict, the higher one wins: **working code + gate output → the pinned
`rusty-kaspa` crate source → the project's source-of-truth register → its research
corpus → a live network/web check → training data** (presumed stale — the network has hardforked, so never
the sole basis for protocol logic). In particular, **consensus logic is consumed from the
pinned crates, never re-implemented from memory** (INV-9). Reality wins: docs converge to the
build, never the reverse. Found drift? Fix it if it's in scope, else log it — never silently
ignore it.

## Read before you build (the spine)

The record is a "spine" of load-bearing documents. Ask for it before you start — it saves
you re-deriving settled ground:

- **The constitution** — the numbered laws (INV-1…12). Read first.
- **The source-of-truth register** — what is true right now: every subsystem's state,
  built or planned.
- **The decision ledger** — the *why* behind established choices (a thing may be
  deliberate before you "fix" it).
- **The research corpus** — the verified research behind every protocol and design claim.

The invariants that bind *your* change are summarised in [SECURITY.md](SECURITY.md), so a
small PR doesn't have to wait on the full record.

## Pull requests

- Branch from `main`; keep the diff the smallest that proves the bar (INV-12 — gold-plating
  is scope drift).
- Commit messages: `type(scope): summary` with the tier tag, e.g.
  `feat(receive): QR + payload-aware address [T1]`.
- Paste your gate result. For T2/T3, note the device proof and which auditor verdicts apply.
- By contributing, you agree your work is licensed under the project's [MIT License](LICENSE).

Welcome aboard — and thank you for holding the line on proof.
