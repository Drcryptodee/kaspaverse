# KaspaVerse

[![gate](https://github.com/Drcryptodee/kaspaverse/actions/workflows/gate.yml/badge.svg)](https://github.com/Drcryptodee/kaspaverse/actions/workflows/gate.yml)

**A sovereign wallet kernel + covenant arcade for the Kaspa BlockDAG.**

Android-first. Non-custodial. Built on [rusty-kaspa](https://github.com/kaspanet/rusty-kaspa)
v2.0.1 (the Toccata-hardfork line, pinned by immutable revision) — a Flutter UI over a Rust
core, with **keys that never leave Rust memory and never cross the language boundary**
(enforced, not aspirational; see [`docs/CONSTITUTION.md`](docs/CONSTITUTION.md)).

## What this becomes

The north star: a sovereign **everything-app for the pure-L1 Kaspa ecosystem** — finance,
communications, identity, and games as native L1 primitives. Built in this order:

- **A minimal, excellent Kaspa wallet** — Keystore/biometric vault, send/receive at
  10 bps speed, KIP-9-aware fees. **Shipped and device-proven** (status below).
- **Native transport** (next) — encrypted-payload messaging as a first-class L1
  primitive: the challenge/handshake rail the games ride on, wire-compatible with the
  ecosystem's established Kasia payload format.
- **The first covenant games on Kaspa L1** — PvP duels with on-chain wager escrow
  enforced by Toccata covenants (KIP-17/20), every move a ~1-second L1 transaction:
  commit-reveal RPS → tic-tac-toe → **Attack & Defend** → ZK battleship (KIP-16,
  settlement-time proving) → tournaments.
- **The covenant vault** — the same engine turned inward: time-locked recovery and
  spending limits; the wallet hardening itself.

Pure L1 — no L2, no house. No servers. No telemetry. Indexers are optional, untrusted
accelerators, always verifiable against the chain.

## Status

**Alpha — the sovereign loop is live and device-proven on mainnet.** On a physical Android
device you can create or restore a vault (biometric ceremony, `FLAG_SECURE` seed backup),
**receive** real KAS (with a scannable QR), watch balance and activity update live, and
**send** it back out — with the exact fee shown and an anti-blind-signing, hold-to-sign
confirm — then kill and relaunch and find everything still true. Keys stay in Rust at every
step (auditor-verified, not vibed).

What's done: the custody core, the platform vault, onboarding & backup, wallet sync, and
**send & receive** (Phase 1.1–1.7) — then **re-proven twice** in 2026-07: a five-pass
adversarial re-audit of the shipped wallet, and a full docs↔code grounding audit that
found **zero code defects**. The evidence trail is public in the decision ledger
(D-051…D-060). What's next: **native transport** (Phase 2), then the covenant engine and
the arcade.

The current state of every subsystem — built, in-flight, or planned — lives in
[`docs/SOURCE_OF_TRUTH.md`](docs/SOURCE_OF_TRUTH.md); the *why* behind every established
choice is ledgered in [`docs/DECISION_LOG.md`](docs/DECISION_LOG.md).

### Known limitations (honest roadmap)

- **Send propagation can be variable.** The wallet currently reaches the network through a
  single public community-node resolver, so the time from broadcast to first confirmation
  depends on that node's quality — sometimes slower than mature wallets like Kaspium/Kasware.
  The transaction mechanics are correct and fully on-chain; the gap is node-infrastructure
  quality, not cryptography. Node-quality selection, fee-bump/replacement, and Send-Max are a
  planned dedicated performance pass.
- **Restore scans a fixed 30-address window per chain** in the alpha. A wallet that used
  more than 30 receive addresses elsewhere can show an incomplete balance after restore —
  window growth is a recorded roadmap item. (Wallets created here stay inside the window.)
- **Arm64-only, physical device.** x86_64 Android emulators can't run upstream `kaspa-hashes`
  (no x86_64-android assembly path at the pinned revision) — use a real device.
- **Receive uses a single static address** for the alpha; next-unused address rotation is
  deferred to a later phase.

## Build & run

Android-first, **arm64-only**, physical device:

```bash
flutter pub get
tools/preflight.sh                                        # orientation
flutter build apk --debug --target-platform android-arm64 # then `flutter install`
tools/gate.sh   # the proof gate, all ten checks: fmt · clippy · tests · cargo-deny ·
                # arm64 cross-compile · dart format · analyze · flutter test ·
                # codegen-drift · repo hygiene
```

Full toolchain + the contributor workflow: [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Contributing & security

Development runs on an internal AI-assisted process; its working journal is not part of
this repo. What *is* here is the complete product record: the code, the research corpus,
a constitution, a decision ledger, and an executable proof gate — the same documents human
contributors and auditors use.

- **[CONTRIBUTING.md](CONTRIBUTING.md)** — build from a clean clone, the proof gate, the
  risk-tier auditor ritual, and the doc "spine".
- **[SECURITY.md](SECURITY.md)** — the security model, the threat-model boundary, and how to
  report a vulnerability privately.
- **[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)** — stag hunt, not prisoner's dilemma.
- **[docs/CONSTITUTION.md](docs/CONSTITUTION.md)** — the numbered invariants (INV-1…12) every
  change is checked against.

## License

MIT — see [LICENSE](LICENSE).
