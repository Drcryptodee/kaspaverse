//! Two user choices that reach the network: the explorer link, and the price.
//!
//! DTOs only (plain structs — the `dag.rs` shape note); `u64` arrives in Dart
//! as `BigInt` (L3); errors cross as `Result<_, AppError>`, never a panic
//! (INV-2). Nothing here touches key material: an explorer template and a
//! price URL are public strings, and the subjects substituted into them —
//! a txid, a receive address — are already on a public ledger (INV-3).
//!
//! **The off switch is structural, one layer down.** `fetch_usd_per_kas` takes
//! the stored [`RateConfig`] rather than an endpoint string and answers `None`
//! without opening a socket when the rate is disabled — so "off" holds for
//! every caller that will ever exist, not only for the one below. It was a
//! `&str` parameter with the guard here for one revision, and this comment
//! asserted an enforcement the code did not have (`consensus-auditor`).

use std::path::PathBuf;

use kaspaverse_chain::prefs::{
    fetch_usd_per_kas, ExplorerConfig, RateConfig, DEFAULT_RATE_ENDPOINT, EXPLORER_DEFAULTS,
};

use crate::api::error::AppError;

fn prefs_dir() -> Result<PathBuf, AppError> {
    super::vault::prefs_dir()
}

/// One shipped explorer, offered as a starting point. Both are replaceable —
/// a list only we can edit is not a sovereignty decision (D-207).
#[derive(Clone)]
pub struct ExplorerDefaultDto {
    pub name: String,
    pub tx_template: String,
    pub address_template: String,
}

/// The explorer choice, plus what the user could return to.
#[derive(Clone)]
pub struct ExplorerConfigDto {
    pub tx_template: String,
    pub address_template: String,
    /// The audited defaults, in ship order. The row renders these as one-tap
    /// starting points beside the editable field.
    pub defaults: Vec<ExplorerDefaultDto>,
}

/// Read the explorer choice (file-backed; defaults to the first shipped one).
pub fn prefs_explorer_config() -> Result<ExplorerConfigDto, AppError> {
    let config = ExplorerConfig::load(&prefs_dir()?);
    Ok(ExplorerConfigDto {
        tx_template: config.tx_template,
        address_template: config.address_template,
        defaults: EXPLORER_DEFAULTS
            .iter()
            .map(|d| ExplorerDefaultDto {
                name: d.name.to_string(),
                tx_template: d.tx_template.to_string(),
                address_template: d.address_template.to_string(),
            })
            .collect(),
    })
}

/// Persist the explorer choice. Both templates are validated in Rust — the
/// render layer never parses or builds a URL — and a rejected save leaves the
/// previous choice untouched, so a typo cannot cost a user their explorer.
pub fn prefs_set_explorer_config(
    tx_template: String,
    address_template: String,
) -> Result<(), AppError> {
    let config = ExplorerConfig {
        tx_template,
        address_template,
    };
    config.save(&prefs_dir()?).map_err(AppError::chain)?;
    log::info!("prefs: explorer templates saved");
    Ok(())
}

/// The exact URL this wallet would open for `txid`.
///
/// Exposed because disclosure is only real if it is specific: the settings row
/// shows the resolved link rather than describing one, and the exit that
/// eventually opens it (UX-5) calls the same function.
pub fn prefs_explorer_tx_url(txid: String) -> Result<String, AppError> {
    ExplorerConfig::load(&prefs_dir()?)
        .tx_url(&txid)
        .map_err(AppError::chain)
}

/// The exact URL this wallet would open for `address`.
pub fn prefs_explorer_address_url(address: String) -> Result<String, AppError> {
    ExplorerConfig::load(&prefs_dir()?)
        .address_url(&address)
        .map_err(AppError::chain)
}

/// The rate posture, plus the endpoint a user can return to.
#[derive(Clone)]
pub struct RateConfigDto {
    pub enabled: bool,
    pub endpoint: String,
    pub default_endpoint: String,
}

/// Read the rate posture (file-backed; ON by default — founder call,
/// 2026-08-27, recorded with its INV-8 concession in the ledger).
pub fn prefs_rate_config() -> Result<RateConfigDto, AppError> {
    let config = RateConfig::load(&prefs_dir()?);
    Ok(RateConfigDto {
        enabled: config.enabled,
        endpoint: config.endpoint,
        default_endpoint: DEFAULT_RATE_ENDPOINT.to_string(),
    })
}

/// Persist the rate posture. An empty endpoint means "back to the shipped
/// default" rather than an error — the field's clear button has to lead
/// somewhere (`transport_set_fill_config`'s contract).
pub fn prefs_set_rate_config(enabled: bool, endpoint: String) -> Result<(), AppError> {
    let endpoint = endpoint.trim().to_string();
    let endpoint = if endpoint.is_empty() {
        DEFAULT_RATE_ENDPOINT.to_string()
    } else {
        endpoint
    };
    RateConfig { enabled, endpoint }
        .save(&prefs_dir()?)
        .map_err(AppError::chain)?;
    log::info!("prefs: rate config saved (enabled={enabled}, endpoint set)");
    Ok(())
}

/// One price, fetched now — or `None` because the user switched the rate off.
///
/// `usd_per_kas` is a **display** number and nothing else: it never prices a
/// fee, sizes a spend, or reaches a signing surface (INV-8's carve-out, BG-5).
/// `fetched_at_unix_ms` is stamped here so the age the glass shows is the age
/// of the fetch, not of the Dart frame that rendered it.
#[derive(Clone)]
pub struct RateQuoteDto {
    pub usd_per_kas: f64,
    pub fetched_at_unix_ms: u64,
    /// The endpoint this price came from — the source the disclosure names.
    pub source: String,
}

/// Fetch one price, or `None` because the rate is off — a refusal the layer
/// below makes, before any socket exists.
///
/// An error means *no usable price*, and the caller must render `—` rather
/// than a stale-but-confident number of its own invention. A caller holding an
/// older quote may keep showing it **with its age** (BG-8's dimmed-cached-truth
/// rule, applied to the one datum consensus cannot check).
pub async fn prefs_rate_quote() -> Result<Option<RateQuoteDto>, AppError> {
    let config = RateConfig::load(&prefs_dir()?);
    let Some(usd_per_kas) = fetch_usd_per_kas(&config).await.map_err(AppError::chain)? else {
        // Off. No socket was opened to learn that.
        return Ok(None);
    };
    Ok(Some(RateQuoteDto {
        usd_per_kas,
        fetched_at_unix_ms: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0),
        source: config.endpoint,
    }))
}
