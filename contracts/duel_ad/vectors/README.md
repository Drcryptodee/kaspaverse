# duel_ad vectors — the founder-negative protocol (DP-9, D-121)

These fixtures are **emitted by the model, never written by hand**
(`rust/covenant/tests/duel_ad_model.rs` — DP-12). Positive vectors are
walker-searched paths reaching every terminal cause the machine has; negative
vectors are the refusals the compiled script and the pinned consensus rules
must make, each naming its enforcing layer. A model beats a human exactly
here: the negatives are enumerated from the frontier, not remembered.

## What to run, and what a colour means

**Today (C3 — no script exists yet):**

```bash
tools/gate.sh          # the model tests run inside `cargo test --workspace`
# or directly:
cargo test --manifest-path rust/Cargo.toml -p kaspaverse-covenant --test duel_ad_model
```

- **Green** = the committed machine, the committed vectors and every INV-6
  property agree: all reachable states enumerated, every property held
  (the run prints the census: reachable states, worst-case sole exit).
- **Red** = the machine changed without re-proof. Someone edited the model,
  the vectors, or the rules they encode, and the three no longer agree.
  **Do not build or audit against `contracts/duel_ad/` until it is green
  again** — the failing test names the violated property or vector.

**At P4 (a compiled template exists):** the parity harness (the P2.2 shape)
drives every positive step sequence and every negative refusal through the
compiled script via `kaspa-txscript` at the pin, and through
`check_sequence_lock` for the consensus-layer rows.

- **A red positive** = the script refuses a path the proven machine allows —
  a liveness defect; a player could be unable to take an exit the spec
  promises. BLOCK until fixed.
- **A red negative** = the script accepts what it must refuse — a fund-loss
  class defect. BLOCK, tier T2+, both mandated auditors re-read.

## Regeneration ritual

Vectors change **only** when the machine changes, and a machine change is a
spec change (T2 once a script exists; consensus-auditor mandatory):

```bash
KV_REGEN_VECTORS=1 cargo test --manifest-path rust/Cargo.toml -p kaspaverse-covenant --test duel_ad_model
git diff contracts/duel_ad/vectors/   # review every changed line
```

Never edit the JSON files directly — the golden test will (correctly) refuse
the divergence.

## Files

| File | Contents |
|:--|:--|
| `positive.json` | 9 scripted walks: regulation win · early elimination · sudden-death decisive pair · counter forfeit (3 claims) · bond exhaustion forfeit · dead-man tie refund · dead-man with leader mid-reveal · resign · sudden-death dead-man mid-pair |
| `negative.json` | 17 refusals with their enforcing layer: premature claims (three shapes — consensus `check_sequence_lock`, script CSV low-sequence, and the **disabled-bit bypass** where the script arm is the only wall) · claims without standing · wrong-signer / duplicate commits · wrong / replayed preimages · phase violations · fee overdraw · unregistered payout · wrong dead-man split · SD elimination · successor tampering |

`windows` in the fixtures use the Standard control (1800 DAA); windows are
per-match terms sheet values (Blitz floor 600 — `pvp_game_theory.md §6`), and
the properties are window-symbolic, so the fixtures stand for any control.
