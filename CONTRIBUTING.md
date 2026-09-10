# Contributing

KaspaVerse holds other people's keys and money on a ledger that cannot be patched. Two things
follow. Nothing is done until the proof gate is green, and any change that touches keys, the
Rust/Dart boundary, transactions or contracts gets a review before it merges.

## Build

You need:

| Tool | Version |
|:--|:--|
| Flutter | 3.41.5 |
| Rust | 1.94.0 (pinned in `rust/rust-toolchain.toml`) |
| cargo-ndk | with the `aarch64-linux-android` target |
| cargo-deny | current |
| JDK | 17 |

Android only, arm64 only, on a physical device. x86_64 emulators cannot run the upstream
hashing crate at the pinned revision.

```bash
flutter pub get
tools/preflight.sh
flutter build apk --debug --target-platform android-arm64
flutter install
```

If you change a type in `rust/bridge`, regenerate the bindings and never edit them by hand:

```bash
flutter_rust_bridge_codegen generate
```

## The gate

`tools/gate.sh` is the arbiter. It runs the same checks locally and in CI: cargo fmt, clippy
with warnings denied, cargo test, cargo-deny, the arm64 cross-compile, dart format, flutter
analyze, flutter test, the Kotlin build and lint, generated-binding drift, and repository
hygiene. Run it before you open a pull request and paste the summary.

Do not weaken a check to get green. Fix the cause. If your machine cannot run a check, say so
in the pull request.

## Review tiers

Every change carries a tier in its commit subject. The tier is the highest tier of anything
the change touches, and it decides who reviews it.

| Tier | Touches | Review before merge |
|:--|:--|:--|
| T0 | UI, copy, theme | UX |
| T1 | chain reads, indexer calls, contract specs | consensus |
| T2 | transaction construction, fees, mass, broadcast | consensus, wallet security |
| T3 | keys, vault, FFI surface, compiled contracts, dependencies | FFI boundary, wallet security, consensus, dependencies |

Reviews end in PASS, CONCERNS or BLOCK, each citing the invariant it rests on. A missing
mandatory review blocks the merge. The invariants that matter for security are summarised in
[SECURITY.md](SECURITY.md).

## Ground rules

- Consensus logic is consumed from the pinned rusty-kaspa crates. It is never re-implemented
  or written from memory.
- When code and documentation disagree, the code and the gate win, then the pinned crate
  source, then a live check of the network. Fix the drift or say where it is.
- Keep the diff the smallest one that proves the change.
- No secret may cross the FFI, exist as a Dart string, or enter a state manager. User-entered
  secrets enter once, as bytes, and are zeroed.

## Pull requests

- Branch from `main`.
- Commit subjects are one plain line: `type(scope): what changed [T0-T3]`, for example
  `fix(receive): reject addresses with the wrong prefix [T1]`. Add a short body only when the
  subject cannot carry it. No em dashes, no prose.
- Paste the gate summary. For T2 and T3, say what was proven on a device and which reviews apply.
- Third-party material comes with its origin and terms, and an entry in [NOTICE.md](NOTICE.md)
  in the same pull request.

## Licence

The project is licensed under the ISC License ([LICENSE](LICENSE)). By opening a pull request
you confirm that you wrote the contribution or have the right to submit it, and that you
license it under the same terms. You keep the copyright in what you wrote. There is no CLA.

The project currently has a single maintainer. If contribution terms change when the project
moves to an organisation, the change will be stated here and will apply going forward, not to
contributions already accepted.

Contributing code grants no rights in the KaspaVerse name or mark; see
[TRADEMARK.md](TRADEMARK.md).
