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
a claim. Two are shipped.

- **Money** — Keystore/biometric vault, send/receive at 10 bps speed, fees priced by the
  pinned consensus crates rather than by us. **Shipped and device-proven** (status below).
- **Communication** — encrypted-payload messaging as a first-class L1 primitive: the
  challenge/handshake rail the games ride on, wire-compatible with the ecosystem's
  established Kasia payload format. **Shipped and interop-proven** against live
  third-party clients.
- **Contracts** — a covenant engine on Toccata (KIP-17/20): state machines whose rules live
  in the script. **The contracts KaspaVerse itself ships carry no admin path, no upgrade
  proxy and no pause guardian**, and every state has a timeout exit one party can take
  alone. That is a claim about *our* contracts, not about every asset the app can display —
  see **Assets** below for what we promise about someone else's. **In progress.**
- **Games** — PvP duels with on-chain wager escrow, no house and no server holding funds.
  The design bar, which no contract ships without meeting: **every state has a timeout exit
  one player can take alone**, so an opponent who walks away cannot strand your money.
  Commit-reveal RPS → tic-tac-toe → **Attack & Defend** → ZK battleship (KIP-16,
  settlement-time proving) → tournaments.
- **Finance** — the contract engine turned inward: time-locked recovery, spending limits,
  dead-man's-switch inheritance — funds owned by a rule you can read rather than a party you
  must trust — **and peer-to-peer swaps of native covenant assets, with no house and no
  escrow.** A swap here is one ordinary transaction that either happens or doesn't: both
  sides sign the whole thing, so deleting the other party's payout invalidates their own
  signature. Counterparties are found and terms are agreed over the encrypted messaging rail
  above, which means no server and no order-book operator. Market structures that need
  shared state (order books, AMMs) remain **out of scope, not queued** — a single pooled
  UTXO that every trader must spend serialises trades and manufactures exactly the
  extractable-value surface "no house" exists to avoid. **Not started.**

- **Assets** — what we promise about tokens *other people* issue, which is different from
  what we promise about our own contracts: **we add no authority and hold no key over
  anything, and we compute what an asset's owners can do to it and show you before you
  accept it.** Kaspa covenants make that answerable from the bytes, locally — consensus
  guarantees a lineage name is unforgeable and nothing else, so supply, ownership and
  freezability all live in the script where they can be read. We do not refuse assets whose
  issuer can freeze them; that would hand the entire dollar surface to custodial apps and
  your money is your business. We show you which kind you are holding. **Not started.**
- **Identity** — your keypair already is your identity; there is no login layer to import.
  Human-readable naming arrives natively or not at all.

Pure L1 — no L2, no house. No servers. No telemetry. Indexers are optional, untrusted
accelerators, always verifiable against the chain.

## How this gets paid for

**KaspaVerse takes no cut of your transactions. Not a swap spread, not a send fee, not a
percentage of anything you do with your own money.** That is a standing constraint, not a
launch promise — it is written into the project's decision ledger and it rules out the
revenue model most wallets use.

The reason is alignment rather than generosity. A wallet earning a slice of your
transactions earns more when you transact more, which quietly points the product at making
you trade rather than at making trading rare and cheap. We would rather not carry that
gradient, because the entire claim of this app is that its interests and yours are the same
one.

So the app is a **public good**, and anything sold sits beside it as a **separate business
with separate money** — paid for by someone other than the sovereign user. Tooling for
people building on the covenant engine. Sponsorship. Optional services you can decline
without the app getting worse.

The test we hold ourselves to is not the licence. In the famous cases where an open project
quietly closed — Red Hat, Android — **the licence never changed**; what moved behind the wall
was everything needed to actually build the thing. So MIT is not the promise. **The app
building and running for a third party, with every optional service switched off, is the
promise** — and it is a thing you can check rather than a thing you have to believe.

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

Next: a **grounding pass** — the covenant standards the ecosystem is converging on (the
Kaspa Calls for Conventions, `KCC-0001/0002/0020`) landed in August 2026 and land directly on
top of the covenant engine's design, so the engine's wire format, authority model and
toolchain get settled against them before any contract is written. Then the **covenant
engine** (Phase 3), then the arcade.

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
- **Restore discovers the address window from the chain** (balance-driven, 256 automatic /
  2048 via a manual deep scan). The fixed 30-address window is only the fallback when
  discovery cannot complete — a restored wallet that used more addresses elsewhere is
  found, not truncated.
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
tools/gate.sh   # the proof gate, all seventeen lanes: cargo fmt · clippy · test (bounded) ·
                # cargo-deny · arm64 cross-compile · dart format · flutter analyze ·
                # flutter test · gradle wrapper · kotlin compile · android lint (NewApi) ·
                # codegen-drift · contract spine · toolchain pins · repo hygiene ·
                # record boundary · record pointers
                #
                # The roster is asserted, not implied: a lane that fails to report at all
                # is a failure, so GREEN means the lanes this tree declares actually ran.
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
