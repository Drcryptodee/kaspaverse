//! The single error type that crosses the FFI (INV-2: `Result`, never a panic).
//!
//! Carries only a human-readable `message` — never secret material. `CoreError`
//! (the custody crate's error) is mapped through its `Display`, which is
//! likewise secret-free by construction (`rust/core/src/error.rs`).

use kaspaverse_core::CoreError;

/// Error crossing the FFI/JNI boundary. A plain message string keeps the DTO
/// trivial for FRB and gives the JNI side something to throw as a Java
/// exception without leaking internals.
#[derive(Debug, Clone)]
pub struct AppError {
    pub message: String,
}

impl AppError {
    /// A bare message (call sites that don't wrap another error).
    pub(crate) fn msg(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }

    /// Map a chain-layer error. A node's own words that ride it are filtered
    /// at this one door (`ChainError::to_screen_text`), as every other route
    /// filters node text.
    pub(crate) fn chain(e: kaspaverse_chain::ChainError) -> Self {
        Self {
            message: e.to_screen_text(),
        }
    }

    /// Map a custody-core error (its `Display` is secret-free, core/error.rs).
    pub(crate) fn core(e: CoreError) -> Self {
        Self {
            message: e.to_string(),
        }
    }

    /// Map a storage I/O error, prefixed so logcat shows the lane.
    pub(crate) fn io(context: &str, e: std::io::Error) -> Self {
        Self {
            message: format!("vault storage {context}: {e}"),
        }
    }
}
