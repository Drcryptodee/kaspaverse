# KaspaVerse

[![gate](https://github.com/Drcryptodee/kaspaverse/actions/workflows/gate.yml/badge.svg)](https://github.com/Drcryptodee/kaspaverse/actions/workflows/gate.yml)

**A sovereign wallet kernel + covenant arcade for the Kaspa BlockDAG.**

Android-first. Non-custodial. Built on [rusty-kaspa](https://github.com/kaspanet/rusty-kaspa)
v2.0.1 (the Toccata-hardfork line, pinned by immutable revision) — a Flutter UI over a Rust
core, with **keys that never leave Rust memory and never cross the language boundary**
(enforced by an executable proof gate, not aspirational — see [SECURITY.md](SECURITY.md)).

## What this becomes

**A minimal, excellent Kaspa wallet that grows one proven surface at a time.** There is no
destination noun here: the app is what it has proven, and the list below is a sequence, not
a claim. Two of the six are shipped.

- **Money** — Keystore/biometric vault, send/receive at 10 bps speed, fees priced by the
  pinned consensus crates rather than by us. **Shipped and device-proven** (status below).
- **Communication** — encrypted-payload messaging as a first-class L1 primitive: the
  challenge/handshake rail the games ride on, wire-compatible with the ecosystem's
  established Kasia payload format. **Shipped and interop-proven** against live
  third-party clients.
- **Contracts** — a covenant engine on Toccata (KIP-17/20): state machines whose rules live
  in the script, with no admin path, no upgrade proxy and no pause guardian unless the
  author writes one as a transition you can read before you fund it. **In progress.**
- **Games** — PvP duels with on-chain wager escrow, no house and no server holding funds.
  The design bar, which no contract ships without meeting: **every state has a timeout exit
  one player can take alone**, so an opponent who walks away cannot strand your money.
  Commit-reveal RPS → tic-tac-toe → **Attack & Defend** → ZK battleship (KIP-16,
  settlement-time proving) → tournaments.
- **Finance** — the contract engine turned inward: time-locked recovery, spending limits,
  dead-man's-switch inheritance. Funds owned by a rule you can read rather than a party you
  must trust. Market structures that need shared state (order books, AMMs) are **out of
  scope**, not queued.
- **Identity** — your keypair already is your identity; there is no login layer to import.
  Human-readable naming arrives natively or not at all.

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
found **zero code defects**. **Native transport shipped 2026-07-08** (Phase 2): encrypted
payloads on L1, byte-parity proven against the ecosystem's cipher and interop-proven
against live third-party clients on mainnet.

**Connection reliability closed 2026-07-31.** The wallet reaches the network through public
community nodes over a phone radio, and holding that link through weak signal and network
changes turned out to be the hard part — it took five iterations, and the root cause was
ours, not the nodes'. Verified across two multi-hour soaks of ordinary use on a real device:
zero healthy nodes wrongly blamed, and reconnects that used to hang now land in seconds
(residual limitation below).

In flight now: the **covenant engine** (Phase 3) — currently in an architecture pass that
settles the module boundary, the custody of covenant state, and the contract specs *before*
any contract is written. Then the arcade.

The state of every subsystem, and the reasoning behind every established choice, live in
the project's engineering record — which is private (see [CONTRIBUTING.md](CONTRIBUTING.md)).

### Known limitations (honest roadmap)

- **Send propagation can be variable.** The wallet reaches the network through public
  community nodes, so the time from broadcast to first confirmation depends on the node that
  accepts it — sometimes slower than mature wallets like Kaspium/Kasware. The transaction
  mechanics are correct and fully on-chain; the gap is node-infrastructure quality, not
  cryptography. Node-quality selection, fee-bump/replacement, and Send-Max are a planned
  dedicated performance pass.
- **A cold start on a weak, lossy link can take 14–28 seconds** before the first balance
  appears. This is known, measured, and deliberately not yet fixed: the reliability pass
  chose to fix *correctness* of the link first, and the remaining cost is latency on bad
  radio, not lost funds or wrong balances. Warm reconnects are seconds.
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
tools/gate.sh   # the proof gate, all eleven checks: fmt · clippy · tests · cargo-deny ·
                # arm64 cross-compile · dart format · analyze · flutter test ·
                # codegen-drift · repo hygiene · record boundary
```

Full toolchain + the contributor workflow: [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Contributing & security

This repo carries the product: the code, the CI, the tooling, and a proof gate anyone can
run. The engineering record behind it — constitution, decision ledger, research corpus,
phase plans — is private. Contributors and auditors get it in full.

- **[CONTRIBUTING.md](CONTRIBUTING.md)** — build from a clean clone, the proof gate, and the
  risk-tier auditor ritual.
- **[SECURITY.md](SECURITY.md)** — the security model, the threat-model boundary, and how to
  report a vulnerability privately.
- **[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)** — stag hunt, not prisoner's dilemma.

## License

MIT — see [LICENSE](LICENSE).
