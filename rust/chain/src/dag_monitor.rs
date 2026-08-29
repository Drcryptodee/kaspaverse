//! Connection lifecycle + notification subscription for the hello-DAG stream.
//!
//! Derived from the pinned rev's `rpc/wrpc/examples/subscriber` example
//! (originally at `90dbf074`; pin since bumped to `cfafeb4c` v2.0.1 — D-058;
//! INV-9). Key protocol fact from that source:
//! notification scopes live on the node for the lifetime of one RPC
//! connection — they are lost on disconnect, so every `RpcState::Connected`
//! event must re-register the listener and its scopes.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use kaspa_addresses::Prefix;
use kaspa_consensus_core::Hash;
use kaspa_wallet_core::rpc::{Rpc, RpcCtl};
use kaspa_wrpc_client::prelude::*;
use tokio::sync::{broadcast, oneshot};

use crate::acceptance::VccBatch;
use crate::error::Result;
use crate::link::{self, EndpointHealth};
use crate::link_rpc::LinkRpc;
use crate::spans;
use crate::transport::{self, TransportEvent};

/// Per-candidate probe budget in the connect race (dial + `get_server_info`).
/// Bounded like the old cached fast path (3 s) plus one health round-trip.
const PROBE_TIMEOUT: Duration = Duration::from_secs(4);

/// Bind budget for the shared socket's dial to the race winner — the node
/// answered a probe milliseconds ago, so a healthy bind is fast; a node that
/// died in between just re-enters the race.
const BIND_TIMEOUT: Duration = Duration::from_secs(3);

/// Parallel `Resolver::get_node` fetches per race round (the resolver API
/// returns ONE node per fetch — spec verified against the pinned source).
///
/// **This constant is an EXPONENT, not a count** (D-201's derivation, and the
/// reason it moved from 3 to 5 at LINK-P2). `Resolver::fetch` shuffles all 16
/// beacons and walks them SERIALLY with no per-URL timeout (pin
/// `resolver.rs:155-167`), so one hung beacon consumes the whole
/// `RESOLVER_FETCH_TIMEOUT` by itself and its walk yields nothing: a single
/// walk succeeds iff a yielding beacon precedes every hung one, `P = y/(y+b)`.
/// Each fetch re-shuffles independently, so a round of `RACE_FETCHES` walks
/// fails with `(b/(y+b))^RACE_FETCHES` — the fan-out is the only lever that
/// buys robustness WITHOUT making a user wait longer, which is why the budget
/// was left alone (see [`link::RESOLVER_FETCH_TIMEOUT`]).
///
/// Measured 2026-08-29 on the build host, reproducing `tools/beacon_floor.sh`'s
/// 2026-08-26 reading exactly: **y=9 yielding, b=5 hung, 2 fast-fail**. At 3
/// walks a cold round found nothing 4.6 % of the time and the derived floor sat
/// at y ≥ 8 — one host of margin on a good sample and zero on a bad one, which
/// D-201 records as a standing correction. At 5 the same fleet gives 0.6 % and
/// the floor drops to **y ≥ 6**. `tools/beacon_floor.sh` and `tools/preflight.sh`
/// assert that floor and BOTH carry this exponent: changing it here without
/// changing them there silently strands the only instrument watching the fleet
/// (the L135 shape — a constant whose watcher is keyed to its old value).
///
/// Cost, and there are THREE items, not two. (1) Two more small HTTPS GETs per
/// round. (2) A peak dial concurrency of 1 cached + `PANTRY_DIALS` +
/// `RACE_FETCHES` = 9; the round ceiling does NOT move, staying
/// `RESOLVER_FETCH_TIMEOUT + PROBE_TIMEOUT` = 9 s. (3) **The strike ledger.** A
/// WINNING round strikes every probe failure in it, and `StrikeReason::
/// DialTimeout` is not excused by `phone_fault_in_round` (which withholds only
/// `DnsFailure`/`Unreachable`), so more candidates per round is also more
/// CONVICTABLE candidates per round — and with `DEMOTE_AT_STRIKES` = 2 inside
/// `STRIKE_WINDOW_SECS` = 600, over a fleet whose yielding beacons front only
/// ~6 distinct nodes, that reaches a demotion sooner. A demoted node leaves
/// `race_pantry`, the warm-reconnect fast path this very change exists to
/// protect, so the failure mode would be self-defeating rather than merely
/// noisy. Raised by `wallet-security-auditor` and NOT dismissed — it is
/// unmeasured, not disproven. **What would falsify it:** an
/// `endpoint_strike`/`endpoint_demoted` span-rate comparison across a device
/// soak, before against after. Only if that shows spurious `DialTimeout`
/// strikes does `phone_fault_in_round` need widening; do not pre-emptively
/// loosen a conviction rule on a hypothesis.
const RACE_FETCHES: usize = 5;

/// Envelope bound for the WHOLE winner-bind call (consensus-audit BLOCK at
/// R0): the dial itself is bounded by [`BIND_TIMEOUT`], but
/// `KaspaRpcClient::connect`'s `Fallback` ERROR arm then locks
/// `disconnect_guard` and runs the shutdown handshake (pin
/// `client.rs:463-467`) — the same guard a starved detached teardown can
/// hold indefinitely (a dispatcher that exits via its error path never
/// answers `close()`'s shutdown handshake, so that teardown may never
/// finish). Sized dial 3 s + teardown-wait 5 s + margin. A timeout here is
/// treated as a failed bind and re-raced with NO strike: the endpoint just
/// won a probe — the block is our own guard, and convicting the node for it
/// would be a self-inflicted verdict (auditor item 18).
const BIND_ENVELOPE_TIMEOUT: Duration = Duration::from_secs(10);

/// Pause between race rounds when NO candidate was healthy (offline, resolver
/// unreachable) — the app-owned replacement for the abandoned ws-level
/// `ConnectStrategy::Retry` loop (D-081).
const RACE_RETRY_DELAY: Duration = Duration::from_secs(3);

/// Empty rounds a SWAP hunt spends before giving up and keeping the incumbent
/// (P0b). A cold hunt is unbounded — the wallet is dark and there is nothing
/// to preserve — but a swap runs *behind a working link*, so it must be a
/// bounded errand rather than a second search authority that never ends.
/// Three rounds is ~33 s on a link where nothing answers (a round is the
/// resolver fetch plus the probe, 9 s, with `RACE_RETRY_DELAY` between them),
/// and one round on a link where something does.
const SWAP_HUNT_ROUNDS: u32 = 3;

/// What a race loop is FOR — and the only thing that decides whether it may
/// bind over a live socket (P0b, tracker row 2026-08-28).
///
/// Before this, every race was a [`RaceMode::Cold`] one and the sequence was
/// **drop, then hunt**: `reconnect` retired the bind and *then* asked for a
/// search. Measured on the founder's Starlink link that cost a healthy
/// 275-second link and did not get one back inside five minutes — one tap,
/// on exactly the network where a user reaches for that control most.
///
/// The shape is now **find, then swap**: the live bind stays up for the whole
/// hunt, the incumbent is excluded from the candidate set so a winner is
/// always a genuinely different node, and the teardown happens inside
/// `install_bind` at the moment a replacement is armed — never for a race
/// that produces nothing.
#[derive(Debug, Clone, PartialEq, Eq)]
enum RaceMode {
    /// Nothing is bound (first connect, a socket death, resume, the OS
    /// signalling a new network). Unbounded rounds: the wallet is dark and
    /// only a node fixes that.
    Cold,
    /// A live bind is up and the user asked for a different node. Bounded by
    /// [`SWAP_HUNT_ROUNDS`]; `from` is the incumbent, excluded from every
    /// round's candidate set.
    Swap { from: String },
}

/// A swap that no longer has an incumbent is no longer a swap.
///
/// The socket it was preserving can vanish under it — its own death, a pause
/// that lost it, a hard pull-heal — and at that instant the wallet is dark and
/// the errand becomes the ordinary hunt: unbounded, and with nothing left to
/// exclude. Without this the loop would keep the swap's three-round bound and
/// give up on a DARK wallet, which is the failure the bound exists to prevent,
/// inverted. Pure so the law is provable without a network.
fn degrade_lost_swap(mode: RaceMode, connected: bool) -> RaceMode {
    match mode {
        RaceMode::Swap { .. } if !connected => RaceMode::Cold,
        other => other,
    }
}

/// The candidate URLs one round may NOT dial.
///
/// The incumbent of a swap is added AFTER the caller has already decided
/// whether hygiene demotions apply this round, and that order is the point:
/// "connectivity beats hygiene" is an argument about *demoted* nodes, and it
/// must never re-admit the one node the user just asked to leave. A swap that
/// could win by re-selecting the incumbent would report a successful swap and
/// change nothing.
fn round_exclusions(demoted: HashSet<String>, mode: &RaceMode) -> HashSet<String> {
    let mut excluded = demoted;
    if let RaceMode::Swap { from } = mode {
        excluded.insert(from.clone());
    }
    excluded
}

/// Has a swap hunt spent its budget **and does it still have something to
/// spend it on**? Cold hunts never have a budget — the wallet is dark and only
/// a node fixes that, so they run until they are bound, paused or shut down.
///
/// `incumbent_alive` is re-read at the call site rather than inherited from the
/// round's opening `mode`, which may be ~9 s stale by the time this is asked
/// (`consensus-auditor`, CONCERNS-1). A swap whose incumbent died mid-round has
/// nothing left to preserve, so spending its budget would end the hunt on a
/// dark wallet — with `on_disconnected`'s own `spawn_race` already refused,
/// because the loop asking this question still holds the single-flight flag.
fn swap_hunt_exhausted(mode: &RaceMode, empty_rounds: u32, incumbent_alive: bool) -> bool {
    incumbent_alive && matches!(mode, RaceMode::Swap { .. }) && empty_rounds >= SWAP_HUNT_ROUNDS
}

/// May this round drop the demotion ledger to keep the wallet dialing?
///
/// The floor exists so two barren rounds cannot leave a **dark** wallet with
/// nothing to dial — connectivity beats hygiene. A swap wallet is connected and
/// working, so that precondition is simply false for it, and with the bound at
/// [`SWAP_HUNT_ROUNDS`] an un-scoped rule fired on the last round of **every**
/// swap: a tap could trade a healthy incumbent for a node the ledger had
/// convicted, and then set `hygiene_advisory`, which suppresses the
/// Connected-time refusal that would have bounced it (`consensus-auditor`,
/// CONCERNS-2 — the L129 shape: a policy carried into a mode whose precondition
/// it no longer has).
fn hygiene_may_degrade(mode: &RaceMode, empty_rounds: u32) -> bool {
    empty_rounds >= 2 && matches!(mode, RaceMode::Cold)
}

/// Throttle for the catch-up cursor write in the hot BlockAdded path: at most
/// one tiny hash write this often. A killed app loses at most this much scan
/// progress, which the next open's catch-up re-covers anyway (idempotent — the
/// fold dedups by txid), so a coarse throttle costs nothing but I/O churn.
const TRANSPORT_CURSOR_MIN_WRITE_SECS: u64 = 3;

/// Bound on one catch-up replay (P5). `get_blocks` returns up to
/// ~`mergeset_size_limit`+1 blocks/page (mainnet = 2·ghostdag_k+1 = 249 at
/// 10 bps), so 48 pages ≈ 12k blocks ≈ **~20 min** of gap — a comfortable
/// idle/background window (the P2.3b sitting's first miss came from a 9-min
/// gap that was borderline under the old 24-page cap). The common small gap
/// stops early (a page of just the low_hash = caught up), so this ceiling only
/// costs work on a genuinely long outage — which is NOT fully recovered (an
/// indexer's job, INV-8; the P3 liveness surface tells the user to reconnect).
const MAX_CATCHUP_PAGES: u32 = 48;

/// Per-page `get_blocks` retry budget for the catch-up. The replay fires the
/// instant transport starts — often BEFORE the wRPC reconnect completes on a
/// cold reopen — so the first page routinely races a not-yet-live socket. We
/// retry (rather than give up after one error, the P2.3b sitting's
/// first-of-three miss) so a message that arrived while the app was closed is
/// never lost to a connect-timing race. Exhausting the budget = the node is
/// truly unreachable or the cursor is pruned; the walk then stops honestly.
const CATCHUP_RPC_ATTEMPTS: u32 = 15;
/// Delay between catch-up `get_blocks` retries — long enough to let a cold
/// wRPC socket finish connecting (cached fast-path ≤3 s; resolver a little
/// more), short enough that the recovery feels immediate.
const CATCHUP_RETRY_DELAY: Duration = Duration::from_millis(1000);

/// How long a RETIRED bind's task keeps servicing its own channels before it
/// exits (R4). Its events are all stale by then — the window exists so the
/// late teardown event that USED to kill the next socket (D-100: 1–5 ms after
/// `connected`, 85 times) is seen, counted and logged as discarded instead of
/// vanishing. Task lifecycle only — it gates no judgment and no dialing
/// decision.
///
/// **Sized above the WHOLE detached teardown, which is two legs since D-215,
/// not one.** The disconnect no longer starts when the drain clock does: the
/// unregister runs first inside the same spawned task, so the handshake this
/// window exists to witness can begin up to [`LISTENER_UNREGISTER_TIMEOUT`]
/// late. The old doc said "above `DISCONNECT_WAIT_TIMEOUT`", which was true
/// when the unregister was awaited before the drain began and is a
/// one-constant-bump away from silently false now — so the law is asserted
/// rather than described.
const RETIRED_DRAIN: Duration = Duration::from_secs(10);
// Compared in MILLIS, not secs: `as_secs()` floors, so an 8500 ms disconnect
// wait would compute 8 + 2 <= 10 and PASS while the real teardown runs 10.5 s
// and outlives the window (`wallet-security-auditor`). An assert that rounds
// its own inputs is the prose it replaced, in a shape that compiles.
const _: () = assert!(
    RETIRED_DRAIN.as_millis()
        >= LISTENER_UNREGISTER_TIMEOUT.as_millis() + link::DISCONNECT_WAIT_TIMEOUT.as_millis(),
    "RETIRED_DRAIN must outlast the whole detached teardown it exists to witness"
);

/// Bound on the best-effort listener unregister at a socket's end (R4).
///
/// The call is a courtesy to a node that, on a dropped socket, has already
/// forgotten us — but it is an RPC round trip, and the C2 sweep bounds it only
/// at the pin's ~65 s request timeout (CONNECTIVITY_PASS §5, finding (b)). That
/// was tolerable while it lived solely in the event loop; R4 routes every
/// teardown through one seam, so the same await now sits on `pause()` — the
/// app-backgrounding path — and on the race's re-bind. A live socket answers in
/// milliseconds; anything slower is a socket we are abandoning anyway.
const LISTENER_UNREGISTER_TIMEOUT: Duration = Duration::from_secs(2);

/// A chain event observed by the [`DagMonitor`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DagEvent {
    /// RPC connection established to `url` (endpoint picked by the resolver).
    Connected { url: Option<String> },
    /// RPC connection lost; the client keeps retrying in the background.
    Disconnected,
    /// The virtual's DAA score changed.
    VirtualDaaScore(u64),
    /// The blue score of the virtual's selected parent (sink) changed.
    SinkBlueScore(u64),
}

/// Map a node notification onto the events this monitor emits.
///
/// Display-only plumbing: values are passed through verbatim from the pinned
/// crates' notification structs — nothing is computed locally (INV-9).
fn map_notification(notification: &Notification) -> Option<DagEvent> {
    match notification {
        Notification::VirtualDaaScoreChanged(n) => {
            Some(DagEvent::VirtualDaaScore(n.virtual_daa_score))
        }
        Notification::SinkBlueScoreChanged(n) => Some(DagEvent::SinkBlueScore(n.sink_blue_score)),
        _ => None,
    }
}

/// **One bound socket — the unit of IDENTITY (R4/D-101).**
///
/// Before R4 the app owned ONE `KaspaRpcClient` for its whole life and every
/// socket took turns inside it. `RpcState` carries no identity (pin
/// `rpc/core/src/api/ctl.rs`: a bare `Connected|Disconnected`), and the pin's
/// `connect()` tears the previous socket down and restarts the ctl relay
/// (`client.rs:433` → `disconnect()` → `stop()` → `start()`), so a teardown's
/// `Disconnected` could be relayed AFTER the next bind's `Connected` and was
/// charged to it: 85 bind-die cycles in 18 minutes, self-sustaining until the
/// app was killed (D-100, L71).
///
/// Now each bind owns its client, its ctl channel, its notification channel
/// and its listener, and carries a `gen` stamped at install. Every intake
/// checks [`DagMonitor::is_current_bind`] first, so an event from a retired
/// socket can only ever be attributed to — and discarded on behalf of — the
/// socket that produced it. Mis-attribution is not judged leniently; it is
/// structurally impossible.
struct BoundSocket {
    /// Monotonic identity, allocated at install and never reused.
    gen: u64,
    /// The endpoint this socket IS — not a descriptor re-read at event time
    /// (the old `client.url()` attribution, `link.rs` D2 reproduction test).
    url: String,
    client: Arc<KaspaRpcClient>,
    /// This socket's own notification channel — handed to its
    /// `ChannelConnection`, dropped with it. A notification from a dead socket
    /// cannot arrive on a live one's stream (D4).
    notification_tx: async_channel::Sender<Notification>,
    notification_rx: async_channel::Receiver<Notification>,
    listener_id: Mutex<Option<ListenerId>>,
    /// Unix-seconds this socket was accepted as connected (0 = never). The
    /// run-length base and half the stall baseline.
    connected_at: AtomicU64,
    /// Unix-seconds of the last block THIS socket delivered. The stall
    /// verdict's evidence clock (L70: a detector measures its subject against
    /// the subject's own lifetime); the process-wide twin on [`Inner`] stays
    /// for the glass's data-age reading.
    last_block_at: AtomicU64,
    daa_seen_since_connect: AtomicBool,
    /// True once this bind's `Connected` was announced to consumers (monitor
    /// ctl open + [`DagEvent::Connected`]) — so retirement tells them exactly
    /// once, and a bind that never came up never announces a disconnect.
    announced: AtomicBool,
    /// Stale-event evidence, reported when the retired task exits.
    stale_ctl: AtomicU64,
    stale_notifications: AtomicU64,
    /// Fired at retirement: the task moves to its bounded drain phase.
    retire_tx: Mutex<Option<oneshot::Sender<()>>>,
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

/// What a retirement yields the caller: enough to judge the run, never the
/// socket itself (it is already on its way down).
struct Retired {
    /// How long the socket was up, 0 if it never reached an accepted
    /// `Connected` (in which case nothing was recorded — there is no run).
    run_secs: u64,
    task: Option<tokio::task::JoinHandle<()>>,
}

struct Inner {
    /// The app's STABLE rpc handle (R4): consumers bind this once and every
    /// call lands on whichever socket is current — see [`LinkRpc`] for why the
    /// handle, not the client, is what must never change (L59).
    link_rpc: Arc<LinkRpc>,
    /// The ctl the app's consumers watch. Monitor-owned and driven ONLY by
    /// events the identity gate accepted, so wallet-core sees a de-aliased
    /// connect/disconnect stream instead of the raw client's.
    monitor_ctl: RpcCtl,
    /// The installed socket, if any. At most one exists at a time —
    /// [`DagMonitor::install_bind`] retires whatever it finds.
    bound: Mutex<Option<Arc<BoundSocket>>>,
    /// The identity that owns the present: `0` = none installed. An event
    /// whose `gen` differs is from a retired socket and is discarded.
    current_gen: AtomicU64,
    /// Allocator for [`BoundSocket::gen`] — monotonic, never reused.
    next_gen: AtomicU64,
    is_connected: AtomicBool,
    events: broadcast::Sender<DagEvent>,
    /// Payload-transport fan-out (P2.1): matches from the BlockAdded scan.
    /// Separate from `events` — these are discrete deliveries, not foldable
    /// absolute-state snapshots, and they stay sparse (only `ciph_msg:` matches
    /// are ever sent; the ~10 blocks/s stream itself never crosses).
    transport_events: broadcast::Sender<TransportEvent>,
    /// Address prefix for the scan's output-address extraction — derived from
    /// the network this monitor was constructed for.
    address_prefix: Prefix,
    /// App-private file remembering the last node that worked (public data,
    /// INV-3; the PNN resolver is already an untrusted accelerator, INV-8 —
    /// remembering its last answer adds no new trust). `None` until the bridge
    /// learns the app dir.
    endpoint_cache: Mutex<Option<PathBuf>>,
    /// V3/D-081 link layer: our own resolver handle (race fetches + stall
    /// escalation) and the network this monitor serves. The shared client's
    /// internal resolver is never exercised — every shared-socket connect
    /// passes an explicit URL picked by the race.
    resolver: Resolver,
    network_id: NetworkId,
    /// The demotion ledger (finding 11) + its persistence path (a sibling of
    /// the endpoint cache). Loaded when the cache path arrives; advisory —
    /// a missing ledger never blocks connectivity.
    health: Mutex<EndpointHealth>,
    health_path: Mutex<Option<PathBuf>>,
    /// Single-flight guard for the race task — one reconnect authority means
    /// at most ONE race loop alive (D-081; the V2 sitting's doubled
    /// `Connected` was two concurrent ws connect loops).
    race_running: AtomicBool,
    /// The race-kick (C4/D-089 ruling 2): a Reconnect tap, resume, or OS
    /// network-available signal during a live search interrupts the retry
    /// PAUSE — never the in-flight probes (the reaper finding), never a
    /// second search authority. `Notify`'s stored permit means an unconsumed
    /// kick lets the next pause skip once — one spurious immediate round,
    /// accepted (register C4 note).
    race_kick: tokio::sync::Notify,
    /// The OS's last word on the default network (C7/D-089 ruling 4): `true`
    /// once `onLost` fires, back to `false` on `onAvailable`. Initialised
    /// `false` = *not known to be offline* — the callback only speaks on
    /// TRANSITIONS, so a launch with no network may produce no callback at
    /// all, and a phone must never be accused of being offline without the OS
    /// actually saying so. Display-only: it changes no dialing decision
    /// (ruling 4 keeps `network_lost` passive), it lets the glass name the
    /// cause instead of blaming the nodes.
    os_offline: AtomicBool,
    /// Unix-seconds of the last `onLost` TRANSITION (0 = never). Separate from
    /// [`Self::os_offline`] because that flag is cleared by `onAvailable`,
    /// while admissibility (R2 D3) is judged after the network is back — the
    /// moment the boolean has already forgotten. Never cleared: an old stamp
    /// simply falls outside [`link::OS_LOST_ADJACENCY_SECS`].
    os_lost_at: AtomicU64,
    /// Unix-seconds the item-9 tripwire last fired (0 = never) — a prior
    /// listener surviving into a new connect, which proves two `Connected`
    /// arrived with no `Disconnected` between them. R2 D2 established the
    /// cause: the pinned ws client re-dials a dropped socket on its own
    /// (`workflow-websocket` `'outer` loop, `reconnect` still true), so a
    /// socket can exist that our reconnect authority never created. Drops in
    /// that neighbourhood are OURS, and R2 D3 refuses to charge them to a node.
    doubled_connect_at: AtomicU64,
    /// Unix-seconds of the last race round that PROVED the phone's own
    /// network broken (correlated DNS or `ENETUNREACH` — R3 D-099); 0 =
    /// never. A pending drop/stall strike whose socket died at-or-before
    /// this stamp is withheld as [`link::StrikeReason::LinkBlackout`]: the
    /// interposed race is the one witness that saw the link at the time of
    /// death.
    phone_fault_round_at: AtomicU64,
    /// The endpoint whose failure awaits network-alive evidence: committed as
    /// a strike by the NEXT `Connected` event from a DIFFERENT endpoint (the
    /// control-group — the network worked via B while this one stayed dark).
    /// REFUTED (discarded) if the struck endpoint's OWN reconnect produces the
    /// event — an endpoint can't be its own alibi-witness, and under Wi-Fi
    /// churn that self-commit strand-locked the whole ledger (D-084). Also
    /// discarded when stale ([`link::PENDING_STRIKE_TTL_SECS`] — a phone that
    /// spent minutes offline blames no one). Robust to every event ordering,
    /// including a phantom redial the ws layer can land before our
    /// disconnect() takes effect (its dial cannot be aborted mid-flight).
    /// Carries (url, event-unix, why) — `why` is [`link::StrikeReason::Drop`]
    /// for a judged socket death, [`link::StrikeReason::Stall`] for a
    /// watchdog execution, so the ledger records the true proximate cause
    /// (R3 D1) instead of flattening both to `drop`.
    pending_strike: Mutex<Option<(String, u64, link::StrikeReason)>>,
    /// True while the live bind KNOWINGLY went to a demoted endpoint (two
    /// whole race rounds found nothing healthy — connectivity over hygiene).
    /// Gates the Connected-time demotion refusal so the advisory bind isn't
    /// bounced by our own enforcement.
    hygiene_advisory: AtomicBool,
    /// The node the wallet is pinned to, or `None` for resolver discovery.
    ///
    /// `Some(..)` stands the race and demotion machinery down and lets the ws
    /// client's own Retry loop keep the pinned URL alive — loyalty is CORRECT
    /// for a pinned node, and since D-187 it is also the whole POINT: a pinned
    /// node NEVER silently falls back to the resolver, because a sovereignty
    /// setting that quietly stops being true exactly when it matters is worse
    /// than not offering it.
    ///
    /// **Mutable since D-187** (it was construction-only while pinning was a
    /// dev/test affordance). Every read goes through [`DagMonitor::pinned_url`]
    /// / [`DagMonitor::is_pinned`], and the ONE writer is
    /// [`DagMonitor::set_pinned_node`], which swaps it with nothing bound and
    /// no race able to bind — see that method for why the window is closed.
    direct_url: Mutex<Option<String>>,
    /// Bumped by every [`DagMonitor::pause`]. [`DagMonitor::set_pinned_node`]
    /// compares it across its teardown await: the `paused` FLAG cannot answer
    /// "did a background pause land while I was tearing down?", because the
    /// repin set that same flag itself one line earlier. A generation can.
    pause_gen: AtomicU64,
    /// True between [`DagMonitor::pause`] and [`DagMonitor::resume`] — a
    /// deliberate grace-drop also emits `Disconnected`, and the rotation-restore
    /// logic must not treat it as a dead node and dial right back.
    paused: AtomicBool,
    /// App-private file holding the hash of the last block whose transport scan
    /// we advanced past — the catch-up cursor (P5/D-067). Public chain data
    /// (INV-3). `None` until transport arms it (`set_transport_cursor`); while
    /// armed, the BlockAdded scan persists it (throttled) so a killed app can
    /// replay the gap on next open ([`catch_up_transport`]). Node-only (INV-8):
    /// the replay is `get_blocks` from this hash, never an indexer.
    transport_cursor: Mutex<Option<PathBuf>>,
    /// Unix-seconds of the last cursor write — throttles the hot BlockAdded path
    /// to one small write every [`TRANSPORT_CURSOR_MIN_WRITE_SECS`].
    transport_cursor_written: AtomicU64,
    /// Unix-seconds of the last BlockAdded we scanned, process-wide (0 = none
    /// yet). This is the **display** clock: how old the data on the glass is,
    /// which is a property of the app's session, not of any one socket, and it
    /// must keep reading across a rebind (C7's no-staleness-before-first-connect
    /// invariant is built on it). A plain atomic store every block (no I/O),
    /// unlike the throttled cursor write.
    ///
    /// Its **judgment** twin is [`BoundSocket::last_block_at`] (R4): a stall
    /// verdict is measured against the accused socket's own silence, never the
    /// process's — that conflation was the D-099/L70 cascade.
    last_block_at: AtomicU64,
    /// V1 acceptance spine: where the event task forwards VirtualChainChanged
    /// batches once the tracker is attached ([`DagMonitor::attach_acceptance`]).
    /// Unattached (or a dead receiver) = batches drop harmlessly — the tracker's
    /// own reconnect catch-up recovers anything missed while detached.
    vcc_tx: Mutex<Option<tokio::sync::mpsc::UnboundedSender<VccBatch>>>,
}

/// Owns one wRPC client plus the event task that tracks its connection state
/// and notification stream, fanning everything out as [`DagEvent`]s.
/// What a watchdog stall claim amounts to once judged against the monitor's
/// own clocks (R3 D-099). The claim arrives from Dart with process-lifetime
/// evidence; only the monitor knows the CURRENT socket's age and silence.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StallVerdict {
    /// Connected and silent past [`link::WATCHDOG_STALL_SECS`] measured from
    /// this socket's own baseline — a true zombie; execute it.
    Execute { silent_secs: u64 },
    /// Connected but the socket's own silence is inside the threshold — the
    /// claim was built on silence older than the socket. It keeps its window.
    Refuse { silent_secs: u64 },
    /// Not connected: there is no defendant. Kick the hunt (C4) instead.
    Hunting,
}

#[derive(Clone)]
pub struct DagMonitor {
    inner: Arc<Inner>,
}

impl DagMonitor {
    /// `url = None` uses the public-node resolver (PNN) for endpoint discovery
    /// via the connect race (D-081); `url = Some` pins that node (dev/tests).
    pub fn try_new(network_id: NetworkId, url: Option<String>) -> Result<Self> {
        let resolver = Resolver::default();
        let (events, _) = broadcast::channel(256);
        let (transport_events, _) = broadcast::channel(256);
        Ok(Self {
            inner: Arc::new(Inner {
                link_rpc: LinkRpc::new(),
                monitor_ctl: RpcCtl::new(),
                bound: Mutex::new(None),
                current_gen: AtomicU64::new(0),
                next_gen: AtomicU64::new(0),
                is_connected: AtomicBool::new(false),
                events,
                transport_events,
                address_prefix: Prefix::from(network_id.network_type),
                endpoint_cache: Mutex::new(None),
                resolver,
                network_id,
                health: Mutex::new(EndpointHealth::default()),
                health_path: Mutex::new(None),
                race_running: AtomicBool::new(false),
                race_kick: tokio::sync::Notify::new(),
                os_offline: AtomicBool::new(false),
                os_lost_at: AtomicU64::new(0),
                doubled_connect_at: AtomicU64::new(0),
                phone_fault_round_at: AtomicU64::new(0),
                pending_strike: Mutex::new(None),
                hygiene_advisory: AtomicBool::new(false),
                pause_gen: AtomicU64::new(0),
                direct_url: Mutex::new(url),
                paused: AtomicBool::new(false),
                transport_cursor: Mutex::new(None),
                transport_cursor_written: AtomicU64::new(0),
                last_block_at: AtomicU64::new(0),
                vcc_tx: Mutex::new(None),
            }),
        })
    }

    /// Attach the acceptance tracker (V1): returns the receiving end of the
    /// VirtualChainChanged forward. Batches that arrive before attachment
    /// drop harmlessly (the tracker's connect catch-up covers the gap).
    pub fn attach_acceptance(&self) -> tokio::sync::mpsc::UnboundedReceiver<VccBatch> {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        *self
            .inner
            .vcc_tx
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(tx);
        rx
    }

    /// Tell the monitor where to remember the last-good endpoint (app-private
    /// file; public data — a wss URL). Callable any time; connects that happen
    /// before this is set simply skip the fast path. The demotion ledger
    /// (V3, finding 11) lives beside it as `endpoint.health` and loads here.
    pub fn set_endpoint_cache(&self, path: PathBuf) {
        let health_path = path.with_file_name("endpoint.health");
        *self
            .inner
            .health
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) =
            EndpointHealth::load(&health_path);
        *self
            .inner
            .health_path
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(health_path);
        *self
            .inner
            .endpoint_cache
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(path);
    }

    /// Current unix-seconds (0 on a pre-epoch clock — never panics).
    fn now_unix() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    }

    /// Record a strike against `url` and persist the ledger. Called only with
    /// network-alive evidence in hand (a race just found another healthy node,
    /// or a fresh node just took an escalation resubmit) — a phone in a tunnel
    /// never demotes an innocent endpoint (D-081 control-group rule).
    fn commit_strike(
        &self,
        url: &str,
        reason: link::StrikeReason,
        event_at_unix: u64,
        phone_fault_correlated: bool,
    ) {
        let now = Self::now_unix();
        // R2 D3 — admissibility is judged at the ONE choke point every strike
        // passes, for the same reason the demotion refusal sits at the one
        // choke point every connection passes: a rule enforced at each call
        // site is a rule the next call site forgets.
        //
        // `event_at_unix` is the moment the EVIDENCE arose, which for a parked
        // drop is when the socket died — not now. Judging a settled strike by
        // its settle time would compare the OS window against a clock reading
        // taken after the network already recovered, and quietly convict the
        // exact endpoints this rule exists to protect.
        let verdict = link::judge_admissibility(
            reason,
            event_at_unix,
            self.inner.os_lost_at.load(Ordering::SeqCst),
            self.inner.doubled_connect_at.load(Ordering::SeqCst),
            phone_fault_correlated,
            self.inner.phone_fault_round_at.load(Ordering::SeqCst),
        );
        let reason = match verdict {
            link::Admissibility::Convict(reason) => reason,
            link::Admissibility::Withhold(why) => {
                let withheld = {
                    let mut health = self
                        .inner
                        .health
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    health.withhold(url, why);
                    self.save_health(&health);
                    health.last_reason(url).map_or(0, |(_, n)| n)
                };
                // Recorded, never erased: the ledger must stay auditable for
                // wrongful ACQUITTALS too, not only wrongful convictions.
                log::info!(
                    "link: strike ({}) on {host} WITHHELD as {} — not the node's fault \
                     ({withheld} withheld so far)",
                    reason.as_token(),
                    why.as_token(),
                    host = link::endpoint_host(url)
                );
                spans::mark_with("endpoint_strike_withheld", link::endpoint_host(url));
                return;
            }
        };
        let demoted = {
            let mut health = self
                .inner
                .health
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let demoted = health.strike(url, now, reason);
            self.save_health(&health);
            demoted
        };
        log::info!(
            "link: strike ({}) on {host}{}",
            reason.as_token(),
            if demoted { " — DEMOTED" } else { "" },
            host = link::endpoint_host(url)
        );
        spans::mark_with(
            if demoted {
                "endpoint_demoted"
            } else {
                "endpoint_strike"
            },
            link::endpoint_host(url),
        );
    }

    /// A connection outlived [`link::CLEAN_RUN_SECS`] — clear its strikes.
    fn commit_clean_run(&self, url: &str) {
        let mut health = self
            .inner
            .health
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        health.clean_run(url);
        self.save_health(&health);
    }

    /// Stamp an observed-healthy moment (C6): a probe win or a `Connected`
    /// on the shared socket. Persisted — the pantry survives restarts.
    fn mark_endpoint_healthy(&self, url: &str) {
        let mut health = self
            .inner
            .health
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        health.mark_healthy(url, Self::now_unix());
        self.save_health(&health);
    }

    fn save_health(&self, health: &EndpointHealth) {
        if let Some(path) = self
            .inner
            .health_path
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
        {
            health.save(path);
        }
    }

    /// Strike a NAMED endpoint — the escalation task's demotion hook (V3
    /// deliverable 2): the stall convicts the SUBMIT-TIME endpoint (retained
    /// with the tx), never whoever the socket re-raced to since
    /// (consensus-audit finding). Only called after a fresh node answered,
    /// so the evidence rule holds.
    pub fn strike_endpoint(&self, url: &str, reason: link::StrikeReason) {
        self.commit_strike(url, reason, Self::now_unix(), false);
    }

    /// The endpoint the installed socket IS bound to — captured by the send
    /// hook at submit time so a later stall strikes the right node. Since R4
    /// this is the bind's own identity rather than the client's descriptor,
    /// so it names the socket that carried the submit, never whichever URL a
    /// later connect happened to write. `None` between binds.
    pub fn current_url(&self) -> Option<String> {
        self.current_bind().map(|bind| bind.url.clone())
    }

    /// Park a strike until network-alive evidence arrives (the next
    /// `Connected` commits it; staleness discards it). `why` names the true
    /// proximate cause — `Drop` for a judged socket death, `Stall` for a
    /// watchdog execution (R3 D1).
    fn set_pending_strike(&self, url: String, why: link::StrikeReason) {
        *self
            .inner
            .pending_strike
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) =
            Some((url, Self::now_unix(), why));
    }

    /// Commit-or-discard the parked strike — called on every `Connected`
    /// (the connect itself is the network-alive proof). `prover_url` is the
    /// endpoint that just connected: when it IS the struck endpoint, the
    /// strike is REFUTED, not proven — the hypothesis behind a strike is
    /// "this endpoint is unhealthy", and its own successful reconnect is the
    /// strongest possible counter-evidence. Committing it anyway is how the
    /// V4 sitting's live-lock spun up (D-084): post-airplane Wi-Fi churn
    /// parked a strike per drop, each endpoint's own reconnect ≤30 s
    /// committed it, the demotion tripped the Connected-time refusal, the
    /// re-race walked to the next endpoint and repeated until the whole
    /// resolver set sat demoted — a connectivity strand. Commit stays for
    /// the true control-group: a DIFFERENT endpoint proved the network alive
    /// while the struck one stayed dark.
    fn settle_pending_strike(&self, prover_url: Option<&str>) {
        let taken = self
            .inner
            .pending_strike
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        if let Some((url, at, why)) = taken {
            if prover_url == Some(url.as_str()) {
                log::info!(
                    "link: pending strike on {host} refuted by its own reconnect — discarded",
                    host = link::endpoint_host(&url)
                );
            } else if Self::now_unix().saturating_sub(at) <= link::PENDING_STRIKE_TTL_SECS {
                // `at` is when the socket DIED, not now — see commit_strike.
                self.commit_strike(&url, why, at, false);
            } else {
                log::info!(
                    "link: pending strike on {host} expired unproven — discarded",
                    host = link::endpoint_host(&url)
                );
            }
        }
    }

    /// The resolver handle the race + escalation share (cheap Arc clone).
    pub fn resolver(&self) -> Resolver {
        self.inner.resolver.clone()
    }

    pub fn network_id(&self) -> NetworkId {
        self.inner.network_id
    }

    fn cache_path(&self) -> Option<PathBuf> {
        self.inner
            .endpoint_cache
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    /// The remembered endpoint, if any. Accepts only ws/wss URLs (a corrupt or
    /// hand-edited file must never redirect the wallet elsewhere).
    fn read_cached_endpoint(&self) -> Option<String> {
        let path = self.cache_path()?;
        let url = std::fs::read_to_string(path).ok()?.trim().to_string();
        (url.starts_with("wss://") || url.starts_with("ws://")).then_some(url)
    }

    /// Best-effort persist of the endpoint that just worked.
    fn persist_endpoint(&self, url: &str) {
        if let Some(path) = self.cache_path() {
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            if let Err(e) = std::fs::write(&path, url) {
                log::warn!("dag-monitor: endpoint cache write failed: {e}");
            }
        }
    }

    /// Arm the transport catch-up cursor at `path` (called by the transport hub
    /// on start, AFTER it has read the prior value for its replay — see
    /// [`take_transport_cursor`]). Once set, the BlockAdded scan persists the
    /// last-scanned block hash here (throttled), so the next open can replay the
    /// gap. Idempotent; changing paths mid-run just re-homes the cursor.
    pub fn set_transport_cursor(&self, path: PathBuf) {
        *self
            .inner
            .transport_cursor
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(path);
    }

    fn transport_cursor_path(&self) -> Option<PathBuf> {
        self.inner
            .transport_cursor
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    /// Read the persisted cursor hash from a file WITHOUT arming persistence —
    /// the transport hub calls this at open to get the PRIOR session's last
    /// scan point for the catch-up replay, before it arms the live cursor.
    /// A missing/corrupt file yields `None` (first run, or nothing to recover).
    pub fn read_transport_cursor(path: &PathBuf) -> Option<Hash> {
        let text = std::fs::read_to_string(path).ok()?;
        text.trim().parse::<Hash>().ok()
    }

    /// Best-effort, throttled persist of the last-scanned block hash. Called
    /// from the BlockAdded scan; a write happens at most every
    /// [`TRANSPORT_CURSOR_MIN_WRITE_SECS`] so the ~10 blocks/s stream never
    /// hammers the disk. No-op until the cursor is armed.
    fn persist_transport_cursor(&self, hash: &Hash) {
        let Some(path) = self.transport_cursor_path() else {
            return;
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let last = self.inner.transport_cursor_written.load(Ordering::Relaxed);
        if now.saturating_sub(last) < TRANSPORT_CURSOR_MIN_WRITE_SECS {
            return;
        }
        self.inner
            .transport_cursor_written
            .store(now, Ordering::Relaxed);
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Err(e) = std::fs::write(&path, hash.to_string()) {
            log::warn!("dag-monitor: transport cursor write failed: {e}");
        }
    }

    /// Replay the transport scan over the blocks the app missed while closed —
    /// the P5/D-067 catch-up. From `from` (the prior session's cursor), walk the
    /// DAG forward with `get_blocks` (node-only, INV-8), run the SAME
    /// [`transport::scan_block`] the live path uses, and fan the matches out on
    /// the transport channel so the hub folds them exactly like live arrivals
    /// (dedup-by-txid makes the boundary-block overlap harmless). Bounded by
    /// [`MAX_CATCHUP_PAGES`]; a pruned/unknown cursor just ends the walk (the
    /// live scan takes over). Returns the number of matches re-emitted.
    ///
    /// `from = None` (first run / no prior cursor) seeds the cursor at the
    /// current sink so the NEXT gap is coverable, and replays nothing — there is
    /// no prior session whose arrivals could have been missed.
    pub async fn catch_up_transport(&self, from: Option<Hash>) -> Result<usize> {
        // Through the stable handle: the replay commonly starts before the
        // first bind lands, and it must keep working across any rebind that
        // happens mid-walk.
        let rpc = self.inner.link_rpc.clone();
        let Some(mut low) = from else {
            if let Ok(sink) = rpc.get_sink().await {
                self.write_cursor_now(&sink.sink);
            }
            return Ok(0);
        };

        let mut emitted = 0usize;
        let mut last_hash = low;
        for _page in 0..MAX_CATCHUP_PAGES {
            // Retry across a still-connecting socket so a cold-reopen race never
            // strands a closed-app arrival. `None` = unreachable/pruned → stop.
            let Some(resp) = self.catch_up_get_blocks(low).await else {
                log::warn!("dag-monitor: catch-up get_blocks unreachable — stopping");
                break;
            };
            // `low_hash` is returned inclusively; a page of just it = caught up.
            if resp.block_hashes.len() <= 1 {
                if let Some(h) = resp.block_hashes.last() {
                    last_hash = *h;
                }
                break;
            }
            for block in &resp.blocks {
                for event in transport::scan_block(block, self.inner.address_prefix) {
                    if self.inner.transport_events.send(event).is_ok() {
                        emitted += 1;
                    }
                }
            }
            if let Some(h) = resp.block_hashes.last() {
                last_hash = *h;
            }
            // Next page starts at the last hash (re-included, then skipped by
            // the dedup fold). Reaching the sink returns a short/So single page.
            low = last_hash;
        }
        // Advance the persisted cursor to where the replay reached, so a second
        // open doesn't redo the same walk.
        self.write_cursor_now(&last_hash);
        log::info!("dag-monitor: transport catch-up re-emitted {emitted} match(es)");
        Ok(emitted)
    }

    /// One catch-up page, tolerant of a still-connecting or briefly-flaky wRPC
    /// socket. `include_blocks + include_transactions` because we need the
    /// payloads. Retries up to [`CATCHUP_RPC_ATTEMPTS`] with a
    /// [`CATCHUP_RETRY_DELAY`] pause — the first page on a cold reopen commonly
    /// runs before the reconnect lands, and a single failure must NOT abandon
    /// the walk (the closed-app arrival would be lost, the sitting bug).
    /// `None` after the whole budget = the node is unreachable or the cursor is
    /// pruned.
    async fn catch_up_get_blocks(&self, low: Hash) -> Option<GetBlocksResponse> {
        // "No bound socket" is just another retryable answer here — the walk
        // is allowed to start before the race has bound anything.
        let rpc = self.inner.link_rpc.clone();
        for attempt in 0..CATCHUP_RPC_ATTEMPTS {
            match rpc.get_blocks(Some(low), true, true).await {
                Ok(resp) => return Some(resp),
                Err(e) => {
                    log::debug!(
                        "dag-monitor: catch-up get_blocks attempt {attempt} failed ({}); retrying",
                        link::sanitize_node_text(&e.to_string())
                    );
                    tokio::time::sleep(CATCHUP_RETRY_DELAY).await;
                }
            }
        }
        None
    }

    /// Force-write the cursor now (bypassing the throttle) — used at the ends of
    /// catch-up and on seeding, where the exact point matters.
    fn write_cursor_now(&self, hash: &Hash) {
        let Some(path) = self.transport_cursor_path() else {
            return;
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        self.inner
            .transport_cursor_written
            .store(now, Ordering::Relaxed);
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Err(e) = std::fs::write(&path, hash.to_string()) {
            log::warn!("dag-monitor: transport cursor write failed: {e}");
        }
    }

    pub fn mainnet() -> Result<Self> {
        Self::mainnet_with_node(None)
    }

    /// Mainnet, against the node the user pinned — or public node discovery
    /// when they have not chosen one (D-187). The one constructor the bridge
    /// calls, so the pin is read BEFORE the first connect rather than applied
    /// to a link that already reached a stranger.
    pub fn mainnet_with_node(url: Option<String>) -> Result<Self> {
        Self::try_new(NetworkId::new(NetworkType::Mainnet), url)
    }

    pub fn is_connected(&self) -> bool {
        self.inner.is_connected.load(Ordering::SeqCst)
    }

    /// Is a connect race alive right now — i.e. are we *hunting for a node*
    /// (C7's second truth)? This is the honest search signal and it holds for
    /// the WHOLE hunt, inter-round pauses included, by construction:
    /// [`Self::spawn_race`] sets the flag before spawning and the spawned task
    /// clears it only after `race_loop().await` RETURNS, while every round —
    /// probe fan-out, the [`link::RACE_RETRY_DELAY`] pause, the next round —
    /// happens inside that one await. So a 14–28 s weak-link hunt (the
    /// 2026-07-30 field capture) reads `true` end to end; it can never blink
    /// off between rounds and let the glass claim connected or offline.
    ///
    /// Since P0b this can be true **while connected**, and that pair is not a
    /// contradiction — it is the swap hunt, and it is the only state in which
    /// both are true for longer than a moment. The glass reads the pair, not
    /// either bit alone: connected + searching is *"answering, and looking for
    /// a different node"*, and it is the honest rendering of a link that is
    /// working while a bounded errand runs behind it.
    pub fn is_searching(&self) -> bool {
        self.inner.race_running.load(Ordering::SeqCst)
    }

    /// Has the OS told us the default network is gone (C7's first truth)?
    /// Only ever `true` because Android's `ConnectivityManager` said `onLost`
    /// — never inferred from our own failures, so the glass can say *phone
    /// offline* without ever blaming a node for a dead Wi-Fi link. A launch
    /// that never sees a callback reads `false` (unknown ≠ offline), and the
    /// UI additionally requires a dead socket before rendering it: a live
    /// socket is proof of a network, whatever a flapping callback claims.
    pub fn os_offline(&self) -> bool {
        self.inner.os_offline.load(Ordering::SeqCst)
    }

    /// New receiver onto the event fan-out. Subscribers that join late simply
    /// pick up from the next event — scores tick about once per second.
    pub fn subscribe(&self) -> broadcast::Receiver<DagEvent> {
        self.inner.events.subscribe()
    }

    /// New receiver onto the payload-transport fan-out (P2.1): one
    /// [`TransportEvent`] per `ciph_msg:` match seen in the BlockAdded stream.
    /// Live-only by design (D-049/§0.3): a late subscriber sees the next match,
    /// never history — the P2.3 message store owns persistence. Rides the same
    /// socket + pause/resume posture as everything else (foreground-only).
    pub fn subscribe_transport(&self) -> broadcast::Receiver<TransportEvent> {
        self.inner.transport_events.subscribe()
    }

    /// The app's wRPC handle (`rpc_api` + `rpc_ctl`), for binding a wallet-core
    /// `UtxoProcessor` to this same connection — one socket for both DAG status
    /// and wallet sync (P1 §0.8 / D-005: no DAA divergence, one link to
    /// manage). The processor reacts to `RpcState` over this ctl, so it
    /// connects and resyncs in lockstep with the monitor.
    ///
    /// Both halves are monitor-owned and STABLE across rebinds (R4): the
    /// [`LinkRpc`] handle routes each call to whichever socket is current, and
    /// the ctl is signalled only for events the identity gate accepted. That
    /// is what lets D-005 stay true while the client underneath rotates — and
    /// what keeps the L59 funds-visibility lanes off the re-plumb path.
    pub fn rpc(&self) -> Rpc {
        Rpc::new(self.inner.link_rpc.clone(), self.inner.monitor_ctl.clone())
    }

    /// Initiates the first connect. Must be called from within a tokio runtime.
    pub async fn start(&self) -> Result<()> {
        self.relink("start").await
    }

    /// The node this monitor is pinned to, if any (D-187). `None` = resolver
    /// discovery, which is the default and today's behaviour.
    pub fn pinned_url(&self) -> Option<String> {
        self.inner
            .direct_url
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    /// May a race bind the socket right now? Checked at the race loop's head
    /// AND again immediately before it installs a winner, because both facts
    /// can change while a round is in flight (a round takes up to
    /// `PROBE_TIMEOUT`).
    ///
    /// The pinned term is the D-187 guarantee made STRUCTURAL. It is not
    /// enough that a pinned monitor never *spawns* a race: [`set_pinned_node`]
    /// can pin while a race spawned moments earlier is still probing, and that
    /// round would otherwise come back and bind a resolver endpoint over the
    /// user's node — the exact silent fallback the pin exists to forbid, and
    /// the hardest kind to notice, because the wallet looks connected. A
    /// timing argument would be enough to close it today; this is enough
    /// forever.
    ///
    /// The live-socket term is **mode-scoped** since P0b. A [`RaceMode::Cold`]
    /// race still may never bind over a live socket: it exists only because
    /// there is no socket, so a socket appearing under it (a ws-level phantom
    /// redial) means its job is already done. A [`RaceMode::Swap`] race is the
    /// exact opposite — binding over the live socket IS its job, it runs only
    /// because the user asked for a different node, and it excludes the
    /// incumbent from every round, so the thing it binds is never the thing it
    /// replaced. The `paused` and `pinned` terms are untouched, which is what
    /// keeps [`Self::set_pinned_node`]'s safety argument intact: that function
    /// stands the race down with `paused`, not with the socket.
    fn may_bind_from_race(&self, mode: &RaceMode) -> bool {
        if self.inner.paused.load(Ordering::SeqCst) || self.is_pinned() {
            return false;
        }
        match mode {
            RaceMode::Cold => !self.is_connected(),
            RaceMode::Swap { .. } => true,
        }
    }

    /// Is a user-chosen node pinned? The one predicate the race, the demotion
    /// ledger and the disconnect path branch on.
    fn is_pinned(&self) -> bool {
        self.inner
            .direct_url
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_some()
    }

    /// **The one doorway back onto the link**, in whatever mode is configured
    /// right now (D-187). Every recovery gesture routes through here.
    ///
    /// Before D-187 the recovery paths — [`resume`], [`reconnect`], the
    /// watchdog kick, the OS network-available signal — all called
    /// [`spawn_or_kick_race`] directly, which is a **no-op in pinned mode**.
    /// That was harmless while a pin was a dev/test affordance (nothing called
    /// pause or reconnect in those runs, and the ws Retry loop owned the link).
    /// The moment a USER can pin, each of those became a way to darken the
    /// wallet permanently: background the app for 30 s and the grace-drop
    /// retires the bind, then foreground it and `resume` races — except a
    /// pinned monitor must not race, so nothing dialled at all. Routing both
    /// modes through one function is what stops that class returning: a future
    /// recovery path cannot forget the pinned arm, because there is only one
    /// arm to call.
    ///
    /// Pinned mode installs a bind whose own Retry loop redials that same
    /// client, so an ordinary drop is serviced by its existing task and
    /// [`on_disconnected`] keeps the bind rather than retiring it. A *recovery
    /// gesture* still lands here and installs a fresh one — `install_bind`
    /// retires the incumbent first, so there is never more than one.
    async fn relink(&self, source: &str) -> Result<()> {
        let Some(url) = self.pinned_url() else {
            self.spawn_or_kick_race(source);
            return Ok(());
        };
        log::info!("link: relink to the pinned node ({source})");
        // The evidence lane names the HOST, never the URL (INV-3): a
        // path-segment token survives `validate_node_url` and this lane is
        // build-flavor-proof, so it must not be the place a credential lands.
        spans::mark_with("pinned_relink", link::endpoint_host(&url));
        let bind = self.install_bind(url.clone()).await?;
        let options = ConnectOptions {
            url: Some(url),
            block_async_connect: false,
            strategy: ConnectStrategy::Retry,
            ..Default::default()
        };
        // UNBOUNDED BY CONSTRUCTION, proven at the pin rather than fenced with
        // a timeout (the D-089/L64 law is bounded OR proven; the race path
        // takes the other branch and envelope-bounds its own connect). Before
        // D-187 this ran once per process from `start()`; it now sits on
        // resume, reconnect, the watchdog kick and network-available, so the
        // proof is written down instead of re-derived:
        //   1. `install_bind` allocates a FRESH `KaspaRpcClient`, so
        //      `connect`'s leading `self.disconnect()` is a no-op —
        //      `workflow-websocket-0.18.0 client/native.rs:388-411` guards
        //      `close()` on `is_connected`, and `client.rs:416-424` guards
        //      `stop()` on `background_services_running`.
        //   2. `connect_guard` is uncontended on a client nobody else holds.
        //   3. `block_async_connect: false` returns `Ok(Some(listener))`
        //      immediately after the spawn (`native.rs:253-256`) — there is no
        //      `Fallback` error arm here to take `disconnect_guard`.
        // A future FRB/wRPC bump re-opens this: re-run the trace or bound it.
        bind.client.connect(Some(options)).await?;
        Ok(())
    }

    /// Pin the wallet to `url`, or clear the pin with `None` (D-187).
    ///
    /// **Why this is safe to do live**, rather than only at construction: the
    /// swap happens with nothing bound and no race able to bind, using
    /// doorways that already carry the scars.
    ///
    /// 1. `paused = true` stands the race loop down. It checks that flag at
    ///    its loop head AND once more immediately before binding a winner, so
    ///    a round already in flight drains its probes and returns without
    ///    installing anything — that second check is the pre-existing
    ///    never-bind-over-a-live-socket guard, and it is what makes this
    ///    cheap instead of a new synchronisation problem.
    /// 2. [`retire_bind`] is the ONE way a socket leaves (R4 D2): it
    ///    invalidates the identity under the publish lock, so the retired
    ///    socket's trailing `Disconnected` lands on a dead generation and the
    ///    gate discards it.
    /// 3. The swap itself, with the link down.
    /// 4. [`relink`] brings it back up in the NEW mode.
    ///
    /// Step 1's flag is then restored rather than cleared: a repin while the
    /// app is backgrounded must not drag the socket back up and burn battery
    /// — `resume` will apply the new mode when the user returns.
    ///
    /// The URL is validated BEFORE any teardown, so a typo costs the user
    /// nothing: the link they had keeps running.
    pub async fn set_pinned_node(&self, url: Option<String>) -> Result<()> {
        let url = url.as_deref().map(link::validate_node_url).transpose()?;
        // A concurrent `pause()` can land between the swap below and the read
        // after it — on a multi-thread runtime that is another worker, and it
        // no longer needs a long window to do it: D-215 detached the teardown,
        // so `retire_bind` awaits nothing at all now. **The guard is still
        // required, and the reason is the race, not the duration** — this
        // comment used to cite the DISCONNECT_WAIT_TIMEOUT await as its whole
        // justification, which would invite a reader who checked to delete a
        // live guard on the backgrounding path. Re-reading the `paused` FLAG
        // cannot detect it either, because the line below sets it — so compare
        // the pause GENERATION across the call.
        let pause_gen = self.inner.pause_gen.load(Ordering::SeqCst);
        let was_paused = self.inner.paused.swap(true, Ordering::SeqCst);
        self.retire_bind("repin").await;
        let paused_mid_repin = self.inner.pause_gen.load(Ordering::SeqCst) != pause_gen;
        *self
            .inner
            .direct_url
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = url.clone();
        match &url {
            Some(url) => {
                log::info!("link: node pinned to {}", link::endpoint_host(url));
                spans::mark_with("node_pinned", link::endpoint_host(url));
            }
            None => {
                log::info!("link: node pin cleared — public node discovery");
                spans::mark("node_pin_cleared");
            }
        }
        if !was_paused && !paused_mid_repin {
            self.inner.paused.store(false, Ordering::SeqCst);
        }
        // Decide from the flag as it stands NOW, after the swap — never from
        // the pre-await snapshot (consensus audit). `pause_gen` sees a pause
        // land mid-teardown but is blind to a **resume**, which does not bump
        // it; a background→foreground bounce inside the ~7 s teardown window
        // would then take the "applies on resume" branch *after* resume had
        // already relinked in the OLD mode — leaving the wallet bound to the
        // previous node (or to a resolver-chosen one) while `pinned_url`
        // reported the new pin. Connected and lying, until the socket dropped.
        //
        // Reading the live flag here converges on every interleaving, because
        // the swap above already happened: any relink from this point on —
        // ours, or a resume racing us — dials the NEW node.
        if self.inner.paused.load(Ordering::SeqCst) {
            log::info!("link: repin while paused — the new mode applies on resume");
            return Ok(());
        }
        self.relink("repin").await
    }

    /// Spawn the race task unless one is already running (single-flight —
    /// exactly one reconnect authority, D-081). Returns whether a NEW loop
    /// was spawned; the already-running path is never silent (C4/D-089 — the
    /// old silent return here was half of the dead-Reconnect symptom) and
    /// callers holding a user gesture escalate it to a [`Self::kick_race`].
    fn spawn_race(&self) -> bool {
        self.spawn_race_with(RaceMode::Cold)
    }

    /// [`Self::spawn_race`], for a named [`RaceMode`]. Single-flight is per
    /// MONITOR, not per mode: there is exactly one search authority (D-081),
    /// so a swap hunt never runs beside a cold one — whichever is already
    /// hunting keeps the flag and the caller's gesture becomes a kick.
    fn spawn_race_with(&self, mode: RaceMode) -> bool {
        if self.is_pinned() {
            return false; // pinned mode: the ws Retry loop owns the link
        }
        if self.inner.race_running.swap(true, Ordering::SeqCst) {
            log::info!("link: spawn_race — a race loop is already hunting");
            return false;
        }
        let monitor = self.clone();
        tokio::spawn(async move {
            monitor.race_loop(mode).await;
            monitor.inner.race_running.store(false, Ordering::SeqCst);
        });
        true
    }

    /// Interrupt a live race's retry PAUSE — C4's "the tap always acts", and
    /// since P0b the `ctl-drop` recovery too, which is a socket DEATH and not
    /// a gesture: `source` is the only thing that tells them apart, so the
    /// line names it rather than asserting a tap that may never have happened.
    /// Kicks never abort in-flight probes (the reaper finding) and never spawn
    /// a second search authority (D-081, ruling 2).
    fn kick_race(&self, source: &str) {
        log::info!("link: race already hunting; kicked the retry pause ({source})");
        spans::mark_with("race_kick", source);
        self.inner.race_kick.notify_one();
    }

    /// Spawn-or-kick (C4): the one entry every recovery gesture routes
    /// through — a fresh race if none is running, a kick into the live one's
    /// retry pause otherwise. Pinned mode does neither (the ws Retry loop
    /// owns a pinned link).
    fn spawn_or_kick_race(&self, source: &str) {
        if !self.spawn_race() && !self.is_pinned() {
            self.kick_race(source);
        }
    }

    /// Best-effort listener unregister, bounded ([`LISTENER_UNREGISTER_TIMEOUT`]).
    /// Never fatal: on a dropped socket the node already forgot us, and a
    /// socket that will not answer is one we are leaving regardless.
    async fn unregister_listener_bounded(client: &Arc<KaspaRpcClient>, id: ListenerId) {
        if tokio::time::timeout(
            LISTENER_UNREGISTER_TIMEOUT,
            client.rpc_api().unregister_listener(id),
        )
        .await
        .is_err()
        {
            log::info!(
                "link: listener unregister exceeded {LISTENER_UNREGISTER_TIMEOUT:?} — \
                 abandoning it with the socket"
            );
        }
    }

    /// The installed socket, if any.
    fn current_bind(&self) -> Option<Arc<BoundSocket>> {
        self.inner
            .bound
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    /// **The identity gate (R4/D-101).** Every ctl event and every
    /// notification asks this BEFORE it is allowed to mean anything. An event
    /// whose bind is no longer the installed one belongs to a socket that is
    /// already dead: it is that socket's news, and the socket that replaced it
    /// answers for nothing it did. This is what makes the D-100 live-lock
    /// impossible rather than merely unconvictable (L71).
    fn is_current_bind(&self, gen: u64) -> bool {
        self.inner.current_gen.load(Ordering::SeqCst) == gen
    }

    /// A ctl event from a retired socket. Logged in full — ctl events are
    /// sparse (a handful per socket) and these lines are the direct evidence
    /// that the aliasing happened and was refused.
    fn discard_ctl(&self, bind: &BoundSocket, state: RpcState) {
        bind.stale_ctl.fetch_add(1, Ordering::Relaxed);
        log::info!(
            "link: stale ctl {state:?} from retired bind gen={} ({}) — DISCARDED \
             (current gen={}); the live socket keeps its life",
            bind.gen,
            link::endpoint_host(&bind.url),
            self.inner.current_gen.load(Ordering::SeqCst)
        );
    }

    /// A notification from a retired socket. Throttled to one line per bind:
    /// a live mainnet socket carries ~10 blocks/s, so logging each would drown
    /// the very lane this evidence lives in (L65/L66). The total is reported
    /// when the retired task exits.
    fn discard_notification(&self, bind: &BoundSocket) {
        if bind.stale_notifications.fetch_add(1, Ordering::Relaxed) == 0 {
            log::info!(
                "link: notification from retired bind gen={} ({}) — DISCARDED \
                 (further ones counted, not logged)",
                bind.gen,
                link::endpoint_host(&bind.url)
            );
        }
    }

    /// Create, publish and start servicing a NEW socket identity.
    ///
    /// The client is built with an EXPLICIT url and NO internal resolver.
    /// That keeps the bounded-await law (D-089/L64) true by construction
    /// rather than by discipline: the ws connect loop's resolver hook runs a
    /// raw `get_node` OUTSIDE `connect_timeout` (pin ws `native.rs:150-156`,
    /// `:178` vs `:182`; `client.rs:233-235`), an unbounded HTTP the old
    /// shared client avoided only because every connect remembered to pass
    /// `options.url: Some(..)`. A per-bind client has no resolver to call.
    async fn install_bind(&self, url: String) -> Result<Arc<BoundSocket>> {
        // At most one identity exists at a time. Anything still installed is
        // retired (and recorded) before the new one is allocated — so a bind
        // can never be leaked by a path that forgot to clean up.
        self.retire_bind("superseded").await;

        let client = Arc::new(KaspaRpcClient::new_with_args(
            WrpcEncoding::Borsh,
            Some(url.as_str()),
            None,
            Some(self.inner.network_id),
            None,
        )?);
        // Register on THIS client's ctl multiplexer before anyone connects it,
        // so its own first `Connected` cannot be missed.
        //
        // The registration lives as long as the `MultiplexerChannel` VALUE:
        // its `Drop` unregisters the sender (workflow-core 0.18.0
        // `channel.rs:316-323`), so keeping only the receiver silently
        // detaches the socket from its own ctl stream. It is therefore moved
        // into the bind's task and dropped only when that task exits.
        let ctl_channel = client.rpc_ctl().multiplexer().channel();
        let ctl_rx = ctl_channel.receiver.clone();
        let (notification_tx, notification_rx) = async_channel::unbounded();
        let (retire_tx, retire_rx) = oneshot::channel();
        let gen = self.inner.next_gen.fetch_add(1, Ordering::SeqCst) + 1;
        let bind = Arc::new(BoundSocket {
            gen,
            url,
            client,
            notification_tx,
            notification_rx,
            listener_id: Mutex::new(None),
            connected_at: AtomicU64::new(0),
            last_block_at: AtomicU64::new(0),
            daa_seen_since_connect: AtomicBool::new(false),
            announced: AtomicBool::new(false),
            stale_ctl: AtomicU64::new(0),
            stale_notifications: AtomicU64::new(0),
            retire_tx: Mutex::new(Some(retire_tx)),
            task: Mutex::new(None),
        });
        // Publish the identity BEFORE the task starts and before any connect:
        // the gate must already read this gen as current when its first event
        // lands, or the socket would discard its own birth.
        self.inner.current_gen.store(gen, Ordering::SeqCst);
        *self
            .inner
            .bound
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(bind.clone());
        let monitor = self.clone();
        let task_bind = bind.clone();
        let task = tokio::spawn(async move {
            // Holding the channel value here is what keeps this socket
            // registered on its own ctl multiplexer (see above).
            let _ctl_registration = ctl_channel;
            monitor.bind_loop(task_bind, ctl_rx, retire_rx).await;
        });
        *bind
            .task
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(task);
        // HOST only, never the whole URL (§19 drain). `validate_node_url` already
        // refuses `@`, `?` and `#`, so the userinfo and query routes for a
        // credential are closed — but it does NOT refuse a PATH SEGMENT, and a
        // user fronting their own node behind a token-auth reverse proxy writes
        // exactly `wss://node/<token>/borsh`. That is a credential, and logcat is
        // world-readable to anything holding READ_LOGS. `endpoint_host` stops at
        // the first `/`, which is what makes INV-3's "the endpoint lane carries
        // public data only" true here rather than merely asserted.
        log::info!(
            "link: bind gen={} armed for {}",
            bind.gen,
            link::endpoint_host(&bind.url)
        );
        Ok(bind)
    }

    /// **The one way a socket leaves (R4 D2).** Takes the installed bind,
    /// invalidates its identity, records its run whatever killed it, tells
    /// consumers once, and hands the client to the bounded teardown.
    ///
    /// Recording lives HERE rather than at each death site because that is
    /// what makes it unforgettable: D-098 read a column of zeros after a
    /// watchdog cascade because the writer existed and the kill path did not
    /// call it, and the soak then found a second silent path (the pause-path
    /// teardown left no lifecycle line at all). A path that tears a socket
    /// down without coming through here no longer exists.
    ///
    /// Recording is not judging: a deliberate teardown (pause, stop, manual
    /// reconnect) writes its lifecycle line and its `last_run_secs` and stops
    /// there — no strike, and no clean-run credit either. Only the arms that
    /// have evidence against an endpoint judge, exactly as before.
    async fn retire_bind(&self, cause: &str) -> Option<Retired> {
        // The whole state transition happens under the ONE lock a publish also
        // takes, with no await inside it — so a retirement and an
        // `on_connected` publish can never interleave and leave the link
        // reading connected with nothing bound (wallet-security BLOCK, R4).
        // The ctl close rides along synchronously (`try_signal_close`, pin
        // `rpc/core/src/api/ctl.rs:83`) so consumers see open/close in exactly
        // the order the state actually changed.
        let bind = {
            let mut bound = self
                .inner
                .bound
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let bind = bound.take()?;
            // From this instant every event still in flight from this socket is
            // stale — including the teardown event we are about to provoke,
            // which is the one that used to kill the next bind.
            self.inner.current_gen.store(0, Ordering::SeqCst);
            self.inner.is_connected.store(false, Ordering::SeqCst);
            self.inner.link_rpc.unbind();
            if bind.announced.swap(false, Ordering::SeqCst) {
                // Consumers hear about a socket exactly once, and only about
                // one that actually came up.
                let _ = self.inner.monitor_ctl.try_signal_close();
                self.emit(DagEvent::Disconnected);
            }
            bind
        };

        let connected_at = bind.connected_at.load(Ordering::Relaxed);
        let ever_connected = connected_at != 0;
        // Measured BEFORE the teardown: the wait for the pin's shutdown
        // handshake is ours, not part of the socket's life (L70 — never charge
        // our own timers to the subject).
        let run_secs = if ever_connected {
            Self::now_unix().saturating_sub(connected_at)
        } else {
            0
        };

        let listener_id = bind
            .listener_id
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        // **The evidence is recorded before we walk away**, not after. It is
        // computed entirely from values already in hand, and it used to sit
        // behind the listener-unregister wait — so a `run ended` line reached
        // the log up to 2 s later than the death it describes.
        if ever_connected {
            self.record_socket_run(&bind.url, run_secs, cause);
        } else {
            log::info!(
                "link: bind gen={} ({}) retired before it ever connected (cause={cause}) — \
                 no run to record",
                bind.gen,
                link::endpoint_host(&bind.url)
            );
        }
        if let Some(tx) = bind
            .retire_tx
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
        {
            let _ = tx.send(());
        }
        // **The goodbye is detached, because nothing may gate on it** (D-215).
        //
        // Both waits below belong to the socket being retired, and both sat on
        // the critical path of whatever came next. `install_bind` retires
        // before it constructs the replacement, so a swap that WINS paid the
        // listener unregister (≤2 s) and the disconnect wait (≤5 s) with the
        // wallet already dark, before one packet reached the node that had just
        // answered a probe; `on_disconnected` paid the same before it could
        // even ask for a new race. That is this file's own law inverted:
        // `DISCONNECT_WAIT_TIMEOUT`'s doc says the teardown is detached, never
        // awaited raw, and **nothing bounded may gate on its completion** — and
        // a bounded path was gating on it, one level up.
        //
        // **Nothing about the socket's death changes.** `bounded_disconnect`
        // already spawns the disconnect and bounds only the wait, and
        // `unregister_listener_bounded` keeps its own timeout inside the task,
        // so both stay exactly as bounded as they were; what is removed is US
        // standing there. The retirement itself — the unbind, the generation
        // bump, the published dark state — stays in the lock block above and is
        // still synchronous, so one-identity-at-a-time (R4 D2) is untouched and
        // connect-before-retire is still refused. A late `Disconnected` from
        // this client lands on a retired identity and is discarded, which is
        // the whole point of R4, and the successor carries its own
        // `BIND_ENVELOPE_TIMEOUT` for the guard this teardown can hold.
        //
        // **What changes for callers**: none of them are told the goodbye is
        // finished any more. The paths where that guarantee actually mattered
        // are `pause()` (the Android background grace-drop), `set_pinned_node`
        // and `hard_reconnect` — NOT `stop()`, which has no production caller
        // at all (the FFI exposes pause/resume; every `stop()` in the tree is a
        // test). On each of them the spawned task is polled on the next
        // scheduler tick, long before Android freezes the process, and a
        // starved socket never sent the close frame anyway — so what a healthy
        // socket now does is what a starved one always did, stated rather than
        // discovered.
        //
        // **It also raises the concurrency ceiling by design**: the await used
        // to serialize teardowns one at a time, and now up to one per
        // retirement can overlap, each holding its `Arc<KaspaRpcClient>` for at
        // most the two bounds above. On the retry-pause-free bind-failure loop
        // a few can coexist, and a `hard_reconnect` to the same URL briefly
        // holds two sockets to one node. Each self-terminates and the disconnect
        // was already detached inside `bounded_disconnect`, so this is a rate
        // change, not a leak.
        let client = bind.client.clone();
        let gen = bind.gen;
        let url = bind.url.clone();
        tokio::spawn(async move {
            if let Some(id) = listener_id {
                // Best-effort, and on ITS OWN client: unregistering through a
                // shared handle is how a stale teardown could deafen a live
                // socket.
                Self::unregister_listener_bounded(&client, id).await;
            }
            // The pin's `disconnect()` is a dispatcher handshake a blackholed
            // socket can starve (`workflow-websocket 0.18.0
            // client/native.rs:322-334` — `ws_sender.send().await` inside a
            // select arm body), and `KaspaRpcClient::disconnect` serializes
            // callers on `disconnect_guard` (pin `client.rs:476-482`).
            link::bounded_disconnect((*client).clone(), link::DISCONNECT_WAIT_TIMEOUT).await;
            log::info!(
                "link: teardown of retired bind gen={gen} ({host}) finished",
                host = link::endpoint_host(&url)
            );
        });
        let task = bind
            .task
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        Some(Retired { run_secs, task })
    }

    /// The connect race (V3 deliverable 1): candidates = the cached last-good
    /// endpoint (immediate dial — the fast path; it wins every tie because
    /// resolver candidates first spend an HTTP round-trip) + [`RACE_FETCHES`]
    /// parallel resolver fetches, demoted endpoints excluded; first HEALTHY
    /// probe wins and the shared socket binds to it. Loops (bounded pause)
    /// until bound, paused, or shut down — the replacement for the ws-level
    /// endless Retry.
    async fn race_loop(&self, mode: RaceMode) {
        // The V1 cold-connect span measures `connect_start` → `wss_connected`.
        // A swap hunt must NOT open one: it runs behind a live socket, so
        // folding it into that span would report a "cold connect" for a
        // wallet that was never cold and corrupt the only number the P0 fix
        // is measured by. It gets its own marker instead.
        let mut mode = mode;
        match &mode {
            RaceMode::Cold => spans::mark("connect_start"),
            RaceMode::Swap { from } => spans::mark_with("swap_start", link::endpoint_host(from)),
        }
        let mut empty_rounds = 0u32;
        loop {
            let degraded = degrade_lost_swap(mode.clone(), self.is_connected());
            if degraded != mode {
                if let RaceMode::Swap { from } = &mode {
                    log::info!(
                        "link: the swap hunt lost its incumbent ({}) — continuing as an \
                         ordinary hunt",
                        link::endpoint_host(from)
                    );
                }
                mode = degraded;
                // The wallet is dark from here, so the cold-connect span opens
                // now and the swap's round budget is discarded with the mode
                // that owned it.
                empty_rounds = 0;
                spans::mark("connect_start");
            }
            if !self.may_bind_from_race(&mode) {
                return;
            }
            let now = Self::now_unix();
            // **Hygiene degrades only for a wallet that is actually stranded**
            // (`consensus-auditor`, CONCERNS-2). The degradation's whole
            // justification, stated below, is "never strand the wallet" — and a
            // swap wallet is by definition not stranded, it is connected and
            // working. Left un-scoped, round 3 of EVERY swap hunt (the bound is
            // 3) emptied the demoted set and told `race_pantry` to ignore
            // demotions, so a tap could trade a healthy incumbent for a node
            // the ledger had convicted — and then set `hygiene_advisory`, which
            // suppresses the Connected-time refusal that would have bounced it.
            // Same shape as L129: a policy carried into a mode whose
            // precondition it no longer has.
            let advisory = hygiene_may_degrade(&mode, empty_rounds);
            let cached = self.read_cached_endpoint();
            let (demoted, pantry) = {
                let health = self
                    .inner
                    .health
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                let demoted = if advisory {
                    // Never strand the wallet on hygiene: two whole rounds
                    // found nothing healthy, so demotion degrades to advisory
                    // — a flaky node beats no node (connectivity over
                    // cleanliness).
                    Default::default()
                } else {
                    health.demoted_set(now)
                };
                // The pantry (C6): recent-healthy nodes dial immediately, in
                // parallel with the cached endpoint — the common reconnect
                // does zero HTTP before dialing a node it trusted recently.
                // Under the advisory degradation it ignores demotions too
                // (R2 D5): a floor that leaves the fast path dark is not a
                // floor, it is a slower way to reach the same dark wallet.
                let pantry =
                    health.race_pantry(cached.as_deref(), now, link::PANTRY_DIALS, advisory);
                (demoted, pantry)
            };
            // The incumbent never enters its own replacement race (P0b). It
            // rides the same set the demotion ledger uses, which is what makes
            // the exclusion total for free: `link::race` filters the cached
            // endpoint, every pantry dial AND every resolver answer against
            // it, so there is no lane left where the node we are already on
            // could win and be "swapped" onto itself.
            let excluded = round_exclusions(demoted, &mode);
            let outcome = link::race(
                &self.inner.resolver,
                self.inner.network_id,
                cached,
                pantry,
                &excluded,
                RACE_FETCHES,
                PROBE_TIMEOUT,
            )
            .await;

            // Judge the ROUND before judging its members (R2 field addendum,
            // widened at R3 D-099): whether a DNS/route failure is the node's
            // fault or the phone's is not visible in any single failure, only
            // in how many DISTINCT hosts failed phone-side at the same moment.
            let phone_fault = link::phone_fault_in_round(&outcome.failed);
            let Some(winner) = outcome.winner else {
                empty_rounds += 1;
                // The link-blackout stamp lives in the NO-WINNER arm only
                // (R3 wallet-security finding): a round that produced a live
                // prover proved the phone's network works, and stamping it
                // would let one stray unreachable candidate nullify the very
                // control-group conviction that round earned.
                //
                // **And only while we are DARK** (`consensus-auditor`,
                // CONCERNS-4). A swap round runs behind a socket delivering
                // ~10 blocks/s, which is direct positive proof the phone's
                // network works — so "every candidate failed phone-side" is no
                // longer the only witness available, and stamping a blackout
                // anyway would make `judge_admissibility` withhold strikes
                // from genuinely dead endpoints on the word of a round that
                // had a live prover the whole time. Lenient direction, but it
                // is the prover-vs-subject rule inverted.
                if phone_fault && !self.is_connected() {
                    self.inner.phone_fault_round_at.store(now, Ordering::SeqCst);
                    log::info!(
                        "link: round failed phone-side across {}+ distinct hosts \
                         (DNS/unreachable) — stamped as link blackout",
                        link::DNS_CORRELATION_MIN
                    );
                }
                // ONE line per empty round (R0 addendum #1, built at R1). An
                // outage used to spend ~9 INFO lines a round (a line per
                // resolver-fetch failure, a line per probe failure, then the
                // round line) — and under the weak-link condition the shared
                // ring retains only ~2 minutes, so the round pressure helped
                // evict its own head before it could be pulled (L65). Every
                // reason is still here, verbatim; only the line count shrank.
                // NOTE the honest bound: coalescing reduces OUR pressure, it
                // does not fix the class — Android's Wi-Fi subsystem is the
                // bigger spammer exactly when connectivity fails.
                log::info!(
                    "link: race round {empty_rounds} found no healthy endpoint ({} probe failure(s), {} other loss(es)) [{}] — retrying in {:?}",
                    outcome.failed.len(),
                    outcome.notes.len().saturating_sub(outcome.failed.len()),
                    link::summarize_losses(&outcome.notes),
                    RACE_RETRY_DELAY
                );
                // **Never tear down for a race that produced nothing** (P0b).
                // A swap is an errand behind a working link, so its failure
                // mode is to end quietly and leave the user exactly where
                // they were — on the node they already had. Nothing is
                // retired here, because a swap only ever retires inside
                // `install_bind`, and `install_bind` only runs on a winner.
                //
                // **The liveness term is re-read HERE, not inherited from the
                // top of the loop** (`consensus-auditor`, CONCERNS-1). `mode`
                // was decided up to ~9 s ago, and the likeliest moment for the
                // incumbent to die is inside the round the user tapped about.
                // Without this the last round's exhaustion would fire against a
                // stale `Swap`, return, and clear `race_running` — on a wallet
                // that had just gone dark, with `on_disconnected`'s own
                // `spawn_race` already refused because THIS loop still held the
                // single-flight flag. That is the exact inversion
                // `degrade_lost_swap` exists to prevent, reached by the one
                // placement its top-of-loop check cannot see. Falling through
                // instead costs one retry pause and the next iteration
                // degrades to an unbounded Cold hunt.
                if swap_hunt_exhausted(&mode, empty_rounds, self.is_connected()) {
                    if let RaceMode::Swap { from } = &mode {
                        log::info!(
                            "link: swap hunt found nothing better in {SWAP_HUNT_ROUNDS} \
                             round(s) — keeping {}",
                            link::endpoint_host(from)
                        );
                        spans::mark_with("swap_kept", link::endpoint_host(from));
                    }
                    return;
                }
                // Kickable pause (C4): a Reconnect tap / resume / OS
                // network-available signal skips the wait and races NOW.
                // Kicks interrupt the SLEEP only — in-flight probes were
                // already drained by race() above (the reaper finding
                // stands: probes are never aborted).
                tokio::select! {
                    _ = tokio::time::sleep(RACE_RETRY_DELAY) => {}
                    _ = self.inner.race_kick.notified() => {
                        log::info!("link: retry pause kicked — racing immediately");
                    }
                }
                continue;
            };
            // A winning round's losers get the same one-line treatment — the
            // strike lines below name the URLs but not WHY, and the why is what
            // separated `ivy`'s real HTTP 500 from four weak-link timeouts in
            // the 2026-07-30 capture.
            if !outcome.notes.is_empty() {
                log::info!(
                    "link: race round {} lost {} candidate(s) before the winner [{}]",
                    empty_rounds + 1,
                    outcome.notes.len(),
                    link::summarize_losses(&outcome.notes)
                );
            }
            empty_rounds = 0;

            // A healthy node answered → the network is alive → probe failures
            // were the NODES' fault: strike them. (The drop that triggered
            // this race is parked as the pending strike and settles at the
            // Connected event — robust to a phantom redial winning first.)
            // The round-correlation verdict still travels with each loss so
            // correlated DNS/unreachable losses are withheld (D-097 widened).
            if phone_fault {
                log::info!(
                    "link: DNS/route failure across {}+ distinct endpoints this round — \
                     reading it as the phone, not the nodes (those strikes withheld)",
                    link::DNS_CORRELATION_MIN
                );
            }
            for (url, reason) in &outcome.failed {
                self.commit_strike(url, *reason, now, phone_fault);
            }

            // Someone else (a ws-level phantom redial) may have connected
            // while the race ran; the Connected-time demotion check has
            // already judged them. Never bind over a live socket — and since
            // D-187, never over a node the user pinned mid-round either. A
            // SWAP passes this deliberately: the live socket it binds over is
            // the one the user asked to leave, and it is never the winner
            // (excluded above).
            if !self.may_bind_from_race(&mode) {
                return;
            }

            log::info!(
                "link: race winner {} (server {}, rpc v{}, daa {}){}",
                link::endpoint_host(&winner.url),
                winner.server_version,
                winner.rpc_api_version,
                winner.virtual_daa_score,
                if advisory { " [hygiene advisory]" } else { "" }
            );
            spans::mark_with("race_winner", link::endpoint_host(&winner.url));
            // **A swap closes the span it opened** (P0b). `on_connected` marks
            // `wss_connected` for this bind like any other, and a swap
            // deliberately never opened a `connect_start` — so without a
            // marker here the winning swap's `wss_connected` is the next thing
            // after whatever `connect_start` came before it, and a
            // cold-connect reading taken by pairing the two reports "time
            // since the app opened". That is the same corruption
            // `RaceMode::Swap`'s own span comment exists to prevent, displaced
            // to the other end of the leg. `swap_start` → `swap_won` is also
            // the only lane that can measure what the fix is FOR.
            if matches!(mode, RaceMode::Swap { .. }) {
                spans::mark_with("swap_won", link::endpoint_host(&winner.url));
            }
            // Pantry stamp (C6): a probe win IS an observed-healthy moment.
            self.mark_endpoint_healthy(&winner.url);
            // An advisory bind to a still-demoted endpoint must not be
            // bounced by our own Connected-time enforcement.
            self.inner.hygiene_advisory.store(
                advisory
                    && self
                        .inner
                        .health
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .is_demoted(&winner.url, Self::now_unix()),
                Ordering::SeqCst,
            );

            // A NEW identity per bind (R4): its own client, its own ctl and
            // notification streams, its own generation. The socket this dials
            // can never be confused with the one it replaces.
            let bind = match self.install_bind(winner.url.clone()).await {
                Ok(bind) => bind,
                Err(e) => {
                    log::warn!(
                        "link: could not arm a bind for {}: {}",
                        link::endpoint_host(&winner.url),
                        link::sanitize_node_text(&e.to_string())
                    );
                    continue;
                }
            };
            let options = ConnectOptions {
                url: Some(winner.url.clone()),
                strategy: ConnectStrategy::Fallback,
                block_async_connect: true,
                connect_timeout: Some(BIND_TIMEOUT),
                ..Default::default()
            };
            // Envelope-bounded (BLOCK fix at R0): the connect's error arm
            // can block on the pin's disconnect_guard behind a starved
            // teardown — bound the whole call at OUR boundary (item 19).
            // A dropped connect future is safe under existing law: a
            // Fallback dial failure self-terminates, AlreadyConnected
            // returns before a loop spawns, and a late success is judged
            // at Connected (D-084 machinery — no second authority).
            match tokio::time::timeout(BIND_ENVELOPE_TIMEOUT, bind.client.connect(Some(options)))
                .await
            {
                Ok(Ok(_)) => {
                    // A pause that landed mid-bind wins: drop the socket.
                    if self.inner.paused.load(Ordering::SeqCst) {
                        self.retire_bind("pause-lost-bind").await;
                        return;
                    }
                    // Somebody retired this bind while we were dialing it (a
                    // Reconnect tap, a pull-heal, the demoted-refusal arm).
                    // Its `Connected` is stale by identity and will be
                    // discarded, so NOTHING will bring the link up if we return
                    // here — and every other recovery path short-circuits on
                    // `is_connected()`. Before R4 the socket's own event still
                    // healed this; now the hunt has to. Keep hunting.
                    if !self.is_current_bind(bind.gen) {
                        log::info!(
                            "link: the bind to {} was retired while it was dialing — \
                             keeping the hunt alive",
                            link::endpoint_host(&winner.url)
                        );
                        continue;
                    }
                    return;
                }
                Ok(Err(e)) => {
                    // Died between probe and bind — strike (network known
                    // alive: it just answered a probe elsewhere) and re-race.
                    log::warn!(
                        "link: bind to race winner {} failed: {}",
                        link::endpoint_host(&winner.url),
                        link::sanitize_node_text(&e.to_string())
                    );
                    // ...unless WE broke the dial by retiring the bind under
                    // it. Convicting a node for our own act is the
                    // self-inflicted verdict auditor item 18 forbids — the same
                    // reasoning that already spares the envelope-timeout arm.
                    if self.is_current_bind(bind.gen) {
                        self.commit_strike(
                            &winner.url,
                            link::StrikeReason::BindFailed,
                            Self::now_unix(),
                            false,
                        );
                    } else {
                        log::info!(
                            "link: bind to {} failed after we retired it — no strike (ours)",
                            link::endpoint_host(&winner.url)
                        );
                    }
                    self.retire_bind("bind-failed").await;
                }
                Err(_) => {
                    // NO strike: the node just won a probe — this is our own
                    // teardown guard blocking, not the endpoint's fault.
                    log::warn!(
                        "link: bind to race winner {} exceeded {BIND_ENVELOPE_TIMEOUT:?} \
                         (teardown guard suspected) — re-racing, no strike",
                        link::endpoint_host(&winner.url)
                    );
                    self.retire_bind("bind-timeout").await;
                }
            }
        }
    }

    /// Background grace-drop (PERFORMANCE_BUDGET "battery posture"): close the
    /// socket and stand the race down, keeping the event task and every
    /// subscriber attached. The wallet processor pauses with the shared ctl and
    /// resyncs in lockstep on [`Self::resume`] (§0.8 / D-005).
    pub async fn pause(&self) -> Result<()> {
        self.inner.pause_gen.fetch_add(1, Ordering::SeqCst);
        self.inner.paused.store(true, Ordering::SeqCst);
        // R4 D2: a grace-drop is a socket death like any other and now leaves
        // its lifecycle line. The soak's 13:57 socket vanished without one and
        // the 14:06 resume raced against a run nobody had measured.
        self.retire_bind("paused").await;
        Ok(())
    }

    /// Foreground resume after a grace-drop: relink in the configured mode —
    /// re-race (the cached last-good endpoint, persisted at most 30 s + grace
    /// ago, is candidate 0 and wins every tie), or redial the pinned node.
    /// No-op while already connected (never bounce a healthy socket); a race
    /// already hunting gets kicked instead of ignored (C4).
    pub async fn resume(&self) -> Result<()> {
        spans::mark("resume_start");
        self.inner.paused.store(false, Ordering::SeqCst);
        if self.is_connected() {
            return Ok(());
        }
        self.relink("resume").await
    }

    /// The user's own "try now" — the P3 honest-liveness Reconnect control and
    /// the foreground watchdog's recovery (D-068). Unlike [`resume`], it does
    /// NOT short-circuit on `is_connected()`: a silently dead wRPC socket can
    /// still report connected, so recovering it needs a real gesture.
    ///
    /// `stalled = true` means the caller HAS failure evidence against the
    /// current endpoint (the watchdog's 30 s block silence) — it enters the
    /// race as a pending strike, committed only if the race finds a healthy
    /// node (control-group rule). A manual Reconnect passes `false`: bouncing
    /// a healthy node must never demote it.
    ///
    /// **What a tap costs depends on what it can preserve** (P0b):
    ///
    /// | state | what happens |
    /// |:--|:--|
    /// | connected, unpinned | bounded swap hunt behind the live link; the incumbent is dropped only when a replacement is armed |
    /// | connected, pinned | [`Self::hard_reconnect`] — there is no other node to find, so a tap can only mean "redial mine" |
    /// | dark / hunting | the C4 kick, unchanged |
    /// | `stalled = true` | the confirmed-stall execution above, then the hard path — the socket is proven silent |
    pub async fn reconnect(&self, stalled: bool) -> Result<()> {
        self.inner.paused.store(false, Ordering::SeqCst);
        if stalled {
            // The watchdog's claim is judged against OUR clocks (R3 D-099).
            // Its Dart-side block-age is process-lifetime, so after a link
            // blackout every fresh bind inherits silence older than itself
            // and used to be executed on the next 10 s tick — runs of ~10 s,
            // repeatedly, one innocent endpoint demoted per cycle (the
            // D-095/D-098 cascade signature). A stall claim now only
            // executes a CONNECTED socket that has ITSELF been silent past
            // the threshold.
            match self.stall_verdict() {
                StallVerdict::Execute { silent_secs } => {
                    // The defendant is the socket the verdict judged — named
                    // by its own identity, not by a descriptor re-read now.
                    if let Some(url) = self.current_bind().map(|bind| bind.url.clone()) {
                        log::info!(
                            "link: watchdog stall confirmed on {host} \
                             (socket silent {silent_secs}s) — executing",
                            host = link::endpoint_host(&url)
                        );
                        // Retirement records the run (cause=watchdog-stall).
                        self.retire_bind("watchdog-stall").await;
                        self.set_pending_strike(url, link::StrikeReason::Stall);
                    }
                }
                StallVerdict::Refuse { silent_secs } => {
                    // No teardown either: the claim is void, and bouncing a
                    // young socket every tick IS the cascade.
                    log::info!(
                        "link: watchdog stall claim refused — socket silent only \
                         {silent_secs}s (< {}s)",
                        link::WATCHDOG_STALL_SECS
                    );
                    return Ok(());
                }
                StallVerdict::Hunting => {
                    // There is no defendant, but the claim still means the
                    // wallet is dark — keep C4's promise and kick the hunt.
                    log::info!("link: watchdog stall claim while hunting — kicking the hunt");
                    return self.relink("watchdog-kick").await;
                }
            }
        }
        // **Find, then swap** (P0b). A tap on a CONNECTED, unpinned wallet is
        // a request for a *different* node, not a request to be disconnected
        // — and the old order made those the same thing. Measured on the
        // founder's link, 2026-08-28: `run ended run=275s
        // cause=manual-reconnect`, then a fresh race that had not landed
        // five minutes later. The wallet the user was trying to improve was
        // the price of asking.
        //
        // So the live bind stays up and a bounded [`RaceMode::Swap`] hunt
        // looks for a replacement behind it. The teardown moves to the only
        // place it can now happen — `install_bind`, on a winner — so a hunt
        // that finds nothing costs the user nothing at all.
        //
        // Pinned is deliberately NOT swapped: there is no different node to
        // find, so a tap can only mean "redial mine", which is the hard path
        // below.
        //
        // The `paused` term is a DEFENSIVE re-read, not the route a paused
        // wallet takes — say so, because the obvious reading is wrong: this
        // function cleared that flag at its head, so on the `!stalled` path
        // (no await in between) it can only be true again if another task
        // paused us in this instant, and a paused wallet has no live bind for
        // `current_bind()` to return anyway. Both facts point the same way —
        // dialing behind the battery posture is exactly what pausing forbids —
        // and the race loop refuses `paused` a third time before it binds.
        if !stalled
            && self.is_connected()
            && !self.is_pinned()
            && !self.inner.paused.load(Ordering::SeqCst)
        {
            if let Some(bind) = self.current_bind() {
                let from = bind.url.clone();
                // L127 holds unchanged: the tap ALWAYS acts. A hunt already
                // running takes the kick — never a second search authority
                // (D-081), and never a silent no-op.
                if !self.spawn_race_with(RaceMode::Swap { from: from.clone() }) {
                    self.kick_race("swap-tap");
                } else {
                    log::info!(
                        "link: swap hunt started — {} stays up until something better answers",
                        link::endpoint_host(&from)
                    );
                }
                return Ok(());
            }
        }
        self.hard_reconnect().await
    }

    /// **Drop, then hunt** — the teardown path, for the gestures that mean it.
    ///
    /// Two callers, both of which have already concluded the socket is no
    /// good: the watchdog's confirmed stall (above), and the hard pull-heal
    /// (`dag_resync`), which is reached only after the socket failed a real
    /// round-trip or read unhealthy. Those want a NEW socket and a rescan on
    /// its `Connected`; keeping a suspected-deaf incumbent because nothing
    /// better answered would make the gesture a no-op and its `true` return a
    /// lie. The user's own tap does not come here while it has a live link to
    /// preserve — see [`Self::reconnect`].
    pub async fn hard_reconnect(&self) -> Result<()> {
        // A deliberate reconnect must never park a strike against the healthy
        // endpoint it is bouncing (caught live at the V3 sitting: a
        // swipe-to-refresh demoted the innocent incumbent) — retirement
        // records the run and judges nothing.
        //
        // Before R4 this arm pre-cleared `is_connected` so the ctl arm's
        // swap-once guard would skip judging our own teardown. That guard is
        // now structural: the teardown's `Disconnected` arrives on a retired
        // identity, and the gate discards it.
        self.retire_bind("manual-reconnect").await;
        // The tap always acts (C4). Unpinned that is spawn-or-kick — the old
        // path silently no-opped here whenever a wedged race loop still held
        // the single-flight flag (the dead-Reconnect symptom's second half).
        // Pinned it redials the user's node, which before D-187 this path
        // could not do at all: it retired the bind and then asked a race that
        // pinned mode refuses to run, so Reconnect KILLED a pinned link.
        self.relink("reconnect").await
    }

    /// OS default-network transition (C5/D-089 ruling 4), relayed from
    /// Android's `ConnectivityManager` over the platform channel + bridge.
    /// Semantics: available with a dead link → redial NOW (spawn-or-kick)
    /// instead of waiting out a retry pause or the 30 s watchdog; available
    /// while connected → log only (the watchdog owns staleness — OS
    /// callbacks can flap, and a handoff-killed socket fires its own
    /// Disconnected); lost → log + span only (passive first: the socket's
    /// own death drives recovery; more aggression only if the soak proves
    /// the watchdog gap hurts). Paused (backgrounded) → observe, never dial:
    /// the battery posture owns the socket then, and resume() re-races.
    pub async fn network_changed(&self, available: bool) {
        // Record it for the glass (C7) before deciding what to DO about it:
        // the honest-states surface needs the OS's word even on the paths that
        // deliberately take no action.
        self.inner.os_offline.store(!available, Ordering::SeqCst);
        if !available {
            // R2 D3: the boolean alone cannot judge admissibility — by the
            // time a parked strike settles, `onAvailable` has usually already
            // flipped it back to false, erasing the very fact the rule needs.
            // Stamp the TRANSITION so the window survives the recovery.
            self.inner
                .os_lost_at
                .store(Self::now_unix(), Ordering::SeqCst);
            spans::mark("network_lost");
            log::info!("link: OS network lost — passive (the socket's own death drives recovery)");
            return;
        }
        spans::mark("network_available");
        if self.inner.paused.load(Ordering::SeqCst) {
            log::info!(
                "link: OS network available while paused — background posture holds, no dial"
            );
        } else if self.is_connected() {
            log::info!(
                "link: OS network available while connected — no action (watchdog owns staleness)"
            );
        } else {
            log::info!("link: OS network available while disconnected — dialling now");
            // Pinned or not: before D-187 this raced, and a race is a no-op
            // while pinned — so a pinned wallet that lost Wi-Fi stayed dark
            // until the process restarted.
            if let Err(e) = self.relink("network_available").await {
                log::warn!("link: network-available relink failed: {e}");
            }
        }
    }

    /// Durably record that a socket's run ended, however it ended (R3 D1).
    /// One greppable lifecycle line + the `last_run_secs` ledger write, from
    /// the SHARED seam both death paths call — the Disconnected arm and the
    /// watchdog execution. The watchdog path used to bypass the Disconnected
    /// arm entirely (it pre-clears `is_connected`, so the swap-once guard
    /// skips the judged branch), which is why D-098 read a column of zeros
    /// after a watchdog-driven cascade: the writer existed and was never on
    /// that path.
    fn record_socket_run(&self, url: &str, run_secs: u64, cause: &str) {
        {
            let mut health = self
                .inner
                .health
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            health.record_run(url, run_secs);
            self.save_health(&health);
        }
        // HOST only (§19 drain — same path-segment credential as `install_bind`).
        // The `url=` KEY is deliberately kept: device forensics and every prior
        // sitting grep this line by it (D-187 and the soak verdicts), so narrowing
        // the VALUE is safe where changing the key would break the readers. The TSV
        // health ledger still keys on the whole URL — that is on-device app-private
        // storage, not the log lane.
        log::info!(
            "link: run ended url={} run={run_secs}s cause={cause}",
            link::endpoint_host(url)
        );
    }

    /// The stall verdict for a watchdog claim (R3 D-099), judged against OUR
    /// clocks: the Dart watchdog's block-age is process-lifetime, so after a
    /// link blackout it reads stale silence against a seconds-old socket.
    /// The evidence baseline is `max(last_block_at, connected_at)` — a socket
    /// cannot be guilty of silence older than itself.
    /// R4 sharpens it further: both halves of the baseline are now the ACCUSED
    /// SOCKET's own (`BoundSocket::last_block_at` / `connected_at`), so a
    /// block delivered by a previous socket can neither excuse nor condemn
    /// this one.
    fn stall_verdict(&self) -> StallVerdict {
        let Some(bind) = self.current_bind() else {
            return StallVerdict::Hunting;
        };
        if !self.is_connected() {
            return StallVerdict::Hunting;
        }
        let now = Self::now_unix();
        let baseline = bind
            .last_block_at
            .load(Ordering::Relaxed)
            .max(bind.connected_at.load(Ordering::Relaxed));
        let silent_secs = now.saturating_sub(baseline);
        if baseline != 0 && silent_secs > link::WATCHDOG_STALL_SECS {
            StallVerdict::Execute { silent_secs }
        } else {
            StallVerdict::Refuse { silent_secs }
        }
    }

    /// Record that a block just arrived (the watchdog heartbeat). Two clocks,
    /// two purposes (R4): the socket's own is the evidence a stall claim is
    /// judged against, the process-wide one is how old the glass's data is.
    fn mark_block_seen(&self, bind: &BoundSocket) {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        bind.last_block_at.store(now, Ordering::Relaxed);
        self.inner.last_block_at.store(now, Ordering::Relaxed);
    }

    /// Seconds since the last BlockAdded, or `None` if none has arrived yet
    /// (fresh boot / never connected). The watchdog's honest-liveness reading:
    /// a healthy mainnet keeps this near zero; a stalled socket lets it grow.
    pub fn last_block_age_secs(&self) -> Option<u64> {
        let last = self.inner.last_block_at.load(Ordering::Relaxed);
        if last == 0 {
            return None;
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        Some(now.saturating_sub(last))
    }

    /// Disconnects, then signals the event task and waits for it to drain.
    /// Sets `paused` so a live race loop stands down instead of redialing.
    pub async fn stop(&self) -> Result<()> {
        self.inner.paused.store(true, Ordering::SeqCst);
        // The retirement records the run and signals the bind's task; at
        // process stop there is nobody left to read the drain evidence, so the
        // task is dropped rather than waited out.
        if let Some(retired) = self.retire_bind("stopped").await {
            if let Some(task) = retired.task {
                task.abort();
                let _ = task.await;
            }
        }
        Ok(())
    }

    fn emit(&self, event: DagEvent) {
        // Send fails only when no receiver is subscribed yet — fine to drop.
        let _ = self.inner.events.send(event);
    }

    /// One socket's whole life, serviced by its own task (R4).
    ///
    /// Every event — before or after retirement — passes the identity gate on
    /// the way in. That is deliberate: retirement and the teardown event it
    /// provokes race each other by design (the soak measured 1–5 ms), so the
    /// task can and does see its own death notice while still in its normal
    /// loop. The gate, not the ordering, is what makes that harmless.
    ///
    /// After retirement the task keeps reading for [`RETIRED_DRAIN`] so the
    /// late teardown — the one that used to be attributed to the next socket
    /// and kill it — is seen, logged and discarded, then reports what it
    /// refused and exits.
    async fn bind_loop(
        self,
        bind: Arc<BoundSocket>,
        ctl_rx: async_channel::Receiver<RpcState>,
        retire_rx: oneshot::Receiver<()>,
    ) {
        let mut retire_rx = retire_rx;
        // `Some(deadline)` once this bind has been retired.
        let mut exit_at: Option<tokio::time::Instant> = None;
        loop {
            tokio::select! {
                // Poll order matters (biased): drain ctl + notifications
                // before honoring the exit, mirroring the upstream example.
                biased;
                msg = ctl_rx.recv() => {
                    match msg {
                        Ok(state) if !self.is_current_bind(bind.gen) => {
                            self.discard_ctl(&bind, state);
                        }
                        Ok(RpcState::Connected) => self.on_connected(&bind).await,
                        Ok(RpcState::Disconnected) => self.on_disconnected(&bind).await,
                        // Ctl channel closed: client is gone, nothing to track.
                        Err(_) => {
                            log::warn!(
                                "dag-monitor: ctl channel closed for bind gen={} — task exiting",
                                bind.gen
                            );
                            break;
                        }
                    }
                }
                notification = bind.notification_rx.recv() => {
                    match notification {
                        Ok(_) if !self.is_current_bind(bind.gen) => {
                            self.discard_notification(&bind);
                        }
                        Ok(notification) => self.on_notification(&bind, notification),
                        Err(_) => {
                            log::warn!(
                                "dag-monitor: notification channel closed for bind gen={} — task exiting",
                                bind.gen
                            );
                            break;
                        }
                    }
                }
                _ = &mut retire_rx, if exit_at.is_none() => {
                    exit_at = Some(tokio::time::Instant::now() + RETIRED_DRAIN);
                }
                _ = async {
                    match exit_at {
                        Some(deadline) => tokio::time::sleep_until(deadline).await,
                        // Never fires while this bind is live.
                        None => std::future::pending::<()>().await,
                    }
                } => break,
            }
        }
        let ctl = bind.stale_ctl.load(Ordering::Relaxed);
        let notes = bind.stale_notifications.load(Ordering::Relaxed);
        if ctl > 0 || notes > 0 {
            log::info!(
                "link: retired bind gen={} ({}) discarded {ctl} stale ctl event(s) and \
                 {notes} stale notification(s)",
                bind.gen,
                link::endpoint_host(&bind.url)
            );
        }
    }

    /// This bind's socket came up — and the gate has already confirmed this
    /// bind is the installed one, so everything below speaks about IT.
    async fn on_connected(&self, bind: &Arc<BoundSocket>) {
        // This connect IS the network-alive proof: settle the parked strike
        // (commit fresh from a DIFFERENT prover; discard stale or
        // self-refuted — D-084). The prover is named by identity now, not by
        // a client descriptor re-read at event time.
        self.settle_pending_strike(Some(bind.url.as_str()));
        // Demotion enforcement at the one choke point every connection passes
        // — a demoted endpoint that sneaks back in (a ws-level phantom redial,
        // a poisoned cache) is refused and re-raced, UNLESS the race itself
        // bound it knowingly (hygiene advisory: nothing healthier exists).
        if !self.is_pinned()
            && !self.inner.hygiene_advisory.load(Ordering::SeqCst)
            && !self.inner.paused.load(Ordering::SeqCst)
            && self
                .inner
                .health
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .is_demoted(&bind.url, Self::now_unix())
        {
            log::warn!(
                "link: demoted endpoint reconnected — refusing {} and re-racing",
                link::endpoint_host(&bind.url)
            );
            self.retire_bind("demoted-refusal").await;
            self.spawn_race();
            return;
        }
        match self.handle_connect(bind).await {
            Ok(()) => {
                // **Publish atomically against retirement (R4, wallet-security
                // BLOCK).** The identity gate runs at event INTAKE, but
                // everything above — the strike settle, the demotion read —
                // takes real time (the subscribe leg does NOT: see
                // `handle_connect`), and even a leg costing nothing would leave
                // this window, because `handle_connect` is an await point
                // whatever it spends. `pause()`,
                // `reconnect()` and the race's own arms all retire from OTHER
                // tasks. A retirement that lands inside that window used to
                // find `bound = Some(..)`, tear the socket down, and then have
                // this arm set `is_connected = true` behind it: link up, no
                // bind installed, every recovery path short-circuiting on
                // `is_connected()` — a dark wallet reading "Connected" that
                // only an app kill could clear, which is the D-100 outage class
                // re-entering through the door built to close it.
                //
                // So the whole transition happens under the ONE lock
                // `retire_bind` takes, with no await inside it. The ctl signal
                // rides along via the pin's SYNCHRONOUS `try_signal_open`
                // (`rpc/core/src/api/ctl.rs:77`) — its multiplexer channels are
                // unbounded (workflow-core `channel.rs:203`), so `try_broadcast`
                // cannot fail for want of capacity — which keeps the consumers'
                // open/close order identical to the state transitions.
                {
                    let bound = self
                        .inner
                        .bound
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    if bound.as_ref().map(|installed| installed.gen) != Some(bind.gen) {
                        log::info!(
                            "link: bind gen={} ({}) was retired while it came up — \
                             not published; the hunt owns recovery",
                            bind.gen,
                            link::endpoint_host(&bind.url)
                        );
                        return;
                    }
                    // `connected_at` FIRST, `is_connected` second (R3
                    // consensus-audit finding): the stamp is published before
                    // the flag, so a stall claim landing between the two can
                    // never judge this fresh socket against a stale baseline.
                    // R4 makes the point moot as well as ordered — the baseline
                    // lives on the socket itself.
                    bind.connected_at.store(Self::now_unix(), Ordering::Relaxed);
                    // The stable handle points at this socket BEFORE anyone is
                    // told it exists, so a consumer reacting to the ctl open
                    // finds it (L59: the funds lanes re-arm on connect).
                    self.inner.link_rpc.bind(bind.client.clone());
                    self.inner.is_connected.store(true, Ordering::SeqCst);
                    bind.daa_seen_since_connect.store(false, Ordering::Relaxed);
                    self.inner
                        .monitor_ctl
                        .set_descriptor(Some(bind.url.clone()));
                    bind.announced.store(true, Ordering::SeqCst);
                    let _ = self.inner.monitor_ctl.try_signal_open();
                    self.emit(DagEvent::Connected {
                        url: Some(bind.url.clone()),
                    });
                }
                // V1 spans: close the cold-connect leg, arm the first-DAA one.
                spans::mark("wss_connected");
                // Shape note for the forensic lane: the endpoint is no longer
                // Debug-printed through an `Option` (it used to read
                // `connected to Some("wss://…")`), because a bind always knows
                // its own url. Capture greps that keyed on `Some(` want
                // `dag-monitor: connected to wss://` now.
                log::info!(
                    "dag-monitor: connected to {} (bind gen={})",
                    link::endpoint_host(&bind.url),
                    bind.gen
                );
                // Remember the node that worked — it is candidate 0 (the fast
                // path) of the next cold start / post-grace race — and stamp it
                // observed-healthy for the pantry (C6).
                self.persist_endpoint(&bind.url);
                self.mark_endpoint_healthy(&bind.url);
            }
            // Stay "disconnected"; the race re-heal answers the Disconnected
            // this failure ends in.
            //
            // **KNOWN GAP, and WORSE than it was written** (audited 2026-06-12;
            // re-read at the pin 2026-08-29, `consensus-auditor` BLOCK on
            // D-216). The old wording — "if the node accepts the socket but
            // rejects a subscription" — cannot happen through this arm at all.
            // `KaspaRpcClient::start_notify` (pin `client.rs:694`) is
            // `notifier().try_start_notify()`, which is SYNCHRONOUS to a
            // `parking_lot` mutation ending in unbounded channel sends
            // (`notifier.rs:467` → `subscriber.rs:210`). The real
            // `RpcApiOps::Subscribe` round-trip is issued later on the
            // Subscriber's own task, and its failure is swallowed there by a
            // `trace!`. So a node that takes the socket and never honours the
            // subscription produces NO error here, `is_connected` publishes
            // `true`, and the wallet is **connected and deaf** — the D-083
            // shape. The only errors this arm can actually see are local.
            //
            // It is also unowned: this arm only warns. It does not retire and
            // does not re-race, so a half-subscribed bind idles until a user
            // tap, an OS network event or a natural drop. The fix is
            // arm-and-verify (prove the push lane is live on the new socket —
            // `bind.daa_seen_since_connect` already exists and is one `if`
            // away), not a timeout on a local call.
            Err(e) => log::warn!(
                "dag-monitor: subscription setup failed: {}",
                link::sanitize_node_text(&e.to_string())
            ),
        }
    }

    /// This bind's socket died — and it is still the installed one, so the
    /// death is real news rather than a retired socket's echo.
    async fn on_disconnected(&self, bind: &Arc<BoundSocket>) {
        let was_connected = self.inner.is_connected.load(Ordering::SeqCst);
        log::info!("dag-monitor: disconnected (bind gen={})", bind.gen);
        // Pinned mode (dev/tests): the pin's own Retry loop owns this client
        // and brings the SAME socket object back up, so the bind is kept and
        // only the connection state is stood down.
        if self.is_pinned() {
            self.inner.is_connected.store(false, Ordering::SeqCst);
            let listener_id = bind
                .listener_id
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .take();
            if let Some(id) = listener_id {
                Self::unregister_listener_bounded(&bind.client, id).await;
            }
            if bind.announced.swap(false, Ordering::SeqCst) {
                let _ = self.inner.monitor_ctl.try_signal_close();
                self.emit(DagEvent::Disconnected);
            }
            return;
        }
        // A socket that never reached an accepted `Connected` belongs to the
        // race loop that is still dialing it: its bind-failure arm retires it
        // (and strikes, when the node is at fault). Retiring it from here
        // would pull the identity out from under an in-flight connect.
        if !was_connected {
            return;
        }
        let paused = self.inner.paused.load(Ordering::SeqCst);
        // The app is the one reconnect authority (D-081): retirement kills the
        // ws-level loop still loyal to the dropped URL (best-effort — a dial
        // already in flight can't be aborted; whatever it lands on is judged
        // at its own Connected) and records the run through the single seam.
        let Some(retired) = self.retire_bind("ctl-drop").await else {
            return;
        };
        if paused {
            return;
        }
        // R2 D4: the run length is recorded for EVERY judgment before deciding
        // what it means — the floor can only be re-examined against the drops
        // it absorbed, and a ledger that stored only convictions would keep
        // proving the floor right by construction.
        let run_secs = retired.run_secs;
        match link::judge_run(run_secs) {
            link::RunJudgment::CleanRun => self.commit_clean_run(&bind.url),
            link::RunJudgment::Strike => {
                self.set_pending_strike(bind.url.clone(), link::StrikeReason::Drop)
            }
            link::RunJudgment::ChurnNoise => {
                // V6 churn-smoothing (item 16): a run this short never lived —
                // its death says nothing about the endpoint.
                log::info!(
                    "link: drop after {run_secs}s run on {} — churn noise, no strike",
                    link::endpoint_host(&bind.url)
                );
            }
        }
        // **Spawn-or-KICK, since P0b.** A bare `spawn_race` was complete while
        // the flag could only be held by a hunt for a link we did not have:
        // reaching here meant the socket had just died, so nothing was
        // hunting, so the spawn always won. Find-then-swap made a race
        // legal behind a LIVE socket — and this is the death of exactly that
        // socket, so now the refusal is the common case, not the impossible
        // one. Refused and silent, the wallet's recovery waited out the swap
        // round in flight plus its retry pause (~9 s) before the loop's own
        // top-of-loop degrade noticed the wallet had gone dark. The kick
        // interrupts the pause and gets that degrade one round sooner; pinned
        // already returned above, so this is spawn-or-kick with the pin arm
        // spent.
        self.spawn_or_kick_race("ctl-drop");
    }

    /// A notification from the installed socket. Everything here folds state
    /// this bind produced; a retired socket's stream is discarded upstream.
    fn on_notification(&self, bind: &Arc<BoundSocket>, notification: Notification) {
        match notification {
            // P2.1 payload scan: BlockAdded is consumed here — the ~10
            // blocks/s stream never leaves this task; only `ciph_msg:` matches
            // fan out (sparse by design, §0.3). Version-neutral by
            // construction (transport.rs, §0.2).
            Notification::BlockAdded(added) => {
                let matches = transport::scan_block(&added.block, self.inner.address_prefix);
                if !matches.is_empty() {
                    // Three-lights producer log (V3/L55): count + receiver
                    // count only — payload bodies are never logged (§4
                    // plaintext discipline). `info`: the liblog lane is
                    // Info-max, a `debug` light is dark on device (L53).
                    log::info!(
                        "dag-monitor: transport emit matches={} receivers={}",
                        matches.len(),
                        self.inner.transport_events.receiver_count()
                    );
                }
                for event in matches {
                    // Send fails only with zero subscribers — fine.
                    let _ = self.inner.transport_events.send(event);
                }
                // Liveness heartbeat for the watchdog (P3): a block arrived,
                // THIS socket is alive right now.
                self.mark_block_seen(bind);
                // Advance the catch-up cursor past this scanned block
                // (throttled; no-op until transport arms it). P5/D-067.
                self.persist_transport_cursor(&added.block.header.hash);
            }
            // V1 acceptance spine: forward the batch to the tracker task when
            // one is attached (never processed here — the event task stays
            // non-blocking; blue-score resolution and persistence live in the
            // tracker).
            Notification::VirtualChainChanged(vcc) => {
                let sender = self
                    .inner
                    .vcc_tx
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .clone();
                if let Some(tx) = sender {
                    let accepted: Vec<(Hash, Vec<Hash>)> = vcc
                        .accepted_transaction_ids
                        .iter()
                        .map(|a| (a.accepting_block_hash, a.accepted_transaction_ids.clone()))
                        .collect();
                    let _ = tx.send(VccBatch {
                        removed_chain_block_hashes: vcc.removed_chain_block_hashes.clone(),
                        added_chain_block_hashes: vcc.added_chain_block_hashes.clone(),
                        accepted: Arc::new(accepted),
                    });
                }
            }
            other => {
                if let Some(event) = map_notification(&other) {
                    // V1 span: the first DAA tick after a connect closes the
                    // time-to-first-DAA row.
                    if matches!(event, DagEvent::VirtualDaaScore(_))
                        && !bind.daa_seen_since_connect.swap(true, Ordering::Relaxed)
                    {
                        spans::mark("first_daa");
                    }
                    self.emit(event);
                }
            }
        }
    }

    /// Scopes are per-connection node state — re-register on every connect,
    /// on the bind's OWN client (identity: a scope belongs to one socket).
    async fn handle_connect(&self, bind: &Arc<BoundSocket>) -> Result<()> {
        let rpc = bind.client.rpc_api();
        // Item 9 (V2 sitting, doubled Connected): a listener from a prior
        // connect that survived to here would ALSO receive every notification
        // — same channel, doubled stream bandwidth. Since R4 each bind starts
        // with an empty slot, so finding one here means THIS client connected
        // twice with no disconnect between: the pin's ws layer re-dialing a
        // dropped socket with no caller (R2 D2, `link.rs` reproduction test).
        // Stamp it, and let the strike path refuse to convict a node for
        // anything dying in its neighbourhood.
        let prior = bind
            .listener_id
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        if let Some(id) = prior {
            self.inner
                .doubled_connect_at
                .store(Self::now_unix(), Ordering::SeqCst);
            log::warn!(
                "dag-monitor: prior listener survived to a new connect — unregistering (item 9); \
                 strikes are inadmissible for {}s (R2 D3)",
                link::SELF_INFLICTED_ADJACENCY_SECS
            );
            Self::unregister_listener_bounded(&bind.client, id).await;
        }
        let listener_id = rpc.register_new_listener(ChannelConnection::new(
            "kaspaverse-dag-monitor",
            bind.notification_tx.clone(),
            ChannelType::Persistent,
        ));
        *bind
            .listener_id
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(listener_id);
        rpc.start_notify(
            listener_id,
            Scope::VirtualDaaScoreChanged(VirtualDaaScoreChangedScope {}),
        )
        .await?;
        rpc.start_notify(
            listener_id,
            Scope::SinkBlueScoreChanged(SinkBlueScoreChangedScope {}),
        )
        .await?;
        // P2.1: the payload-transport scan source. Joins the SAME listener +
        // channel as the score scopes (D-053 single-listener machinery; §0.3) —
        // re-registered on every connect like the others, paused with the
        // socket (foreground-only posture unchanged).
        rpc.start_notify(listener_id, Scope::BlockAdded(BlockAddedScope {}))
            .await?;
        // V1 acceptance spine (D-073): which txids each chain block accepted,
        // plus removed-chain-block hashes on reorg — same listener, same
        // socket (D-005), re-registered per connect like the rest. The stream
        // is consumed by the event task and forwarded (sparse-filtered by the
        // tracker) — it never crosses to Dart.
        rpc.start_notify(
            listener_id,
            Scope::VirtualChainChanged(VirtualChainChangedScope {
                include_accepted_transaction_ids: true,
            }),
        )
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── D-187: a pinned node is the user's, and nothing may take it away ──

    /// The ruling in one assertion: **a pinned node never silently falls back
    /// to the resolver.** Every mechanism that could substitute a different
    /// node stands down while pinned, and this test fails if any of them is
    /// ever re-enabled — which is the point. A wallet that quietly re-races to
    /// a stranger when the user's node dies is worse than one that has no such
    /// setting, because the setting is then a lie told exactly when it counts.
    #[test]
    fn a_pinned_node_never_falls_back_to_the_resolver() {
        let pinned = DagMonitor::try_new(
            NetworkId::new(NetworkType::Mainnet),
            Some("wss://mine.example/kaspa/mainnet/wrpc/borsh".into()),
        )
        .expect("construct");

        assert!(pinned.is_pinned());
        // No race is ever spawned...
        assert!(!pinned.spawn_race(), "pinned mode must never spawn a race");
        // ...and no race already in flight may bind, either. This is the
        // stronger guarantee: `set_pinned_node` can pin while a round spawned
        // moments earlier is still probing, and that round's winner arm asks
        // exactly this question before installing anything.
        // Both modes, because P0b added one that is ALLOWED to bind over a
        // live socket: the pin must outrank that permission, or "find a
        // different node" becomes the silent fallback D-187 exists to forbid.
        assert!(
            !pinned.may_bind_from_race(&RaceMode::Cold),
            "a race in flight must not bind over the user's node"
        );
        assert!(
            !pinned.may_bind_from_race(&RaceMode::Swap {
                from: "wss://whatever.example/borsh".to_string()
            }),
            "not even a swap hunt may bind over the user's node"
        );

        // The control: an unpinned monitor DOES race, so the assertions above
        // are measuring the pin rather than some unrelated stood-down state.
        let discovering = DagMonitor::mainnet().expect("construct");
        assert!(!discovering.is_pinned());
        assert!(
            discovering.may_bind_from_race(&RaceMode::Cold),
            "control: discovery races"
        );
    }

    /// `None` must reproduce today's behaviour EXACTLY — same resolver path,
    /// same race, same demotion. The pin is opt-in; a user who never opens the
    /// setting must not be able to tell this landed.
    #[tokio::test]
    async fn discovery_mode_is_unchanged_by_the_pin_machinery() {
        let monitor = DagMonitor::mainnet().expect("construct");
        assert_eq!(monitor.pinned_url(), None);
        assert!(monitor.may_bind_from_race(&RaceMode::Cold));
        // The demotion ledger is live (the `!is_pinned()` arm in on_connected).
        assert!(!monitor.is_pinned());
        // And the race is genuinely spawnable — single-flight, so the second
        // ask is refused by the flag rather than by the pin.
        assert!(monitor.spawn_race(), "discovery must spawn its race");
        assert!(!monitor.spawn_race(), "single-flight (D-081), not the pin");
        // Stand the detached hunt down (offline unit test — no node to find).
        monitor.inner.paused.store(true, Ordering::SeqCst);
    }

    /// Pinning is reversible without a restart, and the endpoint cache — the
    /// resolver's *performance* memory — is neither read by the pin nor wiped
    /// by clearing it. Different fields, different lifetimes (node_config docs).
    #[tokio::test]
    async fn a_pin_can_be_set_and_cleared_and_never_touches_the_endpoint_cache() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let dir = std::env::temp_dir().join(format!("kv-pin-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let cache = dir.join("endpoint.cache");
        monitor.set_endpoint_cache(cache.clone());
        monitor.persist_endpoint("wss://remembered.example/kaspa/mainnet/wrpc/borsh");

        monitor
            .set_pinned_node(Some("wss://mine.example/borsh".into()))
            .await
            .expect("pin accepted");
        assert_eq!(
            monitor.pinned_url().as_deref(),
            Some("wss://mine.example/borsh")
        );
        // The pin did not consult the cache, and did not overwrite it.
        assert_eq!(
            monitor.read_cached_endpoint().as_deref(),
            Some("wss://remembered.example/kaspa/mainnet/wrpc/borsh"),
            "pinning must not disturb the resolver's last-good memory"
        );

        monitor.set_pinned_node(None).await.expect("clear accepted");
        assert_eq!(monitor.pinned_url(), None);
        assert!(
            monitor.may_bind_from_race(&RaceMode::Cold),
            "cleared → discovery resumes"
        );
        assert_eq!(
            monitor.read_cached_endpoint().as_deref(),
            Some("wss://remembered.example/kaspa/mainnet/wrpc/borsh"),
            "clearing the pin must not wipe the cache"
        );

        // Stand the link down: the repins above left a real Retry loop
        // dialling an example host (offline unit test — nothing to reach).
        monitor.inner.paused.store(true, Ordering::SeqCst);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A typo costs the user nothing: validation happens before any teardown,
    /// so the link they had is still the link they have.
    #[tokio::test]
    async fn a_rejected_url_leaves_the_live_pin_standing() {
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor
            .set_pinned_node(Some("wss://good.example/borsh".into()))
            .await
            .expect("pin accepted");
        for bad in ["https://good.example", "wss://good.example/ x", ""] {
            assert!(
                monitor.set_pinned_node(Some(bad.into())).await.is_err(),
                "{bad:?} must be refused"
            );
            assert_eq!(
                monitor.pinned_url().as_deref(),
                Some("wss://good.example/borsh"),
                "a refused repin must not disturb the standing pin"
            );
        }
        monitor.inner.paused.store(true, Ordering::SeqCst);
    }

    /// The generation the mid-repin guard rests on actually moves. Without
    /// this, `paused_mid_repin` is a comparison that can never be true and the
    /// guard is decoration.
    #[tokio::test]
    async fn every_pause_bumps_the_generation() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let before = monitor.inner.pause_gen.load(Ordering::SeqCst);
        monitor.pause().await.expect("pause");
        let after = monitor.inner.pause_gen.load(Ordering::SeqCst);
        assert_ne!(before, after, "a pause must be observable across an await");
        // And a repin does NOT bump it — only a real pause does, or the guard
        // would fire on every repin and no pin would ever apply live.
        monitor
            .set_pinned_node(Some("wss://mine.example/borsh".into()))
            .await
            .expect("pin accepted");
        assert_eq!(monitor.inner.pause_gen.load(Ordering::SeqCst), after);
    }

    /// The mirror of the case above: a **resume** landing inside the repin's
    /// teardown window. `pause_gen` cannot see one (resume does not bump it),
    /// which is why the decision reads the live flag after the swap. Asserted
    /// as an invariant rather than an interleaving, so it holds however the
    /// two futures happen to schedule.
    #[tokio::test]
    async fn a_repin_racing_a_resume_converges_on_the_new_node() {
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.pause().await.expect("pause");
        let racing = monitor.clone();
        let (repin, resumed) = tokio::join!(
            monitor.set_pinned_node(Some("wss://new.example/borsh".into())),
            async move { racing.resume().await }
        );
        repin.expect("pin accepted");
        resumed.expect("resume ok");
        // Whatever the order: the pin the caller asked for is the pin the
        // monitor reports — never the pre-repin one — and no race may bind
        // over it. The failure this guards is "connected to the old node
        // while the glass names the new one".
        assert_eq!(
            monitor.pinned_url().as_deref(),
            Some("wss://new.example/borsh")
        );
        assert!(
            !monitor.may_bind_from_race(&RaceMode::Cold),
            "pinned: no race may bind"
        );
        monitor.inner.paused.store(true, Ordering::SeqCst);
    }

    /// A repin while the app is backgrounded must not drag the socket back up
    /// (battery posture) — but it must still take effect, on resume.
    #[tokio::test]
    async fn a_repin_while_paused_stays_paused() {
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.pause().await.expect("pause");
        assert!(monitor.inner.paused.load(Ordering::SeqCst));
        monitor
            .set_pinned_node(Some("wss://mine.example/borsh".into()))
            .await
            .expect("pin accepted");
        assert_eq!(
            monitor.pinned_url().as_deref(),
            Some("wss://mine.example/borsh")
        );
        assert!(
            monitor.inner.paused.load(Ordering::SeqCst),
            "a repin must not resume a backgrounded app"
        );
    }

    #[test]
    fn maps_daa_and_blue_score_notifications() {
        let daa = Notification::VirtualDaaScoreChanged(VirtualDaaScoreChangedNotification {
            virtual_daa_score: 123_456_789_012,
        });
        assert_eq!(
            map_notification(&daa),
            Some(DagEvent::VirtualDaaScore(123_456_789_012))
        );

        let blue = Notification::SinkBlueScoreChanged(SinkBlueScoreChangedNotification {
            sink_blue_score: 98_765_432_109,
        });
        assert_eq!(
            map_notification(&blue),
            Some(DagEvent::SinkBlueScore(98_765_432_109))
        );

        let other = Notification::NewBlockTemplate(NewBlockTemplateNotification {});
        assert_eq!(map_notification(&other), None);
    }

    #[test]
    fn constructs_mainnet_monitor_without_network() {
        let monitor = DagMonitor::mainnet().expect("resolver-based client construction is offline");
        assert!(!monitor.is_connected());
    }

    /// D-084 (V4 sitting live-lock): a parked strike settled by the struck
    /// endpoint's OWN successful reconnect is REFUTED — never committed. A
    /// different prover still commits (the true control-group). Without the
    /// self-refute rule, post-airplane Wi-Fi churn demoted every endpoint via
    /// its own reconnect and the Connected-time refusal stranded connectivity.
    #[test]
    fn own_reconnect_refutes_parked_strike_other_prover_commits() {
        const URL: &str = "wss://emma.example/kaspa/mainnet/wrpc/borsh";
        const OTHER: &str = "wss://lena.example/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        let demoted = |m: &DagMonitor| {
            m.inner
                .health
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .is_demoted(URL, DagMonitor::now_unix())
        };

        // Self-refute, twice over (would demote at 2 commits): stays clean.
        for _ in 0..2 {
            monitor.set_pending_strike(URL.to_string(), link::StrikeReason::Drop);
            monitor.settle_pending_strike(Some(URL));
        }
        assert!(!demoted(&monitor), "own reconnect must refute, not convict");

        // Control group intact: a DIFFERENT prover commits; two commits demote.
        for _ in 0..2 {
            monitor.set_pending_strike(URL.to_string(), link::StrikeReason::Drop);
            monitor.settle_pending_strike(Some(OTHER));
            // Past the same-incident dedup window the ledger counts each
            // commit separately; simulate by backdating the last strike.
            monitor
                .inner
                .health
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .backdate_last_strike(URL, link::STRIKE_DEDUP_SECS + 1);
        }
        assert!(demoted(&monitor), "a different prover still convicts");
    }

    /// **R3 D-099 — the stall verdict is judged against the SOCKET's own
    /// clocks.** The D-098 cascade shape: after a link blackout the Dart
    /// watchdog's process-lifetime block-age reads stale silence against a
    /// seconds-old socket and used to execute it on the next 10 s tick.
    /// PB-026: pre-state assertions are bounds, never equalities.
    #[tokio::test]
    async fn stall_verdict_never_convicts_a_socket_younger_than_the_silence() {
        const URL: &str = "wss://emma.example/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        let now = DagMonitor::now_unix();

        // No socket installed: no defendant — the claim becomes a hunt kick.
        assert_eq!(monitor.stall_verdict(), StallVerdict::Hunting);

        let bind = monitor
            .install_bind(URL.to_string())
            .await
            .expect("a bind arms without dialing");
        // Installed but not up: still no defendant.
        assert_eq!(monitor.stall_verdict(), StallVerdict::Hunting);
        monitor.inner.is_connected.store(true, Ordering::SeqCst);

        // The regression case: blocks last seen 120 s ago (the BLACKOUT'S
        // silence), socket bound 5 s ago (ivy, 2026-07-31 01:00:18) — the
        // old rule executed it; the socket must keep its window. Since R4
        // both clocks are the SOCKET'S own, so a previous socket's silence
        // cannot even be read here.
        bind.last_block_at
            .store(now.saturating_sub(120), Ordering::Relaxed);
        bind.connected_at
            .store(now.saturating_sub(5), Ordering::Relaxed);
        assert!(
            matches!(monitor.stall_verdict(), StallVerdict::Refuse { silent_secs } if silent_secs <= 10),
            "a fresh socket must not inherit the blackout's silence"
        );

        // A true zombie: connected 40+ s and blockless the whole time.
        bind.connected_at
            .store(now.saturating_sub(40), Ordering::Relaxed);
        bind.last_block_at
            .store(now.saturating_sub(40), Ordering::Relaxed);
        assert!(
            matches!(monitor.stall_verdict(), StallVerdict::Execute { silent_secs } if silent_secs >= link::WATCHDOG_STALL_SECS),
            "a socket silent past the threshold on its own clock is executed"
        );

        // Blocks flowing now: healthy regardless of age.
        bind.last_block_at.store(now, Ordering::Relaxed);
        assert!(matches!(
            monitor.stall_verdict(),
            StallVerdict::Refuse { .. }
        ));

        // The process-wide display clock is NOT the judgment clock: a stale
        // process reading must never convict a socket that is delivering.
        monitor
            .inner
            .last_block_at
            .store(now.saturating_sub(600), Ordering::Relaxed);
        assert!(matches!(
            monitor.stall_verdict(),
            StallVerdict::Refuse { .. }
        ));
    }

    /// **R3 D1 — the instrument's call-site seam is itself proven.** D-098's
    /// `last_run_secs` column read 0 in production with a green unit test,
    /// because the store was tested and the CALLER was not (the watchdog
    /// path bypassed the arm that called it). Both death paths now share
    /// [`DagMonitor::record_socket_run`]; this drives it and asserts the
    /// LEDGER changed, and proves a stall parking carries its true reason.
    #[test]
    fn a_socket_death_lands_in_the_ledger_with_its_true_reason() {
        const URL: &str = "wss://emma.example/kaspa/mainnet/wrpc/borsh";
        const PROVER: &str = "wss://lena.example/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");

        monitor.record_socket_run(URL, 27, "watchdog-stall");
        {
            let health = monitor
                .inner
                .health
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            assert_eq!(
                health.last_run_secs(URL),
                Some(27),
                "the run must land in the durable ledger, not only in a log line"
            );
        }

        // A stall execution parks Stall, and the settle commits it as such —
        // the ledger's `why` distinguishes an executed zombie from a drop.
        monitor.set_pending_strike(URL.to_string(), link::StrikeReason::Stall);
        monitor.settle_pending_strike(Some(PROVER));
        let health = monitor
            .inner
            .health
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        assert_eq!(
            health.last_reason(URL),
            Some((link::StrikeReason::Stall, 0)),
            "the committed strike must carry the stall cause, not a flattened drop"
        );
    }

    #[test]
    fn endpoint_cache_round_trips_and_rejects_non_ws() {
        let monitor = DagMonitor::mainnet().expect("construct");
        // Unset path → no fast path, no persist crash.
        assert_eq!(monitor.read_cached_endpoint(), None);
        monitor.persist_endpoint("wss://node.example:17110/kaspa/mainnet/wrpc/borsh");

        let dir = std::env::temp_dir().join(format!("kv-epcache-{}", std::process::id()));
        let path = dir.join("endpoint.cache");
        let _ = std::fs::remove_file(&path);
        monitor.set_endpoint_cache(path.clone());

        // Missing file → None.
        assert_eq!(monitor.read_cached_endpoint(), None);
        // Round-trip.
        monitor.persist_endpoint("wss://node.example:17110/kaspa/mainnet/wrpc/borsh");
        assert_eq!(
            monitor.read_cached_endpoint().as_deref(),
            Some("wss://node.example:17110/kaspa/mainnet/wrpc/borsh")
        );
        // A corrupt/hand-edited file must never redirect the wallet to a
        // non-websocket scheme (it would fail anyway — refuse early).
        std::fs::write(&path, "https://evil.example/steal").unwrap();
        assert_eq!(monitor.read_cached_endpoint(), None);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn transport_cursor_round_trips_and_rejects_garbage() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let dir = std::env::temp_dir().join(format!("kv-tcursor-{}", std::process::id()));
        let path = dir.join("scan.cursor");
        let _ = std::fs::remove_file(&path);

        // No file → None (first run / nothing to recover).
        assert_eq!(DagMonitor::read_transport_cursor(&path), None);
        // Unarmed: persist is a no-op, no crash.
        monitor.write_cursor_now(&Hash::from_bytes([1u8; 32]));
        assert_eq!(DagMonitor::read_transport_cursor(&path), None);

        // Armed: a forced write round-trips as the exact block hash.
        monitor.set_transport_cursor(path.clone());
        let h = Hash::from_bytes([7u8; 32]);
        monitor.write_cursor_now(&h);
        assert_eq!(DagMonitor::read_transport_cursor(&path), Some(h));

        // A corrupt cursor never misdirects the walk — it reads as None (the
        // replay then just seeds from the current sink).
        std::fs::write(&path, "not-a-hash").unwrap();
        assert_eq!(DagMonitor::read_transport_cursor(&path), None);

        let _ = std::fs::remove_file(&path);
    }

    /// **P0b — the tap that cost five minutes.**
    ///
    /// Measured on the founder's Starlink link, 2026-08-28: one tap on a
    /// CONNECTED wallet logged `run ended url=wss://tess.kaspa.red/… run=275s
    /// cause=manual-reconnect`, and 77 race rounds later the link had still
    /// not come back. The sequence was drop-then-hunt; it is now
    /// find-then-swap, and the property that makes that true is this one: the
    /// tap must leave the live bind exactly where it found it.
    ///
    /// Deterministic seam, the same one C4's tests use: the single-flight flag
    /// is held so the tap becomes a kick instead of spawning a loop that would
    /// dial the real network. Either arm is covered by the assertion — the
    /// retirement the fix removed lived in `reconnect` itself, before any race
    /// was asked for.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_tap_on_a_connected_wallet_never_costs_the_link() {
        const URL: &str = "wss://incumbent.example/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        let bind = monitor
            .install_bind(URL.to_string())
            .await
            .expect("arm a bind");
        mark_accepted(&monitor, &bind, 275);
        let gen = bind.gen;

        monitor.reconnect(false).await.expect("tap");

        assert!(
            monitor.is_connected(),
            "the tap must not disconnect a working wallet"
        );
        assert!(
            monitor.is_current_bind(gen),
            "the live bind must survive the tap — it is only replaced by a winner"
        );
        assert_eq!(monitor.current_url().as_deref(), Some(URL));
        // A run in the ledger is the signature of a teardown. There must be
        // none: nothing died, so nothing is recorded as having died.
        assert_eq!(
            last_run(&monitor, URL),
            None,
            "a tap that tore nothing down must record no socket run"
        );

        // The control: the HARD path still tears down, because the gestures
        // that mean it (a confirmed stall, the hard pull-heal) still need a
        // new socket. Without this the assertions above would also pass on a
        // build where reconnect simply stopped working.
        monitor.hard_reconnect().await.expect("hard reconnect");
        assert!(!monitor.is_connected(), "control: the hard path drops it");
        assert!(
            last_run(&monitor, URL).is_some(),
            "control: the hard path records the run it ended"
        );
        monitor.inner.race_running.store(false, Ordering::SeqCst);
    }

    /// P0b, the three round-level laws, proven without a network.
    ///
    /// 1. A swap never dials the node it is replacing — otherwise "find a
    ///    different node" could succeed by re-selecting the same one.
    /// 2. The exclusion outranks the advisory degradation: `demoted` may empty
    ///    out when connectivity beats hygiene, and the incumbent must still
    ///    not be re-admitted by it.
    /// 3. A swap is bounded and a cold hunt is not — and a swap that loses its
    ///    incumbent becomes a cold hunt, so it can never give up on a wallet
    ///    that has gone dark.
    #[test]
    fn a_swap_hunt_excludes_its_incumbent_and_is_bounded() {
        const INCUMBENT: &str = "wss://incumbent.example/borsh";
        const DEMOTED: &str = "wss://demoted.example/borsh";
        let swap = RaceMode::Swap {
            from: INCUMBENT.to_string(),
        };

        let demoted: HashSet<String> = [DEMOTED.to_string()].into_iter().collect();
        let excluded = round_exclusions(demoted.clone(), &swap);
        assert!(
            excluded.contains(INCUMBENT),
            "the incumbent never re-enters"
        );
        assert!(excluded.contains(DEMOTED), "hygiene still applies");
        // The advisory round: hygiene degrades to an empty set, the incumbent
        // does not.
        let advisory = round_exclusions(HashSet::new(), &swap);
        assert_eq!(
            advisory,
            [INCUMBENT.to_string()].into_iter().collect::<HashSet<_>>(),
            "connectivity beating hygiene must never re-admit the incumbent"
        );
        // A cold hunt excludes nothing but what the ledger demoted.
        assert_eq!(round_exclusions(demoted, &RaceMode::Cold).len(), 1);

        // Bounded, but only while it has something to preserve.
        assert!(!swap_hunt_exhausted(&swap, SWAP_HUNT_ROUNDS - 1, true));
        assert!(swap_hunt_exhausted(&swap, SWAP_HUNT_ROUNDS, true));
        assert!(
            !swap_hunt_exhausted(&RaceMode::Cold, SWAP_HUNT_ROUNDS * 100, true),
            "a dark wallet is never given up on"
        );

        // Losing the incumbent turns the errand back into the ordinary hunt —
        // the inversion that would otherwise abandon a dark wallet after
        // three rounds.
        assert_eq!(degrade_lost_swap(swap.clone(), false), RaceMode::Cold);
        assert_eq!(degrade_lost_swap(swap.clone(), true), swap);
        assert_eq!(degrade_lost_swap(RaceMode::Cold, true), RaceMode::Cold);
    }

    /// **`consensus-auditor` CONCERNS-1 — the placement the top-of-loop degrade
    /// cannot see.** `mode` is decided at the head of a round that then takes up
    /// to ~9 s, and the likeliest moment for the incumbent to die is inside the
    /// round the user tapped about. If the exhaustion check reads that stale
    /// `Swap`, the loop returns and clears the single-flight flag on a wallet
    /// that has just gone dark — while `on_disconnected`'s own `spawn_race` has
    /// already been refused, because this loop still held the flag. Recovery
    /// would fall to the 30 s Dart watchdog: ~30–40 s dark, where the
    /// pre-P0b path re-raced within about a second.
    ///
    /// Drives `swap_hunt_exhausted` itself — the predicate the loop calls, not
    /// a copy of it — with the liveness term the loop passes.
    #[test]
    fn an_exhausted_swap_that_lost_its_incumbent_never_gives_up() {
        let swap = RaceMode::Swap {
            from: "wss://incumbent.example/borsh".to_string(),
        };

        // Still connected on the last round: keeping the incumbent is right.
        assert!(
            swap_hunt_exhausted(&swap, SWAP_HUNT_ROUNDS, true),
            "a swap that still has its incumbent stops and keeps it"
        );

        // The incumbent died inside the final round. The budget is spent, but
        // there is nothing left to preserve — so the loop must NOT return.
        assert!(
            !swap_hunt_exhausted(&swap, SWAP_HUNT_ROUNDS, false),
            "a swap whose incumbent died must keep hunting — returning here \
             leaves the wallet dark with no search authority running, because \
             on_disconnected's own spawn_race was already refused by this loop"
        );
        // ...and the next iteration's degrade is what makes that unbounded.
        assert_eq!(degrade_lost_swap(swap, false), RaceMode::Cold);
    }

    /// **`consensus-auditor` CONCERNS-2 — hygiene degrades only for a wallet
    /// that is actually stranded.** The advisory rule exists so two barren
    /// rounds cannot leave a DARK wallet with nothing to dial. A swap wallet is
    /// connected and working, so its precondition is false — and with the bound
    /// at three rounds, an un-scoped rule would fire on the last round of every
    /// single swap, letting a tap trade a healthy incumbent for a node the
    /// ledger had convicted, then set `hygiene_advisory` and suppress the
    /// Connected-time refusal that would have bounced it.
    #[test]
    fn a_swap_round_never_degrades_hygiene() {
        let swap = RaceMode::Swap {
            from: "wss://incumbent.example/borsh".to_string(),
        };
        for rounds in 0..=(SWAP_HUNT_ROUNDS + 2) {
            assert!(
                !hygiene_may_degrade(&swap, rounds),
                "round {rounds} of a swap must keep the demotion ledger in force"
            );
        }
        // The control: a dark wallet still gets the floor it was built for, so
        // this is measuring the mode scoping and not a rule that stopped
        // working in both modes at once.
        assert!(!hygiene_may_degrade(&RaceMode::Cold, 1));
        assert!(hygiene_may_degrade(&RaceMode::Cold, 2));
    }

    /// P0b: the permission to bind over a live socket is granted to the swap
    /// and to nothing else. The cold hunt's refusal is what keeps a ws-level
    /// phantom redial from being bounced by the race that was looking for it.
    #[tokio::test]
    async fn only_a_swap_may_bind_over_a_live_socket() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let swap = RaceMode::Swap {
            from: "wss://incumbent.example/borsh".to_string(),
        };
        assert!(
            monitor.may_bind_from_race(&RaceMode::Cold),
            "dark: cold may"
        );
        assert!(monitor.may_bind_from_race(&swap));

        monitor.inner.is_connected.store(true, Ordering::SeqCst);
        assert!(
            !monitor.may_bind_from_race(&RaceMode::Cold),
            "a cold race must never bind over a live socket"
        );
        assert!(
            monitor.may_bind_from_race(&swap),
            "the swap's whole job is to bind over the live socket"
        );

        // Pause outranks both: the battery posture owns the socket, and
        // dialing behind it is exactly what pausing forbids.
        monitor.inner.paused.store(true, Ordering::SeqCst);
        assert!(!monitor.may_bind_from_race(&swap));
    }

    /// C4 (D-089): a Reconnect while a race already holds the single-flight
    /// flag must KICK the live loop's retry pause — the old path silently
    /// no-opped (the dead-Reconnect symptom's second half). Deterministic
    /// seam: the flag is held manually (a live loop's pause, minus the
    /// loop); the kick must reach a waiter on the Notify. The device flap
    /// sitting is the authoritative end-to-end proof (register C8).
    #[tokio::test(flavor = "multi_thread")]
    async fn reconnect_during_a_live_race_kicks_the_retry_pause() {
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        let inner = monitor.inner.clone();
        let waiter = tokio::spawn(async move { inner.race_kick.notified().await });
        tokio::task::yield_now().await;
        // reconnect() on a never-connected client: the disconnect is a fast
        // no-op; spawn_or_kick sees the held flag and kicks.
        monitor.reconnect(false).await.expect("reconnect");
        tokio::time::timeout(Duration::from_secs(2), waiter)
            .await
            .expect("the kick must reach the race pause — silent no-op regression")
            .expect("waiter task");
        monitor.inner.race_running.store(false, Ordering::SeqCst);
    }

    /// C4 stored-permit note: a kick with no pause armed is NOT lost — the
    /// next `notified()` consumes it immediately (one spurious immediate
    /// round, the accepted trade in the register).
    #[tokio::test(flavor = "multi_thread")]
    async fn an_unconsumed_kick_is_stored_not_lost() {
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        monitor.reconnect(false).await.expect("reconnect");
        tokio::time::timeout(Duration::from_secs(2), monitor.inner.race_kick.notified())
            .await
            .expect("the stored permit must satisfy the next pause");
        monitor.inner.race_running.store(false, Ordering::SeqCst);
    }

    /// C7 (D-089 ruling 6 / D-091 ruling 1): the two bits the honest-states
    /// glass reads. `os_offline` must be OS-driven only — false until a real
    /// `onLost`, cleared by `onAvailable` — and recording it must not disturb
    /// ruling 4's passivity (a lost signal still dials nothing). `is_searching`
    /// must track the single-flight race flag, which is what makes a
    /// multi-round weak-link hunt render as ONE continuous *finding a node…*.
    #[tokio::test(flavor = "multi_thread")]
    async fn the_glass_reads_os_offline_and_searching_honestly() {
        let monitor = DagMonitor::mainnet().expect("construct");

        // Unknown ≠ offline: a launch that never saw a callback must not
        // accuse the phone (the callback speaks only on transitions).
        assert!(!monitor.os_offline(), "never offline before the OS says so");
        assert!(!monitor.is_searching());

        monitor.network_changed(false).await;
        assert!(monitor.os_offline(), "onLost must be visible to the glass");
        // Ruling 4 holds: lost is passive — nothing was dialed, so the
        // single-flight race flag is untouched.
        assert!(!monitor.is_searching(), "network_lost must not dial");

        monitor.network_changed(true).await;
        assert!(!monitor.os_offline(), "onAvailable clears the accusation");
        // available && !connected DOES race (C5) — that flag is now the
        // searching truth the beacon renders.
        assert!(monitor.is_searching(), "available while dark starts a hunt");

        // Stand the detached hunt down (offline unit test — it has no node to
        // find and we never await it).
        monitor.inner.paused.store(true, Ordering::SeqCst);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn pause_before_any_connect_is_a_safe_noop() {
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor
            .pause()
            .await
            .expect("disconnect on a never-connected client is Ok");
        assert!(!monitor.is_connected());
        // resume() with no cache + no network initiates the resolver path
        // non-blocking; constructing the future must not panic. We don't await
        // a connection here (offline unit test) — resume itself must be Ok.
        monitor
            .resume()
            .await
            .expect("resume initiates non-blocking connect");
    }

    // ── R4 · per-bind identity (D-101) ────────────────────────────────────

    /// Poll a predicate to a bound. Waiting is unavoidable here — the bind's
    /// task services its channels on its own — but the WAIT is bounded and
    /// the assertion is the predicate, never a sleep-and-hope.
    async fn wait_for(label: &str, mut pred: impl FnMut() -> bool) {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while !pred() {
            assert!(
                tokio::time::Instant::now() < deadline,
                "timed out waiting for {label}"
            );
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }

    /// Put a bind in the state an ACCEPTED `Connected` leaves it in, without
    /// going through `on_connected` — so a test can stage the post-window
    /// state deterministically instead of racing for it (L69/PB-026). Mirrors
    /// `on_connected`'s Ok arm in order: the socket's own stamp, the stable
    /// handle, then the published link state.
    fn mark_accepted(monitor: &DagMonitor, bind: &Arc<BoundSocket>, age_secs: u64) {
        bind.connected_at.store(
            DagMonitor::now_unix().saturating_sub(age_secs),
            Ordering::Relaxed,
        );
        monitor.inner.link_rpc.bind(bind.client.clone());
        monitor.inner.is_connected.store(true, Ordering::SeqCst);
    }

    fn last_run(monitor: &DagMonitor, url: &str) -> Option<u64> {
        monitor
            .inner
            .health
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .last_run_secs(url)
    }

    /// **R4 D3 — the live-lock's regression test.**
    ///
    /// The D-100 soak signature: a fresh bind reports `run ended run=0s
    /// cause=ctl-drop` 1–5 ms after `connected`, because the PREVIOUS socket's
    /// teardown event arrived after the new bind and was attributed to it —
    /// 85 times in 18 minutes, self-sustaining until the app was killed. R3's
    /// churn floor made those deaths unconvictable (zero strikes) and the app
    /// still live-locked: leniency does not fix attribution (L71).
    ///
    /// This drives the LOOP, not one event: three generations, each retired
    /// for real and each followed by its own late teardown event. The property
    /// under test is that the socket which is alive stays alive and carries no
    /// death on its record.
    #[tokio::test]
    async fn a_retired_sockets_teardown_never_kills_the_bind_that_replaced_it() {
        const URLS: [&str; 3] = [
            "wss://vivi.example/kaspa/mainnet/wrpc/borsh",
            "wss://eva.example/kaspa/mainnet/wrpc/borsh",
            "wss://isla.example/kaspa/mainnet/wrpc/borsh",
        ];
        let monitor = DagMonitor::mainnet().expect("construct");

        let mut retired: Vec<Arc<BoundSocket>> = Vec::new();
        for (round, url) in URLS.iter().enumerate() {
            let bind = monitor
                .install_bind((*url).to_string())
                .await
                .expect("arm a bind");
            mark_accepted(&monitor, &bind, 30);

            // Every previously retired socket now shouts its death — the
            // aliasing the soak recorded, several times over, arriving while
            // a healthy socket is bound.
            for dead in &retired {
                for _ in 0..2 {
                    let _ = dead.client.rpc_ctl().signal_close().await;
                }
                wait_for("the retired bind to discard its late teardown", || {
                    dead.stale_ctl.load(Ordering::Relaxed) >= 1
                })
                .await;

                // The living socket is untouched: still connected, still the
                // installed identity, and no race was started on its behalf.
                assert!(
                    monitor.is_connected(),
                    "round {round}: a retired socket's teardown must not take the live link down"
                );
                assert_eq!(
                    monitor.current_bind().map(|b| b.gen),
                    Some(bind.gen),
                    "round {round}: the installed identity must not change"
                );
                assert!(
                    !monitor.is_searching(),
                    "round {round}: a stale event must not start a hunt"
                );
                assert_eq!(
                    last_run(&monitor, url),
                    None,
                    "round {round}: the LIVE socket must carry no death on its record — \
                     this is the `run=0s cause=ctl-drop` the soak saw 85 times"
                );
            }

            // Retire it for real, then let the next generation take over.
            monitor.retire_bind("ctl-drop").await;
            assert!(
                last_run(&monitor, url).is_some(),
                "round {round}: a REAL death is still recorded"
            );
            retired.push(bind);
        }

        // The last generation retired with nothing installed behind it: its
        // late teardown must be refused just the same, and must not resurrect
        // a link that is legitimately down.
        let last = retired.last().expect("three generations ran");
        let _ = last.client.rpc_ctl().signal_close().await;
        wait_for("the final retired bind to discard its teardown", || {
            last.stale_ctl.load(Ordering::Relaxed) >= 1
        })
        .await;
        assert!(!monitor.is_connected(), "nothing is bound; nothing is up");
        assert!(monitor.current_bind().is_none());

        // Every socket's late teardown was SEEN and refused, not silently
        // lost (bounds, not equalities — the pin's own timing decides how many
        // events a dying socket emits; L69/PB-026).
        for (dead, url) in retired.iter().zip(URLS.iter()) {
            assert!(
                dead.stale_ctl.load(Ordering::Relaxed) >= 1,
                "{url}: its late teardown was seen and refused, not silently lost"
            );
        }
    }

    /// **R4 D4 — a retired socket cannot deafen or excuse the live one.**
    ///
    /// The soak convicted two sockets of a 39–40 s stall while race dials to
    /// the same hosts were succeeding in under a second (vivi 13:32, eva
    /// 13:32:43). The mechanism the shared client allowed: one process-wide
    /// `listener_id` and one notification channel, so a retired socket's
    /// teardown could unregister the LIVE socket's listener and leave it
    /// connected but deaf — genuinely silent, and convicted by a rule that was
    /// working correctly on false evidence.
    ///
    /// Both halves are now per-bind, and this proves it from the outside:
    /// the retired socket's stream reaches nothing, and the live socket's
    /// subscription is untouched by its predecessor's death.
    #[tokio::test]
    async fn a_retired_sockets_notifications_reach_nothing_and_its_death_deafens_nobody() {
        const DEAD: &str = "wss://vivi.example/kaspa/mainnet/wrpc/borsh";
        const LIVE: &str = "wss://eva.example/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        let mut events = monitor.subscribe();

        let dead = monitor
            .install_bind(DEAD.to_string())
            .await
            .expect("arm the first bind");
        mark_accepted(&monitor, &dead, 30);
        monitor.retire_bind("ctl-drop").await;

        let live = monitor
            .install_bind(LIVE.to_string())
            .await
            .expect("arm the second bind");
        mark_accepted(&monitor, &live, 0);
        // The live socket's subscription, as `handle_connect` would leave it.
        *live
            .listener_id
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(42);
        let live_block_clock = live.last_block_at.load(Ordering::Relaxed);

        // The dead socket keeps talking: a late teardown AND a late block.
        let _ = dead.client.rpc_ctl().signal_close().await;
        let _ = dead
            .notification_tx
            .send(Notification::VirtualDaaScoreChanged(
                VirtualDaaScoreChangedNotification {
                    virtual_daa_score: 500_808_467,
                },
            ))
            .await;
        wait_for("the retired bind to discard its late notification", || {
            dead.stale_notifications.load(Ordering::Relaxed) >= 1
        })
        .await;

        // Nothing of it reached the app.
        assert!(
            tokio::time::timeout(Duration::from_millis(100), events.recv())
                .await
                .is_err(),
            "a retired socket's notification must not surface as a chain event"
        );
        // Nothing of it reached the live socket, either.
        assert_eq!(
            *live
                .listener_id
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
            Some(42),
            "the live socket's subscription must survive its predecessor's death — \
             the deafness that produced the soak's 39-40 s stall convictions"
        );
        assert_eq!(
            live.last_block_at.load(Ordering::Relaxed),
            live_block_clock,
            "a dead socket's block must not refresh the live socket's evidence clock"
        );
        assert!(monitor.is_connected(), "the live link is still up");
    }

    /// **R4 D2 — every teardown path records, and recording is not judging.**
    ///
    /// D-098 read a column of zeros because the watchdog kill path never
    /// called the writer; the D-100 soak then found a second silent path (the
    /// 13:57 pause-path teardown left no lifecycle line at all, and the 14:06
    /// resume raced against a run nobody had measured). Retirement is now the
    /// only exit, so each of these paths writes the run — and a deliberate
    /// teardown still convicts nobody.
    #[tokio::test]
    async fn every_teardown_path_records_its_run() {
        const RUN: u64 = 42;

        for (case, url) in [
            ("paused", "wss://a.example/kaspa/mainnet/wrpc/borsh"),
            ("stopped", "wss://b.example/kaspa/mainnet/wrpc/borsh"),
            (
                "manual-reconnect",
                "wss://c.example/kaspa/mainnet/wrpc/borsh",
            ),
            ("superseded", "wss://d.example/kaspa/mainnet/wrpc/borsh"),
        ] {
            let monitor = DagMonitor::mainnet().expect("construct");
            // Hold the single-flight flag so a recovery path kicks instead of
            // spawning a race that would dial the real network.
            monitor.inner.race_running.store(true, Ordering::SeqCst);
            let bind = monitor
                .install_bind(url.to_string())
                .await
                .expect("arm a bind");
            mark_accepted(&monitor, &bind, RUN);

            match case {
                "paused" => monitor.pause().await.expect("pause"),
                "stopped" => monitor.stop().await.expect("stop"),
                // The HARD path is where the manual teardown lives since P0b:
                // the user's tap no longer retires a live bind, so asking
                // `reconnect` for a teardown here would be asking it for the
                // behaviour the fix removed.
                "manual-reconnect" => monitor.hard_reconnect().await.expect("hard reconnect"),
                // Installing over a live bind must not leak it.
                _ => {
                    monitor
                        .install_bind("wss://next.example/kaspa/mainnet/wrpc/borsh".to_string())
                        .await
                        .expect("arm the successor");
                }
            }

            let recorded = last_run(&monitor, url)
                .unwrap_or_else(|| panic!("{case}: the run must reach the durable ledger"));
            assert!(
                recorded >= RUN,
                "{case}: the recorded run ({recorded}s) must cover the socket's life"
            );
            // Recording is not judging: a deliberate teardown parks no strike,
            // commits none, and hands out no clean-run credit either. (The
            // ledger row exists — `record_run` created it — but it carries no
            // conviction: `Unknown` is the reason of a row nobody was charged
            // on.)
            {
                let health = monitor
                    .inner
                    .health
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                assert!(
                    !health.is_demoted(url, DagMonitor::now_unix()),
                    "{case}: a deliberate teardown must not demote the endpoint"
                );
                assert!(
                    matches!(
                        health.last_reason(url),
                        None | Some((link::StrikeReason::Unknown, 0))
                    ),
                    "{case}: a deliberate teardown convicts nobody, got {:?}",
                    health.last_reason(url)
                );
            }
            assert!(
                monitor
                    .inner
                    .pending_strike
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .is_none(),
                "{case}: a deliberate teardown parks no strike either"
            );
            assert!(!monitor.is_connected(), "{case}: the link is down");
            assert!(
                monitor.current_bind().is_none() || case == "superseded",
                "{case}: no bind is left installed"
            );
        }
    }

    /// **R4 — a bind retired while it was coming up must not publish.**
    ///
    /// The wallet-security BLOCK: the identity gate runs at event INTAKE, but
    /// `on_connected` then runs the (LOCAL — not four round-trips; see the
    /// arm's own note) subscribe leg before it
    /// publishes. A `pause()` / `reconnect()` / demoted-refusal landing inside
    /// that window used to be overwritten by the publish, leaving
    /// `is_connected = true` with NO bind installed — a state nothing could
    /// clear, because every recovery path short-circuits on `is_connected()`
    /// and the socket's own death notice is (correctly) discarded as stale.
    /// A dark wallet reading "Connected" until the app is killed: the D-100
    /// outage class walking back in through the door built to close it.
    #[tokio::test]
    async fn a_bind_retired_while_coming_up_never_publishes_itself() {
        const URL: &str = "wss://vivi.example/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind(URL.to_string())
            .await
            .expect("arm a bind");

        // The retirement lands while the socket is still coming up — before it
        // ever published (`announced` is false, so consumers were never told).
        monitor.retire_bind("paused").await;

        // The publish now runs on a bind nobody is waiting for any more.
        monitor.on_connected(&bind).await;

        assert!(
            !monitor.is_connected(),
            "a retired bind must not raise the link — this is the unrecoverable \
             connected-with-nothing-bound state"
        );
        assert!(
            monitor.current_bind().is_none(),
            "and it must not reinstall itself"
        );
        assert!(
            !bind.announced.load(Ordering::SeqCst),
            "consumers are never told a retired socket came up"
        );
        // The link is recoverable: a fresh bind can take over cleanly.
        let next = monitor
            .install_bind("wss://eva.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm the successor");
        assert!(monitor.is_current_bind(next.gen));
    }

    /// **R4 D1 — the consumers' handle is the thing that does NOT move.**
    ///
    /// The client rotates once per reconnect; `WalletEngine`'s `UtxoProcessor`
    /// consumes its `Rpc` at construction and the acceptance tracker moves one
    /// into its task, so if THAT changed we would be re-plumbing every
    /// funds-visibility lane L59 scarred us on. It does not: both halves of
    /// `rpc()` are monitor-owned and outlive every bind.
    #[tokio::test]
    async fn the_handle_consumers_bind_at_construction_outlives_every_socket() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let held = monitor.rpc();

        let bind = monitor
            .install_bind("wss://a.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        mark_accepted(&monitor, &bind, 5);
        monitor.retire_bind("ctl-drop").await;
        let next = monitor
            .install_bind("wss://b.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm the successor");
        mark_accepted(&monitor, &next, 0);

        let after = monitor.rpc();
        assert!(
            Arc::ptr_eq(held.rpc_api(), after.rpc_api()),
            "the rpc handle must be the same object across a rebind"
        );
        // The ctl a consumer watches is the monitor's own, and it is still the
        // one being driven — so a processor bound before the first socket
        // existed still hears every accepted connect.
        assert!(
            Arc::ptr_eq(
                &monitor.rpc().rpc_ctl().multiplexer().channels,
                &held.rpc_ctl().multiplexer().channels
            ),
            "the ctl a consumer watches must be the same object across a rebind"
        );
    }

    /// A watchdog execution still records its run and still parks its strike —
    /// R3's ruling 1 machinery is untouched by R4's re-plumb.
    #[tokio::test]
    async fn a_watchdog_execution_still_records_and_parks_its_strike() {
        const URL: &str = "wss://vivi.example/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        let bind = monitor
            .install_bind(URL.to_string())
            .await
            .expect("arm a bind");
        mark_accepted(&monitor, &bind, 60);
        // Silent its whole life: a true zombie on its OWN clock.
        bind.last_block_at.store(0, Ordering::Relaxed);

        monitor.reconnect(true).await.expect("stalled reconnect");

        assert!(
            last_run(&monitor, URL).is_some_and(|run| run >= 60),
            "the executed socket's run reaches the ledger (D-098's column of zeros)"
        );
        let parked = monitor
            .inner
            .pending_strike
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        assert!(
            matches!(parked, Some((ref u, _, link::StrikeReason::Stall)) if u == URL),
            "the execution parks a Stall against the socket it judged, got {parked:?}"
        );
    }

    /// Live smoke test against mainnet via the PNN resolver — run manually:
    /// `cargo test -p kaspaverse-chain -- --ignored --nocapture`
    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "requires network; manual proof for P0.3"]
    async fn live_mainnet_daa_stream() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let mut events = monitor.subscribe();
        monitor.start().await.expect("start");
        let deadline = std::time::Duration::from_secs(60);
        let mut got_daa = None;
        let mut got_blue = None;
        let started = std::time::Instant::now();
        while (got_daa.is_none() || got_blue.is_none()) && started.elapsed() < deadline {
            match tokio::time::timeout(deadline, events.recv()).await {
                Ok(Ok(DagEvent::VirtualDaaScore(v))) => got_daa = Some(v),
                Ok(Ok(DagEvent::SinkBlueScore(v))) => got_blue = Some(v),
                Ok(Ok(event)) => println!("event: {event:?}"),
                Ok(Err(_)) | Err(_) => break,
            }
        }
        monitor.stop().await.expect("stop");
        println!("daa={got_daa:?} blue={got_blue:?}");
        assert!(got_daa.is_some(), "no VirtualDaaScore within {deadline:?}");
        assert!(got_blue.is_some(), "no SinkBlueScore within {deadline:?}");
    }

    /// **P0b end to end, against real nodes** — run manually:
    /// `cargo test -p kaspaverse-chain find_then_swap -- --ignored --nocapture`
    ///
    /// The unit tests above prove the laws in isolation with the single-flight
    /// flag held, which is deterministic but means no real race ever runs. This
    /// one drives the actual gesture on a real link: connect, note the socket,
    /// tap, and watch. The properties it can prove that the seams cannot:
    ///
    /// 1. The link is down for **at most one bounded cut-over window**, and is
    ///    back up before the deadline. Polled continuously, not sampled at the
    ///    ends, because a drop-and-recover inside one sleep is exactly the old
    ///    defect and would pass a two-point check.
    /// 2. Whatever the wallet ends up on, it is a **different node**, or the
    ///    same one because the hunt found nothing better and kept it — never a
    ///    four-minute outage.
    ///
    /// **Property 1 says "bounded", not "never", and the distinction is the
    /// honest one** (`consensus-auditor`, CONCERNS-3). A swap that *wins* does
    /// briefly drop: `install_bind` retires the incumbent before it dials the
    /// winner, so the cut-over costs the DIAL plus the subscribe leg that runs
    /// before `is_connected` publishes — see `cutover_budget` below, which is
    /// the authority. It no longer costs `DISCONNECT_WAIT_TIMEOUT`: D-215 took
    /// the retiring socket's goodbye off this path. As first written this test
    /// asserted the link was
    /// never down at all, which meant it could only pass on the *found nothing*
    /// outcome — it could not bless the outcome it exists to bless, and whoever
    /// ran it first would have read a winning swap as the fix being broken. The
    /// claim the fix actually makes is that a tap costs a bounded cut-over paid
    /// only against a node that has already answered a probe, instead of an
    /// unbounded hunt paid up front.
    ///
    /// The on-device proof is the founder's tap; this is what the gate can
    /// re-run. The gesture is engine-side and has no Android-specific
    /// behaviour, so the device adds a witness rather than a different subject.
    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "requires network; manual proof for P0b (find-then-swap)"]
    async fn live_find_then_swap_never_drops_the_link() {
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.start().await.expect("start");
        // Deliberately generous, and the reason is the P0 in the next row of
        // the same tracker: on a link whose IPv6 blackholes, the FIRST connect
        // is the 4 m 34 s one. This test is about the tap, not the dial — so
        // it waits out the dial rather than pretending the dial is fast.
        let connect_deadline = std::time::Instant::now() + Duration::from_secs(360);
        while !monitor.is_connected() {
            assert!(
                std::time::Instant::now() < connect_deadline,
                "no first connection in 6 min — this test needs a link that comes up; \
                 on a broken-IPv6 link that is the P0, not this"
            );
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        let before = monitor.current_url().expect("a bound socket");
        println!("connected to {before}");

        // The tap.
        monitor.reconnect(false).await.expect("tap");

        // Property 1: at most ONE contiguous down-window, bounded by the
        // cut-over budget. Polled every 20 ms — a two-point check would sleep
        // straight through the outage this test exists to detect.
        // What `install_bind` spends with the socket dark. D-215 took the
        // retiring socket's goodbye off this path — the retirement is
        // synchronous and the unregister (2 s) and disconnect wait (5 s) are
        // detached — but it is NOT "the dial and nothing else", and saying so
        // would be this sitting's own L134 in the file that earned it:
        //
        // - the DIAL, bounded by `BIND_ENVELOPE_TIMEOUT`; and
        // - the SUBSCRIBE leg, which is not bounded at our boundary at all:
        //   `is_connected` is published only after `handle_connect` returns,
        //   and that is `register_new_listener` plus four SEQUENTIAL
        //   `start_notify` round-trips. D-214 defers exactly this leg; the
        //   allowance collapses to ~0 when it lands as a `try_join!` inside a
        //   timeout. The old 17 s budget hid it inside the teardown's slack.
        const SUBSCRIBE_ALLOWANCE: Duration = Duration::from_secs(4);
        // And a WINNER THAT DIES BETWEEN PROBE AND BIND retires and re-races
        // with no retry pause (that arm has none — the pause lives only in the
        // empty-round branch), so one CONTIGUOUS dark window can legitimately
        // carry a whole extra round before the next dial even starts. That path
        // is correct, has its own no-strike rule, and a budget excluding it
        // convicts a healthy build — the exact defect this deadline was widened
        // for earlier in this same sitting.
        let cutover_budget = BIND_ENVELOPE_TIMEOUT
            + SUBSCRIBE_ALLOWANCE
            + link::RESOLVER_FETCH_TIMEOUT
            + PROBE_TIMEOUT;
        // The window must cover the WORST correct run, or the assertion below
        // that the wallet is bound when it expires convicts a healthy build:
        // the hunt can spend its whole budget AND then win on the last round,
        // and that winner's cut-over is `cutover_budget` on its own.
        //
        // A round is the RESOLVER fetch plus the probe — `link::race` awaits
        // `bounded_get_node(.., RESOLVER_FETCH_TIMEOUT)` before it probes
        // anything — and `RACE_RETRY_DELAY` is the pause BETWEEN rounds, not a
        // part of one. The first model spent the retry delay in place of the
        // resolver leg (7 s where the code's ceiling is 9 s) and bought the
        // shortfall back with a phantom `+ 1` round; both are dropped here for
        // the constants the code actually waits on.
        let round = link::RESOLVER_FETCH_TIMEOUT + PROBE_TIMEOUT;
        let deadline = std::time::Instant::now()
            + (round + RACE_RETRY_DELAY) * SWAP_HUNT_ROUNDS
            + cutover_budget;
        let mut saw_searching = false;
        let mut polls = 0u32;
        let mut down_windows = 0u32;
        let mut down_since: Option<std::time::Instant> = None;
        let mut worst_down = Duration::ZERO;
        while std::time::Instant::now() < deadline {
            match (monitor.is_connected(), down_since) {
                (false, None) => {
                    down_windows += 1;
                    down_since = Some(std::time::Instant::now());
                }
                (false, Some(since)) => {
                    let down = since.elapsed();
                    worst_down = worst_down.max(down);
                    assert!(
                        down < cutover_budget,
                        "the link has been down {down:?}, past the {cutover_budget:?} \
                         cut-over budget — a swap must never become an open-ended outage, \
                         which is the P0b defect. Before reading this as a regression, \
                         check the log: a `bind failed` or `exceeded BIND_ENVELOPE_TIMEOUT` \
                         line means the winner died between probe and bind and re-raced \
                         dark, which is a legitimate over-run of this budget"
                    );
                }
                (true, Some(since)) => {
                    worst_down = worst_down.max(since.elapsed());
                    down_since = None;
                }
                (true, None) => {}
            }
            saw_searching |= monitor.is_searching();
            polls += 1;
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(
            monitor.is_connected(),
            "the wallet must be bound when the swap budget expires — either the \
             replacement or the incumbent it was told to keep"
        );
        assert!(
            down_windows <= 1,
            "a swap is ONE cut-over at most; {down_windows} down-windows means the \
             hunt is bouncing the socket, not swapping it"
        );

        let after = monitor.current_url().expect("still bound");
        println!(
            "after the tap: {after} (searching seen: {saw_searching}, {polls} polls, \
             {down_windows} cut-over(s), worst down {worst_down:?})"
        );
        // Property 2: a swap landed somewhere else, or nothing better answered
        // and the incumbent was kept. Both are correct; an open-ended outage is
        // not, and property 1 already ruled that out.
        if after == before {
            println!("kept the incumbent — nothing better answered inside the bound");
        } else {
            println!("swapped {before} -> {after}");
        }
        assert!(
            saw_searching,
            "the tap must actually hunt — a swap that never searched is a no-op \
             wearing the fix's name"
        );
        monitor.stop().await.expect("stop");
    }
}
