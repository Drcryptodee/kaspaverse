//! kaspaverse-core — keys, vault, signing.
//!
//! Empty shell in P0 (no keys, no secrets until P1). When P1 opens, every
//! secret type here is `ZeroizeOnDrop`, signing never leaves this crate, and
//! nothing secret crosses the FFI boundary in either direction (INV-1/2/3).

// Keys and signing are pure Rust; if a dependency ever demands unsafe here,
// that is a design smell to escalate, not a lint to relax.
#![forbid(unsafe_code)]
