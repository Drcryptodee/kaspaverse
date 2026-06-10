# KaspaVerse

**A sovereign wallet kernel + covenant arcade for the Kaspa BlockDAG.**

Android-first. Non-custodial. Built on [rusty-kaspa](https://github.com/kaspanet/rusty-kaspa)
v2.0.0 (the Toccata hardfork release) — Flutter UI over a Rust core, keys never leaving
Rust memory.

## What this becomes

- **A minimal, excellent Kaspa wallet** — Keystore/biometric vault, send/receive at
  10 bps speed, KIP-9-aware fees.
- **The first covenant games on Kaspa L1** — PvP duels with on-chain wager escrow,
  enforced by Toccata covenants (KIP-17/20): commit-reveal RPS → tic-tac-toe →
  ZK battleship (KIP-16) → tournaments. Every move is a ~1-second L1 transaction.
- **Challenge transport** — encrypted payload messaging, wire-compatible with
  [Kasia](https://github.com/K-Kluster/Kasia).
- **Identity** — [KNS](https://app.knsdomains.org/) name resolution.

No servers. No telemetry. Indexers are optional, untrusted accelerators.

## Status

Pre-alpha — governance scaffold + Phase 0 (foundation) in progress. See
`docs/phases/PHASE_INDEX.md` for the roadmap and `docs/CONSTITUTION.md` for the
security invariants this project is built under.

## Development

This repo is built AI-first: `CLAUDE.md` routes an AI architect through a
constitution, phased plan, decision ledger, and an executable proof gate
(`tools/gate.sh`). Humans welcome — the same documents are the contributor guide.

```bash
tools/preflight.sh   # orientation
tools/gate.sh        # the proof gate: fmt, clippy, tests, cargo-deny, analyze
```

## License

MIT — see [LICENSE](LICENSE).
