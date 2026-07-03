# Security Policy

KaspaVerse is a **non-custodial** wallet: it holds the keys to real funds on the Kaspa
BlockDAG, an **unpatchable public ledger**. A key leak is total and silent — discovered by
the victim, not us — and a covenant bug is fund loss, not a hotfix. We treat security as the
product, not a feature of it.

If you are deciding whether something is worth reporting: **if it could move, freeze, or
reveal funds or keys that shouldn't move, freeze, or be revealed, report it.**

## Reporting a vulnerability

**Please do not open a public issue for a security problem.** Use GitHub's private
vulnerability reporting:

> The repository's **Security** tab → **Report a vulnerability**
> (`https://github.com/Drcryptodee/kaspaverse/security/advisories/new`)
>
> Prefer email? `kaspaverse@gmail.com` reaches the maintainer privately too.

This opens a private advisory only the maintainers can see. Include:

- what you found and where (`file:line`, a commit, or a build);
- how to reproduce it, and the impact you believe it has;
- any proof-of-concept (a failing test or a minimal repro is ideal).

We aim to acknowledge a report within a few days and to keep you updated as we confirm,
fix, and prepare a disclosure. We will credit you in the advisory unless you ask us not to.
Please give us a reasonable window to ship a fix before any public disclosure — on a ledger
that cannot be rolled back, a coordinated release protects users who cannot patch retroactively.

There is **no bug-bounty program** at this alpha stage; reports are handled on good faith.

## The security model (what we guarantee, by design)

These are enforced invariants, not aspirations. The full numbered law is
[`docs/CONSTITUTION.md`](docs/CONSTITUTION.md); the security-critical ones:

- **No secret ever crosses the language boundary or lives on the GC heap (INV-1/2/3).**
  Private keys, seeds, mnemonics, and raw signatures are created, used, and destroyed in
  Rust; every secret type is `ZeroizeOnDrop`; signing and broadcast happen Rust-side only.
  A secret is never a Dart `String`, never in a state manager, never in logs, crash reports,
  or the clipboard. Only signed-transaction summaries, booleans, public data, and opaque
  handles cross to the UI.
- **Keys are wrapped by the platform vault (INV-4).** The seed-wrapping key lives in the
  Android Keystore (StrongBox/TEE when present), gated by `BiometricPrompt`, with an
  Argon2id passphrase fallback. The seed-backup screen blocks screenshots (`FLAG_SECURE`).
- **Every covenant state has a unilateral timeout exit (INV-6).** No contract state can be
  frozen forever by an adversary — a game an opponent can stall is a fund-loss bug.
- **No phoning home (INV-8).** No telemetry, no analytics, no mandatory servers. Indexers
  are untrusted, optional accelerators; the app degrades gracefully without them.
- **Consensus parity (INV-9).** Protocol logic is consumed from pinned `rusty-kaspa` crates,
  never re-implemented or "remembered" — so we inherit upstream's audited correctness.
- **Verifiable releases (INV-11).** Every released APK is signed, built from a tagged commit,
  and published with checksums; the build verifies the artifact's *actual* signer against a
  pinned certificate. See [`docs/RELEASE.md`](docs/RELEASE.md) to verify provenance yourself.
- **Supply-chain custody (INV-7).** Dependencies are pinned; `cargo-deny` (advisories,
  licenses, sources) runs in the gate on every push and weekly; every new dependency is a
  recorded decision.

## Threat model boundary

**In scope** (we want to hear about these):

- any path by which a secret crosses the FFI, reaches the GC heap, or is logged/persisted in
  the clear (an INV-1/2/3 break);
- key/seed extraction, vault-unlock or lockout bypass, biometric/passphrase weaknesses;
- transaction tampering: a signed transaction differing from what the confirm screen showed
  (anti-blind-signing), fee/mass miscalculation, or a broadcast the user didn't authorize;
- a covenant state with no working unilateral exit (INV-6);
- a dependency or build-provenance weakness (INV-7/11);
- address handling that enables poisoning or sending to the wrong recipient.

**Out of scope** (real risks, but outside what the app can defend):

- a rooted, malware-infected, or otherwise compromised OS, or a hostile custom ROM;
- physical attacks: device theft with a known PIN/passphrase, coercion, shoulder-surfing,
  a malicious screen overlay;
- the user's own backup hygiene — a seed written down insecurely, phished, or shared;
- bugs in Kaspa consensus itself, or in the upstream `rusty-kaspa` crates (report those
  upstream; we will track the pin);
- the inherent variability of public node infrastructure (see the README's known-limitations
  note on send propagation) — a reliability matter, not a custody one.

## Supported versions

KaspaVerse is **alpha**. Security fixes target `main` and the most recent tagged release
(currently the `v0.2.0-alpha` line). There are no long-term support branches yet.
