//! The covenant FFI contract — what a covenant *summary* is (C1 §3).
//!
//! Under INV-1/2/3 only summaries, booleans, pubkeys and opaque handles cross
//! the bridge. These types are that contract, defined here so the boundary is
//! ratified once; the bridge mirrors them at P3.x (FRB-compatible by
//! construction: `String`/`u64`/`i64`/`bool`/`Vec`/`Option` and data enums
//! only — no `Hash`, no `ScriptPublicKey`, no consensus types).
//!
//! **Every field is public chain data or user-originated display data.** The
//! per-field argument, audited by `ffi-leak-auditor` at C1:
//! covenant ids, template hashes, txids, values, DAA scores and entrypoint
//! names are consensus-public; decoded state fields come from the first-party
//! recipe over on-chain-committed bytes, with hidden material rendered ONLY
//! as its public digest (`is_commitment`); the local player's own move was
//! typed in Dart to begin with. What never crosses, by type absence: redeem
//! preimages, state layouts, script bytes, commit salts, session-key private
//! halves, derivation paths.
//!
//! The confirm renders the **transition** — state before → state after →
//! exits available — never transaction bytes (anti-blind-signing,
//! `transactor_protocol.md §5` item 3). The `nonce` is the same stash-guard
//! discipline the shipped `SignableSummaryDto` uses (B7); the covenant sheet
//! extends that surface (the reserved `SignableKind::Stake` seam), it does
//! not invent a parallel one.

/// One decoded covenant-state field, rendered for display.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StateFieldDto {
    /// Recipe-supplied label ("round", "your bond").
    pub label: String,
    /// Display value, already formatted by the recipe decode.
    pub value: String,
    /// True when `value` is the public digest of hidden material (a
    /// commitment or virtual slot) — the UI renders it as opaque, and the
    /// preimage side NEVER crosses (it does not exist in any DTO type).
    pub is_commitment: bool,
}

/// A decoded covenant state, named and fielded — what "state before" and
/// "state after" render as.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StateRenderDto {
    /// The state's canonical name from the recipe ("AwaitingReveal").
    pub name: String,
    pub fields: Vec<StateFieldDto>,
}

/// Who can take an action, from the local player's perspective.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TakerDto {
    Me,
    Counterparty,
    Anyone,
}

/// When an action unlocks. Chain-truthful DAA numbers — the render layer
/// turns them into ETAs with the DAA ticker it already has; Rust does not
/// format time (render-layer law).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnlockDto {
    Now,
    AtDaaScore(u64),
    AfterInputAge(u64),
}

/// The INV-6 class of an action, mirrored for display.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActionClassDto {
    Cooperative,
    UnilateralExit,
    Crank,
}

/// One action available on a covenant — a move, an exit, or a crank. The
/// live view lists all of them; the confirm sheet's INV-6 line filters for
/// `UnilateralExit`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActionDto {
    /// Entrypoint name, canonical (a `STATES.md` row).
    pub entrypoint: String,
    pub class: ActionClassDto,
    pub taker: TakerDto,
    pub unlock: UnlockDto,
    /// Recipe-supplied outcome label ("settles at last scored round") —
    /// contract-package data, not Rust-composed prose.
    pub outcome: String,
}

/// The live-match view's model of one covenant — the narrowest thing the UI
/// can be correct with. Dart holds NO covenant state machine: it renders
/// snapshots of this and offers `actions`; every action round-trips through
/// the Transactor. Dart never computes what is possible — it displays what
/// Rust enumerated.
#[derive(Clone, Debug)]
pub struct CovenantSummaryDto {
    /// KIP-20 lineage id, hex — consensus-public.
    pub covenant_id_hex: String,
    /// Registry-resolved template identity (template authenticity, DP-6):
    /// the pinned hash and the name the registry maps it to.
    pub template_name: String,
    pub template_hash_hex: String,
    pub state: StateRenderDto,
    pub value_sompi: u64,
    /// Txid of the current live outpoint, hex — public, explorer-linkable.
    pub utxo_txid_hex: String,
    /// DAA score at acceptance of the live UTXO.
    pub accepted_daa: u64,
    /// Recipe-supplied role label for this player ("Attacker"), when the
    /// template has role semantics.
    pub role_label: Option<String>,
    /// Whether it is the local player's turn; `None` when the template has
    /// no turn semantics.
    pub my_turn: Option<bool>,
    /// Every action available now or on a known clock, INV-6-classified.
    pub actions: Vec<ActionDto>,
}

/// The covenant CONFIRM sheet's model — the transition, never bytes. Emitted
/// only by the first-party verifier after its independent re-verify against
/// the watcher's known state; a mismatch is an error, never a sheet.
#[derive(Clone, Debug)]
pub struct TransitionSummaryDto {
    /// Opaque token tying this summary to its stashed transaction (the
    /// shipped B7 stash/nonce discipline).
    pub nonce: u64,
    pub covenant_id_hex: String,
    pub template_name: String,
    pub template_hash_hex: String,
    /// The entrypoint being taken.
    pub entrypoint: String,
    pub before: StateRenderDto,
    /// `None` exactly when this transition settles the family (a final
    /// exit with no successor).
    pub after: Option<StateRenderDto>,
    /// Net value change for the local player, sompi (negative = at risk /
    /// spent, positive = claimed).
    pub my_delta_sompi: i64,
    /// The exact fee the plan carries — never "≈ free".
    pub fee_sompi: u64,
    /// Total compute budget across the plan's inputs, script units —
    /// logistics, rendered as such, never as game semantics
    /// (`transactor_protocol.md §4.1`).
    pub compute_budget_units: u64,
    /// The INV-6 line: exits available in the state being entered.
    pub exits_after: Vec<ActionDto>,
    /// The earliest action the COUNTERPARTY (or anyone) can take against the
    /// successor state if the local player does nothing — the honest "what
    /// happens if I stall" line, structured so the render layer phrases it.
    pub counterparty_next: Option<ActionDto>,
}
