use std::fmt;

/// Chain-layer error. Boxes the upstream wRPC error to keep `Result` slim
/// (clippy::result_large_err — upstream's variant is 144+ bytes) without
/// losing any detail or the error source chain.
#[derive(Debug)]
pub struct ChainError(pub Box<kaspa_wrpc_client::error::Error>);

impl fmt::Display for ChainError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl std::error::Error for ChainError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(self.0.as_ref())
    }
}

impl From<kaspa_wrpc_client::error::Error> for ChainError {
    fn from(e: kaspa_wrpc_client::error::Error) -> Self {
        Self(Box::new(e))
    }
}

impl From<kaspa_wrpc_client::prelude::RpcError> for ChainError {
    fn from(e: kaspa_wrpc_client::prelude::RpcError) -> Self {
        Self(Box::new(e.into()))
    }
}

pub type Result<T> = std::result::Result<T, ChainError>;
