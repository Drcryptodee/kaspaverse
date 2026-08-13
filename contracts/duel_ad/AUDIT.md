# duel_ad — AUDIT (consensus-auditor, COVENANT C6 · FINAL sitting)

**Date:** 2026-08-07 · **Auditor:** consensus-auditor (checklist: C-items 8–16 +
19/20, skill as of the 2026-08-03 L81/D-121 amendment) · **Tier:** T1 sitting
(design + in-tree model; still no `.sil` — the compiled-artifact halves of items
13/14 re-run at P4 and this audit is void the day a `.sil` lands).

> **⚠ THE PIN TABLE BELOW IS SUPERSEDED.** Two of its rows moved after this
> sitting. The **live** pin table is the one under
> [Re-pin sitting — 2026-08-13](#re-pin-sitting--2026-08-13-product-audit-run-1-fix-wave)
> at the foot of this file; read that one. This table is kept verbatim because it
> is part of the C6 sitting's own evidence, not because it is current.

**AUDIT-SCOPE (restated verbatim):** `uncommitted working tree + index vs HEAD
(52f35ed)  ||  ops mirror: uncommitted record vs ac7bc95`

The injected diff was **TRUNCATED** (2,937 lines > the 2,000-line cap). Per the
skill's own instruction this verdict was written after reading the files
directly: `SPEC.md` §3.1/§5.1/§5.1.1 (whole), `STATES.md` (whole),
`rust/covenant/tests/duel_ad_model.rs` (constants + const-assertion block,
`payouts()`, `resolve()`, the vector emitter), both vector files (parsed as JSON
and arithmetically checked), `DECISION_LOG.md` D-127/D-128/D-129/D-130 + the
D-129 addendum, `covenant_engine_architecture.md` §8.6/§8.6.1/§8.8,
`covenant_engine_lexicon.md` §3.4, the P3 covenant-engine phase file
§0 + the P4-inheritance block, the covenant-pass notes OQ-11/OQ-12,
SOURCE_OF_TRUTH §8 header, and the P3.1 session prompt.
(Those four live in the internal engineering record, not in this repo — D-102.)

**Re-pinned to (sha256, working tree at this sitting):**

| File | sha256 | vs the previous pin |
|:--|:--|:--|
| `SPEC.md` | `f5be33f18fd74c0b1eb1ebaf54cf3fc3be48dd4a52be3b45e5247746e8aad476` | changed |
| `STATES.md` | `2d07cd1860eba404e8e2d318dea781e017bb9c057e75e21de5e28df4749d4d7d` | changed — **re-pinned at the wrap after this audit's finding was remediated** (`:100-102` now carries law B's binding-condition floor, not the superseded `β ∈ [φ, α]`); the verdict above is unaffected by that edit, as it anticipated |
| `vectors/positive.json` | `83ae497e53065874de8ac6c7c9ee2299c5981b4f6d4a76ca3bad65b4b975ff25` | **unchanged** |
| `vectors/negative.json` | `b257717f430faa997a6b63b2523438543d9b4e4e47d7255ae0f5ea7576ffbb9e` | changed |
| `vectors/README.md` | `ff34acde6ce2b056b8b90be211c2b1ddabfcc8c955b4800cef0c62cc97327fe0` | **unchanged** |
| `rust/covenant/tests/duel_ad_model.rs` | `20cd387b623eb9e049cfd66a8b3edb6d0e23bf3fc9e9f4af5ed5bad9f66a5973` | changed |

Any change to any pinned file voids this audit. `STATES.md`'s hash being
**unchanged** is itself the evidence for the one open finding below: the law-B
restatement did not reach it. Applying that one-line fix changes this row, and
the wrap must re-run `sha256sum` on it — the verdict is unaffected by that edit,
which is precisely what makes it safe to name here.

---

## VERDICT: CONCERNS ×1 (0 BLOCK · 1 CONCERNS · 0 nits) — merge unblocked

**Reproduced by this auditor, not taken from the record:**

- `cargo test --manifest-path rust/Cargo.toml -p kaspaverse-covenant --test
  duel_ad_model` → **5/5 green**, 1.45 s. Census printed and matching the claim:
  **31,098 reachable states, 432 distinct terminals, P1 worst sole exit 3 windows
  + 7 transitions (bound 4)**.
- `tools/gate.sh` → **GREEN, pass=11 fail=0 skip=0** (run here, not quoted).
- `vectors/positive.json` re-parsed and re-checked arithmetically: **9 terminal
  payout rows, every one summing to exactly `2,147,303,688` sompi = `VALUE_FLOOR`
  (a single distinct value across all nine), minimum payout exactly `23,651,844`
  = `L_FLOOR`.** Item 9 (value conservation) and D-127's tight bound both hold on
  the committed fixtures, not merely in the model.
- `vectors/negative.json`: **19 rows** (17 at C3 + D-129's two).

## Disposition — the five findings this sitting was called to re-check

| # | Finding | Owner | Status |
|:--|:--|:--|:--|
| A | value-floor fix reached the normative sites but not five secondary ones | consensus | ✅ **CLEARED — all five, verified individually** |
| B | law B's `β` floor fails on units and leaves an inert sub-range | consensus | ✅ **CLEARED in substance** — the restated law is sound and non-inert. ⚠ **two sites still carry the superseded form** → the one open finding |
| C | the conservation `assert_eq` is a tautology, SPEC called it a proof | consensus | ✅ **CLEARED** |
| D1 | the silverscript citation is not rev-scoped | steward | ✅ **CLEARED** |
| D2 | `§8.8`'s checklist numbering would re-point three live "item 7" cross-refs | steward | ✅ **CLEARED** |
| D3 | the audit-freshness deferral reason overstates an INV-7 question | steward | ✅ **CLEARED** |

### A — CLEARED at all five sites.

Each read at its line, not taken from the brief:

| Site | Now reads | ✓ |
|:--|:--|:--|
| `covenant_engine_lexicon.md:130` | *"stakes + the **genesis bond capital** + the settlement reserve"*, with the ⚠ C6 amendment note naming `2 · BOND_SLICES · b` a genesis constant and `SETTLE_RESERVE = 2 · L_FLOOR` | ✅ the canonical definition is now the correct one, reserve term included |
| `P3_covenant_engine_ACTIVE.md:37` | `value_out ≥ stakes + BOND_CAPITAL + SETTLE_RESERVE` with both the genesis-constant clause and the covenant-scope clause | ✅ what P3.1 builds against is correct |
| `vectors/negative.json:82` (`overdraw_fee`) | the full enforcer string incl. *"BOND_CAPITAL = 2\*BOND_SLICES\*b is a GENESIS CONSTANT, not the remaining bond fields"* and the covenant-scope clause | ✅ and it came through the **model**, regenerated — the golden test is green, so the fixture cannot drift from the emitter |
| `COVENANT_PASS.md:374` (OQ-11) | `value_out ≥ stakes + BOND_CAPITAL + SETTLE_RESERVE` + the under-reservation reasoning | ✅ |
| `SOURCE_OF_TRUTH.md:5` | same, with the *"not a read of the remaining bond fields"* clause and the 1.0 KAS exposure named | ✅ the grep target is correct |

**Swept for residue, not just spot-checked.** `grep -rn "stakes + bonds\|stakes +
bond_a\|both bond remainders\|bonds + SETTLE_RESERVE"` over `*.md`/`*.rs`/`*.json`
returns **zero live occurrences** outside this audit file's own history. The three
remaining `bond remainders` hits (`duel_ad_model.rs:40,1075`, `SPEC.md:330,561`,
`STATES.md:183`) are §5.3's *payout* language — what the settlement pays out —
which is correct and must not be changed; they are a different quantity from the
floor's reserve. `SPEC.md:377` is the ⚠ rationale block quoting C3's superseded
form on purpose. No site contradicts.

### B — the restated law is sound and non-inert. Judged, not accepted.

Law B now reads (`SPEC.md §3.1`, `§8.6.1`'s blockquote, `duel_ad_model.rs:183-188`):

> `β · stake / 5 ≤ b ≤ α · stake / 5`, `α ≤ ½`, with `β` bounded below by the
> condition that its own term binds: **`β · stake / 5 ≥ 10 · FEE_MOVE_CAP`**.

**Non-inert — by construction, and that is the whole point.** Under the condition,
`max(10·FEE_MOVE_CAP, β·stake/5)` **always** selects the `β` term. The inert
sub-range does not shrink; it ceases to exist. The failure mode the C6 finding
named (*a terms sheet obeys the law while `b` sits at the fee floor*) is now
unrepresentable at the refusal site rather than merely unlikely.

**Sound on units — the cross-unit comparison is gone.** The old form compared `β`
(against the stake) to `φ` (against the pot). The new form compares
`β·stake/5` to `10·FEE_MOVE_CAP` — **both sompi**, both the same object (`b`).
There is no unit to get wrong.

**Ranged over the parameter space (item 15 as amended by L81/D-121), by me:**
substituting law S (`stake ≥ 23·FEE_MOVE_CAP/φ`) gives
`β ≥ 50·φ/23 ≈ 2.174·φ` — and **`FEE_MOVE_CAP` cancels**, so the condition is
invariant in `R` *and* invariant across law M's whole admissible cap range
(`relay_floor … 2×relay_floor`). §8.6.1's "R-invariant" claim is therefore
stronger than it states, and correct. At `φ`'s ceiling of 2 % the crossover is
4.35 %; the ruled `β = 5 %` clears by **1.15×** — the document's own number, which
I recomputed. At the ruled stake the margin is **2.35×** (5 % against 2.13 %),
likewise reproduced. The dominance claim now holds over the admissible space, not
at a preset.

**Machine-asserted, and the assertion is the law and not a restatement of the
preset:** `B_BETA_FLOOR >= 10 * FEE_MOVE_CAP_FLOOR` (`:183-188`) sits beside
`B_SLICE >= B_BETA_FLOOR` and the α ceiling `5*B_SLICE <= STAKE/2`, all
compile-time. Using `FEE_MOVE_CAP_FLOOR` rather than a free cap is correct here
and not a narrowing, because — as computed above — the condition is cap-invariant
once law S is applied; the runtime refusal over a negotiated sheet is the P3.1
genesis-planning deliverable, where the actual cap is known.

### C — CLEARED.

`SPEC.md §5.1.1` now reads: *"the load-bearing element is the `checked_sub` — it
panics when a terminal owes more than the floor guarantees. The conservation
`assert_eq!` beside it is algebraically an identity at today's row set, so it is a
**tripwire against future edits** … rather than a proof in its own right.
Distinguished here because calling a tautology a proof is how the next defect
hides."* That is the distinction exactly, with the reason for making it. Verified
against the code: `payouts()` (`:426-434`) asserts conservation, then
`value.checked_sub(2*STAKE + BOND_CAPITAL)` with a panic message naming the
terminal — the panic is the proof, the assert is the guard.

### D1/D2/D3 — cross-checked for the steward, all three land.

- **D1.** `DECISION_LOG.md:5664` carries a *D-129 addendum* naming
  `michaelsutton/silverscript` rev `d57e5df`, branch `argent-sil-integration`,
  stating that all three coordinates are false on canonical master and that the
  capability survives the rename. The call-sites agree: `SPEC.md:620` (*"at the
  pinned rev `d57e5df`"*), `SPEC.md:833`'s pin table row, `COVENANT_PASS.md:101`,
  and `duel_ad_model.rs:1605` — which carries the rev *inside the emitted vector
  string*, so the golden test now defends the citation mechanically. Append-only
  handled correctly (addendum, not an edit).
- **D2.** `§8.8` is numbered **1–9 sequentially**, item 7 is
  `used_script_units`, and the merged-settlement item is **9, last**, with the
  reason stated in place. The three live cross-refs resolve:
  `covenant_engine_architecture.md:552`, `utxo_contract_prior_art.md:148` and
  `:282` all point at "§8.8 item 7" and all land on `used_script_units`. ✅
- **D3.** `P3_covenant_engine_ACTIVE.md:198-212` restates it as scheduling
  (*"it belongs with the harness that consumes it — and **not** because the hasher
  is an open INV-7 question"*), names `sha2 0.10.9` as already resolved in
  `rust/Cargo.lock`, classes it a D-022a admission, and annotates the superseded
  wording in place. ✅

---

## Finding — the one open item

**[CONCERNS] Law B's superseded `β ∈ [φ, α]` floor survives in two sites, one of
them a pinned normative contract artifact.** Checklist item 14 (*the spec ↔ script
gap; drift between prose and rule is the classic covenant audit failure*),
item 15 as amended by L81/D-121, INV-10.

| Site | Still reads | Why it matters |
|:--|:--|:--|
| `contracts/duel_ad/STATES.md:100-101` | *"**Law B's bounds are terms-sheet material too:** `5b ∈ [β·stake, α·stake]`, **`β ∈ [φ, α]`**, `α ≤ ½` — refused out of range at the same site as the windows."* | A **pinned artifact P4 writes the refusal from**, with no supersession marker. Implemented as written, the genesis refusal admits the entire `β ∈ [φ, 2.17φ)` band — verbatim the inert range finding B exists to delete. Its sha256 is unchanged this sitting, which is how I found it |
| `covenant_engine_architecture.md:715` | the superseded §8.6 law-B row: *"the law is now two-sided … **with `β ∈ [φ, α]`**, `α ≤ ½`"* | Lower severity — the row opens *"⚠ SUPERSEDED at C6 (D-128) → §8.6.1"* and routes readers to the corrected home — but it restates the wrong floor inline, in the table a P4 session reads first |

**Failure scenario (why it is not merely cosmetic).** P3.1's deliverable is the
genesis-planning refusal beside the window bounds. `STATES.md`'s constructor block
is where that refusal's constants live and is the artifact the phase packet points
at. A builder implementing `β ≥ φ` from it accepts a terms sheet at `φ = 1 %`,
`stake = 10 KAS`, `b = 0.0426 KAS` (standing bond 0.213 KAS = 2.13 % of stake):
it clears `5b ≥ φ·stake = 0.0979 KAS` comfortably, and law B collapses to its fee
term — nothing prices grief-by-delay, which is the entire content of D-128's
ruling. Not a fund-loss (no covenant value is at risk; the machine proof, the
payout tables and the value floor are untouched), which is why this is CONCERNS
and not a BLOCK.

**Fix (minimal), two one-line edits:**

1. `STATES.md:100-101` → *"`5b ∈ [β·stake, α·stake]`, `α ≤ ½`, with `β` bounded
   below by the condition that its own term binds — `β·stake/5 ≥ 10·FEE_MOVE_CAP`
   (`SPEC.md §3.1`) — refused out of range at the same site as the windows."*
   Then re-run `sha256sum contracts/duel_ad/STATES.md` and update this audit's
   pin row.
2. `covenant_engine_architecture.md:715` → drop `with β ∈ [φ, α]` from the
   superseded row; leave the pointer to §8.6.1, which states the floor correctly.

---

## Notes (no action required)

- **`D-130`'s body (`DECISION_LOG.md:5637`) still carries the superseded
  audit-freshness reason** (*"std has no sha256 and adding a hasher is an INV-7
  decision"*). The ledger is append-only and the correction landed in the P3
  packet with an explicit *"the earlier wording was …"* annotation, so nothing is
  wrong — but D-129 got an **addendum** for the same class of correction and
  D-130 did not. One addendum line would make the ledger self-consistent about
  its own repair convention. Steward's item, recorded here for the wrap.
- **Items 8, 10, 11, 12, 16, 19, 20 re-checked and unmoved.** This remediation is
  documentation plus three const assertions; the census is byte-identical
  (31,098 / 432 / 3 windows + 7 transitions), no exit changed, no witness surface
  changed, no sighash claim changed (item 20's D-115 fill-site law stands as
  ratified), no await introduced. The C6 pin verification of `check_sequence_lock`,
  `SEQUENCE_LOCK_TIME_MASK/DISABLED`, the CSV arm and `OpTxInputIndex` stands
  unaltered — **no protocol claim moved**, so INV-9 needs no re-derivation.
- **The vectors were regenerated, not hand-edited.** `negative.json`'s hash moved
  and `positive.json`'s did not, which is exactly the expected signature of an
  enforcer-string change routed through the model: the payout arithmetic was never
  wrong, only the guarantee's wording. The golden test is the proof, and it is
  green.
- **P12's worst case is genuinely worst.** Re-derived here: at `VALUE_FLOOR`,
  `buffer = SETTLE_RESERVE = 47,303,688`, `half = 23,651,844 = L_FLOOR`, and a
  loser holding no slices against an opponent holding five receives exactly that.
  The bound is tight in both directions — deleting the reserve fails the property
  rather than silently re-opening the hole.

## INV citations

- **INV-6:** **HELD.** Every reachable terminal emits a broadcastable settlement
  whose smallest output is `≥ L_FLOOR` — proven exhaustively over 432 terminals,
  tight, and reproduced in the committed fixtures by arithmetic here. Every state
  retains a unilateral bounded exit (P1/P4 re-run).
- **INV-9:** **HELD.** No consensus logic re-implemented or remembered; no
  protocol claim moved in this remediation; the D-129 addendum makes the one
  non-rusty-kaspa citation rev-scoped.
- **INV-10:** **HELD** for the value floor — the five-site sweep is complete and
  I verified each site individually. The single residual INV-10 exposure is the
  finding above: two documents state a superseded law.
- **D-019 (stag hunt):** **HELD at the normative sites.** The grief-by-delay price
  is now a parameter-space property, not a preset property — the binding condition
  is `R`- and cap-invariant and the ruled `β = 5 %` clears it across law S's whole
  `φ ∈ [0.5 %, 2 %]` band. The finding above is that one artifact has not yet been
  told.
- **INV-5 / mass:** not implicated (no transaction construction in this diff).

**Disposition: merge unblocked.** Two one-line edits should land in the same wrap
— they are the tail of the very CONCERNS this sitting cleared, and leaving them
means P3.1 inherits a refusal law that disagrees with the ruling it implements.
Re-pin `STATES.md`'s row after the edit.

**Proposed checklist addition (destination: `LESSONS.md` → this checklist):**
*Sweep a corrected law by its **symbol**, not by its section. C6's value-floor
remediation was swept by grepping `BOND_CAPITAL` and reached all five sites,
including two nobody had listed. The law-B remediation was swept by section —
SPEC §3.1, architecture §8.6.1, the model — and missed the two artifacts that
state the law without living under those headings. A law's statement sites are
wherever its symbols appear; a section list is the builder's memory of where it
wrote, which is exactly the thing an audit exists not to trust.*

---
---

# Re-pin sitting — 2026-08-13 (product-audit run 1, fix wave)

**Date:** 2026-08-13 · **Auditor:** consensus-auditor (checklist C-items 8–16 +
19–23, skill as of the 2026-08-13 L83/L86/F16 amendment) · **Tier:** T3 wave, T1
for the covenant portion (still no `.sil`; items 13/14's compiled-artifact halves
remain deferred to P4, and this whole audit is void the day a `.sil` lands).

**AUDIT-SCOPE (restated verbatim):** `uncommitted working tree + index vs HEAD
(4be92e0)  ||  ops mirror: uncommitted record vs 34144c8`

The injected diff was **TRUNCATED** (2,537 lines > the 2,000-line cap). Per the
skill's own instruction the covenant portion of this verdict was written after
reading the files directly: `contracts/duel_ad/STATES.md` (the state-encoding
table and the surrounding value/terms blocks), `contracts/duel_ad/SPEC.md` (every
`bond` occurrence, §5.3's payout formulas), both vector files, and
`rust/covenant/tests/duel_ad_model.rs` (the constant block, the state and
terminal structs, the census assertions). `cargo test -p kaspaverse-covenant
--test duel_ad_model -- --nocapture` was re-run here, not quoted.

## Why this sitting exists

Two files pinned by the C6 sitting changed in this working tree — `STATES.md`
(F14) and `rust/covenant/tests/duel_ad_model.rs` (F16) — while the C6 pin table
was left untouched. By that table's own law (*"Any change to any pinned file
voids this audit"*) the C6 verdict was **void on disk**, and the repo was
carrying a contract audit whose hash table disagreed with the tree. That is
checklist item 23's failure mode at the audit-record level: a published figure
that drifts silently while the gate stays green.

## VERDICT: PASS (0 BLOCK · 0 CONCERNS) — the covenant portion; re-pinned

The C6 sitting's single open CONCERNS (law B's superseded `β ∈ [φ, α]` floor in
`STATES.md:100-101`) is **CLOSED**: the file now reads *"with `β` bounded below by
the condition that its own term binds — `β·stake/5 ≥ 10·FEE_MOVE_CAP` (SPEC.md
§3.1; a numeric `β ≥ φ` floor would leave the sub-range `[φ, 2.17φ)` inert …)"*,
which is the fix that sitting prescribed, verbatim in substance.

**Re-pinned to (sha256, working tree at this sitting) — THIS IS THE LIVE TABLE:**

| File | sha256 | vs the C6 pin |
|:--|:--|:--|
| `SPEC.md` | `f5be33f18fd74c0b1eb1ebaf54cf3fc3be48dd4a52be3b45e5247746e8aad476` | **unchanged** |
| `STATES.md` | `639cac16e27d1375ad8519c63749a4f687bea0fa8445a74d0d48f4522a38d22b` | changed — F14's `bond_a`/`bond_b` retype, plus the C6 law-B remediation |
| `vectors/positive.json` | `83ae497e53065874de8ac6c7c9ee2299c5981b4f6d4a76ca3bad65b4b975ff25` | **unchanged** |
| `vectors/negative.json` | `b257717f430faa997a6b63b2523438543d9b4e4e47d7255ae0f5ea7576ffbb9e` | **unchanged** |
| `vectors/README.md` | `ff34acde6ce2b056b8b90be211c2b1ddabfcc8c955b4800cef0c62cc97327fe0` | **unchanged** |
| `rust/covenant/tests/duel_ad_model.rs` | `d8bc450275ccb90e3899d3b82f6ee388605cff831d4dfd3cb80fae135fb7b776` | changed — F16's three census assertions |

Any change to any pinned file voids this audit.

## F14 — `bond_a`/`bond_b` retyped `u64 · sompi` → `u8 · slices`. PASS.

Verified against all three arbiters independently, not against the brief:

| Arbiter | Says | Read at |
|:--|:--|:--|
| the model (STATES.md's own named arbiter) | `bond_a: u8` / `bond_b: u8` on both the state and terminal structs; `const BOND_SLICES: u8 = 5`; decrement is `n.bond_a -= 1` (a slice, not a sompi amount) | `duel_ad_model.rs:96, 274-275, 349-350, 478-479` |
| `SPEC.md` §5.3 | `+ bond(p) · b` and `+ (BOND_SLICES − bond(p.other())) · b` — the multiplication by `b` only typechecks if `bond()` is a count | `SPEC.md:485-486, 500` |
| the committed vectors | `"bond_a": 5` | `vectors/positive.json` (every genesis row) |

STATES.md was the sole outlier and is now consistent. **Checked for collateral
drift, which is where a retype usually leaves a hole:** STATES.md carries no
state-encoding byte-budget table, so nothing was sized off the old `u64` width
and nothing else needs following. The retype is complete at one line, and the
row now says *count, not sompi* in the text as well as the type column — which is
checklist item 22's rule (*name what the quantity is a count OF*) applied to a
field that was carrying two different units in two different documents.

No rule moved: no exit changed, no payout changed, no witness surface changed,
no bound changed. Items 8/9/10/11/12/15/16 are unmoved by a units correction to
a table that the executable arbiter always had right.

## F16 — the published census is now asserted, not printed. PASS.

**Re-run here:** `cargo test -p kaspaverse-covenant --test duel_ad_model --
--nocapture` → **5 passed, 0 failed**, 2.52 s, printing
`duel_ad model: 31098 reachable states, 432 distinct terminals` and
`P1 worst sole exit: 3 windows, 7 transitions (bound 4)`.

The three new constants match every document that publishes them — checked at
each site rather than assumed: `SPEC.md:94, 735`; `STATES.md:10, 13`; this file
`:48, 208`; `SOURCE_OF_TRUTH.md:337`; `P3_covenant_engine_ACTIVE.md:31`;
`COVENANT_PASS.md:102, 477, 546`; `COMPLETION_HISTORY.md:2584, 2629, 2819, 2840`.

**Item 23's second half is the part that was easy to miss, and it was not
missed.** The pre-existing guard was `cost.0 <= EXIT_WINDOW_BOUND` with
`EXIT_WINDOW_BOUND = 4`, while the *published* worst case is 3 windows — so a
genuine INV-6 degradation from 3 to 4 windows would have passed **green by
construction**. The fix pins the measured pair `WORST_SOLE_EXIT = (3, 7)` with
`assert_eq!` *beneath* the ceiling rather than replacing it, so the per-state
guard and the census claim are now two separate checks doing two separate jobs.
That is the correct shape.

Likewise `assert!(n_reach > 1_000)` → `assert_eq!(n_reach, N_REACHABLE)`: the old
form was a liveness check on the walker, not a census check, and would have
admitted a model that lost 30,000 states.

**One residual, recorded not blocking — the same drift class, one figure over.**
The *property count* is published inconsistently and is still unasserted: the
model's own header enumerates P1, P1f, P2 … P12 (twelve bodies), while
`COMPLETION_HISTORY.md:2584` and `COVENANT_PASS.md:102, 477` say **"11
properties"** and `P3_covenant_engine_ACTIVE.md:31` and `COVENANT_PASS.md:580`
say **"twelve"**. Two documents cannot both be right. F16 killed this failure
mode for the three numeric census figures; the property count is the fourth
published figure and it escaped the sweep. Minimal fix: pick the true count, fix
the two wrong sites, and — since the model has no natural place to assert it —
say plainly in the header how many properties the test enforces so a reader can
count them against the list. Not a fund-safety item; a record-integrity one.

## INV citations (this sitting)

- **INV-6:** **HELD**, and now better defended than at C6 — the worst sole exit
  is pinned at its measured value instead of only under a looser ceiling.
- **INV-9:** **HELD.** No protocol claim moved. No consensus logic was
  re-implemented or remembered in either change; F14 is a units correction to
  prose and F16 adds three assertions over already-computed values.
- **INV-10:** **HELD**, and this sitting is the reason: three figures that four
  documents publish were, until this wave, provable only by reading a `println!`.
- **INV-5 / mass:** not implicated (no transaction construction in this diff).
- **D-019 (stag hunt):** unmoved — no payoff, bond, window or terms-sheet law
  changed. F14 corrects how one field's unit is *described*, not what it is.

**Disposition: the covenant portion of this wave is unblocked.** The wave's
non-covenant findings (F3's provenance surface and the F2 deferral) are reported
in the session verdict, not here — they touch no contract artifact.
