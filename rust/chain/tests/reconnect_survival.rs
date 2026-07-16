//! Reconnect-survival regression harness (V6; guards D-083/L59, PB-022).
//!
//! A subscription that survives a disconnect is worse than one that dies:
//! it silences its own re-registration (L59). These tests script
//! connect → disconnect → reconnect at the pin's own `Rpc` seam and assert
//! each live lane actually RE-FIRES on the NEW connection — turning the
//! class of silent, device-only-detectable fund-visibility bugs into
//! gate-caught ones (`cargo test --workspace` runs this).
//!
//! Negative proof (PB-011, executed at V6 and recorded in the ledger):
//! - neuter the D-083 re-arm (`wallet_sync.rs` UtxoProcStart arm's direct
//!   `processor.register_addresses` block) → `wallet_lane_*` goes RED: the
//!   pin's context-level path filters every address as already-known on
//!   reconnect (its set survives the disconnect), so no epoch-2
//!   `start_notify(UtxosChanged)` ever reaches the node.
//! - neuter the tracker's `DagEvent::Connected → catch_up` arm
//!   (`acceptance.rs`) → `tracker_lane_*` goes RED.
//!
//! PB-022 sweep disposition (audited at V6): the OTHER two lanes need no
//! fake. The DagMonitor's four scopes are re-registered by construction —
//! `handle_connect()` runs unregister-prior + register + start_notify ×4 on
//! every `RpcState::Connected` (its client is concrete `KaspaRpcClient`;
//! refactoring it behind `RpcApi` for a test would rewrite the connect
//! authority for no product gain — INV-12). The transport hub consumes the
//! monitor's BlockAdded matches and holds no node subscription of its own.

mod support;

use std::time::Duration;

use kaspa_wallet_core::rpc::RpcCtl;
use kaspa_wrpc_client::prelude::{NetworkId, NetworkType};
use kaspaverse_chain::{AcceptanceTracker, Address, DagEvent, VccBatch, WalletEngine, WalletEvent};
use support::FakeRpc;

const WAIT: Duration = Duration::from_secs(15);

fn tmp(name: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("kv-reconnect-{}-{name}", std::process::id()))
}

fn test_addresses() -> (Address, Address) {
    // The same mainnet pair the wallet_sync unit tests use.
    let receive: Address = "kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692"
        .try_into()
        .expect("receive address");
    let change: Address = "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf"
        .try_into()
        .expect("change address");
    (receive, change)
}

/// Await a specific WalletEvent variant, draining everything else.
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

/// The D-083 guard: the wallet's live `UtxosChanged` subscription must be
/// re-issued on EVERY connection, not only the first. Epoch-tagged
/// recording makes "re-fired on the new connection" a structural assertion
/// — a total-count check could pass on two epoch-1 registrations (the
/// re-arm plus the context's first-time path) with a deaf epoch 2.
#[tokio::test(flavor = "multi_thread")]
async fn wallet_lane_rearms_utxos_changed_on_every_connection() {
    let network_id = NetworkId::new(NetworkType::Mainnet);
    let fake = FakeRpc::new(network_id);
    let ctl = RpcCtl::new();
    let store = tmp("wallet-lane.kvlog");
    let _ = std::fs::remove_file(&store);

    let engine =
        WalletEngine::new(fake.rpc(ctl.clone()), network_id, store.clone()).expect("engine");
    let mut events = engine.subscribe();
    let (receive, change) = test_addresses();
    engine
        .start(vec![receive.clone(), change.clone()], vec![change.clone()])
        .await
        .expect("engine start");

    // Epoch 1: first connect — the initial registration + scan must land.
    ctl.signal_open().await.expect("signal open");
    fake.wait_until("epoch-1 utxos-changed registration", WAIT, |f| {
        !f.utxos_changed_registrations(1).is_empty() && f.utxo_scans(1) >= 1
    })
    .await;
    let full_set = |registrations: Vec<Vec<Address>>| {
        registrations
            .iter()
            .any(|addrs| addrs.contains(&receive) && addrs.contains(&change))
    };
    assert!(
        full_set(fake.utxos_changed_registrations(1)),
        "epoch-1 registration must carry the full watched set"
    );

    // Disconnect, and PROVE the engine saw it before declaring epoch 2 —
    // otherwise a late epoch-1 call could be mis-tagged as epoch 2.
    ctl.signal_close().await.expect("signal close");
    await_event(&mut events, "disconnect", |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await;

    // Epoch 2: reconnect. Only the D-083 re-arm can produce this
    // registration — the pin's context path filters against its own
    // address set, which SURVIVED the disconnect.
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    fake.wait_until("epoch-2 utxos-changed re-registration", WAIT, |f| {
        !f.utxos_changed_registrations(2).is_empty()
    })
    .await;
    assert!(
        full_set(fake.utxos_changed_registrations(2)),
        "the reconnect re-arm must re-subscribe the FULL watched set"
    );
    fake.wait_until("epoch-2 utxo re-scan", WAIT, |f| f.utxo_scans(2) >= 1)
        .await;

    engine.stop().await.expect("engine stop");
    let _ = std::fs::remove_file(&store);
}

/// The V6 soft pull-refresh pin: `WalletEngine::rescan()` re-asks the node
/// for the watched UTXO set over the LIVE connection — no ctl signal, no
/// reconnect, no `UtxoProcStart`. This is the primitive `dag_resync`'s soft
/// branch rides instead of tearing down a healthy socket (amends V3 register
/// item 12); a regression that couples it back to connection ceremony shows
/// up here as extra epochs or a missing scan.
#[tokio::test(flavor = "multi_thread")]
async fn soft_rescan_reasks_the_node_without_touching_the_connection() {
    let network_id = NetworkId::new(NetworkType::Mainnet);
    let fake = FakeRpc::new(network_id);
    let ctl = RpcCtl::new();
    let store = tmp("soft-rescan.kvlog");
    let _ = std::fs::remove_file(&store);

    let engine =
        WalletEngine::new(fake.rpc(ctl.clone()), network_id, store.clone()).expect("engine");
    let (receive, change) = test_addresses();

    // Before start() there is no watched set — the caller must escalate.
    assert!(
        engine.rescan().await.is_err(),
        "rescan before start must err (soft path unavailable)"
    );

    engine
        .start(vec![receive.clone(), change.clone()], vec![change])
        .await
        .expect("engine start");
    ctl.signal_open().await.expect("signal open");
    fake.wait_until("initial scan", WAIT, |f| f.utxo_scans(1) >= 1)
        .await;
    let scans_before = fake.utxo_scans(1);

    engine.rescan().await.expect("in-place rescan");

    // The node was re-asked on the SAME connection epoch: no signal_close /
    // signal_open happened (the test owns the ctl), so a scan recorded in
    // epoch 1 after the call IS the in-place re-ask.
    assert!(
        fake.utxo_scans(1) > scans_before,
        "rescan must re-fetch the UTXO set over the live connection"
    );

    engine.stop().await.expect("engine stop");
    let _ = std::fs::remove_file(&store);
}

/// The acceptance-spine guard: on every `DagEvent::Connected` the tracker
/// must re-run its VCC catch-up walk (the monitor re-registered the scope;
/// the tracker recovers the gap). A tracker that only catches up at boot
/// goes silently stale after the first reconnect.
#[tokio::test(flavor = "multi_thread")]
async fn tracker_lane_reruns_vcc_catch_up_on_reconnect() {
    let network_id = NetworkId::new(NetworkType::Mainnet);
    let fake = FakeRpc::new(network_id);
    let ctl = RpcCtl::new();
    let dir = tmp("tracker-lane");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("tracker dir");

    let tracker = AcceptanceTracker::load(dir.clone()).expect("tracker");
    // The tracker keys off plain channels — the test owns both ends.
    let (vcc_tx, vcc_rx) = tokio::sync::mpsc::unbounded_channel::<VccBatch>();
    let (dag_tx, dag_rx) = tokio::sync::broadcast::channel::<DagEvent>(16);
    let handle = tracker.run(fake.rpc(ctl), vcc_rx, dag_rx);

    // Boot: no cursor → the tracker seeds at sink and does NOT page-walk.
    // Waiting for the seed also removes the race where an early Connected
    // would seed instead of walking.
    fake.wait_until("boot cursor seed (get_sink)", WAIT, |f| {
        f.sink_calls(1) >= 1
    })
    .await;
    assert_eq!(
        fake.vcc_calls(1),
        0,
        "no catch-up page walk before the first reconnect"
    );

    // Reconnect #1: the Connected arm must walk the chain from the cursor.
    fake.begin_epoch();
    dag_tx
        .send(DagEvent::Connected { url: None })
        .expect("dag event");
    fake.wait_until("epoch-2 vcc catch-up", WAIT, |f| f.vcc_calls(2) >= 1)
        .await;

    // Reconnect #2: and again — every NEW connection recovers its gap.
    fake.begin_epoch();
    dag_tx
        .send(DagEvent::Connected { url: None })
        .expect("dag event");
    fake.wait_until("epoch-3 vcc catch-up", WAIT, |f| f.vcc_calls(3) >= 1)
        .await;

    // Closing the dag lane ends the task (vcc_tx stays alive until here so
    // the loop can only exit through the Closed arm).
    drop(dag_tx);
    drop(vcc_tx);
    let _ = tokio::time::timeout(WAIT, handle).await;
    let _ = std::fs::remove_dir_all(&dir);
}
