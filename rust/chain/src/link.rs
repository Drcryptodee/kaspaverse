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

/// WHY an endpoint was struck (R2 D1). `endpoint.health` recorded *when* a
/// node was convicted and never *why*, so D-095's central question — were the
/// six endpoints demoted in 108 s innocent? — was unanswerable once the log
/// ring rolled (L65). A closed token set, never free text: the value is
/// written into a TAB-separated durable record, so "no tabs, no newlines, no
/// node-supplied bytes" is guaranteed BY CONSTRUCTION here rather than by
/// remembering to call [`sanitize_node_text`] at each call site.
///
/// The tokens are a stable on-disk vocabulary — renaming one silently
/// reinterprets every ledger already on a user's phone. Add variants; never
/// repurpose a token.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum StrikeReason {
    /// A live connection died (the parked strike settled against the node).
    Drop,
    /// A race probe failed and the failure was not classified further.
    ProbeFailed,
    /// A dial or probe never answered — no bytes came back at all.
    DialTimeout,
    /// The node ANSWERED with a server-side error (`ivy`'s real HTTP 500).
    /// The most load-bearing token: this is earned guilt, and D3's
    /// inadmissibility rule must never acquit it (D-092 ruling 6).
    HttpServerError,
    /// The probe won but the shared socket could not bind to it.
    BindFailed,
    /// A submitted tx stalled on the endpoint that took it.
    Stall,
    /// The endpoint's hostname did not resolve. Kept DISTINCT from
    /// [`Self::ProbeFailed`] because it is the one probe failure that may say
    /// nothing about the node at all — we never reached it. Admissibility is
    /// decided by correlation, not by the token alone: see
    /// [`dns_outage_in_round`].
    DnsFailure,
    /// The phone's OWN network stack refused to route the dial
    /// (`ENETUNREACH`, os error 101). Unlike a DNS failure this needs no
    /// correlation to acquit: the OS itself said "no route from HERE", which
    /// is a verdict about the link, never about the node (R3 field capture:
    /// all four candidates failed this way in one round, 1.5 s after a Wi-Fi
    /// re-association).
    Unreachable,
    /// WITHHELD (R3 D-099): between this socket's death and the strike's
    /// settle, a race round failed with phone-side errors (correlated DNS or
    /// `ENETUNREACH`) — the link was provably in blackout when the socket
    /// died, so the drop is evidence about the radio, not the node.
    LinkBlackout,
    /// WITHHELD (R2 D3): the event sat next to the OS reporting the phone's
    /// own network lost, so it is evidence about the link, not the node.
    OsLostAdjacent,
    /// WITHHELD (R2 D3): the event sat next to the item-9 tripwire, which
    /// proves a socket existed that our reconnect authority did not create
    /// (R2 D2 — the pinned ws client re-dials on its own). A strike earned by
    /// our own churn is exactly as unjust as one earned by a dead Wi-Fi.
    SelfInflicted,
    /// Read back from a ledger written before R2 — the record predates the
    /// reason field, so its `why` is genuinely unknown rather than absent.
    #[default]
    Unknown,
}

impl StrikeReason {
    /// The durable token. Stable on disk — see the type's note.
    pub fn as_token(self) -> &'static str {
        match self {
            Self::Drop => "drop",
            Self::ProbeFailed => "probe-failed",
            Self::DialTimeout => "dial-timeout",
            Self::HttpServerError => "http-5xx",
            Self::BindFailed => "bind-failed",
            Self::Stall => "stall",
            Self::DnsFailure => "dns-failure",
            Self::Unreachable => "unreachable",
            Self::LinkBlackout => "link-blackout",
            Self::OsLostAdjacent => "os-lost-adjacent",
            Self::SelfInflicted => "self-inflicted",
            Self::Unknown => "unknown",
        }
    }

    /// Parse a token from disk. An unrecognised token degrades to
    /// [`Self::Unknown`] — a FORWARD-compatibility clause as much as a
    /// corruption one: a ledger written by a newer build that learned a new
    /// reason must still load in an older one (health data is advisory,
    /// never load-bearing for connectivity).
    pub fn from_token(token: &str) -> Self {
        match token {
            "drop" => Self::Drop,
            "probe-failed" => Self::ProbeFailed,
            "dial-timeout" => Self::DialTimeout,
            "http-5xx" => Self::HttpServerError,
            "bind-failed" => Self::BindFailed,
            "stall" => Self::Stall,
            "dns-failure" => Self::DnsFailure,
            "unreachable" => Self::Unreachable,
            "link-blackout" => Self::LinkBlackout,
            "os-lost-adjacent" => Self::OsLostAdjacent,
            "self-inflicted" => Self::SelfInflicted,
            _ => Self::Unknown,
        }
    }

    /// Classify a probe/dial failure from its own error text. The
    /// classification only ever narrows [`Self::ProbeFailed`] — an
    /// unrecognised failure stays the generic token rather than guessing.
    ///
    /// The 5xx arm exists because it is the one reason that must survive D3
    /// untouched: a node answering `500` proved it was reachable, so no
    /// phone-side or self-inflicted excuse applies to it.
    ///
    /// **URLs are scrubbed BEFORE matching, and that is load-bearing, not
    /// tidiness.** Our own error wrapper embeds the endpoint URL in the text
    /// (`probe dial <url>: …`), so a node that simply NAMED itself
    /// `wss://timeout.example/` would otherwise classify its every failure as
    /// [`Self::DialTimeout`] — buying itself whatever leniency D3 grants that
    /// token, purely by choosing a hostname. Classifying node-chosen bytes is
    /// a stag-hunt hole: match only on text WE or the transport wrote.
    /// Scrubbing lives here rather than at the call sites so it cannot be
    /// forgotten by the next caller.
    pub fn classify_probe_failure(text: &str) -> Self {
        // Scrub BEFORE sanitize: `sanitize_node_text` caps at 200 chars, and
        // the URL is the longest single run in our wrapper — sanitizing first
        // can push the informative tail ("… 500 Internal Server Error") past
        // the cap and silently downgrade an EARNED http-5xx to probe-failed.
        let lower = sanitize_node_text(&scrub_urls(text)).to_ascii_lowercase();
        if lower.contains("500 internal server error")
            || lower.contains("502 bad gateway")
            || lower.contains("503 service unavailable")
            || lower.contains("504 gateway timeout")
        {
            Self::HttpServerError
        } else if lower.contains("no address associated with hostname")
            || lower.contains("failed to lookup address information")
            || lower.contains("name or service not known")
            || lower.contains("temporary failure in name resolution")
        {
            // The exact strings the V60 produced through a scripted outage
            // (`DNS: No address associated with hostname`, 8/8 failures) plus
            // the other glibc/getaddrinfo phrasings for the same condition.
            Self::DnsFailure
        } else if lower.contains("network is unreachable") {
            // ENETUNREACH, verbatim from the 2026-07-31 00:56:17 capture: the
            // OS refused to route the dial at all. Narrow on purpose — "host
            // unreachable" can be a remote ICMP verdict and stays generic.
            Self::Unreachable
        } else if lower.contains("timeout") || lower.contains("timed out") {
            Self::DialTimeout
        } else {
            Self::ProbeFailed
        }
    }
}

/// A strike-worthy event within this many seconds of the OS reporting the
/// PHONE's own network lost is phone-side evidence, inadmissible against the
/// endpoint (R2 D3; the parked rule from D-092 ruling 6, whose gate fired six
/// times over in D-095).
///
/// Sized, per D-091 ruling 6, as a NEW rule rather than a re-tuned threshold —
/// so the discipline is "what does the evidence bound?", not "what number
/// feels better?". R1 timestamped the one clean sample to the millisecond:
/// `tess` was struck **86 ms** after `network_lost` under a scripted Wi-Fi
/// kill. Five seconds is ~58× that observed gap — headroom for scheduling
/// jitter on a loaded phone, while staying two orders of magnitude below the
/// 600 s cooldown a wrongful strike would impose. It is deliberately generous
/// in TIME and narrow in SCOPE: the window can only open when the OS actually
/// reported a loss, so on a healthy link it never opens at all.
///
/// Widening this is the wrong repair if it ever proves too narrow — the fix
/// would be a better phone-side signal, not a longer amnesty.
pub const OS_LOST_ADJACENCY_SECS: u64 = 5;
/// The same window for SELF-inflicted churn (R2 D2/D3). The detector is the
/// item-9 tripwire — a prior listener surviving into a new connect proves two
/// `Connected` arrived with no `Disconnected` between them, i.e. a socket
/// exists that our reconnect authority did not create. Anything dying in that
/// neighbourhood cannot be pinned on a node.
pub const SELF_INFLICTED_ADJACENCY_SECS: u64 = 5;

/// How many DISTINCT endpoints must fail DNS in one race round before the
/// round is read as a resolver outage rather than as dead nodes.
///
/// **Two is a logical minimum, not a tuned threshold** — which is the whole
/// reason this rule could be written the day it was found, under D-091
/// ruling 6. One endpoint failing DNS is genuinely ambiguous: an operator who
/// tears down a node may well pull its record, and that endpoint SHOULD stay
/// convictable. But the immediate candidates are distinct hosts across
/// distinct domains (`kaspa.stream`, `kaspa.red`, `kaspa.blue`,
/// `kaspa.green` in the 2026-07-30 field capture) under different operators.
/// Two of those losing DNS in the same round is not two coincident outages;
/// it is our own resolver. There is no number here to get wrong, so there is
/// nothing for a second incident to re-tune.
pub const DNS_CORRELATION_MIN: usize = 2;

/// Does this round's failure set show a PHONE-side DNS outage (R2 field
/// addendum)? Pure — the caller supplies the round.
///
/// Correlation is measured over distinct HOSTS, not over entries: the same
/// endpoint answering twice must never look like corroboration.
pub fn dns_outage_in_round(failed: &[(String, StrikeReason)]) -> bool {
    let hosts: HashSet<&str> = failed
        .iter()
        .filter(|(_, reason)| *reason == StrikeReason::DnsFailure)
        .map(|(url, _)| endpoint_host(url))
        .collect();
    hosts.len() >= DNS_CORRELATION_MIN
}

/// Did this round prove the PHONE's network was broken (R3 D-099)? True when
/// ≥ [`DNS_CORRELATION_MIN`] DISTINCT hosts failed with phone-side reasons
/// (DNS or `ENETUNREACH`) in one round — the two reasons corroborate each
/// other, because a real link blackout produces a mix (the 2026-07-31
/// 00:59:41 round: 2 DNS + 2 unreachable across 4 hosts). A LONE unreachable
/// stays convictable by the same logic as a lone DNS failure (wallet-security
/// finding): one endpoint with no route can be that endpoint's own chronic
/// condition (an AAAA-only host on an IPv4 path), and excusing it forever
/// would make it undemotable. Pure; the caller supplies the round. A `true`
/// round is stamped by the race loop (no-winner rounds ONLY — a round that
/// produced a live prover proved the phone's network works) and refutes
/// pending drop/stall strikes whose socket died just before it (see
/// [`judge_admissibility`]).
pub fn phone_fault_in_round(failed: &[(String, StrikeReason)]) -> bool {
    let hosts: HashSet<&str> = failed
        .iter()
        .filter(|(_, reason)| {
            matches!(reason, StrikeReason::DnsFailure | StrikeReason::Unreachable)
        })
        .map(|(url, _)| endpoint_host(url))
        .collect();
    hosts.len() >= DNS_CORRELATION_MIN
}

/// The block-silence threshold past which a CONNECTED socket is judged
/// stalled — the Rust authority for the claim `chain_service.dart`'s
/// `watchdogStallSecs` (same value) makes from its process-lifetime view.
/// Mainnet delivers ~10 blocks/s, so 30 s of silence on a live socket is
/// ~300 missed blocks: real evidence, once the clock is per-socket
/// ([`crate::DagMonitor`]'s stall verdict uses `max(last_block_at,
/// connected_at)` — a socket cannot be guilty of silence older than itself).
pub const WATCHDOG_STALL_SECS: u64 = 30;

/// What to do with a strike-worthy event (R2 D3). `Withhold` is not
/// forgiveness — the event is still recorded against the endpoint via
/// [`EndpointHealth::withhold`], it just does not count toward demotion.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Admissibility {
    /// Charge it: this is evidence about the node.
    Convict(StrikeReason),
    /// Record it, do not charge it: the evidence is about the phone or about
    /// us. Carries the reason that explains WHY it was withheld.
    Withhold(StrikeReason),
}

/// Decide whether a strike-worthy event is admissible against the endpoint
/// (R2 D3). Pure — no clock, no locks — so the boundaries are pinned by unit
/// test exactly like [`judge_run`]; the caller supplies the timestamps.
///
/// `0` means "never observed" for either signal, which is why the checks are
/// explicit rather than arithmetic: at unix 0 everything is adjacent to
/// everything.
///
/// **The `http-5xx` guard comes first and is absolute.** A node that answered
/// `500` proved it was reachable and proved the fault was its own, so no
/// phone-side or self-inflicted excuse can apply to it. This is the D-092
/// ruling 6 regression bar in code: `ivy` was convicted on merit, and a rule
/// that acquits ivy is a worse bug than the flapping it set out to cure.
pub fn judge_admissibility(
    reason: StrikeReason,
    event_at_unix: u64,
    os_lost_at_unix: u64,
    doubled_connect_at_unix: u64,
    phone_fault_correlated: bool,
    phone_fault_round_at_unix: u64,
) -> Admissibility {
    // Earned guilt is not excusable. Checked before every other arm.
    if reason == StrikeReason::HttpServerError {
        return Admissibility::Convict(reason);
    }
    // Checked before the time windows because it is the more SPECIFIC cause:
    // the field case that motivated it convicted four endpoints 58 s after
    // `network_lost` — long outside the OS window — while the phone's
    // resolver was still cold from a Wi-Fi re-association. A lone failure of
    // either phone-side kind never reaches here as correlated, so a genuinely
    // dead node's pulled record — or a chronically routeless one — stays
    // convictable (R3 wallet-security finding: ENETUNREACH gets the same
    // correlation bar as DNS, not an unconditional pass).
    if phone_fault_correlated
        && matches!(reason, StrikeReason::DnsFailure | StrikeReason::Unreachable)
    {
        return Admissibility::Withhold(reason);
    }
    // A pending drop/stall strike is judged in absentia: the socket died,
    // and only the race that FOLLOWED can say whether the phone's network
    // was alive at the time. A phone-fault round stamped at-or-after the
    // death refutes it (R3 D-099: eva convicted at 00:59:51 while the
    // interposed round failed every candidate with ENETUNREACH). Scoped to
    // Drop/Stall only — race-loss strikes are judged WITH a live winner
    // present, and that evidence stands on its own (`ivy`'s 500 bar).
    if matches!(reason, StrikeReason::Drop | StrikeReason::Stall)
        && phone_fault_round_at_unix != 0
        && phone_fault_round_at_unix >= event_at_unix
    {
        return Admissibility::Withhold(StrikeReason::LinkBlackout);
    }
    // `abs_diff`, not "since": the OS is routinely SLOWER than the socket to
    // notice a dead link (the socket errors first, ConnectivityService's
    // `onLost` lands after), so a window that only looked backwards would
    // miss the common ordering entirely — which is how this rule could look
    // implemented and still convict every innocent node.
    if doubled_connect_at_unix != 0
        && event_at_unix.abs_diff(doubled_connect_at_unix) <= SELF_INFLICTED_ADJACENCY_SECS
    {
        return Admissibility::Withhold(StrikeReason::SelfInflicted);
    }
    if os_lost_at_unix != 0 && event_at_unix.abs_diff(os_lost_at_unix) <= OS_LOST_ADJACENCY_SECS {
        return Admissibility::Withhold(StrikeReason::OsLostAdjacent);
    }
    Admissibility::Convict(reason)
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
#[derive(Debug, Clone, Default, PartialEq, Eq)]
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
    /// WHY the last strike event landed (R2 D1). Covers the last COMMITTED
    /// strike or the last WITHHELD one — whichever happened most recently;
    /// `withheld` says which kind it was.
    last_reason: StrikeReason,
    /// How many strikes were WITHHELD from this endpoint (R2 D3) — evidence
    /// ruled inadmissible, recorded rather than erased. A ledger that only
    /// showed convictions could not be audited for wrongful acquittals, and
    /// a rising count here is the tripwire for an inadmissibility rule that
    /// is too generous (it would look like a suspiciously clean pantry).
    withheld: u32,
    /// Seconds the endpoint's last connection lasted before it dropped
    /// (0 = no drop recorded). Written for EVERY judged drop — clean run,
    /// strike, and churn-noise alike — because R2 D4 could not be decided on
    /// the evidence available: D-095 found four convicting runs landing
    /// exactly on [`MIN_STRIKE_RUN_SECS`], but the second incident's run
    /// lengths had already rolled out of the log ring (L65), and D-091
    /// ruling 6 forbids sizing a threshold on one incident.
    ///
    /// The churn-noise case is the one that MUST be recorded even though it
    /// convicts nobody: a floor can only be judged by the drops it absorbs,
    /// so a ledger that stores only the strikes would keep proving the floor
    /// correct by construction.
    last_run_secs: u64,
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
                // 6th + 7th fields added at R2 (D1), and they inherit exactly
                // the forgiveness the 5th earned: a pre-R2 ledger is missing
                // BOTH, and a phone that upgrades mid-cooldown must keep its
                // demotions rather than have the row dropped for being short.
                // Absent reason = `Unknown` (honest: the record predates the
                // field), absent withheld-count = 0.
                let last_reason = parts
                    .next()
                    .map_or(StrikeReason::Unknown, StrikeReason::from_token);
                let withheld = parts.next().and_then(|v| v.parse().ok()).unwrap_or(0);
                let last_run_secs = parts.next().and_then(|v| v.parse().ok()).unwrap_or(0);
                records.insert(
                    url.to_string(),
                    HealthRecord {
                        strikes,
                        last_strike_unix: last,
                        demoted_until_unix: until,
                        last_healthy_unix,
                        last_reason,
                        withheld,
                        last_run_secs,
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
            // The reason token is a closed enum (never node text), so it can
            // carry no tab or newline into this TSV by construction.
            out.push_str(&format!(
                "{url}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n",
                r.strikes,
                r.last_strike_unix,
                r.demoted_until_unix,
                r.last_healthy_unix,
                r.last_reason.as_token(),
                r.withheld,
                r.last_run_secs
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
    pub fn strike(&mut self, url: &str, now_unix: u64, reason: StrikeReason) -> bool {
        let record = self.records.entry(url.to_string()).or_default();
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
        record.last_reason = reason;
        if record.strikes >= DEMOTE_AT_STRIKES {
            record.demoted_until_unix = now_unix + DEMOTION_COOLDOWN_SECS;
            log::warn!(
                "link: endpoint demoted for {DEMOTION_COOLDOWN_SECS}s after {} strike(s) ({}): {url}",
                record.strikes,
                reason.as_token()
            );
            true
        } else {
            false
        }
    }

    /// Record a strike that was ruled INADMISSIBLE (R2 D3) — the endpoint is
    /// not convicted, but the event is not erased either. `strikes` and
    /// `demoted_until_unix` are deliberately untouched: this is the whole
    /// point of withholding rather than striking-then-forgiving, which would
    /// briefly demote an innocent node and let a concurrent race skip it.
    ///
    /// Counted per event with no dedup window: [`Self::strike`] dedups
    /// because repeated convictions compound into a demotion, whereas a
    /// withheld count is pure audit evidence — under-counting it would hide
    /// exactly the over-generous rule it exists to expose.
    pub fn withhold(&mut self, url: &str, reason: StrikeReason) {
        let record = self.records.entry(url.to_string()).or_default();
        record.withheld = record.withheld.saturating_add(1);
        record.last_reason = reason;
    }

    /// The last recorded strike reason for `url` (committed or withheld), and
    /// how many strikes have been withheld from it. Read by the summary
    /// decode and the tests; `None` for an endpoint with no record.
    pub fn last_reason(&self, url: &str) -> Option<(StrikeReason, u32)> {
        self.records.get(url).map(|r| (r.last_reason, r.withheld))
    }

    /// Record how long a connection lasted before dropping — for EVERY
    /// judgment, including the churn-noise drops that convict nobody. This is
    /// the durable twin of the `drop after Ns run` log line, which is the
    /// datum R2 D4 needed and could not get: on the weak link the ring
    /// retains ~1 minute (L65), so a second incident's run lengths are gone
    /// long before anyone asks.
    pub fn record_run(&mut self, url: &str, run_secs: u64) {
        self.records
            .entry(url.to_string())
            .or_default()
            .last_run_secs = run_secs;
    }

    /// The last recorded run length for `url` (0 = none). Feeds the D4
    /// re-examination once a second incident exists.
    pub fn last_run_secs(&self, url: &str) -> Option<u64> {
        self.records.get(url).map(|r| r.last_run_secs)
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
        let record = self.records.entry(url.to_string()).or_default();
        record.last_healthy_unix = now_unix;
    }

    /// The race's immediate-dial pantry (C6, pure — boundaries pinned by unit
    /// test): up to `k` endpoints seen healthy within [`PANTRY_FRESH_SECS`],
    /// not currently demoted, deduped against the cached endpoint —
    /// most-recently-healthy first (URL as the deterministic tie-break).
    /// These dial in parallel WITHOUT waiting for any resolver HTTP: the
    /// common reconnect re-dials a node the wallet trusted an hour ago and
    /// a slow resolver network stops being load-bearing (INV-8 posture).
    /// `ignore_demotions` is the hygiene-advisory degradation (R2 D5). Without
    /// it the exhaustion floor was half a floor: `race_loop` empties the
    /// `demoted` SET after two barren rounds so demoted endpoints may be
    /// dialed again, but the pantry kept filtering them out on its own — so at
    /// 11-of-11 demoted the fast path stayed dark exactly when it was needed,
    /// and the wallet fell back to the cached endpoint plus resolver HTTP.
    /// That put an untrusted accelerator on the critical path (INV-8 posture)
    /// at the worst possible moment. When connectivity beats hygiene it has to
    /// beat it here too.
    pub fn race_pantry(
        &self,
        cached: Option<&str>,
        now_unix: u64,
        k: usize,
        ignore_demotions: bool,
    ) -> Vec<String> {
        let mut fresh: Vec<(&String, &HealthRecord)> = self
            .records
            .iter()
            .filter(|(url, r)| {
                r.last_healthy_unix > 0
                    && now_unix.saturating_sub(r.last_healthy_unix) <= PANTRY_FRESH_SECS
                    && (ignore_demotions || r.demoted_until_unix <= now_unix)
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

/// The host of a `wss://host/path` candidate — the node's identity. The
/// scheme and the `/kaspa/mainnet/wrpc/borsh` tail are the same on every
/// candidate, so a round summary that repeats them spends bytes saying
/// nothing (and bytes are what evict the ring — L65).
///
/// A resolver-supplied URL is **node-controlled text**, so every caller that
/// puts this into the evidence lane wraps it in [`sanitize_node_text`]
/// (consensus-auditor item 16 — the same rule the error strings already
/// followed; the host was a new doorway for the same class).
pub fn endpoint_host(url: &str) -> &str {
    url.split("://")
        .nth(1)
        .unwrap_or(url)
        .split('/')
        .next()
        .unwrap_or(url)
}

/// Replace every embedded URL with `…`. The failure CLASS is the reason; the
/// address is already carried by the note's actor. Without this, three seeder
/// failures that differ only by seeder URL read as three distinct reasons and
/// grouping buys nothing (measured on device 2026-07-30). ASCII schemes, so
/// the byte offsets are always char boundaries.
fn scrub_urls(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    loop {
        let hit = ["https://", "http://", "wss://", "ws://"]
            .iter()
            .filter_map(|p| rest.find(p))
            .min();
        match hit {
            None => {
                out.push_str(rest);
                return out;
            }
            Some(at) => {
                out.push_str(&rest[..at]);
                out.push('…');
                let tail = &rest[at..];
                let end = tail
                    .find(|c: char| c.is_whitespace() || matches!(c, ')' | '"' | ']' | ','))
                    .unwrap_or(tail.len());
                rest = &tail[end..];
            }
        }
    }
}

/// Strip the layered boilerplate off a candidate's failure text, keeping the
/// clause that says what actually went wrong. Prefix shapes are verbatim from
/// the pin as observed on device 2026-07-30 (pinned in the unit test): a DNS
/// failure arrives as `wRPC -> WebSocket -> WebSocket error: IO error:
/// <cause>`, a seeder failure as `resolver fetch: Failed to connect:
/// [Custom("Unable to connect to <url>: <cause>")]`.
pub fn compact_reason(text: &str) -> String {
    let mut s = scrub_urls(&sanitize_node_text(text));
    // Substring, not prefix: the pin nests these mid-string (our own
    // `probe dial <url>: ` wrapper comes first), which is exactly how the first
    // on-device measurement still spent 452 chars a round.
    for (boilerplate, replacement) in [
        ("wRPC -> WebSocket -> WebSocket error: ", ""),
        ("wRPC -> WebSocket -> ", ""),
        ("probe dial …: ", "dial "),
        ("IO error: ", ""),
        (
            "Failed to connect: [Custom(\"Unable to connect to … ",
            "seeder ",
        ),
        ("Reqwest: error sending request for url ", "request failed "),
        ("failed to lookup address information: ", "DNS: "),
    ] {
        while let Some(at) = s.find(boilerplate) {
            s.replace_range(at..at + boilerplate.len(), replacement);
        }
    }
    s.chars().take(90).collect()
}

/// Collapse a round's losses into ONE compact line: each distinct reason is
/// stated once, prefixed by who hit it (`aria,eva,kate×2`). Grouping is the
/// load-bearing part — the first cut of this coalescing (R0 addendum #1)
/// traded nine verbose lines for one 1900-character line, which saved no
/// BYTES at all and so did not buy the retention it existed to buy. Reasons
/// are still verbatim (compacted, never dropped): they are what convicted
/// `ivy`'s real HTTP 500 and exonerated four weak-link timeouts.
pub fn summarize_losses(notes: &[(String, String)]) -> String {
    let mut order: Vec<&str> = Vec::new();
    let mut by: HashMap<&str, Vec<&str>> = HashMap::new();
    for (who, why) in notes {
        let entry = by.entry(why.as_str()).or_insert_with(|| {
            order.push(why.as_str());
            Vec::new()
        });
        entry.push(who.as_str());
    }
    order
        .into_iter()
        .map(|why| {
            // Collapse repeats of the same actor into `who×N`, first seen first.
            let whos = &by[why];
            let mut seen: Vec<(&str, usize)> = Vec::new();
            for who in whos {
                match seen.iter_mut().find(|(w, _)| w == who) {
                    Some((_, n)) => *n += 1,
                    None => seen.push((who, 1)),
                }
            }
            let actors = seen
                .iter()
                .map(|(w, n)| {
                    if *n == 1 {
                        w.to_string()
                    } else {
                        format!("{w}×{n}")
                    }
                })
                .collect::<Vec<_>>()
                .join(",");
            format!("{actors}: {why}")
        })
        .collect::<Vec<_>>()
        .join(" · ")
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

/// A resolver-supplied candidate URL is DIALABLE text, or it does not enter
/// the race (R3 wallet-security finding). Whitespace or control bytes in a
/// URL are never valid in a dialable endpoint — but they ARE exactly what an
/// adversarial resolver needs: a space smuggles failure-phrase text past
/// `scrub_urls` (which stops scrubbing at whitespace) into
/// [`StrikeReason::classify_probe_failure`]'s matcher, and a `\t`/`\n` in a
/// ledger KEY forges rows in the TSV [`EndpointHealth::save`] writes. One
/// guard at the intake closes both.
pub fn candidate_url_is_clean(url: &str) -> bool {
    !url.is_empty()
        && !url
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || c == '\u{7f}')
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
    /// `(url, why)` per candidate whose probe failed outright. The reason
    /// rides along from the point of failure (R2 D1) — reconstructing it
    /// later from `notes` would mean re-parsing a string that was already
    /// compacted for the log, and the durable ledger must not depend on the
    /// shape of a human-readable line.
    pub failed: Vec<(String, StrikeReason)>,
    /// `(who, why)` per candidate that did NOT win, in join order —
    /// [`summarize_losses`] folds them into the round's single compact summary
    /// line (R0 addendum #1, built at R1). `who` is the node's host (or
    /// `resolver`); `why` is its failure text, boilerplate-stripped but never
    /// dropped: reasons are what convicted `ivy`'s real HTTP 500 and exonerated
    /// four weak-link timeouts in the 2026-07-30 capture (L65).
    pub notes: Vec<(String, String)>,
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
    // A loss carries (the URL to strike, if the NODE is what failed; a note for
    // the round summary). Losing tasks no longer log a line each — the caller
    // prints one coalesced line per round (addendum #1).
    type Loss = (Option<(String, StrikeReason)>, Option<(String, String)>);
    let mut tasks: JoinSet<std::result::Result<ProbeOutcome, Loss>> = JoinSet::new();
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
                    // `[imm]` = the immediate lane (cached + pantry, zero HTTP
                    // before the dial). Which candidates were dialed without
                    // the resolver is how C6 was confirmed in the field, so the
                    // summary keeps the distinction.
                    let text = e.to_string();
                    let note = (
                        format!("{}[imm]", sanitize_node_text(endpoint_host(&url))),
                        compact_reason(&text),
                    );
                    (
                        Some((url, StrikeReason::classify_probe_failure(&text))),
                        Some(note),
                    )
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
                    (
                        None,
                        Some(("resolver".to_string(), compact_reason(&e.to_string()))),
                    )
                })?;
            let url = node.url;
            if !candidate_url_is_clean(&url) {
                // Undialable by construction; only useful to an attacker.
                return Err((
                    None,
                    Some((
                        "resolver".to_string(),
                        "rejected: malformed url".to_string(),
                    )),
                ));
            }
            if demoted.contains(&url) {
                return Err((
                    None,
                    Some((
                        sanitize_node_text(endpoint_host(&url)),
                        "skipped: demoted".to_string(),
                    )),
                ));
            }
            {
                let mut seen = seen
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if !seen.insert(url.clone()) {
                    // Duplicate answer — someone's already dialing it. Not a
                    // loss worth a note: it says nothing about any node.
                    return Err((None, None));
                }
            }
            probe_endpoint(&url, network_id, probe_timeout)
                .await
                .map_err(|e| {
                    let text = e.to_string();
                    let note = (
                        sanitize_node_text(endpoint_host(&url)),
                        compact_reason(&text),
                    );
                    (
                        Some((url, StrikeReason::classify_probe_failure(&text))),
                        Some(note),
                    )
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
            Ok(Err((failed_url, note))) => {
                // A URL means the NODE failed (it gets struck once the network
                // proves alive); a note without a URL is a resolver miss, a
                // demoted skip or a fetch timeout — evidence, but not evidence
                // against a node.
                if let Some(url) = failed_url {
                    outcome.failed.push(url);
                }
                if let Some(note) = note {
                    outcome.notes.push(note);
                }
            }
            Err(_) => {} // panicked probe task — nothing to record
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
        assert!(!health.strike(url, 1_000, StrikeReason::Drop));
        assert!(!health.is_demoted(url, 1_000));
        // Second strike inside the window demotes.
        assert!(health.strike(url, 1_060, StrikeReason::Drop));
        assert!(health.is_demoted(url, 1_060));
        assert!(health.is_demoted(url, 1_060 + DEMOTION_COOLDOWN_SECS - 1));
        // Cooldown lapses — candidacy restored.
        assert!(!health.is_demoted(url, 1_060 + DEMOTION_COOLDOWN_SECS + 1));
    }

    #[test]
    fn same_incident_strikes_dedup() {
        let mut health = EndpointHealth::default();
        let url = "wss://node.example/borsh";
        assert!(!health.strike(url, 1_000, StrikeReason::Drop));
        // A phantom-kill echo 2 s later is the SAME incident — one strike.
        assert!(!health.strike(url, 1_002, StrikeReason::Drop));
        assert!(!health.is_demoted(url, 1_002));
        // A real second flap 60 s later is a new incident — demoted.
        assert!(health.strike(url, 1_060, StrikeReason::Drop));
    }

    #[test]
    fn stale_strike_restarts_the_count() {
        let mut health = EndpointHealth::default();
        let url = "wss://node.example/borsh";
        assert!(!health.strike(url, 1_000, StrikeReason::Drop));
        // Far outside the window: count restarts at 1, no demotion.
        assert!(!health.strike(url, 1_000 + STRIKE_WINDOW_SECS + 10, StrikeReason::Drop));
        assert!(!health.is_demoted(url, 1_000 + STRIKE_WINDOW_SECS + 10));
    }

    #[test]
    fn clean_run_clears_strikes() {
        let mut health = EndpointHealth::default();
        let url = "wss://node.example/borsh";
        assert!(!health.strike(url, 1_000, StrikeReason::Drop));
        health.clean_run(url);
        // The next strike is a fresh first strike, not the demoting second.
        assert!(!health.strike(url, 1_010, StrikeReason::Drop));
    }

    #[test]
    fn ledger_round_trips_and_skips_corrupt_lines() {
        let path = tmp("health");
        let _ = std::fs::remove_file(&path);

        let mut health = EndpointHealth::default();
        health.strike("wss://a.example/borsh", 5_000, StrikeReason::Drop);
        health.strike("wss://a.example/borsh", 5_100, StrikeReason::Drop); // demoted
        health.strike("wss://b.example/borsh", 6_000, StrikeReason::Drop);
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
        assert!(loaded
            .race_pantry(None, 6_000, PANTRY_DIALS, false)
            .is_empty());
        // And the migrated ledger round-trips in the NEW format.
        loaded.save(&path);
        let reloaded = EndpointHealth::load(&path);
        assert!(reloaded.is_demoted("wss://nora.kaspa.stream/kaspa/mainnet/wrpc/borsh", 5_600));
        let _ = std::fs::remove_file(&path);
    }

    /// R2 D4's instrumentation: the run length of a drop that convicts NOBODY
    /// is still recorded durably. D-095 could not re-examine
    /// [`MIN_STRIKE_RUN_SECS`] because the second incident's run lengths had
    /// rolled out of the ring; a floor is judged by what it absorbs, so the
    /// absorbed drops are exactly the ones that must survive a restart.
    #[test]
    fn a_churn_noise_run_is_recorded_even_though_it_convicts_nobody() {
        let path = tmp("health-r2-runs");
        let url = "wss://nora.kaspa.stream/kaspa/mainnet/wrpc/borsh";
        let mut health = EndpointHealth::default();

        // The 14:11 cycle: a 2 s run, acquitted as churn noise.
        let churn = 2;
        assert_eq!(judge_run(churn), RunJudgment::ChurnNoise);
        health.record_run(url, churn);
        health.save(&path);

        let reloaded = EndpointHealth::load(&path);
        assert_eq!(
            reloaded.last_run_secs(url),
            Some(churn),
            "the absorbed drop must survive the restart — it is the evidence"
        );
        // Acquitted means acquitted: no strike, no demotion.
        assert!(!reloaded.is_demoted(url, 10_000));
        assert_eq!(reloaded.last_reason(url), Some((StrikeReason::Unknown, 0)));
        let _ = std::fs::remove_file(&path);
    }

    /// The field-found defect, pinned: the exact string the V60 produced
    /// through a scripted outage must classify as DNS, not as a node fault.
    #[test]
    fn the_devices_own_dns_failure_text_classifies_as_dns() {
        // Verbatim from ~/device_captures/r2_field_20260730_201322/r2_outage.log
        let device_text = "probe dial wss://nora.kaspa.stream/kaspa/mainnet/wrpc/borsh: \
                           wRPC -> WebSocket -> IO error: failed to lookup address \
                           information: No address associated with hostname";
        assert_eq!(
            StrikeReason::classify_probe_failure(device_text),
            StrikeReason::DnsFailure,
            "the failure that convicted four healthy endpoints must be recognisable"
        );
    }

    /// The correlation rule. A resolver outage hits every candidate at once;
    /// a dead node's pulled record hits exactly one.
    #[test]
    fn dns_is_the_resolvers_fault_only_when_distinct_hosts_fail_together() {
        let f = |host: &str, r| (format!("wss://{host}/kaspa/mainnet/wrpc/borsh"), r);

        // The field case: four distinct hosts, four distinct domains, one round.
        let outage = vec![
            f("nora.kaspa.stream", StrikeReason::DnsFailure),
            f("tess.kaspa.red", StrikeReason::DnsFailure),
            f("vivi.kaspa.blue", StrikeReason::DnsFailure),
            f("eva.kaspa.green", StrikeReason::DnsFailure),
        ];
        assert!(dns_outage_in_round(&outage));

        // ONE node's record pulled — genuinely that node's problem. This is
        // the case the rule must NOT excuse, or a dead endpoint becomes
        // permanently unstrikeable.
        let lone = vec![f("nora.kaspa.stream", StrikeReason::DnsFailure)];
        assert!(!dns_outage_in_round(&lone));
        assert_eq!(
            judge_admissibility(StrikeReason::DnsFailure, 10_000, 0, 0, false, 0),
            Admissibility::Convict(StrikeReason::DnsFailure)
        );

        // The SAME host twice is one witness, not two — corroboration must
        // come from distinct endpoints or the rule corroborates itself.
        let repeated = vec![
            f("nora.kaspa.stream", StrikeReason::DnsFailure),
            f("nora.kaspa.stream", StrikeReason::DnsFailure),
        ];
        assert!(!dns_outage_in_round(&repeated));

        // A DNS failure beside an unrelated failure is still one DNS witness.
        let mixed = vec![
            f("nora.kaspa.stream", StrikeReason::DnsFailure),
            f("tess.kaspa.red", StrikeReason::HttpServerError),
        ];
        assert!(!dns_outage_in_round(&mixed));
    }

    /// Correlated DNS is withheld — and the ivy bar still holds inside the
    /// very round that excuses everything else.
    #[test]
    fn a_correlated_dns_round_withholds_dns_but_never_an_answering_node() {
        assert_eq!(
            judge_admissibility(StrikeReason::DnsFailure, 10_000, 0, 0, true, 0),
            Admissibility::Withhold(StrikeReason::DnsFailure)
        );
        // A node that ANSWERED with a 500 in the same round proved it was
        // reachable — the resolver outage is no alibi for it.
        assert_eq!(
            judge_admissibility(StrikeReason::HttpServerError, 10_000, 0, 0, true, 0),
            Admissibility::Convict(StrikeReason::HttpServerError)
        );
        // And a non-DNS failure in a DNS-correlated round is judged on its
        // own merits, not swept up by the round's verdict.
        assert_eq!(
            judge_admissibility(StrikeReason::ProbeFailed, 10_000, 0, 0, true, 0),
            Admissibility::Convict(StrikeReason::ProbeFailed)
        );
    }

    /// **R3 D-099 — the field-found phone-fault vocabulary, pinned to the
    /// device's own bytes.** The 2026-07-31 00:56:17 capture: every candidate
    /// failed `Network is unreachable (os error 101)` 1.5 s after a Wi-Fi
    /// re-association — the OS's own no-route verdict, never node evidence.
    #[test]
    fn the_devices_own_enetunreach_text_classifies_as_unreachable() {
        // Verbatim shape from ~/device_captures/r3_observer_20260731_0105/
        let device_text = "probe dial wss://isla.kaspa.red/kaspa/mainnet/wrpc/borsh: \
                           wRPC -> WebSocket -> IO error: Network is unreachable \
                           (os error 101)";
        assert_eq!(
            StrikeReason::classify_probe_failure(device_text),
            StrikeReason::Unreachable
        );
        // Tokens round-trip: the ledger vocabulary grew, it did not shift.
        assert_eq!(
            StrikeReason::from_token(StrikeReason::Unreachable.as_token()),
            StrikeReason::Unreachable
        );
        assert_eq!(
            StrikeReason::from_token(StrikeReason::LinkBlackout.as_token()),
            StrikeReason::LinkBlackout
        );
    }

    /// A round is phone-fault when ≥2 DISTINCT hosts fail with phone-side
    /// reasons — DNS and ENETUNREACH corroborate EACH OTHER (the 2026-07-31
    /// 00:59:41 round mixed 2 DNS + 2 unreachable), and a LONE failure of
    /// either kind stays ambiguous (wallet-security finding: a chronically
    /// routeless AAAA-only host must not become undemotable, mirroring the
    /// lone-DNS rule).
    #[test]
    fn phone_fault_round_needs_two_distinct_phone_side_hosts() {
        let f = |host: &str, reason| (format!("wss://{host}/kaspa/mainnet/wrpc/borsh"), reason);
        // Mixed corroboration — the real 00:59:41 round shape.
        assert!(phone_fault_in_round(&[
            f("vivi.kaspa.blue", StrikeReason::DnsFailure),
            f("isla.kaspa.red", StrikeReason::Unreachable),
        ]));
        // Pure unreachable across distinct hosts — the 00:56:17 round shape.
        assert!(phone_fault_in_round(&[
            f("eva.kaspa.green", StrikeReason::Unreachable),
            f("ivy.kaspa.green", StrikeReason::Unreachable),
        ]));
        // Lone failures of either kind stay ambiguous; the same host twice
        // is one witness; a 500 proves nothing about the phone; an empty
        // round proves nothing at all.
        assert!(!phone_fault_in_round(&[f(
            "isla.kaspa.red",
            StrikeReason::Unreachable
        )]));
        assert!(!phone_fault_in_round(&[f(
            "nora.kaspa.stream",
            StrikeReason::DnsFailure
        )]));
        assert!(!phone_fault_in_round(&[
            f("isla.kaspa.red", StrikeReason::Unreachable),
            f("isla.kaspa.red", StrikeReason::Unreachable),
        ]));
        assert!(!phone_fault_in_round(&[f(
            "tess.kaspa.red",
            StrikeReason::HttpServerError
        )]));
        assert!(!phone_fault_in_round(&[]));
    }

    /// The race-intake guard (R3 wallet-security): a resolver URL carrying
    /// whitespace or control bytes is never dialable — but a space smuggles
    /// failure-phrase text past `scrub_urls` into the classifier, and a
    /// tab/newline forges rows in the health TSV. Reject at the door.
    #[test]
    fn candidate_url_guard_rejects_whitespace_and_control_bytes() {
        assert!(candidate_url_is_clean(
            "wss://nora.kaspa.stream/kaspa/mainnet/wrpc/borsh"
        ));
        assert!(!candidate_url_is_clean(""));
        assert!(!candidate_url_is_clean(
            "wss://h.example/ network is unreachable"
        ));
        assert!(!candidate_url_is_clean("wss://h.example/\tforged\trow"));
        assert!(!candidate_url_is_clean("wss://h.example/\nwss://victim"));
        assert!(!candidate_url_is_clean("wss://h.example/\u{7f}x"));
    }

    /// **R3 D-099 admissibility.** An ENETUNREACH loss is correlation-gated
    /// like DNS (lone convicts, correlated withholds); a pending drop/stall
    /// strike is refuted by a
    /// phone-fault round stamped at-or-after the death (`eva`, convicted at
    /// 00:59:51 while the interposed round failed every candidate with
    /// ENETUNREACH, is the regression case); the ivy 500 bar survives every
    /// arm; and race-loss reasons are never swept up by the stamp.
    #[test]
    fn link_blackout_refutes_pending_drops_but_never_answering_nodes() {
        // ENETUNREACH mirrors DNS: withheld when the round correlated it,
        // convictable alone (the chronic AAAA-only host stays demotable).
        assert_eq!(
            judge_admissibility(StrikeReason::Unreachable, 10_000, 0, 0, true, 0),
            Admissibility::Withhold(StrikeReason::Unreachable)
        );
        assert_eq!(
            judge_admissibility(StrikeReason::Unreachable, 10_000, 0, 0, false, 0),
            Admissibility::Convict(StrikeReason::Unreachable)
        );
        let drop_at = 10_000;
        // The round after the drop proved the phone broken → refuted.
        assert_eq!(
            judge_admissibility(StrikeReason::Drop, drop_at, 0, 0, false, drop_at + 5),
            Admissibility::Withhold(StrikeReason::LinkBlackout)
        );
        // Same-second stamp still refutes (the race can fail within the
        // death's own second on a fast retry).
        assert_eq!(
            judge_admissibility(StrikeReason::Drop, drop_at, 0, 0, false, drop_at),
            Admissibility::Withhold(StrikeReason::LinkBlackout)
        );
        // A stall execution gets the same refutation — its evidence is the
        // same in-absentia kind.
        assert_eq!(
            judge_admissibility(StrikeReason::Stall, drop_at, 0, 0, false, drop_at + 5),
            Admissibility::Withhold(StrikeReason::LinkBlackout)
        );
        // A stamp OLDER than the death excuses nothing: the blackout ended
        // before this socket died.
        assert_eq!(
            judge_admissibility(StrikeReason::Drop, drop_at, 0, 0, false, drop_at - 1),
            Admissibility::Convict(StrikeReason::Drop)
        );
        // Never-stamped (0) convicts as before.
        assert_eq!(
            judge_admissibility(StrikeReason::Drop, drop_at, 0, 0, false, 0),
            Admissibility::Convict(StrikeReason::Drop)
        );
        // The ivy bar: a 500 in the blackout's own second still convicts.
        assert_eq!(
            judge_admissibility(StrikeReason::HttpServerError, drop_at, 0, 0, false, drop_at),
            Admissibility::Convict(StrikeReason::HttpServerError)
        );
        // Race-loss reasons are judged with a live winner present — the
        // stamp must not acquit them wholesale.
        assert_eq!(
            judge_admissibility(StrikeReason::DialTimeout, drop_at, 0, 0, false, drop_at + 5),
            Admissibility::Convict(StrikeReason::DialTimeout)
        );
    }

    /// **R2 D5 — the exhaustion floor, with the WHOLE pantry demoted.**
    /// D-095 burned six of eleven endpoints in 108 s with 600 s cooldowns, so
    /// "what happens at 11 of 11?" stopped being hypothetical. Read from the
    /// code: `race_loop` sets `advisory = empty_rounds >= 2` and then passes
    /// an EMPTY demoted set, so demoted endpoints re-enter the race — the
    /// wallet always has something to dial and never waits out a cooldown in
    /// the dark. INV-6's unilateral exit is present.
    ///
    /// This pins both halves of that floor, because only one half existed
    /// before R2: the demoted SET degraded, but `race_pantry` filtered
    /// demotions on its own regardless, so the immediate-dial fast path stayed
    /// empty at exactly the moment every candidate was demoted.
    #[test]
    fn the_whole_pantry_demoted_still_leaves_the_wallet_something_to_dial() {
        let now = 10_000;
        let mut health = EndpointHealth::default();
        let urls: Vec<String> = (0..11)
            .map(|i| format!("wss://n{i}.kaspa.stream/kaspa/mainnet/wrpc/borsh"))
            .collect();
        // Every endpoint healthy recently, then every endpoint demoted —
        // the D-095 end state, taken all the way to 11 of 11.
        for url in &urls {
            health.mark_healthy(url, now - 60);
            health.strike(url, now - 30, StrikeReason::Drop);
            health.backdate_last_strike(url, STRIKE_DEDUP_SECS + 1);
            health.strike(url, now - 20, StrikeReason::Drop);
        }
        assert_eq!(
            health.demoted_set(now).len(),
            urls.len(),
            "the fixture must actually reach total exhaustion"
        );

        // Normal hygiene: nothing is offered. This IS the dark-wallet state,
        // and it is why the advisory degradation has to exist.
        assert!(
            health
                .race_pantry(None, now, PANTRY_DIALS, false)
                .is_empty(),
            "under normal hygiene a fully demoted pantry offers nothing"
        );

        // The floor: hygiene degrades to advisory and the fast path comes
        // back, still capped at PANTRY_DIALS and still most-recent-first.
        let floor = health.race_pantry(None, now, PANTRY_DIALS, true);
        assert_eq!(
            floor.len(),
            PANTRY_DIALS,
            "the advisory pantry must offer candidates when every one is demoted"
        );

        // And the floor is a degradation, not an amnesty: the ledger still
        // knows they are demoted, so the moment anything healthier exists the
        // normal path resumes.
        for url in &floor {
            assert!(
                health.is_demoted(url, now),
                "the advisory dial must not silently clear the demotion"
            );
        }
    }

    /// **R2 D3 regression bar — the rule must not acquit `ivy`.** D-092
    /// ruling 6 recorded a real, earned demotion: ivy answered HTTP 500 twice,
    /// once caught live. An inadmissibility rule that would have spared it is
    /// a worse defect than the flapping it cures, because it teaches the
    /// ledger to forgive nodes that genuinely fail. So: even with BOTH excuses
    /// active and perfectly coincident, an `http-5xx` is still convicted.
    #[test]
    fn no_excuse_acquits_a_node_that_answered_with_an_error() {
        let at = 10_000;
        assert_eq!(
            judge_admissibility(StrikeReason::HttpServerError, at, at, at, false, 0),
            Admissibility::Convict(StrikeReason::HttpServerError),
            "ivy's earned strike must survive every excuse the rule can offer"
        );
    }

    /// The rule fires only when a signal actually says so. On a healthy link
    /// (no OS loss ever seen, no doubled connect ever seen) every reason is
    /// admissible — the window cannot open on its own.
    #[test]
    fn a_healthy_link_withholds_nothing() {
        for reason in [
            StrikeReason::Drop,
            StrikeReason::ProbeFailed,
            StrikeReason::DialTimeout,
            StrikeReason::BindFailed,
            StrikeReason::Stall,
        ] {
            assert_eq!(
                judge_admissibility(reason, 10_000, 0, 0, false, 0),
                Admissibility::Convict(reason),
                "{} was withheld with no signal to justify it",
                reason.as_token()
            );
        }
    }

    /// The R1 sample, replayed: `tess` was struck 86 ms after `network_lost`
    /// on a scripted Wi-Fi kill. That strike is now withheld — and the
    /// endpoint keeps its record, because withholding is not erasure.
    #[test]
    fn an_os_adjacent_drop_is_withheld_and_still_recorded() {
        let drop_at = 10_000;
        assert_eq!(
            judge_admissibility(StrikeReason::Drop, drop_at, drop_at, 0, false, 0),
            Admissibility::Withhold(StrikeReason::OsLostAdjacent)
        );

        let url = "wss://tess.kaspa.stream/kaspa/mainnet/wrpc/borsh";
        let mut health = EndpointHealth::default();
        health.withhold(url, StrikeReason::OsLostAdjacent);
        // Not convicted...
        assert!(!health.is_demoted(url, drop_at));
        // ...but not forgotten either.
        assert_eq!(
            health.last_reason(url),
            Some((StrikeReason::OsLostAdjacent, 1))
        );
    }

    /// The OS is routinely SLOWER than the socket to notice a dead link, so
    /// the window must look FORWARD as well as back. A backward-only window
    /// would leave the rule looking implemented while convicting the very
    /// endpoints it exists to protect.
    #[test]
    fn the_os_window_catches_a_loss_reported_after_the_drop() {
        let drop_at = 10_000;
        // OS notices three seconds LATER — the common real ordering.
        assert_eq!(
            judge_admissibility(StrikeReason::Drop, drop_at, drop_at + 3, 0, false, 0),
            Admissibility::Withhold(StrikeReason::OsLostAdjacent)
        );
        // Outside the window in either direction, the node answers for it.
        assert_eq!(
            judge_admissibility(
                StrikeReason::Drop,
                drop_at,
                drop_at + OS_LOST_ADJACENCY_SECS + 1,
                0,
                false,
                0
            ),
            Admissibility::Convict(StrikeReason::Drop)
        );
        assert_eq!(
            judge_admissibility(
                StrikeReason::Drop,
                drop_at,
                drop_at - OS_LOST_ADJACENCY_SECS - 1,
                0,
                false,
                0
            ),
            Admissibility::Convict(StrikeReason::Drop)
        );
    }

    /// D2's finding, enforced: a drop next to the item-9 tripwire is OURS.
    /// The pinned client re-dials on its own, so a socket can die that our
    /// reconnect authority never created — and no node should pay for it.
    #[test]
    fn a_drop_next_to_a_doubled_connect_is_ours_not_the_nodes() {
        let at = 10_000;
        assert_eq!(
            judge_admissibility(StrikeReason::Drop, at, 0, at + 1, false, 0),
            Admissibility::Withhold(StrikeReason::SelfInflicted)
        );
        // An old tripwire is not a standing amnesty.
        assert_eq!(
            judge_admissibility(
                StrikeReason::Drop,
                at,
                0,
                at - SELF_INFLICTED_ADJACENCY_SECS - 1,
                false,
                0
            ),
            Admissibility::Convict(StrikeReason::Drop)
        );
    }

    /// Unix 0 means "never observed", and at unix 0 everything is adjacent to
    /// everything — so the never-observed case must be an explicit check, not
    /// arithmetic. A phone whose clock reads near the epoch must not have its
    /// whole pantry acquitted.
    #[test]
    fn a_never_observed_signal_is_not_an_amnesty_at_the_epoch() {
        assert_eq!(
            judge_admissibility(StrikeReason::Drop, 1, 0, 0, false, 0),
            Admissibility::Convict(StrikeReason::Drop)
        );
    }

    /// **R2 D2 — the mechanism, reproduced.** D-095 hypothesised that a losing
    /// race dial landed late on the shared socket. That is structurally
    /// impossible: [`probe_endpoint`] builds its OWN `KaspaRpcClient`, so a
    /// loser cannot emit on the shared client's ctl channel. The real
    /// mechanism is one layer down, and this test provokes it.
    ///
    /// `WebSocket::connect` (pin `workflow-websocket 0.18.0
    /// client/native.rs:161-250`) spawns a DETACHED `'outer` loop. When a
    /// connection that successfully opened later dies, the loop falls to
    /// `if !this.reconnect.load() { break 'outer }` and, finding `reconnect`
    /// still true, **re-dials on its own** — no caller involved, and the
    /// `Fallback` strategy does not stop it (Fallback only breaks out of the
    /// two connect-FAILURE arms, never after a successful open).
    ///
    /// So the pin holds a reconnect authority of its own. D-081 established
    /// the app as "the one reconnect authority"; that is true of OUR code and
    /// not true of the stack as a whole. `reconnect` is cleared only by
    /// `disconnect()`, and our teardown is a bounded, detached task reacting
    /// to a ctl event that arrives a channel hop later — so the pin's loop is
    /// already re-dialing before our disconnect can run.
    ///
    /// Consequences that convict healthy nodes (D-095's six):
    /// - A spurious re-dial that succeeds emits a second `Ctl::Connect` with
    ///   no intervening `Disconnect` — exactly the item-9 signature captured
    ///   at 14:11:08.519/.771 in `r2_flap_20260730_135734/ring_raw.txt`.
    /// - `Ctl::Disconnect` carries no URL, and the monitor attributes it via
    ///   `client.url()` — the DESCRIPTOR, set by the most recent `connect()`.
    ///   A stale loop's socket dying is therefore charged to whatever endpoint
    ///   the race most recently bound. That is a self-inflicted strike against
    ///   a node that did nothing wrong.
    #[tokio::test(flavor = "multi_thread")]
    async fn the_pinned_client_redials_a_dropped_socket_with_no_caller() {
        use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let dials = std::sync::Arc::new(AtomicUsize::new(0));

        // A server that completes a REAL ws handshake and then drops the
        // socket. The handshake matters: a refused port takes the pin's
        // connect-failure arm (which Fallback does break out of), and would
        // prove nothing. This is the "healthy socket dies" moment.
        let served = dials.clone();
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                served.fetch_add(1, AtomicOrdering::SeqCst);
                tokio::spawn(async move {
                    if let Ok(ws) = tokio_tungstenite::accept_async(stream).await {
                        drop(ws);
                    }
                });
            }
        });

        let url = format!("ws://{addr}/");
        let network_id = NetworkId::new(kaspa_wrpc_client::prelude::NetworkType::Mainnet);
        let client = KaspaRpcClient::new_with_args(
            WrpcEncoding::Borsh,
            Some(&url),
            None,
            Some(network_id),
            None,
        )
        .unwrap();

        // ONE connect call. Nothing below asks for another.
        client
            .connect(Some(ConnectOptions {
                url: Some(url.clone()),
                strategy: ConnectStrategy::Fallback,
                block_async_connect: true,
                connect_timeout: Some(Duration::from_secs(2)),
                ..Default::default()
            }))
            .await
            .expect("the loopback ws server must accept the first dial");

        // At least one dial reached the server — but deliberately NOT `== 1`.
        // That equality was the original assertion and it is FLAKY, because the
        // very behaviour under test defeats it: the pin's loop can re-dial
        // before `connect()` has even returned to us, so a "baseline" reading
        // of exactly one dial is a moment that need not exist. Observed failing
        // at 2 on a warm run. Asserting it would have bought intermittent CI
        // reds — and the failure is itself evidence, so it is recorded here
        // rather than tuned away with a sleep.
        let after_first = dials.load(AtomicOrdering::SeqCst);
        assert!(
            after_first >= 1,
            "the loopback server must have seen the initial dial"
        );

        tokio::time::sleep(Duration::from_millis(700)).await;
        let total = dials.load(AtomicOrdering::SeqCst);
        // Recorded, not asserted: the RATE is environment-sensitive, but it is
        // the number that shows this is a spin, not a single stray retry.
        // Measured 4 on the R2 dev box — a re-dial roughly every 175 ms, for
        // as long as `reconnect` stays true.
        println!("R2 D2: {total} dial(s) reached the server after ONE connect() call");

        // Clean up before asserting, so a failure cannot leave the loop
        // hammering the loopback server for the rest of the suite.
        //
        // BOUNDED, and that is the whole point (F47, product-audit run 3). A raw
        // `client.disconnect().await` here hung the WHOLE test binary — not
        // alone, and not in `link::` alone, but under the full 226-test parallel
        // load, where this test's own subject (a client spinning a re-dial every
        // ~175 ms) starves its teardown. `bounded_disconnect`'s own doc says the
        // teardown "MAY never complete (a starved handshake can be orphaned
        // forever)"; the production paths were bounded for that reason by the C2
        // fix and this test was not. `cargo test` then blocked forever with no
        // per-test timeout: three orphaned test binaries were found alive on the
        // dev box, aged 4h46m, 18h32m and counting, each with this test's thread
        // parked on a futex.
        bounded_disconnect(client, DISCONNECT_WAIT_TIMEOUT).await;

        assert!(
            total > 1,
            "the pin re-dialed {total} time(s) after ONE connect() call — if this is 1, \
             the pinned client no longer self-reconnects and R2's D2 finding (and the \
             self-inflicted-strike reasoning built on it) must be re-derived"
        );
    }

    /// R2 D1 acceptance: a strike written under EACH reason is read back after
    /// the process dies. `load` from a file the running process never touched
    /// IS the process-kill simulation — the ledger's whole point is that it
    /// outlives the app (L65: the durable twin reconstructed a session 90
    /// minutes and one reboot gone).
    #[test]
    fn every_strike_reason_survives_a_process_kill() {
        let path = tmp("health-r2-reasons");
        let reasons = [
            StrikeReason::Drop,
            StrikeReason::ProbeFailed,
            StrikeReason::DialTimeout,
            StrikeReason::HttpServerError,
            StrikeReason::BindFailed,
            StrikeReason::Stall,
        ];
        let url_for = |i: usize| format!("wss://n{i}.kaspa.stream/kaspa/mainnet/wrpc/borsh");

        let mut health = EndpointHealth::default();
        for (i, reason) in reasons.iter().enumerate() {
            health.strike(&url_for(i), 10_000, *reason);
        }
        health.save(&path);

        // Nothing of the writer survives into the reader — a cold load.
        let reloaded = EndpointHealth::load(&path);
        for (i, reason) in reasons.iter().enumerate() {
            assert_eq!(
                reloaded.last_reason(&url_for(i)),
                Some((*reason, 0)),
                "reason {} did not survive the reload",
                reason.as_token()
            );
        }
        let _ = std::fs::remove_file(&path);
    }

    /// The schema-forgiveness clause, proven against a PRE-R2 file: five
    /// fields, no reason, no withheld count. A phone that upgrades mid-
    /// cooldown must keep its demotions — dropping the row for being short
    /// would silently acquit every endpoint the ledger had convicted.
    #[test]
    fn pre_r2_ledger_loads_with_unknown_reason_and_keeps_its_demotions() {
        let path = tmp("health-r2-oldfile");
        std::fs::write(
            &path,
            "wss://ivy.kaspa.blue/kaspa/mainnet/wrpc/borsh\t2\t5100\t5700\t5000\n\
             wss://eva.kaspa.stream/kaspa/mainnet/wrpc/borsh\t1\t6000\t0\t5900\n",
        )
        .unwrap();
        let loaded = EndpointHealth::load(&path);

        // The demotion is intact — the upgrade did not acquit ivy.
        assert!(loaded.is_demoted("wss://ivy.kaspa.blue/kaspa/mainnet/wrpc/borsh", 5_600));
        // The 5th field still parses (the C6 forgiveness is not regressed),
        // and the surviving demotion still does its job: at 5_600 ivy is
        // sitting out, so the pantry offers eva alone. (Past 5_700 ivy is
        // legitimately back — the cooldown lapsing is the ledger healing,
        // not the loader forgetting.)
        assert_eq!(
            loaded.race_pantry(None, 5_600, PANTRY_DIALS, false),
            vec!["wss://eva.kaspa.stream/kaspa/mainnet/wrpc/borsh".to_string()],
        );
        // And the new fields default HONESTLY: the record predates the reason
        // field, so its `why` is Unknown — not a guess, and not a default that
        // would read as an actual classification.
        assert_eq!(
            loaded.last_reason("wss://ivy.kaspa.blue/kaspa/mainnet/wrpc/borsh"),
            Some((StrikeReason::Unknown, 0))
        );
        let _ = std::fs::remove_file(&path);
    }

    /// A node must not be able to classify its OWN failures by choosing a
    /// hostname. Without the scrub, our wrapper's embedded URL puts the
    /// node's chosen bytes into the matcher's input.
    #[test]
    fn a_node_cannot_buy_leniency_with_its_hostname() {
        // The exact shape `probe_endpoint` produces, with an adversarial host.
        let hostile = "probe dial wss://timeout.example/kaspa/mainnet/wrpc/borsh: \
                       wRPC -> WebSocket -> connection refused";
        assert_eq!(
            StrikeReason::classify_probe_failure(hostile),
            StrikeReason::ProbeFailed,
            "a hostname containing 'timeout' must not classify as dial-timeout"
        );
        // The genuine article still classifies — the scrub narrows the input,
        // it does not blind the matcher.
        let real = "probe info wss://nora.kaspa.stream/kaspa/mainnet/wrpc/borsh: timeout";
        assert_eq!(
            StrikeReason::classify_probe_failure(real),
            StrikeReason::DialTimeout
        );
    }

    /// `http-5xx` is the one token D3 must never excuse, so it must not be
    /// lost to truncation: `sanitize_node_text` caps at 200 chars and a long
    /// URL is the longest run in the wrapper. Scrub-then-sanitize keeps the
    /// verdict; sanitize-then-scrub would drop it to `probe-failed`.
    #[test]
    fn an_earned_http_5xx_survives_a_very_long_url() {
        let long_url = format!("wss://ivy.kaspa.blue/{}/wrpc/borsh", "x".repeat(180));
        let text = format!(
            "probe dial {long_url}: wRPC -> WebSocket -> WebSocket error: \
             HTTP error: 500 Internal Server Error"
        );
        assert!(text.len() > 200, "fixture must exceed the sanitize cap");
        assert_eq!(
            StrikeReason::classify_probe_failure(&text),
            StrikeReason::HttpServerError,
            "ivy's earned guilt must survive a long URL"
        );
    }

    /// An unrecognised token from a NEWER build degrades to Unknown rather
    /// than dropping the row — forward compatibility, same forgiveness as an
    /// absent field.
    #[test]
    fn an_unknown_reason_token_degrades_without_losing_the_record() {
        let path = tmp("health-r2-futuretoken");
        std::fs::write(
            &path,
            "wss://ivy.kaspa.blue/kaspa/mainnet/wrpc/borsh\t2\t5100\t5700\t5000\tquantum-flap\t3\n",
        )
        .unwrap();
        let loaded = EndpointHealth::load(&path);
        assert!(loaded.is_demoted("wss://ivy.kaspa.blue/kaspa/mainnet/wrpc/borsh", 5_600));
        assert_eq!(
            loaded.last_reason("wss://ivy.kaspa.blue/kaspa/mainnet/wrpc/borsh"),
            Some((StrikeReason::Unknown, 3)),
            "an unreadable token must not cost us the withheld count beside it"
        );
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
        health.strike("wss://demoted.example/borsh", now - 20, StrikeReason::Drop);
        health.backdate_last_strike("wss://demoted.example/borsh", STRIKE_DEDUP_SECS + 1);
        health.strike("wss://demoted.example/borsh", now - 5, StrikeReason::Drop); // second strike demotes
        assert!(health.is_demoted("wss://demoted.example/borsh", now));

        // The cached endpoint is deduped out even when it is the freshest.
        let pantry =
            health.race_pantry(Some("wss://recent.example/borsh"), now, PANTRY_DIALS, false);
        assert_eq!(
            pantry,
            vec![
                "wss://older.example/borsh".to_string(),
                "wss://oldest.example/borsh".to_string(),
                "wss://boundary.example/borsh".to_string(),
            ]
        );

        // Without the dedup, K caps the list and recency orders it.
        let pantry = health.race_pantry(None, now, PANTRY_DIALS, false);
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
        let pantry = health.race_pantry(None, after_cooldown, 10, false);
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

    /// R0 addendum #1 (built at R1): a lost round reports itself in ONE line,
    /// and the reasons survive the compression. The failing candidate must
    /// still land in `failed` (it is struck once the network proves alive —
    /// D-084) AND contribute a note naming itself, because the reason strings
    /// are what let a cold `endpoint.health` read be interpreted later (L65).
    #[tokio::test(flavor = "multi_thread")]
    async fn a_lost_round_carries_its_reasons_as_notes() {
        // A closed port: refused immediately, so no timeout to wait out.
        let closed = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = closed.local_addr().unwrap();
        drop(closed);
        let url = format!("ws://{addr}/borsh");
        let network_id = NetworkId::new(kaspa_wrpc_client::prelude::NetworkType::Mainnet);
        // fetches = 0: no resolver on the path, so this measures exactly the
        // immediate-candidate lane.
        let outcome = race(
            &Resolver::default(),
            network_id,
            Some(url.clone()),
            Vec::new(),
            &Default::default(),
            0,
            Duration::from_millis(400),
        )
        .await;

        assert!(outcome.winner.is_none(), "a closed port cannot win");
        assert_eq!(outcome.failed.len(), 1, "the node must be strikeable");
        assert_eq!(outcome.failed[0].0, url, "the strike must name the node");
        // A closed port refuses fast on most hosts and times out on some
        // (a filtered port drops the SYN); both are honest "it never
        // answered" verdicts. What matters for D3 is the one this must NOT
        // be: `http-5xx` means the node ANSWERED, which a closed port cannot.
        assert!(
            matches!(
                outcome.failed[0].1,
                StrikeReason::ProbeFailed | StrikeReason::DialTimeout
            ),
            "a closed port classified as {:?}",
            outcome.failed[0].1
        );
        assert_eq!(
            outcome.notes.len(),
            1,
            "one note per loss — no more, no less"
        );
        let (who, why) = &outcome.notes[0];
        assert!(
            who.contains(&addr.to_string()),
            "a note that cannot be attributed to a candidate is not evidence: {who}"
        );
        assert!(
            who.ends_with("[imm]"),
            "the immediate lane must stay distinguishable (C6 forensics): {who}"
        );
        assert!(!why.is_empty(), "a loss with no reason is not evidence");
    }

    /// The coalescing has ONE job: fewer BYTES in the ring, not just fewer
    /// lines (L65 — the ring evicts by size, and the first cut of addendum #1
    /// spent 1900 characters on a single round, which bought nothing). Pinned
    /// against the verbatim strings the device produced on 2026-07-30 during
    /// an 8-round outage.
    #[test]
    fn a_round_summary_groups_identical_reasons_and_stays_small() {
        let dns = "wRPC -> WebSocket -> WebSocket error: IO error: failed to lookup \
                   address information: No address associated with hostname";
        let seeder = |host: &str| {
            format!(
                "resolver fetch: Failed to connect: [Custom(\"Unable to connect to \
                 https://{host}/v2/kaspa/mainnet/any/wrpc/borsh: Reqwest: error sending \
                 request for url (https://{host}/v2/kaspa/mainnet/any/wrpc/borsh)\")]"
            )
        };
        let raw: Vec<(String, String)> = vec![
            ("tess[imm]", dns.to_string()),
            ("aria[imm]", dns.to_string()),
            ("kate[imm]", dns.to_string()),
            ("eva[imm]", dns.to_string()),
            ("resolver", seeder("jack.kaspa.blue")),
            ("resolver", seeder("luke.kaspa.blue")),
            ("resolver", seeder("ryan.kaspa.blue")),
        ]
        .into_iter()
        .map(|(w, y)| (w.to_string(), compact_reason(&y)))
        .collect();

        let line = summarize_losses(&raw);
        // Four identical DNS failures state their reason ONCE.
        assert_eq!(
            line.matches("No address associated with hostname").count(),
            1,
            "identical reasons must be stated once: {line}"
        );
        // Boilerplate the pin nests mid-string must be gone, not just
        // un-prefixed (the first device measurement spent 452 chars a round
        // because `strip_prefix` never matched a nested shape).
        assert!(
            !line.contains("wRPC -> WebSocket"),
            "transport boilerplate is not a reason: {line}"
        );
        assert!(
            line.starts_with("tess[imm],aria[imm],kate[imm],eva[imm]: "),
            "the actors group in first-seen order: {line}"
        );
        // Three seeder failures differ only by URL — compaction must make them
        // one reason, collapsed to `resolver×3`.
        assert!(
            line.contains("resolver×3"),
            "per-seeder URLs must not defeat grouping: {line}"
        );
        // The whole point, measured: the device emitted ~1900 chars for this
        // exact round.
        assert!(
            line.len() < 200,
            "a round summary that big does not buy retention ({} chars): {line}",
            line.len()
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
