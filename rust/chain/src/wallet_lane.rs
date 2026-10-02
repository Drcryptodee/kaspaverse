//! **The wallet lane's boundary** (PRE3-LANE, run 4's F1): what reaches the
//! pinned `UtxoProcessor`, and when.
//!
//! ## The defect this closes (F1, proven red at the pin)
//!
//! The link retires a socket by unbinding its stable handle and only then
//! signalling the ctl close (`DagMonitor::retire_bind`). The processor's
//! `handle_disconnect` therefore unregisters its listener through
//! `LinkRpc::unregister_listener`'s unbound branch, which answers `Ok(())` and
//! touches nothing (D-101 item 7), so the retired client's notifier keeps
//! delivering into the processor's channel. And the processor polls its ctl
//! ahead of its notifications (`select_biased`, pin
//! `wallet/core/src/utxo/processor.rs:710-751` @ `01b532e`), so a `UtxosChanged`
//! already queued when the close lands is handled after it. Either way the frame
//! meets `is_connected == false`, `handle_utxo_changed` `.expect()`s the DAA
//! score `current_daa_score()` withholds (`:203-205`, `:393-394`), and the
//! processor's bare task dies silently. `tests/wallet_lane_survival.rs` drives
//! both shapes.
//!
//! ## How the boundary closes it — three parts, none of them inside the pin
//!
//! 1. **A gate on delivery** ([`LaneRpc`], [`Gate`]). The processor never
//!    registers its own channel with the node client. It is handed a stand-in
//!    `RpcApi` that registers a proxy channel instead and forwards from it into
//!    the processor's channel only while the registration's **epoch** is
//!    current, decided under the lock the sever takes. Severing is therefore
//!    synchronous and total, which the pin's own `unregister_listener` is not:
//!    it removes the listener from the notifier's map but only `try_send`s the
//!    unsubscribe to three broadcaster tasks, and a broadcaster mid-broadcast
//!    still delivers (`notify/src/notifier.rs:363-386`,
//!    `notify/src/broadcaster.rs:157-200`); the processor's connection is
//!    `Persistent`, so `close()` is a no-op too (`notify/src/connection.rs:91-96`).
//! 2. **A drain before every close** (the [`Gate`]'s outstanding list). Each
//!    `UtxosChanged` handed to the processor is tracked by a `Weak` of its
//!    `added` payload; the processor drops the notification when its handler
//!    returns (or unwinds). The close is delivered only once every one of them
//!    has been released, so a frame already inside the processor's channel is
//!    handled while it still reads connected. Severing cannot reach such a
//!    frame; this is the half that does.
//! 3. **Strict alternation of ctl transitions** (the relay). The processor reads
//!    a ctl of its own, which only this boundary signals: one transition at a
//!    time, each acknowledged by the processor's own event (`UtxoProcStart` or
//!    `UtxoProcError` for an open, `UtxoProcStop` for a close) before the next
//!    begins. Without it, a listener registered by a negotiation that was still
//!    out when its socket's close was signalled — on a handle that stays bound
//!    across the close, as a pinned node's redial keeps it — would read
//!    current, and its frames would meet the close. In the found-node topology
//!    a reopen queued behind the close rescues such a frame by timing (the
//!    processor polls its ctl first, so it reconnects before it reads the
//!    frame); alternation removes the reliance on that rescue.
//!
//! The monitor's ctl still drives everything — publishes, retirements, D-101's
//! re-announces — and in the same order; it now reaches the processor through
//! the relay, a hop that costs a task wake-up. One rule binds the three parts:
//! **no `UtxosChanged` reaches the processor while it reads disconnected** —
//! the one notification whose handler `.expect()`s a connected processor.
//! A `VirtualDaaScoreChanged` admitted before a sever is not drained: it can be
//! handled after the close, writing an older DAA score into maps the close just
//! emptied, which the next open's negotiation overwrites; its handler has no
//! such `.expect` (pin `processor.rs:263-269`, dispatched at `:641-642`), and
//! maturity only ever promotes.
//!
//! ## What the boundary also gives the supervisor
//!
//! The processor's task is the only listener on the lane's own ctl (pin
//! `processor.rs:696`; nothing else in the pin or here subscribes to it). Its
//! ctl channel is dropped with its future, and tokio drops a panicked task's
//! future inside its panic guard on the panicking thread (tokio 1.52.3
//! `runtime/task/harness.rs:521-538`), so the listener count falling to zero is
//! a **structural death witness**: whatever killed the task, wherever the panic
//! was located. And every transition's start is on a clock ([`Lane::stalled`]):
//! a CLOSE never acknowledged is a processor wedged on its own side — the
//! supervisor rebuilds it; an OPEN never acknowledged is a negotiation waiting
//! on a socket the link still holds — the link's case, which the supervisor
//! reports to D-101's recovery and never counts as a death. And a
//! `UtxosChanged` the processor has held past [`LANE_HOLD_WITHIN`] while its
//! socket kept talking is a witness of its own ([`Lane::held_stalled`]; a
//! quiet socket is the link's to end): its task is alive but no longer taking
//! frames — the pinned sync monitor dead with its `running` flag set leaves it
//! waiting forever inside `track(true)` (`wallet-security-auditor` C-1).

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::Duration;

use tokio::time::Instant;

use async_trait::async_trait;
use kaspa_notify::connection::Connection;
use kaspa_rpc_core::api::connection::DynRpcConnection;
use kaspa_wallet_core::events::Events;
use kaspa_wallet_core::rpc::{DynRpcApi, Rpc, RpcCtl};
use kaspa_wallet_core::utxo::{UtxoContext, UtxoContextBinding, UtxoProcessor};
use kaspa_wrpc_client::prelude::*;

use crate::link_rpc::rpc_call_table;

/// **N — how long one ctl transition of the processor may take**: a close's
/// sever, drain, delivery and `UtxoProcStop`, or an open's negotiation to
/// `UtxoProcStart` or `UtxoProcError`. Also the bound on a pinned `stop()`.
/// What a stall past it means depends on the transition (`consensus-auditor`,
/// PRE3-LANE): a **close** that is not acknowledged is the processor wedged on
/// its own side, and the supervisor rebuilds the lane; an **open** that is not
/// is a negotiation still waiting on the node — the link's case — and the
/// supervisor reports the lane dark to D-101's recovery, which re-announces and
/// rebinds from its own evidence. An open stall is never a lane death.
///
/// **Fit on recorded data** (the reference device's archive, Aug–Sep 2026,
/// `~/device_captures`). Opens: **594** that succeeded with the engine running
/// took median 0.40 s, p99 2.96 s, p99.9 4.12 s, **max 4.17 s** from
/// `dag-monitor: connected to` to `wallet-sync: utxo-proc start`; the **5** that
/// failed all died with their sockets — two dropped 0.18 s in, three deaf
/// sockets hung their negotiation **31–37 s** until the link retired them, each
/// failure landing 1–6 ms after the retirement (D-334 item 3). So an open past
/// nine seconds is a dark lane, never a healthy one being slow. Closes are
/// local and take microseconds, except when the drain waits on a frame the
/// processor's handler holds: behind a send's `submit_transaction` on its
/// notification lock (pin `tx/generator/pending.rs:216`), one round trip.
/// LINK-Q2's **14,502** probes (`ping` and `get_server_info`, standing in for
/// the submit's own round trip, which no capture has timed yet) answered at
/// median 184 ms, p99.9 1.0 s, slowest **6.0 s**. Nine seconds is 2.2× the
/// slowest healthy negotiation and 1.5× that round trip: **calm**, no recorded
/// healthy transition would have read as a stall (0 of 594); **bias**, a
/// wedged processor is rebuilt, and a dark negotiation reported, at most nine
/// seconds after its transition began. One compound case reads as a stall on
/// a healthy lane: a node that answered unsynced at connect (the probe refuses
/// those), with a send AND the pin's sync poll both in flight at the close —
/// the handler's `track(true)` then waits out the poll's round trip on top of
/// the submit's (`processor.rs:645-647`, `sync.rs:130-137`), up to 12.0 s at
/// the probe worst — and only on a close that keeps the socket bound (a D-101
/// re-announce, or a pinned node's redial): a retirement fails both calls at
/// its teardown. It costs one rebuild from the budget, and no funds move.
pub const LANE_STEP_WITHIN: Duration = Duration::from_secs(9);

/// **How long the processor may hold a `UtxosChanged` while its socket keeps
/// talking** before the lane is convicted (the held-frame witness,
/// `wallet-security-auditor` C-1): twice [`LANE_STEP_WITHIN`].
///
/// **What keeps a frame waiting on a healthy lane — two waits, in series**
/// (`consensus-auditor` delta 3):
///
/// 1. A send's submit holds the processor's notification lock for one round
///    trip (`pending.rs:216`). It is the only holder in this app: our scans go
///    through the context's `scan_and_register_addresses`, which takes no lock
///    (`context.rs:744-755`); only the pin's `Account` scan does (`scan.rs:59`).
///    The lock is async-lock's write-preferring `RwLock`, so a chained send's
///    legs do not stack.
/// 2. Then, on a lane whose node answered unsynced at connect, the handler's
///    `track(true)` waits out the pin's sync poll in flight
///    (`processor.rs:645-647`, `sync.rs:130-137`) — C-1's healthy twin.
///
/// Both round trips stand on LINK-Q2's 14,502 probes (`ping` and
/// `get_server_info`), slowest answered 6.0 s: no capture had timed a submit
/// (its `submit_ok` span had no start), and PRE3-LANE adds `submit_start` so
/// the next soak fits this bound on the real distribution. So the worst
/// healthy hold is 12.0 s, and eighteen seconds is 1.5× it.
///
/// **A frame held on a quiet socket is not judged by this bound.** A submit
/// hung on a deaf socket is the link's to end (`Lane::held_stalled`, C-2):
/// retiring the socket fails its pending calls about two seconds later, at the
/// teardown's disconnect, and a dispatcher starved in its send releases only
/// at the RPC reaper's sixty seconds — then the close's own clock convicts a
/// processor that is blocked, not dead, and the rebuild on the live socket is
/// the right remedy. **One stuck point holds no frame:** a dead sync monitor
/// and a reconnect to a synced node hang `handle_connect_impl`'s `track(true)`
/// (`processor.rs:542`) after `UtxoProcStart`. The next `UtxosChanged` (this
/// bound) or the next close (`LANE_STEP_WITHIN`) sees it; until then only the
/// pending-to-mature promotion waits.
pub const LANE_HOLD_WITHIN: Duration = Duration::from_secs(18);

/// **When the lane calls its socket quiet**: no frame admitted for the link's
/// own base silence deadline, the same evidence (the node's DAA ticks) on the
/// same bound, tied by name so a re-fit of the lane's transition bound cannot
/// move it (`consensus-auditor` delta 4). The two agree within the delivery
/// skew between their listeners (the link's tick handler, the lane's
/// forwarder) and the edge (the link counts from exactly the bound, the lane
/// from past it); inside that sub-millisecond gap a frame already held past
/// [`LANE_HOLD_WITHIN`] can cost one rebuild, and no funds move. After a
/// landed swap the link waits longer (18 s, then hands over to the watchdog)
/// while the lane still reads quiet at nine: there the lane defers more — it
/// waits through silences the link has not yet acted on, and judges them when
/// the socket speaks.
const LANE_QUIET_AFTER: Duration = crate::link::SILENCE_DEADLINE;

/// The one quiet rule, for [`Gate::admit`] and [`Gate::held_view`] alike: no
/// frame admitted, or none for longer than [`LANE_QUIET_AFTER`].
fn quiet_at(last_admitted: Option<Instant>, now: Instant) -> bool {
    last_admitted.is_none_or(|at| now.duration_since(at) > LANE_QUIET_AFTER)
}

/// How often a drain looks again while the processor still holds a frame. The
/// drain is normally instant (the processor handles a frame in microseconds);
/// this only paces the rare wait behind a send's round trip.
const DRAIN_POLL: Duration = Duration::from_millis(2);

/// The listener id answered when nothing may register (a retired lane): the
/// link's own sentinel, which every subscribe call refuses (`link_rpc.rs`).
const NO_LISTENER: ListenerId = ListenerId::MAX;

/// What every call answers once the lane is retired: a typed error, never a
/// panic, never a silent success. A processor left behind by a rebuild may
/// wake from a stuck call and try the socket; it is refused.
const LANE_RETIRED: &str = "wallet lane: retired";

// ── The gate ─────────────────────────────────────────────────────────────────

/// Decides, under one lock, whether a frame may reach the processor, and
/// remembers which `UtxosChanged` it has handed over and not yet seen released.
pub(crate) struct Gate {
    state: Mutex<GateState>,
    retired: AtomicBool,
    /// Frames a severed registration offered and the gate dropped.
    dropped: AtomicU64,
    /// The processor's own connection, as last registered — the dev fault arm
    /// replays the pre-fix ordering into it (`lanefault`, D-340's fence).
    target: Mutex<Option<ChannelConnection>>,
    /// The lane's own wake-up ([`Lane::changed`]), for the two events that turn
    /// the held-frame witness on: a frame handed over while none was
    /// outstanding, and a quiet socket speaking again while one is held.
    wake: Arc<tokio::sync::Notify>,
}

struct GateState {
    /// The current registration epoch. A sever moves it on, and every
    /// registration stamped with an older one is stale from that instant.
    epoch: u64,
    /// `UtxosChanged` handed to the processor and not yet released by it,
    /// each with when it was handed over (oldest first).
    outstanding: Vec<(Instant, Weak<Vec<RpcUtxosByAddressesEntry>>)>,
    /// When the gate last admitted any frame — on a live socket the node's
    /// DAA ticks arrive about ten a second, so this is the socket's own pulse
    /// as the lane sees it.
    last_admitted: Option<Instant>,
}

/// One reading of the held-frame witness's inputs ([`Gate::held_view`]).
struct HeldView {
    /// The clock, read under the gate's lock.
    now: Instant,
    /// No frame admitted for [`LANE_QUIET_AFTER`].
    quiet: bool,
    /// When the oldest `UtxosChanged` still held was handed over.
    oldest: Option<Instant>,
}

impl Gate {
    fn new(wake: Arc<tokio::sync::Notify>) -> Self {
        Self {
            state: Mutex::new(GateState {
                epoch: 1,
                outstanding: Vec::new(),
                last_admitted: None,
            }),
            retired: AtomicBool::new(false),
            dropped: AtomicU64::new(0),
            target: Mutex::new(None),
            wake,
        }
    }

    fn epoch(&self) -> u64 {
        self.state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .epoch
    }

    /// May `notification`, offered by a registration stamped `epoch`, reach
    /// the processor? Decided under the lock [`Gate::sever`] takes, so a sever
    /// that returns has stopped every later frame of the epochs it ended. A
    /// `UtxosChanged` that passes is tracked until the processor releases it.
    fn admit(&self, epoch: u64, notification: &Notification) -> bool {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if self.retired.load(Ordering::SeqCst) || state.epoch != epoch {
            return false;
        }
        let now = Instant::now();
        let was_quiet = quiet_at(state.last_admitted, now);
        state.last_admitted = Some(now);
        // Released frames go as frames arrive, so the list holds what is
        // outstanding — never one entry per frame of a long session.
        state
            .outstanding
            .retain(|(_, frame)| frame.strong_count() > 0);
        let held = !state.outstanding.is_empty();
        if let Notification::UtxosChanged(utxos) = notification {
            state.outstanding.push((now, Arc::downgrade(&utxos.added)));
        }
        // Two EVENTS turn the held-frame witness on, and each wakes the
        // supervisor, whose wake is armed before it reads anything: a first
        // frame held, and a quiet socket speaking again while one is held —
        // never the passage of time, which a look can race on a multi-thread
        // runtime (`consensus-auditor` delta 3).
        if (!held && !state.outstanding.is_empty()) || (held && was_quiet) {
            self.wake.notify_waiters();
        }
        true
    }

    /// **What the held-frame witness reads**, from one lock with the clock read
    /// inside it — the lock and clock [`Gate::admit`] uses — so a look and an
    /// admission are ordered (`consensus-auditor` delta 4). A look that finds
    /// the socket quiet at `t` comes, in lock order, before every admission it
    /// did not see; the first of those reads the same last stamp with a clock
    /// at or after `t`, so it finds the socket quiet too and, with a frame
    /// held, wakes the supervisor.
    fn held_view(&self) -> HeldView {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let now = Instant::now();
        state
            .outstanding
            .retain(|(_, frame)| frame.strong_count() > 0);
        HeldView {
            now,
            quiet: quiet_at(state.last_admitted, now),
            oldest: state.outstanding.first().map(|(at, _)| *at),
        }
    }

    /// End the current epoch: from the instant this returns, nothing a
    /// registration of it offers reaches the processor.
    fn sever(&self) {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.epoch += 1;
    }

    /// Has the processor released every `UtxosChanged` it was handed?
    fn drained(&self) -> bool {
        self.oldest_held().is_none()
    }

    /// When the oldest `UtxosChanged` the processor still holds was handed to
    /// it, if it holds one.
    fn oldest_held(&self) -> Option<Instant> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state
            .outstanding
            .retain(|(_, frame)| frame.strong_count() > 0);
        state.outstanding.first().map(|(at, _)| *at)
    }

    fn retire(&self) {
        self.retired.store(true, Ordering::SeqCst);
        // Under the lock, so a forwarder mid-`admit` sees it.
        drop(self.state.lock().unwrap_or_else(PoisonError::into_inner));
    }

    fn is_retired(&self) -> bool {
        self.retired.load(Ordering::SeqCst)
    }
}

/// Carry one registration's frames from its proxy channel into the processor's
/// own connection, while its epoch is current. Ends when the node client drops
/// the proxy (unregistered, or the retired client finally freed).
async fn forward(
    gate: Arc<Gate>,
    epoch: u64,
    from: async_channel::Receiver<Notification>,
    to: ChannelConnection,
) {
    let mut dropped = 0u64;
    while let Ok(notification) = from.recv().await {
        if !gate.admit(epoch, &notification) {
            dropped += 1;
            gate.dropped.fetch_add(1, Ordering::Relaxed);
            continue;
        }
        if to.send(notification).await.is_err() {
            break;
        }
    }
    if dropped > 0 {
        log::info!(
            "wallet-lane: a retired registration offered {dropped} frame(s) after its socket \
             closed — none reached the processor (PRE3-LANE)"
        );
    }
}

// ── The processor's RpcApi ───────────────────────────────────────────────────

/// The `RpcApi` the processor is built with: every call delegates to the
/// monitor's stable handle byte for byte (INV-9 — the consensus values travel
/// untouched), and the notification API routes through the [`Gate`].
pub(crate) struct LaneRpc {
    inner: Arc<DynRpcApi>,
    gate: Arc<Gate>,
}

impl LaneRpc {
    fn live(&self) -> RpcResult<()> {
        if self.gate.is_retired() {
            Err(RpcError::General(LANE_RETIRED.to_string()))
        } else {
            Ok(())
        }
    }
}

macro_rules! lane_rpc_delegate {
    ($($method:ident($request:ty) -> $response:ty;)*) => {
        #[async_trait]
        impl RpcApi for LaneRpc {
            $(
                async fn $method(
                    &self,
                    connection: Option<&DynRpcConnection>,
                    request: $request,
                ) -> RpcResult<$response> {
                    self.live()?;
                    self.inner.$method(connection, request).await
                }
            )*

            /// The processor's listener, gated: the node client is given a
            /// proxy channel, and a forwarder carries its frames into the
            /// processor's own connection while the registration's epoch is
            /// current. The id is the node client's, so every later call on it
            /// passes straight through.
            fn register_new_listener(&self, connection: ChannelConnection) -> ListenerId {
                if self.gate.is_retired() {
                    return NO_LISTENER;
                }
                let (proxy_tx, proxy_rx) = async_channel::unbounded();
                let epoch = self.gate.epoch();
                let id = self.inner.register_new_listener(ChannelConnection::new(
                    "utxo processor (lane gate)",
                    proxy_tx,
                    ChannelType::Closable,
                ));
                *self.gate.target.lock().unwrap_or_else(PoisonError::into_inner) =
                    Some(connection.clone());
                tokio::spawn(forward(self.gate.clone(), epoch, proxy_rx, connection));
                id
            }

            /// Passed through. The sever that matters already happened, at the
            /// relay, before the close this unregister answers was delivered.
            async fn unregister_listener(&self, id: ListenerId) -> RpcResult<()> {
                self.inner.unregister_listener(id).await
            }

            async fn start_notify(&self, id: ListenerId, scope: Scope) -> RpcResult<()> {
                self.live()?;
                self.inner.start_notify(id, scope).await
            }

            async fn stop_notify(&self, id: ListenerId, scope: Scope) -> RpcResult<()> {
                self.inner.stop_notify(id, scope).await
            }
        }
    };
}

rpc_call_table!(lane_rpc_delegate);

// ── The lane ─────────────────────────────────────────────────────────────────

/// What a transition in flight is (the supervisor's stall clock).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Transition {
    Open,
    Close,
}

/// One processor, its context, and the boundary in front of them. A rebuild
/// discards the whole lane and builds a new one; nothing here is reused.
pub(crate) struct Lane {
    /// 1, 2, 3 … per engine, for the log.
    pub(crate) number: u64,
    pub(crate) processor: UtxoProcessor,
    pub(crate) context: UtxoContext,
    gate: Arc<Gate>,
    /// The processor's own ctl — only the relay signals it.
    ctl: RpcCtl,
    /// The monitor's ctl the relay follows.
    upstream: RpcCtl,
    /// `lane_health::panics_seen()` when the lane was built.
    pub(crate) born_after_panic: u64,
    born: Instant,
    /// Milliseconds since `born` at which the transition in flight began, plus
    /// one; 0 while none is.
    step_since: AtomicU64,
    step_open: AtomicBool,
    /// Listeners on the lane ctl once the processor started (1).
    listeners_at_start: AtomicUsize,
    /// Upstream opens that followed an upstream close: new sockets.
    pub(crate) binds: AtomicU64,
    /// Wakes the supervisor: a transition began or ended, a bind arrived, a
    /// frame was handed over while none was outstanding, or a quiet socket
    /// spoke again while one was held.
    pub(crate) changed: Arc<tokio::sync::Notify>,
    retired: tokio::sync::Notify,
    /// The dev fault arm (D-340's fence): replay the pre-fix ordering at the
    /// next close, once.
    fault_armed: AtomicBool,
    /// The lane's fold task ended (the engine's guard sets it).
    pub(crate) fold_ended: AtomicBool,
    relay: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl Lane {
    /// Build a processor and context on `upstream`'s handle, behind a fresh
    /// boundary. Nothing runs until [`Lane::start_relay`].
    pub(crate) fn new(number: u64, upstream: &Rpc, network_id: NetworkId) -> Arc<Self> {
        let changed = Arc::new(tokio::sync::Notify::new());
        let gate = Arc::new(Gate::new(changed.clone()));
        let ctl = RpcCtl::new();
        let rpc_api: Arc<DynRpcApi> = Arc::new(LaneRpc {
            inner: upstream.rpc_api().clone(),
            gate: gate.clone(),
        });
        let processor = UtxoProcessor::new(
            Some(Rpc::new(rpc_api, ctl.clone())),
            Some(network_id),
            None,
            None,
        );
        let context = UtxoContext::new(&processor, UtxoContextBinding::default());
        Arc::new(Self {
            number,
            processor,
            context,
            gate,
            ctl,
            upstream: upstream.rpc_ctl().clone(),
            born_after_panic: crate::lane_health::panics_seen(),
            born: Instant::now(),
            step_since: AtomicU64::new(0),
            step_open: AtomicBool::new(false),
            listeners_at_start: AtomicUsize::new(0),
            binds: AtomicU64::new(0),
            changed,
            retired: tokio::sync::Notify::new(),
            fault_armed: AtomicBool::new(false),
            fold_ended: AtomicBool::new(false),
            relay: Mutex::new(None),
        })
    }

    /// Arm the dev fault (`lanefault=1`, the dev install only).
    pub(crate) fn arm_fault(&self) {
        self.fault_armed.store(true, Ordering::SeqCst);
    }

    /// Listeners on the processor's ctl right now.
    fn listeners(&self) -> usize {
        self.ctl
            .multiplexer()
            .channels
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .len()
    }

    /// Record the listener count once `processor.start()` has returned, and
    /// start following the monitor's ctl.
    pub(crate) fn start_relay(self: &Arc<Self>) {
        self.listeners_at_start
            .store(self.listeners(), Ordering::SeqCst);
        let lane = self.clone();
        let task = tokio::spawn(async move { lane.relay().await });
        *self.relay.lock().unwrap_or_else(PoisonError::into_inner) = Some(task);
    }

    /// **The structural witness**: the processor's task stopped listening on
    /// its ctl, which happens only when its future was dropped — a panic
    /// anywhere in its call tree, or an exit.
    pub(crate) fn processor_ended(&self) -> bool {
        let at_start = self.listeners_at_start.load(Ordering::SeqCst);
        at_start > 0 && self.listeners() < at_start
    }

    /// A transition in flight longer than [`LANE_STEP_WITHIN`], and which.
    pub(crate) fn stalled(&self) -> Option<Transition> {
        let since = self.step_since.load(Ordering::SeqCst);
        if since == 0 {
            return None;
        }
        let began = self.born + Duration::from_millis(since - 1);
        (began.elapsed() >= LANE_STEP_WITHIN).then(|| self.transition())
    }

    /// Which transition is in flight (0: none) — so one stall is reported once.
    pub(crate) fn step(&self) -> u64 {
        self.step_since.load(Ordering::SeqCst)
    }

    /// When the transition in flight becomes a stall, if one is in flight.
    pub(crate) fn stall_deadline(&self) -> Option<Instant> {
        let since = self.step_since.load(Ordering::SeqCst);
        (since != 0).then(|| self.born + Duration::from_millis(since - 1) + LANE_STEP_WITHIN)
    }

    /// **The held-frame witness** (`wallet-security-auditor` C-1): the
    /// processor has held a `UtxosChanged` past [`LANE_HOLD_WITHIN`] while
    /// its socket kept talking. Its task is alive, so the structural witness
    /// is silent, but it no longer takes frames. During a close's drain,
    /// whichever of this clock and the close's runs out first convicts: both
    /// see the same stuck processor.
    ///
    /// **A quiet socket defers it** (C-2). While the gate has admitted nothing
    /// for [`LANE_QUIET_AFTER`] — the link's base silence deadline — a held
    /// frame waits on the link, not on the processor: a
    /// send's submit hung on a deaf socket holds the lock until the link
    /// replaces the socket, which can take 9 s (the silence deadline) or 31–41 s
    /// (the foreground watchdog, when a hunt finds nothing) or longer (the
    /// deadline's backoff, the background). The verdict waits for the socket to
    /// speak again with the frame still held, an event the gate wakes the
    /// supervisor for: then the processor is stuck on its own side.
    pub(crate) fn held_stalled(&self) -> bool {
        let view = self.gate.held_view();
        !view.quiet
            && view
                .oldest
                .is_some_and(|at| at + LANE_HOLD_WITHIN <= view.now)
    }

    /// When the oldest frame held reaches its bound, if one is held and the
    /// socket is talking. A quiet socket arms nothing: its speaking again is
    /// an event the gate wakes the supervisor for ([`Gate::admit`]).
    pub(crate) fn held_deadline(&self) -> Option<Instant> {
        let view = self.gate.held_view();
        if view.quiet {
            return None;
        }
        view.oldest.map(|at| at + LANE_HOLD_WITHIN)
    }

    fn transition(&self) -> Transition {
        if self.step_open.load(Ordering::SeqCst) {
            Transition::Open
        } else {
            Transition::Close
        }
    }

    fn begin(&self, transition: Transition) {
        let since = u64::try_from(self.born.elapsed().as_millis()).unwrap_or(u64::MAX - 1) + 1;
        self.step_open
            .store(transition == Transition::Open, Ordering::SeqCst);
        self.step_since.store(since, Ordering::SeqCst);
        self.changed.notify_waiters();
    }

    fn end(&self) {
        self.step_since.store(0, Ordering::SeqCst);
        self.changed.notify_waiters();
    }

    /// Frames the gate refused because their socket had closed.
    pub(crate) fn dropped_frames(&self) -> u64 {
        self.gate.dropped.load(Ordering::Relaxed)
    }

    /// Retire the lane: the gate refuses everything from now on, and the relay
    /// stops. The processor is left to its caller (a bounded `stop()`).
    pub(crate) fn retire(&self) {
        self.gate.retire();
        self.retired.notify_waiters();
        if let Some(task) = self
            .relay
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
        {
            task.abort();
        }
    }

    /// **The relay**: the monitor's ctl, re-told to the processor one
    /// acknowledged transition at a time (part 3 above), with the sever and the
    /// drain in front of every close (parts 1 and 2).
    ///
    /// It has no death witness of its own, and needs none: it has no panic
    /// site (no `expect`, no index, no arithmetic that can overflow), and the
    /// channels it reads close only when the lane is dropped. The forwarders
    /// and the supervisor are the same (`wallet-security-auditor`, PRE3-LANE).
    async fn relay(self: Arc<Self>) {
        // Subscribe before reading any state, so nothing is missed between.
        let upstream = self.upstream.multiplexer().channel();
        let events = self.processor.multiplexer().channel();
        let mut pending = std::collections::VecDeque::new();
        if self.upstream.is_connected() {
            pending.push_back(RpcState::Connected);
        }
        let mut step = Step::Idle;
        let mut upstream_closed = false;
        loop {
            // Advance as far as the processor's acknowledgements allow.
            loop {
                match step {
                    Step::Idle => match pending.pop_front() {
                        Some(RpcState::Connected) => step = self.open(),
                        Some(RpcState::Disconnected) => step = self.close_begin(),
                        None => break,
                    },
                    Step::Draining => {
                        // A processor whose task is gone holds its queued
                        // frames forever and protects nothing: waiting on
                        // them would poll every `DRAIN_POLL` until the next
                        // socket (`consensus-auditor` delta, battery).
                        if !self.gate.drained() && !self.processor_ended() {
                            break;
                        }
                        step = self.close_deliver();
                    }
                    Step::AwaitingOpen | Step::AwaitingStop => break,
                }
            }
            if step == Step::Idle && self.step_since.load(Ordering::SeqCst) != 0 {
                self.end();
            }
            tokio::select! {
                biased;
                _ = self.retired.notified() => return,
                event = events.receiver.recv() => match event {
                    Ok(event) => {
                        let acknowledged = matches!(
                            (&step, &*event),
                            (Step::AwaitingOpen, Events::UtxoProcStart)
                                | (Step::AwaitingOpen, Events::UtxoProcError { .. })
                                | (Step::AwaitingStop, Events::UtxoProcStop)
                        );
                        if acknowledged {
                            step = Step::Idle;
                        }
                    }
                    Err(_) => return,
                },
                state = upstream.receiver.recv() => match state {
                    Ok(state) => {
                        // A new socket is counted when the monitor announces
                        // it, not when the processor gets to it: a dead lane's
                        // relay waits forever for an acknowledgement, and the
                        // supervisor's grant for a dark lane keys on this.
                        match state {
                            RpcState::Disconnected => upstream_closed = true,
                            RpcState::Connected if upstream_closed => {
                                upstream_closed = false;
                                self.binds.fetch_add(1, Ordering::SeqCst);
                                self.changed.notify_waiters();
                            }
                            RpcState::Connected => {}
                        }
                        pending.push_back(state);
                    }
                    Err(_) => return,
                },
                _ = tokio::time::sleep(DRAIN_POLL), if step == Step::Draining => {}
            }
        }
    }

    /// An open: carry the descriptor across, and signal the processor. One that
    /// is already connected ignores it (pin `:717-718`), so nothing is awaited.
    fn open(&self) -> Step {
        self.ctl.set_descriptor(self.upstream.descriptor());
        if self.processor.is_connected() {
            let _ = self.ctl.try_signal_open();
            return Step::Idle;
        }
        self.begin(Transition::Open);
        let _ = self.ctl.try_signal_open();
        Step::AwaitingOpen
    }

    /// A close, first half: end the epoch, so nothing more is admitted; the
    /// close itself waits for the drain.
    fn close_begin(&self) -> Step {
        self.begin(Transition::Close);
        if self.fault_armed.swap(false, Ordering::SeqCst) {
            return self.replay_pre_fix_close();
        }
        self.gate.sever();
        Step::Draining
    }

    /// A close, second half: everything handed over has been released, so the
    /// processor may read disconnected now.
    fn close_deliver(&self) -> Step {
        let connected = self.processor.is_connected();
        let _ = self.ctl.try_signal_close();
        if connected {
            Step::AwaitingStop
        } else {
            Step::Idle
        }
    }

    /// **The dev fault arm** (`lanefault=1`; the dev install only, D-340's
    /// fence): the ordering before this sitting, on purpose — the close goes
    /// straight through with no sever and no drain, and one `UtxosChanged`
    /// follows it into the processor's own connection, the frame a retired
    /// socket reads during its teardown. The pin's handler meets it
    /// disconnected and panics at its own line, so the supervisor has a real
    /// death to rebuild from on glass. The frame is empty: the `.expect` is
    /// the handler's first line, so no state is touched.
    fn replay_pre_fix_close(&self) -> Step {
        log::warn!(
            "devab: lanefault — replaying the pre-fix close on wallet lane {} \
             (no sever, no drain, one frame after the close)",
            self.number
        );
        let connected = self.processor.is_connected();
        let _ = self.ctl.try_signal_close();
        let target = self
            .gate
            .target
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        if let Some(target) = target {
            tokio::spawn(async move {
                let _ = target
                    .send(Notification::UtxosChanged(UtxosChangedNotification {
                        added: Arc::new(Vec::new()),
                        removed: Arc::new(Vec::new()),
                    }))
                    .await;
            });
        }
        if connected {
            Step::AwaitingStop
        } else {
            Step::Idle
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Step {
    Idle,
    AwaitingOpen,
    Draining,
    AwaitingStop,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utxos_changed() -> (Notification, Arc<Vec<RpcUtxosByAddressesEntry>>) {
        let added = Arc::new(Vec::new());
        let frame = Notification::UtxosChanged(UtxosChangedNotification {
            added: added.clone(),
            removed: Arc::new(Vec::new()),
        });
        (frame, added)
    }

    fn tick() -> Notification {
        Notification::VirtualDaaScoreChanged(VirtualDaaScoreChangedNotification {
            virtual_daa_score: 1,
        })
    }

    /// Is a wake pending on `woken`? It was armed before the event, as the
    /// supervisor arms its own before it reads anything.
    async fn woke(woken: tokio::sync::futures::Notified<'_>) -> bool {
        tokio::time::timeout(Duration::from_millis(1), woken)
            .await
            .is_ok()
    }

    /// **A quiet socket speaking again wakes the supervisor while a frame is
    /// held** (`consensus-auditor` delta 3). That turns a deferred held-frame
    /// verdict live, and it is an event, not the passage of time, so it gets
    /// a wake: a look racing it on a multi-thread runtime could otherwise read
    /// the verdict quiet and the deadline talking, and arm nothing. And it is
    /// the only extra wake: a tick on a talking socket, or on one holding
    /// nothing, wakes no one.
    #[tokio::test(start_paused = true)]
    async fn a_quiet_socket_speaking_again_wakes_the_supervisor_while_a_frame_is_held() {
        let wake = Arc::new(tokio::sync::Notify::new());
        let gate = Gate::new(wake.clone());

        // Nothing held: a tick after a quiet stretch wakes no one.
        tokio::time::sleep(LANE_STEP_WITHIN + Duration::from_secs(1)).await;
        let woken = wake.notified();
        assert!(gate.admit(1, &tick()));
        assert!(
            !woke(woken).await,
            "a tick with nothing held woke the supervisor"
        );

        // A first frame held starts the clock: a wake.
        let (frame, held) = utxos_changed();
        let woken = wake.notified();
        assert!(gate.admit(1, &frame));
        drop(frame);
        assert!(woke(woken).await, "a first frame held woke no one");

        // A tick on a talking socket, the frame still held: no wake.
        let woken = wake.notified();
        assert!(gate.admit(1, &tick()));
        assert!(
            !woke(woken).await,
            "a tick on a talking socket woke the supervisor"
        );

        // The socket goes quiet with the frame held, then speaks: a wake.
        tokio::time::sleep(LANE_STEP_WITHIN + Duration::from_secs(1)).await;
        let woken = wake.notified();
        assert!(gate.admit(1, &tick()));
        assert!(
            woke(woken).await,
            "a quiet socket speaking again, a frame held, woke no one"
        );
        drop(held);
    }

    /// **The look and the admission agree at the boundary** (`consensus-
    /// auditor` delta 4): one millisecond short of [`LANE_QUIET_AFTER`], at
    /// it, and one past it, what the held-frame witness reads as quiet is
    /// exactly what makes an admission wake the supervisor — so no reading
    /// the witness acts on can fall between the two.
    #[tokio::test(start_paused = true)]
    async fn the_witness_and_the_wake_agree_on_quiet_at_the_boundary() {
        for (after, quiet) in [
            (LANE_QUIET_AFTER - Duration::from_millis(1), false),
            (LANE_QUIET_AFTER, false),
            (LANE_QUIET_AFTER + Duration::from_millis(1), true),
        ] {
            let wake = Arc::new(tokio::sync::Notify::new());
            let gate = Gate::new(wake.clone());
            let (frame, held) = utxos_changed();
            assert!(gate.admit(1, &frame));
            drop(frame);
            tokio::time::sleep(after).await;
            let view = gate.held_view();
            assert_eq!(view.quiet, quiet, "the witness's reading {after:?} after");
            let woken = wake.notified();
            assert!(gate.admit(1, &tick()));
            assert_eq!(
                woke(woken).await,
                quiet,
                "the admission's wake {after:?} after disagrees with the witness"
            );
            drop(held);
        }
    }
}
