//! The first-party verify half of the engine — deliberately **not** on the
//! [`crate::CovenantTransition`] trait.
//!
//! The shipped anti-blind-signing law (`transactor_protocol.md §5`, numbered
//! item 3) says the confirm renders Rust's decode of the stash, never the
//! form's echo. For covenants that extends one step further: never the
//! *builder's* echo either. If `decode` lived on the same trait as `plan`,
//! the implementation under suspicion would render its own confirm sheet —
//! the fox auditing the henhouse. So the seam splits: **build** is swappable
//! code behind the trait; **verify** is first-party code driven by a
//! [`DecodeRecipe`] — declarative data from the contract package, one per
//! pinned template (lexicon §3.3: ours is the contract package + pinned
//! template hash; Argent's artifact would be *mapped into* a recipe once,
//! which is exactly the independent re-derivation gate G-A4).
//!
//! Everything here is `todo!()` at C1 — the shape is the deliverable, the
//! behaviour is P3.1's.

use crate::dto::{CovenantSummaryDto, StateRenderDto, TransitionSummaryDto};
use crate::error::Result;
use crate::seam::{CovenantState, LiveCovenant, TemplateId, TransitionPlan};

/// The machine-readable recipe for decoding one template's states and
/// transitions: state layout, field labels, entrypoint table with INV-6
/// classes, exit conditions. Format is fixed at P3.1 alongside the first
/// contract package; at C1 it is opaque bytes with a pinned identity.
#[derive(Clone, Debug)]
pub struct DecodeRecipe {
    pub template: TemplateId,
    /// Serialized recipe body (format: P3.1, `contracts/<name>/`).
    pub body: Vec<u8>,
}

/// First-party verifier: recipes in, rendered truth out. Owns no keys, no
/// sockets, no implementation of the build seam — it exists to disagree with
/// one.
#[derive(Debug, Default)]
pub struct TransitionVerifier {
    recipes: Vec<DecodeRecipe>,
}

impl TransitionVerifier {
    /// A verifier over the app's pinned recipes (the template registry's
    /// verification half).
    pub fn new(recipes: Vec<DecodeRecipe>) -> Self {
        Self { recipes }
    }

    /// The pinned recipes this verifier answers from.
    pub fn recipes(&self) -> &[DecodeRecipe] {
        &self.recipes
    }

    /// Decode covenant state into display form using the recipe — never the
    /// build implementation. Hidden material renders as its public digest;
    /// no salt or preimage of a commitment ever appears in the output.
    pub fn decode_state(
        &self,
        _template: &TemplateId,
        _state: &CovenantState,
    ) -> Result<StateRenderDto> {
        todo!("P3.1: recipe-driven state decode")
    }

    /// Render a live covenant for the match view. `_current_daa` lets unlock
    /// conditions render as open/pending without the UI doing chain math.
    pub fn summarize_live(
        &self,
        _subject: &LiveCovenant,
        _current_daa: u64,
    ) -> Result<CovenantSummaryDto> {
        todo!("P3.1: live covenant summary")
    }

    /// The covenant CONFIRM decode: independently re-derive what `plan`
    /// claims — successor state, bindings, value flow, exits available in
    /// the state being entered — from the stashed transaction plus the
    /// recipe, cross-checked against `known` (the watcher's view of the
    /// subject). A mismatch is [`crate::CovenantError::StateMismatch`],
    /// never a renderable summary: there is no "render anyway" path.
    pub fn summarize_transition(
        &self,
        _nonce: u64,
        _plan: &TransitionPlan,
        _known: &LiveCovenant,
    ) -> Result<TransitionSummaryDto> {
        todo!("P3.1: independent transition re-verify + summary")
    }
}
