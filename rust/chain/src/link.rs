//! Link-layer trust: endpoint health, race-to-connect, stall escalation (V3,
//! D-073/D-081).
//!
//! Why this module exists (source-convicted at the pinned crates, 2026-07-11):
//! the wRPC client's websocket connect loop CAPTURES its original
//! `ConnectOptions` and re-resolves the URL from them after every
//! established-connection drop — `ConnectStrategy::Fallback` only exits that
//! loop on a FAILED dial, never after a drop (`workflow-websocket-0.18.0`
//! `client/native.rs:161-251`). A connect issued with an explicit URL therefore
//! leaves behind a loop loyal to that URL forever, and the loop's `reconnect`
//! flag is shared per client, so a second `connect()` re-arms the first loop:
//! two connect authorities race (the V2 sitting's doubled `Connected`,
//! findings register items 9 + 11).
//!
//! The cure is ownership, not configuration: the app is the ONE reconnect
//! authority. Every shared-socket connect is an explicit-URL, `Fallback`,
//! blocking dial issued by the monitor's race task ([`race`] picks the URL);
//! a drop is answered by killing any surviving ws loop and racing again.
//! This module holds the pieces the monitor's race task composes:
//!
//! - [`EndpointHealth`] — the demotion ledger (strikes → cooldown; public
//!   wss URLs only, INV-3). Strikes COMMIT only when a race proves the rest
//!   of the network reachable — a phone in a tunnel never demotes an
//!   innocent node.
//! - [`probe_endpoint`] / [`race`] — N parallel `Resolver::get_node` fetches
//!   (the API returns ONE node per fetch) + parallel dials on ephemeral
//!   clients; first HEALTHY endpoint (synced, utxo-indexed, right network)
//!   wins. Probes never serve reads — D-005's single view socket holds.
//! - [`SignedTxRetention`] + [`escalate_stalled_tx`] — on the tracker's
//!   one-shot `Stalled` signal, resubmit the already-signed tx via one
//!   freshly resolved node. Duplicate submission is a clean idempotent
//!   error at the node (mempool/errors strings pinned in
//!   [`is_idempotent_submit_error`]); no fan-out, no RBF (D-008-deferred).
//!
//! Thresholds are PROVISIONAL (V6 owns tuning against sitting data).

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

use kaspa_wrpc_client::prelude::{
    ConnectOptions, ConnectStrategy, KaspaRpcClient, NetworkId, Resolver, RpcApi, RpcTransaction,
    WrpcEncoding,
};
use tokio::task::JoinSet;

use crate::error::{ChainError, Result};

/// Strikes within this window accumulate; an older strike restarts the count.
pub const STRIKE_WINDOW_SECS: u64 = 600;
/// Strikes at/above this within the window demote the endpoint.
pub const DEMOTE_AT_STRIKES: u32 = 2;
/// How long a demoted endpoint sits out of candidacy.
pub const DEMOTION_COOLDOWN_SECS: u64 = 600;
/// A connection that survives this long clears its endpoint's strikes.
pub const CLEAN_RUN_SECS: u64 = 300;
/// Strikes on the SAME endpoint within this window are one incident (a flap's
/// event storm — the drop, a phantom redial's kill, the race's cleanup — must
/// count once, not once per event).
pub const STRIKE_DEDUP_SECS: u64 = 10;
/// A pending strike older than this never commits: the network-alive evidence
/// (the next successful connect) arrived too late to convict the endpoint —
/// a phone that spent minutes in a tunnel blames no one (control-group rule).
pub const PENDING_STRIKE_TTL_SECS: u64 = 30;

/// Per-endpoint health record (all public data: a wss URL + counters).
#[derive(Debug, Clone, PartialEq, Eq)]
struct HealthRecord {
    strikes: u32,
    last_strike_unix: u64,
    demoted_until_unix: u64,
}

/// The demotion ledger — finding 11's cure. Loaded from / persisted to an
/// app-private file beside the endpoint cache (best-effort; a corrupt or
/// missing file is an empty ledger, never an error).
#[derive(Debug, Default)]
pub struct EndpointHealth {
    records: HashMap<String, HealthRecord>,
}

impl EndpointHealth {
    /// Load the ledger. Missing file / corrupt lines are skipped silently —
    /// health data is advisory, never load-bearing for connectivity.
    pub fn load(path: &Path) -> Self {
        let mut records = HashMap::new();
        if let Ok(text) = std::fs::read_to_string(path) {
            for line in text.lines() {
                let mut parts = line.split('\t');
                let (Some(url), Some(s), Some(l), Some(d)) =
                    (parts.next(), parts.next(), parts.next(), parts.next())
                else {
                    continue;
                };
                if !(url.starts_with("wss://") || url.starts_with("ws://")) {
                    continue;
                }
                let (Ok(strikes), Ok(last), Ok(until)) = (s.parse(), l.parse(), d.parse()) else {
                    continue;
                };
                records.insert(
                    url.to_string(),
                    HealthRecord {
                        strikes,
                        last_strike_unix: last,
                        demoted_until_unix: until,
                    },
                );
            }
        }
        Self { records }
    }

    /// Best-effort persist (tab-separated lines, one URL each).
    pub fn save(&self, path: &Path) {
        let mut out = String::new();
        for (url, r) in &self.records {
            out.push_str(&format!(
                "{url}\t{}\t{}\t{}\n",
                r.strikes, r.last_strike_unix, r.demoted_until_unix
            ));
        }
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Err(e) = std::fs::write(path, out) {
            log::warn!("link: endpoint health write failed: {e}");
        }
    }

    /// Record a strike (drop, flap, failed dial, stall). Returns `true` if the
    /// endpoint is demoted as of this strike. A strike older than
    /// [`STRIKE_WINDOW_SECS`] restarts the count at 1; a strike within
    /// [`STRIKE_DEDUP_SECS`] of the last is the SAME incident and is ignored.
    pub fn strike(&mut self, url: &str, now_unix: u64) -> bool {
        let record = self.records.entry(url.to_string()).or_insert(HealthRecord {
            strikes: 0,
            last_strike_unix: 0,
            demoted_until_unix: 0,
        });
        if record.strikes > 0
            && now_unix.saturating_sub(record.last_strike_unix) < STRIKE_DEDUP_SECS
        {
            return record.demoted_until_unix > now_unix;
        }
        if now_unix.saturating_sub(record.last_strike_unix) > STRIKE_WINDOW_SECS {
            record.strikes = 0;
        }
        record.strikes += 1;
        record.last_strike_unix = now_unix;
        if record.strikes >= DEMOTE_AT_STRIKES {
            record.demoted_until_unix = now_unix + DEMOTION_COOLDOWN_SECS;
            log::warn!(
                "link: endpoint demoted for {DEMOTION_COOLDOWN_SECS}s after {} strike(s): {url}",
                record.strikes
            );
            true
        } else {
            false
        }
    }

    /// A connection survived [`CLEAN_RUN_SECS`] — the endpoint earned its
    /// strikes back.
    pub fn clean_run(&mut self, url: &str) {
        if let Some(record) = self.records.get_mut(url) {
            record.strikes = 0;
        }
    }

    pub fn is_demoted(&self, url: &str, now_unix: u64) -> bool {
        self.records
            .get(url)
            .is_some_and(|r| r.demoted_until_unix > now_unix)
    }

    /// URLs currently sitting out (for race candidate filtering).
    pub fn demoted_set(&self, now_unix: u64) -> HashSet<String> {
        self.records
            .iter()
            .filter(|(_, r)| r.demoted_until_unix > now_unix)
            .map(|(url, _)| url.clone())
            .collect()
    }
}

/// Sanitize NODE-CONTROLLED text before it enters logs or error strings: the
/// liblog lane is this project's audit-evidence lane (INV-10/L53), and a
/// malicious node's error text with embedded newlines could forge `kv-span`/
/// `glass:` lines. Control characters are stripped, length bounded.
pub fn sanitize_node_text(text: &str) -> String {
    text.chars().filter(|c| !c.is_control()).take(200).collect()
}

/// A healthy endpoint found by [`probe_endpoint`].
#[derive(Debug, Clone)]
pub struct ProbeOutcome {
    pub url: String,
    pub server_version: String,
    pub virtual_daa_score: u64,
}

/// Dial `url` on an EPHEMERAL client and health-check it via
/// `get_server_info`: synced, utxo-indexed, right network. The client is
/// disconnected and dropped before returning — probes never serve reads
/// (D-005: the one view socket is the monitor's shared client).
pub async fn probe_endpoint(
    url: &str,
    network_id: NetworkId,
    timeout: Duration,
) -> Result<ProbeOutcome> {
    let client =
        KaspaRpcClient::new_with_args(WrpcEncoding::Borsh, Some(url), None, Some(network_id), None)
            .map_err(|e| ChainError::Message(e.to_string()))?;
    let options = ConnectOptions {
        strategy: ConnectStrategy::Fallback,
        block_async_connect: true,
        connect_timeout: Some(timeout),
        ..Default::default()
    };
    let result: Result<ProbeOutcome> = async {
        client.connect(Some(options)).await.map_err(|e| {
            ChainError::Message(format!(
                "probe dial {url}: {}",
                sanitize_node_text(&e.to_string())
            ))
        })?;
        let info = tokio::time::timeout(timeout, client.get_server_info())
            .await
            .map_err(|_| ChainError::Message(format!("probe info {url}: timeout")))?
            .map_err(|e| {
                ChainError::Message(format!(
                    "probe info {url}: {}",
                    sanitize_node_text(&e.to_string())
                ))
            })?;
        // Full NetworkId compare (type AND suffix) — a testnet-10 build must
        // not accept a testnet-11 node as healthy (consensus-audit finding).
        if info.network_id != network_id {
            return Err(ChainError::Message(format!(
                "probe {url}: wrong network {}",
                info.network_id
            )));
        }
        if !info.is_synced {
            return Err(ChainError::Message(format!("probe {url}: not synced")));
        }
        if !info.has_utxo_index {
            return Err(ChainError::Message(format!("probe {url}: no utxo index")));
        }
        Ok(ProbeOutcome {
            url: url.to_string(),
            server_version: info.server_version,
            virtual_daa_score: info.virtual_daa_score,
        })
    }
    .await;
    let _ = client.disconnect().await;
    result
}

/// Race outcome: the winner (if any) plus every candidate URL whose probe
/// FAILED outright (dial error / unhealthy) — the monitor strikes those.
/// Candidates still in flight when a winner lands finish in a reaper (never
/// aborted — see the note in [`race`]) and are not counted as failures.
#[derive(Debug, Default)]
pub struct RaceOutcome {
    pub winner: Option<ProbeOutcome>,
    pub failed: Vec<String>,
}

/// Race-to-connect (V3 deliverable 1): the cached endpoint (if provided and
/// not demoted) starts dialing IMMEDIATELY — that is the fast path, it wins
/// every tie because resolver candidates first spend an HTTP round-trip on
/// `get_node` — while `fetches` parallel resolver fetches feed parallel
/// probes. First healthy endpoint wins; in-flight losers finish their
/// bounded probes in a detached reaper (aborting would leak ws loops).
///
/// `demoted` URLs never enter the race — UNLESS the cached endpoint and every
/// fetched node are all demoted and the race would be empty; connectivity
/// always beats hygiene, so demotion filtering degrades to advisory when it
/// would otherwise strand the wallet (the ledger heals as cooldowns lapse).
pub async fn race(
    resolver: &Resolver,
    network_id: NetworkId,
    cached: Option<String>,
    demoted: &HashSet<String>,
    fetches: usize,
    probe_timeout: Duration,
) -> RaceOutcome {
    let mut tasks: JoinSet<std::result::Result<ProbeOutcome, Option<String>>> = JoinSet::new();
    let mut entered: HashSet<String> = HashSet::new();

    let cached_allowed = cached
        .as_ref()
        .filter(|url| !demoted.contains(*url))
        .cloned();
    if let Some(url) = cached_allowed {
        entered.insert(url.clone());
        tasks.spawn(async move {
            probe_endpoint(&url, network_id, probe_timeout)
                .await
                .map_err(|e| {
                    log::info!("link: race probe failed (cached): {e}");
                    Some(url)
                })
        });
    }

    // Track URLs already dialing so duplicate resolver answers don't double-
    // dial. The resolver returns one node per fetch; fetches run in parallel.
    let seen = std::sync::Arc::new(Mutex::new(entered));
    for _ in 0..fetches {
        let resolver = resolver.clone();
        let demoted = demoted.clone();
        let seen = seen.clone();
        tasks.spawn(async move {
            let node = resolver
                .get_node(WrpcEncoding::Borsh, network_id)
                .await
                .map_err(|e| {
                    log::info!(
                        "link: resolver fetch failed: {}",
                        sanitize_node_text(&e.to_string())
                    );
                    None
                })?;
            let url = node.url;
            if demoted.contains(&url) {
                log::info!("link: race skipping demoted candidate {url}");
                return Err(None);
            }
            {
                let mut seen = seen
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if !seen.insert(url.clone()) {
                    return Err(None); // duplicate answer — someone's already dialing it
                }
            }
            probe_endpoint(&url, network_id, probe_timeout)
                .await
                .map_err(|e| {
                    log::info!("link: race probe failed: {e}");
                    Some(url)
                })
        });
    }

    let mut outcome = RaceOutcome::default();
    while let Some(joined) = tasks.join_next().await {
        match joined {
            Ok(Ok(winner)) => {
                outcome.winner = Some(winner);
                break;
            }
            Ok(Err(Some(failed_url))) => outcome.failed.push(failed_url),
            Ok(Err(None)) => {} // resolver miss / demoted / duplicate — not a node failure
            Err(_) => {}        // panicked probe task — nothing to record
        }
    }
    // NEVER abort in-flight losers (consensus-audit finding): a probe aborted
    // between its connect() and disconnect() leaks a DETACHED ws loop that
    // loyal-redials its node forever (the pinned client's loop holds its own
    // Arc; only disconnect() clears its reconnect flag, and the native
    // interface has no Drop). Losers are bounded (≤ PROBE_TIMEOUT) and
    // self-disconnect — a reaper drains them off the caller's path.
    if !tasks.is_empty() {
        tokio::spawn(async move { while tasks.join_next().await.is_some() {} });
    }
    outcome
}

/// How long an already-signed tx stays resubmittable after its submit.
/// Generous vs the tracker's 60 s stall + 120 s tombstone windows.
const RETAIN_TTL_MS: u64 = 10 * 60 * 1000;
/// Retention cap — matches a realistic burst of batch legs, evicts oldest.
const RETAIN_CAP: usize = 32;

/// Signed-tx retention for stall escalation (V3 deliverable 2). The send path
/// deposits every submitted leg's SIGNED `RpcTransaction` here (public data —
/// a broadcast tx; no key material, INV-1 untouched) together with the
/// SUBMIT-TIME endpoint URL — a later stall must strike the node that took the
/// submit, not whoever the socket re-raced to since (consensus-audit finding).
/// The escalation task `take`s it on the tracker's one-shot `Stalled` signal.
/// In-memory only: after an app restart there is nothing to resubmit —
/// escalation then logs an honest skip (the node itself rebroadcasts
/// High-priority txs ~30 s, so retention is belt-and-braces, not
/// custody-critical).
/// One retained leg: the signed wire form, the submit-time endpoint, and the
/// retention timestamp (ms) the TTL/cap pruning keys on.
type RetainedTx = (RpcTransaction, Option<String>, u64);

#[derive(Default)]
pub struct SignedTxRetention {
    map: Mutex<HashMap<String, RetainedTx>>,
}

impl SignedTxRetention {
    pub fn retain(
        &self,
        txid: &str,
        tx: RpcTransaction,
        submit_url: Option<String>,
        now_unix_ms: u64,
    ) {
        let mut map = self
            .map
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        map.retain(|_, (_, _, at)| now_unix_ms.saturating_sub(*at) <= RETAIN_TTL_MS);
        if map.len() >= RETAIN_CAP {
            if let Some(oldest) = map
                .iter()
                .min_by_key(|(_, (_, _, at))| *at)
                .map(|(k, _)| k.clone())
            {
                map.remove(&oldest);
            }
        }
        map.insert(txid.to_string(), (tx, submit_url, now_unix_ms));
    }

    /// One-shot take — pairs with the tracker's one-shot stall emission.
    /// Returns the signed tx + the endpoint it was submitted through.
    pub fn take(&self, txid: &str) -> Option<(RpcTransaction, Option<String>)> {
        self.map
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(txid)
            .map(|(tx, url, _)| (tx, url))
    }

    pub fn len(&self) -> usize {
        self.map
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// The node's OWN duplicate-submission texts (pinned `mining/errors/src/
/// mempool.rs`, surfaced through `RpcError::RejectedTransaction`): a resubmit
/// that races the original's acceptance or mempool copy fails with one of
/// these, and that failure means SUCCESS — the tx is already where we wanted
/// it. Matched as substrings of the transported error string (the wRPC layer
/// wraps, so exact equality is not available).
pub fn is_idempotent_submit_error(message: &str) -> bool {
    message.contains("already accepted by the consensus")
        || message.contains("is already in the mempool")
        || message.contains("is already in the orphan pool")
}

/// What the one escalation did (logged + span-marked by the caller's task).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EscalationOutcome {
    /// The fresh node took the resubmission.
    Resubmitted { via: String },
    /// The fresh node already knew the tx (idempotent duplicate) — equally
    /// good: the tx is in the network's hands.
    AlreadyKnown { via: String, detail: String },
}

/// Stall escalation: resolve ONE fresh node, dial it, resubmit the
/// already-signed tx through it (dial + submit only — the submit outcome IS
/// the health signal; no separate probe). No blanket fan-out; no RBF
/// (D-008-deferred). The caller strikes the SUBMIT-TIME endpoint and
/// guarantees the one-shot (the tracker emits `Stalled` at most once per
/// txid, and retention `take` is destructive).
pub async fn escalate_stalled_tx(
    resolver: &Resolver,
    network_id: NetworkId,
    txid: &str,
    tx: RpcTransaction,
    probe_timeout: Duration,
) -> Result<EscalationOutcome> {
    let node = resolver
        .get_node(WrpcEncoding::Borsh, network_id)
        .await
        .map_err(|e| {
            ChainError::Message(format!(
                "escalation resolver fetch: {}",
                sanitize_node_text(&e.to_string())
            ))
        })?;
    let url = node.url;
    let client = KaspaRpcClient::new_with_args(
        WrpcEncoding::Borsh,
        Some(&url),
        None,
        Some(network_id),
        None,
    )
    .map_err(|e| ChainError::Message(e.to_string()))?;
    let options = ConnectOptions {
        strategy: ConnectStrategy::Fallback,
        block_async_connect: true,
        connect_timeout: Some(probe_timeout),
        ..Default::default()
    };
    let result: Result<EscalationOutcome> = async {
        client.connect(Some(options)).await.map_err(|e| {
            ChainError::Message(format!(
                "escalation dial {url}: {}",
                sanitize_node_text(&e.to_string())
            ))
        })?;
        match tokio::time::timeout(probe_timeout, client.submit_transaction(tx, false)).await {
            Err(_) => Err(ChainError::Message(format!(
                "escalation submit {url}: timeout"
            ))),
            Ok(Ok(_)) => Ok(EscalationOutcome::Resubmitted { via: url.clone() }),
            Ok(Err(e)) => {
                let message = e.to_string();
                if is_idempotent_submit_error(&message) {
                    Ok(EscalationOutcome::AlreadyKnown {
                        via: url.clone(),
                        // Node-controlled text: sanitized before it can reach
                        // the evidence lane (wallet-security-audit finding).
                        detail: sanitize_node_text(&message),
                    })
                } else {
                    Err(ChainError::Message(format!(
                        "escalation submit {url} refused {txid}: {}",
                        sanitize_node_text(&message)
                    )))
                }
            }
        }
    }
    .await;
    let _ = client.disconnect().await;
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!("kv-link-{}-{name}", std::process::id()))
    }

    #[test]
    fn strikes_accumulate_and_demote_within_window() {
        let mut health = EndpointHealth::default();
        let url = "wss://nora.kaspa.stream/borsh";
        assert!(!health.strike(url, 1_000));
        assert!(!health.is_demoted(url, 1_000));
        // Second strike inside the window demotes.
        assert!(health.strike(url, 1_060));
        assert!(health.is_demoted(url, 1_060));
        assert!(health.is_demoted(url, 1_060 + DEMOTION_COOLDOWN_SECS - 1));
        // Cooldown lapses — candidacy restored.
        assert!(!health.is_demoted(url, 1_060 + DEMOTION_COOLDOWN_SECS + 1));
    }

    #[test]
    fn same_incident_strikes_dedup() {
        let mut health = EndpointHealth::default();
        let url = "wss://node.example/borsh";
        assert!(!health.strike(url, 1_000));
        // A phantom-kill echo 2 s later is the SAME incident — one strike.
        assert!(!health.strike(url, 1_002));
        assert!(!health.is_demoted(url, 1_002));
        // A real second flap 60 s later is a new incident — demoted.
        assert!(health.strike(url, 1_060));
    }

    #[test]
    fn stale_strike_restarts_the_count() {
        let mut health = EndpointHealth::default();
        let url = "wss://node.example/borsh";
        assert!(!health.strike(url, 1_000));
        // Far outside the window: count restarts at 1, no demotion.
        assert!(!health.strike(url, 1_000 + STRIKE_WINDOW_SECS + 10));
        assert!(!health.is_demoted(url, 1_000 + STRIKE_WINDOW_SECS + 10));
    }

    #[test]
    fn clean_run_clears_strikes() {
        let mut health = EndpointHealth::default();
        let url = "wss://node.example/borsh";
        assert!(!health.strike(url, 1_000));
        health.clean_run(url);
        // The next strike is a fresh first strike, not the demoting second.
        assert!(!health.strike(url, 1_010));
    }

    #[test]
    fn ledger_round_trips_and_skips_corrupt_lines() {
        let path = tmp("health");
        let _ = std::fs::remove_file(&path);

        let mut health = EndpointHealth::default();
        health.strike("wss://a.example/borsh", 5_000);
        health.strike("wss://a.example/borsh", 5_100); // demoted
        health.strike("wss://b.example/borsh", 6_000);
        health.save(&path);

        let loaded = EndpointHealth::load(&path);
        assert!(loaded.is_demoted("wss://a.example/borsh", 5_200));
        assert!(!loaded.is_demoted("wss://b.example/borsh", 6_100));
        assert_eq!(loaded.demoted_set(5_200).len(), 1);

        // Corrupt + non-ws lines are skipped, good lines survive.
        std::fs::write(
            &path,
            "garbage line\nhttps://evil.example\t9\t9\t9\nwss://c.example/borsh\t2\t7000\t99999\n",
        )
        .unwrap();
        let loaded = EndpointHealth::load(&path);
        assert!(loaded.is_demoted("wss://c.example/borsh", 8_000));
        assert!(!loaded.is_demoted("https://evil.example", 8));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn missing_ledger_is_empty_not_error() {
        let health = EndpointHealth::load(Path::new("/nonexistent/kv/health"));
        assert!(health.demoted_set(1).is_empty());
    }

    #[test]
    fn classifies_the_pins_duplicate_submit_texts_as_idempotent() {
        // Verbatim shapes from the pinned mining/errors/src/mempool.rs
        // (surfaced via RpcError::RejectedTransaction and stringified).
        assert!(is_idempotent_submit_error(
            "transaction abc123 was already accepted by the consensus"
        ));
        assert!(is_idempotent_submit_error(
            "transaction abc123 is already in the mempool"
        ));
        assert!(is_idempotent_submit_error(
            "orphan transaction abc123 is already in the orphan pool"
        ));
        // A genuine refusal is NOT idempotent — the caller must hear it.
        assert!(!is_idempotent_submit_error(
            "output 0 already spent by transaction def in the mempool"
        ));
        assert!(!is_idempotent_submit_error(
            "transaction abc123 is an orphan where orphans are disallowed"
        ));
        assert!(!is_idempotent_submit_error("storage mass exceeds limit"));
    }

    /// Minimal signed-shape stand-in (RpcTransaction has no Default upstream).
    fn dummy_tx() -> RpcTransaction {
        RpcTransaction {
            version: 0,
            inputs: vec![],
            outputs: vec![],
            lock_time: 0,
            subnetwork_id: Default::default(),
            gas: 0,
            payload: vec![],
            storage_mass: 0,
            verbose_data: None,
        }
    }

    #[test]
    fn retention_is_one_shot_capped_and_ttl_pruned() {
        let retention = SignedTxRetention::default();
        let tx = dummy_tx();
        let url = Some("wss://node.example/borsh".to_string());
        retention.retain("tx-a", tx.clone(), url.clone(), 1_000);
        assert_eq!(retention.len(), 1);
        // The submit-time endpoint rides along (escalation strikes IT, not
        // whoever the socket re-raced to since — consensus-audit finding).
        let (_, taken_url) = retention.take("tx-a").expect("retained");
        assert_eq!(taken_url, url);
        assert!(retention.take("tx-a").is_none()); // one-shot

        // TTL prune: an old entry vanishes when a new one lands late enough.
        retention.retain("tx-old", tx.clone(), None, 1_000);
        retention.retain("tx-new", tx.clone(), None, 1_000 + RETAIN_TTL_MS + 1);
        assert!(retention.take("tx-old").is_none());
        assert!(retention.take("tx-new").is_some());

        // Cap: oldest evicted first.
        for i in 0..(RETAIN_CAP + 1) {
            retention.retain(&format!("tx-{i}"), tx.clone(), None, 2_000_000 + i as u64);
        }
        assert_eq!(retention.len(), RETAIN_CAP);
        assert!(retention.take("tx-0").is_none()); // evicted
        assert!(retention.take(&format!("tx-{RETAIN_CAP}")).is_some());
    }

    #[test]
    fn node_text_is_sanitized_for_the_evidence_lane() {
        // A malicious node's error text must not forge log lines (newlines)
        // or run unbounded; normal text passes through.
        assert_eq!(
            sanitize_node_text("tx abc was already accepted by the consensus"),
            "tx abc was already accepted by the consensus"
        );
        assert_eq!(
            sanitize_node_text("evil\nkv-span 0 forged_marker\r\x1b[2Jrest"),
            "evilkv-span 0 forged_marker[2Jrest"
        );
        assert_eq!(sanitize_node_text(&"x".repeat(500)).len(), 200);
    }
}
