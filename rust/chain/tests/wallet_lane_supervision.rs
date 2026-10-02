//! PRE3-LANE — the class: a pinned-crate task that dies or stalls anyway is
//! observed, and the wallet lane rebuilt, bounded the OTP way.
//!
//! E1 (`wallet_lane_survival.rs`) proves the CAUSE is gone: no frame reaches
//! the processor while it reads disconnected. This file proves what happens
//! when anything else kills or stalls a pinned task — the class run 4 named
//! (technical risk 1: "any other `.expect()` reachable inside a pin-spawned
//! task has the same blast radius"). Each test stages one case through a real
//! path and asserts what the supervisor concluded, from which witness:
//!
//! - **a processor task that dies anywhere** — a panic on its own task at a
//!   location outside the wallet framework, seen by the STRUCTURAL witness
//!   (its ctl listener gone) inside a fraction of the stall bound: rebuilt;
//! - **a wallet-framework panic on another task** — a reason to look, never a
//!   verdict: the healthy lane is left alone (`consensus-auditor` CONCERNS-4);
//! - **a negotiation that never answers** — the link's case, not a death: the
//!   lane reads Recovering past [`LANE_STEP_WITHIN`] and serves once the node
//!   answers (CONCERNS-1/2), in paused time;
//! - **a close that is never acknowledged** — a processor wedged on its own
//!   side, seen by the STALL clock at [`LANE_STEP_WITHIN`]: rebuilt;
//! - **a processor stuck between transitions** — the pinned sync monitor dead
//!   with its flag set, the processor waiting on it forever: seen by the frame
//!   it holds at [`LANE_HOLD_WITHIN`]; a frame held behind a submit inside that
//!   bound is left alone;
//! - **a crash loop** — held by the restart budget ([`LANE_REBUILDS`] in
//!   [`LANE_REBUILD_WINDOW`]), dark until a new socket grants one more; the
//!   user's pull on it escalates to a new socket instead of rebuilding on this
//!   one; the window slides; and the pinned `stop()` of a dead processor
//!   returns, bounded;
//! - **a dead processor holding frames** — its close is not held by them;
//! - **a stopped engine** — never rebuilt, however late a reported death
//!   reaches the flight.

mod support;

use std::sync::Arc;
use std::time::Duration;

use kaspa_wallet_core::rpc::RpcCtl;
use kaspa_wrpc_client::prelude::Notification;
use kaspa_wrpc_client::prelude::{
    NetworkId, NetworkType, UtxosChangedNotification, VirtualDaaScoreChangedNotification,
};
use kaspaverse_chain::{
    Address, LaneRecovery, WalletEngine, WalletEvent, WalletLaneHealth, LANE_HOLD_WITHIN,
    LANE_REBUILDS, LANE_REBUILD_WINDOW, LANE_STEP_WITHIN,
};
use support::FakeRpc;

const WAIT: Duration = Duration::from_secs(30);

/// One test at a time (L6): the panic registry is process-wide by nature.
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// The smallest `UtxosChanged` (the pin's handler `.expect`s on its first line;
/// its content never matters here).
fn utxos_changed() -> Notification {
    Notification::UtxosChanged(UtxosChangedNotification {
        added: Arc::new(vec![]),
        removed: Arc::new(vec![]),
    })
}

/// **The node's pulse**: a `VirtualDaaScoreChanged` every 100 ms, as a live
/// socket delivers them (about ten a second), until the handle is aborted. The
/// held-frame witness judges only a processor whose socket keeps talking
/// (`wallet-security-auditor` C-2).
fn ticking(fake: &Arc<FakeRpc>) -> tokio::task::JoinHandle<()> {
    let fake = fake.clone();
    tokio::spawn(async move {
        let mut virtual_daa_score = 1_000_000;
        loop {
            virtual_daa_score += 1;
            let _ = fake
                .deliver(Notification::VirtualDaaScoreChanged(
                    VirtualDaaScoreChangedNotification { virtual_daa_score },
                ))
                .await;
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    })
}

fn tmp(name: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("kv-supervise-{}-{name}", std::process::id()))
}

fn test_addresses() -> (Address, Address) {
    let receive: Address = "kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692"
        .try_into()
        .expect("receive address");
    let change: Address = "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf"
        .try_into()
        .expect("change address");
    (receive, change)
}

async fn engine_on(
    fake: &Arc<FakeRpc>,
    ctl: &RpcCtl,
    name: &str,
) -> (WalletEngine, std::path::PathBuf) {
    // The bridge installs this at init; a test binary has no bridge.
    kaspaverse_chain::lane_health::install_panic_hook();
    let store = tmp(name);
    let _ = std::fs::remove_file(&store);
    let network_id = NetworkId::new(NetworkType::Mainnet);
    let engine =
        WalletEngine::new(fake.rpc(ctl.clone()), network_id, store.clone()).expect("engine");
    let (receive, change) = test_addresses();
    engine
        .start(vec![receive, change.clone()], vec![change])
        .await
        .expect("engine start");
    (engine, store)
}

/// Fails the test at once when more than `most` lanes exist — a broken
/// restart budget then reads as an assertion, not a crash loop that runs the
/// test binary out of memory first (mutant S6, paused time).
fn at_most(engine: &WalletEngine, most: u64) {
    let built = engine.lanes_built();
    assert!(
        built <= most,
        "the restart budget did not hold: {built} lanes built, at most {most}"
    );
}

async fn until(what: &str, within: Duration, mut done: impl FnMut() -> bool) {
    tokio::time::timeout(within, async {
        while !done() {
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for {what}"));
}

/// **The structural witness.** The processor's task panics inside its own
/// negotiation — at a location OUTSIDE the wallet framework: a task dies of a
/// panic anywhere in its call tree — and its ctl listener goes with its
/// future. The supervisor must see that within a small fraction of the stall
/// bound (proof it was the witness, looked at after the panic, not the stall
/// clock), and the rebuilt lane must serve.
#[tokio::test(flavor = "multi_thread")]
async fn a_processor_task_death_anywhere_is_seen_at_once_and_the_lane_rebuilt() {
    let _serial = SERIAL.lock().await;
    let network_id = NetworkId::new(NetworkType::Mainnet);
    let fake = FakeRpc::new(network_id);
    fake.panic_on_daa_subscribes(1);
    let ctl = RpcCtl::new();
    let (engine, store) = engine_on(&fake, &ctl, "witness.kvlog").await;
    let mut events = engine.subscribe();

    let opened = tokio::time::Instant::now();
    ctl.signal_open().await.expect("signal open");
    until("the rebuild", WAIT, || engine.lanes_built() == 2).await;
    let seen_after = opened.elapsed();
    assert!(
        seen_after < LANE_STEP_WITHIN / 4,
        "the death was seen after {seen_after:?} — the stall clock's work, not the witness's"
    );
    assert_eq!(engine.lane_deaths(), 1);

    // Lane 2 replays the open and serves: its registration, its scan, a balance.
    fake.wait_until("lane 2's registration and scan", WAIT, |f| {
        !f.utxos_changed_registrations(1).is_empty() && f.utxo_scans(1) >= 1
    })
    .await;
    tokio::time::timeout(WAIT, async {
        loop {
            if let Ok(WalletEvent::Balance { .. }) = events.recv().await {
                return;
            }
        }
    })
    .await
    .expect("a balance from the rebuilt lane");
    until("the lane back to Live", WAIT, || {
        engine.lane_health() == WalletLaneHealth::Live
    })
    .await;
    tokio::time::timeout(WAIT, engine.stop())
        .await
        .expect("stop() returned")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A panic is a reason to look, never a verdict** (`consensus-auditor`
/// CONCERNS-4). The wallet framework's code runs on tasks that are not the
/// lane's — a send's submit, for one — so a panic there, here the pin's own
/// `handle_utxo_changed` called on a test task while the processor reads
/// disconnected (the F1 line itself), must leave a healthy lane alone: no
/// death, no rebuild, and the next socket served by the same lane.
#[tokio::test(flavor = "multi_thread")]
async fn a_wallet_framework_panic_on_another_task_leaves_a_healthy_lane_alone() {
    let _serial = SERIAL.lock().await;
    let network_id = NetworkId::new(NetworkType::Mainnet);
    let fake = FakeRpc::new(network_id);
    let ctl = RpcCtl::new();
    let (engine, store) = engine_on(&fake, &ctl, "another-task.kvlog").await;
    let mut events = engine.subscribe();
    ctl.signal_open().await.expect("signal open");
    fake.wait_until("lane 1 up", WAIT, |f| {
        !f.utxos_changed_registrations(1).is_empty()
    })
    .await;
    ctl.signal_close().await.expect("signal close");
    tokio::time::timeout(WAIT, async {
        loop {
            if let Ok(WalletEvent::Disconnected) = events.recv().await {
                return;
            }
        }
    })
    .await
    .expect("the processor read the close");

    let processor = engine.context().processor().clone();
    let staged = tokio::spawn(async move {
        let _ = processor
            .handle_utxo_changed(UtxosChangedNotification {
                added: Arc::new(vec![]),
                removed: Arc::new(vec![]),
            })
            .await;
    });
    assert!(
        staged.await.is_err_and(|e| e.is_panic()),
        "the pin panicked"
    );
    // Past the supervisor's whole ladder of looks after a recorded panic.
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_eq!(engine.lane_deaths(), 0, "a healthy lane was convicted");
    assert_eq!(engine.lanes_built(), 1, "a healthy lane was rebuilt");

    // The next socket opens on the same lane.
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    fake.wait_until("lane 1's registration on the next socket", WAIT, |f| {
        !f.utxos_changed_registrations(2).is_empty()
    })
    .await;
    assert_eq!(engine.lanes_built(), 1);
    tokio::time::timeout(WAIT, engine.stop())
        .await
        .expect("stop() returned")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A negotiation that never answers is the link's case, not a death**
/// (`consensus-auditor` CONCERNS-1/2). The processor is alive and waiting on
/// the node — D-334 recorded deaf sockets holding a negotiation 31–37 s until
/// the link retired them — so the supervisor neither counts a death nor
/// rebuilds on the socket that cannot answer; it reports the lane dark to
/// D-101's recovery (none in this harness) and the glass reads Recovering past
/// [`LANE_STEP_WITHIN`]. When the node answers, the same lane serves. Paused
/// time.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_negotiation_that_never_answers_is_the_links_case_not_a_death() {
    let _serial = SERIAL.lock().await;
    let network_id = NetworkId::new(NetworkType::Mainnet);
    let fake = FakeRpc::new(network_id);
    let negotiation = fake.hold_server_info();
    let ctl = RpcCtl::new();
    let (engine, store) = engine_on(&fake, &ctl, "open-stall.kvlog").await;

    ctl.signal_open().await.expect("signal open");
    tokio::time::sleep(LANE_STEP_WITHIN - Duration::from_secs(1)).await;
    assert_eq!(
        engine.lane_health(),
        WalletLaneHealth::Live,
        "inside the bound a slow negotiation is not a dark lane"
    );
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert_eq!(engine.lane_health(), WalletLaneHealth::Recovering);
    assert_eq!(
        engine.lane_deaths(),
        0,
        "an open stall was counted as a death"
    );
    assert_eq!(engine.lanes_built(), 1, "an open stall rebuilt the lane");
    tokio::time::sleep(LANE_STEP_WITHIN * 4).await;
    assert_eq!(engine.lanes_built(), 1, "a later look rebuilt it");

    // The node answers: the same lane negotiates, and serves.
    negotiation.add_permits(usize::MAX >> 4);
    fake.wait_until("the lane's registration", WAIT, |f| {
        !f.utxos_changed_registrations(1).is_empty()
    })
    .await;
    until("the lane back to Live", WAIT, || {
        engine.lane_health() == WalletLaneHealth::Live
    })
    .await;
    assert_eq!(engine.lane_deaths(), 0);
    tokio::time::timeout(WAIT, engine.stop())
        .await
        .expect("stop() returned")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A close that is never acknowledged is a death** — the processor wedged on
/// its own side. Staged the real way: a frame waits behind the processor's own
/// notification lock (the lock a send's `try_submit` holds across its submit,
/// pin `tx/generator/pending.rs:214`), so the drain cannot complete and the
/// close never reaches it. At [`LANE_STEP_WITHIN`] — not before — the
/// supervisor rebuilds, and the next socket is served by the new lane. Paused
/// time.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_close_that_is_never_acknowledged_is_a_death_and_rebuilt() {
    let _serial = SERIAL.lock().await;
    let network_id = NetworkId::new(NetworkType::Mainnet);
    let fake = FakeRpc::new(network_id);
    let ctl = RpcCtl::new();
    let (engine, store) = engine_on(&fake, &ctl, "close-stall.kvlog").await;
    ctl.signal_open().await.expect("signal open");
    fake.wait_until("lane 1 up", WAIT, |f| {
        !f.utxos_changed_registrations(1).is_empty() && f.utxo_scans(1) >= 1
    })
    .await;

    let processor = engine.context().processor().clone();
    let held = processor.notification_lock().await;
    assert!(
        fake.deliver(utxos_changed()).await >= 1,
        "a frame behind the lock"
    );
    let closed = tokio::time::Instant::now();
    ctl.signal_close().await.expect("signal close");
    until("the rebuild", WAIT * 4, || engine.lanes_built() == 2).await;
    let rebuilt_after = closed.elapsed();
    assert!(
        rebuilt_after >= LANE_STEP_WITHIN,
        "rebuilt after {rebuilt_after:?}, inside the bound"
    );
    assert!(rebuilt_after < LANE_STEP_WITHIN + Duration::from_secs(1));
    assert_eq!(engine.lane_deaths(), 1);
    drop(held);

    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    fake.wait_until("lane 2's registration", WAIT, |f| {
        !f.utxos_changed_registrations(2).is_empty()
    })
    .await;
    until("the lane back to Live", WAIT, || {
        engine.lane_health() == WalletLaneHealth::Live
    })
    .await;
    tokio::time::timeout(WAIT, engine.stop())
        .await
        .expect("stop() returned")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A processor stuck between transitions is seen by the frame it holds**
/// (`wallet-security-auditor` C-1). Staged on the pin's own path:
///
/// 1. A node that answers unsynced at connect makes the processor start its
///    sync monitor (`sync.rs:47-64`, `:113-124`).
/// 2. The monitor's poll panics inside `get_sync_status`, and it dies with its
///    `running` flag still set (cleared only on a clean exit, `:163-166`).
/// 3. The next `UtxosChanged` makes the processor call `track(true)`, which
///    waits in `stop_task()` for a reply only the dead task could send
///    (`processor.rs:645-647`; workflow-core `channel.rs:56-63`).
///
/// The processor's task is alive, so the structural witness is silent; no
/// transition is in flight, so no stall clock runs; the panic was on another
/// task, so the look finds the lane healthy. The frame it holds is the
/// witness: past [`LANE_HOLD_WITHIN`], and not before, the lane is rebuilt,
/// and the new lane serves. Paused time.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_processor_stuck_between_transitions_is_seen_by_the_frame_it_holds() {
    let _serial = SERIAL.lock().await;
    let network_id = NetworkId::new(NetworkType::Mainnet);
    let fake = FakeRpc::new(network_id);
    fake.report_unsynced(1);
    fake.panic_on_sync_status(1);
    let ctl = RpcCtl::new();
    let (engine, store) = engine_on(&fake, &ctl, "held-frame.kvlog").await;
    let mut events = engine.subscribe();

    ctl.signal_open().await.expect("signal open");
    fake.wait_until("lane 1 up", WAIT, |f| {
        !f.utxos_changed_registrations(1).is_empty() && f.utxo_scans(1) >= 1
    })
    .await;
    fake.wait_until("the sync monitor's poll", WAIT, |f| {
        f.sync_status_calls() >= 1
    })
    .await;
    // Past the supervisor's whole ladder of looks after that panic.
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_eq!(
        engine.lane_deaths(),
        0,
        "a panic on the sync monitor's task is not by itself a lane death"
    );

    // The socket keeps talking throughout: the processor is stuck on its own.
    let pulse = ticking(&fake);
    let held_at = tokio::time::Instant::now();
    assert!(
        fake.deliver(utxos_changed()).await >= 1,
        "a frame for lane 1"
    );
    tokio::time::sleep(LANE_HOLD_WITHIN - Duration::from_secs(1)).await;
    assert_eq!(engine.lanes_built(), 1, "convicted inside the bound");
    until("the rebuild", WAIT, || engine.lanes_built() == 2).await;
    let rebuilt_after = held_at.elapsed();
    assert!(
        rebuilt_after >= LANE_HOLD_WITHIN
            && rebuilt_after < LANE_HOLD_WITHIN + Duration::from_secs(1),
        "rebuilt {rebuilt_after:?} after the frame was handed over"
    );
    assert_eq!(engine.lane_deaths(), 1);

    // Lane 2 negotiates on the same live socket (synced now) and serves.
    fake.wait_until("lane 2's registration", WAIT, |f| {
        f.utxos_changed_registrations(1).len() >= 2
    })
    .await;
    tokio::time::timeout(WAIT, async {
        loop {
            if let Ok(WalletEvent::Balance { .. }) = events.recv().await {
                return;
            }
        }
    })
    .await
    .expect("a balance from the rebuilt lane");
    until("the lane back to Live", WAIT, || {
        engine.lane_health() == WalletLaneHealth::Live
    })
    .await;
    pulse.abort();
    tokio::time::timeout(LANE_STEP_WITHIN * 2, engine.stop())
        .await
        .expect("stop() returned inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A frame held behind a slow submit on a live socket is not a death.** A
/// send holds the processor's notification lock across its submit's round trip
/// (pin `tx/generator/pending.rs:216`), and a frame waits behind it. The
/// slowest answered round trip LINK-Q2 recorded was 6.0 s; held for twice that,
/// 12 s, with the socket talking throughout, and then released, the frame is
/// taken and the lane is left alone. The 12 s is written from that evidence,
/// never from [`LANE_HOLD_WITHIN`] (L233), so a bound cut below it goes red
/// here. Paused time.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_frame_held_behind_a_submit_inside_the_bound_is_not_a_death() {
    let _serial = SERIAL.lock().await;
    let network_id = NetworkId::new(NetworkType::Mainnet);
    let fake = FakeRpc::new(network_id);
    let ctl = RpcCtl::new();
    let (engine, store) = engine_on(&fake, &ctl, "held-submit.kvlog").await;
    ctl.signal_open().await.expect("signal open");
    fake.wait_until("lane 1 up", WAIT, |f| {
        !f.utxos_changed_registrations(1).is_empty() && f.utxo_scans(1) >= 1
    })
    .await;

    let pulse = ticking(&fake);
    let processor = engine.context().processor().clone();
    let submit = processor.notification_lock().await;
    assert!(
        fake.deliver(utxos_changed()).await >= 1,
        "a frame behind the lock"
    );
    tokio::time::sleep(Duration::from_secs(12)).await;
    drop(submit);
    tokio::time::sleep(LANE_STEP_WITHIN * 3).await;
    assert_eq!(engine.lane_deaths(), 0, "a slow submit convicted the lane");
    assert_eq!(engine.lanes_built(), 1);
    assert_eq!(engine.lane_health(), WalletLaneHealth::Live);
    pulse.abort();
    tokio::time::timeout(WAIT, engine.stop())
        .await
        .expect("stop() returned")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A frame held while the socket is quiet waits for the link**
/// (`wallet-security-auditor` C-2). A send's submit hung on a socket that went
/// deaf holds the processor's lock until the link replaces the socket, and the
/// link can take 9 s (its silence deadline), 31–41 s (the foreground watchdog,
/// when a hunt finds nothing) or longer (the deadline's backoff, the
/// background): convicting the lane meanwhile would judge it for the socket's
/// fault (PB-019). So 45 s held on a silent socket is no death. When the socket
/// speaks again and the frame is still held, the processor is stuck on its own
/// side: the gate wakes the supervisor for that event, and the lane is rebuilt
/// at once — inside half a second, so a regression to a timer goes red here.
/// Paused time.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_frame_held_while_the_socket_is_quiet_waits_for_the_link() {
    let _serial = SERIAL.lock().await;
    let network_id = NetworkId::new(NetworkType::Mainnet);
    let fake = FakeRpc::new(network_id);
    let ctl = RpcCtl::new();
    let (engine, store) = engine_on(&fake, &ctl, "held-quiet.kvlog").await;
    ctl.signal_open().await.expect("signal open");
    fake.wait_until("lane 1 up", WAIT, |f| {
        !f.utxos_changed_registrations(1).is_empty() && f.utxo_scans(1) >= 1
    })
    .await;

    let processor = engine.context().processor().clone();
    let submit = processor.notification_lock().await;
    assert!(
        fake.deliver(utxos_changed()).await >= 1,
        "a frame behind the lock"
    );
    tokio::time::sleep(Duration::from_secs(45)).await;
    assert_eq!(
        engine.lane_deaths(),
        0,
        "a frame held on a silent socket convicted the lane"
    );
    assert_eq!(engine.lanes_built(), 1);

    let spoke_at = tokio::time::Instant::now();
    let pulse = ticking(&fake);
    until("the rebuild once the socket speaks", WAIT, || {
        engine.lanes_built() == 2
    })
    .await;
    assert!(
        spoke_at.elapsed() <= Duration::from_millis(500),
        "rebuilt {:?} after the socket spoke again",
        spoke_at.elapsed()
    );
    assert_eq!(engine.lane_deaths(), 1);
    drop(submit);
    pulse.abort();
    tokio::time::timeout(LANE_STEP_WITHIN * 2, engine.stop())
        .await
        .expect("stop() returned inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **The restart budget, the pull on a dark lane, the sliding window, and the
/// bounded stop.** Every fresh processor dies in its negotiation (a node whose
/// answer kills it, say): the supervisor rebuilds [`LANE_REBUILDS`] times
/// inside the window and then holds the lane dark — no fourth rebuild, however
/// long it waits. The user's pull does not rebuild on the socket that kills
/// processors: it answers `Err`, which escalates to the link's hard path, and
/// the NEW socket grants one more (`consensus-auditor` CONCERNS-1). Once the
/// window has passed, the budget is whole again. And `stop()` returns although
/// the processor it stops is dead (the pin's own `stop()` would wait forever).
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_crash_loop_is_held_dark_until_a_new_socket() {
    let _serial = SERIAL.lock().await;
    let network_id = NetworkId::new(NetworkType::Mainnet);
    let fake = FakeRpc::new(network_id);
    fake.panic_on_daa_subscribes(u64::MAX);
    let ctl = RpcCtl::new();
    let (engine, store) = engine_on(&fake, &ctl, "crashloop.kvlog").await;
    let budget = u64::try_from(LANE_REBUILDS).expect("small");

    ctl.signal_open().await.expect("signal open");
    until("the budget spent", WAIT, || {
        at_most(&engine, 1 + budget);
        engine.lanes_built() == 1 + budget && engine.lane_health() == WalletLaneHealth::Dark
    })
    .await;
    // Held: a long wait inside the window builds nothing more.
    tokio::time::sleep(Duration::from_secs(120)).await;
    assert_eq!(engine.lanes_built(), 1 + budget, "the budget did not hold");
    assert_eq!(engine.lane_health(), WalletLaneHealth::Dark);

    // The user's pull: escalated to a new socket, not a rebuild on this one.
    assert!(
        engine.rescan().await.is_err(),
        "a pull on a dark lane must hand the bridge its hard path"
    );
    tokio::time::sleep(Duration::from_secs(5)).await;
    assert_eq!(
        engine.lanes_built(),
        1 + budget,
        "the pull rebuilt on the same socket"
    );

    // The new socket the hard path brings: one more rebuild (it dies too).
    ctl.signal_close().await.expect("signal close");
    ctl.signal_open().await.expect("signal reopen");
    until("the new socket's rebuild", WAIT, || {
        at_most(&engine, 2 + budget);
        engine.lanes_built() == 2 + budget
    })
    .await;
    until("dark again", WAIT, || {
        at_most(&engine, 2 + budget);
        engine.lane_health() == WalletLaneHealth::Dark
    })
    .await;

    // The window slides: past it, a new socket finds the whole budget again.
    tokio::time::sleep(LANE_REBUILD_WINDOW + Duration::from_secs(1)).await;
    ctl.signal_close().await.expect("signal close");
    ctl.signal_open().await.expect("signal reopen");
    until("a whole budget spent again", WAIT, || {
        at_most(&engine, 2 + 2 * budget);
        engine.lanes_built() == 2 + 2 * budget && engine.lane_health() == WalletLaneHealth::Dark
    })
    .await;
    assert_eq!(engine.lane_deaths(), 2 + 2 * budget);

    // The processor in hand is dead; `stop()` still returns, inside its bound.
    let stopped_at = tokio::time::Instant::now();
    tokio::time::timeout(LANE_STEP_WITHIN * 2, engine.stop())
        .await
        .expect("stop() returned inside its bound")
        .expect("stop");
    assert!(stopped_at.elapsed() <= LANE_STEP_WITHIN + Duration::from_secs(1));
    let _ = std::fs::remove_file(&store);
}

/// **An unanswered negotiation is handed to the link's recovery — once per
/// stall** (`consensus-auditor` delta). With a real `DagMonitor` attached (it
/// never dials here; its recovery finds no announced socket and stands down),
/// the supervisor reports the lane dark to D-101 when the open passes
/// [`LANE_STEP_WITHIN`], and does not report it again however long the stall
/// lasts — every later look finds the same stall already handed over. Paused
/// time.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn an_unanswered_negotiation_is_reported_to_the_link_once() {
    let _serial = SERIAL.lock().await;
    let network_id = NetworkId::new(NetworkType::Mainnet);
    let fake = FakeRpc::new(network_id);
    let negotiation = fake.hold_server_info();
    let ctl = RpcCtl::new();
    let (engine, store) = engine_on(&fake, &ctl, "report-once.kvlog").await;
    engine.attach_link(kaspaverse_chain::DagMonitor::mainnet().expect("monitor"));

    ctl.signal_open().await.expect("signal open");
    tokio::time::sleep(LANE_STEP_WITHIN - Duration::from_secs(1)).await;
    assert_eq!(
        engine.lane_reports_to_link(),
        0,
        "reported inside the bound"
    );
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert_eq!(
        engine.lane_reports_to_link(),
        1,
        "the stall was not handed over"
    );
    tokio::time::sleep(LANE_STEP_WITHIN * 10).await;
    assert_eq!(
        engine.lane_reports_to_link(),
        1,
        "the same stall was handed over twice"
    );
    assert_eq!(engine.lane_deaths(), 0);

    negotiation.add_permits(usize::MAX >> 4);
    until("the lane back to Live", WAIT, || {
        engine.lane_health() == WalletLaneHealth::Live
    })
    .await;
    tokio::time::timeout(WAIT, engine.stop())
        .await
        .expect("stop() returned")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A dead processor's held frames never hold its close** (`consensus-
/// auditor` delta). A frame handed to a processor whose task is gone stays in
/// its channel forever, so its drain would never complete: on a lane held dark
/// the relay would wake every `DRAIN_POLL` until the next socket — hours, on a
/// phone that is offline. The drain stands down for a dead processor and the
/// close goes through at once. Staged with the restart budget spent, so the
/// death is held dark and the lane's relay stays; the pin's own `stop()` ends
/// the task (it drains what it holds first, `processor.rs:759-763`), and one
/// frame is handed over after it. In the field the death would be a panic on
/// the processor's own task while connected — `context.rs:410`/`:431` at the
/// pin — which needs a real send's outgoing record to stage (PB-042).
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_dead_processors_held_frames_never_hold_its_close() {
    let _serial = SERIAL.lock().await;
    let network_id = NetworkId::new(NetworkType::Mainnet);
    let fake = FakeRpc::new(network_id);
    let budget = u64::try_from(LANE_REBUILDS).expect("small");
    fake.panic_on_daa_subscribes(budget);
    fake.retain_listeners_on_unregister();
    let ctl = RpcCtl::new();
    let (engine, store) = engine_on(&fake, &ctl, "dead-drain.kvlog").await;

    // The budget spent on deaths in negotiation; the last lane serves.
    ctl.signal_open().await.expect("signal open");
    until("the last lane up", WAIT, || {
        at_most(&engine, 1 + budget);
        engine.lanes_built() == 1 + budget && engine.lane_up()
    })
    .await;
    let processor = engine.context().processor().clone();
    processor.stop().await.expect("the pin's own stop");
    assert!(
        fake.deliver(utxos_changed()).await >= 1,
        "a frame for the dead processor"
    );
    tokio::time::sleep(Duration::from_millis(5)).await;

    ctl.signal_close().await.expect("signal close");
    until(
        "the close past the dead processor's held frame",
        WAIT,
        || !processor.rpc_ctl().is_connected(),
    )
    .await;
    assert_eq!(
        engine.frames_refused(),
        0,
        "the frame was refused, not held — the drain was never tested"
    );
    until("the death held dark", WAIT, || {
        engine.lane_health() == WalletLaneHealth::Dark
    })
    .await;
    assert_eq!(engine.lanes_built(), 1 + budget);
    assert_eq!(engine.lane_deaths(), 1 + budget);
    tokio::time::timeout(LANE_STEP_WITHIN * 2, engine.stop())
        .await
        .expect("stop() returned inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **Nothing rebuilds a stopped engine.** A reported death can reach the
/// rebuild long after the report: D-101's check sleeps between its
/// re-announces, and a lane held dark is rebuilt once its window slides. A
/// rebuild after `stop()` would start a fresh processor on the node for nobody,
/// so the stop closes the flight behind it. Staged the late way, in paused
/// time: a crash loop held dark, `stop()`, the window passes, and D-101's
/// recovery asks — it asks the lane before any socket, so an idle monitor
/// still reaches the rebuild.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_stopped_engine_is_never_rebuilt() {
    let _serial = SERIAL.lock().await;
    let network_id = NetworkId::new(NetworkType::Mainnet);
    let fake = FakeRpc::new(network_id);
    fake.panic_on_daa_subscribes(u64::MAX);
    let ctl = RpcCtl::new();
    let (engine, store) = engine_on(&fake, &ctl, "stopped.kvlog").await;
    let link = kaspaverse_chain::DagMonitor::mainnet().expect("monitor");
    engine.attach_link(link.clone());
    let budget = u64::try_from(LANE_REBUILDS).expect("small");

    ctl.signal_open().await.expect("signal open");
    until("the budget spent", WAIT, || {
        at_most(&engine, 1 + budget);
        engine.lanes_built() == 1 + budget && engine.lane_health() == WalletLaneHealth::Dark
    })
    .await;
    tokio::time::timeout(LANE_STEP_WITHIN * 2, engine.stop())
        .await
        .expect("stop() returned inside its bound")
        .expect("stop");

    // Past the window the budget would be whole again.
    tokio::time::sleep(LANE_REBUILD_WINDOW + Duration::from_secs(1)).await;
    let outcome = link.recover_wallet_lane(|| false).await;
    assert_ne!(
        outcome,
        LaneRecovery::Rebuilt,
        "a stopped engine was rebuilt"
    );
    tokio::time::sleep(Duration::from_secs(5)).await;
    assert_eq!(
        engine.lanes_built(),
        1 + budget,
        "a lane was built after the stop"
    );
    let _ = std::fs::remove_file(&store);
}
