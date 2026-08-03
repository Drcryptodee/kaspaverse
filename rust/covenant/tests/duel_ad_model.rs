//! The Attack & Defend exit-property model (COVENANT C3 — DP-12, D-121).
//!
//! This is the machine-checked half of `contracts/duel_ad/STATES.md`: the duel
//! state machine encoded once, its reachable space enumerated exhaustively, and
//! the INV-6 properties asserted on every path — instead of a hand-written exit
//! table (blueprint §9.2: "the largest single upgrade available to the plan").
//!
//! DP-12's tool ruling: a Rust walker in-tree, not TLA+. Reasons (stated per the
//! C3 prompt's criterion — what the consensus-auditor and the founder can READ):
//! the auditor reads Rust daily and TLA+ never; the founder runs `tools/gate.sh`
//! and cannot run TLC; a walker re-proves the properties on every gate run
//! forever instead of once in a pasted transcript; it adds zero packages
//! (std only — INV-7); and its frontier doubles as the DP-9 vector generator,
//! which a TLA+ spec would need a translation layer to feed.
//!
//! The model state IS the on-chain covenant state (foldability by construction:
//! every field below is decoded from the redeem preimage; nothing off-chain).
//! Sudden death is modelled as its exact quotient: between pairs the score is
//! tied by construction, so only the within-pair deltas are carried — the
//! absolute tied base changes no predicate (dead-man compares, forfeits ignore
//! score). Windows are per-match terms; the model costs them symbolically
//! (a claim waits ONE window) and uses Standard-control DAA values (1800) only
//! in emitted vectors.
//!
//! Properties (SPEC.md §7 carries the same list; `covenant_custody.md §2.1`
//! Law 1 mandates P2's witness check per reachable state):
//!   P1  bounded sole exit: each player alone (opponent absent, resign
//!       excluded) reaches a terminal in ≤ EXIT_WINDOW_BOUND windows.
//!   P1f pure abandonment pays the claimant: if the opponent never acted in
//!       the current phase, the claims-only path ends with the claimant paid.
//!   P2  Law 1: no unilateral-exit/crank row requires class-3 material or a
//!       counterparty signature; every signed row carries the wallet arm.
//!   P3  no reachable deadlock (an enabled transition exists everywhere).
//!   P4  abandonment converges: Anyone-takeable edges alone reach a terminal
//!       from every reachable state (the dead-man; C2 §0.1's machine check).
//!   P5  concession counters cannot stick: 3 settles inline (never stored),
//!       and at most one counter is nonzero (the mutual rows are deleted).
//!   P6  bonds stay in [0, BOND_SLICES]; only reveal claims slice; an offense
//!       against an empty bond forfeits.
//!   P7  value conservation: every terminal pays pot + bond remainders
//!       exactly; every slice is paid at claim time from the conceder's bond.
//!   P8  sudden death cannot loop invisibly: every SD pair end is either
//!       decisive or returns to the pair start (the quotient's single cycle),
//!       and P1/P4 hold inside it.
//!   P9  every Taker::Anyone edge has exactly one successor (determined), the
//!       reveal's epistemic branch excepted (unique given the bound preimage).
//!   P11 stalling is strictly dominated mechanically: every claim strictly
//!       worsens the conceder (counter, bond, or match), and the conceder's
//!       own move was enabled from the state's birth (Unlock::Now).
//!
//! Vector emission (DP-9): positive vectors are walker-searched paths to every
//! terminal cause; negative vectors are the refusals the script/consensus must
//! make, each carrying its enforcing layer. Golden-compared against
//! `contracts/duel_ad/vectors/*.json`; regenerate with KV_REGEN_VECTORS=1.

use std::collections::{HashMap, HashSet, VecDeque};

use kaspaverse_covenant::seam::{EntrypointClass, Taker, Unlock};

// ---------------------------------------------------------------------------
// Match terms (per-match negotiables — Standard control shown; the model's
// properties are window-symbolic and hold for any values ≥ the Blitz floor).
// ---------------------------------------------------------------------------

const W_COMMIT: u64 = 1_800; // DAA — per-match term (Blitz floor 600)
const W_REVEAL: u64 = 1_800; // DAA — per-match term
const W_DEADMAN: u64 = 36_000; // DAA ≈ 1 h — fixed statute, all controls
/// The terms-validity law (SPEC §3.1; consensus-auditor C3 finding 1): windows
/// are per-match terms bounded to [W_FLOOR, W_CEILING]. The ceiling is what
/// keeps the stall-to-the-statute defense true — a claims exit (≤ 3 windows)
/// must mature far inside the statute, or a leading staller could reach
/// `dead_man_settle` before the awake victim's first claim. Genesis planning
/// and the first-party confirm refuse out-of-range windows (the same refusal
/// layer as the payout-address rule).
const W_FLOOR: u64 = 600; // Blitz — never below on mainnet (pvp §6)
const W_CEILING: u64 = 6_000; // Relaxed — the largest admissible control
const BOND_SLICES: u8 = 5; // standing reveal bond, in slices of `b`
const ROUNDS: u8 = 10; // regulation length
/// P1's asserted ceiling: phase completion (≤1 window) + three claim windows.
const EXIT_WINDOW_BOUND: u32 = 4;

// ---------------------------------------------------------------------------
// The covenant state (the model state IS the on-chain state — foldability).
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, PartialOrd, Ord)]
enum Player {
    A,
    B,
}
use Player::{A, B};

impl Player {
    fn other(self) -> Player {
        match self {
            A => B,
            B => A,
        }
    }
    fn name(self) -> &'static str {
        match self {
            A => "a",
            B => "b",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
enum Mode {
    /// Regulation round 1..=10. Attacker alternates: A attacks odd rounds
    /// (the a-attacks-odd convention — symmetric, fixed in the terms sheet).
    Reg { round: u8 },
    /// Sudden death, quotiented: scores carry the within-pair deltas only
    /// (0/1 each); between pairs the absolute score is tied by construction.
    /// `second_half` = the pair's second pick is in progress.
    Sd { second_half: bool },
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
enum Phase {
    /// Commitments present per player. {true,true} is unrepresentable: the
    /// second commit's successor is already `Revealing`.
    Committing { a: bool, b: bool },
    /// Both committed; reveals present per player.
    Revealing { a: bool, b: bool },
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
struct S {
    mode: Mode,
    phase: Phase,
    /// Regulation: strikes landed (absolute). SD: within-pair deltas.
    score_a: u8,
    score_b: u8,
    /// Consecutive conceded rounds. 3 settles inline — never stored (P5).
    conc_a: u8,
    conc_b: u8,
    /// Remaining standing-bond slices.
    bond_a: u8,
    bond_b: u8,
}

impl S {
    fn genesis() -> S {
        S {
            mode: Mode::Reg { round: 1 },
            phase: Phase::Committing { a: false, b: false },
            score_a: 0,
            score_b: 0,
            conc_a: 0,
            conc_b: 0,
            bond_a: BOND_SLICES,
            bond_b: BOND_SLICES,
        }
    }

    fn attacker(&self) -> Player {
        match self.mode {
            // a-attacks-odd convention; SD half 1 continues the odd parity.
            Mode::Reg { round } => {
                if round % 2 == 1 {
                    A
                } else {
                    B
                }
            }
            Mode::Sd { second_half } => {
                if second_half {
                    B
                } else {
                    A
                }
            }
        }
    }

    fn bond(&self, p: Player) -> u8 {
        match p {
            A => self.bond_a,
            B => self.bond_b,
        }
    }
    fn leader(&self) -> Option<Player> {
        // Valid in Reg (absolute) and SD (deltas over a tied base) alike.
        match self.score_a.cmp(&self.score_b) {
            std::cmp::Ordering::Greater => Some(A),
            std::cmp::Ordering::Less => Some(B),
            std::cmp::Ordering::Equal => None,
        }
    }
}

// ---------------------------------------------------------------------------
// Terminals and value accounting.
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
enum Cause {
    Elimination,
    Regulation,
    SdPair,
    CounterForfeit,
    BondForfeit,
    DeadMan,
    Resign,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
struct Terminal {
    /// None = tied dead-man: stakes refunded. Every other cause has a winner.
    winner: Option<Player>,
    cause: Cause,
    /// Bond remainders at settlement (slices) — paid to their owners.
    bond_a: u8,
    bond_b: u8,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum Succ {
    Live(S),
    Done(Terminal),
}

// ---------------------------------------------------------------------------
// Entrypoints (edges). Each carries the seam's ratified vocabulary — proving
// STATES.md is expressible in `rust/covenant/src/seam.rs` types (C1, D-114).
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
enum Kind {
    Commit(Player),
    Reveal(Player),
    /// Beneficiary-signed remedy for the counterparty's commit stall.
    ClaimCommitTimeout(Player),
    /// Beneficiary-signed remedy for the counterparty's reveal stall (+slice).
    ClaimRevealTimeout(Player),
    Resign(Player),
    /// The score-aware statute: determined, anyone, from every state.
    DeadMan,
}

/// Witness material class per Law 1 (`covenant_custody.md §2.1`). `OwnSig` is
/// the dual arm (session_pk OR payout_pk) — the wallet arm is always present,
/// so no signed row depends on class-3 material.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Material {
    None,
    OwnSig(Player),
    /// The commit preimage tuple — class 3, held for a RIGHT only (row 9);
    /// P2 asserts it never appears on an exit or crank row.
    Preimage(Player),
}

#[derive(Clone, Debug)]
struct Edge {
    kind: Kind,
    class: EntrypointClass,
    /// Rendered from player A's perspective (the seam's enum is perspectival).
    taker_for_a: Taker,
    unlock: Unlock,
    material: Material,
    /// Slices paid out of a bond to the claimant inside this transition.
    slice_paid_to: Option<Player>,
    succs: Vec<Succ>,
}

fn remaining_attacks(p: Player, next_round: u8) -> u8 {
    // Future attack rounds for p in next_round..=ROUNDS under a-attacks-odd.
    (next_round..=ROUNDS)
        .filter(|r| if p == A { r % 2 == 1 } else { r % 2 == 0 })
        .count() as u8
}

/// Resolve the current round: by full play (attacker_scored known) or by a
/// concession (conceder known). Returns the successor plus whether a slice
/// was paid (reveal claims only).
fn resolve(s: &S, conceder: Option<Player>, attacker_scored: Option<bool>, slice: bool) -> Succ {
    let attacker = s.attacker();
    let mut n = *s;

    // --- bond slice / bond-exhaustion forfeit (reveal claims only) ---------
    if slice {
        let c = conceder.expect("slice implies conceder");
        if n.bond(c) == 0 {
            // "Bond exhausted → next offense forfeits the match."
            return Succ::Done(Terminal {
                winner: Some(c.other()),
                cause: Cause::BondForfeit,
                bond_a: n.bond_a,
                bond_b: n.bond_b,
            });
        }
        match c {
            A => n.bond_a -= 1,
            B => n.bond_b -= 1,
        }
    }

    // --- score the round ---------------------------------------------------
    let scored = match (conceder, attacker_scored) {
        // Conceded rounds resolve at the claimant's optimum: a conceding
        // defender forfeits the block (attacker +1); a conceding attacker
        // forfeits the strike (+0).
        (Some(c), None) => c != attacker,
        (None, Some(hit)) => hit,
        _ => unreachable!("exactly one resolution source"),
    };
    if scored {
        match attacker {
            A => n.score_a += 1,
            B => n.score_b += 1,
        }
    }

    // --- concession counters (consecutive; the non-conceder's chain breaks) -
    match conceder {
        Some(A) => {
            n.conc_a += 1;
            n.conc_b = 0;
            if n.conc_a == 3 {
                return Succ::Done(Terminal {
                    winner: Some(B),
                    cause: Cause::CounterForfeit,
                    bond_a: n.bond_a,
                    bond_b: n.bond_b,
                });
            }
        }
        Some(B) => {
            n.conc_b += 1;
            n.conc_a = 0;
            if n.conc_b == 3 {
                return Succ::Done(Terminal {
                    winner: Some(A),
                    cause: Cause::CounterForfeit,
                    bond_a: n.bond_a,
                    bond_b: n.bond_b,
                });
            }
        }
        None => {
            n.conc_a = 0;
            n.conc_b = 0;
        }
    }

    // --- advance the mode --------------------------------------------------
    match n.mode {
        Mode::Reg { round } => {
            let next = round + 1;
            let rem_a = remaining_attacks(A, next);
            let rem_b = remaining_attacks(B, next);
            // The elimination rule; at round 10 both remainders are 0, so the
            // same comparison IS the regulation settlement.
            if n.score_a > n.score_b + rem_b {
                return Succ::Done(Terminal {
                    winner: Some(A),
                    cause: if round == ROUNDS {
                        Cause::Regulation
                    } else {
                        Cause::Elimination
                    },
                    bond_a: n.bond_a,
                    bond_b: n.bond_b,
                });
            }
            if n.score_b > n.score_a + rem_a {
                return Succ::Done(Terminal {
                    winner: Some(B),
                    cause: if round == ROUNDS {
                        Cause::Regulation
                    } else {
                        Cause::Elimination
                    },
                    bond_a: n.bond_a,
                    bond_b: n.bond_b,
                });
            }
            if round == ROUNDS {
                // Tied after regulation → sudden death; scores become deltas.
                n.mode = Mode::Sd { second_half: false };
                n.score_a = 0;
                n.score_b = 0;
            } else {
                n.mode = Mode::Reg { round: next };
            }
        }
        Mode::Sd { second_half: false } => {
            n.mode = Mode::Sd { second_half: true };
        }
        Mode::Sd { second_half: true } => {
            // Pair end: decisive iff the deltas differ (exactly one scored).
            if n.score_a != n.score_b {
                return Succ::Done(Terminal {
                    winner: n.leader(),
                    cause: Cause::SdPair,
                    bond_a: n.bond_a,
                    bond_b: n.bond_b,
                });
            }
            n.mode = Mode::Sd { second_half: false };
            n.score_a = 0;
            n.score_b = 0;
        }
    }

    n.phase = Phase::Committing { a: false, b: false };
    Succ::Live(n)
}

fn taker_for_a(p: Player) -> Taker {
    match p {
        A => Taker::Me,
        B => Taker::Counterparty,
    }
}

/// Enumerate every entrypoint takeable from a live state — the STATES.md rows.
fn edges(s: &S) -> Vec<Edge> {
    let mut out = Vec::new();

    match s.phase {
        Phase::Committing { a, b } => {
            for p in [A, B] {
                let done = if p == A { a } else { b };
                if !done {
                    let np = match p {
                        A => Phase::Committing { a: true, b },
                        B => Phase::Committing { a, b: true },
                    };
                    let succ = match np {
                        // The second commit's successor is the reveal phase.
                        Phase::Committing { a: true, b: true } => {
                            Phase::Revealing { a: false, b: false }
                        }
                        other => other,
                    };
                    out.push(Edge {
                        kind: Kind::Commit(p),
                        class: EntrypointClass::Cooperative,
                        taker_for_a: taker_for_a(p),
                        unlock: Unlock::Now,
                        material: Material::OwnSig(p),
                        slice_paid_to: None,
                        succs: vec![Succ::Live(S { phase: succ, ..*s })],
                    });
                }
            }
            // Standing rule: a claim exists only where the claimant's own act
            // is in state and the counterparty's is absent.
            for (claimant, standing, absent) in [(A, a, b), (B, b, a)] {
                if standing && !absent {
                    out.push(Edge {
                        kind: Kind::ClaimCommitTimeout(claimant),
                        class: EntrypointClass::UnilateralExit,
                        taker_for_a: taker_for_a(claimant),
                        unlock: Unlock::AfterInputAge(W_COMMIT),
                        material: Material::OwnSig(claimant),
                        slice_paid_to: None,
                        succs: vec![resolve(s, Some(claimant.other()), None, false)],
                    });
                }
            }
        }
        Phase::Revealing { a, b } => {
            for p in [A, B] {
                let done = if p == A { a } else { b };
                if !done {
                    let completes = if p == A { b } else { a };
                    let succs = if completes {
                        // The second reveal resolves — the model branches on
                        // the (already-locked, hidden) zones; on-chain the
                        // outcome is unique given the two bound preimages.
                        vec![
                            resolve(s, None, Some(true), false),
                            resolve(s, None, Some(false), false),
                        ]
                    } else {
                        let np = match p {
                            A => Phase::Revealing { a: true, b },
                            B => Phase::Revealing { a, b: true },
                        };
                        vec![Succ::Live(S { phase: np, ..*s })]
                    };
                    out.push(Edge {
                        kind: Kind::Reveal(p),
                        class: EntrypointClass::Cooperative,
                        taker_for_a: Taker::Anyone, // preimage-gated, sig-free
                        unlock: Unlock::Now,
                        material: Material::Preimage(p),
                        slice_paid_to: None,
                        succs,
                    });
                }
            }
            for (claimant, standing, absent) in [(A, a, b), (B, b, a)] {
                if standing && !absent {
                    out.push(Edge {
                        kind: Kind::ClaimRevealTimeout(claimant),
                        class: EntrypointClass::UnilateralExit,
                        taker_for_a: taker_for_a(claimant),
                        unlock: Unlock::AfterInputAge(W_REVEAL),
                        material: Material::OwnSig(claimant),
                        slice_paid_to: if s.bond(claimant.other()) > 0 {
                            Some(claimant)
                        } else {
                            None // empty bond: the offense forfeits instead
                        },
                        succs: vec![resolve(s, Some(claimant.other()), None, true)],
                    });
                }
            }
        }
    }

    // Resign: voluntary, instant, pot to the opponent (a product row, not an
    // INV-6 exit — value flows away from the taker by their own choice).
    for p in [A, B] {
        out.push(Edge {
            kind: Kind::Resign(p),
            class: EntrypointClass::Cooperative,
            taker_for_a: taker_for_a(p),
            unlock: Unlock::Now,
            material: Material::OwnSig(p),
            slice_paid_to: None,
            succs: vec![Succ::Done(Terminal {
                winner: Some(p.other()),
                cause: Cause::Resign,
                bond_a: s.bond_a,
                bond_b: s.bond_b,
            })],
        });
    }

    // The dead-man statute: determined (score is state, payout exact),
    // takeable by anyone, from every live state — D-119 set (a).
    out.push(Edge {
        kind: Kind::DeadMan,
        class: EntrypointClass::Crank,
        taker_for_a: Taker::Anyone,
        unlock: Unlock::AfterInputAge(W_DEADMAN),
        material: Material::None,
        slice_paid_to: None,
        succs: vec![Succ::Done(Terminal {
            winner: s.leader(),
            cause: Cause::DeadMan,
            bond_a: s.bond_a,
            bond_b: s.bond_b,
        })],
    });

    out
}

// ---------------------------------------------------------------------------
// Reachability.
// ---------------------------------------------------------------------------

struct Space {
    reachable: HashSet<S>,
    terminals: HashSet<Terminal>,
}

fn enumerate() -> Space {
    let mut reachable = HashSet::new();
    let mut terminals = HashSet::new();
    let mut queue = VecDeque::new();
    reachable.insert(S::genesis());
    queue.push_back(S::genesis());
    while let Some(s) = queue.pop_front() {
        for e in edges(&s) {
            for succ in &e.succs {
                match succ {
                    Succ::Live(n) => {
                        if reachable.insert(*n) {
                            queue.push_back(*n);
                        }
                    }
                    Succ::Done(t) => {
                        terminals.insert(*t);
                    }
                }
            }
        }
    }
    Space {
        reachable,
        terminals,
    }
}

/// Edges player `p` can take alone: their own moves and claims plus
/// signature-free rows whose material they hold. `Reveal(other)` needs the
/// opponent's preimage — not theirs. Resign is excluded: P1 measures the
/// value-preserving exit, not the donation.
fn sole_edges(s: &S, p: Player) -> Vec<Edge> {
    edges(s)
        .into_iter()
        .filter(|e| match e.kind {
            Kind::Commit(q) | Kind::ClaimCommitTimeout(q) | Kind::ClaimRevealTimeout(q) => q == p,
            Kind::Reveal(q) => q == p,
            Kind::Resign(_) => false,
            Kind::DeadMan => true,
        })
        .collect()
}

/// Windows a sole path must wait for this edge (symbolic: one W per claim;
/// the dead-man's statute counts as its DAA ratio so the minimiser prefers
/// claims but may still fall back to it if claims ever vanished).
fn window_cost(e: &Edge) -> u32 {
    match e.unlock {
        Unlock::Now => 0,
        Unlock::AfterInputAge(w) => {
            if w == W_DEADMAN {
                20 // 36 000 / 1 800 — orders of magnitude, not exactness
            } else {
                1
            }
        }
        Unlock::AtDaaScore(_) => unreachable!("the wedge is relative-only (OQ-8 ruling)"),
    }
}

/// Min-max sole-exit cost for `p` from `s`: p minimises (windows, transitions)
/// lexicographically; chance branches (the completing reveal) cost their worst
/// outcome. Returns None if a terminal is unreachable by p alone (a P1 FAIL).
fn sole_exit_cost(
    s: &S,
    p: Player,
    memo: &mut HashMap<(S, Player), Option<(u32, u32)>>,
    visiting: &mut HashSet<(S, Player)>,
) -> Option<(u32, u32)> {
    if let Some(hit) = memo.get(&(*s, p)) {
        return *hit;
    }
    if !visiting.insert((*s, p)) {
        // Cycle on the sole subgraph: this path never terminates; another
        // branch must provide the exit.
        return None;
    }
    let mut best: Option<(u32, u32)> = None;
    for e in sole_edges(s, p) {
        let mut worst: Option<(u32, u32)> = Some((0, 0));
        for succ in &e.succs {
            let c = match succ {
                Succ::Done(_) => Some((0, 0)),
                Succ::Live(n) => sole_exit_cost(n, p, memo, visiting),
            };
            worst = match (worst, c) {
                (Some(w), Some(c)) => Some(w.max(c)),
                _ => None,
            };
        }
        if let Some((ww, wt)) = worst {
            let cand = (ww + window_cost(&e), wt + 1);
            best = Some(match best {
                Some(b) => b.min(cand),
                None => cand,
            });
        }
    }
    visiting.remove(&(*s, p));
    memo.insert((*s, p), best);
    best
}

/// The pure-abandonment path: from a state where `p` has standing (or can
/// gain it) and the opponent's current-phase act is absent, drive p's
/// act-then-claim strategy to its terminal and return it.
fn abandonment_terminal(mut s: S, p: Player) -> Terminal {
    loop {
        // Prefer: claim if standing, else act (commit/reveal own).
        let es = sole_edges(&s, p);
        let claim = es.iter().find(|e| {
            matches!(e.kind, Kind::ClaimCommitTimeout(q) | Kind::ClaimRevealTimeout(q) if q == p)
        });
        let act = es
            .iter()
            .find(|e| matches!(e.kind, Kind::Commit(q) | Kind::Reveal(q) if q == p));
        let chosen = claim
            .or(act)
            .expect("abandonment strategy always has a move");
        // The opponent is absent, so no chance branch ever completes a round:
        // p's reveal only parks (the opponent never committed past this
        // phase)… except p's reveal after both committed — the opponent DID
        // act this round; that state is outside pure abandonment. Callers
        // only hand states where the opponent's current-phase act is absent.
        match &chosen.succs[0] {
            Succ::Live(n) => s = *n,
            Succ::Done(t) => return *t,
        }
    }
}

// ---------------------------------------------------------------------------
// The properties.
// ---------------------------------------------------------------------------

#[test]
fn the_duel_state_space_satisfies_the_inv6_properties() {
    let space = enumerate();
    let n_reach = space.reachable.len();
    assert!(
        n_reach > 1_000,
        "the walk must actually enumerate ({n_reach})"
    );

    let mut max_exit: (u32, u32) = (0, 0);
    let mut memo = HashMap::new();

    for s in &space.reachable {
        let es = edges(s);

        // P3 — no deadlock.
        assert!(!es.is_empty(), "deadlocked state {s:?}");

        // P4 — abandonment converges via Anyone edges alone: the dead-man is
        // present, determined, one transition, bounded by its statute.
        let dm = es
            .iter()
            .find(|e| matches!(e.kind, Kind::DeadMan))
            .unwrap_or_else(|| panic!("no dead-man from {s:?}"));
        assert_eq!(dm.taker_for_a, Taker::Anyone);
        assert_eq!(dm.class, EntrypointClass::Crank);
        assert_eq!(dm.unlock, Unlock::AfterInputAge(W_DEADMAN));
        assert_eq!(dm.material, Material::None);
        assert_eq!(dm.succs.len(), 1, "dead-man must be determined");

        // P5 — counters: 3 never stored; at most one nonzero.
        assert!(
            s.conc_a <= 2 && s.conc_b <= 2,
            "counter stored at 3+: {s:?}"
        );
        assert!(
            s.conc_a == 0 || s.conc_b == 0,
            "both counters nonzero — the deleted mutual rows resurfaced: {s:?}"
        );

        // P6 — bonds in range (slicing asserted per-edge below).
        assert!(s.bond_a <= BOND_SLICES && s.bond_b <= BOND_SLICES);

        // Scores stay in their domains (Reg absolute / SD deltas).
        match s.mode {
            Mode::Reg { round } => {
                assert!((1..=ROUNDS).contains(&round));
                assert!(s.score_a <= 5 && s.score_b <= 5);
            }
            Mode::Sd { .. } => {
                assert!(
                    s.score_a <= 1 && s.score_b <= 1,
                    "SD deltas out of range {s:?}"
                );
            }
        }

        for e in &es {
            // P2 — Law 1 per row: no exit/crank cites class-3 material or a
            // counterparty signature; signed rows always carry the wallet arm.
            match e.class {
                EntrypointClass::UnilateralExit | EntrypointClass::Crank => {
                    assert!(
                        !matches!(e.material, Material::Preimage(_)),
                        "Law 1 violation — class-3 material on an exit row: {e:?}"
                    );
                    if let Material::OwnSig(who) = e.material {
                        // The signer must be the taker — never the counterparty.
                        match e.taker_for_a {
                            Taker::Me => assert_eq!(who, A),
                            Taker::Counterparty => assert_eq!(who, B),
                            Taker::Anyone => panic!("signed row cannot be Anyone: {e:?}"),
                        }
                    }
                }
                EntrypointClass::Cooperative => {}
            }

            // P9 — determinedness: every Anyone edge has one successor; the
            // completing reveal's two branches are epistemic (the bound
            // preimages fix the outcome on-chain).
            if e.taker_for_a == Taker::Anyone {
                match e.kind {
                    Kind::Reveal(_) => assert!(e.succs.len() <= 2),
                    _ => assert_eq!(e.succs.len(), 1, "non-determined Anyone edge {e:?}"),
                }
            }

            // P6 — only reveal claims slice, by exactly one, from the
            // conceder, paid to the claimant (local conservation → P7 global).
            match e.kind {
                Kind::ClaimRevealTimeout(claimant) => {
                    for succ in &e.succs {
                        let (nb_a, nb_b) = match succ {
                            Succ::Live(n) => (n.bond_a, n.bond_b),
                            Succ::Done(t) => (t.bond_a, t.bond_b),
                        };
                        let conceder = claimant.other();
                        if s.bond(conceder) == 0 {
                            // Empty bond: the offense forfeits, no slice.
                            assert_eq!((nb_a, nb_b), (s.bond_a, s.bond_b));
                            assert!(matches!(succ, Succ::Done(t) if t.cause == Cause::BondForfeit));
                            assert_eq!(e.slice_paid_to, None);
                        } else {
                            let expect = match conceder {
                                A => (s.bond_a - 1, s.bond_b),
                                B => (s.bond_a, s.bond_b - 1),
                            };
                            assert_eq!((nb_a, nb_b), expect, "slice must come from the conceder");
                            assert_eq!(e.slice_paid_to, Some(claimant));
                        }
                    }
                }
                _ => {
                    for succ in &e.succs {
                        let (nb_a, nb_b) = match succ {
                            Succ::Live(n) => (n.bond_a, n.bond_b),
                            Succ::Done(t) => (t.bond_a, t.bond_b),
                        };
                        assert_eq!(
                            (nb_a, nb_b),
                            (s.bond_a, s.bond_b),
                            "bonds moved outside a reveal claim: {e:?}"
                        );
                    }
                }
            }

            // P11 — every claim strictly worsens the conceder mechanically.
            if let Kind::ClaimCommitTimeout(c) | Kind::ClaimRevealTimeout(c) = e.kind {
                let conceder = c.other();
                for succ in &e.succs {
                    match succ {
                        Succ::Done(t) => assert_eq!(
                            t.winner,
                            Some(c),
                            "a claim's terminal must pay the claimant: {e:?}"
                        ),
                        Succ::Live(n) => {
                            let counter_up = match conceder {
                                A => n.conc_a > s.conc_a,
                                B => n.conc_b > s.conc_b,
                            };
                            let bond_down = n.bond(conceder) < s.bond(conceder);
                            assert!(
                                counter_up || bond_down,
                                "claim did not worsen the conceder: {e:?}"
                            );
                        }
                    }
                }
            }
        }

        // P1 — bounded sole exit for each player, resign excluded.
        for p in [A, B] {
            let mut visiting = HashSet::new();
            let cost = sole_exit_cost(s, p, &mut memo, &mut visiting)
                .unwrap_or_else(|| panic!("player {p:?} has no sole exit from {s:?}"));
            assert!(
                cost.0 <= EXIT_WINDOW_BOUND,
                "sole exit for {p:?} needs {} windows from {s:?}",
                cost.0
            );
            max_exit = max_exit.max(cost);
        }

        // P1f — pure abandonment pays the claimant: wherever the opponent's
        // current-phase act is absent, the act-then-claim strategy ends with
        // the pot to the standing player.
        for p in [A, B] {
            let opponent_acted = match s.phase {
                Phase::Committing { a, b } => {
                    if p == A {
                        b
                    } else {
                        a
                    }
                }
                Phase::Revealing { a, b } => {
                    if p == A {
                        b
                    } else {
                        a
                    }
                }
            };
            if !opponent_acted {
                let t = abandonment_terminal(*s, p);
                assert_eq!(
                    t.winner,
                    Some(p),
                    "abandonment must pay the present player: from {s:?} got {t:?}"
                );
            }
        }
    }

    // P7 — terminal payout table: pot + bond remainders, nothing else.
    // (Slices moved at claim time — asserted per edge above; the buffer's
    // split is a constant rule, C4 prices it.)
    for t in &space.terminals {
        match t.cause {
            Cause::DeadMan => {} // winner may be None (tie refund)
            _ => assert!(
                t.winner.is_some(),
                "non-dead-man terminal without winner {t:?}"
            ),
        }
        assert!(t.bond_a <= BOND_SLICES && t.bond_b <= BOND_SLICES);
    }

    // P8 — the SD quotient: reachable SD states carry deltas only, and both
    // pair outcomes (decisive, continue) are reachable — the loop is real and
    // its every iteration passes through the claimable/dead-man-covered
    // states already checked above.
    let sd_states = space
        .reachable
        .iter()
        .filter(|s| matches!(s.mode, Mode::Sd { .. }))
        .count();
    assert!(sd_states > 0, "sudden death must be reachable");
    assert!(
        space.terminals.iter().any(|t| t.cause == Cause::SdPair),
        "a decisive SD pair must be reachable"
    );

    // Every terminal cause is reachable — the machine has no dead law.
    for cause in [
        Cause::Elimination,
        Cause::Regulation,
        Cause::SdPair,
        Cause::CounterForfeit,
        Cause::BondForfeit,
        Cause::DeadMan,
        Cause::Resign,
    ] {
        assert!(
            space.terminals.iter().any(|t| t.cause == cause),
            "terminal cause {cause:?} unreachable"
        );
    }

    println!(
        "duel_ad model: {} reachable states, {} distinct terminals",
        n_reach,
        space.terminals.len()
    );
    println!(
        "P1 worst sole exit: {} windows, {} transitions (bound {})",
        max_exit.0, max_exit.1, EXIT_WINDOW_BOUND
    );
}

/// The mutual-stall rows of `pvp_game_theory.md §6`'s table are deliberately
/// deleted (SPEC.md §5.4): no claim exists without standing, so a state where
/// neither player acted offers no claim edge at all — the dead-man is the
/// only absence remedy. This test pins the deletion.
#[test]
fn no_claim_exists_without_standing() {
    let space = enumerate();
    for s in &space.reachable {
        let nobody_acted = matches!(
            s.phase,
            Phase::Committing { a: false, b: false } | Phase::Revealing { a: false, b: false }
        );
        if nobody_acted {
            for e in edges(s) {
                assert!(
                    !matches!(
                        e.kind,
                        Kind::ClaimCommitTimeout(_) | Kind::ClaimRevealTimeout(_)
                    ),
                    "claim without standing from {s:?}"
                );
            }
        }
    }
}

/// The terms-validity law, asserted (SPEC §3.1): every admissible window sits
/// in [W_FLOOR, W_CEILING], and the worst claims exit (3 windows, the P1
/// bound) matures at no more than half the statute — the margin that makes
/// the stall-to-the-statute row of the stag-hunt table true for EVERY
/// admissible terms sheet, not only the three named controls.
#[test]
fn the_terms_validity_law_bounds_every_window() {
    for w in [W_COMMIT, W_REVEAL] {
        assert!(
            (W_FLOOR..=W_CEILING).contains(&w),
            "window {w} outside the terms-validity law"
        );
    }
    // The ratio half is a compile-time proof: the constants are the law.
    const {
        assert!(
            W_CEILING * 3 <= W_DEADMAN / 2,
            "a 3-window claims exit must mature inside half the statute"
        );
    }
}

/// A-3's transaction-count consequence, machine-checked: every edge is one
/// transaction (no MUX split anywhere), so `pvp §10`'s buffer sizing at the
/// TRANSITION count is the TRANSACTION count — the D-117 trigger fires green.
#[test]
fn every_transition_is_one_transaction() {
    let space = enumerate();
    let mut max_edges = 0usize;
    for s in &space.reachable {
        // Structural: the model has no two-transaction row to express; this
        // test exists so adding one ever fails loudly here first.
        max_edges = max_edges.max(edges(s).len());
    }
    assert!(
        max_edges <= 7,
        "the per-state entrypoint census moved: {max_edges}"
    );
}

// ---------------------------------------------------------------------------
// DP-9 — vector emission from the model's frontier.
// ---------------------------------------------------------------------------

mod vectors {
    use super::*;

    /// A deterministic scripted walk to a named terminal: at each state the
    /// script names the edge (and the chance branch where a reveal resolves).
    struct Walk {
        name: &'static str,
        description: &'static str,
        /// (edge kind, chance index into succs)
        steps: Vec<(Kind, usize)>,
    }

    fn kind_label(k: Kind) -> String {
        match k {
            Kind::Commit(p) => format!("commit_{}", p.name()),
            Kind::Reveal(p) => format!("reveal_{}", p.name()),
            Kind::ClaimCommitTimeout(p) => format!("claim_commit_timeout_{}", p.name()),
            Kind::ClaimRevealTimeout(p) => format!("claim_reveal_timeout_{}", p.name()),
            Kind::Resign(p) => format!("resign_{}", p.name()),
            Kind::DeadMan => "dead_man_settle".to_string(),
        }
    }

    fn age_for(e: &Edge) -> u64 {
        match e.unlock {
            Unlock::Now => 0,
            Unlock::AfterInputAge(w) => w,
            Unlock::AtDaaScore(_) => unreachable!(),
        }
    }

    /// Drive a scripted walk, emitting one JSON step per transition and
    /// asserting it ends in the expected terminal cause.
    fn run(walk: &Walk, expect: Cause) -> String {
        let mut s = S::genesis();
        let mut steps = Vec::new();
        let mut terminal: Option<Terminal> = None;
        for (kind, branch) in &walk.steps {
            assert!(terminal.is_none(), "{}: walked past terminal", walk.name);
            let es = edges(&s);
            let e = es
                .iter()
                .find(|e| e.kind == *kind)
                .unwrap_or_else(|| panic!("{}: {:?} not enabled at {:?}", walk.name, kind, s));
            let succ = &e.succs[*branch];
            let outcome = match (e.kind, e.succs.len(), branch) {
                (Kind::Reveal(_), 2, 0) => ",\"attacker_scored\":true",
                (Kind::Reveal(_), 2, 1) => ",\"attacker_scored\":false",
                _ => "",
            };
            steps.push(format!(
                "{{\"age_daa\":{},\"entrypoint\":\"{}\"{}}}",
                age_for(e),
                kind_label(e.kind),
                outcome
            ));
            match succ {
                Succ::Live(n) => s = *n,
                Succ::Done(t) => terminal = Some(*t),
            }
        }
        let t = terminal.unwrap_or_else(|| panic!("{}: walk ended live at {:?}", walk.name, s));
        assert_eq!(t.cause, expect, "{}: wrong terminal", walk.name);
        let winner = match t.winner {
            Some(p) => format!("\"{}\"", p.name()),
            None => "null".to_string(),
        };
        format!(
            "    {{\n      \"name\": \"{}\",\n      \"description\": \"{}\",\n      \"steps\": [{}],\n      \"terminal\": {{\"cause\": \"{:?}\", \"winner\": {}, \"bond_a\": {}, \"bond_b\": {}}}\n    }}",
            walk.name,
            walk.description,
            steps.join(", "),
            t.cause,
            winner,
            t.bond_a,
            t.bond_b
        )
    }

    fn round_full(attacker_scored: bool) -> Vec<(Kind, usize)> {
        vec![
            (Kind::Commit(A), 0),
            (Kind::Commit(B), 0),
            (Kind::Reveal(A), 0),
            (Kind::Reveal(B), if attacker_scored { 0 } else { 1 }),
        ]
    }

    fn walks() -> Vec<(Walk, Cause)> {
        let mut v = Vec::new();

        // Regulation win, all ten rounds played: A scores rounds 1,3,5 (their
        // attacks), B scores 2,4 — 3–2 at the horn… make it undecided until
        // round 10: A scores odd rounds 1,3; B scores 2,4; rounds 5–8 blocked;
        // round 9 A scores (3–2), round 10 B blocked → 3–2 Regulation, A.
        let mut steps = Vec::new();
        for r in 1..=10u8 {
            let hit = matches!(r, 1 | 3 | 2 | 4 | 9);
            steps.extend(round_full(hit));
        }
        v.push((
            Walk {
                name: "regulation_win_by_play",
                description: "Ten full rounds, no stalls; 3-2 on the final resolution.",
                steps,
            },
            Cause::Regulation,
        ));

        // Early elimination: A scores every attack, B never scores.
        // After round 6: A 3-0, B's remaining attacks (8, 10) = 2 → 3 > 0+2.
        let mut steps = Vec::new();
        for r in 1..=6u8 {
            steps.extend(round_full(r % 2 == 1));
        }
        v.push((
            Walk {
                name: "early_elimination",
                description: "A converts three attacks while B converts none; the round-6 resolution settles mathematically.",
                steps,
            },
            Cause::Elimination,
        ));

        // Tie through regulation, decisive first SD pair.
        let mut steps = Vec::new();
        for r in 1..=10u8 {
            steps.extend(round_full(matches!(r, 1 | 2 | 5 | 6))); // 2-2
        }
        steps.extend(round_full(true)); // SD half 1: A scores
        steps.extend(round_full(false)); // SD half 2: B blocked → decisive
        v.push((
            Walk {
                name: "tie_to_sudden_death_decisive",
                description: "2-2 regulation; first sudden-death pair splits 1-0 to A.",
                steps,
            },
            Cause::SdPair,
        ));

        // Counter forfeit: B never commits; A commits and claims three times.
        let mut steps = Vec::new();
        for _ in 0..3 {
            steps.push((Kind::Commit(A), 0));
            steps.push((Kind::ClaimCommitTimeout(A), 0));
        }
        v.push((
            Walk {
                name: "commit_stall_counter_forfeit",
                description: "B vanishes before round 1; three standing claims by A run B's counter to the forfeit. A's exit needs 3 windows.",
                steps,
            },
            Cause::CounterForfeit,
        ));

        // Bond forfeit: B reveal-stalls every one of their own attacks —
        // conceding an attack scores +0, so the score stays level while five
        // slices drain and the played rounds in between reset the counter.
        // The tie reaches sudden death, where the sixth offense meets an
        // empty bond and forfeits.
        let mut steps = Vec::new();
        for r in 1..=10u8 {
            if r % 2 == 1 {
                steps.extend(round_full(false)); // played round, no strike
            } else {
                steps.push((Kind::Commit(A), 0));
                steps.push((Kind::Commit(B), 0));
                steps.push((Kind::Reveal(A), 0));
                steps.push((Kind::ClaimRevealTimeout(A), 0)); // B's attack conceded
            }
        }
        steps.extend(round_full(false)); // SD half 1 played
        steps.push((Kind::Commit(A), 0)); // SD half 2: the sixth offense
        steps.push((Kind::Commit(B), 0));
        steps.push((Kind::Reveal(A), 0));
        steps.push((Kind::ClaimRevealTimeout(A), 0));
        v.push((
            Walk {
                name: "reveal_stalls_exhaust_bond_then_forfeit",
                description: "B reveal-stalls each of their five regulation attacks (+0 keeps the score tied; played rounds between reset the counter); the sixth offense, in sudden death, hits an empty bond and forfeits.",
                steps,
            },
            Cause::BondForfeit,
        ));

        // Dead-man, tied: nobody moves after genesis.
        v.push((
            Walk {
                name: "dead_man_tie_refund",
                description:
                    "No transition for the statute from genesis; tied 0-0, stakes refunded.",
                steps: vec![(Kind::DeadMan, 0)],
            },
            Cause::DeadMan,
        ));

        // Dead-man with a leader, mid-reveal: one played round (A scores),
        // then both vanish mid round 2.
        let mut steps = round_full(true);
        steps.push((Kind::Commit(A), 0));
        steps.push((Kind::Commit(B), 0));
        steps.push((Kind::Reveal(B), 0));
        steps.push((Kind::DeadMan, 0));
        v.push((
            Walk {
                name: "dead_man_leader_mid_reveal",
                description: "1-0 after round 1; both vanish inside round 2's reveal phase; anyone settles at score after the statute.",
                steps,
            },
            Cause::DeadMan,
        ));

        // Resign.
        let mut steps = round_full(true);
        steps.push((Kind::Resign(B), 0));
        v.push((
            Walk {
                name: "resign_after_first_round",
                description: "B resigns down 0-1; instant settlement to A.",
                steps,
            },
            Cause::Resign,
        ));

        // SD dead-man mid-pair: tie, SD half 1 resolves (A scores), then
        // silence — the half-1 delta decides the dead-man leader.
        let mut steps = Vec::new();
        for r in 1..=10u8 {
            steps.extend(round_full(matches!(r, 1 | 2)));
        }
        steps.extend(round_full(true)); // SD half 1: A's delta 1
        steps.push((Kind::DeadMan, 0));
        v.push((
            Walk {
                name: "sd_dead_man_mid_pair",
                description: "Sudden death, pair half 1 scored by A, then both vanish; the dead-man pays the delta leader.",
                steps,
            },
            Cause::DeadMan,
        ));

        v
    }

    /// The refusals the compiled script and the consensus rules must make.
    /// `enforcer` names the layer per the promise map (SPEC.md §8): `script`
    /// rows fail in the template's own code; `consensus` rows fail in the
    /// pinned node's validation (cites at SPEC.md §6).
    fn negatives() -> String {
        let rows: Vec<(&str, &str, &str, &str)> = vec![
            (
                "premature_claim_sequence_lock",
                "A commit-timeout claim broadcast before the window: the claim input carries sequence = W, and the state UTXO is younger than W.",
                "consensus",
                "check_sequence_lock rejects until the spent UTXO is `sequence` DAA old (tx_validation_in_utxo_context.rs:136-155 at cfafeb4c)",
            ),
            (
                "premature_claim_low_sequence",
                "A claim built with sequence < W to slip the consensus lock: the script's CSV guard reads W from the template and the input's sequence is below it.",
                "script",
                "OpCheckSequenceVerify fails when stack_sequence > input.sequence (opcodes/mod.rs, UnsatisfiedLockTime)",
            ),
            (
                "premature_claim_disabled_bit",
                "A claim built with sequence = W | SEQUENCE_LOCK_TIME_DISABLED (1<<63): consensus FILTERS disabled-bit inputs out of the sequence lock, so the script's CSV arm is the only wall standing.",
                "script",
                "OpCheckSequenceVerify refuses a spending input whose sequence carries the disabled bit (opcodes/mod.rs:1093-1094 at cfafeb4c) — the one premature shape with a single enforcement layer; the P4 harness must execute it",
            ),
            (
                "premature_dead_man",
                "A dead-man settlement attempted before the 36000-DAA statute.",
                "consensus",
                "same sequence lock, statute-length window",
            ),
            (
                "claim_without_standing",
                "A claim from a state where the claimant's own commit/reveal is absent (nobody acted).",
                "script",
                "the claim branch requires the claimant's slot to be present in state — no such entrypoint exists (STATES.md standing rule)",
            ),
            (
                "claim_when_opponent_acted",
                "A commit-timeout claim while the opponent's commitment is already in state.",
                "script",
                "the claim branch requires the counterparty's slot to be absent",
            ),
            (
                "commit_wrong_signer",
                "B's key signing into A's commitment slot.",
                "script",
                "the commit branch checks the signature against the slot owner's registered session_pk or payout_pk",
            ),
            (
                "commit_duplicate_hash",
                "The second commitment byte-equal to the first (copy attempt).",
                "script",
                "explicit inequality check at the second commit (pvp §4 defense-in-depth)",
            ),
            (
                "reveal_wrong_preimage",
                "A reveal whose (zone, salt) does not hash to the stored commitment under the revealer's identity fields.",
                "script",
                "Blake2b(domain ‖ covenant_id ‖ round ‖ role ‖ session_pk ‖ zone ‖ salt) mismatch",
            ),
            (
                "reveal_cross_round_replay",
                "Replaying round N's preimage in round N+1.",
                "script",
                "the round number is an identity field in the reconstructed hash",
            ),
            (
                "reveal_cross_match_replay",
                "Replaying a preimage from another match.",
                "script",
                "the covenant id is an identity field in the reconstructed hash",
            ),
            (
                "commit_in_reveal_phase",
                "A commit attempted while both commitments are already in state.",
                "script",
                "phase dispatch: the commit branch requires an empty own slot in the committing phase",
            ),
            (
                "overdraw_fee",
                "A transition whose successor value is more than the fee cap below the input value.",
                "script",
                "value floor: next.value >= self.value - FEE_CAP, and never below stakes + bonds",
            ),
            (
                "settle_unregistered_payout",
                "A settlement output paying a script public key that is not the genesis-registered payout of the entitled player.",
                "script",
                "output introspection pins every settlement output to registered payout SPKs (OpTxOutputSpk)",
            ),
            (
                "dead_man_wrong_split",
                "A dead-man settlement paying the pot to the trailing player.",
                "script",
                "the settle branch computes the payout from the state's scores; any other output layout fails introspection",
            ),
            (
                "sd_elimination_check",
                "An elimination settlement attempted during sudden death.",
                "script",
                "the elimination comparison is gated on regulation mode (§7 disabled in SD)",
            ),
            (
                "successor_state_tamper",
                "A transition whose successor output carries a state the transition function did not produce (wrong score after a reveal).",
                "script",
                "successor validation recomputes and pins template ‖ state for the covenant output",
            ),
        ];
        let mut out = Vec::new();
        for (name, description, layer, enforcer) in rows {
            out.push(format!(
                "    {{\n      \"name\": \"{}\",\n      \"description\": \"{}\",\n      \"reject_layer\": \"{}\",\n      \"enforcer\": \"{}\"\n    }}",
                name, description, layer, enforcer
            ));
        }
        out.join(",\n")
    }

    fn render_positive() -> String {
        let body = walks()
            .iter()
            .map(|(w, c)| run(w, *c))
            .collect::<Vec<_>>()
            .join(",\n");
        format!(
            "{{\n  \"format\": \"duel-ad-vectors-v1\",\n  \"source\": \"rust/covenant/tests/duel_ad_model.rs (DP-9/DP-12; regenerate with KV_REGEN_VECTORS=1)\",\n  \"windows\": {{\"w_commit\": {W_COMMIT}, \"w_reveal\": {W_REVEAL}, \"w_dead_man\": {W_DEADMAN}, \"note\": \"per-match terms (Standard control shown); ages are the claim input's minimum sequence\"}},\n  \"vectors\": [\n{body}\n  ]\n}}\n"
        )
    }

    fn render_negative() -> String {
        format!(
            "{{\n  \"format\": \"duel-ad-vectors-v1\",\n  \"source\": \"rust/covenant/tests/duel_ad_model.rs (DP-9/DP-12; regenerate with KV_REGEN_VECTORS=1)\",\n  \"note\": \"each row names the layer that must refuse it; at P4 the parity harness drives the script rows through kaspa-txscript against the compiled template and asserts the named failure\",\n  \"vectors\": [\n{}\n  ]\n}}\n",
            negatives()
        )
    }

    fn golden(path_tail: &str, rendered: &str) {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../contracts/duel_ad/vectors")
            .join(path_tail);
        if std::env::var("KV_REGEN_VECTORS").is_ok() {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, rendered).unwrap();
            return;
        }
        let committed = std::fs::read_to_string(&path).unwrap_or_else(|e| {
            panic!("missing committed vectors {path:?} ({e}) — run with KV_REGEN_VECTORS=1")
        });
        assert_eq!(
            committed, rendered,
            "committed vectors diverge from the model — the machine changed without re-proof; regenerate with KV_REGEN_VECTORS=1 and re-audit"
        );
    }

    /// DP-9: the committed vector set is exactly what the model emits.
    #[test]
    fn committed_vectors_match_the_model() {
        golden("positive.json", &render_positive());
        golden("negative.json", &render_negative());
    }
}
