//! PRE3-LANE E1 — a notification from a retired socket must never reach the
//! pinned `UtxoProcessor` while it reads disconnected (run 4's F1, the S1).
//!
//! **The real path each case stands for** (PB-042: the fake reproduces the
//! pin's ordering; it does not supply the failure):
//!
//! - The link unbinds its stable handle BEFORE it signals the ctl close
//!   (`DagMonitor::retire_bind`), so wallet-core's `handle_disconnect` reaches
//!   `LinkRpc::unregister_listener`'s unbound branch, which answers `Ok(())`
//!   without unregistering (D-101 item 7). The processor's listener stays on
//!   the retired client's notifier. `FakeRpc::retain_listeners_on_unregister`
//!   is that branch, verbatim in effect.
//! - The pinned processor then reads `is_connected == false`, and
//!   `handle_utxo_changed` `.expect()`s a DAA score that `current_daa_score()`
//!   withholds while disconnected (pin `wallet/core/src/utxo/processor.rs`
//!   `:203-205`, `:393-394` @ `01b532e`). The panic kills the processor's bare
//!   tokio task: no `UtxoProcError`, `task_is_running` stays set, `stop()`
//!   waits on a response nobody will send (`:770-783`), and the next connect
//!   has nobody to hear it.
//!
//! **Case 1, `a_frame_after_the_close`** — a `UtxosChanged` delivered to the
//! retained listener after the processor handled the close: the frame the
//! retired socket reads during its 0–4 ms teardown (the teardown is detached
//! and runs after the close is signalled). Covered by SEVERING the retired
//! registration's delivery.
//!
//! **Case 2, `a_notification_queued_at_the_close`** — a `UtxosChanged`
//! already queued in the processor's OWN channel when the close lands. The
//! processor polls ctl ahead of notifications (`select_biased`, `:710-751`),
//! so it handles the close first and the queued frame after it. Severing
//! future delivery cannot reach a frame already inside the processor; this
//! case is covered by DRAINING before the close is delivered. The processor
//! is held in its notification arm by its own `notification_lock()` (the lock
//! a send's `try_submit` holds across `submit_transaction`, pin
//! `tx/generator/pending.rs:214-219`) — the real way a frame queues behind it.
//!
//! **Case 3, `a_close_during_a_slow_negotiation`** — the socket is retired
//! while the processor is still negotiating on it (its `get_server_info`
//! round trip: p99.9 1.0 s, max 6.0 s on the reference device), and its
//! listener is registered only after the close was signalled — on a client
//! that can still deliver. Covered by STRICT ALTERNATION: the relay begins a
//! transition only once the processor acknowledged the last, so the close's
//! sever comes after the registration it must cut, and the drain after its
//! frames. **What it stands for, and what it does not (PB-042):** the
//! registration lands on a live client after the close only where the
//! stable handle stays bound across it — a pinned node's redial, whose
//! `on_disconnected` keeps the bind (`dag_monitor.rs`) — or on a future
//! transport. In the found-node topology the handle is unbound after the
//! close (a registration is refused), and a new socket's open queues behind
//! the close, which the processor's ctl-first select would handle before any
//! frame: a rescue by timing. This case proves the mechanism that removes
//! the reliance on that rescue, not a field frequency. (Its first cut queued
//! the reopen behind the close and passed with alternation removed — the
//! rescue at work.)

mod support;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Once};
use std::time::Duration;

use kaspa_wallet_core::rpc::RpcCtl;
use kaspa_wrpc_client::prelude::{
    NetworkId, NetworkType, Notification, UtxosChangedNotification,
    VirtualDaaScoreChangedNotification,
};
use kaspaverse_chain::{Address, WalletEngine, WalletEvent};
use support::FakeRpc;

const WAIT: Duration = Duration::from_secs(15);
/// `stop()` must return inside its own bound; this is that bound plus
/// scheduling margin, so a hang reads as a hang and not as a slow runner.
const STOP_WITHIN: Duration = Duration::from_secs(10);
/// **The soonest the next socket opens after a retirement, measured**: 453 ms,
/// the fastest of 758 retirement → next `connected to` gaps on the reference
/// device's archive (a tap swap; median 5.8 s; `~/device_captures`, Aug–Sep
/// 2026). The next open must not arrive sooner here than it can there: the
/// processor polls ctl first, so an open queued beside a dangling frame is
/// handled before it and RESCUES the frame (it then meets a connected
/// processor) — a rescue the field never offers. This was learned by the
/// first cut of these tests passing at HEAD in 0.1 s.
const NEXT_BIND_FLOOR: Duration = Duration::from_millis(453);

/// Panics located in the pinned wallet framework, counted by a chained hook
/// this test binary installs once. A panic anywhere in this binary's wallet
/// lanes is a lane death: none may happen.
static WALLET_CORE_PANICS: AtomicUsize = AtomicUsize::new(0);

/// **One test at a time** (L6): the panic registry and its hook are
/// process-wide by nature, so a death staged in one test (under a mutant)
/// would read as a death in every test running beside it — which the first
/// mutation run showed, three reds for one defect. Held for each test's run.
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn count_wallet_core_panics() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            if info
                .location()
                .is_some_and(|at| at.file().contains("wallet/core/src"))
            {
                WALLET_CORE_PANICS.fetch_add(1, Ordering::SeqCst);
            }
            previous(info);
        }));
    });
}

fn tmp(name: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("kv-lane-{}-{name}", std::process::id()))
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

/// The smallest `UtxosChanged`: the pin's `.expect` is the first line of its
/// handler, so the content never matters to the death.
fn utxos_changed() -> Notification {
    Notification::UtxosChanged(UtxosChangedNotification {
        added: Arc::new(vec![]),
        removed: Arc::new(vec![]),
    })
}

fn tick(score: u64) -> Notification {
    Notification::VirtualDaaScoreChanged(VirtualDaaScoreChangedNotification {
        virtual_daa_score: score,
    })
}

async fn await_event(
    events: &mut tokio::sync::broadcast::Receiver<WalletEvent>,
    what: &str,
    pred: impl Fn(&WalletEvent) -> bool,
) {
    tokio::time::timeout(WAIT, async {
        loop {
            match events.recv().await {
                Ok(event) if pred(&event) => return,
                Ok(_) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(e) => panic!("wallet event stream closed while waiting for {what}: {e}"),
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for {what}"));
}

/// The engine on the fake, started, connected once, with its first
/// registration and scan landed.
async fn connected_engine(
    name: &str,
) -> (
    Arc<FakeRpc>,
    RpcCtl,
    WalletEngine,
    tokio::sync::broadcast::Receiver<WalletEvent>,
    std::path::PathBuf,
) {
    count_wallet_core_panics();
    let network_id = NetworkId::new(NetworkType::Mainnet);
    let fake = FakeRpc::new(network_id);
    fake.retain_listeners_on_unregister();
    let ctl = RpcCtl::new();
    let store = tmp(name);
    let _ = std::fs::remove_file(&store);
    let engine =
        WalletEngine::new(fake.rpc(ctl.clone()), network_id, store.clone()).expect("engine");
    let events = engine.subscribe();
    let (receive, change) = test_addresses();
    engine
        .start(vec![receive, change.clone()], vec![change])
        .await
        .expect("engine start");
    ctl.signal_open().await.expect("signal open");
    fake.wait_until("epoch-1 registration and scan", WAIT, |f| {
        !f.utxos_changed_registrations(1).is_empty() && f.utxo_scans(1) >= 1
    })
    .await;
    (fake, ctl, engine, events, store)
}

/// The next socket: the wallet lane must be re-armed on it and fold a fresh
/// balance, no lane may have died, and `stop()` must come back.
async fn the_next_socket_serves(
    fake: &FakeRpc,
    ctl: &RpcCtl,
    engine: WalletEngine,
    mut events: tokio::sync::broadcast::Receiver<WalletEvent>,
    store: std::path::PathBuf,
    deaths_before: usize,
) {
    // The field's interval before the next socket: long enough for the
    // processor to meet the frame (at HEAD it dies within microseconds, and
    // the wait ends there).
    let _ = tokio::time::timeout(NEXT_BIND_FLOOR, async {
        while WALLET_CORE_PANICS.load(Ordering::SeqCst) == deaths_before {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await;
    // Drain whatever epoch 1 left on the stream, so the balance below is the
    // NEW socket's.
    while events.try_recv().is_ok() {}
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    fake.wait_until("epoch-2 utxos-changed registration", WAIT, |f| {
        !f.utxos_changed_registrations(2).is_empty()
    })
    .await;
    await_event(&mut events, "a balance on the new socket", |e| {
        matches!(e, WalletEvent::Balance { .. })
    })
    .await;
    assert_eq!(engine.lane_deaths(), 0, "the supervisor found a lane death");
    assert_eq!(
        WALLET_CORE_PANICS.load(Ordering::SeqCst) - deaths_before,
        0,
        "a panic in the pinned wallet framework (the independent witness)"
    );
    assert_eq!(
        engine.lanes_built(),
        1,
        "the lane was rebuilt, so it had died"
    );
    tokio::time::timeout(STOP_WITHIN, engine.stop())
        .await
        .expect("stop() returned inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// Case 1: a frame the retired socket delivers after the close.
#[tokio::test(flavor = "multi_thread")]
async fn a_frame_after_the_close_never_reaches_the_processor() {
    let _serial = SERIAL.lock().await;
    let (fake, ctl, engine, mut events, store) = connected_engine("after-close.kvlog").await;
    let deaths_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);

    ctl.signal_close().await.expect("signal close");
    await_event(&mut events, "the processor's disconnect", |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await;
    // The retired client's notifier still holds the listener (the unbound
    // branch did not unregister it) and reads one more frame.
    assert!(
        fake.deliver(utxos_changed()).await >= 1,
        "the retired listener must still be there to deliver to"
    );
    // The gate saw it and refused it — the check looked (PB-029).
    tokio::time::timeout(WAIT, async {
        while engine.frames_refused() == 0 {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .expect("the gate refused the retired registration's frame");

    the_next_socket_serves(&fake, &ctl, engine, events, store, deaths_before).await;
}

/// Case 2: a frame already queued in the processor's own channel when the
/// close lands.
#[tokio::test(flavor = "multi_thread")]
async fn a_notification_queued_at_the_close_never_meets_a_disconnected_processor() {
    let _serial = SERIAL.lock().await;
    let (fake, ctl, engine, events, store) = connected_engine("queued.kvlog").await;
    let deaths_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let processor = engine.context().processor().clone();

    // Hold the processor in its notification arm: take the lock its handler
    // writes under, then hand it a tick. The lock is write-preferring
    // (async-lock), so once the processor waits to write, a second read
    // waits too — which is how this test knows the tick was dequeued.
    let held = processor.notification_lock().await;
    assert!(fake.deliver(tick(1_000_001)).await >= 1, "tick delivered");
    tokio::time::timeout(WAIT, async {
        loop {
            match tokio::time::timeout(Duration::from_millis(20), processor.notification_lock())
                .await
            {
                Ok(probe) => {
                    drop(probe);
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
                Err(_) => return, // a writer is waiting: the processor holds the tick
            }
        }
    })
    .await
    .expect("the processor took the tick and waits for its lock");

    // Behind it, in the processor's own channel: a UtxosChanged. Then the close.
    assert!(fake.deliver(utxos_changed()).await >= 1, "frame delivered");
    ctl.signal_close().await.expect("signal close");
    // Let the close reach whoever handles it before the processor moves on.
    tokio::time::sleep(Duration::from_millis(50)).await;
    drop(held);

    the_next_socket_serves(&fake, &ctl, engine, events, store, deaths_before).await;
}

/// Case 3: a close while the processor is still negotiating, with its
/// listener registered after the close on a client that still delivers.
#[tokio::test(flavor = "multi_thread")]
async fn a_close_during_a_slow_negotiation_never_dangles_a_listener() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let network_id = NetworkId::new(NetworkType::Mainnet);
    let fake = FakeRpc::new(network_id);
    fake.retain_listeners_on_unregister();
    let negotiation = fake.hold_server_info();
    let subscribe = fake.hold_daa_subscribe();
    let ctl = RpcCtl::new();
    let store = tmp("slow-negotiation.kvlog");
    let _ = std::fs::remove_file(&store);
    let engine =
        WalletEngine::new(fake.rpc(ctl.clone()), network_id, store.clone()).expect("engine");
    let events = engine.subscribe();
    let (receive, change) = test_addresses();
    engine
        .start(vec![receive, change.clone()], vec![change])
        .await
        .expect("engine start");
    let deaths_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);

    // The socket opens; the processor starts negotiating and is held there.
    ctl.signal_open().await.expect("signal open");
    fake.wait_until("the negotiation's round trip", WAIT, |f| {
        f.server_info_calls() >= 1
    })
    .await;
    // The link retires it while the round trip is still out.
    ctl.signal_close().await.expect("signal close");
    tokio::time::sleep(Duration::from_millis(50)).await;

    // The round trip answers: the processor reads connected and registers its
    // listener on the client, which still delivers, and is held at its first
    // subscribe — registered, its negotiation not yet done.
    negotiation.add_permits(usize::MAX >> 4);
    fake.wait_until("the listener's registration", WAIT, |f| {
        f.daa_subscribes() >= 1
    })
    .await;
    // A frame for that listener, while the close waits.
    assert!(fake.deliver(utxos_changed()).await >= 1, "frame delivered");
    subscribe.add_permits(usize::MAX >> 4);

    // The next socket comes only at the field's floor; then it must serve.
    the_next_socket_serves(&fake, &ctl, engine, events, store, deaths_before).await;
}
