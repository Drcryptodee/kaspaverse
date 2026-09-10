# KaspaVerse

[![gate](https://github.com/Drcryptodee/kaspaverse/actions/workflows/gate.yml/badge.svg)](https://github.com/Drcryptodee/kaspaverse/actions/workflows/gate.yml)

A non-custodial Kaspa wallet and covenant app for Android. Flutter on top, Rust underneath,
and the keys never leave Rust.

KaspaVerse starts as a small wallet that does the basics well and grows from there into
covenant applications on Kaspa's L1: games with on-chain escrow, self-custody tooling, and
peer-to-peer swaps. Pure L1. No servers, no telemetry, no house, no custody.

## The stack

- **Kaspa after Toccata.** Covenants and covenant ids (KIP-20) are the primitive everything
  above the wallet is built on. No L2.
- **rusty-kaspa v2.0.1**, pinned by revision. Consensus logic, fees and mass come from the
  pinned crates. Nothing consensus-shaped is re-implemented here.
- **Silverscript v1** is the contract compiler ([kaspanet/silverscript](https://github.com/kaspanet/silverscript)),
  pinned by tag per contract. **Argent** ([argent-lang/argent](https://github.com/argent-lang/argent))
  is the actor language and runtime the contracts are written in. A contract is authored in
  Argent, compiled to Silverscript, and executed against the same pinned engine the wallet uses,
  with the compiled artifact committed and checked for drift.
- **The Kaspa Calls for Conventions** (KCC-1 covenant ABI, KCC-2 authority schemes, KCC-20
  tokens) are followed as drafts at a named revision. They change; we re-read them when they do.
- **Flutter 3.41 and Rust 1.94** over flutter_rust_bridge 2.12. The vault is the Android
  Keystore (StrongBox or TEE where present) behind BiometricPrompt, with an Argon2id passphrase
  path. The wallet talks wRPC to whichever Kaspa node you choose.
- **The proof gate**, `tools/gate.sh`: fmt, clippy, tests, cargo-deny, arm64 cross-compile,
  Dart analysis and tests, Kotlin, generated-binding drift, repo hygiene. If the gate is not
  green, it is not done.

## Surfaces

| Surface | What it is | Status |
|:--|:--|:--|
| Money | Vault, send, receive, live balance and activity, fees priced by the pinned crates | Shipped, device-proven on mainnet |
| Messaging | Encrypted payloads on L1, wire-compatible with Kasia and KaChat | Shipped, proven against live third-party clients |
| Contracts | The covenant engine: Argent contracts on Silverscript, executed at the pin | Designed; the toolchain is the next build |
| Games | An on-chain arcade. Offers stand on chain with their terms; anyone who meets them can take one. First game: Attack & Defend | Not started |
| Finance | The engine turned inward: time-locked recovery, spending limits, and peer-to-peer swaps of covenant assets with no escrow | Not started |
| Assets | What the app tells you about tokens other people issue, read from the script, before you accept one | Not started |

Three rules hold across all of them. Every contract state has a timeout exit one party can take
alone. Our own contracts carry no admin key, no pause and no upgrade path. The app takes no cut
of anything you do with your money: no send fee, no swap spread.

One exception is stated rather than hidden: the fiat price. It is the only thing on screen no
node can verify. It comes from an endpoint you can change or switch off, it never prices a fee or
a spend, and it never appears on a signing screen.

## Status

Alpha, unreleased. On a physical Android device you can create or restore a vault, receive and
send KAS on mainnet with the exact fee shown and a hold-to-sign confirm, message other Kaspa
wallets, and pick your own node. The UI is being rebuilt screen by screen; after that comes the
contract toolchain, then the covenant engine, then the arcade.

Known limitations:

- Confirmation time depends on the public node that accepts the transaction. The mechanics are
  correct; node quality varies.
- A cold start on a weak connection can take a while before the first balance appears. Warm
  reconnects take seconds.
- arm64 only, on a physical device. x86_64 emulators cannot run the upstream hashing crate at
  the pinned revision.

## Build

```bash
flutter pub get
tools/preflight.sh
flutter build apk --debug --target-platform android-arm64
flutter install
tools/gate.sh
```

Toolchain versions and the contributor workflow are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Security, conduct, licence

- [SECURITY.md](SECURITY.md): the security model, what is in scope, and how to report privately.
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
- The code is licensed under the ISC License ([LICENSE](LICENSE)). Third-party material keeps
  its own terms; [NOTICE.md](NOTICE.md) lists it. The name and the mark are not part of the
  licence grant; see [TRADEMARK.md](TRADEMARK.md).
