# duel_ad — AUDIT (consensus-auditor, COVENANT C3 sitting)

**Date:** 2026-08-03 · **Auditor:** consensus-auditor (checklist version: C-items
8–16 + 19/20, skill as of 2026-08-01 D-115 amendment) · **Tier:** T1 sitting
(design + in-tree model; no `.sil` exists — the compiled-artifact halves of
items 13/14 re-run at P4 and this audit is void the day a `.sil` lands).

**AUDIT-SCOPE (restated verbatim):** `uncommitted working tree + index vs HEAD
(86fa7b4)  ||  ops mirror: uncommitted record vs 4bceb1b`

**Pinned to (sha256, working tree at C3 — re-pinned after the in-sitting
remediation below, per this audit's own disposition):**

| File | sha256 |
|:--|:--|
| `SPEC.md` | `2fd1f10a84df17aad33bceaae21e2640dfa8f1c452f4181a0b78018aa7e2d88a` |
| `STATES.md` | `4083a075a9cd8bc2f85dd3d92c12cb4e211da313fd3cf54a2a4ecb80e4ef3781` |
| `vectors/positive.json` | `e8f1ce83f23101b9c0aaeeac58fec9acb546773a4f853590fc8e0221c3c726b1` |
| `vectors/negative.json` | `f48110372dac54d93d435beef96b8be153138a1901756c3fa8094dbb6894f75a` |
| `vectors/README.md` | `ff34acde6ce2b056b8b90be211c2b1ddabfcc8c955b4800cef0c62cc97327fe0` |
| `rust/covenant/tests/duel_ad_model.rs` | `35730cef48e8de1b75d33cded20d44f257de873c044c50a83cbf7834acb5d8fb` |

Any change to any pinned file voids this audit (the golden test enforces the
vector half mechanically).

**REMEDIATION — all three CONCERNS fixed in-sitting (2026-08-03, before the
wrap commit), each exactly the minimal fix this audit named:**

1. **Terms-validity law stated and asserted** — SPEC §3.1 (bounds
   `W ∈ [600, 6000]`, refusal at genesis planning + confirm), STATES.md
   constructor-constants block, stag-hunt row updated to cite its
   precondition, and the model gained
   `the_terms_validity_law_bounds_every_window` (bounds at runtime; the
   3-window-exit ≤ half-statute ratio as a **compile-time const assertion**
   — the gate's clippy pass upgraded it from a runtime check). 5/5 tests
   green; the model-file hash above reflects the post-rustfmt final form.
2. **Per-move sighash named** — SPEC §4.2 + STATES.md authentication
   preamble: every signed row is `SIG_HASH_ALL` under the D-115 fill-site
   law; no `D-` exception exists for this contract.
3. **`premature_claim_disabled_bit` vector added** (script layer,
   `opcodes/mod.rs:1093-1094`) — regenerated via the README ritual;
   negative set now 17 rows; golden test green.

Verdict standing: **CONCERNS ×3 → all remediated in-sitting**; merge may
proceed. The compiled-template halves re-run at P4 as noted.

---

## VERDICT: CONCERNS (no BLOCK)

**Independently reproduced by this auditor, not taken from the record:**
`cargo test -p kaspaverse-covenant --test duel_ad_model` → 4/4 green;
**31,098 reachable states, 432 distinct terminals, P1 worst sole exit
3 windows + 7 transitions (bound 4)**; committed vectors byte-equal to the
model's emission. Every pin cite in SPEC §6/§12 re-read at the cargo checkout
of `cfafeb4c`: `check_sequence_lock` at
`tx_validation_in_utxo_context.rs:136-155`, called at `:53` **before** the
`TxValidationFlags` match (unconditional for Full / SkipScriptChecks /
SkipMassCheck); `SEQUENCE_LOCK_TIME_MASK`/`DISABLED` at `constants.rs:47,52`;
CSV at `opcodes/mod.rs:1066` with the input disabled-bit refusal at
`:1093-1094` and the masked comparison at `:1098`; `OpTxInputDaaScore` at
`:1282` (present, unused by the wedge). All cites exact. INV-6 holds on the
model: every reachable state has a bounded sole exit and the statute converges
by Anyone edges alone (P1/P4, re-proven this sitting). The standing rule is a
textbook prover ≠ subject guard (item 16): every default witness is chain
state — the claimant's own act, elapsed input age, the accused's empty slot —
never a message the defaulter controls. Item 15's table is honest and mostly
machine-backed. The three findings below are real but each has a minimal,
in-scope fix; none traps funds at rest.

### Findings

1. **[CONCERNS] No window-ceiling law — the stall-to-the-statute defense is
   parameter-conditional and the constraint is unstated** — violates the
   D-019 stag-hunt bar (checklist item 15; item 12's "stall paths favor the
   honest party"). SPEC §9's row ("a present opponent reaches forfeit in
   ≤ 3W ≪ 36,000") and promise-map row 5 ("stalling costs the staller") hold
   only while `max(W_commit, W_reveal) < W_DEADMAN`, and windows are
   **per-match free parameters with only a floor** (Blitz 600 —
   `pvp §6`; SPEC §3.1 lists them as unconstrained terms-sheet material).
   Failure scenario: a terms sheet with `W_commit ≥ 36,000` (consented, but
   nothing refuses it) → leader stalls in C_victim; the victim's claim
   matures at `W ≥` statute while `dead_man_settle` matures at 36,000 **on
   the same input**; the leader (or anyone) cranks first and takes the pot
   at score against a fully awake victim — defection pays the full pot. The
   three named controls all satisfy the constraint (max 6,000, 6× margin),
   and the model cannot see the pathology (window costs are symbolic counts;
   clock interleaving is not modelled). **Fix (minimal):** state the
   terms-validity law in SPEC §3.1 + STATES.md's constructor-constants block
   (`W_commit, W_reveal ≤ 6,000` — the Relaxed ceiling — or at minimum
   strictly `< W_DEADMAN`), name its enforcement site (the genesis
   plan/confirm first-party refusal, the same layer that pins payout
   addresses; the constants are baked at genesis so refusal-at-plan is the
   right site), and add one model assertion
   (`assert!(W_COMMIT.max(W_REVEAL) < W_DEADMAN)`).

2. **[CONCERNS] Per-move sighash type unnamed** — checklist item 20 / L79 /
   D-115. SPEC names `SIG_HASH_ALL` only at genesis (§3); §4.2's dual-arm
   rule and §5.2's "the signature gates abuse" are commitment claims whose
   truth requires ALL on **every** signed row. Failure scenario under a
   looser type (e.g. NONE): the signature stops committing to outputs, so a
   mempool observer rebinds a broadcast commit's successor state —
   substituting a commitment hash whose preimage the observer knows (the
   identity fields `domain ‖ covenant_id ‖ round ‖ role ‖ session_pk` are
   all public state) — and later "reveals" the victim's move at will. The
   space is **not** unconstrained (this is why no BLOCK): the ratified D-115
   fill-site law on `SignatureSlot` (`rust/covenant/src/seam.rs:258-270`,
   refusal implemented at P3.1; no signing code exists yet) is exactly the
   mandated constraint shape, and only the actor can produce the actor's
   signature. **Fix (minimal):** one sentence in SPEC §4.2 — *every signed
   row's signature is `SIG_HASH_ALL` under the D-115 fill-site law; no `D-`
   exception exists for this contract* — echoed in STATES.md's
   authentication preamble, so the per-row claims name their type.

3. **[CONCERNS] The disabled-bit bypass has no negative vector** — checklist
   item 13 (vectors must cover the dispute/refusal surface) against the
   D-116 clause-4 posture SPEC §6 itself adopts. At the pin, consensus
   **filters out** inputs whose sequence carries `SEQUENCE_LOCK_TIME_DISABLED`
   (`tx_validation_in_utxo_context.rs:138`), so for
   `sequence = W | (1 << 63)` the script CSV arm
   (`opcodes/mod.rs:1093-1094`) is the **only** enforcement layer — the one
   premature shape where defense-in-depth is down to one wall. SPEC §6 names
   the refusal, but the committed vector set — which SPEC declares to be the
   pinned P4 executed-rejection obligation — has no row for it, so P4's
   parity harness could discharge clause 4 without ever executing this
   shape. **Fix (minimal):** add a `premature_claim_disabled_bit` row
   (layer: `script`, enforcer: the `:1093` input disabled-bit arm) to
   `negatives()` in the model and regenerate (`KV_REGEN_VECTORS=1` + diff
   review per the README ritual).

### Notes (no action required)

- Item 8's ".sil implements each exit" half is **unadjudicable at C3 by
  design** (no `.sil` exists; SPEC says so in its status line and labels
  every promise-map row "design → 4" honestly). This audit covers the
  machine, the model, and the vectors; the compiled-template audit is P4's
  and re-pins this file.
- P7 is proven at **slice granularity**; sompi-granular conservation
  (fees vs the value floor) is the script's §5.1/§5.2 rules with the
  `overdraw_fee` vector at P4 — honestly labeled in SPEC §7's scope note.
- `every_transition_is_one_transaction` is a census tripwire (the model
  cannot express a MUX split); its own comment says so — honest, not
  overclaimed. The real 1:1 enforcement is A-3's single-template ruling plus
  P4's compiled-size check.
- `pvp §6`'s stale absolute-idiom paragraph (`:708-715`) is superseded eight
  lines below in the same collision block and in the v2.5 header — adequate
  proximity; no fix demanded.
- The A-10 race (late move vs standing claim) is correctly ruled
  both-outcomes-legitimate; the dead-man's exact-draw uniqueness kills the
  RBF-grief lane (§5.2) — verified reasoning, no gap found.
- Rulings audited and found sound: A-3 (dissolution is genuine — buffer-fed
  fees leave the session key propertyless), A-6 (the last revealer's only
  option is strictly dominated, `pvp §9` row 2), OQ-9 protocol half (the
  sequential-join refusal correctly prices the contested-singleton window),
  OQ-10 wedge discharge (single-template makes `SuccessorExpectation`
  complete — confirmed against `seam.rs:287-309`), OQ-8 idiom ruling
  (semantic identity argument is correct: every A&D clock is input age; both
  enforcement halves verified at the pin by this auditor).
- `docs/environment.local.md` (in scope as untracked): machine-local build
  notes only; no consensus content.

### INV citations

- **INV-6:** HELD on the model (P1/P3/P4 reproduced; worst sole exit
  3 windows + 7 transitions; the statute is a material-free Anyone exit from
  every reachable state). Finding 1 does not break INV-6 — funds always
  exit — it breaks a stag-hunt payoff claim under pathological terms.
- **INV-9:** HELD — no consensus logic re-implemented; every protocol claim
  cites the pin and the cites were re-read at `cfafeb4` this sitting; the
  walker models the contract's own rules, not consensus.
- **D-019 (stag hunt):** CONCERNS — finding 1 names the payoff gap (full pot
  to a stalling leader under `W ≥ W_DEADMAN` terms).
- **D-115 / L79 (constrain, then claim):** CONCERNS — finding 2; the
  constraint exists and is ratified, the spec's per-row claims must name it.
- **INV-10:** the model's proof is gate-carried (`cargo test --workspace` in
  `tools/gate.sh`) and was independently re-run for this verdict.

**Disposition:** merge may proceed once the three CONCERNS fixes land (all
are doc/vector/one-assert changes inside this sitting's own files — no
design change required); re-pin the hashes above after the vector
regeneration.
