use std::fmt;

/// Chain-layer error. Variants are boxed where the upstream payload is large
/// (clippy::result_large_err — the wRPC and wallet-core errors are 100+ bytes)
/// without losing detail or the source chain.
#[derive(Debug)]
pub enum ChainError {
    /// wRPC client / RPC transport error (P0.3 DAG monitor).
    Rpc(Box<kaspa_wrpc_client::error::Error>),
    /// kaspa-wallet-core error (UTXO processor / context — P1.5 sync).
    Wallet(Box<kaspa_wallet_core::error::Error>),
    /// Local activity-store I/O (app-private file; public data only, INV-3).
    Io(std::io::Error),
    /// The mature UTXO set can't cover a send (the wallet-core Generator's
    /// `InsufficientFunds`, surfaced as a typed variant so the bridge can tell a
    /// true shortfall from "not yet spendable / still maturing" using the live
    /// balance — P1.6). `additional_needed` is sompi short of amount + fee.
    InsufficientFunds { additional_needed: u64 },
    /// KIP-9 storage mass for this send exceeds the per-tx maximum: the amount
    /// is too small relative to the wallet's UTXOs (a tiny output is penalized).
    /// Typed so the bridge can guide the user to a larger amount (P1.6).
    StorageMassExceeded { storage_mass: u64 },
    /// A chain-layer message with no upstream source.
    Message(String),
}

impl fmt::Display for ChainError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ChainError::Rpc(e) => e.fmt(f),
            ChainError::Wallet(e) => e.fmt(f),
            ChainError::Io(e) => e.fmt(f),
            ChainError::InsufficientFunds { additional_needed } => {
                write!(f, "insufficient funds — {additional_needed} sompi short")
            }
            ChainError::StorageMassExceeded { storage_mass } => {
                write!(f, "storage mass {storage_mass} exceeds the per-tx maximum")
            }
            ChainError::Message(m) => f.write_str(m),
        }
    }
}

impl std::error::Error for ChainError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            ChainError::Rpc(e) => Some(e.as_ref()),
            ChainError::Wallet(e) => Some(e.as_ref()),
            ChainError::Io(e) => Some(e),
            ChainError::InsufficientFunds { .. }
            | ChainError::StorageMassExceeded { .. }
            | ChainError::Message(_) => None,
        }
    }
}

impl From<kaspa_wrpc_client::error::Error> for ChainError {
    fn from(e: kaspa_wrpc_client::error::Error) -> Self {
        ChainError::Rpc(Box::new(e))
    }
}

impl From<kaspa_wrpc_client::prelude::RpcError> for ChainError {
    fn from(e: kaspa_wrpc_client::prelude::RpcError) -> Self {
        ChainError::Rpc(Box::new(e.into()))
    }
}

impl From<kaspa_wallet_core::error::Error> for ChainError {
    fn from(e: kaspa_wallet_core::error::Error) -> Self {
        ChainError::Wallet(Box::new(e))
    }
}

impl From<std::io::Error> for ChainError {
    fn from(e: std::io::Error) -> Self {
        ChainError::Io(e)
    }
}

pub type Result<T> = std::result::Result<T, ChainError>;
