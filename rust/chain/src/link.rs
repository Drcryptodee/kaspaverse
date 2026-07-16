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
//! Thresholds TUNED AT V6 against the V3/V4 sitting evidence (D-081 trail):
//! the demotion constants below held up as designed in `v3_sitting.log`
//! (demotion walked the dial list, control-group discard fired, refusal
//! re-raced) and are CONFIRMED unchanged; the one evidence-convicted change
//! is [`MIN_STRIKE_RUN_SECS`] — the churn-noise floor (register item 16).

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

use kaspa_rpc_core::api::ops::RPC_API_VERSION;
use kaspa_wrpc_client::node::NodeDescriptor;
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
/// A drop that ends a run SHORTER than this parks no strike at all — the
/// connection never lived long enough for its death to say anything about
/// the endpoint (V6 churn-smoothing, register item 16: the V3 sitting's
/// first mia strike punished a 25 ms run — pure Wi-Fi re-association noise;
/// `v3_sitting.log` 13:42:30.698→.723). Ten seconds ≈ ~100 BlockAdded
/// heartbeats at 10 bps: a run that survives it proves the interface
/// genuinely held, so a later drop is admissible evidence (and D-084's
/// self-refutation still acquits it if the same endpoint reconnects).
pub const MIN_STRIKE_RUN_SECS: u64 = 10;
/// Deadline for ONE `Resolver::get_node` fetch (D-089 root cause, C1). The
/// pinned resolver walks its seeder URLs SEQUENTIALLY inside a single
/// `fetch()` (pin `rpc/wrpc/client/src/resolver.rs:155-167`), and the HTTP
/// layer beneath is a default `reqwest::Client::new()` with NO timeout
/// anywhere in the crate (`workflow-http 0.18.0 src/native.rs`) — one
/// silently blackholed request (Wi-Fi power-save, AP roam, Wi-Fi↔cell
/// handoff: no RST ever arrives) used to hang the whole race loop forever.
/// 5 s because it caps the pin's WHOLE sequential seeder walk, not one
/// seeder: a healthy seeder answers well under 1 s, so a walk that needs
/// 5 s is a walk that is not going to succeed; the race round's worst case
/// becomes fetch 5 s + probe ~8 s and the loop CYCLES instead of wedging.
pub const RESOLVER_FETCH_TIMEOUT: Duration = Duration::from_secs(5);
/// Deadline for AWAITING a client's teardown (probe/escalation/shared).
/// `disconnect()` at the pin is a dispatcher handshake that a blackholed
/// socket can starve (`workflow-websocket 0.18.0 client/native.rs:322-334`:
/// `ws_sender.send().await` runs INSIDE a select arm body, so the shutdown
/// arm is unpolled while it blocks) — and a dispatcher that exits via its
/// ERROR path never answers the handshake at all, so a starved teardown may
/// NEVER complete. The teardown is therefore detached (never aborted — the
/// reaper finding) and never awaited raw, and nothing bounded may gate on
/// its completion; only the caller's WAIT is bounded, so a probe task can
/// never wedge the race's drain.
pub const DISCONNECT_WAIT_TIMEOUT: Duration = Duration::from_secs(5);

/// Judgment of a dropped connection by run length (the V6 three-way split of
/// the old clean-or-strike coin flip). Pure — the boundaries are pinned by
/// unit test; the DagMonitor's disconnect arm consumes the verdict.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunJudgment {
    /// Survived [`CLEAN_RUN_SECS`] — clears the endpoint's strikes.
    CleanRun,
    /// A real run that ended early — park a strike for the control group
    /// (and D-084 self-refutation) to settle.
    Strike,
    /// Died inside [`MIN_STRIKE_RUN_SECS`] — interface churn noise; the drop
    /// is inadmissible against the endpoint. No strike, no clean-run.
    ChurnNoise,
}

pub fn judge_run(run_secs: u64) -> RunJudgment {
    if run_secs >= CLEAN_RUN_SECS {
        RunJudgment::CleanRun
    } else if run_secs >= MIN_STRIKE_RUN_SECS {
        RunJudgment::Strike
    } else {
        RunJudgment::ChurnNoise
    }
}

/// How many recent-healthy pantry candidates join the cached endpoint as
/// immediate parallel dials in the race (C6/D-089 ruling 5): enough that one
/// live node among them makes the common reconnect resolver-free, small
/// enough that a race round stays a handful of sockets.
pub const PANTRY_DIALS: usize = 3;
/// A pantry candidate must have been seen healthy within this window — a
/// node that hasn't answered in a week is the resolver's job to re-find,
/// not a dial-list squatter.
pub const PANTRY_FRESH_SECS: u64 = 7 * 24 * 3600;

/// Per-endpoint health record (all public data: a wss URL + counters).
#[derive(Debug, Clone, PartialEq, Eq)]
struct HealthRecord {
    strikes: u32,
    last_strike_unix: u64,
    demoted_until_unix: u64,
    /// Unix-seconds this endpoint last PROVED healthy (won a probe, or the
    /// shared socket connected to it); 0 = never observed healthy. Feeds the
    /// race pantry (C6): recent-healthy nodes dial immediately, without the
    /// resolver on the critical path (INV-8 posture — the resolver is an
    /// untrusted accelerator, and now it isn't load-bearing either).
    last_healthy_unix: u64,
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
                // 5th field added at C6 (D-089): ABSENT in every pre-R0
                // ledger, so absent = 0 (never-observed-healthy), and a
                // malformed value degrades the same way — the IO contract
                // (PB-023) splits absent-vs-corrupt from error kinds; health
                // data is advisory either way.
                let last_healthy_unix = parts.next().and_then(|v| v.parse().ok()).unwrap_or(0);
                records.insert(
                    url.to_string(),
                    HealthRecord {
                        strikes,
                        last_strike_unix: last,
                        demoted_until_unix: until,
                        last_healthy_unix,
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
                "{url}\t{}\t{}\t{}\t{}\n",
                r.strikes, r.last_strike_unix, r.demoted_until_unix, r.last_healthy_unix
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
            last_healthy_unix: 0,
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

    /// Stamp `url` as observed-healthy NOW (C6): a probe win or a shared-
    /// socket `Connected`. Feeds [`Self::race_pantry`].
    pub fn mark_healthy(&mut self, url: &str, now_unix: u64) {
        let record = self.records.entry(url.to_string()).or_insert(HealthRecord {
            strikes: 0,
            last_strike_unix: 0,
            demoted_until_unix: 0,
            last_healthy_unix: 0,
        });
        record.last_healthy_unix = now_unix;
    }

    /// The race's immediate-dial pantry (C6, pure — boundaries pinned by unit
    /// test): up to `k` endpoints seen healthy within [`PANTRY_FRESH_SECS`],
    /// not currently demoted, deduped against the cached endpoint —
    /// most-recently-healthy first (URL as the deterministic tie-break).
    /// These dial in parallel WITHOUT waiting for any resolver HTTP: the
    /// common reconnect re-dials a node the wallet trusted an hour ago and
    /// a slow resolver network stops being load-bearing (INV-8 posture).
    pub fn race_pantry(&self, cached: Option<&str>, now_unix: u64, k: usize) -> Vec<String> {
        let mut fresh: Vec<(&String, &HealthRecord)> = self
            .records
            .iter()
            .filter(|(url, r)| {
                r.last_healthy_unix > 0
                    && now_unix.saturating_sub(r.last_healthy_unix) <= PANTRY_FRESH_SECS
                    && r.demoted_until_unix <= now_unix
                    && Some(url.as_str()) != cached
            })
            .collect();
        fresh.sort_by(|(a_url, a), (b_url, b)| {
            b.last_healthy_unix
                .cmp(&a.last_healthy_unix)
                .then_with(|| a_url.cmp(b_url))
        });
        fresh
            .into_iter()
            .take(k)
            .map(|(url, _)| url.clone())
            .collect()
    }

    /// Test seam: age an endpoint's last strike so the same-incident dedup
    /// window doesn't swallow the next one (crate tests only).
    #[cfg(test)]
    pub(crate) fn backdate_last_strike(&mut self, url: &str, secs: u64) {
        if let Some(r) = self.records.get_mut(url) {
            r.last_strike_unix = r.last_strike_unix.saturating_sub(secs);
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
    /// The node's RPC API major — carried for forensics (winners' majors
    /// climbing is the early signal of a network-wide upgrade wave).
    pub rpc_api_version: u16,
}

/// Whether a node's RPC API major is servable by this pinned client. `<=`,
/// not `==`, mirroring the pin's own handshake gate (wallet-core
/// processor.rs refuses only NEWER majors): an older major has already
/// proven wire compatibility by answering the probe, while a newer one can
/// carry call semantics the pin cannot parse. A stricter `!=` here would
/// make the probe disagree with the wallet-core gate on the same socket.
fn rpc_major_supported(server_major: u16) -> bool {
    server_major <= RPC_API_VERSION
}

/// The ONE bounded doorway to `Resolver::get_node` (D-089 bounded-await law,
/// C1): every resolver fetch in this crate goes through here, never raw —
/// the raw call has no deadline at any layer beneath it (see
/// [`RESOLVER_FETCH_TIMEOUT`]) and a blackholed fetch wedged the whole
/// recovery engine. Errors are sanitized before the evidence lane.
pub async fn bounded_get_node(
    resolver: &Resolver,
    network_id: NetworkId,
    timeout: Duration,
) -> Result<NodeDescriptor> {
    tokio::time::timeout(timeout, resolver.get_node(WrpcEncoding::Borsh, network_id))
        .await
        .map_err(|_| ChainError::Message(format!("resolver fetch: timeout after {timeout:?}")))?
        .map_err(|e| {
            ChainError::Message(format!(
                "resolver fetch: {}",
                sanitize_node_text(&e.to_string())
            ))
        })
}

/// Detach-and-bound a client's teardown (C2 fix, same class as C1): the
/// teardown task is detached, never cancelled (aborting it would leak a
/// detached ws loop — the reaper finding) and never awaited raw; it MAY
/// never complete (a starved handshake can be orphaned forever — see
/// [`DISCONNECT_WAIT_TIMEOUT`]), which is precisely why the caller's WAIT
/// is bounded and why nothing on a bounded path may gate on the teardown
/// finishing (the winner bind carries its own envelope for the guard this
/// teardown can hold — `BIND_ENVELOPE_TIMEOUT`).
pub(crate) async fn bounded_disconnect(client: KaspaRpcClient, wait: Duration) {
    let teardown = tokio::spawn(async move {
        let _ = client.disconnect().await;
    });
    if tokio::time::timeout(wait, teardown).await.is_err() {
        log::warn!("link: disconnect wait exceeded {wait:?} — teardown continues detached");
    }
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
        // Wrong-major refusal (V6 ecosystem rider): a node speaking a newer
        // RPC major than the pin would strand the shared socket half-up at
        // wallet-core's own handshake gate — refuse at candidacy instead,
        // where the race just walks to the next node.
        if !rpc_major_supported(info.rpc_api_version) {
            return Err(ChainError::Message(format!(
                "probe {url}: rpc major v{} newer than pinned v{RPC_API_VERSION}",
                info.rpc_api_version
            )));
        }
        Ok(ProbeOutcome {
            url: url.to_string(),
            server_version: info.server_version,
            virtual_daa_score: info.virtual_daa_score,
            rpc_api_version: info.rpc_api_version,
        })
    }
    .await;
    bounded_disconnect(client, DISCONNECT_WAIT_TIMEOUT).await;
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

/// Race-to-connect (V3 deliverable 1, pantry since C6/D-089): the cached
/// endpoint plus up to [`PANTRY_DIALS`] recent-healthy pantry candidates
/// (if provided and not demoted) start dialing IMMEDIATELY — the fast path;
/// they win every tie because resolver candidates first spend an HTTP
/// round-trip on `get_node` — while `fetches` parallel resolver fetches feed
/// parallel probes, joining as they land. First healthy endpoint wins;
/// in-flight losers finish their bounded probes in a detached reaper
/// (aborting would leak ws loops). The common reconnect therefore does ZERO
/// HTTP before dialing a node it trusted recently.
///
/// `demoted` URLs never enter the race — UNLESS the cached endpoint, the
/// pantry and every fetched node are all demoted and the race would be
/// empty; connectivity always beats hygiene, so demotion filtering degrades
/// to advisory when it would otherwise strand the wallet (the ledger heals
/// as cooldowns lapse).
pub async fn race(
    resolver: &Resolver,
    network_id: NetworkId,
    cached: Option<String>,
    pantry: Vec<String>,
    demoted: &HashSet<String>,
    fetches: usize,
    probe_timeout: Duration,
) -> RaceOutcome {
    let mut tasks: JoinSet<std::result::Result<ProbeOutcome, Option<String>>> = JoinSet::new();
    let mut entered: HashSet<String> = HashSet::new();

    // Cached first, then the pantry: identical immediate-dial treatment, and
    // `entered` dedups (race_pantry already excludes the cached URL, but a
    // caller-composed pantry must not double-dial either way).
    let immediate = cached
        .into_iter()
        .chain(pantry)
        .filter(|url| !demoted.contains(url));
    for url in immediate {
        if !entered.insert(url.clone()) {
            continue;
        }
        tasks.spawn(async move {
            probe_endpoint(&url, network_id, probe_timeout)
                .await
                .map_err(|e| {
                    log::info!("link: race probe failed (immediate): {e}");
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
            // Bounded doorway (C1): the raw get_node has no deadline at any
            // layer and one blackholed fetch wedged the race loop forever.
            let node = bounded_get_node(&resolver, network_id, RESOLVER_FETCH_TIMEOUT)
                .await
                .map_err(|e| {
                    log::info!("link: {e}");
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
    // Bounded doorway (C1): the same blackhole that wedged the race would
    // otherwise wedge the stuck-payment rescue path silently.
    let node = bounded_get_node(resolver, network_id, RESOLVER_FETCH_TIMEOUT)
        .await
        .map_err(|e| ChainError::Message(format!("escalation {e}")))?;
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
    bounded_disconnect(client, DISCONNECT_WAIT_TIMEOUT).await;
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!("kv-link-{}-{name}", std::process::id()))
    }

    #[test]
    fn run_judgment_boundaries_hold() {
        // The churn-noise floor and the clean-run ceiling (item 16, V6):
        // 25 ms-class interface deaths are inadmissible; a run past the
        // floor strikes; a run past CLEAN_RUN_SECS clears.
        assert_eq!(judge_run(0), RunJudgment::ChurnNoise);
        assert_eq!(judge_run(MIN_STRIKE_RUN_SECS - 1), RunJudgment::ChurnNoise);
        assert_eq!(judge_run(MIN_STRIKE_RUN_SECS), RunJudgment::Strike);
        assert_eq!(judge_run(CLEAN_RUN_SECS - 1), RunJudgment::Strike);
        assert_eq!(judge_run(CLEAN_RUN_SECS), RunJudgment::CleanRun);
    }

    #[test]
    fn rpc_major_gate_refuses_only_newer_majors() {
        // Pin the boundary: older majors have proven wire-compat by
        // answering the probe; only a NEWER major is refused (the
        // wallet-core handshake-gate semantics, never stricter).
        assert!(rpc_major_supported(0));
        assert!(rpc_major_supported(RPC_API_VERSION));
        assert!(!rpc_major_supported(RPC_API_VERSION + 1));
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

    /// PB-023 (C6/D-089 ruling 5): the ledger on every device that ran a
    /// pre-R0 build is 4-field lines — EXACTLY this fixture's format (copied
    /// from a real V6 `endpoint.health` line shape). It must parse with
    /// `last_healthy_unix` defaulting to 0, all other fields intact; a
    /// malformed 5th field degrades to 0 the same way (absent-vs-corrupt by
    /// IO contract, and health data is advisory either way).
    #[test]
    fn old_format_ledger_parses_with_last_healthy_defaulting_to_zero() {
        let path = tmp("health-pb023");
        std::fs::write(
            &path,
            "wss://nora.kaspa.stream/kaspa/mainnet/wrpc/borsh\t2\t5100\t5700\n\
             wss://lena.kaspa.stream/kaspa/mainnet/wrpc/borsh\t1\t6000\t0\n\
             wss://mia.kaspa.stream/kaspa/mainnet/wrpc/borsh\t0\t0\t0\tgarbage\n",
        )
        .unwrap();
        let loaded = EndpointHealth::load(&path);
        // Old fields intact: nora is demoted until 5700, lena is not.
        assert!(loaded.is_demoted("wss://nora.kaspa.stream/kaspa/mainnet/wrpc/borsh", 5_600));
        assert!(!loaded.is_demoted("wss://lena.kaspa.stream/kaspa/mainnet/wrpc/borsh", 5_600));
        // Absent (and corrupt) 5th field = never-observed-healthy: nothing
        // qualifies for the pantry.
        assert!(loaded.race_pantry(None, 6_000, PANTRY_DIALS).is_empty());
        // And the migrated ledger round-trips in the NEW format.
        loaded.save(&path);
        let reloaded = EndpointHealth::load(&path);
        assert!(reloaded.is_demoted("wss://nora.kaspa.stream/kaspa/mainnet/wrpc/borsh", 5_600));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn pantry_selects_fresh_undemoted_deduped_most_recent_first() {
        let now = 1_000_000u64;
        let mut health = EndpointHealth::default();
        // Fresh and clean — candidates, ordered by recency.
        health.mark_healthy("wss://recent.example/borsh", now - 60);
        health.mark_healthy("wss://older.example/borsh", now - 3_600);
        health.mark_healthy("wss://oldest.example/borsh", now - 86_400);
        // Exactly at the freshness boundary — still in.
        health.mark_healthy("wss://boundary.example/borsh", now - PANTRY_FRESH_SECS);
        // One second past the boundary — out.
        health.mark_healthy("wss://stale.example/borsh", now - PANTRY_FRESH_SECS - 1);
        // Fresh but demoted — out while the cooldown holds.
        health.mark_healthy("wss://demoted.example/borsh", now - 30);
        health.strike("wss://demoted.example/borsh", now - 20);
        health.backdate_last_strike("wss://demoted.example/borsh", STRIKE_DEDUP_SECS + 1);
        health.strike("wss://demoted.example/borsh", now - 5); // second strike demotes
        assert!(health.is_demoted("wss://demoted.example/borsh", now));

        // The cached endpoint is deduped out even when it is the freshest.
        let pantry = health.race_pantry(Some("wss://recent.example/borsh"), now, PANTRY_DIALS);
        assert_eq!(
            pantry,
            vec![
                "wss://older.example/borsh".to_string(),
                "wss://oldest.example/borsh".to_string(),
                "wss://boundary.example/borsh".to_string(),
            ]
        );

        // Without the dedup, K caps the list and recency orders it.
        let pantry = health.race_pantry(None, now, PANTRY_DIALS);
        assert_eq!(
            pantry,
            vec![
                "wss://recent.example/borsh".to_string(),
                "wss://older.example/borsh".to_string(),
                "wss://oldest.example/borsh".to_string(),
            ]
        );

        // A lapsed demotion cooldown restores pantry candidacy.
        let after_cooldown = now + DEMOTION_COOLDOWN_SECS;
        let pantry = health.race_pantry(None, after_cooldown, 10);
        assert!(pantry.contains(&"wss://demoted.example/borsh".to_string()));
    }

    /// C1 (D-089): the wedge test. A seeder that ACCEPTS the TCP connection
    /// and never answers (the silent-blackhole shape — no RST, no response)
    /// must error within [`bounded_get_node`]'s bound instead of hanging the
    /// caller forever. The outer 10 s guard is the negative-proof detector
    /// (PB-011): with the timeout wrap reverted this test goes RED on the
    /// guard's expect instead of hanging the suite.
    #[tokio::test(flavor = "multi_thread")]
    async fn bounded_get_node_errors_within_bound_on_hanging_seeder() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            // Accept and HOLD each socket open, never writing a byte.
            let mut held = Vec::new();
            for stream in listener.incoming() {
                match stream {
                    Ok(s) => held.push(s),
                    Err(_) => break,
                }
            }
        });
        // Point the pin's Resolver at the hanging listener via its public
        // constructor — `Resolver::new(urls: Option<Vec<Arc<String>>>, tls:
        // bool)` (pin rpc/wrpc/client/src/resolver.rs:106).
        let resolver = Resolver::new(
            Some(vec![std::sync::Arc::new(format!("http://{addr}"))]),
            false,
        );
        let network_id = NetworkId::new(kaspa_wrpc_client::prelude::NetworkType::Mainnet);
        let started = std::time::Instant::now();
        let result = tokio::time::timeout(
            Duration::from_secs(10),
            bounded_get_node(&resolver, network_id, Duration::from_millis(400)),
        )
        .await
        .expect("bounded_get_node must return within its bound — it hung (the D-089 wedge)");
        assert!(result.is_err(), "a hanging seeder cannot yield a node");
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "errored, but not within the configured bound"
        );
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
