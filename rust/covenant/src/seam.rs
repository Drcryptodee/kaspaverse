//! The `CovenantTransition` seam (DP-2, D-114) — the entire Argent-optionality
//! mechanism, as compilable Rust.
//!
//! The unit of exchange is a **complete transition plan**, not per-input script
//! bytes. Two facts force that granularity. First, every field the pinned
//! sighash commits to — version, all outpoints, all sequences, the spent
//! SPK/amount, outputs *including covenant bindings*, `lock_time`, payload
//! (`consensus/core/src/hashing/sighash.rs`, `calc_schnorr_signature_hash`, at
//! `cfafeb4c`) — must be final before any signature exists, so an
//! implementation must own whole-transaction assembly to be able to promise
//! anything. Second, the nearest real implementation model,
//! `argent-template/src/bin/counter.rs` at `0eae1fd`, builds transactions
//! exactly this way (`TxContext` → `TxBuilder::build`); a per-input seam would
//! fight the one implementation it exists to make swappable.
//!
//! What the sighash does **not** commit to is signature scripts — so signing
//! can happen after planning, in `rust/core`, over the stashed bytes, and the
//! witness assembles afterwards without invalidating anything. That is the
//! request/response split OQ-1 asked to be tested: [`TransitionPlan`] carries
//! the frozen unsigned transaction plus [`InputWitnessTemplate`]s whose
//! [`SignatureSlot`]s name keys by [`KeyRole`]. Only `rust/core` can resolve a
//! role to a key; this crate cannot even name a secret type.
//!
//! The pinned wallet-core Generator is **excluded from this path** by three
//! independent pin facts: it hardcodes `version = 0`
//! (`generator.rs:1093,1158`), a v0 transaction cannot carry a covenant
//! binding (`tx_validation_in_isolation.rs:209-212`), and it hardcodes every
//! input's `sequence = 0` with no setter (`generator.rs:735`) — which would
//! make any `OpCheckSequenceVerify` exit unsatisfiable. Implementations emit
//! v1 transactions directly and control `sequence` (relative idiom) and
//! `lock_time` (absolute idiom) as first-class fields, so the timeout-idiom
//! ruling (OQ-8 → C3) is not foreclosed by this seam in either direction.

use kaspa_consensus_core::hashing::sighash_type::SigHashType;
use kaspa_consensus_core::tx::{ScriptPublicKey, Transaction, TransactionOutpoint};
use kaspa_consensus_core::Hash;
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::error::Result;

/// The pinned identity of a template — the hash a player's app pins and the
/// registry resolves to a human name (template authenticity, DP-6/C4). The
/// program without state; lexicon §3.1.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TemplateId(pub Hash);

/// Encoded covenant state — the typed fields inside the redeem preimage, in
/// their script-committed encoding. Opaque here: the layout is known to the
/// implementation that builds with it and to the decode recipe that renders
/// it, never to this seam.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CovenantState(pub Vec<u8>);

/// The redeem preimage: template ‖ current state, revealed at spend — the
/// only thing that can spend the UTXO (lexicon §3.1). Zeroized on drop as
/// hygiene: for a public state machine it is class-1 derivable material, but
/// the same type will carry `virtual`-slot expansions whose loss freezes the
/// UTXO and whose custody is C2's problem — the type does not get to know
/// which class it holds, so it drops safely for both. `Debug` is opaque for
/// the same reason (ffi-leak C1 audit): a derived `{:?}` would copy the
/// bytes into unzeroized formatter output.
pub struct RedeemPreimage(pub Vec<u8>);

impl std::fmt::Debug for RedeemPreimage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "RedeemPreimage({} bytes)", self.0.len())
    }
}

impl Zeroize for RedeemPreimage {
    fn zeroize(&mut self) {
        self.0.zeroize();
    }
}
impl Drop for RedeemPreimage {
    fn drop(&mut self) {
        self.zeroize();
    }
}
impl ZeroizeOnDrop for RedeemPreimage {}

/// The engine's view of one live covenant UTXO — everything is public chain
/// data. Produced by the watcher, consumed by planning and verification.
#[derive(Clone, Debug)]
pub struct LiveCovenant {
    /// Consensus-tracked lineage id (KIP-20).
    pub covenant_id: Hash,
    /// The current live outpoint.
    pub outpoint: TransactionOutpoint,
    pub value_sompi: u64,
    /// The P2SH commitment currently holding the value.
    pub script_public_key: ScriptPublicKey,
    /// Encoded covenant state at this outpoint.
    pub state: CovenantState,
    /// DAA score at which this UTXO's transaction was accepted — the anchor
    /// both timeout idioms measure from.
    pub accepted_daa: u64,
}

/// How an entrypoint unlocks. Both timeout idioms are first-class so the seam
/// forecloses neither (OQ-8 is C3's ruling, per state):
/// [`Unlock::AtDaaScore`] is the absolute idiom (`OpTxInputDaaScore` 0xc0 +
/// lock-time), [`Unlock::AfterInputAge`] the relative one
/// (`OpCheckSequenceVerify` 0xb1, constraining the spending input's
/// `sequence`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Unlock {
    /// Takeable now, no time condition.
    Now,
    /// Takeable once the network passes an absolute DAA score.
    AtDaaScore(u64),
    /// Takeable once the spent UTXO is at least this many DAA old.
    AfterInputAge(u64),
}

/// Who may take an entrypoint, from the local player's perspective.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Taker {
    /// Requires our signature.
    Me,
    /// Requires the counterparty's signature.
    Counterparty,
    /// Permissionless — anyone may broadcast it, because the covenant
    /// determines every output. **Not a synonym for "crank."** A crank is
    /// this composed with [`EntrypointClass::Crank`] (recovery from a
    /// stall); the same `Anyone` composed with
    /// [`EntrypointClass::Cooperative`] is the ordinary, non-stalled
    /// determined transition — a MUX worker executing an already-declared
    /// move, or a settlement whose payout the script pins exactly. In the
    /// reference chess family that case is the *majority*: nine of its
    /// twelve compiled templates contain no signature check at all
    /// (`covenant_design_patterns.md §7`, lexicon §3.4). The composition is
    /// intended; only this comment used to foreclose it (D-117).
    Anyone,
}

/// The INV-6 classification of an entrypoint.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntrypointClass {
    /// An ordinary move inside the game's cooperative path. Says nothing
    /// about who may take it: pair with [`Taker`] for that. `Cooperative` +
    /// [`Taker::Anyone`] is the ordinary determined transition (lexicon
    /// §3.4) and is a normal, expected combination — D-117.
    Cooperative,
    /// A unilateral exit — takeable alone, without the counterparty
    /// (INV-6; `toccata_protocol.md §15` row L19).
    UnilateralExit,
    /// A determined transition broadcast to **rescue a stalled match**. The
    /// recovery subset of [`Taker::Anyone`], not the whole of it.
    Crank,
}

/// One named spend path through the template, as planning and the UI see it.
#[derive(Clone, Debug)]
pub struct EntrypointDescriptor {
    /// The entrypoint's canonical name (a row in the contract's `STATES.md`).
    pub name: String,
    pub class: EntrypointClass,
    pub taker: Taker,
    pub unlock: Unlock,
}

/// A typed entrypoint argument. The encoding an implementation lowers these
/// to (selector layout, argument order — exactly the surface Argent's entry
/// ABI churns on, OQ-3) is that implementation's private business.
#[derive(Clone, Debug)]
pub enum EntryArg {
    U64(u64),
    I64(i64),
    Bool(bool),
    Hash(Hash),
    Bytes(Vec<u8>),
}

/// A key named by role, never by material. Resolution happens in `rust/core`
/// only — this crate has no dependency path to the vault, so a role is the
/// strongest thing an implementation can hold (OQ-1, INV-1/2).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum KeyRole {
    /// The wallet key that owns this script public key; core resolves it to
    /// a derivation through its own address book.
    Wallet(ScriptPublicKey),
    /// The ephemeral per-match session key (lexicon §3.4). Whether its spend
    /// constraint needs a second covenant is A-3, open until C3 — this
    /// reference is agnostic.
    Session {
        /// The match this key is scoped to, by covenant id.
        match_covenant_id: Hash,
    },
}

/// A funding input the Transactor selected and will let core sign — fees and
/// wager value beyond what the consumed covenant carries. Selection policy is
/// the Transactor's, before planning; the plan freezes the result.
#[derive(Clone, Debug)]
pub struct FundingInput {
    pub outpoint: TransactionOutpoint,
    pub value_sompi: u64,
    pub script_public_key: ScriptPublicKey,
    /// Which key must sign this input.
    pub key: KeyRole,
}

/// A request to plan one transition of one live covenant. Everything the
/// final transaction will commit to is already here: the plan may not invent
/// inputs, outputs or destinations the request did not name.
#[derive(Clone, Debug)]
pub struct TransitionRequest {
    pub subject: LiveCovenant,
    /// The entrypoint to take, by canonical name.
    pub entrypoint: String,
    pub args: Vec<EntryArg>,
    /// Transactor-selected funding, complete (may be empty).
    pub funding: Vec<FundingInput>,
    /// Where non-covenant remainder value returns; `None` when the request
    /// expects exact consumption.
    pub change: Option<ScriptPublicKey>,
    /// The fee the Transactor priced (node policy, never a constant —
    /// `transactor_protocol.md §4.2`); the plan must leave exactly this
    /// input−output gap.
    pub fee_sompi: u64,
}

/// A request to plan a covenant genesis — the family's first UTXO(s). The
/// covenant id is derived, never chosen: implementations call the pinned
/// `kaspa_consensus_core::hashing::covenant_id` (INV-9), which binds the
/// authorizing outpoint to the exact ordered initial output set.
#[derive(Clone, Debug)]
pub struct GenesisRequest {
    pub template: TemplateId,
    /// Constants baked into the redeem script at genesis (lexicon §3.1).
    pub constructor_constants: Vec<EntryArg>,
    /// Initial covenant state for each output in the genesis group, in order.
    pub initial_states: Vec<CovenantState>,
    /// Value for each genesis-group output, matching `initial_states`.
    pub values_sompi: Vec<u64>,
    pub funding: Vec<FundingInput>,
    pub change: Option<ScriptPublicKey>,
    pub fee_sompi: u64,
}

/// One chunk of a signature script under assembly.
#[derive(Clone, Debug)]
pub enum WitnessChunk {
    /// Bytes the implementation computed from public material: entrypoint
    /// selectors, encoded arguments, revealed state, the redeem preimage
    /// push. Frozen at planning.
    Literal(Vec<u8>),
    /// A hole only `rust/core` can fill: a signature by `key` over the
    /// pinned sighash of the stashed transaction. The engine never sees a
    /// sighash to forward and never receives the ability to fill the hole
    /// itself.
    Signature(SignatureSlot),
}

/// The request half of the OQ-1 split: which key, which sighash mode.
///
/// **Sighash law (C1 closure audit · D-115).** The freeze property this seam
/// promises — nothing rebinds after core signs — holds because the sighash
/// commits to the whole transaction, and it does that **only under
/// `SIG_HASH_ALL`**: the pinned hasher zeroes entire commitment fields for
/// the rest of the type space (`sequences_hash` → `ZERO_HASH` under
/// `NONE`/`SINGLE`/`ANYONECANPAY`; `outputs_hash` → `ZERO_HASH` under `NONE`;
/// `previous_outputs_hash` → `ZERO_HASH` under `ANYONECANPAY` —
/// `consensus/core/src/hashing/sighash.rs` at `cfafeb4c`). Core's slot-fill
/// therefore REFUSES any slot whose type is not `SIG_HASH_ALL` unless a
/// `D-` entry names the exception and the narrower commitment it accepts —
/// an implementation cannot widen what the user's signature stops committing
/// to by picking a looser mode. A default is not a constraint; this law is.
#[derive(Clone, Debug)]
pub struct SignatureSlot {
    pub key: KeyRole,
    /// Pinned sighash type (INV-9 — the pin's own type, not a re-statement).
    /// Constrained at fill time by the D-115 law above.
    pub sighash: SigHashType,
}

/// The signature-script template for one input of the planned transaction.
#[derive(Clone, Debug)]
pub struct InputWitnessTemplate {
    pub input_index: u32,
    /// Chunks in final script order; assembly is mechanical concatenation of
    /// pushes once every slot is filled.
    pub chunks: Vec<WitnessChunk>,
}

/// What planning promises the successor will be — the watcher pre-registers
/// it, and the first-party verifier checks the plan actually creates it
/// (successor validation is the covenant's job on-chain; this is the app's
/// mirror of the same claim).
///
/// **Open: this expectation cannot name the successor's *template*, so it
/// describes single-template families only (D-117, routed to C3).** To check
/// the promise, the verifier must re-derive the successor output's script
/// public key = P2SH(template ‖ state); the only template it can reach is
/// [`CovenantTransition::template`], which is the template being *spent*. In
/// a MUX family the successor is a different template by construction —
/// chess routes `Mux` → `Pawn` → `Mux` across twelve of them
/// (`covenant_design_patterns.md §7/§10`) — and the MUX is our own stated
/// core pattern for complex covenants, so this is not a foreign-only
/// concern. Whether the fix is a `TemplateId` here, a family-scoped
/// implementation, or a decode-recipe lookup is a design question with a
/// tier and auditors; it is deliberately **not** patched in passing.
#[derive(Clone, Debug)]
pub struct SuccessorExpectation {
    pub covenant_id: Hash,
    pub output_index: u32,
    pub state: CovenantState,
}

/// A complete, frozen transition plan. `unsigned_tx` is final in every field
/// the sighash commits to; only signature scripts remain empty, described by
/// `witness`. The Transactor stashes it under a nonce (the shipped B7
/// discipline), core fills the slots over the stashed bytes, chain
/// broadcasts.
#[derive(Clone, Debug)]
pub struct TransitionPlan {
    /// The v1 transaction, complete but unsigned. Per-input compute budgets
    /// ride in its inputs' `compute_commit` — logistics, third-party
    /// repairable, excluded from txid and sighash
    /// (`transactor_protocol.md §4.1`).
    pub unsigned_tx: Transaction,
    pub witness: Vec<InputWitnessTemplate>,
    /// `None` exactly when this transition settles the family with no
    /// successor (a final exit).
    pub successor: Option<SuccessorExpectation>,
}

/// The Covenant Engine's build seam. One implementation per codegen path:
/// Impl A is Silverscript-direct with witnesses we compute (P3/P4); Impl B
/// would be `argent-runtime` behind this same trait with witnesses derived
/// from the artifact (P5+, only if the C5 gates pass). Swapping
/// implementations must change no caller and rename nothing (D-106).
///
/// What an implementation receives is public chain data and public
/// parameters; what it returns is a frozen plan whose only unfinished parts
/// are [`SignatureSlot`]s it cannot fill. An implementation that hoards its
/// own key material can therefore *propose* anything and *authorize*
/// nothing: user keys are unreachable through this crate (no dependency path
/// to `kaspaverse-core`), and a hostile plan is caught at CONFIRM, where the
/// first-party verifier — never the implementation — renders what will be
/// signed (`verify`, B7 extended).
///
/// Implementations must be `Send + Sync` (the Transactor plans off the UI
/// thread) and object-safe (asserted in `lib.rs`).
pub trait CovenantTransition: Send + Sync {
    /// The template this implementation speaks for.
    fn template(&self) -> TemplateId;

    /// Compute the redeem preimage (template ‖ state) whose P2SH hash is the
    /// covenant's script public key. Pure; used by genesis, by spend
    /// planning, and by the watcher's re-derivation checks.
    fn redeem_preimage(&self, state: &CovenantState) -> Result<RedeemPreimage>;

    /// Enumerate the entrypoints available from a state, classified for
    /// INV-6. The verifier cross-checks this listing against the decode
    /// recipe: an implementation cannot hide an exit by omitting it here,
    /// because the recipe's exit table — not this listing — is what the
    /// confirm screen renders.
    fn entrypoints(&self, state: &CovenantState) -> Result<Vec<EntrypointDescriptor>>;

    /// Plan one transition: the complete unsigned v1 transaction plus its
    /// witness templates. Everything the sighash commits to is final on
    /// return — including each input's `sequence` and the transaction's
    /// `lock_time`, which is what keeps both timeout idioms expressible.
    fn plan(&self, request: &TransitionRequest) -> Result<TransitionPlan>;

    /// Plan a covenant genesis: the authorizing input, the ordered genesis
    /// group with bindings carrying the derived id, and the witness
    /// templates for the funding inputs.
    fn plan_genesis(&self, request: &GenesisRequest) -> Result<TransitionPlan>;
}
