use std::fmt;

/// Covenant-engine error. The variant split is law, not taste:
/// `transactor_protocol.md §4.1` — `compute_budget` is a third-party repair
/// channel, so a budget/mass shortfall is a **resource** failure and must
/// never render as a **transition** failure. A player told "your reveal was
/// rejected" when the truth is "that input was under-budgeted" has been
/// handed a false model of a game they have money in. The two failure
/// classes are therefore distinct variants from the first compiled line,
/// and the bridge maps them to different user surfaces.
///
/// **Reason law (ffi-leak C1 audit):** every `reason` crosses the FFI as a
/// Dart `String` and enters logs via `Display`. Reasons carry positions,
/// names and expectations — **never payload bytes**. A decode failure over a
/// preimage or a `virtual`-slot expansion must not quote the offending bytes
/// (the §5 no-echo law, applied to errors).
#[derive(Debug)]
pub enum CovenantError {
    /// The requested move is not valid from this covenant state — the state
    /// rule itself refuses (wrong entrypoint, wrong turn, bad argument).
    Transition { entrypoint: String, reason: String },
    /// A resource failure: compute budget, mass, or fee — the state rule may
    /// be perfect and the transaction still cannot run. Never rendered as a
    /// transition failure (§4.1).
    Resource { reason: String },
    /// The caller's view of the live covenant disagrees with what the
    /// watcher knows from the chain — the independent re-verify law
    /// (`transactor_protocol.md §5`, numbered item 3) refuses to produce a
    /// summary from a stale or forged view. There is deliberately no
    /// "render anyway with a warning" path: a failed re-verify is an error,
    /// never a sheet.
    StateMismatch { reason: String },
    /// The template is unknown, its decode recipe is missing, or the recipe
    /// cannot decode these state bytes (template-authenticity surface, DP-6).
    Recipe { reason: String },
    /// Malformed encoding — state bytes, argument bytes, or witness chunks
    /// that do not parse.
    Encoding { reason: String },
}

impl fmt::Display for CovenantError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CovenantError::Transition { entrypoint, reason } => {
                write!(
                    f,
                    "transition refused at entrypoint `{entrypoint}`: {reason}"
                )
            }
            CovenantError::Resource { reason } => {
                write!(f, "resource failure (not a transition failure): {reason}")
            }
            CovenantError::StateMismatch { reason } => {
                write!(f, "live covenant state mismatch: {reason}")
            }
            CovenantError::Recipe { reason } => write!(f, "decode recipe: {reason}"),
            CovenantError::Encoding { reason } => write!(f, "encoding: {reason}"),
        }
    }
}

impl std::error::Error for CovenantError {}

/// Engine-local result alias.
pub type Result<T> = std::result::Result<T, CovenantError>;
