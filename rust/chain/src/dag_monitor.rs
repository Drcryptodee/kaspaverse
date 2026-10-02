//! Connection lifecycle + notification subscription for the hello-DAG stream.
//!
//! Derived from the pinned rev's `rpc/wrpc/examples/subscriber` example
//! (originally at `90dbf074`; pin since bumped to `cfafeb4c` v2.0.1 — D-058,
//! then to `01b532e` v2.1.0 — D-324; INV-9). Key protocol fact from that source:
//! notification scopes live on the node for the lifetime of one RPC
//! connection — they are lost on disconnect, so every `RpcState::Connected`
//! event must re-register the listener and its scopes.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use kaspa_addresses::Prefix;
use kaspa_consensus_core::Hash;
use kaspa_wallet_core::rpc::{Rpc, RpcCtl};
use kaspa_wrpc_client::prelude::*;
use tokio::sync::{broadcast, oneshot};

use crate::acceptance::{TrackerFeed, VccBatch};
use crate::devab;
use crate::error::Result;
use crate::link::{self, EndpointHealth};
use crate::link_rpc::LinkRpc;
use crate::spans;
use crate::transport::{self, TransportEvent};
use crate::walk::{self, MessageSink, TransportMatcher, Walk};

/// Per-candidate probe budget in the connect race (dial + `get_server_info`).
/// Bounded like the old cached fast path (3 s) plus one health round-trip.
/// **Public, because `T5`'s `Test` runs the same probe on a node the user
/// typed** — one budget, so a node the test accepts is a node the race would
/// accept, by construction rather than by two literals agreeing
/// (`consensus-auditor`, UX-R3 second beat).
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(4);

// **The deadline on one `probe_link` round trip is no longer a constant**
// (LINK-Q1, D-333). It was a fixed 1.8 s, and on the founder's Starlink hop an
// ordinary answer past it blanked the reading — a slow, live link drawn as no
// link. Each bound socket now carries its own RFC 6298 clock
// (`link::ProbeClock`: SRTT + 4·RTTVAR, floored 1 s, capped 5 s, doubled on a
// timeout), and a timeout is reported as "at least the deadline" rather than
// as nothing. Still deliberately NOT [`PROBE_TIMEOUT`], the connect race's
// per-round budget: two different errands, two names (BG-21 one layer down).

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

/// How many parked strikes may wait for their `Connected` at once (LINK-Q4).
/// One per endpoint: a stretch between two connects parks the dead socket's
/// strike and one per winner whose bind failed after it, and a winner that
/// fails again replaces its own entry. Eight is past any stretch the captures
/// show (LINK-Q1's worst: one death, one bind failure). Past it the oldest —
/// the one [`link::PENDING_STRIKE_TTL_SECS`] is nearest to expiring anyway —
/// is dropped unjudged and logged, which errs toward acquittal, never toward
/// a strike.
const PENDING_STRIKES_CAP: usize = 8;

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

/// Tests: what a race round was asked for ([`DagMonitor::run_race`]).
#[cfg(test)]
#[derive(Debug, Clone)]
struct RoundAsked {
    pantry: Vec<String>,
    excluded: HashSet<String>,
    prefer: std::collections::HashMap<String, u64>,
}

/// Tests: a scripted race round ([`DagMonitor::run_race`]).
#[cfg(test)]
type RaceScript = Box<dyn Fn(&RoundAsked) -> link::RaceOutcome + Send + Sync>;

/// How often a held winner re-reads its incumbent while it waits for the swap
/// (LINK-Q4). The swap stage and a tap wake it at once through the race kick;
/// this poll is for the incumbent speaking again, which nothing signals, and
/// for a socket that died (its `Disconnected` retires it synchronously). A
/// quarter second is the silence clock's resolution that matters: the stand-
/// down races the swap by at most that much.
const HOLD_POLL: Duration = Duration::from_millis(250);

/// What became of a winner the pre-dial held (LINK-Q4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Held {
    /// Let it in now.
    Install,
    /// The incumbent spoke again: keep it, end the hunt.
    StandDown,
    /// Held past the pre-dial's lead and one deadline: its probe is stale, so
    /// the hunt probes again.
    Stale,
}

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
    /// A live bind is up and a different node is wanted. Bounded by
    /// [`SWAP_HUNT_ROUNDS`]; `from` is the incumbent, excluded from every
    /// round's candidate set; `why` says who wanted it, which decides one
    /// thing only — whether the incumbent speaking again ends the hunt.
    Swap { from: String, why: SwapWhy },
}

/// The cause a silence swap's winner retires its incumbent under — the one
/// token the race's winner arm chooses ([`DagMonitor::retire_cause`]), the
/// silence budget counts on, and the soak judge reads (`consensus-auditor`
/// delta CONCERNS-A′: a budget keyed on a log label matching by hand).
const SILENCE_SWAP: &str = "silence-swap";

/// The cause a moved-network hunt's winner retires its incumbent under
/// (LINK-Q4): recorded, not judged — the phone moved, the node did not fail.
const NETWORK_SWAP: &str = "network-swap";

/// Why a swap hunt runs — and so whether its incumbent can call it off.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SwapWhy {
    /// The user tapped for a different node. The incumbent speaking changes
    /// nothing: they asked to leave it, not to wait for it.
    Asked,
    /// The incumbent went quiet past its silence deadline (LINK-Q1). `gen`
    /// names that socket and `ticks` is its tick count when the hunt began, so
    /// the hunt stands down if it comes back
    /// ([`link::silent_incumbent_spoke_again`]) — the founder's "keep the
    /// incumbent if it speaks again, swap if a new node answers". `asked` is
    /// the monitor's tap count when it began: a tap that lands DURING the hunt
    /// makes it the user's, and the user's hunt is never called off by the
    /// node they asked to leave (`consensus-auditor` CONCERNS-2).
    Silent { gen: u64, ticks: u64, asked: u64 },
    /// The phone's default network moved under the incumbent (LINK-Q4, D-337
    /// (ii): "swap … at once when the old network is gone"). `gen` names that
    /// socket. Its winner comes in at once, and the incumbent speaking does not
    /// call it off: its ticks are on a network the phone has left, which
    /// Android tears down (or, for a cellular socket after Wi-Fi returns,
    /// keeps billing) on its own schedule. `asked` is the tap count when it
    /// began; `tapped` says the user asked to LEAVE the incumbent's node — the
    /// hunt was the user's swap before the move, or a tap has landed since —
    /// and only then is that node kept out of the race (`wallet-security-
    /// auditor`, round 2: a move alone leaves a network, not a node).
    Moved { gen: u64, asked: u64, tapped: bool },
}

/// **Did this retirement judge the LINK, or was it our own hand?** (LINK-Q4,
/// D-344's L249 routed here.) The message walk counts a page that died with
/// its socket toward the three failed runs that end in a skip, and a new
/// socket never forgives it — because a page too large for the link silences
/// the heartbeat, the silence swap kills the page, and every new socket would
/// otherwise ask again forever. That argument holds only for the causes the
/// link's own trouble brings: the silence swap, the watchdog's execution, the
/// socket's own death. A pause, a repin, a stop, the user's tap (a swap they
/// asked for, or a hard reconnect), a lane rebind or a bind that never came up
/// say nothing about whether the page can be carried — and in the field a
/// tap's `superseded` was counted (2026-09-29 00:01:04, the dev install's
/// catch-up; L249's field line).
fn retirement_judges_the_link(cause: &str) -> bool {
    matches!(cause, SILENCE_SWAP | "watchdog-stall" | "ctl-drop")
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
///
/// **A moved-network hunt excludes nothing of its own** (LINK-Q4,
/// `consensus-auditor` round 1): it leaves a NETWORK, not a node, and the node
/// it was on may be the best one on the new network too — unless the user
/// asked to leave that node, which a move does not undo (`wallet-security-
/// auditor`, round 2; L127, the tap always acts).
fn round_exclusions(demoted: HashSet<String>, mode: &RaceMode) -> HashSet<String> {
    let mut excluded = demoted;
    if let RaceMode::Swap { from, why } = mode {
        if !matches!(why, SwapWhy::Moved { tapped: false, .. }) {
            excluded.insert(from.clone());
        }
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
///
/// `joined`: a tap has joined a silence hunt the loop head has not re-cast
/// yet (`consensus-auditor` delta CONCERNS-B). Landing inside the final round,
/// it used to be spent with the silence's budget — no round of its own, and
/// logged as silence's (L127). Not exhausted, the loop falls to its pause, the
/// tap's stored kick skips it, and the head re-casts the hunt as the user's.
fn swap_hunt_exhausted(
    mode: &RaceMode,
    empty_rounds: u32,
    incumbent_alive: bool,
    joined: bool,
) -> bool {
    incumbent_alive
        && !joined
        && matches!(mode, RaceMode::Swap { .. })
        && empty_rounds >= SWAP_HUNT_ROUNDS
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

/// How long the V2b fill waits for the message walk to settle after an arm,
/// so node truth folds before any indexer claim (D-074's order). A run that
/// cannot reach its node ends in about eight seconds (the walk's retries); one
/// whose page times out ends at the page timeout (60 s); a full catch-up is up
/// to three runs of sixteen pages (a landing on the mark a lock left, one on
/// the arm's own, then the tip), since a budget that lands on a mark walks on
/// unsettled (D-344). Past this the fill runs anyway, as it did after a
/// catch-up that ended early.
pub const INTAKE_SETTLE_WAIT: Duration = Duration::from_secs(120);

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

/// **The wallet lane's recovery, bounded** (D-101's deferred arm, owed since
/// LINK-Q1 — D-334). When the wallet processor's connect negotiation fails on
/// a socket that STAYED bound, the monitor re-announces that socket to it this
/// many times, after these pauses, before it rebinds.
///
/// Why a re-announce is a real retry on the same socket, read at the pin
/// (`wallet/core/src/utxo/processor.rs` @ `01b532e`): the processor's own task
/// renegotiates only on a `RpcState::Connected` edge, and only while its own
/// `is_connected` is false (`:717-718`). A negotiation that failed in
/// `init_state_from_server` — the `get_server_info` round trip, the only step
/// that can fail on a live socket — failed BEFORE that flag was set (`:537-539`),
/// so one more `Connected` on the monitor's ctl makes the processor run its
/// whole negotiation again, through its own task, serialized behind whatever it
/// is doing. The processor's task is the ONLY listener on that ctl (`:696`;
/// the sync monitor and our acceptance tracker listen elsewhere), so the edge
/// reaches nothing else (PB-036). One retry owner (PB-019): this monitor.
///
/// Two, because the one failure a live socket can produce is a round trip that
/// did not come back, and a second chance covers a node that was briefly busy;
/// more would only delay the rebind that a node which cannot answer
/// `get_server_info` needs. **Two per SOCKET, not per check**
/// (`wallet-security-auditor`): a negotiation that fails fast gets its second
/// chance five seconds later, but one that hangs to the wRPC timeout (60 s,
/// polled every 5 — `workflow-rpc 0.18.0 client/mod.rs:151-152`) is still
/// running when this check settles, and its failure arrives after the check
/// has ended. That echo starts a new check, which finds the socket's budget
/// spent and goes straight to rebind-or-stop — so a node that ticks but never
/// answers costs one socket two retries, not two a minute forever.
const LANE_REANNOUNCE_AFTER: [Duration; 2] = [Duration::from_secs(2), Duration::from_secs(5)];

/// How long the processor gets after the last re-announce before the lane is
/// judged still dark. A healthy negotiation is one round trip; five seconds
/// is the probe's own ceiling for one ([`link::PROBE_DEADLINE_CAP`]).
const LANE_SETTLE: Duration = Duration::from_secs(5);

/// At most ONE lane rebind per this window, whatever keeps failing. A node
/// that cannot answer its first `get_server_info` on any socket would otherwise
/// turn this recovery into a rebind loop in the funds lane — the exact thing
/// D-101 deferred it for. Past the budget the recovery says so and stops; the
/// next natural drop, a pull (which takes the hard path when the lane is down)
/// or a tap heals it.
const LANE_REBIND_WINDOW_SECS: u64 = 600;

/// Milliseconds on a process-wide MONOTONIC clock. The unix-second clocks in
/// this file are fine for a 30 s verdict and useless for a nine-second
/// deadline (a whole-second clock is ±1 s of it), and a wall clock can step
/// under NTP; the silence hunt's stand-down reads this instead.
pub(crate) fn mono_ms() -> u64 {
    static EPOCH: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    ms_since(*EPOCH.get_or_init(std::time::Instant::now))
}

/// Milliseconds since `epoch`, **counted from 1**. Every monotonic stamp on a
/// socket keeps 0 for "never" (`connected_mono_ms`, `last_tick_mono_ms`, and
/// the message walk's progress stamp, `walk.rs`), and the clock's epoch is its
/// first call — which in a process is the first socket's publish. Counted from 0, that socket stamped
/// itself "never published", and the blockless-ticks witness (D-334 item 1)
/// stayed silent for the first socket of every process: found by LINK-Q2's
/// `ba=0` arms, an hour of blockless ticks and not one line. A uniform +1
/// moves no difference and no deadline.
fn ms_since(epoch: std::time::Instant) -> u64 {
    ms_of(epoch.elapsed())
}

/// A span in whole milliseconds, counted from 1 (see [`ms_since`]).
fn ms_of(span: Duration) -> u64 {
    u64::try_from(span.as_millis())
        .unwrap_or(u64::MAX)
        .saturating_add(1)
}

/// **The silence deadline's clock, one per socket** (LINK-Q1, D-334; two
/// stages since LINK-Q4).
///
/// Owned by the socket's own task, which is the only place its ticks are
/// folded, so it needs no lock; kept on tokio's clock so a test can run a
/// nine-second silence in paused time instead of sleeping through it. Pure:
/// `bind_loop` feeds it and asks it when the next stage is due.
///
/// **Two stages per silence** (D-337 (ii), built at LINK-Q4): the PRE-DIAL
/// ([`link::predial_after`], 3 s for the base deadline) starts a hunt behind
/// the socket that holds its winner, and the SWAP (the deadline itself, 9 s,
/// budgeted) lets that winner in. **And one extension**: when a stage falls
/// while our own catch-up page could explain the silence, both stages move one
/// deadline later, once per silence — the page is our load, not the node's
/// (`consensus-auditor` item 18, L70), but a deaf socket must not hide behind
/// it for the page's whole minute.
#[derive(Debug, Default)]
struct SilenceClock {
    /// When this socket last proved it was alive: its accepted `Connected`,
    /// then every DAA tick after it. `None` while the socket is not up.
    heard: Option<tokio::time::Instant>,
    /// Whether it has delivered a tick since it came up — the log line names
    /// the deaf-from-the-start socket (`ivy`, 11 of 30 runs) apart from one
    /// that stopped.
    scored: bool,
    /// This silence already started its pre-dial hunt.
    predialed: bool,
    /// This silence already reached its swap stage. The next tick re-arms the
    /// clock; until then the socket is the watchdog's to judge, never a
    /// second hunt's.
    fired: bool,
    /// A catch-up page in flight explained this silence once: both stages
    /// are one deadline later. The next tick clears it.
    extended: bool,
    /// When the current CLEAN stretch began: this socket's accepted
    /// `Connected`, or its first tick after a quiet spell of at least the
    /// BASE deadline — fired or not, since with the budget at 18 s or off a
    /// silence can pass unfired and the link still did not hold
    /// (`consensus-auditor` delta NOTE 3). A clean [`link::SILENCE_HOLD_RESET`]
    /// is the link having HELD. Measured from the LAST quiet spell, not over
    /// the socket's life (third-delta NOTE 2): a latch kept a long-lived
    /// socket that coughed once on the watchdog's line for good.
    clean_since: Option<tokio::time::Instant>,
    /// This clean stretch already reported holding; once per stretch.
    held: bool,
}

/// Which of a silence's two stages is due (LINK-Q4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SilenceStage {
    /// Start a hunt behind the socket and hold its winner.
    Predial,
    /// The deadline: let a winner in.
    Swap,
}

impl SilenceClock {
    fn up(&mut self, now: tokio::time::Instant) {
        *self = Self {
            heard: Some(now),
            clean_since: Some(now),
            ..Self::default()
        };
    }

    /// A tick. Returns true the first time a clean stretch reaches
    /// [`link::SILENCE_HOLD_RESET`] — a minute with no quiet spell of the base
    /// deadline: the link HELD, and the silence deadline's backoff may reset.
    fn tick(&mut self, now: tokio::time::Instant) -> bool {
        let Some(heard) = self.heard else {
            return false;
        };
        if now.saturating_duration_since(heard) >= link::SILENCE_DEADLINE {
            self.clean_since = Some(now);
            self.held = false;
        }
        self.heard = Some(now);
        self.scored = true;
        self.predialed = false;
        self.fired = false;
        self.extended = false;
        let held = !self.held
            && self.clean_since.is_some_and(|clean| {
                now.saturating_duration_since(clean) >= link::SILENCE_HOLD_RESET
            });
        self.held |= held;
        held
    }

    fn down(&mut self) {
        *self = Self::default();
    }

    /// The next stage and when it falls, or `None` when there is nothing to
    /// watch — nothing up, this silence already reached its swap, or the
    /// budget has switched the deadline off (`deadline` is
    /// [`link::silence_deadline_after`]'s answer).
    fn next(&self, deadline: Option<Duration>) -> Option<(tokio::time::Instant, SilenceStage)> {
        if self.fired {
            return None;
        }
        let deadline = deadline?;
        let from = self.heard?
            + if self.extended {
                deadline
            } else {
                Duration::ZERO
            };
        Some(if self.predialed {
            (from + deadline, SilenceStage::Swap)
        } else {
            (from + link::predial_after(deadline), SilenceStage::Predial)
        })
    }

    /// When the swap stage falls (tests: the deadline as LINK-Q1 knew it).
    #[cfg(test)]
    fn due(&self, deadline: Option<Duration>) -> Option<tokio::time::Instant> {
        if self.fired {
            return None;
        }
        let deadline = deadline?;
        Some(
            self.heard?
                + deadline
                + if self.extended {
                    deadline
                } else {
                    Duration::ZERO
                },
        )
    }

    /// Both stages move one deadline later, once per silence.
    fn extend(&mut self) {
        self.extended = true;
    }

    fn fire(&mut self, stage: SilenceStage) {
        match stage {
            SilenceStage::Predial => self.predialed = true,
            SilenceStage::Swap => {
                self.predialed = true;
                self.fired = true;
            }
        }
    }
}

/// One re-announce's outcome (D-101's recovery).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Reannounce {
    Done,
    /// The socket is no longer the bound, announced one.
    SocketGone,
    /// This socket already had its re-announces.
    BudgetSpent,
}

/// What the wallet lane's recovery found, and what it did (D-101, LINK-Q1).
/// Every arm is logged by name, so a capture reads the outcome directly —
/// the trigger that "fired 5×" in CONN-F1's retrospective was five of the
/// benign first two, and nothing then said so.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LaneRecovery {
    /// A check was already running; this report is queued behind it, and one
    /// more pass runs when it ends (reports that queue together share it).
    Queued,
    /// The processor is up — the error came from its notification path, or
    /// the negotiation already succeeded on a newer socket.
    NotDark,
    /// The socket the negotiation ran on is gone; the next bind's `Connected`
    /// renegotiates on its own, as it did in all five CONN-F1 cases.
    SocketGone,
    /// The lane came up — by itself (`0`) or after this many re-announces in
    /// this check.
    Recovered { reannounced: u32 },
    /// Still dark on the same live socket after the re-announces: rebound.
    Rebound,
    /// Still dark, and this window's rebind is spent — logged, and left to
    /// the next drop, pull or tap.
    GaveUp,
    /// The lane's processor was dead or stalled (PRE3-LANE): a fresh processor
    /// and context were built on the live socket.
    Rebuilt,
    /// Dead, and the lane's restart budget is spent (PRE3-LANE): it reads dark
    /// until the next socket or a pull.
    RebuildsSpent,
}

/// **What the wallet lane answers its recovery** (PRE3-LANE). A processor whose
/// task panicked or stalled cannot hear a re-announce — the pin keeps its
/// `task_is_running` set, so nothing restarts it — and the only repair is a new
/// lane. The engine attaches these answers, and the recovery asks them first,
/// inside the one flight it already owns (PB-019: one retry owner).
pub trait WalletLaneHooks: Send + Sync {
    /// The supervisor found the lane dead and no rebuild has answered yet.
    fn lane_dead(&self) -> bool;
    /// Discard the dead lane's processor and context and build fresh ones.
    fn rebuild(
        &self,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = LaneRecovery> + Send + '_>>;
}

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

/// **What the phone's own network did** (LINK-Q4, D-337 (ii)) — relayed from
/// Android's default-network callback by the host activity, as a kind and
/// nothing else: no network identity, no address, no SSID crosses (INV-3,
/// `ffi-leak-auditor`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetworkEvent {
    /// A default network is up after none was (`onAvailable` following an
    /// `onLost`, or the first one this process heard).
    Available,
    /// The default network is gone and nothing replaced it (`onLost`).
    Lost,
    /// The default network MOVED: a different network became the default
    /// while the old one was still up (Wi-Fi returning over cellular, one
    /// Wi-Fi to another).
    Moved,
    /// The default network's link changed in place — its addresses, or its
    /// Wi-Fi band. A hint, never the only signal: a roam within one SSID can
    /// keep the network and say nothing (LINK-Q1's 10:59 band hop).
    Changed,
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
    /// Unix-seconds of the last DAA tick THIS socket delivered. The stall
    /// verdict's evidence clock (L70: a detector measures its subject against
    /// the subject's own lifetime); the process-wide twin on [`Inner`] stays
    /// for the glass's data-age reading. It was the last BLOCK until LINK-Q1
    /// moved the heartbeat to the tick every stream shape keeps (D-334; what
    /// that did to the stall line is on [`link::WATCHDOG_STALL_SECS`]).
    last_tick_at: AtomicU64,
    /// DAA ticks this socket has delivered — the silence hunt's "did it come
    /// back?" counter ([`SwapWhy::Silent`]).
    ticks: AtomicU64,
    /// [`mono_ms`] at this socket's last tick (0 = none yet) — the same fact on
    /// a clock fine enough for a nine-second deadline.
    last_tick_mono_ms: AtomicU64,
    /// This socket's probe clock (D-333): a round trip learned on one node
    /// says nothing about the next, so it is born with the socket and dies
    /// with it.
    probe_clock: Mutex<link::ProbeClock>,
    /// A background round-trip probe is in flight on this socket (LINK-Q4):
    /// one at a time, however slow the answer.
    probing: AtomicBool,
    /// [`mono_ms`] of this socket's last answered probe, from either reader
    /// (0 = none) — the background probe skips a turn the Network screen's
    /// probe has just taken.
    last_probe_mono_ms: AtomicU64,
    /// [`mono_ms`] this socket last logged its window's median (0 = never).
    rtt_logged_mono_ms: AtomicU64,
    /// This socket's current silence reached its swap stage (LINK-Q4): a
    /// pre-dialled winner held behind it may come in. Set by the socket's own
    /// task at the deadline, cleared by its next tick.
    swap_due: AtomicBool,
    /// Re-announces this socket has had from the wallet lane's recovery — its
    /// budget is [`LANE_REANNOUNCE_AFTER`]'s length FOR THE SOCKET, not per
    /// check (`wallet-security-auditor`): a negotiation that hangs to the wRPC
    /// timeout (~60 s) fails after the check that retried it has ended, and
    /// that echo must not buy the same socket two more.
    lane_reannounced: AtomicU32,
    /// How many times this identity has been PUBLISHED. A race bind publishes
    /// once; a pinned bind redials inside one identity (the pin's own retry
    /// loop), so its gen alone cannot tell one physical socket from the next.
    /// The wallet lane's recovery keys on (gen, this) — `consensus-auditor`
    /// delta NOTE 2.
    publishes: AtomicU64,
    /// [`mono_ms`] when this socket was published (0 = not yet): where the
    /// witness's stretch starts (`consensus-auditor` CONCERNS-3, D-334). Since
    /// LINK-Q3 the witness watches the message walk, not blocks
    /// (`Walk::note_ticks`).
    connected_mono_ms: AtomicU64,
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
    /// Payload-transport fan-out (P2.1) for OBSERVERS (the dev wire view):
    /// matches from the message walk (LINK-Q3). Separate from `events` — these
    /// are discrete deliveries, not foldable snapshots, and they stay sparse
    /// (only `ciph_msg:`/`kchat:` matches are ever sent). The hub does not read
    /// this: it folds each page through its [`MessageSink`], so its success is
    /// what commits the walk's cursor.
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
    /// watchdog execution, [`link::StrikeReason::BindFailed`] for a winner
    /// whose bind failed (LINK-Q4: judged in absentia since D-340 item 9), so
    /// the ledger records the true proximate cause (R3 D1) instead of
    /// flattening them to `drop`.
    ///
    /// **A list, one entry per endpoint, since LINK-Q4.** It was one slot
    /// while only a death parked, and a death is followed by a race, not by
    /// another death. A bind failure is followed by the next round at once, so
    /// a drop parked on one node and a bind failure on the next would have
    /// overwritten the drop — acquitting it by accident. Bounded at
    /// [`PENDING_STRIKES_CAP`]; every entry settles at the next `Connected`.
    pending_strikes: Mutex<Vec<(String, u64, link::StrikeReason)>>,
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
    /// **The message walk** (LINK-Q3, D-344): one cursor, one fetch per chain
    /// move, the transport matcher over what the chain accepted (`walk.rs`).
    /// Poked by this socket's `VirtualChainChanged` and by every publish; armed
    /// by the hub at unlock, held at lock.
    walk: Arc<Walk>,
    /// The walk's transport matcher, kept to hand it the hub's sink at arm.
    transport_matcher: Arc<TransportMatcher>,
    /// Unix-seconds of the last DAA tick, process-wide (0 = none yet). This is
    /// the **display** clock: how old the data on the glass is, which is a
    /// property of the app's session, not of any one socket, and it must keep
    /// reading across a rebind (C7's no-staleness-before-first-connect
    /// invariant is built on it). A plain atomic store per tick (no I/O).
    /// Fed by `BlockAdded` until LINK-Q1 (D-334) — see
    /// [`link::WATCHDOG_STALL_SECS`] for what the move changed.
    ///
    /// Its **judgment** twin is [`BoundSocket::last_tick_at`] (R4): a stall
    /// verdict is measured against the accused socket's own silence, never the
    /// process's — that conflation was the D-099/L70 cascade.
    last_tick_at: AtomicU64,
    /// Every DAA tick an installed socket has delivered in this process. A
    /// plain count, never reset, counted here before the bridge's 250 ms
    /// coalescer so it is the real tick count rather than the coalesced one.
    /// It fed the Network screen's `DAA · 10 Hz` until LINK-UX1 (D-342), whose
    /// `BPS` reads the DTO's `virtual_daa_score` climb instead; since then it
    /// reaches the logs and the diagnostics pull only (`dag_status`).
    daa_ticks: AtomicU64,
    /// Single-flight for [`DagMonitor::recover_wallet_lane`] (D-101): one
    /// recovery at a time, however many errors report in.
    lane_recovering: AtomicBool,
    /// A report asked for a pass that has not run yet. Set by EVERY report
    /// before it tries for [`Self::lane_recovering`], drained by whoever holds
    /// it — so a report that finds a check running is queued behind it, never
    /// dropped (`wallet-security-auditor`: the running check may be about a
    /// socket that has since been replaced, and the report about its
    /// successor was the only one that successor would ever send).
    lane_report_pending: AtomicBool,
    /// Unix-seconds of the last lane rebind (0 = never) — the
    /// [`LANE_REBIND_WINDOW_SECS`] budget.
    lane_rebound_at: AtomicU64,
    /// The wallet engine's own answers — is its lane dead, and the rebuild —
    /// so a death rides this same flight (PRE3-LANE). `None` until an engine
    /// attaches ([`DagMonitor::attach_wallet_lane`]).
    wallet_lane: std::sync::Mutex<Option<Arc<dyn WalletLaneHooks>>>,
    /// Silence swaps that have landed since the link last HELD
    /// ([`link::SILENCE_HOLD_RESET`]) — the silence deadline's backoff
    /// ([`link::silence_deadline_after`], `consensus-auditor` CONCERNS-1).
    silence_backoff: AtomicU32,
    /// Every user swap tap, counted. A silence hunt remembers the count it
    /// began at; a tap during it makes the hunt the user's, which its
    /// incumbent's comeback can no longer call off (CONCERNS-2).
    swaps_asked: AtomicU64,
    /// Each node's round trip over its last full window, on the network the
    /// phone is on now (LINK-Q4, [`link::RttBook`]): ranks the pantry and the
    /// race's preference; flushed when the network moves.
    rtt: Mutex<link::RttBook>,
    /// Tests: a scripted round in place of [`link::race`], handed the round's
    /// exclusions — so the race LOOP (its judgments, its holds, its binds) is
    /// driven offline (LINK-Q4).
    #[cfg(test)]
    race_script: Mutex<Option<RaceScript>>,
    /// [`mono_ms`] when the phone's default network last moved or came back
    /// ([`NetworkEvent::Moved`] / [`NetworkEvent::Available`]); 0 = never. A
    /// socket published before it is on a network the phone has left
    /// ([`DagMonitor::network_moved_under`], LINK-Q4).
    network_moved_mono_ms: AtomicU64,
    /// The default network was lost and nothing has replaced it yet: the next
    /// [`NetworkEvent::Available`] is a different network from the one any
    /// live socket was dialled on. Without it that event is only the state
    /// Android reports as a callback registers, and marks nothing.
    network_lost_pending: AtomicBool,
    /// V1 acceptance spine: where the event task forwards VirtualChainChanged
    /// batches, and the message walk its pages' acceptances (LINK-Q3), once
    /// the tracker is attached ([`DagMonitor::attach_acceptance`]). Shared with
    /// the walk's transport matcher. Unattached (or a dead receiver) = batches
    /// drop harmlessly — the tracker's own reconnect catch-up recovers anything
    /// missed while detached.
    vcc_tx: Arc<Mutex<Option<tokio::sync::mpsc::UnboundedSender<TrackerFeed>>>>,
    /// LINK-Q2's measurement seam: dev flags, default OFF. Every hook
    /// into it is one relaxed load that returns while the flags file is absent.
    devab: Arc<devab::DevAb>,
    /// Set when the flags file said `on=1` as the files dir became known —
    /// then, and only then, [`Self::start`] spawns the flags loop.
    devab_armed: AtomicBool,
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

/// One reading of the bound link — see [`DagMonitor::probe_link`].
///
/// Three outcomes, never two (D-333): an answer (`latency_ms`), a round trip
/// that outlasted the deadline (`timed_out_ms` — a lower bound, not an
/// absence), or neither, which is an error (no socket, a refused call).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LinkProbe {
    /// Round trip of one `get_server_info` on the bound socket, in ms.
    pub latency_ms: Option<u64>,
    /// The deadline, in ms, that one `get_server_info` outlasted. The round
    /// trip was AT LEAST this — a censored sample the reader shows as `> N s`
    /// rather than blanking a slow, live link.
    pub timed_out_ms: Option<u64>,
    /// The node's own `is_synced`; `None` when it did not answer.
    pub synced: Option<bool>,
    /// The node's peer count; `None` when not asked for, or not answered.
    pub peers: Option<u32>,
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
        let address_prefix = Prefix::from(network_id.network_type);
        let vcc_tx = Arc::new(Mutex::new(None));
        let devab = Arc::new(devab::DevAb::default());
        let transport_matcher = TransportMatcher::new(
            address_prefix,
            transport_events.clone(),
            vcc_tx.clone(),
            devab.clone(),
        );
        let walk = Walk::new(vec![transport_matcher.clone() as Arc<dyn walk::WalkMatcher>]);
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
                address_prefix,
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
                pending_strikes: Mutex::new(Vec::new()),
                hygiene_advisory: AtomicBool::new(false),
                pause_gen: AtomicU64::new(0),
                direct_url: Mutex::new(url),
                paused: AtomicBool::new(false),
                walk,
                transport_matcher,
                last_tick_at: AtomicU64::new(0),
                daa_ticks: AtomicU64::new(0),
                lane_recovering: AtomicBool::new(false),
                lane_report_pending: AtomicBool::new(false),
                lane_rebound_at: AtomicU64::new(0),
                wallet_lane: std::sync::Mutex::new(None),
                silence_backoff: AtomicU32::new(0),
                swaps_asked: AtomicU64::new(0),
                network_moved_mono_ms: AtomicU64::new(0),
                rtt: Mutex::new(link::RttBook::default()),
                #[cfg(test)]
                race_script: Mutex::new(None),
                network_lost_pending: AtomicBool::new(false),
                vcc_tx,
                devab,
                devab_armed: AtomicBool::new(false),
            }),
        })
    }

    /// Attach the acceptance tracker (V1): returns the receiving end of the
    /// VirtualChainChanged forward, which since LINK-Q3 also carries the
    /// message walk's acceptances. Batches that arrive before attachment drop
    /// harmlessly (the tracker's connect catch-up covers the gap).
    pub fn attach_acceptance(&self) -> tokio::sync::mpsc::UnboundedReceiver<TrackerFeed> {
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
        // LINK-Q2: the dev flags live beside the ledger. Read now, so
        // an armed build's socket registry is on before the first dial.
        if devab::prime(&self.inner.devab, &path.with_file_name(devab::FLAGS_FILE)) {
            self.inner.devab_armed.store(true, Ordering::SeqCst);
        }
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
                self.record_withheld(url, reason, why);
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

    /// Record a strike ruled inadmissible — recorded, never erased: the
    /// ledger must stay auditable for wrongful ACQUITTALS too, not only
    /// wrongful convictions.
    fn record_withheld(&self, url: &str, reason: link::StrikeReason, why: link::StrikeReason) {
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
        log::info!(
            "link: strike ({}) on {host} WITHHELD as {} — not the node's fault \
             ({withheld} withheld so far)",
            reason.as_token(),
            why.as_token(),
            host = link::endpoint_host(url)
        );
        spans::mark_with("endpoint_strike_withheld", link::endpoint_host(url));
    }

    /// A stall the watchdog executed under our own page (LINK-Q4): withheld
    /// at once, never parked.
    fn withhold_strike(&self, url: &str, why: link::StrikeReason) {
        self.record_withheld(url, link::StrikeReason::Stall, why);
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
    /// watchdog execution (R3 D1), `BindFailed` for a winner that would not
    /// bind (LINK-Q4). A newer event on the same endpoint replaces its older
    /// one (the ledger would count them as one incident anyway,
    /// [`link::STRIKE_DEDUP_SECS`]); a full list drops its oldest, logged.
    fn set_pending_strike(&self, url: String, why: link::StrikeReason) {
        let mut pending = self
            .inner
            .pending_strikes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        pending.retain(|(parked, _, _)| *parked != url);
        if pending.len() >= PENDING_STRIKES_CAP {
            let (oldest, _, oldest_why) = pending.remove(0);
            log::info!(
                "link: pending strike ({}) on {host} dropped unjudged — {PENDING_STRIKES_CAP} \
                 already wait for a connect",
                oldest_why.as_token(),
                host = link::endpoint_host(&oldest)
            );
        }
        pending.push((url, Self::now_unix(), why));
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
        let taken = std::mem::take(
            &mut *self
                .inner
                .pending_strikes
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
        );
        for (url, at, why) in taken {
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

    /// **A race winner's bind failed** (LINK-Q4, D-340 item 9). It used to be
    /// convicted at once, on "the network is known alive: it just answered a
    /// probe". A probe proves the network as it WAS: at 10:59:43 (LINK-Q1)
    /// `ivy` answered its probe, its bind timed out three seconds later inside
    /// a band hop Android never reported, and every other node and every
    /// resolver walk found nothing for the next twelve seconds. So:
    ///
    /// - **we retired the bind under the dial** → no strike: convicting a node
    ///   for our own act is the self-inflicted verdict auditor item 18
    ///   forbids (the envelope-timeout arm is spared for the same reason);
    /// - **the node answered with a server error** → convicted now, as
    ///   `http-5xx`: an answer is earned guilt, and the in-absentia rule must
    ///   never become its alibi (`ivy`'s 500 bar, D-092 ruling 6);
    /// - **anything else** (a timeout, a reset, a refusal) → parked like a
    ///   drop and judged by the rounds after it: committed at the next
    ///   `Connected` from another node, withheld if a round in between proved
    ///   the phone dark, refuted by the node's own reconnect.
    fn judge_bind_failure(&self, url: &str, gen: u64, text: &str) {
        let host = link::endpoint_host(url);
        if !self.is_current_bind(gen) {
            log::info!("link: bind to {host} failed after we retired it — no strike (ours)");
            return;
        }
        if link::StrikeReason::classify_probe_failure(text) == link::StrikeReason::HttpServerError {
            self.commit_strike(
                url,
                link::StrikeReason::HttpServerError,
                Self::now_unix(),
                false,
            );
            return;
        }
        log::info!(
            "link: bind-failed on {host} parked — judged by the rounds after it, since a probe \
             proves the network only as it was"
        );
        self.set_pending_strike(url.to_string(), link::StrikeReason::BindFailed);
    }

    /// **The nodes whose bind failed and who await judgment** (LINK-Q4,
    /// `consensus-auditor` round 1 BLOCK): parked `bind-failed` strikes still
    /// inside [`link::PENDING_STRIKE_TTL_SECS`]. They sit out every round
    /// until judged, so the connect that judges them is another node's — the
    /// node itself cannot be its own witness either way (D-084), and a node
    /// that answers probes but fails binds cannot hold the wallet dark by
    /// winning every round. Past the TTL the strike would expire unjudged at
    /// the settle anyway, and the node may race again.
    fn bind_failures_awaiting_judgment(&self, now: u64) -> HashSet<String> {
        self.inner
            .pending_strikes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .filter(|(_, at, why)| {
                *why == link::StrikeReason::BindFailed
                    && now.saturating_sub(*at) <= link::PENDING_STRIKE_TTL_SECS
            })
            .map(|(url, _, _)| url.clone())
            .collect()
    }

    /// One race round: [`link::race`] over the resolver and the probes — or,
    /// in a test, the scripted round.
    async fn run_race(
        &self,
        cached: Option<String>,
        pantry: Vec<String>,
        excluded: &HashSet<String>,
        prefer: &std::collections::HashMap<String, u64>,
    ) -> link::RaceOutcome {
        #[cfg(test)]
        if let Some(script) = self
            .inner
            .race_script
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
        {
            return script(&RoundAsked {
                pantry,
                excluded: excluded.clone(),
                prefer: prefer.clone(),
            });
        }
        link::race(
            &self.inner.resolver,
            self.inner.network_id,
            cached,
            pantry,
            excluded,
            RACE_FETCHES,
            PROBE_TIMEOUT,
            prefer,
        )
        .await
    }

    /// The endpoints whose strikes are parked awaiting a connect.
    fn parked_urls(&self) -> HashSet<String> {
        self.inner
            .pending_strikes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .map(|(url, _, _)| url.clone())
            .collect()
    }

    /// The incumbent a race round runs behind, as (gen, ticks) — `None` while
    /// nothing is up. Read before the round; [`Self::stamp_barren_round`]
    /// reads it again after.
    fn round_prover(&self) -> Option<(u64, u64)> {
        if !self.is_connected() {
            return None;
        }
        self.current_bind()
            .map(|bind| (bind.gen, bind.ticks.load(Ordering::SeqCst)))
    }

    /// Did the incumbent vouch for the phone's network THROUGH the round —
    /// still the bound socket, still up, and ticked since the round began?
    fn prover_spoke_through(&self, prover: Option<(u64, u64)>) -> bool {
        let Some((gen, ticks)) = prover else {
            return false;
        };
        self.is_connected()
            && self
                .current_bind()
                .is_some_and(|bind| bind.gen == gen && bind.ticks.load(Ordering::SeqCst) > ticks)
    }

    /// **Stamp a barren round as the phone's fault, when it is the only
    /// witness and it says so** (R3 D-099; widened at LINK-Q4). The stamp is
    /// what [`link::judge_admissibility`] reads to withhold a strike parked
    /// in absentia (a drop, a stall, a bind failure) whose event came at or
    /// before it. Returns whether it stamped.
    ///
    /// **What says so.** Either rule: ≥ 2 distinct hosts failed DNS or
    /// `ENETUNREACH` ([`link::phone_fault_in_round`]), or nothing answered at
    /// all — no resolver walk, no dial, ≥ 2 distinct hosts
    /// ([`link::nothing_answered_in_round`], the band-hop case the first rule
    /// cannot see because a dark Wi-Fi times out rather than refusing).
    ///
    /// **When the round is the only witness** (`consensus-auditor` CONCERNS-4,
    /// re-derived): a socket that TICKED through the round is direct proof
    /// the phone's network works, and a round behind it must not stamp a
    /// blackout on its word. That used to be written "only while
    /// disconnected", which also silenced a SILENCE hunt's rounds — whose
    /// incumbent is quiet by definition and vouches for nothing (IDEAS
    /// 2026-09-26, *the phone-fault stamp is gated on "dark"*; routed here by
    /// D-340 item 9 as the same admissibility question as `bind-failed`). The
    /// gate now reads the evidence instead of the mode: no incumbent, one
    /// that died, or one that stayed silent through the round → the round
    /// witnesses the phone; one that ticked → it does not.
    fn stamp_barren_round(&self, outcome: &link::RaceOutcome, prover: Option<(u64, u64)>) -> bool {
        let dns = link::phone_fault_in_round(&outcome.failed);
        let dark = link::nothing_answered_in_round(&outcome.failed, outcome.answered);
        if !dns && !dark {
            return false;
        }
        if self.prover_spoke_through(prover) {
            log::info!(
                "link: round failed phone-side behind a socket that ticked through it — not \
                 stamped (a live socket vouches for the network)"
            );
            return false;
        }
        // Stamped at the round's END: the round saw the network dark for its
        // whole span, so an event inside it is covered too (the stamp used to
        // be the round's start, read at the loop head).
        self.inner
            .phone_fault_round_at
            .store(Self::now_unix(), Ordering::SeqCst);
        if dns {
            log::info!(
                "link: round failed phone-side across {}+ distinct hosts (DNS/unreachable) — \
                 stamped as link blackout",
                link::DNS_CORRELATION_MIN
            );
        } else {
            log::info!(
                "link: nothing answered this round ({} node(s), every resolver walk) — stamped \
                 as link blackout",
                outcome.failed.len()
            );
        }
        true
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

    /// **Arm the message intake** (LINK-Q3, D-344): from now on the walk folds
    /// every page's transport matches through `sink` (the unlocked hub), and
    /// commits its cursor at `cursor_path` only once they are folded. Resumes
    /// from the committed cursor, so whatever the walk has not folded since, a
    /// cold open's gap, a reconnect's, a lock's, is replayed by construction.
    /// Called at every unlock (`transport_start`); returns the arm's epoch for
    /// [`Self::intake_settled`].
    pub fn arm_intake(&self, cursor_path: PathBuf, sink: Arc<dyn MessageSink>) -> u64 {
        // The sink first: the walk may run the moment it is armed.
        self.inner.transport_matcher.set_sink(sink);
        self.inner.walk.arm(cursor_path)
    }

    /// **Hold the message intake** (the vault locked): no page is fetched until
    /// the next arm, and the committed cursor is written, so the unlock replays
    /// what the lock refused (deliverable 4, `wallet-security-auditor`).
    pub fn hold_intake(&self, why: &str) {
        self.inner.walk.hold(why);
    }

    /// **Hold the intake and wait out a fold in flight**: once this returns no
    /// page is being folded and none can start until the next arm. The hub
    /// calls it before it restarts on a new store, so the store has one writer
    /// (the previous fold task used to be aborted for the same reason).
    pub async fn quiesce_intake(&self, why: &str) {
        self.inner.walk.hold(why);
        self.inner.walk.quiesce().await;
    }

    /// Wait (at most `within`) until the walk under the arm that returned
    /// `epoch` has settled: a run reached the tip, gave up on an unreachable
    /// node, re-seeded at the sink, or spent a budget past the arm's mark (a
    /// budget that lands on a mark walks on unsettled, D-344). The V2b fill
    /// waits on it so node truth folds before any indexer claim (D-074's
    /// order). `false` on the timeout.
    pub async fn intake_settled(&self, epoch: u64, within: Duration) -> bool {
        self.inner.walk.settled(epoch, within).await
    }

    /// Read a persisted intake cursor WITHOUT arming anything — the hub reads
    /// the PRIOR session's point at open, for the gap-age line. A missing or
    /// corrupt file yields `None` (first run, or nothing to recover).
    pub fn read_transport_cursor(path: &std::path::Path) -> Option<Hash> {
        walk::read_cursor(path)
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
    /// [`TransportEvent`] per `ciph_msg:`/`kchat:` match in an ACCEPTED
    /// transaction, as the message walk folds it (LINK-Q3). For observers (the
    /// dev wire view): the hub folds through its [`MessageSink`] instead, so a
    /// slow observer can lag without losing a message. A late subscriber sees
    /// the next match, never history — the P2.3 message store owns persistence.
    /// Rides the same socket + pause/resume posture as everything else.
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
    /// **One honest round trip to the node, its own word on whether it is
    /// synced, and — when asked — how many peers it has.**
    ///
    /// `T5`'s connection card reads all three, and none may be invented —
    /// BG-8's rule is that the absence of a reading is its own face, so every
    /// field is an `Option` and comes back `None` the moment the call does not
    /// answer.
    ///
    /// **What the latency measures, exactly:** the wall time of one
    /// `get_server_info` on the bound wRPC socket — request out, response back.
    /// It costs what a `ping` costs (one small frame each way; the answer is a
    /// version string and five scalars the node reads off its own state) and,
    /// unlike a `ping`, it carries `is_synced`: the fact the connect race checks
    /// once at candidacy and never again, on a bind that can stay up for days.
    /// It is deliberately NOT derived from block age: a node can be answering
    /// instantly while the DAG is quiet, and the two would then contradict each
    /// other on one card.
    ///
    /// **Whose peers, and why they are optional:** the node's, from
    /// `get_connections` — two integers, where `get_connected_peer_info`
    /// serialises every peer's address, agent and timings to answer the same
    /// question. A light wallet has exactly one peer (this node), so the useful
    /// number is how well connected the node we are trusting is. It changes
    /// over minutes while a latency changes over seconds, so the caller asks
    /// for it on its own slower cadence and `None` means *not asked* as well
    /// as *not answered* — the caller knows which.
    ///
    /// Called only while the node surface is open. It holds no lock across the
    /// await and never retries: a probe that papered over a failure would be
    /// reporting the retry's latency, not the link's.
    ///
    /// **Both calls carry our own deadline**, and that is a correctness
    /// property rather than tidiness (`consensus-auditor`, UX-R3). Unbounded,
    /// the only backstop was the transport's own 60 s default, and a stalled
    /// node would stack probes whose answers could land out of order — an older
    /// slow reading overwriting a newer fast one: the confidently-wrong-number
    /// this probe exists to prevent (BG-8).
    ///
    /// **The deadline is the bound socket's own RFC 6298 clock** (LINK-Q1,
    /// D-333 — [`link::ProbeClock`]), no longer a fixed 1.8 s. A fixed deadline
    /// under the old 2 s poll turned every slow answer on the founder's
    /// Starlink hop into "no reading", and the seat went dark and relit on a
    /// socket that never dropped. Now the wait follows the answers this socket
    /// has actually given, and a round trip that outlasts it comes back as
    /// `timed_out_ms` — "at least this long" — which the reader draws as a
    /// slow link, not a dead one. The caller's single-flight is unchanged: a
    /// slow answer occupies poll ticks rather than stacking calls.
    pub async fn probe_link(&self, with_peers: bool) -> LinkProbe {
        let rpc = self.inner.link_rpc.clone();
        // The socket whose clock sets the wait. `None` between binds: then
        // there is no round trip to time, and the call below answers the
        // typed no-socket error at once — an error, not a timeout.
        let bind = self.current_bind();
        let deadline = bind.as_ref().map_or(link::PROBE_DEADLINE_CAP, |bind| {
            bind.probe_clock
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .deadline()
        });
        let deadline_ms = u64::try_from(deadline.as_millis()).unwrap_or(u64::MAX);
        let started = std::time::Instant::now();
        let sent_unix_ms = Self::now_unix_ms();
        let mut probe = LinkProbe::default();
        match tokio::time::timeout(deadline, rpc.get_server_info()).await {
            Ok(Ok(info)) => {
                let rtt = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
                probe.latency_ms = Some(rtt);
                probe.synced = Some(info.is_synced);
                if let Some(bind) = &bind {
                    bind.probe_clock
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .answered(rtt);
                    self.note_rtt(bind, sent_unix_ms, rtt, false);
                }
            }
            Err(_) => {
                probe.timed_out_ms = Some(deadline_ms);
                if let Some(bind) = &bind {
                    bind.probe_clock
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .timed_out();
                    self.note_rtt(bind, sent_unix_ms, deadline_ms, true);
                }
            }
            // A refused call (no socket, a node error) is neither a sample nor
            // a lower bound; the reader counts it toward its dwell.
            Ok(Err(_)) => {}
        }
        // Peers only after an ANSWER (`ux-auditor` N5): the screen reads a
        // peer count only beside a latency, so asking after a timeout or a
        // refusal bought nothing and doubled a slow probe's wait.
        if with_peers && probe.latency_ms.is_some() {
            if let Ok(Ok(connections)) =
                tokio::time::timeout(deadline, rpc.get_connections(false)).await
            {
                probe.peers = Some(u32::from(connections.peers));
            }
        }
        probe
    }

    pub fn rpc(&self) -> Rpc {
        Rpc::new(self.inner.link_rpc.clone(), self.inner.monitor_ctl.clone())
    }

    /// Current unix milliseconds (0 on a pre-epoch clock — never panics):
    /// the Starlink tag is a wall-clock fact.
    fn now_unix_ms() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
    }

    /// **A round trip read on `bind`** (LINK-Q4, D-337 (vi)): into the node's
    /// window ([`link::RttBook`]) while the socket is still the bound one; a
    /// spike (≥ [`link::RTT_SPIKE_MS`], or a timeout) is logged with its
    /// place on Starlink's schedule, and each full window's median once per
    /// window, so a capture can rank the nodes and split the air's spikes
    /// from the link's own.
    fn note_rtt(&self, bind: &BoundSocket, sent_unix_ms: u64, rtt_ms: u64, timed_out: bool) {
        if !self.is_current_bind(bind.gen) {
            return;
        }
        let now = mono_ms();
        bind.last_probe_mono_ms.store(now, Ordering::Relaxed);
        let median = {
            let mut book = self
                .inner
                .rtt
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            book.record(&bind.url, now, rtt_ms);
            book.median(&bind.url)
        };
        let host = link::endpoint_host(&bind.url);
        if timed_out || rtt_ms >= link::RTT_SPIKE_MS {
            let place = match link::starlink_boundary_in(sent_unix_ms, rtt_ms) {
                Some(second) => format!("straddles Starlink's :{second:02} boundary"),
                None => "off Starlink's schedule (Wi-Fi or the path)".to_string(),
            };
            log::info!(
                "link: rtt spike {}{rtt_ms} ms on {host}{} — {place}",
                if timed_out { "≥ " } else { "" },
                median.map_or(String::new(), |m| format!(" (30 s median {m} ms)"))
            );
        }
        let window = u64::try_from(link::RTT_WINDOW.as_millis()).unwrap_or(u64::MAX);
        if let Some(median) = median {
            let logged = bind.rtt_logged_mono_ms.load(Ordering::Relaxed);
            if logged == 0 || now.saturating_sub(logged) >= window {
                bind.rtt_logged_mono_ms.store(now, Ordering::Relaxed);
                log::info!("link: rtt {host} 30 s median {median} ms");
            }
        }
    }

    /// **The bound socket's round trip, read in the background** (LINK-Q4):
    /// one probe in flight at a time, and a turn is skipped when the Network
    /// screen's own probe answered within the last half-cadence. The same
    /// [`Self::probe_link`] the screen calls, so one clock and one book.
    fn spawn_link_probe(&self, bind: &Arc<BoundSocket>) {
        if !bind.announced.load(Ordering::SeqCst)
            || self.inner.paused.load(Ordering::SeqCst)
            || !self.is_current_bind(bind.gen)
        {
            return;
        }
        let half = u64::try_from(link::RTT_PROBE_EVERY.as_millis() / 2).unwrap_or(0);
        let last = bind.last_probe_mono_ms.load(Ordering::Relaxed);
        if last != 0 && mono_ms().saturating_sub(last) < half {
            return;
        }
        if bind.probing.swap(true, Ordering::SeqCst) {
            return;
        }
        let monitor = self.clone();
        let bind = bind.clone();
        tokio::spawn(async move {
            monitor.probe_link(false).await;
            bind.probing.store(false, Ordering::SeqCst);
        });
    }

    /// Initiates the first connect and starts the message walk's task (idle
    /// until the hub arms it). Must be called from within a tokio runtime.
    pub async fn start(&self) -> Result<()> {
        // LINK-Q3: one task, one fetch at a time, through the stable handle so
        // a rebind mid-page is survived; it waits for its first poke.
        let source = walk::LinkSource(self.inner.link_rpc.clone());
        tokio::spawn(
            self.inner
                .walk
                .clone()
                .run(Arc::new(source) as Arc<dyn walk::ChainSource>),
        );
        // LINK-Q2: the flags loop exists only in a process that
        // started with the flags file saying `on=1` — never in today's app.
        if self.inner.devab_armed.load(Ordering::SeqCst) {
            tokio::spawn(devab::run(DevHostHandle {
                inner: Arc::downgrade(&self.inner),
            }));
        }
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
        self.install_bind_after(url, "superseded").await
    }

    /// [`Self::install_bind`], naming why the incumbent (if any) leaves. A
    /// silence hunt's winner retires its incumbent as `silence-swap`, so a
    /// capture can tell the deadline's swaps from the user's (LINK-Q1).
    /// Recording is not judging either way: no strike.
    ///
    /// A silence swap's cost is paid the instant its incumbent is retired, so
    /// it is counted against the silence deadline's budget HERE, on the one
    /// path every silence swap takes (`consensus-auditor` CONCERNS-A: counted
    /// in the race loop, the line that advances the budget was reachable only
    /// by a race that found a winner over the network, and no test drove it).
    async fn install_bind_after(&self, url: String, cause: &str) -> Result<Arc<BoundSocket>> {
        // At most one identity exists at a time. Anything still installed is
        // retired (and recorded) before the new one is allocated — so a bind
        // can never be leaked by a path that forgot to clean up.
        let retired = self.retire_bind(cause).await;
        if cause == SILENCE_SWAP && retired.is_some() {
            self.note_silence_swap_landed();
        }

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
            last_tick_at: AtomicU64::new(0),
            ticks: AtomicU64::new(0),
            last_tick_mono_ms: AtomicU64::new(0),
            probe_clock: Mutex::new(link::ProbeClock::default()),
            swap_due: AtomicBool::new(false),
            probing: AtomicBool::new(false),
            last_probe_mono_ms: AtomicU64::new(0),
            rtt_logged_mono_ms: AtomicU64::new(0),
            lane_reannounced: AtomicU32::new(0),
            publishes: AtomicU64::new(0),
            connected_mono_ms: AtomicU64::new(0),
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
            self.inner
                .link_rpc
                .unbind(retirement_judges_the_link(cause));
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
            RaceMode::Swap { from, .. } => {
                spans::mark_with("swap_start", link::endpoint_host(from))
            }
        }
        let mut empty_rounds = 0u32;
        loop {
            let degraded = degrade_lost_swap(mode.clone(), self.is_connected());
            if degraded != mode {
                if let RaceMode::Swap { from, .. } = &mode {
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
            // **A silence hunt whose incumbent is talking again has nothing to
            // replace** (LINK-Q1: keep the incumbent if it speaks again). Asked
            // at every round's head — before any candidate is dialled — and
            // once more before a winner is installed, below.
            if self.silent_incumbent_is_back(&mode) {
                return;
            }
            // **A tap that joins a silence hunt makes it the user's** — from
            // here it IS a swap they asked for, with the rounds of one
            // (`consensus-auditor` note e: joined at round 3, the tap used to
            // buy no probe of its own, and the log still said "silence").
            if let Some(theirs) = self.joined_by_tap(&mode) {
                if let RaceMode::Swap { from, why } = &theirs {
                    if matches!(why, SwapWhy::Moved { .. }) {
                        log::info!(
                            "link: a tap joined the moved-network hunt behind {} — it stays out \
                             of the race now, with its own {SWAP_HUNT_ROUNDS} round(s)",
                            link::endpoint_host(from)
                        );
                    } else {
                        log::info!(
                            "link: a tap joined the silence hunt behind {} — it is the user's \
                             swap now, with its own {SWAP_HUNT_ROUNDS} round(s)",
                            link::endpoint_host(from)
                        );
                    }
                }
                mode = theirs;
                empty_rounds = 0;
            }
            // **A hunt running when the phone's network moved becomes the
            // moved-network hunt** (LINK-Q4, `wallet-security-auditor` round
            // 1): its incumbent is on a network the phone left, so its winner
            // comes in at once, with rounds of its own — the move's kick
            // cannot be spent on a round dialled on the old network and end in
            // "keeping" the socket there.
            if let Some(moved) = self.recast_if_moved(&mode) {
                if let RaceMode::Swap { from, .. } = &moved {
                    log::info!(
                        "link: the phone's network moved under {} during a hunt — it is the \
                         moved-network hunt now, with its own {SWAP_HUNT_ROUNDS} round(s)",
                        link::endpoint_host(from)
                    );
                }
                mode = moved;
                empty_rounds = 0;
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
            let ranks = self
                .inner
                .rtt
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .ranks();
            let (demoted, pantry, prefer) = {
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
                // Preferred by round trip only while clean (LINK-Q4: "never
                // over a strike") — a live strike or one parked awaiting its
                // connect takes a node out of the preference, not the race.
                let parked = self.parked_urls();
                let prefer: std::collections::HashMap<String, u64> = ranks
                    .iter()
                    .filter(|(url, _)| !health.has_live_strike(url, now) && !parked.contains(*url))
                    .map(|(url, rank)| (url.clone(), *rank))
                    .collect();
                // The pantry (C6): recent-healthy nodes dial immediately, in
                // parallel with the cached endpoint — the common reconnect
                // does zero HTTP before dialing a node it trusted recently.
                // Under the advisory degradation it ignores demotions too
                // (R2 D5): a floor that leaves the fast path dark is not a
                // floor, it is a slower way to reach the same dark wallet.
                // Ranked by the CLEAN ranks, so a struck node's good median
                // never buys it a fast-lane seat ahead of a clean one
                // (`consensus-auditor`, LINK-Q4 round 1).
                let pantry = health.race_pantry(
                    cached.as_deref(),
                    now,
                    link::PANTRY_DIALS,
                    advisory,
                    &prefer,
                );
                (demoted, pantry, prefer)
            };
            // The incumbent never enters its own replacement race (P0b). It
            // rides the same set the demotion ledger uses, which is what makes
            // the exclusion total for free: `link::race` filters the cached
            // endpoint, every pantry dial AND every resolver answer against
            // it, so there is no lane left where the node we are already on
            // could win and be "swapped" onto itself. **And a node whose bind
            // failed sits out until it is judged** (LINK-Q4): parked, it can
            // only be judged at ANOTHER node's connect, so the rounds that
            // judge it must be rounds it cannot win (`consensus-auditor`,
            // round 1 BLOCK: a node that answers probes and fails binds would
            // otherwise win every round and hold the wallet dark unjudged).
            let mut excluded = round_exclusions(demoted, &mode);
            excluded.extend(self.bind_failures_awaiting_judgment(now));
            // Who could vouch for the phone's network while this round runs:
            // the incumbent as it stands now (read again after the round).
            let prover = self.round_prover();
            let outcome = self.run_race(cached, pantry, &excluded, &prefer).await;

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
                // control-group conviction that round earned. Who else could
                // have vouched for the network, and what counts as the phone's
                // fault, is [`Self::stamp_barren_round`]'s (LINK-Q4).
                self.stamp_barren_round(&outcome, prover);
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
                if self.swap_hunt_spent(&mode, empty_rounds) {
                    if let RaceMode::Swap { from, why } = &mode {
                        log::info!(
                            "link: {} hunt found nothing better in {SWAP_HUNT_ROUNDS} \
                             round(s) — keeping {}{}",
                            if matches!(why, SwapWhy::Silent { .. }) {
                                "silence"
                            } else {
                                "swap"
                            },
                            link::endpoint_host(from),
                            if matches!(why, SwapWhy::Silent { .. }) {
                                "; the watchdog's stall line stands behind it"
                            } else {
                                ""
                            }
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
            // The round took real time, and the silent incumbent may have
            // spoken inside it: it keeps its place over a node that merely
            // answered a probe (LINK-Q1). Checked before a single byte of the
            // winner's bind is dialled.
            if self.silent_incumbent_is_back(&mode) {
                return;
            }
            // **A pre-dialled winner waits for the swap** (LINK-Q4): the hunt
            // began at the pre-dial stage, and its winner comes in when the
            // silence reaches the deadline — or the incumbent dies, or the
            // user taps, or the phone's network moves — and not before.
            match self.hold_winner(&mode, &winner.url).await {
                Held::Install => {}
                Held::StandDown => return,
                Held::Stale => continue,
            }
            // **A tap in this round is asked before its winner comes in**
            // (`wallet-security-auditor`, LINK-Q4 round 3; L127, the tap
            // always acts): a moved-network round races its incumbent, so the
            // node a tap asked to leave can win the very round the tap landed
            // in. The loop head re-casts the hunt with it out.
            if self.tap_rules_out(&mode, &winner.url) {
                log::info!(
                    "link: a tap landed while {} won the round — the user asked to leave it; \
                     the hunt races again without it",
                    link::endpoint_host(&winner.url)
                );
                continue;
            }
            // **The hold is an await between the guard above and the bind
            // below, so the guard is asked again** (`wallet-security-auditor`,
            // LINK-Q4 round 1 BLOCK; L73's shape): `install_gate` asks
            // `may_bind_from_race` first, every time the hold wakes and on its
            // last read, and nothing below awaits before the bind — a pin set,
            // or a pause, while the winner was held stands it down; never a
            // public node installed over the user's own.

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
            // can never be confused with the one it replaces. A silence hunt's
            // incumbent leaves as `silence-swap`, so a capture can count the
            // deadline's swaps apart from the user's (recording, not judging).
            // The cause is the hunt's to earn and the silence budget is counted
            // inside, the moment the incumbent is retired (CONCERNS-1, A, A′, C).
            let bind = match self.install_bind_leaving(winner.url.clone(), &mode).await {
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
                    // Died between probe and bind: judged in absentia
                    // (LINK-Q4), then re-race.
                    let text = e.to_string();
                    log::warn!(
                        "link: bind to race winner {} failed: {}",
                        link::endpoint_host(&winner.url),
                        link::sanitize_node_text(&text)
                    );
                    self.judge_bind_failure(&winner.url, bind.gen, &text);
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
                    if let Some(bind) = self.current_bind() {
                        let url = bind.url.clone();
                        // Read BEFORE the retirement ends the page with the
                        // socket (LINK-Q4).
                        let own_load = self.page_explains_silence(&bind);
                        log::info!(
                            "link: watchdog stall confirmed on {host} \
                             (socket silent {silent_secs}s) — executing",
                            host = link::endpoint_host(&url)
                        );
                        // Retirement records the run (cause=watchdog-stall).
                        self.retire_bind("watchdog-stall").await;
                        if own_load {
                            // **A walk page in flight must not convict a
                            // node** (LINK-Q4, item 18, L70): the silence sat
                            // under our own catch-up page. Executed all the
                            // same — thirty seconds is too long for anyone —
                            // and recorded, never charged.
                            self.withhold_strike(&url, link::StrikeReason::OwnLoad);
                        } else {
                            self.set_pending_strike(url, link::StrikeReason::Stall);
                        }
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
                // Counted BEFORE the hunt is asked for: a silence hunt already
                // running reads this and becomes the user's, so the
                // incumbent's comeback can no longer call it off (LINK-Q1,
                // `consensus-auditor` CONCERNS-2).
                self.inner.swaps_asked.fetch_add(1, Ordering::SeqCst);
                // L127 holds unchanged: the tap ALWAYS acts. A hunt already
                // running takes the kick — never a second search authority
                // (D-081), and never a silent no-op.
                if !self.spawn_race_with(RaceMode::Swap {
                    from: from.clone(),
                    why: SwapWhy::Asked,
                }) {
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
        self.hard_reconnect_because("manual-reconnect", "reconnect")
            .await
    }

    /// [`Self::hard_reconnect`], naming its cause: the run-ended line records
    /// `cause`, and the relink's span carries `source`. The wallet lane's
    /// rebind (D-101) goes through here as `lane-dark`, so a capture can tell
    /// it from the user's hand.
    async fn hard_reconnect_because(&self, cause: &str, source: &str) -> Result<()> {
        // A deliberate reconnect must never park a strike against the healthy
        // endpoint it is bouncing (caught live at the V3 sitting: a
        // swipe-to-refresh demoted the innocent incumbent) — retirement
        // records the run and judges nothing.
        //
        // Before R4 this arm pre-cleared `is_connected` so the ctl arm's
        // swap-once guard would skip judging our own teardown. That guard is
        // now structural: the teardown's `Disconnected` arrives on a retired
        // identity, and the gate discards it.
        self.retire_bind(cause).await;
        // The tap always acts (C4). Unpinned that is spawn-or-kick — the old
        // path silently no-opped here whenever a wedged race loop still held
        // the single-flight flag (the dead-Reconnect symptom's second half).
        // Pinned it redials the user's node, which before D-187 this path
        // could not do at all: it retired the bind and then asked a race that
        // pinned mode refuses to run, so Reconnect KILLED a pinned link.
        self.relink(source).await
    }

    /// **The phone's own network changed** (C5/D-089 ruling 4; acted on since
    /// LINK-Q4, D-337 (ii)), relayed from Android's default-network callback
    /// over the platform channel and the bridge as a kind and nothing else.
    ///
    /// - [`NetworkEvent::Lost`]: recorded — the glass names the cause, and the
    ///   stamp survives the recovery for admissibility (R2 D3) — and passive:
    ///   there is no network to dial on, and the socket's own death drives the
    ///   hunt.
    /// - [`NetworkEvent::Available`] / [`NetworkEvent::Moved`]: a new default
    ///   network. Dark → redial now (a race's retry pause is kicked, D-340
    ///   item 9 keeping the pause itself). Live → the socket was dialled on
    ///   the network the phone has left: a hunt behind it on the new one, and
    ///   its winner comes in at once ([`Self::hunt_off_moved_network`]).
    /// - [`NetworkEvent::Changed`]: the link changed in place (addresses, the
    ///   Wi-Fi band). A hint and never the only signal — a roam within one SSID
    ///   can say nothing at all (LINK-Q1's 10:59 band hop) — so it kicks a
    ///   hunt's pause and otherwise leaves the silence clock to decide.
    ///
    /// Paused (backgrounded) → observe, never dial: the battery posture owns
    /// the socket then, and `resume()` re-races. Pinned: there is no other node
    /// to find, so a live pinned socket is left to its own retry loop, as
    /// before; a dark one is relinked.
    pub async fn network_event(&self, event: NetworkEvent) {
        let available = event != NetworkEvent::Lost;
        // Record it for the glass (C7) before deciding what to DO about it.
        self.inner.os_offline.store(!available, Ordering::SeqCst);
        match event {
            NetworkEvent::Lost => {
                // R2 D3: the boolean alone cannot judge admissibility — by
                // the time a parked strike settles, `onAvailable` has usually
                // already flipped it back, erasing the very fact the rule
                // needs. Stamp the TRANSITION so the window survives.
                self.inner
                    .os_lost_at
                    .store(Self::now_unix(), Ordering::SeqCst);
                self.inner
                    .network_lost_pending
                    .store(true, Ordering::SeqCst);
                spans::mark("network_lost");
                log::info!(
                    "link: OS network lost — passive (the socket's own death drives recovery)"
                );
                return;
            }
            NetworkEvent::Changed => {
                spans::mark("network_changed");
                log::info!(
                    "link: OS network changed in place (addresses or Wi-Fi band) — a hint: the \
                     silence clock decides{}",
                    if self.is_searching() {
                        "; a hunt's pause is kicked"
                    } else {
                        ""
                    }
                );
                if self.is_searching() && !self.inner.paused.load(Ordering::SeqCst) {
                    self.kick_race("network-changed");
                }
                return;
            }
            NetworkEvent::Available | NetworkEvent::Moved => {
                // Available after a loss, or a move: any socket up now was
                // dialled on a network the phone has left. Available with no
                // loss before it is the state Android reports as the callback
                // registers (or a repeat), and marks nothing — else the first
                // launch would swap the socket it just bound.
                let lost = self
                    .inner
                    .network_lost_pending
                    .swap(false, Ordering::SeqCst);
                if event == NetworkEvent::Moved || lost {
                    self.inner
                        .network_moved_mono_ms
                        .store(mono_ms(), Ordering::SeqCst);
                    // Round trips measured on the old network rank nothing on
                    // the new one (RFC 8305 §4).
                    self.inner
                        .rtt
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .flush();
                }
            }
        }
        let word = if event == NetworkEvent::Moved {
            "moved"
        } else {
            "available"
        };
        spans::mark(if event == NetworkEvent::Moved {
            "network_moved"
        } else {
            "network_available"
        });
        if self.inner.paused.load(Ordering::SeqCst) {
            log::info!("link: OS network {word} while paused — background posture holds, no dial");
        } else if self.is_connected() {
            let moved_under = self
                .current_bind()
                .is_some_and(|bind| self.network_moved_under(&bind));
            if !moved_under {
                log::info!(
                    "link: OS network {word} while connected — the socket is on it; no action"
                );
            } else if self.is_pinned() {
                log::info!(
                    "link: OS network {word} while connected to the pinned node — its own retry \
                     loop owns the socket"
                );
            } else {
                self.hunt_off_moved_network();
            }
        } else {
            log::info!("link: OS network {word} while disconnected — dialling now");
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
    /// clocks: the Dart watchdog's tick-age is process-lifetime, so after a
    /// link blackout it reads stale silence against a seconds-old socket.
    /// The evidence baseline is `max(last_tick_at, connected_at)` — a socket
    /// cannot be guilty of silence older than itself.
    /// R4 sharpens it further: both halves of the baseline are now the ACCUSED
    /// SOCKET's own (`BoundSocket::last_tick_at` / `connected_at`), so a tick
    /// delivered by a previous socket can neither excuse nor condemn this one.
    /// Since LINK-Q1 the evidence is the DAA tick, not the block — see
    /// [`link::WATCHDOG_STALL_SECS`] for exactly what that moved.
    fn stall_verdict(&self) -> StallVerdict {
        let Some(bind) = self.current_bind() else {
            return StallVerdict::Hunting;
        };
        if !self.is_connected() {
            return StallVerdict::Hunting;
        }
        let now = Self::now_unix();
        let baseline = bind
            .last_tick_at
            .load(Ordering::Relaxed)
            .max(bind.connected_at.load(Ordering::Relaxed));
        let silent_secs = now.saturating_sub(baseline);
        if baseline != 0 && silent_secs > link::WATCHDOG_STALL_SECS {
            StallVerdict::Execute { silent_secs }
        } else {
            StallVerdict::Refuse { silent_secs }
        }
    }

    /// **Record that the socket's heartbeat beat** — one DAA tick
    /// (`VirtualDaaScoreChanged`) arrived on it. Two clocks, two purposes (R4):
    /// the socket's own is the evidence a stall claim is judged against, the
    /// process-wide one is how old the glass's data is; the counts feed the
    /// silence hunt's stand-down and the node screen's rate.
    ///
    /// **The heartbeat moved here from `BlockAdded` at LINK-Q1 (D-334).** Full
    /// blocks are the stream LINK-Q2 may reshape, and a watchdog welded to them
    /// would have gone blind the day they were gated (IDEAS_BACKLOG's "rides
    /// the most expensive subscription"). The tick is the one notification
    /// every shape keeps — the pin's own wallet subscribes to nothing but it
    /// and `UtxosChanged` — and it is the signal the lamp already read, so the
    /// watchdog, the silence deadline, the node screen and the glass now beat
    /// to ONE clock instead of two that could disagree.
    fn mark_tick(&self, bind: &BoundSocket) {
        let now = Self::now_unix();
        let mono = mono_ms();
        bind.last_tick_at.store(now, Ordering::Relaxed);
        bind.last_tick_mono_ms.store(mono, Ordering::Relaxed);
        bind.ticks.fetch_add(1, Ordering::SeqCst);
        bind.swap_due.store(false, Ordering::SeqCst);
        self.inner.last_tick_at.store(now, Ordering::Relaxed);
        self.inner.daa_ticks.fetch_add(1, Ordering::Relaxed);
        // D-334's witness, re-aimed at the message walk (LINK-Q3): ticking
        // while no page is answered says so once per stretch, no verdict.
        self.inner.walk.note_ticks(
            link::endpoint_host(&bind.url),
            bind.connected_mono_ms.load(Ordering::Relaxed),
            mono,
        );
        self.inner.devab.on_tick(mono);
    }

    /// Seconds since the last DAA tick, or `None` if none has arrived yet
    /// (fresh boot / never connected). The watchdog's honest-liveness reading:
    /// a healthy mainnet keeps this near zero; a stalled socket lets it grow.
    /// It read the last BLOCK until LINK-Q1 (D-334).
    pub fn last_tick_age_secs(&self) -> Option<u64> {
        let last = self.inner.last_tick_at.load(Ordering::Relaxed);
        if last == 0 {
            return None;
        }
        Some(Self::now_unix().saturating_sub(last))
    }

    /// Every DAA tick an installed socket has delivered in this process — a
    /// monotonic count the node screen differences against its own clock to
    /// show the link's beat as a rate (D-332). Public chain liveness, no I/O.
    pub fn daa_ticks(&self) -> u64 {
        self.inner.daa_ticks.load(Ordering::Relaxed)
    }

    /// **A silence hunt's incumbent is talking again** — then the hunt has
    /// nothing to replace, and says so on its way out (LINK-Q1). `false` for
    /// every other mode: a hunt the user asked for is not called off by the
    /// node they asked to leave.
    fn silent_incumbent_is_back(&self, mode: &RaceMode) -> bool {
        let RaceMode::Swap {
            from,
            why: SwapWhy::Silent { gen, ticks, asked },
        } = mode
        else {
            return false;
        };
        // A tap landed while this hunt ran: it is the user's hunt now, and
        // they asked to LEAVE the incumbent, not to wait for it
        // (`consensus-auditor` CONCERNS-2 — L127, the tap always acts).
        if self.silence_hunt_was_asked(*asked) {
            return false;
        }
        let Some(bind) = self.current_bind().filter(|bind| bind.gen == *gen) else {
            // The incumbent is gone (retired, died): `degrade_lost_swap` turns
            // the errand into the ordinary hunt at the next loop head.
            return false;
        };
        // Its ticks come over a network the phone has left (LINK-Q4): they
        // say nothing about the link it is on now.
        if self.network_moved_under(&bind) {
            return false;
        }
        let quiet = Duration::from_millis(
            mono_ms().saturating_sub(bind.last_tick_mono_ms.load(Ordering::Relaxed)),
        );
        if !link::silent_incumbent_spoke_again(bind.ticks.load(Ordering::SeqCst), *ticks, quiet) {
            return false;
        }
        log::info!(
            "link: {} spoke again — the silence hunt stands down and keeps it",
            link::endpoint_host(from)
        );
        spans::mark_with("silence_kept", link::endpoint_host(from));
        true
    }

    /// **May a race's winner come in now?** (LINK-Q4.) `Some(Held::Install)`
    /// for every mode but a silence hunt still silence's own; for that one,
    /// `StandDown` if its incumbent spoke again, `Install` if the swap stage
    /// has fallen on it, it is gone, a tap has made the hunt the user's, or
    /// the phone's default network has moved since the hunt began — else
    /// `None`: keep holding.
    fn install_gate(&self, mode: &RaceMode) -> Option<Held> {
        // A pin, a pause or a stop ends the errand, whatever it held: asked
        // here on every wake of the hold and on its last read, with no await
        // between that read and the bind — the one guard the hold needs.
        if !self.may_bind_from_race(mode) {
            return Some(Held::StandDown);
        }
        let RaceMode::Swap {
            why: SwapWhy::Silent { gen, .. },
            ..
        } = mode
        else {
            return Some(Held::Install);
        };
        if self.joined_by_tap(mode).is_some() {
            return Some(Held::Install);
        }
        if self.silent_incumbent_is_back(mode) {
            return Some(Held::StandDown);
        }
        let incumbent = self.current_bind().filter(|bind| bind.gen == *gen);
        let Some(bind) = incumbent.filter(|_| self.is_connected()) else {
            // Gone: the wallet is dark, and the winner in hand is the fastest
            // way back.
            return Some(Held::Install);
        };
        if bind.swap_due.load(Ordering::SeqCst) || self.network_moved_under(&bind) {
            return Some(Held::Install);
        }
        None
    }

    /// **Hold a pre-dialled winner until [`Self::install_gate`] lets it in**
    /// (LINK-Q4). Woken by the race kick — the swap stage kicks the hunt that
    /// holds the single-flight flag, and so do a tap and a network event — and
    /// otherwise re-read every [`HOLD_POLL`]. Bounded: a winner held past the
    /// pre-dial's lead and one more deadline is stale, and the hunt probes
    /// again.
    async fn hold_winner(&self, mode: &RaceMode, winner: &str) -> Held {
        let started = tokio::time::Instant::now();
        let limit = link::PREDIAL_LEAD + self.silence_deadline().unwrap_or(link::SILENCE_DEADLINE);
        let mut said = false;
        loop {
            if let Some(held) = self.install_gate(mode) {
                return held;
            }
            if started.elapsed() >= limit {
                log::info!(
                    "link: held {} for {}s and the swap never fell — its probe is stale, probing \
                     again",
                    link::endpoint_host(winner),
                    limit.as_secs()
                );
                return Held::Stale;
            }
            if !said {
                said = true;
                if let RaceMode::Swap { from, .. } = mode {
                    log::info!(
                        "link: {} answered — held behind {} until its silence reaches the \
                         deadline",
                        link::endpoint_host(winner),
                        link::endpoint_host(from)
                    );
                }
            }
            tokio::select! {
                _ = tokio::time::sleep(HOLD_POLL) => {}
                _ = self.inner.race_kick.notified() => {}
            }
        }
    }

    /// Did a user tap land after a silence hunt that began at tap-count
    /// `asked`? Then the hunt is theirs.
    fn silence_hunt_was_asked(&self, asked: u64) -> bool {
        self.inner.swaps_asked.load(Ordering::SeqCst) != asked
    }

    /// **Install a race's winner, retiring the incumbent under the cause its
    /// hunt earned** ([`Self::retire_cause`]) — the winner arm's one call, so
    /// the choice and the silence budget it feeds are driven together by the
    /// teardown test (`consensus-auditor` third delta, CONCERNS-C: a cause
    /// picked in the arm itself could be switched off with every test green).
    async fn install_bind_leaving(&self, url: String, mode: &RaceMode) -> Result<Arc<BoundSocket>> {
        self.install_bind_after(url, self.retire_cause(mode)).await
    }

    /// [`swap_hunt_exhausted`], asked of the live monitor — the race loop's
    /// one call, reading the incumbent's liveness and a joined tap itself, so
    /// that call site holds no free argument a test cannot reach
    /// (`consensus-auditor` third delta, CONCERNS-C).
    fn swap_hunt_spent(&self, mode: &RaceMode, empty_rounds: u32) -> bool {
        swap_hunt_exhausted(
            mode,
            empty_rounds,
            self.is_connected(),
            self.joined_by_tap(mode).is_some() || self.recast_if_moved(mode).is_some(),
        )
    }

    /// A swap hunt whose incumbent is on a network the phone has left, re-cast
    /// as the moved-network hunt — `None` for one that already is, a cold hunt,
    /// or an incumbent still on the phone's network (LINK-Q4).
    fn recast_if_moved(&self, mode: &RaceMode) -> Option<RaceMode> {
        let RaceMode::Swap { from, why } = mode else {
            return None;
        };
        if matches!(why, SwapWhy::Moved { .. }) {
            return None;
        }
        let bind = self
            .current_bind()
            .filter(|bind| bind.url == *from && self.network_moved_under(bind))?;
        Some(RaceMode::Swap {
            from: from.clone(),
            why: SwapWhy::Moved {
                gen: bind.gen,
                // A silence hunt's own count carries over, so a tap landing
                // between the loop head's two reads is still heard at the
                // next (`wallet-security-auditor`, round 3 note).
                asked: match why {
                    SwapWhy::Silent { asked, .. } => *asked,
                    _ => self.inner.swaps_asked.load(Ordering::SeqCst),
                },
                // The user's own swap keeps its "leave this node" through
                // the move; a silence hunt was never the user's (a tap would
                // have re-cast it as theirs first, at the loop head).
                tapped: matches!(why, SwapWhy::Asked),
            },
        })
    }

    /// The cause a race's winner retires its incumbent under: [`SILENCE_SWAP`]
    /// while the hunt is still silence's own, `superseded` for everything
    /// else — a tap's swap, a silence hunt a tap has since joined (CONCERNS-2),
    /// a cold hunt with nothing to retire.
    fn retire_cause(&self, mode: &RaceMode) -> &'static str {
        // A silence hunt whose incumbent's network moved while its winner was
        // held leaves for the move, not the silence: no budget spent, no page
        // counted against the link (`consensus-auditor`, round 1 note).
        if let RaceMode::Swap {
            why: SwapWhy::Silent { asked, .. },
            ..
        } = mode
        {
            if !self.silence_hunt_was_asked(*asked)
                && self
                    .current_bind()
                    .is_some_and(|bind| self.network_moved_under(&bind))
            {
                return NETWORK_SWAP;
            }
        }
        match mode {
            RaceMode::Swap {
                why: SwapWhy::Silent { asked, .. },
                ..
            } if !self.silence_hunt_was_asked(*asked) => SILENCE_SWAP,
            RaceMode::Swap {
                why: SwapWhy::Moved { .. },
                ..
            } => NETWORK_SWAP,
            _ => "superseded",
        }
    }

    /// **Is `bind` on a network the phone has left?** (LINK-Q4.) It was
    /// published before the default network last moved or came back
    /// ([`NetworkEvent::Moved`] / [`NetworkEvent::Available`]). Android
    /// destroys a socket whose address goes, but not always at once, and a
    /// cellular socket outlives Wi-Fi's return until the old network's linger
    /// ends — billing the user's data the while.
    fn network_moved_under(&self, bind: &BoundSocket) -> bool {
        let moved = self.inner.network_moved_mono_ms.load(Ordering::SeqCst);
        moved != 0 && moved > bind.connected_mono_ms.load(Ordering::Relaxed)
    }

    /// **The phone's network moved under the live socket: find a node on the
    /// new one behind it, and let it in at once** (LINK-Q4, D-337 (ii)). A
    /// hunt already running takes the kick — a pre-dial's gate then lets its
    /// winner in, a user's swap was going to anyway.
    fn hunt_off_moved_network(&self) {
        let Some(bind) = self.current_bind() else {
            return;
        };
        let host = link::endpoint_host(&bind.url);
        let mode = RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Moved {
                gen: bind.gen,
                asked: self.inner.swaps_asked.load(Ordering::SeqCst),
                tapped: false,
            },
        };
        if self.spawn_race_with(mode) {
            log::info!(
                "link: the phone's network moved under {host} — finding a node on the new one \
                 behind it; the first that answers comes in"
            );
            spans::mark_with("network_hunt", host);
        } else if !self.is_pinned() {
            self.kick_race("network-moved");
        }
    }

    /// Does the hunt a tap has since made of `mode` keep `winner` out? Only a
    /// moved-network round races its own incumbent, so only there can a tap
    /// rule out the node that just won (see the winner arm).
    fn tap_rules_out(&self, mode: &RaceMode, winner: &str) -> bool {
        self.joined_by_tap(mode)
            .is_some_and(|theirs| round_exclusions(HashSet::new(), &theirs).contains(winner))
    }

    /// A silence hunt a tap has since joined, re-cast as the swap the user
    /// asked for — `None` while it is still silence's own, or was never one.
    fn joined_by_tap(&self, mode: &RaceMode) -> Option<RaceMode> {
        match mode {
            RaceMode::Swap {
                from,
                why: SwapWhy::Silent { asked, .. },
            } if self.silence_hunt_was_asked(*asked) => Some(RaceMode::Swap {
                from: from.clone(),
                why: SwapWhy::Asked,
            }),
            // A tap into the moved-network hunt: the user wants off the node
            // too, so it stays out of the race from the next round, with
            // rounds of its own (`wallet-security-auditor`, round 2).
            RaceMode::Swap {
                from,
                why:
                    SwapWhy::Moved {
                        gen,
                        asked,
                        tapped: false,
                    },
            } if self.silence_hunt_was_asked(*asked) => Some(RaceMode::Swap {
                from: from.clone(),
                why: SwapWhy::Moved {
                    gen: *gen,
                    asked: self.inner.swaps_asked.load(Ordering::SeqCst),
                    tapped: true,
                },
            }),
            _ => None,
        }
    }

    /// The silence deadline as the budget stands now — nine seconds, eighteen
    /// after one silence swap the link has not yet held through, off after two
    /// ([`link::silence_deadline_after`]).
    fn silence_deadline(&self) -> Option<Duration> {
        link::silence_deadline_after(self.inner.silence_backoff.load(Ordering::SeqCst))
    }

    /// A silence swap landed: the next socket's deadline doubles until the
    /// link holds ([`link::SILENCE_HOLD_RESET`]) — `consensus-auditor`
    /// CONCERNS-1's budget, so swaps cannot chain every ten seconds forever.
    fn note_silence_swap_landed(&self) {
        let landed = self
            .inner
            .silence_backoff
            .fetch_add(1, Ordering::SeqCst)
            .saturating_add(1);
        match link::silence_deadline_after(landed) {
            Some(next) => log::info!(
                "link: a silence swap landed — the next silence deadline is {}s until the \
                 link holds for {}s",
                next.as_secs(),
                link::SILENCE_HOLD_RESET.as_secs()
            ),
            None => log::info!(
                "link: {landed} silence swaps without the link holding — the deadline is \
                 off, and the watchdog's stall line owns a silence until the link holds \
                 for {}s",
                link::SILENCE_HOLD_RESET.as_secs()
            ),
        }
    }

    /// A socket stayed up a clean [`link::SILENCE_HOLD_RESET`] — no quiet
    /// spell of the base deadline in it: the link HELD, and the silence
    /// deadline is nine seconds again.
    fn note_link_held(&self, bind: &BoundSocket) {
        if self.inner.silence_backoff.swap(0, Ordering::SeqCst) > 0 {
            log::info!(
                "link: {} held for {}s — the silence deadline is back to {}s",
                link::endpoint_host(&bind.url),
                link::SILENCE_HOLD_RESET.as_secs(),
                link::SILENCE_DEADLINE.as_secs()
            );
        }
    }

    /// **The silence deadline fired on this socket** (LINK-Q1, D-334): it has
    /// gone its deadline ([`Self::silence_deadline`] — nine seconds unless the
    /// budget has stretched it) without a DAA tick — never scored, or stopped.
    /// Start the bounded find-then-swap hunt behind it.
    ///
    /// Not a verdict, so it does nothing a verdict does: no teardown, no
    /// strike, no run recorded. The socket stays up and keeps its place unless
    /// a different node answers a probe before it speaks again; conviction
    /// stays the watchdog's, on its 30 s evidence. Pinned, there is no other
    /// node to find — the watchdog's hard path owns a silent pinned socket.
    fn on_silence(&self, bind: &Arc<BoundSocket>, scored: bool, after: Duration) {
        if !self.is_current_bind(bind.gen)
            || !self.is_connected()
            || !bind.announced.load(Ordering::SeqCst)
            || self.inner.paused.load(Ordering::SeqCst)
        {
            return;
        }
        // A winner the pre-dial is holding may come in now (LINK-Q4).
        bind.swap_due.store(true, Ordering::SeqCst);
        let host = link::endpoint_host(&bind.url);
        let after = after.as_secs();
        let silence = if scored {
            "since its last tick"
        } else {
            "since it connected, having delivered no tick"
        };
        if self.is_pinned() {
            log::info!(
                "link: {host} silent {after}s {silence} — pinned, so there is no other node \
                 to find; the watchdog's stall line owns it"
            );
            return;
        }
        log::info!(
            "link: {host} silent {after}s {silence} — hunting for a replacement behind it \
             (silence deadline); it keeps its place if it speaks first"
        );
        spans::mark_with("silence_hunt", host);
        let mode = RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Silent {
                gen: bind.gen,
                ticks: bind.ticks.load(Ordering::SeqCst),
                asked: self.inner.swaps_asked.load(Ordering::SeqCst),
            },
        };
        // One search authority (D-081). A hunt already running — the user's
        // own swap — takes the kick; it is looking for the same thing.
        if !self.spawn_race_with(mode) {
            self.kick_race("silence");
        }
    }

    /// **The pre-dial stage fell on this socket** (LINK-Q4, D-337 (ii)): it
    /// has been silent [`link::predial_after`] the deadline — 3 s at the base
    /// nine. Start the same bounded hunt the deadline starts, behind the
    /// socket, but it HOLDS its winner until the swap stage (or the socket
    /// dies, or the user taps, or the phone's network moves), and stands down
    /// if the socket speaks again. Not a verdict either: no teardown, no
    /// strike. A hunt already running is left to run — it is looking for the
    /// same thing, and the swap stage kicks it when it falls.
    fn on_silence_predial(&self, bind: &Arc<BoundSocket>, scored: bool, after: Duration) {
        if !self.is_current_bind(bind.gen)
            || !self.is_connected()
            || !bind.announced.load(Ordering::SeqCst)
            || self.inner.paused.load(Ordering::SeqCst)
            || self.is_pinned()
        {
            return;
        }
        let host = link::endpoint_host(&bind.url);
        let silence = if scored {
            "since its last tick"
        } else {
            "since it connected, having delivered no tick"
        };
        let mode = RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Silent {
                gen: bind.gen,
                ticks: bind.ticks.load(Ordering::SeqCst),
                asked: self.inner.swaps_asked.load(Ordering::SeqCst),
            },
        };
        if self.spawn_race_with(mode) {
            log::info!(
                "link: {host} silent {:.1}s {silence} — pre-dialling a replacement behind it; it \
                 comes in at the silence deadline, and {host} keeps its place if it speaks first",
                after.as_secs_f64()
            );
            spans::mark_with("silence_predial", host);
        }
    }

    /// Our own catch-up page may be what holds this socket's ticks back:
    /// both stages moved one deadline later, once (LINK-Q4).
    fn note_silence_extended(&self, bind: &BoundSocket, after: Duration, deadline: Duration) {
        log::info!(
            "link: {} silent {:.1}s under our own catch-up page — its silence stages wait one more \
             {}s (the page is our load, not the node's)",
            link::endpoint_host(&bind.url),
            after.as_secs_f64(),
            deadline.as_secs()
        );
    }

    /// **Could our own page in flight explain this socket's silence?**
    /// (LINK-Q4, `consensus-auditor` item 18, L70.) A catch-up page ([`walk::
    /// PageInFlight::catch_up`]) went out on THIS socket, and the socket ticked
    /// after it went out — so it was alive under the page, and a large reply
    /// on a weak link holds every notification behind it on the one socket.
    /// A socket that was already silent when the page went out (`ivy` deaf at
    /// 23:59:17, the walk's first page at 23:59:22, LINK-Q3's capture) is not
    /// explained by it, and neither is one that never ticked, nor a tip page.
    fn page_explains_silence(&self, bind: &BoundSocket) -> bool {
        let Some(page) = self.inner.walk.page_in_flight() else {
            return false;
        };
        let last_tick = bind.last_tick_mono_ms.load(Ordering::Relaxed);
        page.catch_up
            && page.socket == Some(Arc::as_ptr(&bind.client) as usize)
            && last_tick != 0
            && page.sent_mono_ms <= last_tick
    }

    /// The installed bind, if it is up and announced to consumers — the only
    /// kind the wallet lane negotiates on — as (gen, publish epoch): the
    /// PHYSICAL socket, which a pinned bind's redial changes under one gen.
    /// `None` between binds, while paused, and for a bind still coming up.
    fn announced_live_socket(&self) -> Option<(u64, u64)> {
        if self.inner.paused.load(Ordering::SeqCst) || !self.is_connected() {
            return None;
        }
        self.inner
            .bound
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .filter(|bind| bind.announced.load(Ordering::SeqCst))
            .map(|bind| (bind.gen, bind.publishes.load(Ordering::SeqCst)))
    }

    /// The re-announces the socket `(gen, publish epoch)` has had, while it is
    /// still the one bound; `None` once it is not. Nonzero exactly when a
    /// check has PROVEN the lane dark on it — the proof and the first
    /// re-announce are one step under the lock ([`Self::reannounce_to_wallet_lane`]).
    fn socket_reannounces(&self, socket: (u64, u64)) -> Option<u32> {
        if self.announced_live_socket() != Some(socket) {
            return None;
        }
        self.inner
            .bound
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .filter(|bind| (bind.gen, bind.publishes.load(Ordering::SeqCst)) == socket)
            .map(|bind| bind.lane_reannounced.load(Ordering::SeqCst))
    }

    /// **Prove the lane dark on `socket`, then re-announce it to the wallet
    /// lane** — one more `Connected` on the monitor's ctl, which makes the
    /// processor renegotiate on the same socket through its own task (see
    /// [`LANE_REANNOUNCE_AFTER`] for the pin reading). Under the ONE lock
    /// retirement and a publish take, so the ctl never says "open" about a
    /// socket a retirement or a publish has already replaced, and the proof
    /// the pull keys on can never outlive the physical socket it is about: a
    /// pinned redial's publish zeroes it under this same lock (`consensus-
    /// auditor` delta NOTE 2). A pinned DROP stands the link down without
    /// this lock, so an open here can follow its close; the proof no longer
    /// depends on that order, and the worst case is one negotiation that fails
    /// and reads `SocketGone` (`wallet-security-auditor`, fourth delta).
    fn reannounce_to_wallet_lane(&self, socket: (u64, u64)) -> Reannounce {
        if self.inner.paused.load(Ordering::SeqCst) {
            return Reannounce::SocketGone;
        }
        let (gen, _) = socket;
        let bound = self
            .inner
            .bound
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(bind) = bound.as_ref().filter(|bind| {
            (bind.gen, bind.publishes.load(Ordering::SeqCst)) == socket
                && bind.announced.load(Ordering::SeqCst)
                && self.inner.is_connected.load(Ordering::SeqCst)
        }) else {
            return Reannounce::SocketGone;
        };
        // Dark on this live socket, seconds after an error: PROVEN — the
        // first re-announce below IS the proof the pull's hard path keys on
        // ([`Self::wallet_lane_known_dark`] reads this socket's own count), so
        // it is born, counted and cleared with the physical socket, under
        // this lock, and no separate record can outlive it.
        // **Two reports start a check** since PRE3-LANE: a processor error,
        // and the wallet lane's supervisor finding an open unanswered past
        // `LANE_STEP_WITHIN` while its negotiation is still out. In the second
        // case the lane's relay holds this re-announce until that open is
        // acknowledged (strict alternation, `wallet_lane.rs`), so a lane that
        // comes up next was answered by the open it was already running: a
        // `Recovered { reannounced: n }` then counts re-announces the processor
        // had not yet read. Nothing but `GaveUp` changes the lane's state;
        // the count is evidence, read with this in mind.
        // **The budget is the SOCKET's** (`wallet-security-auditor`): a
        // negotiation that hangs to the wRPC timeout fails after the check
        // that retried it has ended, and that echo starts a new check — which
        // must find this socket's re-announces already spent, not two fresh
        // ones, or a node that ticks but never answers is retried about once
        // a minute forever.
        let spent = bind.lane_reannounced.load(Ordering::SeqCst);
        let budget = u32::try_from(LANE_REANNOUNCE_AFTER.len()).unwrap_or(u32::MAX);
        if spent >= budget {
            return Reannounce::BudgetSpent;
        }
        bind.lane_reannounced.store(spent + 1, Ordering::SeqCst);
        // PB-020: the intent is on record before the act. None of OUR handlers
        // hears this edge — the bind's own task listens to its CLIENT's ctl,
        // not this one — and the processor, which does, acts on it only while
        // its own negotiation has not succeeded.
        log::info!(
            "link: wallet lane dark on a live socket (bind gen={gen}, {}) — re-announcing it \
             to the processor, {}/{budget} for this socket (D-101 recovery)",
            link::endpoint_host(&bind.url),
            spent + 1
        );
        spans::mark_with("lane_reannounce", link::endpoint_host(&bind.url));
        let _ = self.inner.monitor_ctl.try_signal_open();
        Reannounce::Done
    }

    /// Did the wallet-lane recovery PROVE the lane dark on the physical socket
    /// bound right now? The pull's hard path asks this, never the processor's
    /// bit alone — that bit is also false for the sub-second of every healthy
    /// socket's first negotiation (`consensus-auditor` note a). The proof is
    /// the socket's own re-announce count, so nothing can hold it past the
    /// socket: not a retirement, not a pinned redial's publish (which zeroes
    /// the count under the lock), not a pinned drop — which leaves no
    /// announced live socket to ask about (`wallet-security-auditor`, third
    /// delta NOTE 1: a separate proof record outlived that drop).
    pub fn wallet_lane_known_dark(&self) -> bool {
        self.announced_live_socket()
            .and_then(|socket| self.socket_reannounces(socket))
            .is_some_and(|reannounced| reannounced > 0)
    }

    /// Attach the wallet engine's answers (PRE3-LANE). The bridge's engine
    /// does this at `attach_link`, before it starts.
    pub fn attach_wallet_lane(&self, hooks: Arc<dyn WalletLaneHooks>) {
        *self
            .inner
            .wallet_lane
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(hooks);
    }

    fn wallet_lane_hooks(&self) -> Option<Arc<dyn WalletLaneHooks>> {
        self.inner
            .wallet_lane
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    /// Is the wallet lane dead (its supervisor said so, no rebuild yet)?
    fn wallet_lane_dead(&self) -> bool {
        self.wallet_lane_hooks()
            .is_some_and(|hooks| hooks.lane_dead())
    }

    /// The rebuild, run inside the flight.
    async fn rebuild_wallet_lane(&self) -> LaneRecovery {
        match self.wallet_lane_hooks() {
            Some(hooks) => hooks.rebuild().await,
            None => LaneRecovery::NotDark,
        }
    }

    /// **The wallet lane's recovery (D-101's deferred arm, owed since
    /// LINK-Q1).** Called when the wallet processor reports an error; decides,
    /// from evidence, whether the lane is actually dark on a socket that stayed
    /// bound, and only then acts: two re-announces of the same socket, then one
    /// rebind — at most one per [`LANE_REBIND_WINDOW_SECS`] — then it stops and
    /// says so. `lane_up` is the processor's own "negotiated" bit.
    ///
    /// **What the evidence said before this was built** (CONN-F1's 14-day
    /// capture): all five `UtxoProcError`s were negotiations that died WITH
    /// their socket — two dropped 0.2 s after connecting, three deaf sockets
    /// retired at 31–37 s — and every next socket renegotiated in ~2 s by
    /// itself. Those are [`LaneRecovery::SocketGone`] here, decided in the
    /// first instant and logged as benign. The case this exists for — the
    /// lane dark behind a live socket, where the pull's soft path cannot
    /// re-arm the processor and a swap that finds nothing leaves it dark — has
    /// not been seen, and would otherwise be silent: the balance at full
    /// brightness, no live deposits.
    ///
    /// Single-flight, and the flag is released by a guard, so a cancelled run
    /// can never wedge every later one out. **Coalescing, not dropping**: a
    /// report that finds a check running leaves a request the running check
    /// drains before it lets go — one pass covers only the socket it began on,
    /// so the report of a successor that negotiated dark while its
    /// predecessor's check was still asleep would otherwise never be checked,
    /// leaving the exact silent dark lane this exists to catch
    /// (`wallet-security-auditor`). It ends: each extra pass answers a new
    /// processor error, and those are bounded per socket (two re-announces,
    /// so three negotiations) and, across sockets, by one rebind per window.
    pub async fn recover_wallet_lane<F>(&self, lane_up: F) -> LaneRecovery
    where
        F: Fn() -> bool + Sync,
    {
        struct Release<'a>(&'a AtomicBool);
        impl Drop for Release<'_> {
            fn drop(&mut self) {
                self.0.store(false, Ordering::SeqCst);
            }
        }
        // A report with the lane UP has nothing to check — the notification
        // handler's error (`processor.rs:747`: a node sending a malformed
        // `UtxosChanged`), or a negotiation already retried. Answered at the
        // door, with no queued pass and no log line, so a node-paced burst of
        // them costs the RECOVERY nothing (`wallet-security-auditor`, item
        // 22's rider) — the engine's arm still logs each and spawns this call.
        //
        // **A dead lane is never "up"** (PRE3-LANE): a processor that panicked
        // while connected keeps reading connected — nothing clears its bit —
        // so the door asks the lane's supervisor too.
        if lane_up() && !self.wallet_lane_dead() {
            return LaneRecovery::NotDark;
        }
        // The request is on record BEFORE anyone decides who serves it. Whoever
        // holds the flag re-reads it after letting go, so a report landing
        // between the last drain and the release is still served (all SeqCst:
        // a report that saw the flag held stored its request first).
        self.inner.lane_report_pending.store(true, Ordering::SeqCst);
        let mut outcome = LaneRecovery::Queued;
        loop {
            if self.inner.lane_recovering.swap(true, Ordering::SeqCst) {
                if outcome == LaneRecovery::Queued {
                    log::info!(
                        "link: a wallet-lane check is already running — this report is queued \
                         behind it (D-101)"
                    );
                }
                return outcome;
            }
            {
                let _release = Release(&self.inner.lane_recovering);
                while self.inner.lane_report_pending.swap(false, Ordering::SeqCst) {
                    outcome = self.recover_wallet_lane_once(&lane_up).await;
                    log::info!("link: wallet-lane check → {outcome:?} (D-101)");
                }
            }
            if !self.inner.lane_report_pending.load(Ordering::SeqCst) {
                return outcome;
            }
        }
    }

    async fn recover_wallet_lane_once(&self, lane_up: &(dyn Fn() -> bool + Sync)) -> LaneRecovery {
        // A dead lane first: re-announcing to a task that is gone, or stuck,
        // would only spend the socket's budget (PRE3-LANE).
        if self.wallet_lane_dead() {
            return self.rebuild_wallet_lane().await;
        }
        if lane_up() {
            return LaneRecovery::NotDark;
        }
        let Some(socket) = self.announced_live_socket() else {
            log::info!(
                "link: the wallet lane's negotiation died with its socket — the next bind \
                 renegotiates on its own; nothing to recover (D-101)"
            );
            return LaneRecovery::SocketGone;
        };
        let (gen, _) = socket;
        // **What the lane coming up means depends on where** (`consensus-
        // auditor` delta notes f and 1, `wallet-security-auditor` delta NOTE).
        // Up on another physical socket — a successor, or a pinned redial
        // under the same gen — the negotiation died with its own socket:
        // `SocketGone`. Up on THIS one before any check proved it dark, it was
        // never dark here: the processor renegotiates only on a `Connected`
        // (pin `:717-718`), which only a publish (a new socket) or a
        // re-announce sends, so what came up was a negotiation still in flight
        // when this pass began — a queued report's pass can begin on a
        // successor that never reported (`NotDark`). Only a socket proven dark
        // and then up is a recovery.
        let settled = |reannounced| match self.socket_reannounces(socket) {
            None => LaneRecovery::SocketGone,
            Some(0) => LaneRecovery::NotDark,
            Some(_) => LaneRecovery::Recovered { reannounced },
        };
        let mut reannounced = 0u32;
        for wait in LANE_REANNOUNCE_AFTER {
            tokio::time::sleep(wait).await;
            if self.wallet_lane_dead() {
                return self.rebuild_wallet_lane().await;
            }
            if lane_up() {
                return settled(reannounced);
            }
            match self.reannounce_to_wallet_lane(socket) {
                Reannounce::Done => reannounced += 1,
                Reannounce::SocketGone => return LaneRecovery::SocketGone,
                // This socket already had its re-announces (an earlier
                // check's echo brought us here): straight to rebind-or-stop.
                Reannounce::BudgetSpent => break,
            }
        }
        tokio::time::sleep(LANE_SETTLE).await;
        if self.wallet_lane_dead() {
            return self.rebuild_wallet_lane().await;
        }
        if lane_up() {
            return settled(reannounced);
        }
        if self.announced_live_socket() != Some(socket) {
            return LaneRecovery::SocketGone;
        }
        let now = Self::now_unix();
        let last = self.inner.lane_rebound_at.load(Ordering::SeqCst);
        if last != 0 && now.saturating_sub(last) < LANE_REBIND_WINDOW_SECS {
            log::warn!(
                "link: wallet lane still dark on bind gen={gen} after this socket's \
                 re-announces, and this window's rebind is spent (one per \
                 {LANE_REBIND_WINDOW_SECS}s) — left to the next drop, pull or tap (D-101)"
            );
            return LaneRecovery::GaveUp;
        }
        self.inner.lane_rebound_at.store(now, Ordering::SeqCst);
        log::warn!(
            "link: wallet lane still dark on bind gen={gen} after this socket's re-announces \
             — rebinding (D-101 escalation)"
        );
        // The hard path, not a swap (D-213 §2's doctrine): what the lane needs
        // is a NEW socket whose `Connected` makes the processor negotiate
        // afresh, and a swap that found nothing would keep the socket that
        // cannot serve it. No strike — recording is not judging.
        if let Err(e) = self.hard_reconnect_because("lane-dark", "lane-dark").await {
            log::warn!(
                "link: the wallet lane's rebind failed to start: {}",
                link::sanitize_node_text(&e.to_string())
            );
        }
        LaneRecovery::Rebound
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
    ///
    /// **It also keeps this socket's silence deadline** (LINK-Q1, D-334): the
    /// task is the only place this socket's ticks are folded, so it owns the
    /// [`SilenceClock`] outright — armed by the accepted `Connected`, re-armed
    /// by every DAA tick, disarmed by a drop or retirement. Ticks are polled
    /// ahead of the deadline (`biased`), so a tick that lands as the deadline
    /// falls wins: the incumbent speaking is exactly what keeps its place.
    async fn bind_loop(
        self,
        bind: Arc<BoundSocket>,
        ctl_rx: async_channel::Receiver<RpcState>,
        retire_rx: oneshot::Receiver<()>,
    ) {
        let mut retire_rx = retire_rx;
        // `Some(deadline)` once this bind has been retired.
        let mut exit_at: Option<tokio::time::Instant> = None;
        let mut silence = SilenceClock::default();
        // The round-trip probe's cadence (LINK-Q4); a slow answer skips
        // turns rather than stacking them.
        let mut probe_every = tokio::time::interval(link::RTT_PROBE_EVERY);
        probe_every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            // The deadline as the budget stands NOW — re-read every turn, so a
            // swap that landed elsewhere, or a link that held, is honoured.
            let deadline = self.silence_deadline();
            let silence_next = silence.next(deadline);
            tokio::select! {
                // Poll order matters (biased): drain ctl + notifications
                // before honoring the exit, mirroring the upstream example.
                biased;
                msg = ctl_rx.recv() => {
                    match msg {
                        Ok(state) if !self.is_current_bind(bind.gen) => {
                            self.discard_ctl(&bind, state);
                        }
                        Ok(RpcState::Connected) => {
                            self.on_connected(&bind).await;
                            // Only a PUBLISHED socket has a deadline: one that
                            // was refused or retired while coming up is not
                            // the wallet's, and nothing may hunt on its behalf.
                            if bind.announced.load(Ordering::SeqCst) {
                                silence.up(tokio::time::Instant::now());
                            }
                        }
                        Ok(RpcState::Disconnected) => {
                            silence.down();
                            self.on_disconnected(&bind).await;
                        }
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
                        Ok(notification) => {
                            let tick = matches!(
                                notification,
                                Notification::VirtualDaaScoreChanged(_)
                            );
                            self.on_notification(&bind, notification);
                            if tick && silence.tick(tokio::time::Instant::now()) {
                                self.note_link_held(&bind);
                            }
                        }
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
                    silence.down();
                }
                _ = async {
                    match silence_next {
                        Some((due, _)) => tokio::time::sleep_until(due).await,
                        None => std::future::pending::<()>().await,
                    }
                }, if exit_at.is_none() => {
                    // `silence_next` was `Some` only because `deadline` and
                    // `heard` were.
                    if let (Some((_, stage)), Some(heard)) = (silence_next, silence.heard) {
                        let quiet = tokio::time::Instant::now().saturating_duration_since(heard);
                        if !silence.extended && self.page_explains_silence(&bind) {
                            // Our own catch-up page may hold the ticks behind
                            // it: one more deadline, once (LINK-Q4).
                            silence.extend();
                            self.note_silence_extended(
                                &bind,
                                quiet,
                                deadline.unwrap_or(link::SILENCE_DEADLINE),
                            );
                        } else {
                            let scored = silence.scored;
                            silence.fire(stage);
                            match stage {
                                SilenceStage::Predial => {
                                    self.on_silence_predial(&bind, scored, quiet)
                                }
                                SilenceStage::Swap => self.on_silence(&bind, scored, quiet),
                            }
                        }
                    }
                }
                _ = probe_every.tick(), if exit_at.is_none() => {
                    self.spawn_link_probe(&bind);
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
                    bind.connected_mono_ms.store(mono_ms(), Ordering::Relaxed);
                    // A pinned bind redials inside one identity (the pin's own
                    // retry loop), so every publish is a NEW socket: its
                    // re-announce budget — which is also its dark-lane proof —
                    // and its witness stretch start clean (`consensus-auditor`
                    // note g, `wallet-security-auditor`). Loop-safe: a
                    // re-announce goes to the monitor's ctl, never this
                    // socket's, so it cannot reach this arm. A no-op for a
                    // race bind, which publishes once.
                    bind.publishes.fetch_add(1, Ordering::SeqCst);
                    bind.lane_reannounced.store(0, Ordering::SeqCst);
                    self.inner.walk.socket_published();
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
                // LINK-Q3: a new socket may follow a gap; the walk resumes
                // from its committed cursor (a no-op while the intake is held).
                self.inner.walk.poke();
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
            //
            // **Since LINK-Q1 the deaf-but-PUBLISHED shape above is owned**
            // (D-334): the silence clock arms at the publish, so a socket
            // that never delivers a tick is hunted behind at
            // [`link::SILENCE_DEADLINE`] like any other silent one, with the
            // watchdog's stall line behind that. What stays unowned is THIS
            // arm — a local failure leaves the bind unpublished, and nothing
            // arms a deadline for a socket the wallet was never given.
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
            // **No production subscription since LINK-Q3** (D-344): messages
            // come from accepted transactions (`walk.rs`). A block arrives only
            // under the dev install's parity arm (`ba=1`), which scans it to
            // set the stream's sighting beside the walk's, logs only: nothing
            // is emitted, nothing is committed, no witness moves.
            Notification::BlockAdded(added) => {
                if self.inner.devab.block_added_on() {
                    self.inner.devab.on_block(&added.block);
                    self.inner.devab.on_ba_matches(&transport::scan_block(
                        &added.block,
                        self.inner.address_prefix,
                    ));
                }
            }
            // V1 acceptance spine: forward the batch to the tracker task when
            // one is attached (never processed here — the event task stays
            // non-blocking; blue-score resolution and persistence live in the
            // tracker). And since LINK-Q3 the chain moving is the message
            // walk's cue: one more page, coalesced with any already asked for.
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
                    let _ = tx.send(TrackerFeed::Vcc(VccBatch {
                        removed_chain_block_hashes: vcc.removed_chain_block_hashes.clone(),
                        added_chain_block_hashes: vcc.added_chain_block_hashes.clone(),
                        accepted: Arc::new(accepted),
                    }));
                }
                self.inner.walk.poke();
            }
            other => {
                if let Some(event) = map_notification(&other) {
                    if matches!(event, DagEvent::VirtualDaaScore(_)) {
                        // The link's heartbeat (LINK-Q1): THIS socket's node
                        // just advanced its virtual — it is alive and current.
                        self.mark_tick(bind);
                        // V1 span: the first DAA tick after a connect closes
                        // the time-to-first-DAA row.
                        if !bind.daa_seen_since_connect.swap(true, Ordering::Relaxed) {
                            spans::mark("first_daa");
                        }
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
        // **The full-block stream is no longer subscribed** (LINK-Q3, D-344,
        // moving D-062's receive lock as D-340 approved): 97 % of the app's
        // download, for sightings the message walk no longer reads. Only the
        // dev install's parity arm (`ba=1`) subscribes it, on the SAME
        // listener, never with the flags file absent (`devab.rs`'s fence).
        let with_block_added = self.inner.devab.block_added_on();
        if with_block_added {
            rpc.start_notify(listener_id, Scope::BlockAdded(BlockAddedScope {}))
                .await?;
        }
        self.inner.devab.subscribed(bind.gen, with_block_added);
        // V1 acceptance spine (D-073): which txids each chain block accepted,
        // plus removed-chain-block hashes on reorg — same listener, same
        // socket (D-005), re-registered per connect like the rest. The stream
        // is consumed by the event task and forwarded (sparse-filtered by the
        // tracker) — it never crosses to Dart. Since LINK-Q3 it is also the
        // message walk's cue to fetch the page it describes.
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

/// The monitor's side of LINK-Q2's seam: the dev loops hold only a
/// weak handle, so they never keep a monitor alive and exit when it is gone.
#[derive(Clone)]
struct DevHostHandle {
    inner: std::sync::Weak<Inner>,
}

#[async_trait::async_trait]
impl devab::DevHost for DevHostHandle {
    fn alive(&self) -> bool {
        self.inner.strong_count() > 0
    }

    fn flags_path(&self) -> Option<PathBuf> {
        let inner = self.inner.upgrade()?;
        let health = inner
            .health_path
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()?;
        Some(health.with_file_name(devab::FLAGS_FILE))
    }

    fn bound(&self) -> Option<(u64, String)> {
        let inner = self.inner.upgrade()?;
        let bind = inner
            .bound
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()?;
        Some((bind.gen, bind.url.clone()))
    }

    fn rpc(&self) -> Arc<dyn RpcApi> {
        match self.inner.upgrade() {
            Some(inner) => inner.link_rpc.clone(),
            None => LinkRpc::new(),
        }
    }

    fn devab(&self) -> Arc<devab::DevAb> {
        match self.inner.upgrade() {
            Some(inner) => inner.devab.clone(),
            None => Arc::new(devab::DevAb::default()),
        }
    }

    async fn set_block_added(&self, gen: u64, subscribe: bool) -> std::result::Result<(), String> {
        let inner = self.inner.upgrade().ok_or("the monitor is gone")?;
        let bind = inner
            .bound
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
            .ok_or("no bound socket")?;
        if bind.gen != gen {
            return Err("the bound socket changed".to_string());
        }
        let listener = (*bind
            .listener_id
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner))
        .ok_or("no listener on the bound socket")?;
        let rpc = bind.client.rpc_api();
        let scope = Scope::BlockAdded(BlockAddedScope {});
        let outcome = if subscribe {
            rpc.start_notify(listener, scope).await
        } else {
            rpc.stop_notify(listener, scope).await
        };
        outcome.map_err(|e| e.to_string())
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
                from: "wss://whatever.example/borsh".to_string(),
                why: SwapWhy::Asked,
            }),
            "not even a swap hunt may bind over the user's node"
        );
        // Nor a silence hunt: a pinned socket that goes quiet is the
        // watchdog's to redial, never the deadline's to replace (LINK-Q1).
        assert!(
            !pinned.may_bind_from_race(&RaceMode::Swap {
                from: "wss://whatever.example/borsh".to_string(),
                why: SwapWhy::Silent {
                    gen: 1,
                    ticks: 0,
                    asked: 0
                },
            }),
            "not even a silence hunt may bind over the user's node"
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
        bind.last_tick_at
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
        bind.last_tick_at
            .store(now.saturating_sub(40), Ordering::Relaxed);
        assert!(
            matches!(monitor.stall_verdict(), StallVerdict::Execute { silent_secs } if silent_secs >= link::WATCHDOG_STALL_SECS),
            "a socket silent past the threshold on its own clock is executed"
        );

        // Blocks flowing now: healthy regardless of age.
        bind.last_tick_at.store(now, Ordering::Relaxed);
        assert!(matches!(
            monitor.stall_verdict(),
            StallVerdict::Refuse { .. }
        ));

        // The process-wide display clock is NOT the judgment clock: a stale
        // process reading must never convict a socket that is delivering.
        monitor
            .inner
            .last_tick_at
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

    /// The intake cursor's reader. **The old build's file is the fixture**
    /// (PB-023): the block scan wrote a bare hex hash, no newline, and the walk
    /// reads that same format as its starting point (a non-chain start is fine
    /// at the pin, `walk.rs` module doc). Missing or corrupt reads as none, and
    /// the walk then seeds at the sink rather than walking from garbage.
    #[test]
    fn transport_cursor_round_trips_and_rejects_garbage() {
        let dir = std::env::temp_dir().join(format!("kv-tcursor-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        let _ = std::fs::remove_file(&path);
        assert_eq!(DagMonitor::read_transport_cursor(&path), None);
        let h = Hash::from_bytes([7u8; 32]);
        std::fs::write(&path, h.to_string()).unwrap();
        assert_eq!(DagMonitor::read_transport_cursor(&path), Some(h));
        std::fs::write(&path, format!("{h}\n")).unwrap();
        assert_eq!(DagMonitor::read_transport_cursor(&path), Some(h));
        std::fs::write(&path, "not-a-hash").unwrap();
        assert_eq!(DagMonitor::read_transport_cursor(&path), None);
        let _ = std::fs::remove_dir_all(&dir);
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
            why: SwapWhy::Asked,
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
        assert!(!swap_hunt_exhausted(
            &swap,
            SWAP_HUNT_ROUNDS - 1,
            true,
            false
        ));
        assert!(swap_hunt_exhausted(&swap, SWAP_HUNT_ROUNDS, true, false));
        assert!(
            !swap_hunt_exhausted(&RaceMode::Cold, SWAP_HUNT_ROUNDS * 100, true, false),
            "a dark wallet is never given up on"
        );
        // A tap that joined in the final round is owed rounds of its own
        // (`consensus-auditor` delta CONCERNS-B).
        assert!(
            !swap_hunt_exhausted(&swap, SWAP_HUNT_ROUNDS, true, true),
            "a joined tap is never spent with the silence's budget"
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
            why: SwapWhy::Asked,
        };

        // Still connected on the last round: keeping the incumbent is right.
        assert!(
            swap_hunt_exhausted(&swap, SWAP_HUNT_ROUNDS, true, false),
            "a swap that still has its incumbent stops and keeps it"
        );

        // The incumbent died inside the final round. The budget is spent, but
        // there is nothing left to preserve — so the loop must NOT return.
        assert!(
            !swap_hunt_exhausted(&swap, SWAP_HUNT_ROUNDS, false, false),
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
            why: SwapWhy::Asked,
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
            why: SwapWhy::Asked,
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

        monitor.network_event(NetworkEvent::Lost).await;
        assert!(monitor.os_offline(), "onLost must be visible to the glass");
        // Ruling 4 holds: lost is passive — nothing was dialed, so the
        // single-flight race flag is untouched.
        assert!(!monitor.is_searching(), "network_lost must not dial");

        monitor.network_event(NetworkEvent::Available).await;
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
        let live_tick_clock = live.last_tick_at.load(Ordering::Relaxed);

        // The dead socket keeps talking: a late teardown AND a late tick.
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
            live.last_tick_at.load(Ordering::Relaxed),
            live_tick_clock,
            "a dead socket's tick must not refresh the live socket's evidence clock"
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
            // LINK-Q1: the silence hunt's winner retires its incumbent under
            // its own name, and the wallet lane's rebind goes the hard path
            // under its own — both record, neither judges.
            (SILENCE_SWAP, "wss://e.example/kaspa/mainnet/wrpc/borsh"),
            ("lane-dark", "wss://f.example/kaspa/mainnet/wrpc/borsh"),
            // A silence hunt a tap joined: its winner retires the incumbent as
            // the user's swap, and the silence budget does not move.
            ("tap-joined", "wss://g.example/kaspa/mainnet/wrpc/borsh"),
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
                "lane-dark" => monitor
                    .hard_reconnect_because("lane-dark", "lane-dark")
                    .await
                    .expect("lane rebind"),
                // The race's winner arm, driven: the cause is the hunt's to
                // earn (`consensus-auditor` third delta, CONCERNS-C).
                SILENCE_SWAP | "tap-joined" => {
                    let silent = RaceMode::Swap {
                        from: url.to_string(),
                        why: SwapWhy::Silent {
                            gen: bind.gen,
                            ticks: 0,
                            asked: monitor.inner.swaps_asked.load(Ordering::SeqCst),
                        },
                    };
                    if case == "tap-joined" {
                        monitor.inner.swaps_asked.fetch_add(1, Ordering::SeqCst);
                    }
                    monitor
                        .install_bind_leaving(
                            "wss://next.example/kaspa/mainnet/wrpc/borsh".to_string(),
                            &silent,
                        )
                        .await
                        .expect("arm the hunt's winner");
                }
                // Installing over a live bind must not leak it.
                _ => {
                    monitor
                        .install_bind("wss://next.example/kaspa/mainnet/wrpc/borsh".to_string())
                        .await
                        .expect("arm the successor");
                }
            }
            // Only the silence deadline's own swap spends its budget, and it
            // does on the install path every silence swap takes
            // (`consensus-auditor` CONCERNS-A — this case drives that line).
            assert_eq!(
                monitor.silence_deadline(),
                Some(if case == SILENCE_SWAP {
                    link::SILENCE_DEADLINE * 2
                } else {
                    link::SILENCE_DEADLINE
                }),
                "{case}: the silence budget moves for a silence swap and nothing else"
            );

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
                    .pending_strikes
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .is_empty(),
                "{case}: a deliberate teardown parks no strike either"
            );
            assert!(!monitor.is_connected(), "{case}: the link is down");
            assert!(
                monitor.current_bind().is_none()
                    || matches!(case, "superseded" | "tap-joined")
                    || case == SILENCE_SWAP,
                "{case}: no bind is left installed"
            );
        }
    }

    /// **The connect step leaves the block stream OFF — unless the dev arm asks
    /// for it** (LINK-Q3, D-344; the LINK-Q2 test inverted). Drives the real
    /// `handle_connect` offline on an armed-but-unconnected bind and reads the
    /// step's own report, so flipping the one production line reds this.
    #[tokio::test]
    async fn the_connect_step_leaves_the_stream_off_unless_a_dev_arm_asks_for_it() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://a.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        monitor
            .handle_connect(&bind)
            .await
            .expect("the connect step runs without a node");
        assert_eq!(
            monitor.inner.devab.ba_known(bind.gen),
            Some(false),
            "with no flags file the block stream must NOT be subscribed at connect"
        );
        devab::store_switches(&monitor.inner.devab, &devab::DevFlags::parse("on=1\nba=1"));
        let next = monitor
            .install_bind("wss://b.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm the successor");
        monitor
            .handle_connect(&next)
            .await
            .expect("the connect step runs without a node");
        assert_eq!(monitor.inner.devab.ba_known(next.gen), Some(true));
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
        bind.last_tick_at.store(0, Ordering::Relaxed);

        monitor.reconnect(true).await.expect("stalled reconnect");

        assert!(
            last_run(&monitor, URL).is_some_and(|run| run >= 60),
            "the executed socket's run reaches the ledger (D-098's column of zeros)"
        );
        let parked = monitor
            .inner
            .pending_strikes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        assert!(
            matches!(parked.as_slice(), [(u, _, link::StrikeReason::Stall)] if u == URL),
            "the execution parks a Stall against the socket it judged, got {parked:?}"
        );
    }

    // ── LINK-Q1 · the heartbeat, the silence deadline, the wallet lane (D-334) ──

    fn daa_tick(score: u64) -> Notification {
        Notification::VirtualDaaScoreChanged(VirtualDaaScoreChangedNotification {
            virtual_daa_score: score,
        })
    }

    /// A block with nothing in it — the scan reads its transactions and finds
    /// none, which is all this needs: a `BlockAdded` that is not a tick.
    fn empty_block() -> Notification {
        let zero = Hash::from_bytes([0u8; 32]);
        Notification::BlockAdded(kaspa_rpc_core::BlockAddedNotification {
            block: Arc::new(kaspa_rpc_core::RpcBlock {
                header: kaspa_rpc_core::RpcHeader {
                    hash: zero,
                    version: 0,
                    parents_by_level: vec![],
                    hash_merkle_root: zero,
                    accepted_id_merkle_root: zero,
                    utxo_commitment: zero,
                    timestamp: 0,
                    bits: 0,
                    nonce: 0,
                    daa_score: 0,
                    blue_work: Default::default(),
                    blue_score: 0,
                    pruning_point: zero,
                },
                transactions: vec![],
                verbose_data: None,
            }),
        })
    }

    /// Stage an announced, live bind — the state a successful publish leaves,
    /// `announced` included (which `mark_accepted` leaves alone).
    fn stage_live(monitor: &DagMonitor, bind: &Arc<BoundSocket>) {
        mark_accepted(monitor, bind, 30);
        bind.announced.store(true, Ordering::SeqCst);
    }

    /// A bind's retire signal is taken exactly once, by `retire_bind` — so an
    /// untaken one proves the socket was never retired, by construction.
    fn never_retired(bind: &BoundSocket) -> bool {
        bind.retire_tx
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_some()
    }

    fn no_pending_strike(monitor: &DagMonitor) -> bool {
        monitor
            .inner
            .pending_strikes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_empty()
    }

    /// **LINK-Q1 · the heartbeat is the DAA tick** (D-334). A block is the
    /// transport scan's input and moves no liveness clock; a tick moves all
    /// four — the socket's evidence clock, the process's display clock, the
    /// socket's count the silence hunt reads, and the process count the node
    /// screen turns into a rate.
    ///
    /// The last half is the behaviour change, proven in the direction that
    /// would catch it being undone (PB-031): a socket connected 40 s that has
    /// delivered fifty blocks and no tick is SILENT on the heartbeat, and the
    /// stall verdict executes it. With `BlockAdded` still marking, this reds.
    #[tokio::test]
    async fn the_heartbeat_is_the_daa_tick_and_a_block_is_not() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://ella.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        mark_accepted(&monitor, &bind, 40);

        for _ in 0..50 {
            monitor.on_notification(&bind, empty_block());
        }
        assert_eq!(
            bind.last_tick_at.load(Ordering::Relaxed),
            0,
            "a block is not the heartbeat"
        );
        assert_eq!(monitor.inner.last_tick_at.load(Ordering::Relaxed), 0);
        assert_eq!(bind.ticks.load(Ordering::SeqCst), 0);
        assert_eq!(monitor.daa_ticks(), 0);
        assert_eq!(
            monitor.last_tick_age_secs(),
            None,
            "no tick yet: the glass has nothing to age"
        );
        assert!(
            matches!(monitor.stall_verdict(), StallVerdict::Execute { silent_secs } if silent_secs >= link::WATCHDOG_STALL_SECS),
            "blocks without a tick are silence on the heartbeat — executed on its own clock"
        );

        monitor.on_notification(&bind, daa_tick(900));
        assert!(
            bind.last_tick_at.load(Ordering::Relaxed) > 0,
            "the socket's evidence clock moved"
        );
        assert!(
            monitor.inner.last_tick_at.load(Ordering::Relaxed) > 0,
            "and the glass's"
        );
        assert_eq!(bind.ticks.load(Ordering::SeqCst), 1);
        assert_eq!(monitor.daa_ticks(), 1);
        assert!(monitor.last_tick_age_secs().is_some_and(|age| age <= 1));
        assert!(
            matches!(monitor.stall_verdict(), StallVerdict::Refuse { .. }),
            "a socket that ticked just now is not a zombie"
        );
    }

    /// The silence deadline's clock, as a pure thing: armed by the accepted
    /// connect, re-armed by every tick, one hunt per silence, disarmed by a
    /// drop — and a tick before the connect arms nothing.
    #[test]
    fn the_silence_clock_arms_on_connect_rearms_on_a_tick_and_fires_once() {
        let deadline = link::SILENCE_DEADLINE;
        let d = Some(deadline);
        let t0 = tokio::time::Instant::now();
        let mut clock = SilenceClock::default();
        assert_eq!(clock.due(d), None, "nothing up, nothing to watch");
        assert!(!clock.tick(t0));
        assert_eq!(clock.due(d), None, "a tick before the connect arms nothing");

        clock.up(t0);
        assert_eq!(clock.due(d), Some(t0 + deadline));
        assert_eq!(
            clock.due(None),
            None,
            "a budget that switched it off arms nothing"
        );
        assert!(!clock.scored, "never scored until it ticks");

        let t1 = t0 + Duration::from_secs(3);
        assert!(!clock.tick(t1));
        assert_eq!(clock.due(d), Some(t1 + deadline));
        assert!(clock.scored);

        clock.fire(SilenceStage::Swap);
        assert_eq!(clock.due(d), None, "one hunt per silence");

        let t2 = t1 + Duration::from_secs(20);
        assert!(
            !clock.tick(t2),
            "a socket whose deadline fired has not held"
        );
        assert_eq!(
            clock.due(d),
            Some(t2 + deadline),
            "a tick re-arms it: the next silence may start the next hunt"
        );

        clock.down();
        assert_eq!(clock.due(d), None);
        assert!(!clock.scored);
    }

    /// **The link HELD** — a clean `SILENCE_HOLD_RESET` on one socket, no
    /// quiet spell of the base deadline in it — is what gives the silence
    /// deadline its nine seconds back (CONCERNS-1's budget). Reported once per
    /// clean stretch; a quiet spell, fired or not, starts the minute again
    /// (`consensus-auditor` delta NOTE 3), from the LAST quiet spell rather
    /// than for the socket's life (third-delta NOTE 2), and the base deadline
    /// is the edge exactly (third-delta NOTE 3).
    #[test]
    fn a_socket_that_stays_up_a_minute_says_the_link_held_once() {
        let t0 = tokio::time::Instant::now();
        let at = |ms: u64| t0 + Duration::from_millis(ms);
        let held_at = |clock: &mut SilenceClock, ticks: &[u64]| -> Vec<u64> {
            ticks
                .iter()
                .copied()
                .filter(|&ms| clock.tick(at(ms)))
                .collect()
        };
        let every_second = |from: u64, to: u64| (from..=to).map(|s| s * 1000).collect::<Vec<_>>();

        let mut steady = SilenceClock::default();
        steady.up(t0);
        assert_eq!(
            held_at(&mut steady, &every_second(1, 90)),
            [60_000],
            "once, at the minute"
        );

        // A silence the deadline fired on: the minute restarts at the tick
        // that ends it.
        let mut shaky = SilenceClock::default();
        shaky.up(t0);
        assert!(!shaky.tick(at(1_000)));
        shaky.fire(SilenceStage::Swap);
        let mut ticks = vec![12_000];
        ticks.extend(every_second(13, 90));
        assert_eq!(
            held_at(&mut shaky, &ticks),
            [72_000],
            "a clean minute after the silence"
        );

        // Quiet unfired is still quiet — with the budget at 18 s or off, a
        // twelve-second silence fires nothing and the link still did not hold.
        let mut quiet = SilenceClock::default();
        quiet.up(t0);
        assert!(!quiet.tick(at(1_000)));
        let mut ticks = vec![13_000];
        ticks.extend(every_second(14, 90));
        assert_eq!(held_at(&mut quiet, &ticks), [73_000]);

        // The edge is the base deadline exactly: 8.99 s is not a quiet spell,
        // 9 s is.
        let mut under = SilenceClock::default();
        under.up(t0);
        assert!(!under.tick(at(1_000)));
        let mut ticks = vec![9_990];
        ticks.extend(every_second(10, 70));
        assert_eq!(
            held_at(&mut under, &ticks),
            [60_000],
            "8.99 s leaves the minute running"
        );
        let mut at_edge = SilenceClock::default();
        at_edge.up(t0);
        assert!(!at_edge.tick(at(1_000)));
        let mut ticks = vec![10_000];
        ticks.extend(every_second(11, 75));
        assert_eq!(held_at(&mut at_edge, &ticks), [70_000], "9 s restarts it");

        // A long-lived socket that coughs AFTER holding holds again a clean
        // minute later — the budget is not lost for the socket's life.
        let mut long = SilenceClock::default();
        long.up(t0);
        let mut ticks = every_second(1, 100);
        ticks.push(111_000);
        ticks.extend(every_second(112, 180));
        assert_eq!(held_at(&mut long, &ticks), [60_000, 171_000]);
    }

    /// **The winner arm's cause is chosen by one tested function**
    /// (`consensus-auditor` delta CONCERNS-A′): the silence budget counts
    /// [`SILENCE_SWAP`], so the choice of it is the budget's other half.
    #[test]
    fn only_silences_own_hunt_retires_as_a_silence_swap() {
        const FROM: &str = "wss://ella.example/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        let asked = monitor.inner.swaps_asked.load(Ordering::SeqCst);
        let silent = RaceMode::Swap {
            from: FROM.to_string(),
            why: SwapWhy::Silent {
                gen: 1,
                ticks: 0,
                asked,
            },
        };
        let tapped = RaceMode::Swap {
            from: FROM.to_string(),
            why: SwapWhy::Asked,
        };
        assert_eq!(monitor.retire_cause(&silent), SILENCE_SWAP);
        assert_eq!(monitor.retire_cause(&tapped), "superseded");
        assert_eq!(monitor.retire_cause(&RaceMode::Cold), "superseded");
        monitor.inner.swaps_asked.fetch_add(1, Ordering::SeqCst);
        assert_eq!(
            monitor.retire_cause(&silent),
            "superseded",
            "a silence hunt a tap has joined is the user's swap"
        );
    }

    /// **LINK-Q1 · a live socket silent past the deadline asks for a hunt
    /// behind itself, and a tick in time keeps it quiet** — driven through the
    /// socket's own task (the real publish arms the clock) on tokio's paused
    /// clock, so eighteen seconds of silence cost none. The single-flight flag
    /// is held so the hunt becomes a kick the test can see without dialling the
    /// network — the seam every swap test here uses.
    ///
    /// And it is NOT a verdict: after the deadline the socket is still bound,
    /// no run is recorded and no strike is parked.
    #[tokio::test(start_paused = true)]
    async fn a_silent_live_socket_hunts_behind_itself_and_a_tick_keeps_it_quiet() {
        const URL: &str = "wss://kate.example/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        let bind = monitor
            .install_bind(URL.to_string())
            .await
            .expect("arm a bind");
        // Up through its own task: `on_connected` publishes, then the clock arms.
        let _ = bind.client.rpc_ctl().signal_open().await;
        wait_for("the bind to publish", || {
            bind.announced.load(Ordering::SeqCst)
        })
        .await;
        assert!(monitor.is_connected());

        let kicked = Arc::new(AtomicBool::new(false));
        let waiter = {
            let inner = monitor.inner.clone();
            let kicked = kicked.clone();
            tokio::spawn(async move {
                inner.race_kick.notified().await;
                kicked.store(true, Ordering::SeqCst);
            })
        };

        // Eight seconds of silence, then it speaks: the clock re-arms there.
        tokio::time::sleep(Duration::from_secs(8)).await;
        let _ = bind.notification_tx.send(daa_tick(1)).await;
        wait_for("the tick to fold", || {
            bind.ticks.load(Ordering::SeqCst) == 1
        })
        .await;

        // Sixteen seconds since the connect, eight since the tick: no hunt.
        tokio::time::sleep(Duration::from_secs(8)).await;
        assert!(
            !kicked.load(Ordering::SeqCst),
            "a socket that spoke eight seconds ago is inside its deadline"
        );

        // Past the deadline measured from the TICK: the hunt is asked for.
        tokio::time::sleep(Duration::from_secs(2)).await;
        wait_for("the silence hunt to be asked for", || {
            kicked.load(Ordering::SeqCst)
        })
        .await;

        assert!(
            monitor.is_current_bind(bind.gen),
            "no teardown on the deadline"
        );
        assert!(monitor.is_connected());
        assert!(
            never_retired(&bind),
            "never retired — the structural proof; a run length cannot be one here, because \
             paused time leaves the wall clock a run is measured on standing still"
        );
        assert!(
            no_pending_strike(&monitor),
            "and no strike: conviction is the watchdog's"
        );

        waiter.abort();
        monitor.inner.race_running.store(false, Ordering::SeqCst);
    }

    /// A pinned socket that goes silent has no other node to find: the deadline
    /// asks for nothing — neither a hunt nor a kick — and the watchdog's stall
    /// line owns it. PB-031: without the pinned arm `on_silence` would fall
    /// through to the kick, and this reds on the stored permit.
    #[tokio::test]
    async fn a_pinned_silent_socket_asks_for_no_hunt() {
        const URL: &str = "wss://mine.example/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::try_new(NetworkId::new(NetworkType::Mainnet), Some(URL.into()))
            .expect("construct");
        let bind = monitor
            .install_bind(URL.to_string())
            .await
            .expect("arm a bind");
        stage_live(&monitor, &bind);

        monitor.on_silence(&bind, true, link::SILENCE_DEADLINE);

        assert!(!monitor.is_searching(), "no hunt was spawned");
        assert!(
            tokio::time::timeout(
                Duration::from_millis(50),
                monitor.inner.race_kick.notified()
            )
            .await
            .is_err(),
            "and no kick was stored for one to find"
        );
        assert!(monitor.is_current_bind(bind.gen));
    }

    /// The stand-down belongs to the silence hunt and to its own incumbent: a
    /// socket that ticks since the hunt began is kept; a user's swap is never
    /// called off by the node they asked to leave; another socket's comeback
    /// is not this hunt's business.
    #[tokio::test]
    async fn a_silence_hunt_stands_down_only_for_its_own_incumbent_speaking() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://kate.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        stage_live(&monitor, &bind);
        let asked = monitor.inner.swaps_asked.load(Ordering::SeqCst);
        let silent = |gen: u64, ticks: u64| RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Silent { gen, ticks, asked },
        };

        assert!(
            !monitor.silent_incumbent_is_back(&silent(bind.gen, 0)),
            "still silent: the hunt goes on"
        );
        monitor.on_notification(&bind, daa_tick(7));
        assert!(
            monitor.silent_incumbent_is_back(&silent(bind.gen, 0)),
            "it spoke since the hunt began, and just now: keep it"
        );
        assert!(
            !monitor.silent_incumbent_is_back(&silent(bind.gen, 1)),
            "no tick since THIS hunt began"
        );
        assert!(
            !monitor.silent_incumbent_is_back(&silent(bind.gen + 1, 0)),
            "a different socket's tick is not this incumbent's comeback"
        );
        assert!(!monitor.silent_incumbent_is_back(&RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Asked,
        }));
        assert!(!monitor.silent_incumbent_is_back(&RaceMode::Cold));

        // **A tap during the hunt makes it the user's** (CONCERNS-2): the tap
        // path counts itself before asking for a hunt, and a silence hunt that
        // began at the old count is no longer called off by its incumbent —
        // the user asked to LEAVE it (L127: the tap always acts).
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        monitor.reconnect(false).await.expect("tap");
        assert!(
            !monitor.silent_incumbent_is_back(&silent(bind.gen, 0)),
            "the incumbent spoke, but the user's tap outranks its comeback"
        );
        monitor.inner.race_running.store(false, Ordering::SeqCst);
    }

    /// **The loop itself stands down at its head** (`consensus-auditor` note c,
    /// PB-031): a silence hunt whose incumbent is talking again returns before
    /// a single candidate is dialled. Bounded so a regression cannot hang the
    /// suite — without the check the loop would go on to the resolver.
    #[tokio::test]
    async fn a_silence_hunt_whose_incumbent_came_back_never_dials() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://kate.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        stage_live(&monitor, &bind);
        monitor.on_notification(&bind, daa_tick(1));
        let mode = RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Silent {
                gen: bind.gen,
                ticks: 0,
                asked: monitor.inner.swaps_asked.load(Ordering::SeqCst),
            },
        };
        tokio::time::timeout(Duration::from_millis(500), monitor.race_loop(mode))
            .await
            .expect("the hunt stands down at its head, before any network round");
        assert!(monitor.is_current_bind(bind.gen));
        assert!(never_retired(&bind));
    }

    /// **CONCERNS-1's budget: silence swaps cannot chain.** A landed silence
    /// swap doubles the next deadline; a second switches it off, leaving the
    /// watchdog's stall line (with its strike justice) to own the silence; a
    /// socket that holds for a minute gives the nine seconds back.
    #[tokio::test]
    async fn silence_swaps_are_budgeted_until_the_link_holds() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://kate.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        assert_eq!(monitor.silence_deadline(), Some(link::SILENCE_DEADLINE));
        monitor.note_silence_swap_landed();
        assert_eq!(monitor.silence_deadline(), Some(link::SILENCE_DEADLINE * 2));
        monitor.note_silence_swap_landed();
        assert_eq!(monitor.silence_deadline(), None, "two landed: off");
        monitor.note_link_held(&bind);
        assert_eq!(monitor.silence_deadline(), Some(link::SILENCE_DEADLINE));
    }

    /// The budget reaches the socket's own task: with the deadline switched
    /// off, a live socket silent for a full minute asks for no hunt at all.
    #[tokio::test(start_paused = true)]
    async fn with_the_budget_spent_a_silent_socket_asks_for_nothing() {
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        monitor.inner.silence_backoff.store(2, Ordering::SeqCst);
        let bind = monitor
            .install_bind("wss://kate.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        let _ = bind.client.rpc_ctl().signal_open().await;
        wait_for("the bind to publish", || {
            bind.announced.load(Ordering::SeqCst)
        })
        .await;
        tokio::time::sleep(Duration::from_secs(60)).await;
        assert!(
            tokio::time::timeout(Duration::from_millis(1), monitor.inner.race_kick.notified())
                .await
                .is_err(),
            "no hunt was asked for: the watchdog owns this silence now"
        );
        monitor.inner.race_running.store(false, Ordering::SeqCst);
    }

    /// **D-334's witness, re-aimed** (LINK-Q3): a published socket that keeps
    /// ticking while the message walk has had no page answered says so once,
    /// through the tick path itself; a socket not yet published has no stretch.
    #[tokio::test]
    async fn ticks_without_walk_progress_say_so_once() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let dir = std::env::temp_dir().join(format!("kv-witness-{}", std::process::id()));
        monitor.inner.walk.arm(dir.join("scan.cursor"));
        monitor.inner.walk.set_running_since(1);
        let bind = monitor
            .install_bind("wss://ivy.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        stage_live(&monitor, &bind);
        bind.connected_mono_ms.store(1, Ordering::Relaxed);
        let stall_ms = link::WATCHDOG_STALL_SECS * 1000;
        // The real clock is far past 1 + stall here only if the process is old;
        // drive the witness at explicit readings instead.
        monitor.inner.walk.note_ticks("ivy.example", 1, stall_ms);
        assert!(!monitor.inner.walk.witness_spoke(), "under the stall line");
        monitor
            .inner
            .walk
            .note_ticks("ivy.example", 1, 1 + stall_ms);
        assert!(
            monitor.inner.walk.witness_spoke(),
            "a stretch the length of the stall line"
        );
        // A publish starts the next socket's stretch clean.
        monitor.on_connected(&bind).await;
        assert!(!monitor.inner.walk.witness_spoke());
        // Not yet published: nothing to measure.
        monitor.inner.walk.note_ticks("kate.example", 0, u64::MAX);
        assert!(!monitor.inner.walk.witness_spoke());
    }

    /// **The monotonic clock counts from 1** (LINK-Q2, L232): its epoch is
    /// its first call, the first publish, so that stamp is the clock's very
    /// first reading, and it must not collide with the "never" 0 every stamp
    /// keeps, or the witness is silent for the socket most sessions keep for
    /// hours (`consensus-auditor` second delta: deterministic, at the epoch).
    #[test]
    fn the_monotonic_clock_counts_from_one() {
        assert_eq!(ms_of(Duration::ZERO), 1);
        assert!(ms_since(std::time::Instant::now()) >= 1);
        assert!(mono_ms() >= 1);
    }

    /// **The walk hears the chain move and every publish** (LINK-Q3): a
    /// `VirtualChainChanged` on the installed socket and an accepted connect
    /// each poke it; a DAA tick does not.
    #[tokio::test]
    async fn the_chain_moving_and_a_publish_poke_the_walk() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://ivy.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        let quick = Duration::from_millis(20);
        assert!(!monitor.inner.walk.take_poke(quick).await, "nothing yet");
        monitor.on_notification(&bind, daa_tick(1));
        assert!(
            !monitor.inner.walk.take_poke(quick).await,
            "a tick is not a chain move"
        );
        monitor.on_notification(
            &bind,
            Notification::VirtualChainChanged(kaspa_rpc_core::VirtualChainChangedNotification {
                removed_chain_block_hashes: Arc::new(vec![]),
                added_chain_block_hashes: Arc::new(vec![Hash::from_bytes([3u8; 32])]),
                accepted_transaction_ids: Arc::new(vec![]),
            }),
        );
        assert!(monitor.inner.walk.take_poke(quick).await, "the chain moved");
        monitor.on_connected(&bind).await;
        assert!(monitor.is_connected());
        assert!(monitor.inner.walk.take_poke(quick).await, "a publish");
    }

    /// **The pull keys on proof, not on the bit** (`consensus-auditor` note
    /// a): before a check has found the lane dark on THIS socket, the pull's
    /// hard path is not armed; after one has, it is; a new socket clears it.
    #[tokio::test(start_paused = true)]
    async fn the_pull_keys_on_a_lane_proven_dark_on_this_socket() {
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        // The window's rebind is spent, so the check re-announces and stops.
        monitor
            .inner
            .lane_rebound_at
            .store(DagMonitor::now_unix(), Ordering::SeqCst);
        let bind = monitor
            .install_bind("wss://ella.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        stage_live(&monitor, &bind);
        assert!(
            !monitor.wallet_lane_known_dark(),
            "no check has found it dark"
        );
        assert_eq!(
            monitor.recover_wallet_lane(|| false).await,
            LaneRecovery::GaveUp
        );
        assert!(
            monitor.wallet_lane_known_dark(),
            "proven dark on this socket"
        );
        let next = monitor
            .install_bind("wss://leah.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm the next");
        stage_live(&monitor, &next);
        assert!(
            !monitor.wallet_lane_known_dark(),
            "the proof was about the socket that is gone"
        );
        monitor.inner.race_running.store(false, Ordering::SeqCst);
    }

    /// **The recovery's budget is the SOCKET's** (`wallet-security-auditor`).
    /// A stand-in for the pin's processor that fails its negotiation sixty
    /// seconds after EVERY `Connected` it sees — a node that ticks but never
    /// answers `get_server_info`, so every retry dies at the wRPC timeout,
    /// after the check that asked for it has ended. Over thirty virtual
    /// minutes the socket gets at most its two re-announces, and the checks
    /// stop: a single-flight bound per run alone would have retried it about
    /// once a minute forever.
    #[tokio::test(start_paused = true)]
    async fn a_hanging_negotiation_gets_two_reannounces_per_socket_then_quiet() {
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        monitor
            .inner
            .lane_rebound_at
            .store(DagMonitor::now_unix(), Ordering::SeqCst);
        let bind = monitor
            .install_bind("wss://ivy.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        stage_live(&monitor, &bind);
        let opens = Arc::new(AtomicU64::new(0));
        let checks = Arc::new(AtomicU64::new(0));
        let processor = {
            let ctl = monitor.rpc().rpc_ctl().multiplexer().channel();
            let monitor = monitor.clone();
            let opens = opens.clone();
            let checks = checks.clone();
            tokio::spawn(async move {
                while let Ok(state) = ctl.receiver.recv().await {
                    if state != RpcState::Connected {
                        continue;
                    }
                    opens.fetch_add(1, Ordering::SeqCst);
                    let (monitor, checks) = (monitor.clone(), checks.clone());
                    tokio::spawn(async move {
                        tokio::time::sleep(Duration::from_secs(60)).await;
                        checks.fetch_add(1, Ordering::SeqCst);
                        monitor.recover_wallet_lane(|| false).await;
                    });
                }
            })
        };
        // The first failure — the socket's own negotiation.
        checks.fetch_add(1, Ordering::SeqCst);
        monitor.recover_wallet_lane(|| false).await;
        tokio::time::sleep(Duration::from_secs(30 * 60)).await;
        assert!(
            opens.load(Ordering::SeqCst) <= LANE_REANNOUNCE_AFTER.len() as u64,
            "{} re-announces on one socket — the budget is per socket",
            opens.load(Ordering::SeqCst)
        );
        assert_eq!(
            bind.lane_reannounced.load(Ordering::SeqCst) as usize,
            LANE_REANNOUNCE_AFTER.len()
        );
        let settled = checks.load(Ordering::SeqCst);
        tokio::time::sleep(Duration::from_secs(30 * 60)).await;
        assert_eq!(
            checks.load(Ordering::SeqCst),
            settled,
            "and the checks stopped: nothing re-triggers a socket whose budget is spent"
        );
        processor.abort();
        monitor.inner.race_running.store(false, Ordering::SeqCst);
    }

    /// With no socket there is no round trip to time: the probe is an ERROR —
    /// neither a sample nor a lower bound — so the reader counts it toward its
    /// dwell instead of drawing "at least" a number for a link that is not
    /// there (D-333).
    #[tokio::test]
    async fn a_probe_with_no_socket_is_an_error_not_a_timeout() {
        let monitor = DagMonitor::mainnet().expect("construct");
        assert_eq!(monitor.probe_link(true).await, LinkProbe::default());
    }

    /// The wallet-lane check acts only on evidence: an up lane is not dark, and
    /// a lane with no announced socket died with it — the five CONN-F1 cases.
    #[tokio::test(start_paused = true)]
    async fn the_wallet_lane_check_does_nothing_when_nothing_is_dark() {
        let monitor = DagMonitor::mainnet().expect("construct");
        assert_eq!(
            monitor.recover_wallet_lane(|| true).await,
            LaneRecovery::NotDark
        );
        assert_eq!(
            monitor.recover_wallet_lane(|| false).await,
            LaneRecovery::SocketGone,
            "no socket: the negotiation died with it, and the next bind renegotiates"
        );
        let bind = monitor
            .install_bind("wss://ella.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        mark_accepted(&monitor, &bind, 0);
        assert_eq!(
            monitor.recover_wallet_lane(|| false).await,
            LaneRecovery::SocketGone,
            "installed and up but never announced: not a socket the lane was offered"
        );
    }

    /// The wallet engine as the recovery sees it (PRE3-LANE), standing in:
    /// dead or not, and a rebuild that records whether it ran inside the
    /// flight.
    struct StandInLane {
        monitor: DagMonitor,
        dead: AtomicBool,
        rebuilds: AtomicU32,
        rebuilt_inside_the_flight: AtomicBool,
    }

    impl WalletLaneHooks for StandInLane {
        fn lane_dead(&self) -> bool {
            self.dead.load(Ordering::SeqCst)
        }

        fn rebuild(
            &self,
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = LaneRecovery> + Send + '_>>
        {
            Box::pin(async move {
                self.rebuilt_inside_the_flight.store(
                    self.monitor.inner.lane_recovering.load(Ordering::SeqCst),
                    Ordering::SeqCst,
                );
                self.rebuilds.fetch_add(1, Ordering::SeqCst);
                self.dead.store(false, Ordering::SeqCst);
                LaneRecovery::Rebuilt
            })
        }
    }

    /// **A dead lane is rebuilt inside the one flight, even while it reads up**
    /// (PRE3-LANE). A processor that panicked while connected keeps its bit
    /// set — nothing in the pin clears it — so the door's `lane_up()` alone
    /// would answer `NotDark` and leave it dead. The door asks the lane too,
    /// and the rebuild runs under the flag D-101's checks take (PB-019): never
    /// beside a re-announce, and no re-announce is sent to a task that is gone.
    #[tokio::test(start_paused = true)]
    async fn a_dead_lane_is_rebuilt_inside_the_flight_even_while_it_reads_up() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://ella.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        stage_live(&monitor, &bind);
        let ctl = monitor.rpc().rpc_ctl().multiplexer().channel();
        let lane = Arc::new(StandInLane {
            monitor: monitor.clone(),
            dead: AtomicBool::new(true),
            rebuilds: AtomicU32::new(0),
            rebuilt_inside_the_flight: AtomicBool::new(false),
        });
        monitor.attach_wallet_lane(lane.clone());

        assert_eq!(
            monitor.recover_wallet_lane(|| true).await,
            LaneRecovery::Rebuilt
        );
        assert_eq!(lane.rebuilds.load(Ordering::SeqCst), 1);
        assert!(
            lane.rebuilt_inside_the_flight.load(Ordering::SeqCst),
            "the rebuild ran outside D-101's single flight"
        );
        assert!(
            !monitor.inner.lane_recovering.load(Ordering::SeqCst),
            "and the flight was released after it"
        );
        assert!(
            ctl.receiver.try_recv().is_err(),
            "no re-announce to a dead task"
        );
        // Rebuilt, the lane is not dead: an up lane is answered at the door.
        assert_eq!(
            monitor.recover_wallet_lane(|| true).await,
            LaneRecovery::NotDark
        );
        assert_eq!(lane.rebuilds.load(Ordering::SeqCst), 1);
    }

    /// **A death reported while a dark-lane check sleeps turns the check into
    /// the rebuild** (PRE3-LANE): re-announcing to a task that just died would
    /// only spend the socket's budget, so the check asks after every sleep and
    /// hands over — within one re-announce interval, not after the schedule.
    #[tokio::test(start_paused = true)]
    async fn a_death_during_a_dark_lane_check_becomes_the_rebuild() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://ella.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        stage_live(&monitor, &bind);
        let lane = Arc::new(StandInLane {
            monitor: monitor.clone(),
            dead: AtomicBool::new(false),
            rebuilds: AtomicU32::new(0),
            rebuilt_inside_the_flight: AtomicBool::new(false),
        });
        monitor.attach_wallet_lane(lane.clone());

        let started = tokio::time::Instant::now();
        let check = {
            let monitor = monitor.clone();
            tokio::spawn(async move { monitor.recover_wallet_lane(|| false).await })
        };
        // The check is asleep before its first re-announce; the supervisor
        // reports a death.
        tokio::time::sleep(LANE_REANNOUNCE_AFTER[0] / 2).await;
        lane.dead.store(true, Ordering::SeqCst);
        assert_eq!(check.await.expect("check task"), LaneRecovery::Rebuilt);
        assert_eq!(lane.rebuilds.load(Ordering::SeqCst), 1);
        assert!(lane.rebuilt_inside_the_flight.load(Ordering::SeqCst));
        assert!(
            started.elapsed() <= LANE_REANNOUNCE_AFTER[0] + Duration::from_millis(50),
            "handed over after {:?}, not at the first wake",
            started.elapsed()
        );
    }

    /// **A re-announce IS a retry on the same socket.** Stands in for the pin's
    /// processor exactly as far as this claim needs: it renegotiates when it
    /// sees `Connected` on the monitor's ctl while its lane is down
    /// (`processor.rs:717-718`). The lane comes up on the first re-announce,
    /// and the socket carrying it was never touched.
    #[tokio::test(start_paused = true)]
    async fn a_reannounce_brings_the_lane_up_on_the_same_socket() {
        const URL: &str = "wss://ella.example/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind(URL.to_string())
            .await
            .expect("arm a bind");
        stage_live(&monitor, &bind);
        let lane = Arc::new(AtomicBool::new(false));
        let processor = {
            let ctl = monitor.rpc().rpc_ctl().multiplexer().channel();
            let lane = lane.clone();
            tokio::spawn(async move {
                while let Ok(state) = ctl.receiver.recv().await {
                    if state == RpcState::Connected {
                        lane.store(true, Ordering::SeqCst);
                    }
                }
            })
        };
        let probe = lane.clone();
        let outcome = monitor
            .recover_wallet_lane(move || probe.load(Ordering::SeqCst))
            .await;
        assert_eq!(outcome, LaneRecovery::Recovered { reannounced: 1 });
        assert!(
            monitor.is_current_bind(bind.gen),
            "the same socket carries the lane"
        );
        assert!(never_retired(&bind), "nothing was torn down");
        processor.abort();
    }

    /// **D-101's loop terminates, inside its bound** — what its deferral asked
    /// for: "its own loop bound". A lane that never comes up on a socket that
    /// stays bound gets exactly two re-announces and one rebind, in no more
    /// than the schedule's own time; the next report inside the window gets
    /// the two re-announces and a stop; outside the window the rebind is
    /// available again. Paused time: the elapsed VIRTUAL time is the bound.
    #[tokio::test(start_paused = true)]
    async fn the_wallet_lane_recovery_is_bounded_and_ends() {
        const URL: &str = "wss://ella.example/kaspa/mainnet/wrpc/borsh";
        const NEXT: &str = "wss://leah.example/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        // The rebind's relink kicks a held flag instead of dialling the network.
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        let ctl = monitor.rpc().rpc_ctl().multiplexer().channel();
        let drain = |rx: &async_channel::Receiver<RpcState>| {
            let (mut opens, mut closes) = (0usize, 0usize);
            while let Ok(state) = rx.try_recv() {
                match state {
                    RpcState::Connected => opens += 1,
                    RpcState::Disconnected => closes += 1,
                }
            }
            (opens, closes)
        };
        let bind = monitor
            .install_bind(URL.to_string())
            .await
            .expect("arm a bind");
        stage_live(&monitor, &bind);

        let started = tokio::time::Instant::now();
        let outcome = monitor.recover_wallet_lane(|| false).await;
        let took = started.elapsed();
        let schedule = LANE_REANNOUNCE_AFTER.iter().sum::<Duration>() + LANE_SETTLE;
        assert_eq!(outcome, LaneRecovery::Rebound);
        assert!(
            took <= schedule + Duration::from_millis(50),
            "{took:?} past {schedule:?}"
        );
        assert_eq!(
            drain(&ctl.receiver),
            (LANE_REANNOUNCE_AFTER.len(), 1),
            "two re-announces, then the rebind's one close"
        );
        assert!(!monitor.is_current_bind(bind.gen), "rebound");
        assert!(
            last_run(&monitor, URL).is_some(),
            "the rebind recorded the run it ended"
        );
        assert!(no_pending_strike(&monitor), "and judged nothing");

        // The next report, inside the window, on the next socket.
        let next = monitor
            .install_bind(NEXT.to_string())
            .await
            .expect("arm the next");
        stage_live(&monitor, &next);
        assert_eq!(
            monitor.recover_wallet_lane(|| false).await,
            LaneRecovery::GaveUp
        );
        assert_eq!(
            drain(&ctl.receiver),
            (LANE_REANNOUNCE_AFTER.len(), 0),
            "re-announced again, but NOT rebound: the window's budget held"
        );
        assert!(monitor.is_current_bind(next.gen));

        // Outside the window the rebind is there again (the budget is a
        // wall-clock stamp, so the window is crossed by backdating it).
        monitor.inner.lane_rebound_at.store(
            DagMonitor::now_unix().saturating_sub(LANE_REBIND_WINDOW_SECS + 1),
            Ordering::SeqCst,
        );
        assert_eq!(
            monitor.recover_wallet_lane(|| false).await,
            LaneRecovery::Rebound
        );
        assert!(!monitor.is_current_bind(next.gen));
        monitor.inner.race_running.store(false, Ordering::SeqCst);
    }

    /// One check at a time, and a socket that dies mid-check ends it as
    /// `SocketGone` with the flag released — a report that lands on a running
    /// check is queued behind it rather than starting a second loop, and the
    /// queued pass finds nothing bound either.
    #[tokio::test(start_paused = true)]
    async fn one_lane_check_at_a_time_and_a_socket_that_dies_ends_it() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://ella.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        stage_live(&monitor, &bind);
        let first = {
            let monitor = monitor.clone();
            tokio::spawn(async move { monitor.recover_wallet_lane(|| false).await })
        };
        wait_for("the first check to take the flag", || {
            monitor.inner.lane_recovering.load(Ordering::SeqCst)
        })
        .await;
        assert_eq!(
            monitor.recover_wallet_lane(|| false).await,
            LaneRecovery::Queued
        );
        // A report with the lane up is answered at the door — it queues no
        // pass behind the running one (item 22's rider: a node-paced burst of
        // notification-handler errors costs nothing).
        monitor
            .inner
            .lane_report_pending
            .store(false, Ordering::SeqCst);
        assert_eq!(
            monitor.recover_wallet_lane(|| true).await,
            LaneRecovery::NotDark
        );
        assert!(!monitor.inner.lane_report_pending.load(Ordering::SeqCst));
        monitor
            .inner
            .lane_report_pending
            .store(true, Ordering::SeqCst);
        monitor.retire_bind("ctl-drop").await;
        assert_eq!(first.await.expect("check task"), LaneRecovery::SocketGone);
        assert!(
            !monitor.inner.lane_recovering.load(Ordering::SeqCst),
            "released for the next report"
        );
        assert!(
            !monitor.inner.lane_report_pending.load(Ordering::SeqCst),
            "and the queued report was served, not left behind"
        );
    }

    /// **A report about a successor is queued, never dropped**
    /// (`wallet-security-auditor`). A check is asleep on socket A; A is
    /// replaced by B, and B's negotiation fails at once — B's only report
    /// lands while A's check still holds the flag. Dropped, nothing would ever
    /// check B: the pull keyed on A's proof, B's processor never offered
    /// another `Connected`, the lane dark behind a live socket with nothing on
    /// the glass. Queued, B gets its own pass: its two re-announces, and the
    /// proof the pull's hard path keys on.
    #[tokio::test(start_paused = true)]
    async fn a_report_about_a_successor_is_queued_and_checked() {
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        // The window's rebind is spent, so each pass re-announces and stops.
        monitor
            .inner
            .lane_rebound_at
            .store(DagMonitor::now_unix(), Ordering::SeqCst);
        let a = monitor
            .install_bind("wss://ella.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm A");
        stage_live(&monitor, &a);
        let first = {
            let monitor = monitor.clone();
            tokio::spawn(async move { monitor.recover_wallet_lane(|| false).await })
        };
        wait_for("A's check to take the flag", || {
            monitor.inner.lane_recovering.load(Ordering::SeqCst)
        })
        .await;
        let b = monitor
            .install_bind("wss://leah.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm B over A");
        stage_live(&monitor, &b);
        assert_eq!(
            monitor.recover_wallet_lane(|| false).await,
            LaneRecovery::Queued,
            "B's report lands on A's running check"
        );
        assert_eq!(
            first.await.expect("check task"),
            LaneRecovery::GaveUp,
            "the queued pass ran on B and ended inside its bound"
        );
        assert_eq!(
            b.lane_reannounced.load(Ordering::SeqCst) as usize,
            LANE_REANNOUNCE_AFTER.len(),
            "B was checked: its own re-announces were spent on it"
        );
        assert!(monitor.wallet_lane_known_dark(), "proven dark on B");
        assert!(!monitor.inner.lane_recovering.load(Ordering::SeqCst));
        monitor.inner.race_running.store(false, Ordering::SeqCst);
    }

    /// **The lane coming up on a successor is not this socket's recovery**
    /// (`consensus-auditor` note f): a check that began on A, where A dropped
    /// and B negotiated by itself, is the benign case — the negotiation died
    /// with its socket — and says so, rather than `Recovered`, which a capture
    /// counts as a dark lane on a live socket.
    #[tokio::test(start_paused = true)]
    async fn a_lane_that_comes_up_on_a_successor_is_not_this_sockets_recovery() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let a = monitor
            .install_bind("wss://ella.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm A");
        stage_live(&monitor, &a);
        let lane = Arc::new(AtomicBool::new(false));
        let check = {
            let (monitor, lane) = (monitor.clone(), lane.clone());
            tokio::spawn(async move {
                monitor
                    .recover_wallet_lane(move || lane.load(Ordering::SeqCst))
                    .await
            })
        };
        wait_for("the check to take the flag", || {
            monitor.inner.lane_recovering.load(Ordering::SeqCst)
        })
        .await;
        let b = monitor
            .install_bind("wss://leah.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm B over A");
        stage_live(&monitor, &b);
        lane.store(true, Ordering::SeqCst);
        assert_eq!(check.await.expect("check task"), LaneRecovery::SocketGone);
        assert_eq!(
            b.lane_reannounced.load(Ordering::SeqCst),
            0,
            "nothing was re-announced on a socket that never reported"
        );
    }

    /// **A lane that comes up by itself on the socket the check began on was
    /// never dark there** (`consensus-auditor` delta note 1,
    /// `wallet-security-auditor` delta NOTE): the processor renegotiates only
    /// on a `Connected`, and none was sent — what came up was a negotiation
    /// still in flight when the pass began. `NotDark`, never a `Recovered` a
    /// capture would count as a dark lane on a live socket, and no proof.
    #[tokio::test(start_paused = true)]
    async fn a_lane_that_was_still_negotiating_is_not_dark() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://ella.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        stage_live(&monitor, &bind);
        let lane = Arc::new(AtomicBool::new(false));
        let check = {
            let (monitor, lane) = (monitor.clone(), lane.clone());
            tokio::spawn(async move {
                monitor
                    .recover_wallet_lane(move || lane.load(Ordering::SeqCst))
                    .await
            })
        };
        wait_for("the check to take the flag", || {
            monitor.inner.lane_recovering.load(Ordering::SeqCst)
        })
        .await;
        lane.store(true, Ordering::SeqCst);
        assert_eq!(check.await.expect("check task"), LaneRecovery::NotDark);
        assert!(!monitor.wallet_lane_known_dark(), "nothing was proven");
        assert_eq!(bind.lane_reannounced.load(Ordering::SeqCst), 0);
    }

    /// **A pinned redial mid-check is a new socket** (`consensus-auditor`
    /// delta NOTE 2): one identity, a second publish. The check that began on
    /// the first physical socket ends `SocketGone` and proves nothing about
    /// the second — its proof would otherwise land just after the publish
    /// cleared it and arm the pull's hard path over a healthy negotiation.
    #[tokio::test(start_paused = true)]
    async fn a_pinned_redial_mid_check_is_a_new_socket() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://ella.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        monitor.on_connected(&bind).await;
        assert_eq!(bind.publishes.load(Ordering::SeqCst), 1);
        let check = {
            let monitor = monitor.clone();
            tokio::spawn(async move { monitor.recover_wallet_lane(|| false).await })
        };
        wait_for("the check to take the flag", || {
            monitor.inner.lane_recovering.load(Ordering::SeqCst)
        })
        .await;
        // The pin's retry loop brings the same identity back up.
        monitor.on_connected(&bind).await;
        assert_eq!(bind.publishes.load(Ordering::SeqCst), 2);
        assert_eq!(check.await.expect("check task"), LaneRecovery::SocketGone);
        assert!(
            !monitor.wallet_lane_known_dark(),
            "no proof about the socket the check never saw"
        );
        assert_eq!(bind.lane_reannounced.load(Ordering::SeqCst), 0);
    }

    /// **Each publish is a fresh socket for the lane** (`consensus-auditor`
    /// note g, `wallet-security-auditor`): a pinned bind redials inside one
    /// identity, so the re-announce budget, the dark-lane proof and the
    /// blockless warning of the socket before must not carry into the next.
    #[tokio::test]
    async fn each_publish_starts_the_sockets_lane_state_clean() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://ella.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        // What an earlier socket under this identity left behind: its spent
        // budget, which is also its proof of a dark lane.
        bind.lane_reannounced
            .store(LANE_REANNOUNCE_AFTER.len() as u32, Ordering::SeqCst);
        monitor.inner.walk.arm(
            std::env::temp_dir()
                .join(format!("kv-publish-{}", std::process::id()))
                .join("scan.cursor"),
        );
        monitor.inner.walk.set_running_since(1);
        monitor
            .inner
            .walk
            .note_ticks("ella.example", 1, 1 + link::WATCHDOG_STALL_SECS * 1000);
        assert!(monitor.inner.walk.witness_spoke(), "the stretch before");
        monitor.on_connected(&bind).await;
        assert!(monitor.is_connected(), "the socket published");
        assert_eq!(bind.lane_reannounced.load(Ordering::SeqCst), 0);
        assert!(!monitor.wallet_lane_known_dark());
        assert!(
            !monitor.inner.walk.witness_spoke(),
            "a publish starts the stretch clean"
        );
    }

    /// **The race loop's exhaustion call reads the live monitor**
    /// (`consensus-auditor` third delta, CONCERNS-C): a silence hunt's
    /// budget is spent only while its incumbent lives and no tap has joined.
    #[tokio::test]
    async fn a_silence_hunt_is_spent_only_while_its_incumbent_lives_untapped() {
        const URL: &str = "wss://ella.example/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind(URL.to_string())
            .await
            .expect("arm a bind");
        stage_live(&monitor, &bind);
        let silent = RaceMode::Swap {
            from: URL.to_string(),
            why: SwapWhy::Silent {
                gen: bind.gen,
                ticks: 0,
                asked: monitor.inner.swaps_asked.load(Ordering::SeqCst),
            },
        };
        assert!(!monitor.swap_hunt_spent(&silent, SWAP_HUNT_ROUNDS - 1));
        assert!(monitor.swap_hunt_spent(&silent, SWAP_HUNT_ROUNDS));
        monitor.inner.swaps_asked.fetch_add(1, Ordering::SeqCst);
        assert!(
            !monitor.swap_hunt_spent(&silent, SWAP_HUNT_ROUNDS),
            "a tap that joined in the final round is owed its own rounds"
        );
        monitor.inner.swaps_asked.fetch_sub(1, Ordering::SeqCst);
        monitor.inner.is_connected.store(false, Ordering::SeqCst);
        assert!(
            !monitor.swap_hunt_spent(&silent, SWAP_HUNT_ROUNDS),
            "a hunt whose incumbent died keeps hunting"
        );
    }

    /// **The dark-lane proof cannot outlive its physical socket**
    /// (`wallet-security-auditor` third delta, NOTE 1): a pinned drop keeps
    /// the bind but takes the link down (`is_connected` and `announced`
    /// false, the pinned arm of `on_disconnected`), and the pull's hard path
    /// must stop reading a proof about a socket that is gone.
    #[tokio::test(start_paused = true)]
    async fn a_dropped_socket_carries_no_dark_lane_proof() {
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        monitor
            .inner
            .lane_rebound_at
            .store(DagMonitor::now_unix(), Ordering::SeqCst);
        let bind = monitor
            .install_bind("wss://ella.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        stage_live(&monitor, &bind);
        assert_eq!(
            monitor.recover_wallet_lane(|| false).await,
            LaneRecovery::GaveUp
        );
        assert!(
            monitor.wallet_lane_known_dark(),
            "proven on the live socket"
        );
        // The pinned drop itself — the real arm, not its two stores by hand
        // (`wallet-security-auditor`, fourth delta): the bind is kept, the
        // link stood down.
        *monitor
            .inner
            .direct_url
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(bind.url.clone());
        monitor.on_disconnected(&bind).await;
        assert!(
            monitor.is_current_bind(bind.gen),
            "pinned: the bind is kept"
        );
        assert!(
            !monitor.wallet_lane_known_dark(),
            "no proof over a socket that is gone"
        );
        monitor.inner.race_running.store(false, Ordering::SeqCst);
    }

    /// **A silence swap with no incumbent left spends no budget**
    /// (`consensus-auditor` fourth delta note 3): the incumbent dropped inside
    /// the winning round, so the swap cost nothing the budget counts.
    #[tokio::test]
    async fn a_silence_swap_with_no_incumbent_left_spends_no_budget() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let silent = RaceMode::Swap {
            from: "wss://ella.example/kaspa/mainnet/wrpc/borsh".to_string(),
            why: SwapWhy::Silent {
                gen: 1,
                ticks: 0,
                asked: monitor.inner.swaps_asked.load(Ordering::SeqCst),
            },
        };
        monitor
            .install_bind_leaving(
                "wss://leah.example/kaspa/mainnet/wrpc/borsh".to_string(),
                &silent,
            )
            .await
            .expect("arm the winner");
        assert_eq!(
            monitor.silence_deadline(),
            Some(link::SILENCE_DEADLINE),
            "nothing was retired, so nothing was spent"
        );
    }

    /// **A tap that joins a silence hunt makes it the user's** (`consensus-
    /// auditor` note e): re-cast as a swap they asked for, it gets that
    /// swap's rounds and name — joined at round three, it used to buy no
    /// probe of its own and still be logged as silence's.
    #[tokio::test]
    async fn a_tap_that_joins_a_silence_hunt_makes_it_the_users() {
        const FROM: &str = "wss://ella.example/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        let asked = monitor.inner.swaps_asked.load(Ordering::SeqCst);
        let silent = RaceMode::Swap {
            from: FROM.to_string(),
            why: SwapWhy::Silent {
                gen: 1,
                ticks: 0,
                asked,
            },
        };
        assert_eq!(monitor.joined_by_tap(&silent), None, "silence's own");
        monitor.inner.swaps_asked.fetch_add(1, Ordering::SeqCst);
        let theirs = RaceMode::Swap {
            from: FROM.to_string(),
            why: SwapWhy::Asked,
        };
        assert_eq!(monitor.joined_by_tap(&silent), Some(theirs.clone()));
        assert_eq!(monitor.joined_by_tap(&theirs), None, "already the user's");
        assert_eq!(monitor.joined_by_tap(&RaceMode::Cold), None);
    }

    // ── LINK-Q4 · bind-failed in absentia, the barren round's stamp ────────────

    fn pending(monitor: &DagMonitor) -> Vec<(String, u64, link::StrikeReason)> {
        monitor
            .inner
            .pending_strikes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    fn ledger_reason(monitor: &DagMonitor, url: &str) -> Option<(link::StrikeReason, u32)> {
        monitor
            .inner
            .health
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .last_reason(url)
    }

    /// A barren round of dial timeouts across `hosts`, nothing answered — the
    /// shape of LINK-Q1's 10:59:48 and 10:59:56 rounds.
    fn dark_round(hosts: &[&str]) -> link::RaceOutcome {
        link::RaceOutcome {
            failed: hosts
                .iter()
                .map(|host| {
                    (
                        format!("wss://{host}/kaspa/mainnet/wrpc/borsh"),
                        link::StrikeReason::DialTimeout,
                    )
                })
                .collect(),
            ..Default::default()
        }
    }

    /// **The fixture, through the monitor: LINK-Q1's 10:59:43 band hop.**
    /// `ivy`'s bind timed out three seconds after its probe answered; the next
    /// round found `ivy`, `sara`, `kate` and `leah` and every walk silent;
    /// `kate` connected at 11:00:02. The bind failure is parked, not convicted,
    /// the dark round stamps, and the settle at `kate`'s connect withholds it —
    /// recorded as `link-blackout`, never erased. The control, the same
    /// failure with a round that found the network alive: convicted.
    #[tokio::test]
    async fn a_failed_bind_is_parked_and_the_band_hop_acquits_it() {
        const IVY: &str = "wss://ivy.kaspa.green/kaspa/mainnet/wrpc/borsh";
        const KATE: &str = "wss://kate.kaspa.red/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor.install_bind(IVY.to_string()).await.expect("arm");

        monitor.judge_bind_failure(IVY, bind.gen, "wRPC -> WebSocket -> Connection timeout");
        assert!(
            matches!(pending(&monitor).as_slice(), [(u, _, link::StrikeReason::BindFailed)] if u == IVY),
            "parked, not convicted: {:?}",
            pending(&monitor)
        );
        assert_eq!(ledger_reason(&monitor, IVY), None, "nothing charged yet");

        monitor.retire_bind("bind-failed").await;
        assert!(
            monitor.stamp_barren_round(
                &dark_round(&[
                    "ivy.kaspa.green",
                    "sara.kaspa.red",
                    "kate.kaspa.red",
                    "leah.kaspa.red"
                ]),
                None
            ),
            "dark and no incumbent: the round is the only witness"
        );
        monitor.settle_pending_strike(Some(KATE));
        assert_eq!(
            ledger_reason(&monitor, IVY),
            Some((link::StrikeReason::LinkBlackout, 1)),
            "withheld as the phone's, and still on the record"
        );
        assert!(!monitor
            .inner
            .health
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_demoted(IVY, DagMonitor::now_unix()));

        // The control: no dark round between the failure and the connect.
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor.install_bind(IVY.to_string()).await.expect("arm");
        monitor.judge_bind_failure(IVY, bind.gen, "wRPC -> WebSocket -> Connection timeout");
        monitor.settle_pending_strike(Some(KATE));
        assert_eq!(
            ledger_reason(&monitor, IVY),
            Some((link::StrikeReason::BindFailed, 0)),
            "the network was alive at the next connect: the node's"
        );
    }

    /// The other two arms: a bind the node refused with a server error is
    /// earned guilt, convicted at once as `http-5xx` (a parked one could
    /// expire unjudged, and the in-absentia rule must never become its
    /// alibi); a bind WE retired under the dial is no one's fault.
    #[tokio::test]
    async fn a_bind_refused_with_a_server_error_is_convicted_now_and_ours_is_no_ones() {
        const URL: &str = "wss://ivy.kaspa.green/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor.install_bind(URL.to_string()).await.expect("arm");
        monitor.judge_bind_failure(
            URL,
            bind.gen,
            "wRPC -> WebSocket -> HTTP error: 500 Internal Server Error",
        );
        assert_eq!(
            ledger_reason(&monitor, URL),
            Some((link::StrikeReason::HttpServerError, 0))
        );
        assert!(pending(&monitor).is_empty(), "convicted, so nothing parked");

        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor.install_bind(URL.to_string()).await.expect("arm");
        monitor.retire_bind("superseded").await;
        monitor.judge_bind_failure(URL, bind.gen, "wRPC -> WebSocket -> Connection timeout");
        assert!(pending(&monitor).is_empty(), "retired under the dial: ours");
        assert_eq!(ledger_reason(&monitor, URL), None);
    }

    /// **A parked drop survives a bind failure on the next node** — the
    /// single slot the list replaced would have overwritten it, acquitting the
    /// drop by accident. Both settle at the next connect; a second failure on
    /// the same node replaces its own entry.
    #[tokio::test]
    async fn a_parked_drop_survives_a_bind_failure_on_another_node() {
        const KATE: &str = "wss://kate.kaspa.red/kaspa/mainnet/wrpc/borsh";
        const IVY: &str = "wss://ivy.kaspa.green/kaspa/mainnet/wrpc/borsh";
        const LEAH: &str = "wss://leah.kaspa.red/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.set_pending_strike(KATE.to_string(), link::StrikeReason::Drop);
        let bind = monitor.install_bind(IVY.to_string()).await.expect("arm");
        monitor.judge_bind_failure(IVY, bind.gen, "wRPC -> WebSocket -> Connection timeout");
        monitor.judge_bind_failure(IVY, bind.gen, "wRPC -> WebSocket -> Connection reset");
        assert_eq!(pending(&monitor).len(), 2, "{:?}", pending(&monitor));

        monitor.settle_pending_strike(Some(LEAH));
        assert!(pending(&monitor).is_empty());
        assert_eq!(
            ledger_reason(&monitor, KATE),
            Some((link::StrikeReason::Drop, 0))
        );
        assert_eq!(
            ledger_reason(&monitor, IVY),
            Some((link::StrikeReason::BindFailed, 0))
        );
    }

    /// **The stamp reads the evidence, not the mode** (IDEAS 2026-09-26, the
    /// phone-fault stamp gated on "dark"; routed by D-340 item 9). No
    /// incumbent, or one that stayed silent through the round — a silence
    /// hunt's — and the round is the only witness: it stamps. One that ticked
    /// through the round vouches for the network: no stamp (CONCERNS-4). A
    /// round where something answered stamps nothing either way.
    #[tokio::test]
    async fn the_stamp_reads_the_prover_not_the_mode() {
        let hosts = ["ivy.kaspa.green", "sara.kaspa.red"];
        let stamped = |m: &DagMonitor| m.inner.phone_fault_round_at.load(Ordering::SeqCst) != 0;

        // Dark, nothing up: stamps.
        let monitor = DagMonitor::mainnet().expect("construct");
        assert!(monitor.stamp_barren_round(&dark_round(&hosts), monitor.round_prover()));
        assert!(stamped(&monitor));

        // Behind a live socket.
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://nina.kaspa.blue/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm");
        stage_live(&monitor, &bind);
        let prover = monitor.round_prover();
        assert!(prover.is_some());
        assert!(
            monitor.stamp_barren_round(&dark_round(&hosts), prover),
            "an incumbent silent through the round vouches for nothing (a silence hunt's)"
        );

        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://nina.kaspa.blue/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm");
        stage_live(&monitor, &bind);
        let prover = monitor.round_prover();
        monitor.on_notification(&bind, daa_tick(1));
        assert!(
            !monitor.stamp_barren_round(&dark_round(&hosts), prover),
            "it ticked through the round: the network works"
        );
        assert!(!stamped(&monitor));

        // Something answered: no stamp, whoever vouches.
        let monitor = DagMonitor::mainnet().expect("construct");
        let mut lit = dark_round(&hosts);
        lit.answered = 1;
        assert!(!monitor.stamp_barren_round(&lit, None));
        assert!(!stamped(&monitor));
    }

    // ── LINK-Q4 · the two-stage silence clock and the held winner ─────────────

    /// **Two stages per silence, and one extension** (D-337 (ii)): the
    /// pre-dial falls at [`link::predial_after`] (3 s for nine, 12 s for
    /// eighteen), the swap at the deadline; an extension moves both one
    /// deadline later, once; a tick re-arms everything; the budget off arms
    /// nothing.
    #[test]
    fn the_silence_clock_predials_then_swaps_and_extends_once() {
        let nine = Some(link::SILENCE_DEADLINE);
        let eighteen = Some(link::SILENCE_DEADLINE * 2);
        let t0 = tokio::time::Instant::now();
        let s = Duration::from_secs;
        let mut clock = SilenceClock::default();
        assert_eq!(clock.next(nine), None, "nothing up");
        clock.up(t0);
        assert_eq!(clock.next(nine), Some((t0 + s(3), SilenceStage::Predial)));
        assert_eq!(
            clock.next(eighteen),
            Some((t0 + s(12), SilenceStage::Predial))
        );
        assert_eq!(clock.next(None), None, "the budget off: no stage at all");

        clock.fire(SilenceStage::Predial);
        assert_eq!(clock.next(nine), Some((t0 + s(9), SilenceStage::Swap)));
        clock.fire(SilenceStage::Swap);
        assert_eq!(clock.next(nine), None, "one swap per silence");

        let t1 = t0 + s(20);
        clock.tick(t1);
        assert_eq!(
            clock.next(nine),
            Some((t1 + s(3), SilenceStage::Predial)),
            "a tick re-arms both"
        );

        clock.extend();
        assert_eq!(clock.next(nine), Some((t1 + s(12), SilenceStage::Predial)));
        clock.fire(SilenceStage::Predial);
        assert_eq!(clock.next(nine), Some((t1 + s(18), SilenceStage::Swap)));
        assert_eq!(clock.due(nine), Some(t1 + s(18)));
        let t2 = t1 + s(30);
        clock.tick(t2);
        assert_eq!(
            clock.next(nine),
            Some((t2 + s(3), SilenceStage::Predial)),
            "the extension is this silence's only"
        );

        // A swap stage fired straight away (no pre-dial first) is the swap.
        let mut direct = SilenceClock::default();
        direct.up(t0);
        direct.fire(SilenceStage::Swap);
        assert_eq!(direct.next(nine), None);
    }

    /// **Through the socket's own task** (paused time): at 3 s of silence the
    /// pre-dial asks for a hunt (held single-flight, so nothing is kicked); at
    /// 9 s the swap stage marks the socket due and kicks the hunt that holds
    /// the flag; a tick clears the mark.
    #[tokio::test(start_paused = true)]
    async fn a_silent_socket_predials_at_three_and_is_due_at_nine() {
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        let bind = monitor
            .install_bind("wss://kate.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        let _ = bind.client.rpc_ctl().signal_open().await;
        wait_for("the bind to publish", || {
            bind.announced.load(Ordering::SeqCst)
        })
        .await;

        let kicked = Arc::new(AtomicBool::new(false));
        let waiter = {
            let inner = monitor.inner.clone();
            let kicked = kicked.clone();
            tokio::spawn(async move {
                inner.race_kick.notified().await;
                kicked.store(true, Ordering::SeqCst);
            })
        };
        tokio::time::sleep(Duration::from_secs(4)).await;
        assert!(
            !kicked.load(Ordering::SeqCst),
            "a pre-dial holds nothing up: no kick"
        );
        assert!(
            !bind.swap_due.load(Ordering::SeqCst),
            "and nothing is due yet"
        );

        tokio::time::sleep(Duration::from_secs(6)).await;
        wait_for("the swap stage to kick the held hunt", || {
            kicked.load(Ordering::SeqCst)
        })
        .await;
        assert!(
            bind.swap_due.load(Ordering::SeqCst),
            "the held winner may come in"
        );
        assert!(monitor.is_current_bind(bind.gen), "still no verdict");

        let _ = bind.notification_tx.send(daa_tick(1)).await;
        wait_for("the tick to fold", || {
            bind.ticks.load(Ordering::SeqCst) == 1
        })
        .await;
        assert!(!bind.swap_due.load(Ordering::SeqCst), "a tick clears it");
        waiter.abort();
        monitor.inner.race_running.store(false, Ordering::SeqCst);
    }

    /// **The held winner's gate.** A silence hunt still silence's own holds
    /// until the swap is due, the incumbent is gone, a tap makes it the
    /// user's, or the network moved under it — and stands down if the
    /// incumbent speaks. Every other mode lets its winner in at once.
    #[tokio::test]
    async fn a_held_winner_comes_in_on_the_swap_the_tap_the_move_or_the_death() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://kate.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm");
        stage_live(&monitor, &bind);
        bind.connected_mono_ms.store(mono_ms(), Ordering::Relaxed);
        let silent = RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Silent {
                gen: bind.gen,
                ticks: 0,
                asked: monitor.inner.swaps_asked.load(Ordering::SeqCst),
            },
        };
        assert_eq!(
            monitor.install_gate(&silent),
            None,
            "silent, not yet due: hold"
        );

        bind.swap_due.store(true, Ordering::SeqCst);
        assert_eq!(
            monitor.install_gate(&silent),
            Some(Held::Install),
            "the swap fell"
        );
        bind.swap_due.store(false, Ordering::SeqCst);

        monitor
            .inner
            .network_moved_mono_ms
            .store(mono_ms() + 1, Ordering::SeqCst);
        assert!(monitor.network_moved_under(&bind));
        assert_eq!(
            monitor.install_gate(&silent),
            Some(Held::Install),
            "the network moved"
        );
        monitor.on_notification(&bind, daa_tick(3));
        assert_eq!(
            monitor.install_gate(&silent),
            Some(Held::Install),
            "a socket on a network the phone left is never back, whatever it says"
        );
        monitor
            .inner
            .network_moved_mono_ms
            .store(0, Ordering::SeqCst);
        assert_eq!(
            monitor.install_gate(&silent),
            Some(Held::StandDown),
            "it spoke on the network the phone is on: keep it"
        );

        let fresh = RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Silent {
                gen: bind.gen,
                ticks: 1,
                asked: monitor.inner.swaps_asked.load(Ordering::SeqCst),
            },
        };
        monitor.inner.swaps_asked.fetch_add(1, Ordering::SeqCst);
        assert_eq!(
            monitor.install_gate(&fresh),
            Some(Held::Install),
            "the user tapped"
        );

        let other = RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Silent {
                gen: bind.gen + 7,
                ticks: 0,
                asked: monitor.inner.swaps_asked.load(Ordering::SeqCst),
            },
        };
        assert_eq!(
            monitor.install_gate(&other),
            Some(Held::Install),
            "its incumbent is gone"
        );

        for mode in [
            RaceMode::Swap {
                from: bind.url.clone(),
                why: SwapWhy::Asked,
            },
            RaceMode::Swap {
                from: bind.url.clone(),
                why: SwapWhy::Moved {
                    gen: bind.gen,
                    asked: 0,
                    tapped: false,
                },
            },
        ] {
            assert_eq!(monitor.install_gate(&mode), Some(Held::Install), "{mode:?}");
        }
        assert_eq!(
            monitor.install_gate(&RaceMode::Cold),
            Some(Held::StandDown),
            "a cold race never binds over a live socket"
        );
    }

    /// **A pin, or a pause, set while a winner is held ends the errand**
    /// (`wallet-security-auditor`, LINK-Q4 round 1 BLOCK; L73): the hold is an
    /// await between the race's guard and its bind, so the gate asks the guard
    /// first, on every wake — never a public node installed over the user's
    /// own, never a dial behind the battery posture. The pin here is set before
    /// the hold's first read; every wake reads the same gate.
    #[tokio::test]
    async fn a_pin_or_a_pause_during_a_hold_stands_the_winner_down() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://kate.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm");
        stage_live(&monitor, &bind);
        let silent = RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Silent {
                gen: bind.gen,
                ticks: 0,
                asked: monitor.inner.swaps_asked.load(Ordering::SeqCst),
            },
        };
        bind.swap_due.store(true, Ordering::SeqCst);
        assert_eq!(
            monitor.install_gate(&silent),
            Some(Held::Install),
            "due: in"
        );

        *monitor
            .inner
            .direct_url
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) =
            Some("wss://mine.example/kaspa/mainnet/wrpc/borsh".to_string());
        assert_eq!(
            monitor.install_gate(&silent),
            Some(Held::StandDown),
            "pinned mid-hold"
        );
        assert_eq!(
            monitor
                .hold_winner(&silent, "wss://ivy.example/borsh")
                .await,
            Held::StandDown
        );
        *monitor
            .inner
            .direct_url
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = None;

        monitor.inner.paused.store(true, Ordering::SeqCst);
        assert_eq!(
            monitor.install_gate(&silent),
            Some(Held::StandDown),
            "paused mid-hold"
        );
    }

    /// **The hold itself is bounded and wakes on the kick** (paused time): a
    /// winner held behind a silent incumbent comes in the moment the swap
    /// stage marks the socket due and kicks; one whose swap never falls is
    /// dropped as stale after the pre-dial's lead and a deadline.
    #[tokio::test(start_paused = true)]
    async fn a_held_winner_waits_for_the_kick_and_goes_stale_past_its_bound() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://kate.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm");
        stage_live(&monitor, &bind);
        let silent = RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Silent {
                gen: bind.gen,
                ticks: 0,
                asked: monitor.inner.swaps_asked.load(Ordering::SeqCst),
            },
        };
        let due = {
            let inner = monitor.inner.clone();
            let bind = bind.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_secs(6)).await;
                bind.swap_due.store(true, Ordering::SeqCst);
                inner.race_kick.notify_one();
            })
        };
        let started = tokio::time::Instant::now();
        assert_eq!(
            monitor
                .hold_winner(&silent, "wss://ivy.example/borsh")
                .await,
            Held::Install
        );
        assert!(started.elapsed() >= Duration::from_secs(6));
        assert!(started.elapsed() < Duration::from_secs(7));
        due.await.expect("the stage task");

        bind.swap_due.store(false, Ordering::SeqCst);
        let started = tokio::time::Instant::now();
        let held = tokio::time::timeout(
            Duration::from_secs(60),
            monitor.hold_winner(&silent, "wss://ivy.example/borsh"),
        )
        .await
        .expect("a hold is bounded — it must not wait forever");
        assert_eq!(held, Held::Stale);
        assert!(started.elapsed() >= link::PREDIAL_LEAD + link::SILENCE_DEADLINE);
    }

    // ── LINK-Q4 · the phone's own network events ──────────────────────────────

    /// **The kinds, while connected** (the single-flight flag held, so a
    /// hunt shows as a kick): the first `Available` is the state Android
    /// reports as the callback registers — nothing moves; a `Lost` then an
    /// `Available`, or a `Moved`, is the socket's network left behind — a hunt
    /// is asked for; a `Changed` kicks only a hunt already running; round
    /// trips from the old network are forgotten.
    #[tokio::test]
    async fn the_phones_network_events_move_a_live_socket_only_when_it_is_left_behind() {
        async fn kicked(m: &DagMonitor) -> bool {
            tokio::time::timeout(Duration::from_millis(20), m.inner.race_kick.notified())
                .await
                .is_ok()
        }
        let live = || async {
            let monitor = DagMonitor::mainnet().expect("construct");
            let bind = monitor
                .install_bind("wss://nina.kaspa.blue/kaspa/mainnet/wrpc/borsh".to_string())
                .await
                .expect("arm");
            stage_live(&monitor, &bind);
            bind.connected_mono_ms.store(mono_ms(), Ordering::Relaxed);
            monitor.inner.race_running.store(true, Ordering::SeqCst);
            (monitor, bind)
        };

        let (monitor, bind) = live().await;
        tokio::time::sleep(Duration::from_millis(2)).await;
        monitor.network_event(NetworkEvent::Available).await;
        assert!(
            !monitor.network_moved_under(&bind),
            "a state report moves nothing"
        );
        assert!(!kicked(&monitor).await);

        let (monitor, bind) = live().await;
        for i in 0..15u64 {
            monitor
                .inner
                .rtt
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .record(&bind.url, 1 + i * 2_000, 175);
        }
        assert!(
            monitor
                .inner
                .rtt
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .median(&bind.url)
                .is_some(),
            "a full window ranks before the move"
        );
        tokio::time::sleep(Duration::from_millis(2)).await;
        monitor.network_event(NetworkEvent::Lost).await;
        assert!(
            !monitor.network_moved_under(&bind),
            "lost alone: nothing to move to"
        );
        monitor.network_event(NetworkEvent::Available).await;
        assert!(
            monitor.network_moved_under(&bind),
            "back after a loss: a different network"
        );
        assert!(kicked(&monitor).await, "a hunt behind it was asked for");
        assert!(
            monitor
                .inner
                .rtt
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .median(&bind.url)
                .is_none(),
            "the old network's round trips are gone (RFC 8305 §4)"
        );

        let (monitor, bind) = live().await;
        tokio::time::sleep(Duration::from_millis(2)).await;
        monitor.network_event(NetworkEvent::Moved).await;
        assert!(monitor.network_moved_under(&bind));
        assert!(kicked(&monitor).await);

        let (monitor, bind) = live().await;
        monitor.network_event(NetworkEvent::Changed).await;
        assert!(!monitor.network_moved_under(&bind), "a hint moves nothing");
        assert!(kicked(&monitor).await, "but kicks the hunt in flight");
        monitor.inner.race_running.store(false, Ordering::SeqCst);
        monitor.network_event(NetworkEvent::Changed).await;
        assert!(!kicked(&monitor).await, "and asks for none");
    }

    /// A socket on a left network, pinned: its own retry loop owns it — no
    /// hunt, no kick. Paused: nothing dials.
    #[tokio::test]
    async fn a_moved_network_leaves_a_pinned_or_paused_link_alone() {
        const URL: &str = "wss://mine.example/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::try_new(NetworkId::new(NetworkType::Mainnet), Some(URL.into()))
            .expect("construct");
        let bind = monitor.install_bind(URL.to_string()).await.expect("arm");
        stage_live(&monitor, &bind);
        bind.connected_mono_ms.store(mono_ms(), Ordering::Relaxed);
        tokio::time::sleep(Duration::from_millis(2)).await;
        monitor.network_event(NetworkEvent::Moved).await;
        assert!(!monitor.is_searching());
        assert!(tokio::time::timeout(
            Duration::from_millis(20),
            monitor.inner.race_kick.notified()
        )
        .await
        .is_err());

        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.inner.paused.store(true, Ordering::SeqCst);
        monitor.network_event(NetworkEvent::Moved).await;
        assert!(!monitor.is_searching(), "paused: the battery posture holds");
    }

    /// The moved-network hunt's winner retires its incumbent as
    /// `network-swap` — recorded, not judged, and not the silence budget's.
    #[tokio::test]
    async fn a_moved_network_hunt_retires_as_a_network_swap_and_spends_no_budget() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://nina.kaspa.blue/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm");
        let moved = RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Moved {
                gen: bind.gen,
                asked: 0,
                tapped: false,
            },
        };
        assert_eq!(monitor.retire_cause(&moved), NETWORK_SWAP);
        assert!(!retirement_judges_the_link(NETWORK_SWAP));
        stage_live(&monitor, &bind);
        monitor
            .install_bind_leaving(
                "wss://ivy.kaspa.green/kaspa/mainnet/wrpc/borsh".into(),
                &moved,
            )
            .await
            .expect("arm the winner");
        assert_eq!(monitor.silence_deadline(), Some(link::SILENCE_DEADLINE));
        assert_eq!(last_run(&monitor, &bind.url), Some(30));
    }

    // ── LINK-Q4 · a walk page in flight must not convict a node ───────────────

    /// **Which retirements count against a page** (L249's field line: a tap's
    /// `superseded` was counted): only the link's own trouble — the silence
    /// swap, the watchdog, the socket's death. Every cause the monitor uses.
    #[test]
    fn only_the_links_own_trouble_counts_against_a_page() {
        for cause in [SILENCE_SWAP, "watchdog-stall", "ctl-drop"] {
            assert!(retirement_judges_the_link(cause), "{cause}");
        }
        for cause in [
            "superseded",
            NETWORK_SWAP,
            "paused",
            "pause-lost-bind",
            "repin",
            "stopped",
            "manual-reconnect",
            "lane-dark",
            "bind-failed",
            "bind-timeout",
            "demoted-refusal",
        ] {
            assert!(!retirement_judges_the_link(cause), "{cause}");
        }
    }

    /// And the monitor tells the handle, so the walk can ask: a socket our
    /// hand retired is remembered as such, one the link lost as judged.
    #[tokio::test]
    async fn a_retirement_tells_the_handle_whether_it_judged_the_link() {
        let monitor = DagMonitor::mainnet().expect("construct");
        for (cause, judged) in [("superseded", false), ("ctl-drop", true), ("paused", false)] {
            let bind = monitor
                .install_bind("wss://nina.kaspa.blue/kaspa/mainnet/wrpc/borsh".to_string())
                .await
                .expect("arm");
            stage_live(&monitor, &bind);
            let socket = monitor.inner.link_rpc.bound_identity().expect("bound");
            monitor.retire_bind(cause).await;
            assert_eq!(
                monitor.inner.link_rpc.retired_judged(socket),
                Some(judged),
                "{cause}"
            );
        }
    }

    /// Put a page in flight on `bind`, sent at `sent` on the monotonic clock.
    fn page_on(monitor: &DagMonitor, bind: &BoundSocket, sent: u64, catch_up: bool) {
        monitor.inner.walk.set_in_flight(Some(walk::PageInFlight {
            sent_mono_ms: sent,
            socket: Some(Arc::as_ptr(&bind.client) as usize),
            catch_up,
        }));
    }

    /// **Our own catch-up page can explain a silence only when the socket was
    /// alive under it**: a catch-up page, on this socket, sent at or before
    /// its last tick. A tip page, another socket's page, a page sent after the
    /// socket had already gone quiet (`ivy` at 23:59, LINK-Q3's capture), or a
    /// socket that never ticked: not explained.
    #[tokio::test]
    async fn a_catch_up_page_explains_a_silence_only_on_a_socket_alive_under_it() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://nina.kaspa.blue/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm");
        stage_live(&monitor, &bind);
        assert!(!monitor.page_explains_silence(&bind), "no page in flight");
        page_on(&monitor, &bind, 100, true);
        assert!(!monitor.page_explains_silence(&bind), "never ticked");
        bind.last_tick_mono_ms.store(150, Ordering::Relaxed);
        assert!(
            monitor.page_explains_silence(&bind),
            "ticked after the page went out"
        );
        bind.last_tick_mono_ms.store(100, Ordering::Relaxed);
        assert!(monitor.page_explains_silence(&bind), "at the same instant");
        bind.last_tick_mono_ms.store(99, Ordering::Relaxed);
        assert!(
            !monitor.page_explains_silence(&bind),
            "already quiet when it went out"
        );
        bind.last_tick_mono_ms.store(150, Ordering::Relaxed);
        page_on(&monitor, &bind, 100, false);
        assert!(
            !monitor.page_explains_silence(&bind),
            "a tip page holds nothing back"
        );
        monitor.inner.walk.set_in_flight(Some(walk::PageInFlight {
            sent_mono_ms: 100,
            socket: Some(1),
            catch_up: true,
        }));
        assert!(
            !monitor.page_explains_silence(&bind),
            "another socket's page"
        );
        monitor.inner.walk.set_in_flight(None);
    }

    /// **Through the socket's task** (paused time): a silence under our own
    /// catch-up page moves both stages one deadline later — the swap falls at
    /// 18 s, not 9 — once (the pre-dial's move is the clock's own test). The
    /// single-flight flag is held, so no hunt dials.
    #[tokio::test(start_paused = true)]
    async fn a_silence_under_our_own_catch_up_page_waits_one_more_deadline() {
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        let bind = monitor
            .install_bind("wss://kate.example/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm a bind");
        let _ = bind.client.rpc_ctl().signal_open().await;
        wait_for("the bind to publish", || {
            bind.announced.load(Ordering::SeqCst)
        })
        .await;
        let _ = bind.notification_tx.send(daa_tick(1)).await;
        wait_for("the tick", || bind.ticks.load(Ordering::SeqCst) == 1).await;
        page_on(
            &monitor,
            &bind,
            bind.last_tick_mono_ms.load(Ordering::Relaxed),
            true,
        );

        tokio::time::sleep(Duration::from_secs(17)).await;
        assert!(
            !bind.swap_due.load(Ordering::SeqCst),
            "nine seconds passed under our page, and seventeen: not due yet"
        );
        tokio::time::sleep(Duration::from_secs(2)).await;
        wait_for("the extended swap stage", || {
            bind.swap_due.load(Ordering::SeqCst)
        })
        .await;
        monitor.inner.walk.set_in_flight(None);
        monitor.inner.race_running.store(false, Ordering::SeqCst);
    }

    /// **The watchdog executes a silence under our own page without a
    /// strike** — recorded as `own-load`, never parked; the same execution
    /// with no page still parks its stall.
    #[tokio::test]
    async fn the_watchdog_executes_under_our_own_page_but_charges_no_strike() {
        const URL: &str = "wss://nina.kaspa.blue/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        let bind = monitor.install_bind(URL.to_string()).await.expect("arm");
        mark_accepted(&monitor, &bind, 60);
        bind.last_tick_at
            .store(DagMonitor::now_unix() - 40, Ordering::Relaxed);
        bind.last_tick_mono_ms.store(500, Ordering::Relaxed);
        page_on(&monitor, &bind, 400, true);
        monitor.reconnect(true).await.expect("stalled reconnect");
        assert!(!never_retired(&bind), "executed");
        assert!(pending(&monitor).is_empty(), "nothing parked");
        assert_eq!(
            ledger_reason(&monitor, URL),
            Some((link::StrikeReason::OwnLoad, 1)),
            "withheld as our own load, and on the record"
        );
        monitor.inner.walk.set_in_flight(None);

        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        let bind = monitor.install_bind(URL.to_string()).await.expect("arm");
        mark_accepted(&monitor, &bind, 60);
        bind.last_tick_at
            .store(DagMonitor::now_unix() - 40, Ordering::Relaxed);
        monitor.reconnect(true).await.expect("stalled reconnect");
        assert!(
            matches!(pending(&monitor).as_slice(), [(u, _, link::StrikeReason::Stall)] if u == URL),
            "no page: the stall is parked as before"
        );
    }

    // ── LINK-Q4 · round trips ─────────────────────────────────────────────────

    /// **A round trip lands in its node's window only while the socket is
    /// the bound one**, and a timeout lands at its deadline.
    #[tokio::test]
    async fn a_round_trip_is_booked_to_the_bound_socket_only() {
        const URL: &str = "wss://ivy.kaspa.green/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor.install_bind(URL.to_string()).await.expect("arm");
        stage_live(&monitor, &bind);
        for _ in 0..3 {
            monitor.note_rtt(&bind, 1, 175, false);
        }
        monitor.note_rtt(&bind, 1, 5_000, true);
        let book = |m: &DagMonitor| {
            m.inner
                .rtt
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .samples_for_tests(URL)
        };
        assert_eq!(book(&monitor), vec![175, 175, 175, 5_000]);
        assert!(bind.last_probe_mono_ms.load(Ordering::Relaxed) > 0);
        monitor.retire_bind("superseded").await;
        monitor.note_rtt(&bind, 1, 175, false);
        assert_eq!(book(&monitor).len(), 4, "a retired socket books nothing");
    }

    // ── LINK-Q4 round 1 · the race loop itself, driven offline ──────────────

    /// A loopback WebSocket server that completes the handshake and holds
    /// every socket open: a node the bind can reach, without a node.
    async fn holding_ws_server() -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                tokio::spawn(async move {
                    if let Ok(ws) = tokio_tungstenite::accept_async(stream).await {
                        let _held = ws;
                        std::future::pending::<()>().await;
                    }
                });
            }
        });
        format!("ws://{addr}/")
    }

    /// A port that refuses every dial.
    fn refusing_port() -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        drop(listener);
        format!("ws://{addr}/")
    }

    fn won_by(url: &str) -> link::RaceOutcome {
        link::RaceOutcome {
            winner: Some(link::ProbeOutcome {
                url: url.to_string(),
                server_version: String::new(),
                virtual_daa_score: 0,
                rpc_api_version: 1,
                info_ms: 0,
            }),
            ..Default::default()
        }
    }

    /// **A node that wins every probe and fails every bind cannot hold the
    /// wallet dark** (`consensus-auditor`, LINK-Q4 round 1 BLOCK). `x` answers
    /// first in every round it is allowed into and refuses every bind; `y`
    /// binds. Parked, `x` sits out the next round, `y` connects, and `x`'s
    /// strike is judged — and committed — at `y`'s connect. Driven through the
    /// real race loop with a scripted round.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_node_that_wins_probes_and_fails_binds_sits_out_until_another_connects() {
        let x = refusing_port();
        let y = holding_ws_server().await;
        let monitor = DagMonitor::mainnet().expect("construct");
        let asked: Arc<Mutex<Vec<RoundAsked>>> = Arc::new(Mutex::new(Vec::new()));
        {
            let (x, y, asked) = (x.clone(), y.clone(), asked.clone());
            *monitor
                .inner
                .race_script
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) =
                Some(Box::new(move |round: &RoundAsked| {
                    asked.lock().unwrap().push(round.clone());
                    won_by(if round.excluded.contains(&x) { &y } else { &x })
                }));
        }
        assert!(monitor.spawn_race());
        wait_for("y to connect", || {
            monitor.is_connected() && monitor.current_url().as_deref() == Some(y.as_str())
        })
        .await;
        assert_eq!(
            ledger_reason(&monitor, &x),
            Some((link::StrikeReason::BindFailed, 0)),
            "x judged at y's connect"
        );
        let rounds = asked.lock().unwrap().clone();
        assert!(
            !rounds[0].excluded.contains(&x),
            "x races until its bind fails"
        );
        assert!(
            rounds[1].excluded.contains(&x),
            "then sits out until judged"
        );
        monitor.stop().await.expect("stop");
    }

    /// Past the TTL a parked failure no longer excludes its node (it would
    /// expire unjudged at the settle anyway); a drop or a stall never
    /// excluded anyone — their node reconnecting refutes them (D-084).
    #[test]
    fn only_a_fresh_bind_failure_sits_its_node_out() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let now = DagMonitor::now_unix();
        {
            let mut pending = monitor
                .inner
                .pending_strikes
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            pending.push((
                "wss://fresh".into(),
                now - 5,
                link::StrikeReason::BindFailed,
            ));
            pending.push((
                "wss://edge".into(),
                now - link::PENDING_STRIKE_TTL_SECS,
                link::StrikeReason::BindFailed,
            ));
            pending.push((
                "wss://stale".into(),
                now - link::PENDING_STRIKE_TTL_SECS - 1,
                link::StrikeReason::BindFailed,
            ));
            pending.push(("wss://dropped".into(), now, link::StrikeReason::Drop));
            pending.push(("wss://stalled".into(), now, link::StrikeReason::Stall));
        }
        let out = monitor.bind_failures_awaiting_judgment(now);
        let want: HashSet<String> = ["wss://fresh".to_string(), "wss://edge".to_string()]
            .into_iter()
            .collect();
        assert_eq!(out, want);
    }

    /// **The pantry is ranked by the CLEAN ranks** (`consensus-auditor`,
    /// round 1): a node with a live strike keeps no fast-lane seat by its
    /// median, through the real race loop.
    #[tokio::test]
    async fn a_struck_nodes_median_buys_it_no_fast_lane_seat() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let url = |h: &str| format!("wss://{h}/kaspa/mainnet/wrpc/borsh");
        let now = DagMonitor::now_unix();
        {
            let mut health = monitor
                .inner
                .health
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            for (i, h) in ["struck", "a", "b", "c"].into_iter().enumerate() {
                health.mark_healthy(&url(h), now - i as u64);
            }
            health.strike(&url("struck"), now, link::StrikeReason::Drop);
        }
        {
            let mut book = monitor
                .inner
                .rtt
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            for (h, rtt) in [("struck", 50), ("a", 300)] {
                for i in 0..15u64 {
                    book.record(&url(h), 1 + i * 2_000, rtt);
                }
            }
        }
        let asked: Arc<Mutex<Option<RoundAsked>>> = Arc::new(Mutex::new(None));
        {
            let asked = asked.clone();
            *monitor
                .inner
                .race_script
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) =
                Some(Box::new(move |round: &RoundAsked| {
                    *asked.lock().unwrap() = Some(round.clone());
                    link::RaceOutcome::default()
                }));
        }
        monitor.inner.paused.store(false, Ordering::SeqCst);
        let hunt = {
            let monitor = monitor.clone();
            tokio::spawn(async move { monitor.race_loop(RaceMode::Cold).await })
        };
        wait_for("one round", || asked.lock().unwrap().is_some()).await;
        monitor.inner.paused.store(true, Ordering::SeqCst);
        monitor.inner.race_kick.notify_one();
        let _ = hunt.await;
        let round = asked.lock().unwrap().clone().unwrap();
        assert_eq!(round.pantry.first(), Some(&url("a")), "{:?}", round.pantry);
        assert!(!round.prefer.contains_key(&url("struck")));
    }

    /// **A hunt running when the network moves becomes the moved-network
    /// hunt** (`wallet-security-auditor`, round 1): not exhausted while the
    /// re-cast is pending; a silence hunt's winner retires its incumbent as a
    /// network swap, not a silence swap; the moved hunt excludes nothing of
    /// its own.
    #[tokio::test]
    async fn a_hunt_whose_network_moved_is_recast_and_leaves_for_the_move() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://nina.kaspa.blue/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm");
        stage_live(&monitor, &bind);
        bind.connected_mono_ms.store(mono_ms(), Ordering::Relaxed);
        let silent = RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Silent {
                gen: bind.gen,
                ticks: 0,
                asked: monitor.inner.swaps_asked.load(Ordering::SeqCst),
            },
        };
        let asked = RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Asked,
        };
        assert_eq!(monitor.recast_if_moved(&silent), None);
        assert!(monitor.swap_hunt_spent(&asked, SWAP_HUNT_ROUNDS));
        assert_eq!(monitor.retire_cause(&silent), SILENCE_SWAP);

        monitor
            .inner
            .network_moved_mono_ms
            .store(mono_ms() + 1, Ordering::SeqCst);
        let moved = RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Moved {
                gen: bind.gen,
                asked: 0,
                tapped: false,
            },
        };
        assert_eq!(monitor.recast_if_moved(&silent), Some(moved.clone()));
        let theirs = RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Moved {
                gen: bind.gen,
                asked: 0,
                tapped: true,
            },
        };
        assert_eq!(
            monitor.recast_if_moved(&asked),
            Some(theirs.clone()),
            "the user's swap keeps its 'leave this node' through the move"
        );
        assert!(round_exclusions(HashSet::new(), &theirs).contains(&bind.url));
        assert_eq!(monitor.recast_if_moved(&moved), None, "already it");
        assert!(
            !monitor.swap_hunt_spent(&asked, SWAP_HUNT_ROUNDS),
            "the move's re-cast is pending: not exhausted"
        );
        assert_eq!(monitor.retire_cause(&silent), NETWORK_SWAP);
        assert!(round_exclusions(HashSet::new(), &moved).is_empty());
        assert!(round_exclusions(HashSet::new(), &silent).contains(&bind.url));

        // A tap landing between the loop head's two reads is not absorbed:
        // the silence hunt's own count carries into the re-cast, and the next
        // loop head hears the tap.
        monitor.inner.swaps_asked.fetch_add(1, Ordering::SeqCst);
        assert_eq!(monitor.recast_if_moved(&silent), Some(moved.clone()));
        assert_eq!(
            monitor.joined_by_tap(&moved),
            Some(RaceMode::Swap {
                from: bind.url.clone(),
                why: SwapWhy::Moved {
                    gen: bind.gen,
                    asked: 1,
                    tapped: true,
                },
            })
        );
    }

    /// **The loop re-casts a hunt whose network moved, and it still ends**
    /// (paused time, a round that finds nothing): as the moved-network hunt it
    /// gets its own rounds and gives up after them. Without the re-cast at the
    /// loop head the pending re-cast keeps the hunt from ever counting as spent,
    /// and it would hunt forever.
    #[tokio::test(start_paused = true)]
    async fn a_silence_hunt_whose_network_moved_is_recast_and_still_ends() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let bind = monitor
            .install_bind("wss://nina.kaspa.blue/kaspa/mainnet/wrpc/borsh".to_string())
            .await
            .expect("arm");
        stage_live(&monitor, &bind);
        bind.connected_mono_ms.store(mono_ms(), Ordering::Relaxed);
        monitor
            .inner
            .network_moved_mono_ms
            .store(mono_ms() + 1, Ordering::SeqCst);
        let rounds = Arc::new(AtomicU32::new(0));
        {
            let rounds = rounds.clone();
            *monitor
                .inner
                .race_script
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) =
                Some(Box::new(move |_: &RoundAsked| {
                    rounds.fetch_add(1, Ordering::SeqCst);
                    link::RaceOutcome::default()
                }));
        }
        let silent = RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Silent {
                gen: bind.gen,
                ticks: 0,
                asked: monitor.inner.swaps_asked.load(Ordering::SeqCst),
            },
        };
        tokio::time::timeout(Duration::from_secs(120), monitor.race_loop(silent))
            .await
            .expect("the re-cast hunt spends its own rounds and ends");
        assert_eq!(
            rounds.load(Ordering::SeqCst),
            SWAP_HUNT_ROUNDS,
            "its own rounds"
        );
        assert!(monitor.is_current_bind(bind.gen), "found nothing: kept");
    }

    /// **A tap's "leave this node" survives a move** (`wallet-security-
    /// auditor`, rounds 2–3), through the real race loop with a scripted round:
    /// (1) the user's swap re-cast by a move keeps the node out of every round;
    /// (2) a tap into a moved-network hunt puts it out from the next round;
    /// (3) a move alone never does; (4) a tap inside a round the incumbent
    /// itself wins does not re-install it (the other side:
    /// [`a_tap_in_a_moved_round_lets_another_winner_in`]).
    #[tokio::test(start_paused = true)]
    async fn a_taps_leave_this_node_survives_a_network_move() {
        async fn rounds_of(
            monitor: &DagMonitor,
            mode: RaceMode,
            tap_after_first: bool,
            first_won_by: Option<String>,
        ) -> Vec<RoundAsked> {
            let asked: Arc<Mutex<Vec<RoundAsked>>> = Arc::new(Mutex::new(Vec::new()));
            {
                let asked = asked.clone();
                let inner = monitor.inner.clone();
                *monitor
                    .inner
                    .race_script
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner) =
                    Some(Box::new(move |round: &RoundAsked| {
                        let mut seen = asked.lock().unwrap();
                        seen.push(round.clone());
                        if tap_after_first && seen.len() == 1 {
                            inner.swaps_asked.fetch_add(1, Ordering::SeqCst);
                        }
                        match &first_won_by {
                            Some(url) if seen.len() == 1 => won_by(url),
                            _ => link::RaceOutcome::default(),
                        }
                    }));
            }
            tokio::time::timeout(Duration::from_secs(120), monitor.race_loop(mode))
                .await
                .expect("the hunt ends");
            let rounds = asked.lock().unwrap().clone();
            rounds
        }
        let live = || async {
            let monitor = DagMonitor::mainnet().expect("construct");
            let bind = monitor
                .install_bind("wss://nina.kaspa.blue/kaspa/mainnet/wrpc/borsh".to_string())
                .await
                .expect("arm");
            stage_live(&monitor, &bind);
            bind.connected_mono_ms.store(mono_ms(), Ordering::Relaxed);
            monitor
                .inner
                .network_moved_mono_ms
                .store(mono_ms() + 1, Ordering::SeqCst);
            (monitor, bind)
        };

        let (monitor, bind) = live().await;
        let theirs = RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Asked,
        };
        let rounds = rounds_of(&monitor, theirs, false, None).await;
        assert!(
            rounds.iter().all(|r| r.excluded.contains(&bind.url)),
            "(1) out every round"
        );

        let (monitor, bind) = live().await;
        let moved = RaceMode::Swap {
            from: bind.url.clone(),
            why: SwapWhy::Moved {
                gen: bind.gen,
                asked: 0,
                tapped: false,
            },
        };
        let rounds = rounds_of(&monitor, moved.clone(), true, None).await;
        assert!(
            !rounds[0].excluded.contains(&bind.url),
            "(3) a move alone keeps it in"
        );
        assert!(
            rounds[1].excluded.contains(&bind.url),
            "(2) the tap puts it out"
        );
        assert_eq!(
            rounds.len() as u32,
            1 + SWAP_HUNT_ROUNDS,
            "the tap bought rounds of its own"
        );

        let (monitor, bind) = live().await;
        let rounds = rounds_of(&monitor, moved.clone(), false, None).await;
        assert!(
            rounds.iter().all(|r| !r.excluded.contains(&bind.url)),
            "(3) never excluded"
        );

        let (monitor, bind) = live().await;
        let rounds = rounds_of(&monitor, moved, true, Some(bind.url.clone())).await;
        assert!(
            monitor.is_current_bind(bind.gen),
            "(4) the node the tap left is not re-installed"
        );
        assert!(
            rounds.len() > 1 && rounds[1].excluded.contains(&bind.url),
            "(4) and the next round races without it: {} round(s)",
            rounds.len()
        );
    }

    /// **A tap inside a moved-network round rules out only the node it left**
    /// (`wallet-security-auditor`, round 3): another node that wins the round
    /// comes in at once, in that round. Real time and a loopback node, because
    /// the winner is dialled.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_tap_in_a_moved_round_lets_another_winner_in() {
        let y = holding_ws_server().await;
        let monitor = DagMonitor::mainnet().expect("construct");
        // A live incumbent: without one the loop head degrades the swap to a
        // cold hunt, and no moved round runs at all.
        let incumbent = monitor.install_bind(refusing_port()).await.expect("arm");
        stage_live(&monitor, &incumbent);
        let asked: Arc<Mutex<Vec<RoundAsked>>> = Arc::new(Mutex::new(Vec::new()));
        {
            let (y, asked, inner) = (y.clone(), asked.clone(), monitor.inner.clone());
            *monitor
                .inner
                .race_script
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) =
                Some(Box::new(move |round: &RoundAsked| {
                    let mut seen = asked.lock().unwrap();
                    seen.push(round.clone());
                    if seen.len() == 1 {
                        inner.swaps_asked.fetch_add(1, Ordering::SeqCst);
                        return won_by(&y);
                    }
                    link::RaceOutcome::default()
                }));
        }
        let moved = RaceMode::Swap {
            from: incumbent.url.clone(),
            why: SwapWhy::Moved {
                gen: incumbent.gen,
                asked: monitor.inner.swaps_asked.load(Ordering::SeqCst),
                tapped: false,
            },
        };
        tokio::time::timeout(Duration::from_secs(30), monitor.race_loop(moved))
            .await
            .expect("the hunt ends");
        assert_eq!(
            monitor.current_url().as_deref(),
            Some(y.as_str()),
            "the node the tap did not leave comes in"
        );
        let rounds = asked.lock().unwrap().clone();
        assert_eq!(rounds.len(), 1, "at once, in the round it won");
        assert!(
            !rounds[0].excluded.contains(&incumbent.url),
            "a moved round: its incumbent raced"
        );
    }

    /// **The parked list's edges** (`consensus-auditor`, round 1): up to the
    /// cap every endpoint waits; one past it drops the oldest — unjudged, the
    /// acquittal side — and keeps the newest.
    #[test]
    fn the_parked_list_holds_its_cap_and_drops_the_oldest_past_it() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let url = |i: usize| format!("wss://n{i}.example/borsh");
        for i in 0..PENDING_STRIKES_CAP - 1 {
            monitor.set_pending_strike(url(i), link::StrikeReason::Drop);
        }
        assert_eq!(pending(&monitor).len(), PENDING_STRIKES_CAP - 1);
        monitor.set_pending_strike(url(PENDING_STRIKES_CAP - 1), link::StrikeReason::Drop);
        assert_eq!(
            pending(&monitor).len(),
            PENDING_STRIKES_CAP,
            "at the cap: all kept"
        );
        monitor.set_pending_strike(url(PENDING_STRIKES_CAP), link::StrikeReason::Drop);
        let kept: Vec<String> = pending(&monitor).into_iter().map(|(u, _, _)| u).collect();
        assert_eq!(kept.len(), PENDING_STRIKES_CAP);
        assert!(!kept.contains(&url(0)), "the oldest dropped");
        assert!(kept.contains(&url(PENDING_STRIKES_CAP)), "the newest kept");
        monitor.settle_pending_strike(Some("wss://prover.example/borsh"));
        assert!(
            ledger_reason(&monitor, &url(0)).is_none(),
            "dropped unjudged: acquitted, never struck"
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
