# duel_ad — STATES (COVENANT C3, D-120/D-121)

> The state machine's row table — the human rendering of the machine that
> `rust/covenant/tests/duel_ad_model.rs` enumerates and proves (31,098 reachable
> states; every property in `SPEC.md §7` held; worst-case sole exit **3 windows +
> 7 transactions**). The model is the arbiter: if this table and the model ever
> disagree, the model's committed vectors fail the gate and this table is wrong.
> Design law and rulings live in `SPEC.md`; this file is the table.
>
> **Idiom, ruled once (SPEC.md §6, OQ-8):** every timed row uses the **relative
> idiom** — `Unlock::AfterInputAge(W)`, lowered to `OpCheckSequenceVerify` with
> the consensus half `check_sequence_lock` — because every clock in this machine
> measures *elapsed silence since the last transition*, which **is** input age.
> The per-row reason column would repeat that sentence; it is stated here once.
> No row needs `Unlock::AtDaaScore`: the design has no whole-match horizon.
>
> **Authentication, ruled once (SPEC.md §4.2):** every signed row verifies
> against the actor's **session_pk OR payout_pk** (the wallet arm). "own sig"
> below always means that dual arm — no signed row depends on class-3 material
> (Law 1, `covenant_custody.md §2.1`), and a lost session key degrades UX,
> never function. **Every signature on every signed row is `SIG_HASH_ALL`**
> under the D-115 fill-site law; no `D-` exception exists for this contract
> (SPEC.md §4.2 — a looser type would stop committing to the successor).
>
> **Taker mapping:** rows are god-view (`actor` = A, B, or Anyone). The seam's
> perspectival `Taker` renders actor-me as `Me` and actor-other as
> `Counterparty` (`rust/covenant/src/seam.rs:116-135`).

## The state

Phase is **derived** from slot occupancy (zeroed = absent), per `pvp §8`.
Six live phase families exist; `Committing{a,b both present}` is
unrepresentable — the second commit's successor is already `Revealing`.

| Family | Meaning |
|:--|:--|
| **C∅** | committing; neither commitment present (every round's entry state) |
| **C_A / C_B** | committing; exactly A's / B's commitment present |
| **R∅** | both committed; no reveal present |
| **R_A / R_B** | exactly A's / B's reveal present (zone parked) |

### State layout (on-chain fields; script arithmetic is 64-bit, KIP-10)

| Field | Width | Notes |
|:--|:--|:--|
| `round` | u16 | 1-based; keeps counting in sudden death |
| `score_a` / `score_b` | u8 | strikes, per player |
| `conc_a` / `conc_b` | u8 | consecutive conceded rounds; **3 is never stored** — the third settles inline; at most one is nonzero (model-proved invariant) |
| `bond_a` / `bond_b` | u64 | remaining standing-bond sompi (5 slices of `b` at genesis) |
| `commit_a` / `commit_b` | 32 B | commitment hashes; zeroed = absent |
| `reveal_first_zone` | u8 | first reveal's zone, parked until resolution (0xFF = absent) |
| `revealed_a` / `revealed_b` | bool | who has revealed this round |
| `sd_delta_a` / `sd_delta_b` | u8 | within-pair strike deltas (sudden death only) |
| `is_sudden_death` | bool | switches §7 elimination off, pair evaluation on |
| `payout_pk_a` / `payout_pk_b` | 32 B | **dual duty**: settlement destination (standard P2PK SPK derives from it — the §1.4 payout-address rule) AND the wallet arm of every signed row |
| `session_pk_a` / `session_pk_b` | 32 B | commitment identity anchor (`pvp §4`) + the prompt-free signing arm |

**Deleted from `pvp §8`'s v2.2 table, with reasons (SPEC.md §5.4):**
`last_update_daa_score` — redundant under the relative idiom: the chain's own
UTXO entry carries the anchor (`accepted_daa`), and a stored copy would be a
second source of truth the script never needs.

**Constructor constants** (baked in the redeem script at genesis, from the
terms sheet): stakes, `b` (slice), `W_commit`, `W_reveal`, `W_deadman = 36000`,
`FEE_FIXED`, `FEE_MOVE_CAP`, the a-attacks-odd role convention.
**Terms-validity law (SPEC.md §3.1):** `W_commit, W_reveal ∈ [600, 6000]` DAA
— refused outside the bounds at genesis planning and confirm; the ceiling is
what makes the claims exit mature inside half the statute for every
admissible terms sheet (machine-asserted).

## The rows

Material classes per `covenant_custody.md §1` (DP-4). "resolve(…)" =
`SPEC.md §4.4`'s resolution: score at the claimant's optimum, counters
(conceder +1 → 3 settles inline; the other's chain breaks to 0), then
elimination / round-10 / pair evaluation — the successor is the next round's
C∅ **or a settlement**, decided inside the same transition.

### C∅ — committing, neither present

| Entrypoint | Actor | Class | Unlock | Material required | Successor |
|:--|:--|:--|:--|:--|:--|
| `commit_a` | A | Cooperative | Now | own sig · salt sealed first (Law 2 receipt) | C_A |
| `commit_b` | B | Cooperative | Now | own sig · Law 2 receipt | C_B |
| `resign_a` | A | Cooperative | Now | own sig | **settle**: pot → B, remainders per SPEC §5.3 |
| `resign_b` | B | Cooperative | Now | own sig | **settle**: pot → A |
| `dead_man_settle` | Anyone | Crank | AfterInputAge(36000) | none | **settle at score** (leader takes pot; tie refunds) |

*No claim rows: nobody has standing (SPEC.md §4.3 — the mutual-stall rows of
`pvp §6` are deliberately deleted; the dead-man is the only absence remedy
here).*

### C_A — A committed, B pending *(C_B is the mirror)*

| Entrypoint | Actor | Class | Unlock | Material required | Successor |
|:--|:--|:--|:--|:--|:--|
| `commit_b` | B | Cooperative | Now | own sig · Law 2 receipt · hash ≠ `commit_a` | R∅ |
| `claim_commit_timeout_a` | A | UnilateralExit | AfterInputAge(W_commit) | own sig — **wallet arm satisfies Law 1** | resolve(conceder = B) → next C∅ or settle |
| `resign_a` / `resign_b` | A / B | Cooperative | Now | own sig | settle |
| `dead_man_settle` | Anyone | Crank | AfterInputAge(36000) | none | settle at score |

*B's late commit stays valid after W_commit — windows are lower bounds that
open claims, never doors that close moves. A late move races the standing
claim on the same UTXO; DAG ordering resolves; both outcomes are legitimate
(A-10's race shape, `covenant_custody.md §6`).*

### R∅ — both committed, none revealed

| Entrypoint | Actor | Class | Unlock | Material required | Successor |
|:--|:--|:--|:--|:--|:--|
| `reveal_a` | Anyone *(preimage-gated)* | Cooperative | Now | A's commit preimage tuple — class 3, **a right, never an exit dependency** | R_A |
| `reveal_b` | Anyone *(preimage-gated)* | Cooperative | Now | B's preimage tuple | R_B |
| `resign_a` / `resign_b` | A / B | Cooperative | Now | own sig | settle |
| `dead_man_settle` | Anyone | Crank | AfterInputAge(36000) | none | settle at score |

*Reveals are signature-free (SPEC.md §4.5, the row-9 ruling): the stored
commitment admits exactly one preimage under the revealer's state-bound
identity fields, so possession is the authentication. A client that lost its
session key but kept its salt still reveals. No claim rows: neither player
has revealed, so neither has standing.*

### R_A — A revealed, B pending *(R_B is the mirror)*

| Entrypoint | Actor | Class | Unlock | Material required | Successor |
|:--|:--|:--|:--|:--|:--|
| `reveal_b` | Anyone *(preimage-gated)* | Cooperative | Now | B's preimage tuple | **resolution** → next C∅ or settle |
| `claim_reveal_timeout_a` | A | UnilateralExit | AfterInputAge(W_reveal) | own sig — wallet arm satisfies Law 1 | resolve(conceder = B, **slice `b` → A**; empty bond ⇒ forfeit settle) → next C∅ or settle |
| `resign_a` / `resign_b` | A / B | Cooperative | Now | own sig | settle |
| `dead_man_settle` | Anyone | Crank | AfterInputAge(36000) | none | settle at score |

### Genesis (row 0 — creates C∅ round 1; not a transition of the machine)

| Entrypoint | Actor | Class | Unlock | Material required | Successor |
|:--|:--|:--|:--|:--|:--|
| `genesis` | A + B jointly | Cooperative | Now | both wallet sigs over the **same byte-identical plan** (OQ-9 ruling, SPEC §3); terms sheet (class 2) | C∅, round 1 |

*Genesis is the one co-signed transaction and it is **not an exit** — Law 1's
boundary begins at the covenant's birth. The pre-genesis lifecycle (offer →
release → confirm/revoke) is off-chain and already ruled: `covenant_custody.md
§3.2`. The unilateral pre-genesis exit is refusing to sign, or the revocation
sweep.*

### Settlement (inline — no settle state exists)

Every settlement above is the **same transition that decided it**: the
resolving reveal, the forfeiting claim, the resign, or the dead-man crank pays
the pot, bond remainders and buffer split directly (successor `None` in the
plan; output layout pinned by introspection to the genesis-registered payout
SPKs). A separate "settleable" state would add one state, one transaction and
one liveness question per match and answer nothing — deleted by design
(SPEC.md §4.6).

## The set-(b) audit (OQ-4/OQ-5 re-arm triggers, checked)

Set (b) — transitions needing *us specifically* — is exactly **{own moves
(commit / reveal / resign), timeout claims}**. Claims are lower-bound rights
with no expiry; moves are foreground by the product's own UX law. **No row
gives set (b) a genuine deadline, and set (b) is not larger than C2 ruled** —
neither re-arm trigger fires (`COVENANT_PASS.md §6` OQ-4/OQ-5). No row's
advance requires a specific sleeping phone (`covenant_custody.md §5.1`'s bar):
every Anyone row is takeable by the counterparty or a stranger, and every
timed row re-arms rather than expires.

## Foldability (Law 1's cousin, `covenant_custody.md §4.4`)

Every field above lives in the redeem preimage; the model's state struct **is**
this table's state (asserted by construction in the walker). A cold resync
reconstructs each row's enablement from chain data alone: slot occupancy from
decoded state, every clock from `accepted_daa` vs current DAA. No off-chain
memory is part of any state's identity.
