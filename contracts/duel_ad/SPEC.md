# duel_ad — SPEC: Attack & Defend, formally (COVENANT C3, D-120/D-121)

> **Status:** design law, ratified at C3 (2026-08-03). No `.sil` exists; the
> compiled template is P4's, the codegen path is C5's (DP-11), and the cost
> constants are C4's (DP-7). What is fixed here: the state machine, its exit
> proofs, the four rulings C3 owned, and the vocabulary every later artifact
> must use. The machine itself is **executable law**:
> `rust/covenant/tests/duel_ad_model.rs` (DP-12) enumerates it exhaustively and
> the gate re-proves it on every run.
>
> **Evidence tiers** (pass law, `COVENANT_PASS.md §1`): `[pin]` = rusty-kaspa
> `cfafeb4c` (= v2.0.1) with `path:line`, **read this sitting** where marked;
> `[chess]` = `argent-playground` branch `chess` @ `115f29a`, carried from
> D-116/D-117's ratified reads; `[ship]` = this repo; `[spine]` = our record.
>
> **Consumed by:** P4 (the `.sil`, against this spec and these vectors) ·
> C4 (the transaction count §5.5, the idiom choice §6, DP-8's lineage
> questions) · C5 (the codegen comparison runs on THIS machine) · P3.1 (the
> seam extension §3.3; the custody build-list already planted) · the wager
> confirm sheet (§8's promise map rows).

---

## §0 The rulings, stated first

1. **A-3 — the wedge is single-covenant AND single-template** (§2). The
   session key owns nothing: it is a state-registered authenticator, so there
   is no allowance to constrain and no second covenant. All entrypoints fit
   one template dispatching on derived phase.
2. **OQ-8 — the relative idiom, uniformly** (§6). Every clock in the machine
   measures silence since the last transition — which *is* input age. Both
   halves of the enforcement chain are now verified at the pin (the gap
   chess's clause 4 left open). This supersedes `pvp §6`'s absolute-DAA
   standardization; both facts that motivated it have moved.
3. **OQ-9 protocol half — joint genesis; D-029 stands** (§3). Sequential join
   would trade a typed, additive seam extension for a new on-chain state with
   its own INV-6 proof and a contested-singleton window — and re-open a
   ratified decision. Refused on that trade.
4. **A-6 — identity-bound commit-reveal is sufficient hiding** (§4.7). The
   last revealer's only power is paying a bond slice for a strictly worse
   outcome; validated, closed.
5. **OQ-10 — discharged for the wedge by A-3** (§2.1); the general
   multi-template ruling stays armed on its existing trigger.
6. **The claims restructure** (§4.3): every value-moving stall branch is a
   beneficiary-signed **timeout claim** requiring the claimant's own act in
   state (**standing**); the two mutual-stall rows of `pvp §6` are deleted;
   the **dead-man statute stays permissionless** (§4.4) — reconciling the
   D-117 correction with C2's ratified partition, and converging on chess's
   own signature discipline from the opposite direction.

Machine verdict (DP-12, gate-reproved): **31,098 reachable states · every
property of §7 held · worst-case sole exit 3 windows + 7 transactions.**

---

## §1 The game (settled upstream, cited not restated)

Rules, equilibrium, fairness floor: `pvp_game_theory.md §1–§2` (D-029-audited,
re-verified D-057). Ten regulation rounds, strict role alternation
(a-attacks-odd, fixed in the terms sheet — symmetric 5/5), three zones,
commit-reveal per round (D-059 tier 1: A&D is a plaintext game), sudden death
in atomically-evaluated pairs, concession counters, standing reveal bonds,
score-aware dead-man. This spec formalizes that design; where it amends it,
§5.4 lists every deletion with its reason.

## §2 Architecture — one covenant, one template (A-3 ruled)

One covenant UTXO carries the whole match: stakes + bonds + fee buffer in,
state overwritten in place per transition (`pvp §3`'s baseline, Sutton
pattern). **A-3 is confirmed on both axes:**

- **Single-covenant.** `pvp §5`'s allowance covenant existed to constrain a
  session key that *owned fee money*. Under §5's fee architecture the session
  key owns **nothing**: moves are fee'd from the covenant's internal buffer,
  so a move transaction is `[covenant in] → [successor out]` with no session
  UTXO anywhere. A key that holds no value needs no spend constraint — the
  allowance question dissolves rather than resolves. What remains of `pvp §5`
  is the key's real role: the identity anchor in commitments and the
  prompt-free signing arm (§4.2). No micro-UTXOs, no consolidation sweep, no
  second covenant, no second genesis output (`GenesisRequest`'s singular
  `template` fits as shipped).
- **Single-template.** A&D has no per-piece dispatch — the heaviest
  transition (the resolving reveal: one Blake2b over 108 B, score arithmetic,
  the elimination comparison) is far below chess's per-worker complexity, and
  chess's largest compiled script is 3,510 B `[chess]` with every template
  clearing the budget with room to spare (`covenant_design_patterns.md §7`).
  One template dispatches on derived phase exactly as chess's `Mux` dispatches
  its own entrypoints. **No MUX split exists, so every transition is one
  transaction** — machine-asserted (`every_transition_is_one_transaction`),
  which fires `pvp §3`'s D-117 trigger *green*: §10's buffer sizing at the
  transition count IS the transaction count. The TX2-determined law
  (`covenant_custody.md §1.2`) is vacuously satisfied and inherited by any
  future split.

### 2.1 OQ-10 — discharged for the wedge, armed in general

Every successor in this machine is the same template, so the shipped
`SuccessorExpectation` (no `TemplateId` — `rust/covenant/src/seam.rs:287-309`
`[ship]`) describes the wedge completely. **No seam change lands at P3.1 for
OQ-10.** The general ruling — a `TemplateId` on the expectation vs a
family-scoped implementation vs a decode-recipe lookup — is deliberately NOT
pre-ruled without a driving contract (INV-12): it stays armed on OQ-10's
existing trigger (*any contract package declares a second template*), and
C2's family-scoped package format (`covenant_custody.md §1.6`) already keeps
the registry shape ready for whichever shape wins.

## §3 Genesis — joint, byte-identical, co-signed (OQ-9 protocol half ruled)

**D-029 stands: ONE atomic transaction, both stakes + both bonds + the
buffer, both players' funding inputs, both wallet signatures.** Each side
plans the complete transaction **independently and deterministically from the
terms sheet**, verifies **byte-equality** against the counterparty's plan over
the shipped P2 transport, signs only its own funding inputs (`SIG_HASH_ALL` —
the D-115 law), releases the signature as a **genesis offer**
(`covenant_custody.md §3.2` lifecycle, offer expiry on the terms sheet),
and either side broadcasts. The covenant id derives from the authorizing
outpoint + ordered initial outputs (`consensus/core/src/hashing/covenant_id.rs:16-30`
`[pin]`, carried from C1) — the terms sheet fixes the authorizing outpoint, so
both plans derive the same id.

**Why not sequential join** (the register's alternative, ruled against on the
trade OQ-9 stated): a half-funded on-chain state needs its own timeout branch
and INV-6 proof (a new state, new vector rows, a second genesis-shaped
transaction); it opens a **contested-singleton window** — B's join racing A's
cancel on the same UTXO is an auction we would be hosting
(`pvp §0.6.4`), and the join-wins outcome traps A in a match A tried to leave;
and it re-opens a ratified decision (D-029) for the convenience of not
extending the seam. The seam extension is the smaller, typed, auditable cost.

### 3.1 Registered at genesis — and the terms-validity law

Per player: `payout_pk` (wallet-derived; its standard P2PK SPK is the payout
address — the §1.4 payout-address rule holds by construction, and the same key
is every signed row's wallet arm) · `session_pk` (transient authenticator).
Match constants: stakes, `b`, windows, `FEE_FIXED`, `FEE_MOVE_CAP`, the role
convention. All of it is terms-sheet material (class 2) landing on chain at
genesis.

**The terms-validity law** *(consensus-auditor C3, finding 1)*: negotiable
terms are bounded, and out-of-range terms are **refused at genesis planning
and at the first-party confirm** — the same refusal layer that pins payout
addresses. Binding bounds: **`W_commit, W_reveal ∈ [600, 6000]` DAA** (the
Blitz floor, `pvp §6`; the Relaxed ceiling, new here). The ceiling is what
keeps §9's stall-to-the-statute row true for *every* admissible terms sheet:
a full claims exit (≤ 3 windows = 18,000 DAA at the ceiling) matures inside
half the 36,000-DAA statute, so a leading staller can never reach
`dead_man_settle` before an awake victim's claims. Without the ceiling that
defense is parameter-conditional — a consented `W ≥ 36,000` terms sheet would
invert it. Machine-asserted:
`the_terms_validity_law_bounds_every_window`.

### 3.2 What never exists

No half-funded on-chain state (atomicity), no pre-genesis covenant state to
model (INV-6's on-chain guarantee begins at genesis — Law 1's boundary,
`covenant_custody.md §2.1`), no co-signing ceremony on any later row (the
corollary: genesis is the only two-signature transaction in the family's
life).

### 3.3 The seam extension this ruling routes to P3.1 (T3)

The seam cannot yet name a key we do not hold (D-114's gap, OQ-9). Additive,
behind the ratified plan-granularity: a **foreign-key role** —
`KeyRole::CounterpartyWallet(ScriptPublicKey)`-shaped — whose slot **core
refuses to fill** (it is not ours to sign); the exchange layer fills it with
the counterparty's released signature bytes after byte-equality verification.
Tier **T3** (seam surface: ffi-leak + wallet-security + consensus +
dependency-steward per the router table). P3.1 implements; nothing in this
contract waits on it before then.

## §4 The machine

The row table is `STATES.md`; the walker is the arbiter. This section is the
law behind the rows.

### 4.1 Moves never wait; windows open claims

Every move row (`commit`, `reveal`, `resign`) is `Unlock::Now` from its
state's birth. Every timed row is a **lower bound** that *opens a remedy* —
nothing expires, nothing closes (both idioms are lower bounds,
`covenant_custody.md §6`; the race between a late move and a standing claim
is A-10's shape, resolved by DAG ordering, both outcomes legitimate).

### 4.2 One authentication rule — the dual arm

Every signed row verifies the actor against **session_pk OR payout_pk**. The
session arm is the prompt-free UX (`pvp §5`'s purpose, kept); the wallet arm
is Law 1's guarantee and the total-loss fallback: a client that lost its
session key plays on with per-move biometrics — degraded, never stranded.
This dissolves the rekey entrypoint (C2's §1.5(a) option (iii) — an extra
state-machine row bought nothing the dual arm doesn't give), and C2's
recommended option **(ii)** (session key persisted at class-3 rank in the
match custody store) is adopted as the custody posture, making the fallback
rare. Both C2 prices honoured, no hidden liveness cost, background-lock law
exceptionless.

**Sighash, named per row** *(consensus-auditor C3, finding 2)*: every signed
row's signature — either arm — is **`SIG_HASH_ALL`** under the D-115
fill-site law (`SignatureSlot`, `rust/covenant/src/seam.rs:258-270`); **no
`D-` exception exists for this contract.** The gating claims of this section
and §5.2 are true *because* of it: under any looser type the signature stops
committing to the successor outputs, and a mempool observer could rebind a
broadcast commit's successor to a commitment whose preimage the observer
knows (every identity field is public state).

### 4.3 Timeout claims — beneficiary-signed, standing-gated

The corrected `pvp §3` (D-117) requires per-row classification: branches that
merely advance may be permissionless; branches that concede a round, slice a
bond, or end the match transfer value on an unprovable absence and carry the
beneficiary's signature. Applied, the stall surface collapses to **two rows**:

- `claim_commit_timeout` — the counterparty never committed; claimant's own
  commitment is in state.
- `claim_reveal_timeout` — the counterparty never revealed; claimant's own
  reveal is in state (slice `b` from the conceder's bond, paid to the
  claimant in the same transition; empty bond ⇒ the offense forfeits).

**Standing** — the claimant's own act recorded in state — is what the state
*can* prove: "I acted; the window since has elapsed; my counterparty's slot
is empty." The absence itself stays unprovable, which is exactly why the row
carries the signature of the only party entitled to waive waiting (chess's
`Mux.timeout` discipline `[chess]`, reached here from the opposite direction:
we derived it from the D-117 rule, then found the reference already obeying
it). A claim's resolution scores the round at the claimant's optimum, runs
the conceder's counter (+1; the third settles inline), and breaks the
claimant's own chain.

### 4.4 The dead-man statute — permissionless, deliberately

`dead_man_settle` is `Anyone · Crank · AfterInputAge(36000) · no material`,
from **every** live state, settling at the standing score (leader takes the
pot; a tie refunds stakes; remainders return). It is D-119's set (a), ratified
at C2, and this spec keeps it against the grain of §4.3 for stated reasons:

- **It transfers value on no one's claim.** The parties agreed at genesis
  that match-wide silence for the statute ends the match *at the score* — an
  expiry both consented to, not an award on an asserted fault. A tie pays
  nobody; there is no beneficiary to gate on. The permissionless law's test
  ("does any party retain a choice they are entitled to make?") answers no:
  any party wanting a different outcome had 36,000 DAA — 6× the most relaxed
  window — in which *any* transition of theirs would have re-armed the clock.
- **C2's headline depends on it.** "The backup ceremony does not grow" is
  guaranteed by settlement converging to seed-derived addresses *without
  us* (`covenant_custody.md §0.1`). A signed dead-man would strand a mutually
  abandoned pot until a claimant returned — chess's actual posture, which our
  custody ruling deliberately refused.
- **It cannot rob an awake player.** The concession path pays a present
  player the full pot in ≤ 3 windows (≤ 1,800 DAA at Blitz) — twenty times
  inside the statute. A player asleep for the whole hour of a live match is
  the case the confirm sheet prices in plain words (promise sentence 2,
  `covenant_custody.md §5.3`). The model's P1 bound is the proof.

### 4.5 Reveals are signature-free (the row-9 ruling)

The stored commitment admits exactly one `(zone, salt)` under the revealer's
state-bound identity fields (`domain ‖ covenant_id ‖ round ‖ role ‖
session_pk ‖ zone ‖ salt`, all fixed-width — `pvp §4` unchanged), so
possession is the authentication and the transition is **preimage-gated**:
signature-free but *not* determined (the preimage is class-3 material until
disclosed — the lexicon's new row). Consequences, all intended: salt recovery
and session-key recovery decouple (`covenant_custody.md §1.3` row 9); a
mempool observer can at most rebroadcast the identical outcome (§5.2's exact
draw makes the transaction unique); identity binding kills copying
(`pvp §4`, A-6 below). Law 2 binds the other side of the same coin: no commit
broadcasts before its salt's persist receipt (`covenant_custody.md §2.2`).

### 4.6 Settlement is inline

Whatever transition makes the match decided — the resolving reveal, the
third-concession or empty-bond claim, the resign, the dead-man — **is** the
settlement: pot, bond remainders and buffer split pay in that same
transaction (plan successor `None`), output layout pinned by introspection to
genesis-registered payout SPKs. A separate settleable state would add a
state, a transaction and a liveness question per match and answer nothing.

### 4.7 A-6 ruled — the last-revealer question (D-059 re-checked)

The second revealer learns the round's outcome before choosing to reveal —
and can do nothing with it: the move is locked (hash-bound), so the only
"option" is *not revealing*, which costs the round at the opponent's optimum
**plus** a bond slice — strictly worse than revealing a loss (`pvp §9` row 2,
the reason bonds exist). Copying is dead by identity binding; cross-round and
cross-match replay die on the bound `round`/`covenant_id` fields; sudden
death's sequential pressure is already neutralized by atomic pair evaluation
(`pvp §8.4` — the equilibrium is state-independent). Commit-reveal with
identity binding and reveal bonds is sufficient hiding for A&D's simultaneous
rounds. **A-6: validated, closed.** (D-059's rubric placement — tier 1,
plaintext game — unchanged.)

## §5 Value rules

### 5.1 The buffer pays; the floor protects

The covenant carries a fee buffer from genesis (`pvp §10`), and — one
deliberate widening of §10's design — **it funds moves as well as claims and
cranks**: every transition may draw its fee from the covenant's own value, so
*no row ever requires external liquidity*. An exit that needs a funding input
is an exit that needs you to have money outside the match; the buffer deletes
that dependency for every player and every stranger cranking the statute.
The script enforces per transition:

- `value_out ≥ value_in − DRAW_CAP(row)` and
- `value_out ≥ stakes + bond_a + bond_b` (**the value floor** — fees can
  never eat entitlements; bonds/stakes leave only through §5.3's tables).

Buffer remaining is *derived* (`value − floor`), never stored. If the buffer
runs dry, transitions remain takeable with externally-funded fees (the draw
becomes 0 and a funder's input/change ride along — the script constrains the
covenant's value flow and payout outputs, not the transaction's other lanes).
C4 sizes the buffer against §5.5's counts so exhaustion is a
theoretical tail, not a plan.

### 5.2 Draw rules per row class

- **Signed rows** (commits, claims, resign): the signer chooses the draw in
  `[0, FEE_MOVE_CAP]` — the signature gates abuse; the cap and floor bound it.
- **Signature-free rows** (reveals, dead-man): the draw is **exactly
  `FEE_FIXED`** (or exactly 0 when externally funded). A variable draw on an
  unsigned row would let any observer re-broadcast the same transition with a
  larger draw as an RBF-winning grief (`pvp §0.6.4`'s auction, fed by the
  match's own buffer). Exact draw ⇒ the honest transaction is unique ⇒
  nothing to outbid with our money. This is the determinism discipline of the
  TX2-determined law applied to fees.

### 5.3 Terminal payout tables (all introspection-pinned)

| Cause | Pot (2 × stake) | Bonds | Buffer remainder |
|:--|:--|:--|:--|
| Elimination / Regulation / SdPair | winner | remainders to owners | split 50/50, odd sompi to fee |
| CounterForfeit / BondForfeit | claimant | remainders to owners | split |
| Resign | the opponent | remainders to owners | split |
| DeadMan, leader | leader | remainders to owners | split |
| DeadMan, tied | stakes refunded each | remainders to owners | split |

Slices moved at claim time (one output per reveal-claim, to the claimant's
payout SPK) — the model asserts local conservation per edge, which composes
to global (P7).

### 5.4 Amendments to `pvp §6`/`§8`, enumerated

Deletions the formalization forced, each with its reason — `pvp` v2.5's delta
note points here; the theory doc remains authoritative for the game theory:

1. **Both-stall rows (commit and reveal) deleted.** A claim now requires
   standing, so a state where nobody acted offers no claim. The mutual rows
   were the only source of simultaneous counter increments and of
   value-moving *determined* stall branches — the exact class the D-117
   correction flagged. Their job (mutual abandonment) is the statute's.
   Machine-checked: `no_claim_exists_without_standing`, and the
   at-most-one-nonzero-counter invariant (P5) — which also makes `pvp §6`'s
   mutual-forfeit-at-(3,3) rule **vacant** rather than wrong.
2. **`last_update_daa_score` deleted from the state table** — the relative
   idiom reads the anchor from the UTXO entry itself (§6); a stored copy is
   a redundant second source of truth.
3. **Slice-to-crank-fee cases deleted** with the mutual rows — every slice
   now pays the standing claimant.
4. **Resign added** (one row): the honest instant quit. Same terminal value
   as decay-forfeit (pot to opponent, bond remainders keep), strictly faster
   for both sides, trivially dominated as an attack (it pays the opponent).
5. **Settlement inlined** (§4.6) — no separate settle transaction.

### 5.5 Handed to C4 (DP-7's inputs, from the machine)

Transitions **= transactions, 1:1, machine-asserted**. Genesis 1 (co-signed,
2+ funding inputs) · full regulation 40 + genesis = 41 · expected ≈ 46
(11.2 rounds, `pvp §2`) · every claim replaces the two transitions it
forecloses · reveal-claims add one slice output · the statute is 1. Idiom:
relative only — no dual-idiom cost row needed (C2 §6's both-idioms pricing
question does not arise). Bond slice `b` must clear the §10 rule
(`b ≥ 10× fee`) *and* KIP-9 storage mass as a small standalone output — C4
prices both, plus `FEE_FIXED`/`FEE_MOVE_CAP`/buffer size at real mass numbers.

## §6 The timeout idiom — OQ-8 ruled at the pin

**Ruling: the relative idiom (input age), uniformly, every timed row.**
`Unlock::AfterInputAge(W)` at the seam; `sequence = W` on the claim input;
`OpCheckSequenceVerify` in the script. Grounds:

1. **Semantic identity.** Every clock in this machine — both windows and the
   statute — measures *elapsed silence since the last transition*, and the
   current state UTXO's age is that quantity, by definition of a UTXO state
   machine. The absolute encoding would compute the same predicate with two
   opcodes and a lock_time the builder must set; the relative one reads it
   natively.
2. **The enforcement chain is verified at the pin — both halves, re-read this
   sitting** `[pin]`, extending `toccata_protocol.md §14` C8's existing
   consensus cite (D-110) with the call-site and domain analysis:
   - *Consensus:* `check_sequence_lock` —
     `consensus/src/processes/transaction_validator/tx_validation_in_utxo_context.rs:136-155`,
     called **unconditionally for every validation-flags variant** at `:53`
     (Full, SkipScriptChecks, SkipMassCheck alike) — rejects any transaction
     whose input is younger (in DAA) than its
     `sequence & SEQUENCE_LOCK_TIME_MASK`.
   - *Script:* `OpCheckSequenceVerify` fails when `stack_sequence >
     input.sequence` and refuses the disabled-bit bypass
     (`crypto/txscript/src/opcodes/mod.rs`, the `UnsatisfiedLockTime` arms).
   - *Domain:* the mask is 32 bits of DAA
     (`consensus/core/src/constants.rs:47,52`) ≈ 13.6 years — every window
     fits with five orders of magnitude to spare.
   **Honest scope (L79's shape — constrain, then claim):** this is
   source-level verification. D-116's clause-4 gap — no *executed* rejection
   of a premature claim exists anywhere yet (chess's tests are all positive) —
   is not closed by reading the rule; it is **pinned as a standing
   obligation**: the committed premature-claim vectors
   (`vectors/negative.json`, both layers) fail the P4 parity harness until it
   demonstrates the rejection against the pinned validator itself.
3. **No state needs the absolute idiom.** Its one exclusive capability — a
   horizon that survives transitions (`covenant_custody.md §6`'s asymmetry) —
   is a whole-match deadline this design deliberately does not have (matches
   end by play, forfeit, resign, or the statute; a hard horizon would hand a
   leader a stall-to-the-buzzer strategy). The seam keeps `AtDaaScore`
   expressible for future rungs (C1 §2.6); no dual-idiom cost lands on C4.
4. **Production congruence.** Chess is exclusively relative — nine `this.age`
   guards, per-game windows `[chess]` (OQ-8's D-116 datapoint) — and the
   primary codegen path's ergonomic primitive lowers to exactly this opcode
   (`silverscript_reference.md §4.5`), so C5 inherits alignment instead of a
   fight.

**This supersedes `pvp §6`'s standardization on absolute DAA introspection,
and says so.** Both facts that motivated that standing choice have moved:
the pinned Generator whose hardcoded `sequence = 0` made CSV unsatisfiable is
**excluded from the covenant path** since D-114 (implementations emit v1 with
`sequence` first-class, plan-frozen — `rust/covenant/src/seam.rs` `[ship]`),
and the consensus half, unverified when §6 declined CSV, is verified above.
`pvp §6` carries the pointer; C5's codegen half of OQ-8 (`toccata §14` C8)
stays armed only for confirming the chosen path *sets* the field.

## §7 The model (DP-12 ruled) — properties and verdicts

**Tool ruling: an in-tree Rust walker, not TLA+** — decided on the prompt's
criterion (what the consensus-auditor and the founder can *read*): the
auditor reads Rust daily and TLA+ never; the founder's proof surface is
`tools/gate.sh`, which re-runs the walker on every gate forever (a TLC run is
a pasted transcript); it adds zero packages (std only, INV-7); and its
frontier emits the DP-9 vectors directly. The walker types its rows in the
seam's own enums — the machine is *provably expressible* in the ratified
vocabulary (`Unlock`/`Taker`/`EntrypointClass`).

Properties, all asserted per reachable state
(`rust/covenant/tests/duel_ad_model.rs`; run output in COMPLETION_HISTORY):

| # | Property | Verdict |
|:--|:--|:--|
| P1 | bounded sole exit: each player alone (opponent absent, resign excluded) reaches a terminal | **held — worst case 3 windows + 7 transactions** |
| P1f | pure abandonment pays the standing player (claims path ends in their forfeit win) | held on every qualifying state |
| P2 | Law 1 per row: no exit/crank needs class-3 material or a counterparty signature; signed rows carry the wallet arm | held (the machine-checked half of `covenant_custody.md §2.1`) |
| P3 | no reachable deadlock | held |
| P4 | abandonment converges by Anyone edges alone (the statute, determined, from every state) | held — C2 §0.1's headline, machine-checked |
| P5 | counters never stored at 3; **at most one nonzero** | held — the claims restructure's invariant |
| P6 | bonds in [0,5]; only reveal-claims slice; empty bond ⇒ forfeit | held |
| P7 | value conservation: slices at claim time, terminals pay pot + remainders exactly | held (local per edge ⇒ global) |
| P8 | sudden death quotient sound; decisive pair reachable; P1/P4 hold inside | held |
| P9 | every Anyone row determined (single successor); the reveal's branch is epistemic only | held |
| P11 | every claim strictly worsens the conceder; every move was `Now`-enabled first | held |
| — | census: 31,098 reachable states, 432 distinct terminals; all 7 terminal causes reachable | held |

Honest scope notes: the walker proves the **protocol layer** exhaustively;
the game layer's termination-with-probability-1 (sudden death's geometric
tail) is analytic (`pvp §2`'s table; `pvp §8` point 5) and cited, not enumerated — the quotient
proves the loop's every iteration passes through claimable, statute-covered
states, which is the INV-6-relevant half. Chance at the resolving reveal is
branched adversarially (both outcomes explored).

## §8 The promise map (`pvp §0.6.2`'s audit rule, mandatory)

Every promise the surface makes, with its enforcer — **at spec stage the
enforcement level is what P4 must make true**; a row is Level 4 only once the
compiled script exists and the vectors bind it. Labeled honestly:

| Promise to the player | Enforcer (named) | Level now → at P4 |
|:--|:--|:--|
| Your stake moves only by match rules | covenant script + KIP-20 lineage (creation-time rejection) | design → 4 |
| Payouts reach only genesis-registered, wallet-derived addresses | output introspection (`OpTxOutputSpk`/`Amount`) + §1.4 plan/confirm refusals | design → 4 |
| Your pick is secret until both are locked | Blake2b commitment, 256-bit salt (`pvp §4`) | 4 (cryptographic) |
| Your commitment cannot be copied or replayed | identity-bound preimage (covenant_id ‖ round ‖ role ‖ session_pk) | design → 4 |
| Stalling costs the staller (bond + concession) | claim rows + bond slices; strict dominance (§9) | design → 4 |
| You can always leave alone, boundedly | P1's machine-checked bound (3 windows + 7 tx); claims wallet-arm-satisfiable | design → 4 |
| An abandoned match settles without anyone | the statute (P4 property) + payout-address rule | design → 4 |
| Leaving mid-match loses at most stake + bond | value floor + payout tables; the confirm sheet says it in words | design → 4 (copy: T0, ux-auditor) |
| The house takes nothing | there is no house key in any row (grep the material column) | 4 by construction |
| Session-key theft costs at most this match | the key authorizes moves only; payouts pinned to wallet keys; no rekey needed (dual arm) | design → 4 |

## §9 The stag-hunt table (D-019; `pvp §9` extended per state)

`pvp §9`'s ten rows survive unchanged and now carry machine-checked
counterparts where the protocol layer is involved. New rows from this spec's
structures. "Dominated" = strictly, per D-019; consensus-auditor item 15
reads this table.

| Deviation (state family) | What happens | Why honesty dominates | Checked by |
|:--|:--|:--|:--|
| Stall at commit (C_you) | opponent claims after W: round at their optimum, your counter +1 → forfeit at 3 | acting is free, `Now`-enabled, and weakly better in-round; the counter makes indifference strictly losing | P11 + `pvp §9` row 1 |
| Stall at reveal (R_opp) | as above **plus** a bond slice to the claimant | revealing a lost round costs the round; stalling costs the round + `b` | P11, P6 + `pvp §9` row 2 |
| Copy the opponent's commitment | reveal can never verify (identity-bound) → decays to a reveal stall | the v1-fatal exploit stays dead; attempting donates `b` | negative vectors (`reveal_wrong_preimage`, `commit_duplicate_hash`) |
| Replay old commitments (any round/match) | hash binds round + covenant id | same decay | negative vectors |
| Claim without absence (opponent acted) | no such entrypoint; the slot-presence check refuses | claims need standing AND the counterparty's empty slot | `claim_when_opponent_acted` vector; standing rule |
| Premature claim | consensus rejects by sequence age; script rejects low sequence | windows are real at both layers | the two premature vectors + §6's pin cites |
| Vanish while losing | claims → CounterForfeit (3W) or the statute at score | you cannot annul a loss by leaving | P1f + `commit_stall_counter_forfeit` |
| Vanish while winning | the present player's claimed rounds resolve at *their* optimum: they score their attacks, your lead erodes, forfeit at 3 lands regardless of score | stalling never preserves a lead; forfeit ignores score | P1f (winner = claimant on every abandonment path) |
| Stall-to-the-statute while leading | a present opponent reaches forfeit in ≤ 3W ≤ 18,000 < 36,000; only a *mutually* absent match reaches the statute | the gambit requires the victim asleep for the whole statute — priced in promise sentence 2, not exploitable against an awake player. **True for every admissible terms sheet because of §3.1's terms-validity law** (the window ceiling) — not only the named controls | P1 bound × the ceiling assertion (`the_terms_validity_law_bounds_every_window`) |
| Grief the buffer (broadcast max-draw transitions) | signed rows: only you can sign yours; unsigned rows: exact draw, the transaction is unique | nothing variable to outbid with match money | §5.2's rule |
| Eternal mutual draw (both stall attacks forever in SD) | possible only by *both* players' continuous choice; either exits any time (play → decisive, stop → claimed, resign) | strictly dominated by the statute's tie refund (same outcome, minus fees and an hour) | quotient structure (P8) + analytic note |
| Resign as an attack | pays the opponent the pot | self-harm is not an attack | payout table |
| Mempool snooping / miner censorship / weak RNG | unchanged from `pvp §9` rows 8–10 | window floors price censorship; salts are CSPRNG; the coin-flip floor stands | `pvp §9` (protocol-external) |

Net: the dominant strategy remains indistinguishable from honest play, now
with the protocol-layer rows machine-checked instead of argued.

## §10 Custody hooks (C2's laws, bound into this contract)

- **Law 1** (`covenant_custody.md §2.1`): enforced here as the STATES.md
  material column + model P2 (both mandated enforcement sites, live). Every
  exit's witness: chain state + at most the actor's wallet-arm signature.
- **Law 2** (§2.2): the commit rows name the persist receipt; the salt is
  sealed to the match custody store before any commit broadcasts. P3.1
  builds the store + receipt with the three test shapes already written.
- **Session key custody**: option (ii) adopted (§4.2) — persisted at class-3
  rank for the match's life, wiped at settlement; the dual arm makes even
  its total loss non-stranding.
- **Foldability**: STATES.md's closing section; the model state IS the
  on-chain state, asserted by construction.
- **Set-(b) audit**: STATES.md's closing section — neither OQ-4 nor OQ-5
  re-arm trigger fires.

## §11 What this spec deliberately does not fix

Fee/bond/buffer *numbers* and storage-mass pricing (C4, DP-7 — §5.5 hands it
the counts) · reorg/tombstone semantics for the watcher (C4, DP-8) · the
codegen path and the `.sil` (C5 DP-11, P4) · template authenticity mechanics
(C4, DP-6) · the seam extension's implementation (P3.1, §3.3) · RPS
(`contracts/duel_rps/` will instantiate this machine's single-round
degenerate case at P4 — same rows, one round, no SD).

## §12 Provenance

| Source | Rev | Read for |
|:--|:--|:--|
| rusty-kaspa pin `[pin]` | `cfafeb4c` (= v2.0.1), **read directly this sitting** | `check_sequence_lock` (`tx_validation_in_utxo_context.rs:53,136-155`) · CSV semantics + disabled-bit rule (`crypto/txscript/src/opcodes/mod.rs`, `UnsatisfiedLockTime` arms) · `SEQUENCE_LOCK_TIME_MASK`/`DISABLED` (`consensus/core/src/constants.rs:47,52`) · `OpTxInputDaaScore` present (`opcodes/mod.rs:1282`) — noted, unused by the wedge |
| carried pin cites | from C1/C2 verified tables | covenant-id derivation (`hashing/covenant_id.rs:16-30`) · v1-necessity (A-4) · v1 txid excludes signature scripts |
| chess `[chess]` | `115f29a` (D-116/D-117 ratified reads; paths `chess/`-relative) | signature discipline (`Mux.timeout` signed; workers/settle free) · compiled sizes · exclusively-relative timeout shape |
| shipped `[ship]` | working tree at C3 | `rust/covenant/src/seam.rs` (Unlock/Taker/EntrypointClass/KeyRole/SuccessorExpectation) · `rust/covenant/tests/duel_ad_model.rs` (this spec's arbiter) |
| spine `[spine]` | this pass | `pvp_game_theory.md` §0.5/§0.6/§1–§10 (as corrected D-110/D-116/D-117) · `covenant_custody.md` (D-118/D-119, whole) · `covenant_design_patterns.md §7` · `covenant_engine_lexicon.md` · `COVENANT_PASS.md` registers · D-029 (`DECISION_LOG.md:368`) · D-115 sighash law |
