//! Two user choices that are neither custody nor consensus: **where a
//! transaction is looked up**, and **whether a price is fetched at all**.
//!
//! Both are egress decisions, so both live here rather than in the render
//! layer: Dart states a preference, this module validates it, persists it, and
//! is the only thing that builds a URL or opens a socket (the `node_config`
//! discipline — a second, weaker guard on the Dart side is what INV-9's
//! reasoning forbids).
//!
//! | | explorer | rate |
//! |:--|:--|:--|
//! | what it can see | one txid or one address, and the IP that asked | that this wallet is running, and its IP |
//! | what it can lie about | **nothing we read back** — it is an outbound link | the price, which is the one claim consensus cannot check |
//! | off switch | replace the template (any host) | `enabled = false`, and the fetch refuses at this layer |
//!
//! That table is the INV-8 census row for both (D-207 clause a), and it is the
//! same sentence the endpoint rows print on the glass (BG-17 / ux-auditor 30).
//!
//! **Why the explorer is a template and not a vendor list.** A list only we
//! can edit is not a sovereignty decision (D-207, amending D-192's closed
//! two-vendor enum). Two audited defaults ship; either may be replaced with
//! any `https://` URL carrying the placeholder.
//!
//! Persistence seeds `node_config`'s idiom rather than inventing a third one:
//! JSON, infallible load, **durable** write. Durability is load-bearing on
//! both files and in the same direction — a lost `rate.config` reverts to
//! `enabled = true`, so an ENOSPC or a power loss would silently undo a user's
//! decision to stop talking to a price vendor.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::error::{ChainError, Result};
use crate::history_fill::write_json_durable;

const EXPLORER_CONFIG_FILE: &str = "explorer.config";
const RATE_CONFIG_FILE: &str = "rate.config";

/// The placeholder a transaction template must carry.
pub const TXID_PLACEHOLDER: &str = "{txid}";

/// The placeholder an address template must carry.
pub const ADDRESS_PLACEHOLDER: &str = "{address}";

/// Longest template we will store. Generous for a real explorer path and short
/// enough that a pasted essay is refused rather than persisted.
const MAX_TEMPLATE_LEN: usize = 300;

/// Per-request deadline for the price fetch. `workflow-http`'s native path sets
/// no timeout of its own; an unreachable source must fail the rate honestly
/// (rendering `—`), never hang the caller (`history_fill::PAGE_TIMEOUT`, same
/// reasoning, same number).
const RATE_TIMEOUT: Duration = Duration::from_secs(10);

/// The price source shipped as the default (D-191 chose the vendor; the law
/// names only the shape — D-207 moved the name out of constitutional text).
///
/// The full URL is the setting, not a base, because the exact string that
/// leaves the phone is the thing being consented to. A replacement must answer
/// `{"price": <number>}` in **USD**; that response shape is the contract, and
/// it is stated on the row that offers the field.
pub const DEFAULT_RATE_ENDPOINT: &str = "https://api.kaspa.org/info/price";

/// A price this app will not render. Not a clamp — a **refusal**, so the glass
/// falls back to BG-5's honest `—` rather than painting a balance nobody
/// vouches for. The endpoint is user-replaceable by law, which is exactly why
/// a hostile or misconfigured one must not be able to state that a wallet
/// holds ten billion dollars.
const MAX_SANE_USD_PER_KAS: f64 = 1_000_000.0;

// ── The explorer ───────────────────────────────────────────────────────────

/// One audited default, offered as a starting point and freely replaceable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExplorerDefault {
    /// The host, as the disclosure names it.
    pub name: &'static str,
    pub tx_template: &'static str,
    pub address_template: &'static str,
}

/// The two shipped defaults, route shapes **verified against the explorers
/// themselves** on 2026-08-27 rather than recalled:
/// `explorer.kaspa.org` runs `lAmeR1/kaspa-explorer`, whose router declares
/// `/txs/:id` and `/addresses/:addr` (`src/App.js`); `kaspa.stream` publishes
/// `/transactions/<hash>` and `/addresses/<addr>` pages. `kas.fyi` — which the
/// design export named — **has shut down**, and a wallet handing you a dead
/// link is worse than one offering none (D-192).
pub const EXPLORER_DEFAULTS: [ExplorerDefault; 2] = [
    ExplorerDefault {
        name: "explorer.kaspa.org",
        tx_template: "https://explorer.kaspa.org/txs/{txid}",
        address_template: "https://explorer.kaspa.org/addresses/{address}",
    },
    ExplorerDefault {
        name: "kaspa.stream",
        tx_template: "https://kaspa.stream/transactions/{txid}",
        address_template: "https://kaspa.stream/addresses/{address}",
    },
];

/// Where "view this in an explorer" goes. Two templates, because a transaction
/// page and an address page are different paths on every explorer that has
/// both — one template with two placeholders could serve neither.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ExplorerConfig {
    pub tx_template: String,
    pub address_template: String,
}

impl Default for ExplorerConfig {
    fn default() -> Self {
        Self {
            tx_template: EXPLORER_DEFAULTS[0].tx_template.to_string(),
            address_template: EXPLORER_DEFAULTS[0].address_template.to_string(),
        }
    }
}

impl ExplorerConfig {
    /// Infallible, with three outcomes and only one of them substitutes ours.
    ///
    /// - **Absent** — nothing was ever chosen, so the shipped default is the
    ///   honest answer.
    /// - **Unreadable** — the bytes are not a config; there is no user choice
    ///   left in the file to preserve, so the default it is.
    /// - **Parses, but a template no longer validates** — the strings are
    ///   **kept as stored**. [`Self::tx_url`] and [`Self::address_url`]
    ///   re-validate and will refuse, so nothing half-read reaches a browser
    ///   intent, and the row can show the user what was refused.
    ///
    /// The third case used to return ours, which is the exact outcome
    /// [`RateConfig::load`] refuses ten lines below — *a user who replaced the
    /// vendor must never be silently returned to ours* — with the same
    /// argument reaching the opposite conclusion in the same file
    /// (`wallet-security-auditor`). A silent substitution here would send a
    /// txid to `explorer.kaspa.org` for a user who had deliberately pointed it
    /// at their own instance.
    pub fn load(dir: &Path) -> Self {
        let Ok(bytes) = std::fs::read(dir.join(EXPLORER_CONFIG_FILE)) else {
            return Self::default();
        };
        let Ok(config) = serde_json::from_slice::<Self>(&bytes) else {
            log::warn!(
                "prefs: the stored explorer choice is unreadable ({} bytes) — using the default",
                bytes.len()
            );
            return Self::default();
        };
        if let Err(e) = config.validated() {
            log::warn!(
                "prefs: a stored explorer template is not usable ({e}) — kept, and every link                  through it is refused until it is fixed"
            );
        }
        config
    }

    /// Persist the choice. Validated here, so a rejected save leaves the
    /// previous templates untouched (the `NodeConfig::save` contract).
    pub fn save(&self, dir: &Path) -> Result<()> {
        let config = self.validated()?;
        write_json_durable(&dir.join(EXPLORER_CONFIG_FILE), &config)
    }

    pub fn path(dir: &Path) -> PathBuf {
        dir.join(EXPLORER_CONFIG_FILE)
    }

    fn validated(&self) -> Result<Self> {
        Ok(Self {
            tx_template: validate_template(&self.tx_template, TXID_PLACEHOLDER)?,
            address_template: validate_template(&self.address_template, ADDRESS_PLACEHOLDER)?,
        })
    }

    /// The URL this config would open for `txid` — built HERE, so the render
    /// layer never concatenates one.
    pub fn tx_url(&self, txid: &str) -> Result<String> {
        Ok(validate_template(&self.tx_template, TXID_PLACEHOLDER)?
            .replace(TXID_PLACEHOLDER, &checked_subject(txid)?))
    }

    /// The URL this config would open for `address`.
    pub fn address_url(&self, address: &str) -> Result<String> {
        Ok(
            validate_template(&self.address_template, ADDRESS_PLACEHOLDER)?
                .replace(ADDRESS_PLACEHOLDER, &checked_subject(address)?),
        )
    }
}

/// A template is a URL we will hand to a browser, so the bar is a URL's.
///
/// The placeholder must sit in the **path**, never in the authority: a
/// template like `https://{txid}.example` would send the identifier as a DNS
/// query to whoever runs that suffix, which is a leak the user cannot see in
/// the string they typed.
pub fn validate_template(template: &str, placeholder: &str) -> Result<String> {
    let t = template.trim();
    if t.is_empty() {
        return Err(ChainError::Message("the explorer link is empty".into()));
    }
    if t.len() > MAX_TEMPLATE_LEN {
        return Err(ChainError::Message(format!(
            "the explorer link is longer than {MAX_TEMPLATE_LEN} characters"
        )));
    }
    // Whitespace and control bytes: the ledger-row forgery guard `link.rs`
    // applies to node URLs, for the same reason — a string with a newline in
    // it prints as two lines in a log and as one link on a screen.
    if t.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(ChainError::Message(
            "the explorer link cannot contain spaces or line breaks".into(),
        ));
    }
    let Some(rest) = t.strip_prefix("https://") else {
        return Err(ChainError::Message(
            "the explorer link must start with https://".into(),
        ));
    };
    let (authority, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, ""),
    };
    if authority.is_empty() {
        return Err(ChainError::Message(
            "the explorer link has no address after https://".into(),
        ));
    }
    // Credentials in an explorer URL would be carried into every log line and
    // shown on the settings row — the same refusal `validate_node_url` makes.
    if authority.contains('@') {
        return Err(ChainError::Message(
            "the explorer link cannot carry a username or password".into(),
        ));
    }
    if !path.contains(placeholder) {
        return Err(ChainError::Message(format!(
            "the explorer link must contain {placeholder} after the site address"
        )));
    }
    // Exactly one substitution point, and only its own: two `{txid}`s in one
    // template is a typo we can name, and an `{address}` in the transaction
    // link is a template that would silently open the wrong page.
    if t.matches(placeholder).count() != 1 {
        return Err(ChainError::Message(format!(
            "the explorer link must contain {placeholder} exactly once"
        )));
    }
    let other = if placeholder == TXID_PLACEHOLDER {
        ADDRESS_PLACEHOLDER
    } else {
        TXID_PLACEHOLDER
    };
    if t.contains(other) {
        return Err(ChainError::Message(format!(
            "this link takes {placeholder}, not {other}"
        )));
    }
    Ok(t.to_string())
}

/// What may be substituted into a template: a txid or a Kaspa address, and
/// nothing that could re-point the URL.
///
/// Both are already public chain data, so the risk is not disclosure but
/// **shape** — a subject carrying `/`, `?`, `#` or `%` could turn a path
/// segment into a different path, a query, or a fragment on a host the user
/// chose for a different purpose.
fn checked_subject(subject: &str) -> Result<String> {
    let s = subject.trim();
    if s.is_empty() {
        return Err(ChainError::Message("nothing to look up".into()));
    }
    if s.len() > 128 {
        return Err(ChainError::Message("that identifier is too long".into()));
    }
    if !s
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == ':' || c == '-' || c == '_')
    {
        return Err(ChainError::Message(
            "that identifier is not a transaction id or an address".into(),
        ));
    }
    Ok(s.to_string())
}

// ── The rate ───────────────────────────────────────────────────────────────

/// Whether a price is fetched, and from where.
///
/// **Default ON** (founder call, 2026-08-27), which is the one place this
/// module concedes something to convenience: the app opens an egress the user
/// did not individually ask for. Everything INV-8's carve-out demands is still
/// true — the endpoint is named where it is chosen, replaceable, and switched
/// off in one tap; the price never reaches a fee, a spend or a signing
/// surface; and the wallet is fully correct with it off.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RateConfig {
    pub enabled: bool,
    pub endpoint: String,
}

impl Default for RateConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            endpoint: DEFAULT_RATE_ENDPOINT.to_string(),
        }
    }
}

impl RateConfig {
    /// Infallible, and it defaults ON — see [`RateConfig::save`] for why the
    /// write is durable in spite of that.
    pub fn load(dir: &Path) -> Self {
        let Ok(bytes) = std::fs::read(dir.join(RATE_CONFIG_FILE)) else {
            return Self::default();
        };
        let Ok(config) = serde_json::from_slice::<Self>(&bytes) else {
            log::warn!(
                "prefs: the stored rate choice is unreadable ({} bytes) — using the default",
                bytes.len()
            );
            return Self::default();
        };
        match validate_rate_endpoint(&config.endpoint) {
            Ok(endpoint) => Self {
                enabled: config.enabled,
                endpoint,
            },
            Err(e) => {
                // The endpoint is unusable, so the honest state is OFF rather
                // than "on, pointed at the default": a user who replaced the
                // vendor must never be silently returned to ours.
                log::warn!("prefs: stored rate endpoint rejected ({e}) — the rate is off");
                Self {
                    enabled: false,
                    endpoint: config.endpoint,
                }
            }
        }
    }

    /// Persist the posture. **Durable**, and the direction of the failure is
    /// the argument: the default is ON, so a truncated write turns a user's
    /// decision to stop talking to a price vendor back into a decision to
    /// start (`NodeConfig::save`'s reasoning, with the sign flipped).
    pub fn save(&self, dir: &Path) -> Result<()> {
        let config = Self {
            enabled: self.enabled,
            endpoint: validate_rate_endpoint(&self.endpoint)?,
        };
        write_json_durable(&dir.join(RATE_CONFIG_FILE), &config)
    }

    pub fn path(dir: &Path) -> PathBuf {
        dir.join(RATE_CONFIG_FILE)
    }
}

/// The price source is a URL we will GET. `https` only: a price fetched in
/// cleartext is a plaintext announcement of which app is running, to every hop
/// on the path, in exchange for a number nobody can verify anyway.
pub fn validate_rate_endpoint(endpoint: &str) -> Result<String> {
    let e = endpoint.trim();
    if e.is_empty() {
        return Err(ChainError::Message("the rate source is empty".into()));
    }
    if e.len() > MAX_TEMPLATE_LEN {
        return Err(ChainError::Message(format!(
            "the rate source is longer than {MAX_TEMPLATE_LEN} characters"
        )));
    }
    if e.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(ChainError::Message(
            "the rate source cannot contain spaces or line breaks".into(),
        ));
    }
    let Some(rest) = e.strip_prefix("https://") else {
        return Err(ChainError::Message(
            "the rate source must start with https://".into(),
        ));
    };
    let authority = rest.split('/').next().unwrap_or("");
    if authority.is_empty() {
        return Err(ChainError::Message(
            "the rate source has no address after https://".into(),
        ));
    }
    if authority.contains('@') {
        return Err(ChainError::Message(
            "the rate source cannot carry a username or password".into(),
        ));
    }
    Ok(e.to_string())
}

/// What a price source is required to answer. One field; everything else in
/// the body is ignored, so a source that returns a richer object still works.
#[derive(Debug, Deserialize)]
struct PriceResponse {
    price: f64,
}

/// One USD-per-KAS price — or `None`, because the user switched the rate off.
///
/// **It takes the config, not an endpoint, and that is the off switch.** A
/// `&str` parameter put the guard in the caller and left this function able to
/// open a socket for a disabled rate; the bridge module then documented an
/// enforcement it did not have, which is a claim rather than a mechanism
/// (`consensus-auditor`, this sitting). Taking [`RateConfig`] makes "off"
/// true for every caller that will ever exist, including the ones nobody has
/// written yet.
///
/// **Never a fabricated number**: a missing, non-finite, zero, negative or
/// absurd price is an error here so that the glass renders BG-5's `—` instead
/// of a figure nobody stands behind.
pub async fn fetch_usd_per_kas(config: &RateConfig) -> Result<Option<f64>> {
    if !config.enabled {
        return Ok(None);
    }
    let url = validate_rate_endpoint(&config.endpoint)?;
    let response =
        match tokio::time::timeout(RATE_TIMEOUT, workflow_http::get_json::<PriceResponse>(&url))
            .await
        {
            Ok(Ok(value)) => value,
            Ok(Err(e)) => return Err(ChainError::Message(format!("rate request failed: {e}"))),
            Err(_) => return Err(ChainError::Message("rate request timed out (10 s)".into())),
        };
    check_price(response.price).map(Some)
}

/// The sanity gate, split out because it is the part worth testing without a
/// network.
fn check_price(price: f64) -> Result<f64> {
    if !price.is_finite() || price <= 0.0 {
        return Err(ChainError::Message(
            "the rate source did not return a usable price".into(),
        ));
    }
    if price > MAX_SANE_USD_PER_KAS {
        return Err(ChainError::Message(
            "the rate source returned a price outside any believable range".into(),
        ));
    }
    Ok(price)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kv-prefs-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn both_shipped_explorer_defaults_are_valid_templates() {
        // The defaults are the one part of this no user can fix for us: a
        // shipped template that fails our own validator would hand every new
        // wallet a dead link (D-192's scar, in reverse).
        for d in EXPLORER_DEFAULTS {
            validate_template(d.tx_template, TXID_PLACEHOLDER).unwrap();
            validate_template(d.address_template, ADDRESS_PLACEHOLDER).unwrap();
        }
        validate_rate_endpoint(DEFAULT_RATE_ENDPOINT).unwrap();
    }

    #[test]
    fn a_template_must_be_https_and_carry_its_own_placeholder_in_the_path() {
        for bad in [
            "",
            "   ",
            "http://explorer.example/txs/{txid}", // cleartext
            "explorer.example/txs/{txid}",        // no scheme
            "https://explorer.example/txs/",      // no placeholder
            "https://{txid}.explorer.example/",   // placeholder in the authority
            "https://explorer.example/{txid}/{txid}", // twice
            "https://explorer.example/txs/{address}", // the wrong subject
            "https://user:pw@explorer.example/t/{txid}", // credentials
            "https://explorer.example/txs/{txid} extra", // whitespace
            "https://explorer.example/txs/{txid}\nforge", // control byte
        ] {
            assert!(
                validate_template(bad, TXID_PLACEHOLDER).is_err(),
                "{bad:?} must be refused"
            );
        }
        // The control: the honest form passes, and trims.
        assert_eq!(
            validate_template("  https://explorer.example/txs/{txid}  ", TXID_PLACEHOLDER).unwrap(),
            "https://explorer.example/txs/{txid}"
        );
    }

    #[test]
    fn a_url_is_built_only_from_a_subject_that_cannot_repoint_it() {
        let config = ExplorerConfig::default();
        assert_eq!(
            config.tx_url(&"a1b2".repeat(16)).unwrap(),
            format!("https://explorer.kaspa.org/txs/{}", "a1b2".repeat(16))
        );
        assert_eq!(
            config.address_url("kaspa:qqtest-1_2").unwrap(),
            "https://explorer.kaspa.org/addresses/kaspa:qqtest-1_2"
        );
        for bad in [
            "",
            "../../admin",
            "abc?next=evil",
            "abc#frag",
            "abc%2f..",
            "abc/def",
            "spaced id",
        ] {
            assert!(config.tx_url(bad).is_err(), "{bad:?} must be refused");
        }
    }

    #[test]
    fn a_users_explorer_is_never_silently_replaced_with_ours() {
        // The rule `RateConfig::load` states and this one used to break: a
        // stored choice that no longer validates is KEPT, and every link
        // through it refuses, so the user is told rather than redirected.
        let dir = tmp("explorer-kept");
        std::fs::write(
            ExplorerConfig::path(&dir),
            br#"{"tx_template":"http://mine.example/t/{txid}","address_template":"https://mine.example/a/{address}"}"#,
        )
        .unwrap();
        let loaded = ExplorerConfig::load(&dir);
        assert_eq!(
            loaded.tx_template, "http://mine.example/t/{txid}",
            "their template is kept, so the row can show what was refused"
        );
        assert!(
            loaded.tx_url(&"ab".repeat(32)).is_err(),
            "and nothing is built from it"
        );
        // The half that still works keeps working: one bad template must not
        // take the other down with it.
        assert!(loaded.address_url("kaspa:qqtest").is_ok());
    }

    #[test]
    fn an_explorer_choice_survives_a_round_trip_and_a_corrupt_file_does_not_break_it() {
        let dir = tmp("explorer");
        assert_eq!(ExplorerConfig::load(&dir), ExplorerConfig::default());

        let chosen = ExplorerConfig {
            tx_template: EXPLORER_DEFAULTS[1].tx_template.to_string(),
            address_template: EXPLORER_DEFAULTS[1].address_template.to_string(),
        };
        chosen.save(&dir).unwrap();
        assert_eq!(ExplorerConfig::load(&dir), chosen);

        // A rejected save leaves the stored choice standing.
        assert!(ExplorerConfig {
            tx_template: "http://nope.example/{txid}".into(),
            address_template: chosen.address_template.clone(),
        }
        .save(&dir)
        .is_err());
        assert_eq!(ExplorerConfig::load(&dir), chosen);

        // Corrupt reads as the default — there is no choice left in the file
        // to preserve. Well-formed-but-invalid does NOT: see
        // `a_users_explorer_is_never_silently_replaced_with_ours`.
        std::fs::write(ExplorerConfig::path(&dir), b"{not json").unwrap();
        assert_eq!(ExplorerConfig::load(&dir), ExplorerConfig::default());
        std::fs::write(
            ExplorerConfig::path(&dir),
            br#"{"tx_template":"javascript:alert(1){txid}","address_template":"https://e.example/{address}"}"#,
        )
        .unwrap();
        let kept = ExplorerConfig::load(&dir);
        assert_eq!(kept.tx_template, "javascript:alert(1){txid}");
        assert!(
            kept.tx_url(&"ab".repeat(32)).is_err(),
            "kept, and refused — never opened"
        );
    }

    #[test]
    fn the_rate_is_on_by_default_and_off_survives_the_round_trip() {
        let dir = tmp("rate");
        assert_eq!(RateConfig::load(&dir), RateConfig::default());
        assert!(
            RateConfig::load(&dir).enabled,
            "on by default is the founder's call (2026-08-27), not an accident"
        );

        let off = RateConfig {
            enabled: false,
            endpoint: DEFAULT_RATE_ENDPOINT.to_string(),
        };
        off.save(&dir).unwrap();
        assert_eq!(RateConfig::load(&dir), off, "off must survive a restart");
    }

    #[test]
    fn an_unusable_stored_rate_endpoint_reads_as_off_never_as_ours() {
        let dir = tmp("rate-bad");
        std::fs::write(
            RateConfig::path(&dir),
            br#"{"enabled":true,"endpoint":"http://cleartext.example/price"}"#,
        )
        .unwrap();
        let loaded = RateConfig::load(&dir);
        assert!(!loaded.enabled, "a broken source is off, not on");
        assert_eq!(
            loaded.endpoint, "http://cleartext.example/price",
            "their endpoint is kept so the row can show what was refused"
        );
    }

    #[test]
    fn a_rate_endpoint_must_be_an_https_url_without_credentials() {
        for bad in [
            "",
            "api.kaspa.org/info/price",
            "http://api.kaspa.org/info/price",
            "https://",
            "https://user:pw@api.kaspa.org/info/price",
            "https://api.kaspa.org/info/price with space",
        ] {
            assert!(
                validate_rate_endpoint(bad).is_err(),
                "{bad:?} must be refused"
            );
        }
        assert_eq!(
            validate_rate_endpoint(" https://price.example/p ").unwrap(),
            "https://price.example/p"
        );
    }

    #[test]
    fn a_price_that_is_not_a_price_is_an_error_never_a_number_on_the_glass() {
        assert_eq!(check_price(0.02864504).unwrap(), 0.02864504);
        for bad in [
            0.0,
            -1.0,
            f64::NAN,
            f64::INFINITY,
            f64::NEG_INFINITY,
            MAX_SANE_USD_PER_KAS * 2.0,
        ] {
            assert!(check_price(bad).is_err(), "{bad} must be refused");
        }
        // The boundary belongs to the believable side.
        assert!(check_price(MAX_SANE_USD_PER_KAS).is_ok());
    }

    #[tokio::test]
    async fn a_disabled_rate_opens_no_socket_and_says_so() {
        // The endpoint here is deliberately UNREACHABLE and deliberately
        // valid: if the switch were checked after the dial rather than before
        // it, this test would hang for the ten-second deadline instead of
        // returning. It runs on a bare executor with no network at all.
        let off = RateConfig {
            enabled: false,
            endpoint: "https://127.0.0.1:1/price".to_string(),
        };
        let answer = fetch_usd_per_kas(&off).await;
        assert!(
            matches!(answer, Ok(None)),
            "off must refuse before it dials"
        );
    }

    #[test]
    fn the_response_shape_is_the_one_the_default_source_actually_answers() {
        // Measured against `GET https://api.kaspa.org/info/price` on
        // 2026-08-27: `{"price":0.02864504}`. Pinned as a parse test so a
        // future edit to the DTO reds here rather than on a user's phone.
        let parsed: PriceResponse = serde_json::from_slice(br#"{"price":0.02864504}"#).unwrap();
        assert_eq!(check_price(parsed.price).unwrap(), 0.02864504);
        // A richer body still parses — a replacement source may say more.
        let richer: PriceResponse =
            serde_json::from_slice(br#"{"price":0.03,"currency":"USD","ts":1}"#).unwrap();
        assert_eq!(richer.price, 0.03);
        // A body with no price at all is a parse failure, not a zero.
        assert!(serde_json::from_slice::<PriceResponse>(br#"{"usd":0.03}"#).is_err());
    }
}
