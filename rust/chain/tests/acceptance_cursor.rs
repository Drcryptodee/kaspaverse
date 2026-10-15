//! The acceptance tracker's `vcc.cursor` follows the write-ahead rule: it
//! never moves past a chain batch whose facts did not reach disk, so the walk
//! a reconnect starts from it folds them again.
//!
//! **The real path this stands for.** The tracker's own run loop, its own log
//! and cursor files, and a write that fails in the operating system (the log's
//! path is a directory for the length of one batch). The fake node only
//! serves the pages, each keyed to the block it starts from and shaped as the
//! pin answers it: a walk reports as removed only the blocks of its start
//! block's own chain (`calculate_chain_path`,
//! `consensus/src/processes/traversal_manager.rs:34-44` @ `01b532e`). So the
//! accepting block appears as removed only in a walk that starts at it or
//! after it on its chain, and a walk begun from an earlier cursor gets a page
//! without the fact and the test reads red.

mod support;

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use kaspa_wallet_core::rpc::RpcCtl;
use kaspa_wrpc_client::prelude::{GetVirtualChainFromBlockResponse, NetworkId, NetworkType};
use kaspaverse_chain::{
    AcceptanceTracker, DagEvent, Hash, TrackerFeed, TxStatus, VccBatch, WatchSource,
};
use support::FakeRpc;

const WAIT: Duration = Duration::from_secs(15);

/// A live cursor write waits this long after the last one
/// (`CURSOR_MIN_WRITE_SECS`, counted in whole seconds), plus the rounding.
/// Without the wait the throttle alone would keep the old code's cursor in
/// place and the test could not see it move.
const PAST_THE_THROTTLE: Duration = Duration::from_secs(4);

fn h(n: u8) -> Hash {
    Hash::from_bytes([n; 32])
}

fn cursor(dir: &Path) -> Option<Hash> {
    std::fs::read_to_string(dir.join("vcc.cursor"))
        .ok()?
        .trim()
        .parse()
        .ok()
}

async fn eventually(what: &str, pred: impl Fn() -> bool) {
    let deadline = Instant::now() + WAIT;
    while !pred() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

fn batch(removed: Vec<Hash>, added: Vec<Hash>, accepted: Vec<(Hash, Vec<Hash>)>) -> TrackerFeed {
    TrackerFeed::Vcc(VccBatch {
        removed_chain_block_hashes: Arc::new(removed),
        added_chain_block_hashes: Arc::new(added),
        accepted: Arc::new(accepted),
    })
}

/// The log's path made a directory: every open for write fails.
struct Unwritable {
    path: PathBuf,
    aside: PathBuf,
}

impl Unwritable {
    fn at(path: PathBuf) -> Self {
        let aside = path.with_extension("aside");
        std::fs::rename(&path, &aside).unwrap();
        std::fs::create_dir(&path).unwrap();
        Self { path, aside }
    }

    fn restore(self) {
        std::fs::remove_dir(&self.path).unwrap();
        std::fs::rename(&self.aside, &self.path).unwrap();
    }
}

/// A removal lost to a failed write, then a reconnect: the walk starts from
/// the cursor the failure held, folds the removal, and releases the cursor,
/// so the next clean live batch moves it again.
#[tokio::test(flavor = "multi_thread")]
async fn a_reconnect_walk_from_the_held_cursor_folds_the_lost_fact() {
    let dir = std::env::temp_dir().join(format!("kv-cursor-hold-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let fake = FakeRpc::new(NetworkId::new(NetworkType::Mainnet));
    let tracker = AcceptanceTracker::load(dir.clone()).unwrap();

    let (sent, probe) = (h(0x11), h(0x12));
    let (accepting, next, probe_block, after, later) =
        (h(0xA1), h(0xB1), h(0xA2), h(0xB2), h(0xB3));
    tracker.watch(&sent.to_string(), WatchSource::Send);
    tracker.watch(&probe.to_string(), WatchSource::Send);

    let (vcc_tx, vcc_rx) = tokio::sync::mpsc::unbounded_channel();
    let (dag_tx, dag_rx) = tokio::sync::broadcast::channel(16);
    let _task = tracker.run(fake.rpc(RpcCtl::new()), vcc_rx, dag_rx);

    // A cold start with no cursor seeds it at the sink.
    let start = FakeRpc::sink_hash();
    eventually("the cursor seeded at the sink", || {
        cursor(&dir) == Some(start)
    })
    .await;
    let seeded = Instant::now();
    // A walk from the accepting block, once that block has left the chain,
    // reports it removed: it is the start block's own chain.
    fake.set_vcc_page(
        accepting,
        GetVirtualChainFromBlockResponse {
            removed_chain_block_hashes: vec![accepting],
            added_chain_block_hashes: vec![after],
            accepted_transaction_ids: vec![],
        },
    );

    // The send is accepted (the node refuses `get_block`, so the fold takes
    // the sink bound).
    vcc_tx
        .send(batch(
            vec![],
            vec![accepting],
            vec![(accepting, vec![sent])],
        ))
        .unwrap();
    eventually("the send accepted", || {
        matches!(
            tracker.status(&sent.to_string()),
            Some(TxStatus::Accepted { .. })
        )
    })
    .await;
    // The cursor moved to the accepting block at once, past the throttle: a
    // walk must be able to see that block leave the chain.
    eventually("the cursor at the accepting block", || {
        cursor(&dir) == Some(accepting)
    })
    .await;
    tokio::time::sleep(PAST_THE_THROTTLE.saturating_sub(seeded.elapsed())).await;

    // Its accepting block leaves the chain, and the write of that fact fails.
    let held = Unwritable::at(dir.join("acceptance.kvlog"));
    vcc_tx
        .send(batch(vec![accepting], vec![next], vec![]))
        .unwrap();
    // A later batch with a `get_block` call: once it arrives, the batch
    // before it has been folded.
    vcc_tx
        .send(batch(
            vec![],
            vec![probe_block],
            vec![(probe_block, vec![probe])],
        ))
        .unwrap();
    fake.wait_until("the batch after the lost removal", WAIT, |f| {
        f.get_block_calls() >= 2
    })
    .await;
    assert_eq!(
        cursor(&dir),
        Some(accepting),
        "the cursor moved past the lost removal"
    );
    assert!(
        matches!(
            tracker.status(&sent.to_string()),
            Some(TxStatus::Accepted { .. })
        ),
        "the failed write applied nothing"
    );

    // A reconnect while the disk still refuses: the walk folds its page and
    // its write fails too, so the walk does not move the cursor either.
    dag_tx.send(DagEvent::Connected { url: None }).unwrap();
    fake.wait_until("the walk's page", WAIT, |f| f.vcc_calls(1) >= 1)
        .await;
    // The page is removal-only: once answered it folds with no further
    // await, so this outlasts it many times over.
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(
        cursor(&dir),
        Some(accepting),
        "a walk whose write failed moved the cursor past what it lost"
    );
    held.restore();

    // A reconnect walks from the cursor; the removal lands.
    dag_tx.send(DagEvent::Connected { url: None }).unwrap();
    eventually("the send displaced by the walk", || {
        tracker.status(&sent.to_string()) == Some(TxStatus::Displaced)
    })
    .await;
    eventually("the walk's cursor", || cursor(&dir) == Some(after)).await;
    let walked = Instant::now();

    // Released: a clean live batch moves the cursor again.
    tokio::time::sleep(PAST_THE_THROTTLE.saturating_sub(walked.elapsed())).await;
    vcc_tx.send(batch(vec![], vec![later], vec![])).unwrap();
    eventually("the cursor released", || cursor(&dir) == Some(later)).await;

    let _ = std::fs::remove_dir_all(&dir);
}

/// Waits on tokio's clock, which a paused test advances on its own.
async fn until(what: &str, pred: impl Fn() -> bool) {
    tokio::time::timeout(WAIT, async {
        while !pred() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for {what}"));
}

/// **A held cursor heals on the tracker's own tick, with no reconnect, and
/// keeps its hold while the node cannot answer the walk.** On a steady link
/// the next reconnect can be hours away, and the held-back removal must land
/// before its acceptance reads Confirmed. A walk the node refuses page after
/// page gives up the hold only past the pruning horizon; before it, the next
/// tick walks again. Paused time: the tick is 10 s and a refused page is
/// retried for 8 s.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_held_cursor_heals_on_the_tick_and_waits_out_a_refused_walk() {
    let dir = std::env::temp_dir().join(format!("kv-cursor-tick-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let fake = FakeRpc::new(NetworkId::new(NetworkType::Mainnet));
    let tracker = AcceptanceTracker::load(dir.clone()).unwrap();

    let (sent, probe) = (h(0x21), h(0x22));
    let (accepting, next, probe_block, after) = (h(0xA1), h(0xB1), h(0xA2), h(0xB2));
    tracker.watch(&sent.to_string(), WatchSource::Send);
    tracker.watch(&probe.to_string(), WatchSource::Send);

    let (vcc_tx, vcc_rx) = tokio::sync::mpsc::unbounded_channel();
    let (_dag_tx, dag_rx) = tokio::sync::broadcast::channel(16);
    let _task = tracker.run(fake.rpc(RpcCtl::new()), vcc_rx, dag_rx);
    let start = FakeRpc::sink_hash();
    until("the cursor seeded at the sink", || {
        cursor(&dir) == Some(start)
    })
    .await;
    fake.set_vcc_page(
        accepting,
        GetVirtualChainFromBlockResponse {
            removed_chain_block_hashes: vec![accepting],
            added_chain_block_hashes: vec![after],
            accepted_transaction_ids: vec![],
        },
    );

    vcc_tx
        .send(batch(
            vec![],
            vec![accepting],
            vec![(accepting, vec![sent])],
        ))
        .unwrap();
    until("the cursor at the accepting block", || {
        cursor(&dir) == Some(accepting)
    })
    .await;

    // The removal's write fails; the cursor holds at the accepting block.
    let held = Unwritable::at(dir.join("acceptance.kvlog"));
    vcc_tx
        .send(batch(vec![accepting], vec![next], vec![]))
        .unwrap();
    vcc_tx
        .send(batch(
            vec![],
            vec![probe_block],
            vec![(probe_block, vec![probe])],
        ))
        .unwrap();
    fake.wait_until("the batch after the lost removal", WAIT, |f| {
        f.get_block_calls() >= 2
    })
    .await;
    held.restore();

    // The disk takes writes again, but the node refuses the walk: the tick's
    // walk keeps the hold rather than re-seed at the sink.
    fake.refuse_vcc_pages(true);
    let walks = fake.vcc_calls(1);
    tokio::time::sleep(Duration::from_secs(30)).await;
    assert!(
        fake.vcc_calls(1) > walks,
        "no walk ran on the tick while the cursor was held"
    );
    assert_eq!(
        cursor(&dir),
        Some(accepting),
        "a refused walk gave up the cursor's hold"
    );
    assert!(matches!(
        tracker.status(&sent.to_string()),
        Some(TxStatus::Accepted { .. })
    ));

    // The node answers again: the next tick's walk folds the removal, after
    // a backoff step (paused time makes the wait free).
    fake.refuse_vcc_pages(false);
    tokio::time::sleep(Duration::from_secs(60)).await;
    until("the send displaced by the tick's walk", || {
        tracker.status(&sent.to_string()) == Some(TxStatus::Displaced)
    })
    .await;
    until("the walk's cursor", || cursor(&dir) == Some(after)).await;

    let _ = std::fs::remove_dir_all(&dir);
}

fn nth(i: usize) -> Hash {
    let mut bytes = [0xEE; 32];
    bytes[..8].copy_from_slice(&(i as u64).to_le_bytes());
    Hash::from_bytes(bytes)
}

/// **A walk that spends its page budget before it folds cleanly keeps the
/// hold.** A long gap behind a held cursor: every page is full, and the
/// first one carries the removal the disk refuses. The walk stops at its
/// budget (16 pages) with the cursor still at the accepting block, rather
/// than re-seed at the sink and give the fact up; once the disk takes the
/// write, the next tick's walk lands it. Paused time.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_walk_that_spends_its_budget_unclean_keeps_the_hold() {
    let dir = std::env::temp_dir().join(format!("kv-cursor-budget-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let fake = FakeRpc::new(NetworkId::new(NetworkType::Mainnet));
    let tracker = AcceptanceTracker::load(dir.clone()).unwrap();

    let (sent, probe) = (h(0x31), h(0x32));
    let (accepting, next, probe_block) = (h(0xA1), h(0xB1), h(0xA2));
    tracker.watch(&sent.to_string(), WatchSource::Send);
    tracker.watch(&probe.to_string(), WatchSource::Send);

    let (vcc_tx, vcc_rx) = tokio::sync::mpsc::unbounded_channel();
    let (_dag_tx, dag_rx) = tokio::sync::broadcast::channel(16);
    let _task = tracker.run(fake.rpc(RpcCtl::new()), vcc_rx, dag_rx);
    let start = FakeRpc::sink_hash();
    until("the cursor seeded at the sink", || {
        cursor(&dir) == Some(start)
    })
    .await;
    // The walk from the accepting block: its removal, then a full page.
    fake.set_vcc_page(
        accepting,
        GetVirtualChainFromBlockResponse {
            removed_chain_block_hashes: vec![accepting],
            added_chain_block_hashes: (0..support::FULL_VCC_PAGE).map(nth).collect(),
            accepted_transaction_ids: vec![],
        },
    );
    fake.fill_vcc_pages(true);

    vcc_tx
        .send(batch(
            vec![],
            vec![accepting],
            vec![(accepting, vec![sent])],
        ))
        .unwrap();
    until("the cursor at the accepting block", || {
        cursor(&dir) == Some(accepting)
    })
    .await;
    let held = Unwritable::at(dir.join("acceptance.kvlog"));
    vcc_tx
        .send(batch(vec![accepting], vec![next], vec![]))
        .unwrap();
    vcc_tx
        .send(batch(
            vec![],
            vec![probe_block],
            vec![(probe_block, vec![probe])],
        ))
        .unwrap();
    fake.wait_until("the batch after the lost removal", WAIT, |f| {
        f.get_block_calls() >= 2
    })
    .await;

    // The tick's walk, with the disk still refusing: sixteen full pages.
    let walked = fake.vcc_calls(1);
    until("the walk's page budget spent", || {
        fake.vcc_calls(1) >= walked + 16
    })
    .await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(
        cursor(&dir),
        Some(accepting),
        "a walk that never folded cleanly gave up the cursor's hold"
    );

    held.restore();
    fake.fill_vcc_pages(false);
    // The next tick walk comes after a backoff step (the hold's walks back
    // off from one tick); paused time makes the wait free.
    tokio::time::sleep(Duration::from_secs(60)).await;
    until("the send displaced by the next tick's walk", || {
        tracker.status(&sent.to_string()) == Some(TxStatus::Displaced)
    })
    .await;

    let _ = std::fs::remove_dir_all(&dir);
}

/// **A walk that starts clean and meets a write it cannot make keeps the
/// hold from that page on.** A reconnect walks from the cursor; its first page
/// carries a removal the disk refuses, and the next page is refused by the
/// node. Re-seeding at the sink there would give the removal up; the walk
/// holds the cursor at the page it could not fold, and the next tick's walk
/// lands it. Paused time.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_walk_that_meets_a_failed_write_keeps_the_hold_from_that_page() {
    let dir = std::env::temp_dir().join(format!("kv-cursor-midwalk-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let fake = FakeRpc::new(NetworkId::new(NetworkType::Mainnet));
    let tracker = AcceptanceTracker::load(dir.clone()).unwrap();
    let sent = h(0x41);
    let accepting = h(0xA1);
    tracker.watch(&sent.to_string(), WatchSource::Send);

    let (vcc_tx, vcc_rx) = tokio::sync::mpsc::unbounded_channel();
    let (dag_tx, dag_rx) = tokio::sync::broadcast::channel(16);
    let _task = tracker.run(fake.rpc(RpcCtl::new()), vcc_rx, dag_rx);
    let start = FakeRpc::sink_hash();
    until("the cursor seeded at the sink", || {
        cursor(&dir) == Some(start)
    })
    .await;
    // The walk from the accepting block: its removal, then a full page, so
    // the walk goes on to a page from a start nobody keyed.
    fake.set_vcc_page(
        accepting,
        GetVirtualChainFromBlockResponse {
            removed_chain_block_hashes: vec![accepting],
            added_chain_block_hashes: (0..support::FULL_VCC_PAGE).map(nth).collect(),
            accepted_transaction_ids: vec![],
        },
    );
    vcc_tx
        .send(batch(
            vec![],
            vec![accepting],
            vec![(accepting, vec![sent])],
        ))
        .unwrap();
    until("the cursor at the accepting block", || {
        cursor(&dir) == Some(accepting)
    })
    .await;

    // A reconnect, the disk refusing and the node refusing the second page.
    let held = Unwritable::at(dir.join("acceptance.kvlog"));
    fake.refuse_unkeyed_vcc_pages(true);
    let walked = fake.vcc_calls(1);
    dag_tx.send(DagEvent::Connected { url: None }).unwrap();
    until("the walk's refused second page", || {
        fake.vcc_calls(1) >= walked + 1 + 8
    })
    .await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(
        cursor(&dir),
        Some(accepting),
        "a walk that could not write its first page gave up the hold"
    );

    held.restore();
    fake.refuse_unkeyed_vcc_pages(false);
    until("the send displaced by the tick's walk", || {
        tracker.status(&sent.to_string()) == Some(TxStatus::Displaced)
    })
    .await;

    let _ = std::fs::remove_dir_all(&dir);
}

/// **A held cursor backs off a walk the node keeps refusing.** Each tick walk
/// that leaves the hold in place doubles the wait, up to five minutes: over
/// ten minutes of refusals the walks number a handful, not one per tick.
/// Paused time.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_held_cursor_backs_off_a_walk_the_node_keeps_refusing() {
    let dir = std::env::temp_dir().join(format!("kv-cursor-backoff-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let fake = FakeRpc::new(NetworkId::new(NetworkType::Mainnet));
    let tracker = AcceptanceTracker::load(dir.clone()).unwrap();
    let (sent, probe) = (h(0x51), h(0x52));
    let (accepting, next, probe_block) = (h(0xA1), h(0xB1), h(0xA2));
    tracker.watch(&sent.to_string(), WatchSource::Send);
    tracker.watch(&probe.to_string(), WatchSource::Send);

    let (vcc_tx, vcc_rx) = tokio::sync::mpsc::unbounded_channel();
    let (_dag_tx, dag_rx) = tokio::sync::broadcast::channel(16);
    let _task = tracker.run(fake.rpc(RpcCtl::new()), vcc_rx, dag_rx);
    let start = FakeRpc::sink_hash();
    until("the cursor seeded at the sink", || {
        cursor(&dir) == Some(start)
    })
    .await;
    vcc_tx
        .send(batch(
            vec![],
            vec![accepting],
            vec![(accepting, vec![sent])],
        ))
        .unwrap();
    until("the cursor at the accepting block", || {
        cursor(&dir) == Some(accepting)
    })
    .await;
    let held = Unwritable::at(dir.join("acceptance.kvlog"));
    vcc_tx
        .send(batch(vec![accepting], vec![next], vec![]))
        .unwrap();
    vcc_tx
        .send(batch(
            vec![],
            vec![probe_block],
            vec![(probe_block, vec![probe])],
        ))
        .unwrap();
    fake.wait_until("the batch after the lost removal", WAIT, |f| {
        f.get_block_calls() >= 2
    })
    .await;
    held.restore();

    // Every page refused for ten minutes: eight attempts a walk.
    fake.refuse_vcc_pages(true);
    let before = fake.vcc_calls(1);
    tokio::time::sleep(Duration::from_secs(600)).await;
    let walks = (fake.vcc_calls(1) - before) / 8;
    assert!(
        (2..=8).contains(&walks),
        "{walks} walks in ten minutes of refusals"
    );
    assert_eq!(cursor(&dir), Some(accepting));

    let _ = std::fs::remove_dir_all(&dir);
}

/// **A new hold walks at its first tick.** The walk backoff belongs to one
/// hold: after a reconnect's walk released a hold whose backoff had grown, a
/// hold begun moments later is walked at the next tick, not when the old one
/// would have been. Paused time.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_new_hold_walks_at_its_first_tick() {
    let dir = std::env::temp_dir().join(format!("kv-cursor-new-hold-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let fake = FakeRpc::new(NetworkId::new(NetworkType::Mainnet));
    let tracker = AcceptanceTracker::load(dir.clone()).unwrap();
    let (sent, probe, again, probe_again) = (h(0x51), h(0x52), h(0x53), h(0x54));
    let (accepting, next, probe_block, healed) = (h(0xA1), h(0xB1), h(0xA2), h(0xB2));
    let (second, after, probe_second) = (h(0xC1), h(0xD1), h(0xC2));
    for txid in [sent, probe, again, probe_again] {
        tracker.watch(&txid.to_string(), WatchSource::Send);
    }

    let (vcc_tx, vcc_rx) = tokio::sync::mpsc::unbounded_channel();
    let (dag_tx, dag_rx) = tokio::sync::broadcast::channel(16);
    let _task = tracker.run(fake.rpc(RpcCtl::new()), vcc_rx, dag_rx);
    let start = FakeRpc::sink_hash();
    until("the cursor seeded at the sink", || {
        cursor(&dir) == Some(start)
    })
    .await;
    fake.set_vcc_page(
        accepting,
        GetVirtualChainFromBlockResponse {
            removed_chain_block_hashes: vec![accepting],
            added_chain_block_hashes: vec![healed],
            accepted_transaction_ids: vec![],
        },
    );
    vcc_tx
        .send(batch(
            vec![],
            vec![accepting],
            vec![(accepting, vec![sent])],
        ))
        .unwrap();
    until("the cursor at the accepting block", || {
        cursor(&dir) == Some(accepting)
    })
    .await;
    let held = Unwritable::at(dir.join("acceptance.kvlog"));
    vcc_tx
        .send(batch(vec![accepting], vec![next], vec![]))
        .unwrap();
    vcc_tx
        .send(batch(
            vec![],
            vec![probe_block],
            vec![(probe_block, vec![probe])],
        ))
        .unwrap();
    fake.wait_until("the batch after the lost removal", WAIT, |f| {
        f.get_block_calls() >= 2
    })
    .await;
    held.restore();

    // Refused long enough for the backoff to grow past two minutes, then a
    // reconnect's walk, answered, releases the hold.
    fake.refuse_vcc_pages(true);
    tokio::time::sleep(Duration::from_secs(200)).await;
    fake.refuse_vcc_pages(false);
    dag_tx.send(DagEvent::Connected { url: None }).unwrap();
    until("the reconnect's walk released the hold", || {
        cursor(&dir) == Some(healed)
    })
    .await;
    assert_eq!(tracker.status(&sent.to_string()), Some(TxStatus::Displaced));

    // A second acceptance, written; its removal lost: a new hold.
    let blocks = fake.get_block_calls();
    vcc_tx
        .send(batch(vec![], vec![second], vec![(second, vec![again])]))
        .unwrap();
    until("the cursor at the second accepting block", || {
        cursor(&dir) == Some(second)
    })
    .await;
    let held = Unwritable::at(dir.join("acceptance.kvlog"));
    vcc_tx
        .send(batch(vec![second], vec![after], vec![]))
        .unwrap();
    vcc_tx
        .send(batch(
            vec![],
            vec![probe_second],
            vec![(probe_second, vec![probe_again])],
        ))
        .unwrap();
    fake.wait_until("the batch after the second lost removal", WAIT, |f| {
        f.get_block_calls() >= blocks + 2
    })
    .await;
    held.restore();

    fake.refuse_vcc_pages(true);
    let before = fake.vcc_calls(1);
    tokio::time::sleep(Duration::from_secs(25)).await;
    assert!(
        fake.vcc_calls(1) > before,
        "the new hold waited out the old one's backoff"
    );
    assert_eq!(cursor(&dir), Some(second));

    let _ = std::fs::remove_dir_all(&dir);
}
