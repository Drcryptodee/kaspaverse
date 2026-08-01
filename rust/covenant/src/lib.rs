//! kaspaverse-covenant — the Covenant Engine's boundary.
//!
//! Written at COVENANT C1 (DP-1/DP-2, D-113/D-114) as a **compilable stub**:
//! every signature is real, every body that would need behaviour is `todo!()`,
//! and the gate stays green. P3.1's first commit is this crate growing its
//! first behaviour — not an argument about where things go. The full boundary
//! rationale lives in `docs/research/covenant_engine_architecture.md`.
//!
//! Two absences are the architecture:
//!
//! - **No dependency path to `kaspaverse-core`.** Key material, the vault and
//!   the signer are unreachable from any implementation compiled against this
//!   seam. The trait speaks in [`seam::KeyRole`] *references* that only
//!   `rust/core` can resolve, and signature slots are filled there, after
//!   planning ends (OQ-1, INV-1/2). Core depends on this crate for the plan
//!   types; the arrow never points back.
//! - **No RPC dependency.** The engine cannot open a socket (INV-8). Chain
//!   extracts [`watch::CovenantSighting`]s from its existing block stream and
//!   feeds them in; chain broadcasts the plans the engine emits.
//!
//! Vocabulary is the lexicon's (`covenant_engine_lexicon.md`, D-106), and only
//! the lexicon's: covenant, covenant ID, template, redeem preimage, covenant
//! state, transition, entrypoint, successor validation, covenant genesis,
//! decode recipe, covenant watcher, crank, session key.

pub mod dto;
pub mod error;
pub mod seam;
pub mod verify;
pub mod watch;

pub use error::CovenantError;
pub use seam::CovenantTransition;

/// Compile-time proof that the seam supports a runtime implementation swap
/// (`dyn CovenantTransition`) — the Argent-optionality mechanism is a trait
/// object away, not a rewrite away. If a future method breaks object safety,
/// this line is the first thing that fails.
const _OBJECT_SAFE: Option<&dyn CovenantTransition> = None;
