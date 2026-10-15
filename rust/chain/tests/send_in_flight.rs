//! A send's submit and the wallet lane around it.
//!
//! The pinned `try_submit` registers its transaction in the processor's
//! outgoing map, broadcasts it, then reads the entry back and `.expect()`s it
//! (pin `wallet/core/src/utxo/context.rs:265`, `:285` @ `01b532e`). A close of
//! the processor clears that map (`processor.rs:594-615`) without the lock the
//! submit holds. So a close that lands between the broadcast and the read back
//! turned a transaction the node had into a panic, a send the user saw fail,
//! and a retry that built a second payment from other coins.
//!
//! **The real path each case stands for** (the fake supplies a node, never the
//! failure under test):
//!
//! - `a_close_during_a_submit_waits_for_it`: the link closes the socket while
//!   the node has the transaction and its answer is on the way. The close is
//!   the monitor's own ctl, through the lane's relay, exactly as in the app.
//! - `a_submit_without_an_answer_is_named_and_a_refused_one_is_not`: the ways
//!   a submit fails after its request may have left, wrapped as the pinned
//!   wRPC client wraps them (`RpcSubsystem`, `rpc/macros/src/wrpc/client.rs:73-74`),
//!   and the stable handle's refusal before any request.
//! - `a_send_that_straddles_a_rebuild_reaches_the_activity`: a close the
//!   submit holds back goes unacknowledged past its bound, so the supervisor
//!   rebuilds the lane while the submit is still out.
//! - `a_send_behind_a_stuck_processor_is_refused_before_its_broadcast`: the
//!   processor stuck inside its handler with its notification lock taken (the
//!   pinned sync monitor dead with its running flag set, the supervision
//!   suite's own staging), which the pinned `try_submit` would wait on forever.
//!
//! And what the balance says while a send is in flight:
//!
//! - `a_merge_in_flight_is_unsettled_not_gone`: a merge to our own address
//!   has no payment value, so the pin's `calculate_balance` (`context.rs:506-547`)
//!   reads mature, pending and outgoing all zero until its acceptance. The
//!   balance event carries what it left out.
//! - `a_send_that_outlives_its_socket_*`: a close between a send's submit and
//!   its acceptance clears the processor's outgoing map and not the context's
//!   (`cleanup()`, `processor.rs:609-615`). The record left behind is
//!   discharged before the reopen's rescan, landed or not.
//!
//! And what a read of the node's unspent set may decide and file:
//!
//! - `a_narrow_read_leaves_a_send_it_did_not_ask_about_in_flight`: a prepare
//!   reads its change address alone, as in the app.
//! - `a_read_during_a_submit_leaves_that_send_to_its_submit`: a prepare while
//!   a send's submit is out, the node's answer already without its coins.
//! - `a_send_accepted_after_the_answer_keeps_its_coins_out`: the read held at
//!   the node while the acceptance is folded.
//! - `a_read_files_new_coins_without_holding_the_handler`: the timestamp call
//!   a filing makes, held at the node while a deposit arrives.
//! - `a_read_before_the_reopen_hands_back_the_sends_files_nothing_they_create`:
//!   the processor held inside its connect, as a slow subscribe holds it.

mod support;

use std::collections::HashSet;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Once};
use std::time::Duration;

use kaspa_consensus_core::tx::SignableTransaction;
use kaspa_txscript::extract_script_pub_key_address;
use kaspa_txscript::pay_to_address_script;
use kaspa_wallet_core::rpc::RpcCtl;
use kaspa_wallet_core::tx::generator::signer::SignerT;
use kaspa_wrpc_client::prelude::{
    NetworkId, NetworkType, Notification, RpcTransaction, RpcTransactionOutpoint, RpcUtxoEntry,
    RpcUtxosByAddressesEntry, UtxosChangedNotification, VirtualDaaScoreChangedNotification,
};
use kaspaverse_chain::{
    Address, Hash, PreparedSend, WalletEngine, WalletEvent, LANE_HOLD_WITHIN, LANE_STEP_WITHIN,
};
use support::{FakeRpc, SubmitAnswer};

const WAIT: Duration = Duration::from_secs(15);
const SOMPI_PER_KAS: u64 = 100_000_000;

/// Panics located in the pinned wallet framework, counted by a chained hook
/// installed once per test binary.
static WALLET_CORE_PANICS: AtomicUsize = AtomicUsize::new(0);

/// One test at a time: the panic count and the process panic hook are
/// process-wide, so a panic staged in one test would read as one in another.
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn count_wallet_core_panics() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        kaspaverse_chain::lane_health::install_panic_hook();
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

/// Signs nothing. The fake node checks no signature, and what is under test
/// is what happens around the broadcast, not the signature.
struct Unsigned;

impl SignerT for Unsigned {
    fn try_sign(
        &self,
        transaction: SignableTransaction,
        _addresses: &[Address],
    ) -> kaspa_wallet_core::result::Result<SignableTransaction> {
        Ok(transaction)
    }
}

fn address(text: &str) -> Address {
    text.try_into().expect("address")
}

fn receive() -> Address {
    address("kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692")
}

fn change() -> Address {
    address("kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf")
}

/// A payee outside the wallet.
fn payee() -> Address {
    address("kaspa:qqwsnxvukqew5hx5r7y5dr938hnw7hmgs7ca87zlvwlrps6rxdy2ja3xknpvj")
}

/// A mature coin at `at` (the fake node's virtual DAA score is 1,000,000).
fn coin(at: &Address, n: u8, sompi: u64) -> RpcUtxosByAddressesEntry {
    RpcUtxosByAddressesEntry {
        address: Some(at.clone()),
        outpoint: RpcTransactionOutpoint {
            transaction_id: Hash::from_bytes([n; 32]),
            index: 0,
        },
        utxo_entry: RpcUtxoEntry::new(sompi, pay_to_address_script(at), 900_000, false, None),
    }
}

fn tmp(name: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("kv-send-{}-{name}", std::process::id()))
}

async fn next_event(
    events: &mut tokio::sync::broadcast::Receiver<WalletEvent>,
    within: Duration,
    pred: impl Fn(&WalletEvent) -> bool,
) -> Option<WalletEvent> {
    tokio::time::timeout(within, async {
        loop {
            match events.recv().await {
                Ok(event) if pred(&event) => return event,
                Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(e) => panic!("wallet event stream closed: {e}"),
            }
        }
    })
    .await
    .ok()
}

/// The engine on the fake with two 10 KAS coins at the receive address,
/// connected, its first balance folded.
async fn funded(
    name: &str,
    fake: &Arc<FakeRpc>,
    ctl: &RpcCtl,
) -> (
    WalletEngine,
    tokio::sync::broadcast::Receiver<WalletEvent>,
    std::path::PathBuf,
) {
    funded_with(
        name,
        fake,
        ctl,
        vec![
            coin(&receive(), 0x51, 10 * SOMPI_PER_KAS),
            coin(&receive(), 0x52, 10 * SOMPI_PER_KAS),
        ],
    )
    .await
}

/// The engine on the fake holding `coins`, connected, its first balance
/// folded.
async fn funded_with(
    name: &str,
    fake: &Arc<FakeRpc>,
    ctl: &RpcCtl,
    coins: Vec<RpcUtxosByAddressesEntry>,
) -> (
    WalletEngine,
    tokio::sync::broadcast::Receiver<WalletEvent>,
    std::path::PathBuf,
) {
    let total: u64 = coins.iter().map(|c| c.utxo_entry.amount).sum();
    fake.set_utxos(coins);
    let store = tmp(name);
    let _ = std::fs::remove_file(&store);
    let engine = WalletEngine::new(
        fake.rpc(ctl.clone()),
        NetworkId::new(NetworkType::Mainnet),
        store.clone(),
    )
    .expect("engine");
    let mut events = engine.subscribe();
    engine
        .start(vec![receive(), change()], vec![change()])
        .await
        .expect("engine start");
    ctl.signal_open().await.expect("signal open");
    next_event(
        &mut events,
        WAIT,
        |e| matches!(e, WalletEvent::Balance { mature, .. } if *mature == total),
    )
    .await
    .expect("the funded balance");
    (engine, events, store)
}

/// One KAS to the payee, change home to the receive address.
async fn one_kas(engine: &WalletEngine, fake: &Arc<FakeRpc>, ctl: &RpcCtl) -> PreparedSend {
    engine
        .prepare_send(
            payee(),
            SOMPI_PER_KAS,
            receive(),
            Arc::new(Unsigned),
            fake.rpc(ctl.clone()),
            None,
            &[],
        )
        .await
        .expect("a buildable send")
}

fn mainnet_fake() -> Arc<FakeRpc> {
    FakeRpc::new(NetworkId::new(NetworkType::Mainnet))
}

/// **A close while the node has the transaction waits for its answer.** The
/// processor does not read disconnected until the submit returns, the send
/// reports the broadcast, and its record reaches the activity; then the close
/// lands. No panic anywhere in the wallet framework.
#[tokio::test(flavor = "multi_thread")]
async fn a_close_during_a_submit_waits_for_it() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded("close-straddle.kvlog", &fake, &ctl).await;
    let prepared = one_kas(&engine, &fake, &ctl).await;

    let hold = fake.hold_submits();
    let commit = tokio::spawn(prepared.commit(None));
    fake.wait_until("the submit at the node", WAIT, |f| f.submitted().len() == 1)
        .await;

    ctl.signal_close().await.expect("signal close");
    assert!(
        next_event(&mut events, Duration::from_millis(300), |e| {
            matches!(e, WalletEvent::Disconnected)
        })
        .await
        .is_none(),
        "the close reached the processor while the submit was out"
    );

    hold.add_permits(1);
    let outcome = commit.await.expect("the send's task must not panic");
    assert_eq!(
        outcome.error, None,
        "a broadcast the node took reported as failed"
    );
    assert_eq!(outcome.submitted, 1);
    let txid = outcome.final_txid.clone().expect("the broadcast's txid");
    assert!(
        next_event(&mut events, WAIT, |e| matches!(
            e,
            WalletEvent::Disconnected
        ))
        .await
        .is_some(),
        "the close lands once the submit has returned"
    );
    assert_eq!(
        WALLET_CORE_PANICS.load(Ordering::SeqCst),
        panics_before,
        "a panic in the pinned wallet framework"
    );
    assert!(
        engine.activity_daa_score(&txid).is_some(),
        "the send's record never reached the activity"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A submit whose request may have left is named; one refused before it is
/// not.** A timeout, a dropped socket and a node's error alike mean the
/// transaction may be on the network, so the outcome names its txid for the
/// caller to watch. Neither kind reaches the hook whose caller keeps an
/// acknowledged leg's bytes for the stall lane's resend: a leg that may never
/// have reached a node, resent after the user sent again with other coins,
/// would pay twice.
#[tokio::test(flavor = "multi_thread")]
async fn a_submit_without_an_answer_is_named_and_a_refused_one_is_not() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, _events, store) = funded("unanswered.kvlog", &fake, &ctl).await;

    for (answer, unanswered) in [
        (SubmitAnswer::Fail("WebSocket disconnected".into()), true),
        (SubmitAnswer::Fail("RPC request timeout".into()), true),
        // A node's error is no proof nothing went out: it refuses a
        // transaction it already holds, or one a node has accepted.
        (
            SubmitAnswer::Fail(
                "RPC response error Text(\"Rejected transaction 11: fee too low\")".into(),
            ),
            true,
        ),
        (
            SubmitAnswer::Fail(
                "RPC response error Text(\"transaction 11 is already in the mempool\")".into(),
            ),
            true,
        ),
        // Refused before any request: the only kind that proves it.
        (SubmitAnswer::Unbound, false),
    ] {
        let label = format!("{answer:?}");
        fake.answer_submits(answer);
        let sent_before = fake.submitted().len();
        let prepared = one_kas(&engine, &fake, &ctl).await;
        let mut kept: Vec<(String, RpcTransaction)> = Vec::new();
        let mut hook = |txid: &str, signed: RpcTransaction| kept.push((txid.to_string(), signed));
        let outcome = prepared.commit(Some(&mut hook)).await;
        assert_eq!(outcome.submitted, 0, "{label}");
        assert!(outcome.error.is_some(), "{label}");
        let at_node = fake.submitted();
        if unanswered {
            assert_eq!(at_node.len(), sent_before + 1, "{label}");
            let sent_id =
                kaspa_consensus_core::tx::Transaction::try_from(at_node[sent_before].clone())
                    .expect("a transaction")
                    .id()
                    .to_string();
            assert_eq!(outcome.unanswered, Some(sent_id), "{label}");
        } else {
            assert_eq!(at_node.len(), sent_before, "{label}");
            // The wallet's own refusal, said in words, not the link's string.
            assert_eq!(
                outcome.error.as_deref(),
                Some("The wallet could not reach the network in time. Try again in a moment."),
                "{label}"
            );
            assert_eq!(outcome.unanswered, None, "{label}");
        }
        assert!(
            kept.is_empty(),
            "a leg with no acknowledgement was kept: {label}"
        );
    }

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A send that straddles a rebuild still reaches the activity.** The close
/// the submit holds back goes unacknowledged past its bound, so the lane is
/// rebuilt while the submit is out. The old processor stops only after the
/// submit returns, and the old lane's fold, held up until then, folds the
/// send's record. Paused time.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_send_that_straddles_a_rebuild_reaches_the_activity() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, _events, store) = funded("rebuild-straddle.kvlog", &fake, &ctl).await;
    let prepared = one_kas(&engine, &fake, &ctl).await;

    let hold = fake.hold_submits();
    let commit = tokio::spawn(prepared.commit(None));
    fake.wait_until("the submit at the node", WAIT, |f| f.submitted().len() == 1)
        .await;
    ctl.signal_close().await.expect("signal close");
    tokio::time::timeout(LANE_STEP_WITHIN * 3, async {
        while engine.lanes_built() < 2 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the unacknowledged close convicted and the lane rebuilt");

    hold.add_permits(1);
    let outcome = commit.await.expect("the send's task must not panic");
    assert_eq!(outcome.error, None);
    assert_eq!(outcome.submitted, 1);
    let txid = outcome.final_txid.clone().expect("txid");
    tokio::time::timeout(WAIT, async {
        while engine.activity_daa_score(&txid).is_none() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the straddled send's record reached the activity");
    assert_eq!(WALLET_CORE_PANICS.load(Ordering::SeqCst), panics_before);

    tokio::time::timeout(LANE_STEP_WITHIN * 2, engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A send behind a stuck processor is refused before its broadcast.** The
/// processor holds its notification lock inside its handler and never lets go;
/// the pinned `try_submit` would wait on it forever, even after the lane is
/// rebuilt, because the send was built on this lane's context. The wait is
/// bounded before the submit, never around it, and nothing reaches the node.
/// Paused time.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_send_behind_a_stuck_processor_is_refused_before_its_broadcast() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    fake.report_unsynced(1);
    fake.panic_on_sync_status(1);
    let ctl = RpcCtl::new();
    let (engine, _events, store) = funded("stuck-lock.kvlog", &fake, &ctl).await;
    fake.wait_until("the sync monitor's poll", WAIT, |f| {
        f.sync_status_calls() >= 1
    })
    .await;
    let prepared = one_kas(&engine, &fake, &ctl).await;

    // The socket keeps talking; a frame takes the processor's lock, and its
    // handler waits on the dead sync monitor for good.
    let pulse = {
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
    };
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![]),
            removed: Arc::new(vec![]),
        }))
        .await
            >= 1
    );
    tokio::time::sleep(Duration::from_millis(100)).await;

    let outcome = tokio::time::timeout(LANE_HOLD_WITHIN * 2, prepared.commit(None))
        .await
        .expect("the send never came back");
    assert_eq!(outcome.submitted, 0);
    assert_eq!(
        outcome.unanswered, None,
        "a refusal before the broadcast is not unanswered"
    );
    assert!(
        outcome
            .error
            .as_deref()
            .is_some_and(|e| e.contains("could not reach the network in time")),
        "{:?}",
        outcome.error
    );
    assert!(
        fake.submitted().is_empty(),
        "the transaction reached the node"
    );

    pulse.abort();
    tokio::time::timeout(LANE_STEP_WITHIN * 2, engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// The output of a submitted transaction that pays `to`: its index and value.
fn output_to(transaction: &RpcTransaction, to: &Address) -> (u32, u64) {
    transaction
        .outputs
        .iter()
        .enumerate()
        .find_map(|(index, output)| {
            (extract_script_pub_key_address(&output.script_public_key, to.prefix).ok()? == *to)
                .then_some((index as u32, output.value))
        })
        .expect("an output to the address")
}

/// The coin a transaction's output becomes at the node.
fn output_coin(
    at: &Address,
    txid: Hash,
    index: u32,
    sompi: u64,
    daa: u64,
) -> RpcUtxosByAddressesEntry {
    RpcUtxosByAddressesEntry {
        address: Some(at.clone()),
        outpoint: RpcTransactionOutpoint {
            transaction_id: txid,
            index,
        },
        utxo_entry: RpcUtxoEntry::new(sompi, pay_to_address_script(at), daa, false, None),
    }
}

/// The balance event the predicate picks, or a failure naming it.
async fn balance_where(
    events: &mut tokio::sync::broadcast::Receiver<WalletEvent>,
    what: &str,
    pred: impl Fn(u64, u64, u64, u64) -> bool,
) -> (u64, u64, u64, u64) {
    match next_event(events, WAIT, |e| match e {
        WalletEvent::Balance {
            mature,
            pending,
            outgoing,
            unsettled,
        } => pred(*mature, *pending, *outgoing, *unsettled),
        _ => false,
    })
    .await
    {
        Some(WalletEvent::Balance {
            mature,
            pending,
            outgoing,
            unsettled,
        }) => (mature, pending, outgoing, unsettled),
        _ => panic!("timed out waiting for {what}"),
    }
}

/// **A merge in flight is unsettled, not gone.** The pin's figures read zero
/// for the moment between the merge's submit and its acceptance; the balance
/// event carries the merged amount as unsettled through it, and drops it in
/// the same event that brings the coin home.
#[tokio::test(flavor = "multi_thread")]
async fn a_merge_in_flight_is_unsettled_not_gone() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded("merge-in-flight.kvlog", &fake, &ctl).await;
    let prepared = engine
        .prepare_consolidate(receive(), &[], Arc::new(Unsigned), fake.rpc(ctl.clone()))
        .await
        .expect("a buildable merge");
    let outcome = prepared.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let merge = fake.submitted().pop().expect("the merge at the node");
    let (index, merged) = output_to(&merge, &receive());

    // The pin's own figures for a transaction with no payment value: zero,
    // all three. The event carries what they leave out.
    let in_flight = balance_where(&mut events, "the balance after the submit", |m, _, _, _| {
        m == 0
    })
    .await;
    assert_eq!(
        in_flight,
        (0, 0, 0, merged),
        "(mature, pending, outgoing, unsettled)"
    );

    // Accepted: the coins it spent leave, the merged coin arrives.
    let txid: Hash = outcome.final_txid.expect("txid").parse().expect("a txid");
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![output_coin(
                &receive(),
                txid,
                index,
                merged,
                1_000_001
            )]),
            removed: Arc::new(vec![
                coin(&receive(), 0x51, 10 * SOMPI_PER_KAS),
                coin(&receive(), 0x52, 10 * SOMPI_PER_KAS),
            ]),
        }))
        .await
            >= 1
    );
    let settled = balance_where(&mut events, "the balance at acceptance", |m, _, _, _| {
        m == merged
    })
    .await;
    assert_eq!(
        settled,
        (merged, 0, 0, 0),
        "(mature, pending, outgoing, unsettled)"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// A one-KAS payment submitted, then its socket closed before its acceptance
/// reached the wallet. Answers the transaction and the coin it spent.
async fn sent_then_closed(
    fake: &Arc<FakeRpc>,
    ctl: &RpcCtl,
    engine: &WalletEngine,
    events: &mut tokio::sync::broadcast::Receiver<WalletEvent>,
) -> (RpcTransaction, Hash) {
    let outcome = one_kas(engine, fake, ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let sent = fake.submitted().pop().expect("the payment at the node");
    ctl.signal_close().await.expect("signal close");
    next_event(events, WAIT, |e| matches!(e, WalletEvent::Disconnected))
        .await
        .expect("the processor's disconnect");
    let txid: Hash = outcome.final_txid.expect("txid").parse().expect("a txid");
    (sent, txid)
}

/// The funded wallet's two coins split by `sent`: those it left unspent, as
/// the node lists them, and those it spent.
fn split_by(
    sent: &RpcTransaction,
) -> (Vec<RpcUtxosByAddressesEntry>, Vec<RpcUtxosByAddressesEntry>) {
    let spent: HashSet<Hash> = sent
        .inputs
        .iter()
        .map(|input| input.previous_outpoint.transaction_id)
        .collect();
    [0x51u8, 0x52]
        .into_iter()
        .map(|n| coin(&receive(), n, 10 * SOMPI_PER_KAS))
        .partition(|entry| !spent.contains(&entry.outpoint.transaction_id))
}

fn value_of(coins: &[RpcUtxosByAddressesEntry]) -> u64 {
    coins.iter().map(|entry| entry.utxo_entry.amount).sum()
}

/// **A send that outlived its socket and landed is counted once.** At the
/// reopen the node has the change and no longer has the coins it spent; the
/// balance is the coins it left plus the change, exactly, with nothing
/// outgoing.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_that_outlives_its_socket_and_landed_is_counted_once() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded("orphan-landed.kvlog", &fake, &ctl).await;
    let (sent, txid) = sent_then_closed(&fake, &ctl, &engine, &mut events).await;
    let (index, change) = output_to(&sent, &receive());
    let (mut node, _) = split_by(&sent);
    let left = value_of(&node);
    // Already mature at the rescan: no promotion will run on it.
    node.push(output_coin(&receive(), txid, index, change, 900_001));

    fake.set_utxos(node);
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    let reopened = balance_where(&mut events, "the balance after the reopen", |_, _, _, _| {
        true
    })
    .await;
    assert_eq!(
        reopened,
        (left + change, 0, 0, 0),
        "(mature, pending, outgoing, unsettled)"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A send the node may still hold keeps its coin out at a reopen.** The
/// node took it, and at the reopen its index still lists the coin it spent:
/// the send may be in a mempool, which the index does not see. The coin stays
/// off the spendable set and the balance reads as before the close; the
/// send's acceptance after the reopen settles it once, and its record is
/// purged at maturity with no lane death.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_the_node_may_still_hold_keeps_its_coin_out_at_a_reopen() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded("orphan-held.kvlog", &fake, &ctl).await;
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let in_flight = balance_where(
        &mut events,
        "the balance with the send in flight",
        |_, _, o, _| o > 0,
    )
    .await;
    let sent = fake.submitted().pop().expect("the payment at the node");
    let txid: Hash = outcome.final_txid.expect("txid").parse().expect("a txid");
    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");

    // The index still lists both coins.
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    let reopened = balance_where(&mut events, "the balance after the reopen", |_, _, _, _| {
        true
    })
    .await;
    assert_eq!(
        reopened, in_flight,
        "(mature, pending, outgoing, unsettled) changed across the reopen"
    );
    let spendable: u64 = engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set")
        .iter()
        .map(|entry| entry.amount)
        .sum();
    let (unspent, spent) = split_by(&sent);
    let left = value_of(&unspent);
    assert_eq!(
        spendable, left,
        "a coin came back while its send may be in a mempool"
    );

    // Accepted after the reopen: the coins it spent leave, the change arrives.
    let (index, change) = output_to(&sent, &receive());
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![output_coin(
                &receive(),
                txid,
                index,
                change,
                1_000_001
            )]),
            removed: Arc::new(spent),
        }))
        .await
            >= 1
    );
    let settled = balance_where(
        &mut events,
        "the balance at its acceptance",
        |_, _, o, _| o == 0,
    )
    .await;
    assert_eq!(
        settled,
        (left + change, 0, 0, 0),
        "(mature, pending, outgoing, unsettled)"
    );
    past_maturity(&fake).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(WALLET_CORE_PANICS.load(Ordering::SeqCst), panics_before);
    assert_eq!(engine.lane_deaths(), 0);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A leg the pin cancelled, which landed while the socket was down, is not
/// spendable again.** Its submit got no answer and the pin returned its coin
/// to the mature list; the node took it all the same. At the reopen the index
/// no longer lists its coins, and the balance is the coins it left plus the
/// change, each counted once.
#[tokio::test(flavor = "multi_thread")]
async fn a_cancelled_leg_that_landed_while_down_is_not_spendable_again() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded("cancelled-landed.kvlog", &fake, &ctl).await;
    fake.answer_submits(SubmitAnswer::Fail(
        "RPC response error: a timeout".to_string(),
    ));
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!(outcome.submitted, 0);
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    fake.answer_submits(SubmitAnswer::Accept);
    let sent = fake.submitted().pop().expect("the leg at the node");
    let txid = txid_of(&sent);
    let (index, change) = output_to(&sent, &receive());
    let (mut node, _) = split_by(&sent);
    let left = value_of(&node);
    node.push(output_coin(&receive(), txid, index, change, 900_001));
    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");

    fake.set_utxos(node);
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    let reopened = balance_where(&mut events, "the balance after the reopen", |m, _, _, _| {
        m != 20 * SOMPI_PER_KAS
    })
    .await;
    assert_eq!(
        reopened,
        (left + change, 0, 0, 0),
        "(mature, pending, outgoing, unsettled)"
    );
    let spendable: u64 = engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set")
        .iter()
        .map(|entry| entry.amount)
        .sum();
    assert_eq!(spendable, left + change);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A send waiting through a reopen goes out after the reopen's rescan.**
/// The processor reads connected before it registers its listener and its
/// start; a submit admitted then would register before the reopen had handed
/// back its sends or armed the subscription, and could miss its own
/// acceptance. The reopen's UTXO read is held at the node: nothing is
/// submitted until it is answered.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_waiting_through_a_reopen_goes_out_after_its_rescan() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded("reopen-wait.kvlog", &fake, &ctl).await;
    let prepared = one_kas(&engine, &fake, &ctl).await;
    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");

    let scans = fake.hold_scans();
    let commit = tokio::spawn(prepared.commit(None));
    let epoch = fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    fake.wait_until("the reopen's UTXO read", WAIT, |f| f.utxo_scans(epoch) >= 1)
        .await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(
        fake.submitted().is_empty(),
        "the send went out before the reopen's rescan was answered"
    );

    scans.add_permits(1_000);
    let outcome = tokio::time::timeout(WAIT, commit)
        .await
        .expect("the send came back")
        .expect("the send's task must not panic");
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A send built on a lane that has since been replaced is refused before
/// its broadcast.** Its transactions were built over the old lane's context,
/// whose processor is stopping or stopped: submitting there would land a
/// record nothing folds. The close is held unacknowledged past its bound (a
/// frame queued behind the processor's own lock, the supervision suite's
/// staging), so the supervisor replaces the lane. Paused time.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_send_built_on_a_replaced_lane_is_refused_before_its_broadcast() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, _events, store) = funded("replaced-lane.kvlog", &fake, &ctl).await;
    let prepared = one_kas(&engine, &fake, &ctl).await;

    let processor = engine.context().processor().clone();
    let held = processor.notification_lock().await;
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![]),
            removed: Arc::new(vec![]),
        }))
        .await
            >= 1
    );
    // The gate's forwarder hands the frame over on its own task: let it run,
    // or the close's sever can end the frame's epoch first and the gate drops
    // it, leaving nothing to hold the close back.
    tokio::time::sleep(Duration::from_millis(50)).await;
    ctl.signal_close().await.expect("signal close");
    tokio::time::timeout(LANE_STEP_WITHIN * 3, async {
        while engine.lanes_built() < 2 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the lane replaced");
    drop(held);

    let outcome = tokio::time::timeout(LANE_HOLD_WITHIN * 2, prepared.commit(None))
        .await
        .expect("the send came back");
    assert_eq!(outcome.submitted, 0);
    assert_eq!(outcome.unanswered, None);
    assert!(
        outcome
            .error
            .as_deref()
            .is_some_and(|e| e.contains("reconnected during the send")),
        "{:?}",
        outcome.error
    );
    assert!(
        fake.submitted().is_empty(),
        "the transaction reached the node"
    );

    tokio::time::timeout(LANE_STEP_WITHIN * 2, engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// One more DAA tick, past the user maturity hold (100 DAA, pin
/// `wallet/core/src/utxo/settings.rs:49`): the processor promotes what it
/// holds pending.
async fn past_maturity(fake: &FakeRpc) {
    assert!(
        fake.deliver(Notification::VirtualDaaScoreChanged(
            VirtualDaaScoreChangedNotification {
                virtual_daa_score: 1_000_200,
            },
        ))
        .await
            >= 1
    );
}

fn txid_of(transaction: &RpcTransaction) -> Hash {
    kaspa_consensus_core::tx::Transaction::try_from(transaction.clone())
        .expect("a transaction")
        .id()
}

/// **A send that outlived its socket and landed, its change still pending at
/// the reopen, matures without a lane death.** The pin promotes a pending
/// coin only if no outgoing record names its transaction (`context.rs:408-411`,
/// `unreachable!`); the record a close orphaned would kill the processor at
/// the change's promotion.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_that_outlives_its_socket_and_landed_matures_its_change() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded("orphan-pending.kvlog", &fake, &ctl).await;
    let (sent, txid) = sent_then_closed(&fake, &ctl, &engine, &mut events).await;
    let (index, change) = output_to(&sent, &receive());
    let (mut node, _) = split_by(&sent);
    let left = value_of(&node);
    // Accepted a moment ago: still inside the maturity hold at the reopen.
    node.push(output_coin(&receive(), txid, index, change, 1_000_001));
    fake.set_utxos(node);
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    let reopened = balance_where(&mut events, "the balance after the reopen", |_, _, _, _| {
        true
    })
    .await;
    assert_eq!(reopened, (left, change, 0, 0));

    past_maturity(&fake).await;
    let matured = balance_where(&mut events, "the change matured", |m, _, _, _| {
        m == left + change
    })
    .await;
    assert_eq!(matured, (left + change, 0, 0, 0));
    assert_eq!(WALLET_CORE_PANICS.load(Ordering::SeqCst), panics_before);
    assert_eq!(engine.lane_deaths(), 0);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **An exit sweep the node may still hold keeps its coin out at a reopen.**
/// A sweep of one coin is built on the pin's receiver-pays arm, whose context
/// record the commit discharges at submit (the pin counts its fee twice
/// otherwise); the processor's record is handed back at the reopen. The
/// index still lists the coin, so the sweep may be in a mempool: the coin
/// stays off the spendable set until the sweep's acceptance takes it.
#[tokio::test(flavor = "multi_thread")]
async fn an_exit_sweep_the_node_may_still_hold_keeps_its_coin_out_at_a_reopen() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded_with(
        "sweep-held.kvlog",
        &fake,
        &ctl,
        vec![coin(&receive(), 0x61, 10 * SOMPI_PER_KAS)],
    )
    .await;
    let outcome = engine
        .prepare_sweep(
            payee(),
            receive(),
            Arc::new(Unsigned),
            fake.rpc(ctl.clone()),
        )
        .await
        .expect("a buildable sweep")
        .commit(None)
        .await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let txid = outcome.final_txid.clone().expect("the sweep's txid");
    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");

    // The index still lists the coin.
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    let reopened = balance_where(&mut events, "the balance after the reopen", |_, _, _, _| {
        true
    })
    .await;
    assert_eq!(
        reopened,
        (0, 0, 0, 0),
        "the swept coin came back while the sweep may be in a mempool"
    );
    let spendable = engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set");
    assert!(spendable.is_empty(), "{spendable:?}");

    // Accepted after the reopen: the coin leaves, and the pin's own record of
    // the sweep reaches the activity.
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![]),
            removed: Arc::new(vec![coin(&receive(), 0x61, 10 * SOMPI_PER_KAS)]),
        }))
        .await
            >= 1
    );
    tokio::time::timeout(WAIT, async {
        while engine.activity_daa_score(&txid).is_none() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the sweep's acceptance in the activity");
    assert_eq!(WALLET_CORE_PANICS.load(Ordering::SeqCst), panics_before);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A merge chain's accepted batch output, promoted after a reconnect, is no
/// lane death.** The pin never inserts a batch leg's outputs at its
/// acceptance (`context.rs:593-602`) and purges its accepted record only
/// through the processor's map, which a close clears. The rescan files the
/// output as pending, and its promotion meets the record unless the reopen
/// discharged it.
#[tokio::test(flavor = "multi_thread")]
async fn an_accepted_batch_output_promoted_after_a_reconnect_is_no_lane_death() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let coins: Vec<RpcUtxosByAddressesEntry> = (0..300u32)
        .map(|i| RpcUtxosByAddressesEntry {
            address: Some(receive()),
            outpoint: RpcTransactionOutpoint {
                transaction_id: Hash::from_bytes([0x71; 32]),
                index: i,
            },
            utxo_entry: RpcUtxoEntry::new(
                SOMPI_PER_KAS / 2,
                pay_to_address_script(&receive()),
                900_000,
                false,
                None,
            ),
        })
        .collect();
    let by_outpoint: std::collections::HashMap<u32, RpcUtxosByAddressesEntry> = coins
        .iter()
        .map(|c| (c.outpoint.index, c.clone()))
        .collect();
    let (engine, mut events, store) = funded_with("batch-orphan.kvlog", &fake, &ctl, coins).await;
    let prepared = engine
        .prepare_consolidate(receive(), &[], Arc::new(Unsigned), fake.rpc(ctl.clone()))
        .await
        .expect("a buildable merge");
    let legs = prepared.summary().tx_count as usize;
    assert!(legs >= 2, "the merge must be a chain, built {legs} leg(s)");

    // The batch legs are taken; the last leg's answer never comes.
    let mut answers = vec![SubmitAnswer::Accept; legs - 1];
    answers.push(SubmitAnswer::Fail("WebSocket disconnected".into()));
    fake.queue_submit_answers(answers);
    let outcome = prepared.commit(None).await;
    assert_eq!(outcome.submitted as usize, legs - 1);
    let sent = fake.submitted();
    let batches = &sent[..legs - 1];

    // The batch legs are accepted: their coins leave, their outputs arrive.
    let mut added = Vec::new();
    let mut removed = Vec::new();
    for batch in batches {
        let txid = txid_of(batch);
        for input in &batch.inputs {
            removed.push(by_outpoint[&input.previous_outpoint.index].clone());
        }
        for (index, output) in batch.outputs.iter().enumerate() {
            added.push(output_coin(
                &receive(),
                txid,
                index as u32,
                output.value,
                1_000_001,
            ));
        }
    }
    let outputs: u64 = added.iter().map(|c| c.utxo_entry.amount).sum();
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(added.clone()),
            removed: Arc::new(removed),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the balance at acceptance", |_, _, _, _| true).await;

    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");
    // The last leg never landed: the node holds the batch outputs, unspent.
    fake.set_utxos(added);
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    balance_where(&mut events, "the balance after the reopen", |_, p, _, _| {
        p == outputs
    })
    .await;

    past_maturity(&fake).await;
    let matured = balance_where(&mut events, "the outputs matured", |m, _, _, _| {
        m == outputs
    })
    .await;
    assert_eq!(matured, (outputs, 0, 0, 0));
    assert_eq!(
        WALLET_CORE_PANICS.load(Ordering::SeqCst),
        panics_before,
        "a panic in the pinned wallet framework"
    );
    assert_eq!(engine.lane_deaths(), 0);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A stop with a submit stuck in flight still returns inside its bound.**
/// The stop waits for the submit before stopping the processor (a stop under
/// a submit would clear the map it reads back), but only as long as a stop
/// may take: a submit that never returns leaves the processor running rather
/// than the stop waiting forever. Paused time.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_stop_with_a_submit_in_flight_returns_inside_its_bound() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, _events, store) = funded("stop-in-flight.kvlog", &fake, &ctl).await;
    let prepared = one_kas(&engine, &fake, &ctl).await;
    let hold = fake.hold_submits();
    let commit = tokio::spawn(prepared.commit(None));
    fake.wait_until("the submit at the node", WAIT, |f| f.submitted().len() == 1)
        .await;

    tokio::time::timeout(LANE_STEP_WITHIN * 2, engine.stop())
        .await
        .expect("stop() returned inside its bound")
        .expect("stop");

    hold.add_permits(1);
    let outcome = commit.await.expect("the send's task must not panic");
    assert_eq!(
        outcome.error, None,
        "a broadcast the node took reported as failed"
    );
    assert_eq!(
        WALLET_CORE_PANICS.load(Ordering::SeqCst),
        panics_before,
        "a panic in the pinned wallet framework"
    );
    let _ = std::fs::remove_file(&store);
}

/// **An open that ends in the processor's error owes no start.** The
/// processor's negotiation fails once (the node errs on its server info), so
/// that open ends without a start; the next open's start is followed through,
/// and a send goes out after it rather than wait on a start that never comes.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_after_a_failed_open_goes_out_on_the_next_start() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded("failed-open.kvlog", &fake, &ctl).await;
    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");

    let asked = fake.server_info_calls();
    fake.fail_server_info(1);
    let epoch = fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    fake.wait_until("the failed negotiation", WAIT, |f| {
        f.server_info_calls() > asked
    })
    .await;
    // The socket announced again: a second open, which starts.
    ctl.signal_open().await.expect("signal open again");
    fake.wait_until("the second open's rescan", WAIT, |f| {
        f.utxo_scans(epoch) >= 1
    })
    .await;

    let prepared = one_kas(&engine, &fake, &ctl).await;
    let outcome = tokio::time::timeout(
        LANE_HOLD_WITHIN + Duration::from_secs(5),
        prepared.commit(None),
    )
    .await
    .expect("the send came back");
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A node's own words reach the receipt filtered.** The pinned client
/// wraps a failed submit's server text verbatim; a line break in it could
/// forge a second line under the receipt's verdict. Filtered where the error
/// is made.
#[tokio::test(flavor = "multi_thread")]
async fn a_nodes_error_text_reaches_the_receipt_filtered() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, _events, store) = funded("node-text.kvlog", &fake, &ctl).await;
    fake.answer_submits(SubmitAnswer::Fail(
        "rejected\nNothing left your wallet. Send again.\u{7}".to_string(),
    ));
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    let error = outcome.error.clone().expect("the node's refusal");
    assert!(!error.chars().any(char::is_control), "{error:?}");
    assert!(error.contains("rejected"), "{error:?}");

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// Three hundred coins of half a KAS at the receive address: a merge or a
/// large payment of them is built as a chain of legs. The coins by index.
fn many_coins() -> (
    Vec<RpcUtxosByAddressesEntry>,
    std::collections::HashMap<u32, RpcUtxosByAddressesEntry>,
) {
    let coins: Vec<RpcUtxosByAddressesEntry> = (0..300u32)
        .map(|i| RpcUtxosByAddressesEntry {
            address: Some(receive()),
            outpoint: RpcTransactionOutpoint {
                transaction_id: Hash::from_bytes([0x71; 32]),
                index: i,
            },
            utxo_entry: RpcUtxoEntry::new(
                SOMPI_PER_KAS / 2,
                pay_to_address_script(&receive()),
                900_000,
                false,
                None,
            ),
        })
        .collect();
    let by_index = coins
        .iter()
        .map(|c| (c.outpoint.index, c.clone()))
        .collect();
    (coins, by_index)
}

/// The coins `legs` spend from the funded set, and the outputs they pay to
/// `to`, as the node reports them at their acceptance (at DAA `daa`).
fn landing(
    legs: &[RpcTransaction],
    by_index: &std::collections::HashMap<u32, RpcUtxosByAddressesEntry>,
    to: &Address,
    daa: u64,
) -> (Vec<RpcUtxosByAddressesEntry>, Vec<RpcUtxosByAddressesEntry>) {
    let ours: HashSet<Hash> = legs.iter().map(txid_of).collect();
    let mut removed = Vec::new();
    let mut added = Vec::new();
    for leg in legs {
        for input in &leg.inputs {
            if !ours.contains(&input.previous_outpoint.transaction_id) {
                removed.push(by_index[&input.previous_outpoint.index].clone());
            }
        }
    }
    // Outputs created and spent inside the same batch of legs cancel out at
    // the node (`consensus/core/src/utxo/utxo_diff.rs:246-266`).
    let spent: HashSet<(Hash, u32)> = legs
        .iter()
        .flat_map(|leg| leg.inputs.iter())
        .map(|input| {
            (
                input.previous_outpoint.transaction_id,
                input.previous_outpoint.index,
            )
        })
        .collect();
    for leg in legs {
        let txid = txid_of(leg);
        for (index, output) in leg.outputs.iter().enumerate() {
            let pays_us = extract_script_pub_key_address(
                &output.script_public_key,
                kaspa_addresses::Prefix::Mainnet,
            )
            .is_ok_and(|a| &a == to);
            if pays_us && !spent.contains(&(txid, index as u32)) {
                added.push(output_coin(to, txid, index as u32, output.value, daa));
            }
        }
    }
    (removed, added)
}

/// **A chain in flight across a reopen keeps every leg.** All legs of a merge
/// were taken and none is accepted at the reopen. A later leg's input is an
/// earlier leg's output, which the node's index cannot list until that leg is
/// accepted: that absence proves nothing, so no leg is discharged, the plate
/// reads as before the close, and the chain's acceptance after the reopen
/// settles it once.
#[tokio::test(flavor = "multi_thread")]
async fn a_chain_in_flight_across_a_reopen_keeps_every_leg() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, mut events, store) = funded_with("chain-held.kvlog", &fake, &ctl, coins).await;
    let prepared = engine
        .prepare_consolidate(receive(), &[], Arc::new(Unsigned), fake.rpc(ctl.clone()))
        .await
        .expect("a buildable merge");
    let legs = prepared.summary().tx_count as usize;
    assert!(legs >= 2, "the merge must be a chain, built {legs} leg(s)");
    let outcome = prepared.commit(None).await;
    assert_eq!(
        (outcome.submitted as usize, outcome.error.clone()),
        (legs, None)
    );
    let sent = fake.submitted();
    let (_, merged) = output_to(sent.last().expect("the last leg"), &receive());
    let in_flight =
        balance_where(&mut events, "the merge in flight", |_, _, _, u| u == merged).await;
    assert_eq!(in_flight, (0, 0, 0, merged));

    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");
    // Nothing accepted: the index still lists every funded coin.
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    let reopened = balance_where(&mut events, "the balance after the reopen", |_, _, _, _| {
        true
    })
    .await;
    assert_eq!(
        reopened,
        (0, 0, 0, merged),
        "(mature, pending, outgoing, unsettled) changed across the reopen"
    );
    let held: HashSet<Hash> = engine
        .context()
        .processor()
        .outgoing()
        .iter()
        .map(|entry| *entry.key())
        .collect();
    for leg in &sent {
        assert!(
            held.contains(&txid_of(leg)),
            "a leg in flight was discharged"
        );
    }

    // The chain is accepted after the reopen.
    let (removed, added) = landing(&sent, &by_index, &receive(), 1_000_001);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(added),
            removed: Arc::new(removed),
        }))
        .await
            >= 1
    );
    let settled = balance_where(&mut events, "the merge settled", |m, p, _, u| {
        u == 0 && m + p == merged
    })
    .await;
    assert_eq!(settled.0 + settled.1, merged);
    past_maturity(&fake).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(WALLET_CORE_PANICS.load(Ordering::SeqCst), panics_before);
    assert_eq!(engine.lane_deaths(), 0);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A chain whose earlier legs landed and whose last is in flight keeps
/// their outputs off the spendable set.** The index lists the earlier legs'
/// outputs, unspent while the last leg sits in a mempool; filing them would
/// count the merge twice and offer coins the last leg spends.
#[tokio::test(flavor = "multi_thread")]
async fn a_chain_whose_last_leg_is_in_flight_withholds_what_it_spends() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, mut events, store) = funded_with("chain-half.kvlog", &fake, &ctl, coins).await;
    let prepared = engine
        .prepare_consolidate(receive(), &[], Arc::new(Unsigned), fake.rpc(ctl.clone()))
        .await
        .expect("a buildable merge");
    let legs = prepared.summary().tx_count as usize;
    assert!(legs >= 2, "the merge must be a chain, built {legs} leg(s)");
    let outcome = prepared.commit(None).await;
    assert_eq!(outcome.submitted as usize, legs);
    let sent = fake.submitted();
    let (_, merged) = output_to(sent.last().expect("the last leg"), &receive());
    let batches = &sent[..legs - 1];

    // The earlier legs are accepted; the last is not.
    let (removed, added) = landing(batches, &by_index, &receive(), 1_000_001);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(added.clone()),
            removed: Arc::new(removed),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the earlier legs accepted", |_, _, _, _| true).await;

    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");
    fake.set_utxos(added.clone());
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    let reopened = balance_where(&mut events, "the balance after the reopen", |_, _, _, _| {
        true
    })
    .await;
    assert_eq!(
        reopened.0 + reopened.1 + reopened.2 + reopened.3,
        merged,
        "{reopened:?}: the merge counted other than once"
    );
    let spendable: HashSet<(Hash, u32)> = engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set")
        .iter()
        .map(|entry| {
            let id = entry.outpoint.inner();
            (id.transaction_id, id.index)
        })
        .collect();
    for coin in &added {
        assert!(
            !spendable.contains(&(coin.outpoint.transaction_id, coin.outpoint.index)),
            "an output the last leg spends was offered as spendable"
        );
    }

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A chained payment whose last leg got no answer, and which landed after
/// all, reads as sent.** The pin's cancel returned the last leg's inputs to
/// the mature list, the earlier leg's output among them, which the context's
/// map never held: left there it would stay after both legs land, spent, and
/// the balance would read as if nothing had left. Taken back at the cancel.
#[tokio::test(flavor = "multi_thread")]
async fn a_chained_payment_with_no_answer_that_lands_reads_as_sent() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let funded_total: u64 = coins.iter().map(|c| c.utxo_entry.amount).sum();
    let (engine, mut events, store) = funded_with("chain-noanswer.kvlog", &fake, &ctl, coins).await;
    let paid = 100 * SOMPI_PER_KAS;
    let prepared = engine
        .prepare_send(
            payee(),
            paid,
            receive(),
            Arc::new(Unsigned),
            fake.rpc(ctl.clone()),
            None,
            &[],
        )
        .await
        .expect("a buildable payment");
    let legs = prepared.summary().tx_count as usize;
    assert!(
        legs >= 2,
        "the payment must be a chain, built {legs} leg(s)"
    );
    let mut answers = vec![SubmitAnswer::Accept; legs - 1];
    answers.push(SubmitAnswer::Fail("WebSocket disconnected".into()));
    fake.queue_submit_answers(answers);
    let outcome = prepared.commit(None).await;
    assert_eq!(outcome.submitted as usize, legs - 1);
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let sent = fake.submitted();
    assert_eq!(sent.len(), legs, "the last leg reached the node");

    // Every leg lands, the last one included.
    let (removed, added) = landing(&sent, &by_index, &receive(), 900_001);
    let change: u64 = added.iter().map(|c| c.utxo_entry.amount).sum();
    let untouched = funded_total - removed.iter().map(|c| c.utxo_entry.amount).sum::<u64>();
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(added),
            removed: Arc::new(removed),
        }))
        .await
            >= 1
    );
    let landed = balance_where(&mut events, "the payment landed", |m, p, _, _| {
        m + p == untouched + change
    })
    .await;
    assert_eq!(landed.0 + landed.1, untouched + change);
    let spendable: u64 = engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set")
        .iter()
        .map(|entry| entry.amount)
        .sum();
    assert_eq!(
        spendable,
        untouched + change,
        "a spent coin is offered as spendable"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A reopen whose one read of the node fails files nothing and decides
/// nothing.** The send landed while the socket was down; the reopen's read
/// gets no answer inside its bound, so the send stays in flight and its
/// change is not filed (filed beside the record still held it would count
/// twice, and a pending change promoted beside that record is the pin's
/// `unreachable!`). The next read, a pull, settles it once. Paused time.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_reopen_whose_read_fails_files_nothing_until_the_next_read() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded("read-fails.kvlog", &fake, &ctl).await;
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let in_flight = balance_where(&mut events, "the send in flight", |_, _, o, _| o > 0).await;
    let sent = fake.submitted().pop().expect("the payment at the node");
    let txid = txid_of(&sent);
    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");

    // It landed while the socket was down, its change still young.
    let (index, change) = output_to(&sent, &receive());
    let (mut node, _) = split_by(&sent);
    let left = value_of(&node);
    node.push(output_coin(&receive(), txid, index, change, 1_000_001));
    fake.set_utxos(node);
    let reads = fake.hold_scans();
    let epoch = fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    fake.wait_until("the reopen's read", WAIT, |f| f.utxo_scans(epoch) >= 1)
        .await;
    tokio::time::sleep(LANE_HOLD_WITHIN + Duration::from_secs(1)).await;
    let spendable: u64 = engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set")
        .iter()
        .map(|entry| entry.amount)
        .sum();
    assert_eq!(
        spendable, left,
        "the unanswered reopen filed or freed a coin"
    );
    let _ = in_flight;

    reads.add_permits(1_000);
    engine.rescan().await.expect("the pull");
    let settled = balance_where(&mut events, "the send settled by the pull", |_, p, o, _| {
        o == 0 && p == change
    })
    .await;
    assert_eq!(settled, (left, change, 0, 0));
    past_maturity(&fake).await;
    let matured = balance_where(&mut events, "the change matured", |m, _, _, _| {
        m == left + change
    })
    .await;
    assert_eq!(matured, (left + change, 0, 0, 0));
    assert_eq!(WALLET_CORE_PANICS.load(Ordering::SeqCst), panics_before);
    assert_eq!(engine.lane_deaths(), 0);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A cancelled last leg's parent output is counted once.** The pin's
/// cancel pushes it onto the mature list while its leg, still in flight,
/// carries it as unsettled. Taken back at the cancel, it reads as unsettled
/// until its leg is accepted, then in no figure until the next read of the
/// node files it (low, never high). Filed as pending while its accepted leg's
/// record still stands, it matures with no lane death.
#[tokio::test(flavor = "multi_thread")]
async fn a_cancelled_last_legs_parent_output_counts_once() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, mut events, store) =
        funded_with("chain-cancelled.kvlog", &fake, &ctl, coins).await;
    let prepared = engine
        .prepare_consolidate(receive(), &[], Arc::new(Unsigned), fake.rpc(ctl.clone()))
        .await
        .expect("a buildable merge");
    let legs = prepared.summary().tx_count as usize;
    assert!(legs >= 2, "the merge must be a chain, built {legs} leg(s)");
    let mut answers = vec![SubmitAnswer::Accept; legs - 1];
    answers.push(SubmitAnswer::Fail("WebSocket disconnected".into()));
    fake.queue_submit_answers(answers);
    let outcome = prepared.commit(None).await;
    assert_eq!(outcome.submitted as usize, legs - 1);
    let sent = fake.submitted();
    let batches = &sent[..legs - 1];
    let parents: u64 = batches.iter().map(|leg| output_to(leg, &receive()).1).sum();

    engine.context().update_balance().await.expect("a balance");
    let after = balance_where(&mut events, "the balance after the cancel", |_, _, _, u| {
        u == parents
    })
    .await;
    assert_eq!(
        after,
        (0, 0, 0, parents),
        "(mature, pending, outgoing, unsettled): the parents' output counted twice"
    );

    // The earlier legs are accepted: their output is in no figure until the
    // next read files it, then counted once.
    let (removed, added) = landing(batches, &by_index, &receive(), 1_000_001);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(added.clone()),
            removed: Arc::new(removed),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the parents accepted", |_, _, _, u| u == 0).await;
    fake.set_utxos(added);
    engine.rescan().await.expect("the pull");
    let filed = balance_where(&mut events, "the parents' output filed", |m, p, _, _| {
        m + p == parents
    })
    .await;
    assert_eq!(filed.0 + filed.1 + filed.2 + filed.3, parents);
    past_maturity(&fake).await;
    let matured = balance_where(&mut events, "the parents' output matured", |m, _, _, _| {
        m == parents
    })
    .await;
    assert_eq!(matured, (parents, 0, 0, 0));
    assert_eq!(
        WALLET_CORE_PANICS.load(Ordering::SeqCst),
        panics_before,
        "a panic in the pinned wallet framework"
    );
    assert_eq!(engine.lane_deaths(), 0);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A read for some addresses judges no send by the coins it did not ask
/// about.** A prepare reads its change address alone. A send in flight whose
/// coins sit at another address reads absent there whatever became of them;
/// discharged on that, its coins would come back at the next read of the
/// whole window while it may still land.
#[tokio::test(flavor = "multi_thread")]
async fn a_narrow_read_leaves_a_send_it_did_not_ask_about_in_flight() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let coins = vec![
        coin(&change(), 0x51, 10 * SOMPI_PER_KAS),
        coin(&change(), 0x52, 10 * SOMPI_PER_KAS),
    ];
    let (engine, mut events, store) = funded_with("narrow-read.kvlog", &fake, &ctl, coins).await;
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let in_flight = balance_where(
        &mut events,
        "the balance with the send in flight",
        |_, _, o, _| o > 0,
    )
    .await;
    let txid: Hash = outcome.final_txid.expect("txid").parse().expect("a txid");
    let sent = fake.submitted().pop().expect("the payment at the node");
    let spent: HashSet<Hash> = sent
        .inputs
        .iter()
        .map(|input| input.previous_outpoint.transaction_id)
        .collect();

    // A second prepare, its change at the receive address: its read asks for
    // that address alone. The node still lists every coin the send spent (it
    // is in a mempool, which the index does not see), and the pull after it
    // reads the whole window.
    let _ = engine
        .prepare_send(
            payee(),
            SOMPI_PER_KAS,
            receive(),
            Arc::new(Unsigned),
            fake.rpc(ctl.clone()),
            None,
            &[],
        )
        .await;
    engine.rescan().await.expect("the pull");

    assert!(
        engine.context().processor().outgoing().contains_key(&txid),
        "a read that did not ask about the send's coins discharged it"
    );
    let spendable = engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set");
    assert!(
        spendable
            .iter()
            .all(|entry| !spent.contains(&entry.outpoint.inner().transaction_id)),
        "a coin came back while its send may be in a mempool"
    );
    let balance = engine.context().calculate_balance().await;
    assert_eq!(
        (balance.mature, balance.pending, balance.outgoing),
        (in_flight.0, in_flight.1, in_flight.2),
        "(mature, pending, outgoing) changed"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A read while a submit is out leaves that send to its submit.** The
/// submit holds the processor's lock on its read side only, as a read does,
/// and reads its record back when the request returns (`context.rs:265`).
/// Discharged under it, even by an answer that shows its coins gone, the
/// record's absence is a panic in the wallet framework after a broadcast the
/// node took. Only a send whose submit has returned is judged.
#[tokio::test(flavor = "multi_thread")]
async fn a_read_during_a_submit_leaves_that_send_to_its_submit() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, _events, store) = funded("read-under-submit.kvlog", &fake, &ctl).await;
    let prepared = one_kas(&engine, &fake, &ctl).await;
    let hold = fake.hold_submits();
    let commit = tokio::spawn(prepared.commit(None));
    fake.wait_until("the submit at the node", WAIT, |f| f.submitted().len() == 1)
        .await;
    let sent = fake.submitted().pop().expect("the payment at the node");

    // The node already lists the send's coins as spent, at the address the
    // read asks for: evidence enough for a send whose submit has returned.
    let (unspent, _) = split_by(&sent);
    fake.set_utxos(unspent);
    let _ = engine
        .prepare_send(
            payee(),
            SOMPI_PER_KAS,
            receive(),
            Arc::new(Unsigned),
            fake.rpc(ctl.clone()),
            None,
            &[],
        )
        .await;

    hold.add_permits(1);
    let outcome = commit.await.expect("the send's task must not panic");
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    assert_eq!(
        WALLET_CORE_PANICS.load(Ordering::SeqCst),
        panics_before,
        "a panic in the pinned wallet framework"
    );
    let txid: Hash = outcome.final_txid.expect("txid").parse().expect("a txid");
    assert!(engine.context().processor().outgoing().contains_key(&txid));

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A send accepted after the node answered keeps its coins out.** The
/// read's answer lists the coins the send spent; the acceptance is folded
/// before the read takes the lock, so the send is no longer in flight there,
/// but those coins are spent, and the answer must not file them back.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_accepted_after_the_answer_keeps_its_coins_out() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded("accepted-after-answer.kvlog", &fake, &ctl).await;
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    balance_where(
        &mut events,
        "the balance with the send in flight",
        |_, _, o, _| o > 0,
    )
    .await;
    let sent = fake.submitted().pop().expect("the payment at the node");
    let txid = txid_of(&sent);

    let hold = fake.hold_scans();
    let epoch = fake.begin_epoch();
    let pull = tokio::spawn({
        let engine = engine.clone();
        async move { engine.rescan().await }
    });
    fake.wait_until("the pull's read at the node", WAIT, |f| {
        f.utxo_scans(epoch) >= 1
    })
    .await;
    // Accepted now: the coins it spent leave, the change arrives.
    let (index, change) = output_to(&sent, &receive());
    let (unspent, spent) = split_by(&sent);
    let left = value_of(&unspent);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![output_coin(
                &receive(),
                txid,
                index,
                change,
                1_000_001
            )]),
            removed: Arc::new(spent),
        }))
        .await
            >= 1
    );
    balance_where(
        &mut events,
        "the balance at its acceptance",
        |_, _, o, _| o == 0,
    )
    .await;
    // The read answers as the index stood before, the spent coins listed.
    hold.add_permits(1);
    pull.await.expect("the pull's task").expect("the pull");

    let spendable: u64 = engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set")
        .iter()
        .map(|entry| entry.amount)
        .sum();
    assert_eq!(
        spendable,
        left + change,
        "a coin the accepted send spent was filed back as spendable"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A read files the coins it found without holding the processor's
/// handler.** Each transaction whose coins a read files new costs a call to
/// the node for its timestamp (the processor has no wallet bus). Held under
/// the notification lock, those calls would keep a `UtxosChanged` waiting,
/// and every submit queued behind it, for as long as the node takes: a large
/// wallet's first read would convict its own lane.
#[tokio::test(flavor = "multi_thread")]
async fn a_read_files_new_coins_without_holding_the_handler() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded("read-handler.kvlog", &fake, &ctl).await;
    // A deposit only the read sees.
    fake.set_utxos(vec![
        coin(&receive(), 0x51, 10 * SOMPI_PER_KAS),
        coin(&receive(), 0x52, 10 * SOMPI_PER_KAS),
        coin(&receive(), 0x61, 5 * SOMPI_PER_KAS),
    ]);
    let hold = fake.hold_timestamps();
    let calls = fake.timestamp_calls();
    let pull = tokio::spawn({
        let engine = engine.clone();
        async move { engine.rescan().await }
    });
    fake.wait_until("the read's timestamp call", WAIT, |f| {
        f.timestamp_calls() > calls
    })
    .await;

    // While that call waits on the node, a deposit arrives live.
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![coin(&receive(), 0x62, 3 * SOMPI_PER_KAS)]),
            removed: Arc::new(vec![]),
        }))
        .await
            >= 1
    );
    let folded = balance_where(&mut events, "the live deposit folded", |m, _, _, _| {
        m == 28 * SOMPI_PER_KAS
    })
    .await;
    assert_eq!(folded, (28 * SOMPI_PER_KAS, 0, 0, 0));

    hold.add_permits(64);
    pull.await.expect("the pull's task").expect("the pull");
    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A cancelled leg's parent output, filed by a reopen's read, is taken out
/// whole.** The chain's last leg waited out a reopen that settled the legs
/// before it and filed their output as pending; its register left that
/// pending coin alone (`context.rs:254`) and its cancel pushed a mature copy
/// beside it (`:280-291`). Removing what the map holds drops only the pending
/// copy. Spent if the leg lands after all, no copy may read as spendable.
#[tokio::test(flavor = "multi_thread")]
async fn a_cancelled_legs_parent_filed_by_a_reopen_is_taken_out() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, mut events, store) =
        funded_with("chain-reopened.kvlog", &fake, &ctl, coins.clone()).await;
    let prepared = engine
        .prepare_consolidate(receive(), &[], Arc::new(Unsigned), fake.rpc(ctl.clone()))
        .await
        .expect("a buildable merge");
    let legs = prepared.summary().tx_count as usize;
    assert!(legs >= 2, "the merge must be a chain, built {legs} leg(s)");
    let mut answers = vec![SubmitAnswer::Accept; legs - 1];
    answers.push(SubmitAnswer::Fail("WebSocket disconnected".into()));
    fake.queue_submit_answers(answers);
    let hold = fake.hold_submits();
    let commit = tokio::spawn(prepared.commit(None));
    for leg in 1..legs - 1 {
        fake.wait_until("a leg at the node", WAIT, |f| f.submitted().len() == leg)
            .await;
        hold.add_permits(1);
    }
    fake.wait_until("the last leg's parent at the node", WAIT, |f| {
        f.submitted().len() == legs - 1
    })
    .await;
    // A close behind that leg's submit: it lands once the submit returns, and
    // the last leg waits for the reopen.
    ctl.signal_close().await.expect("signal close");
    hold.add_permits(1);
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");

    // The legs before the last were accepted meanwhile: the node no longer
    // lists their coins, and lists their output, still pending at the reopen.
    let earlier = fake.submitted();
    let (removed, added) = landing(&earlier, &by_index, &receive(), 1_000_001);
    let gone: HashSet<u32> = removed.iter().map(|c| c.outpoint.index).collect();
    let mut node: Vec<RpcUtxosByAddressesEntry> = coins
        .into_iter()
        .filter(|c| !gone.contains(&c.outpoint.index))
        .collect();
    node.extend(added.iter().cloned());
    fake.set_utxos(node);
    fake.begin_epoch();
    hold.add_permits(64);
    ctl.signal_open().await.expect("signal reopen");
    let outcome = commit.await.expect("the send's task must not panic");
    assert_eq!(outcome.submitted as usize, legs - 1);
    assert!(outcome.error.is_some(), "{outcome:?}");

    let parents: HashSet<(Hash, u32)> = added
        .iter()
        .map(|c| (c.outpoint.transaction_id, c.outpoint.index))
        .collect();
    assert!(
        !parents.is_empty(),
        "the last leg spends an earlier leg's output"
    );
    let spendable = engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set");
    assert!(
        spendable.iter().all(|entry| {
            let id = entry.outpoint.inner();
            !parents.contains(&(id.transaction_id, id.index))
        }),
        "a copy of the cancelled leg's parent output reads as spendable"
    );
    assert_eq!(WALLET_CORE_PANICS.load(Ordering::SeqCst), panics_before);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A read before the reopen has handed back the sends files nothing they
/// create.** The processor reads connected before its start reaches the fold,
/// and the close cleared its record of the sends in flight; a prepare in that
/// window reads with none. A chain whose earlier legs were accepted while the
/// socket was down: the node lists their output, which the last leg, still in
/// flight, spends. Our own record of the legs, which survives the close,
/// keeps it out.
#[tokio::test(flavor = "multi_thread")]
async fn a_read_before_the_reopen_hands_back_the_sends_files_nothing_they_create() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, mut events, store) =
        funded_with("reopen-window.kvlog", &fake, &ctl, coins.clone()).await;
    let prepared = engine
        .prepare_consolidate(receive(), &[], Arc::new(Unsigned), fake.rpc(ctl.clone()))
        .await
        .expect("a buildable merge");
    let legs = prepared.summary().tx_count as usize;
    assert!(legs >= 2, "the merge must be a chain, built {legs} leg(s)");
    let outcome = prepared.commit(None).await;
    assert_eq!(outcome.submitted as usize, legs);
    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");

    // The legs before the last were accepted while the socket was down.
    let sent = fake.submitted();
    // Mature at the node's DAA score, so a copy filed by mistake would be
    // spendable at once.
    let (removed, added) = landing(&sent[..legs - 1], &by_index, &receive(), 999_000);
    let gone: HashSet<u32> = removed.iter().map(|c| c.outpoint.index).collect();
    let mut node: Vec<RpcUtxosByAddressesEntry> = coins
        .into_iter()
        .filter(|c| !gone.contains(&c.outpoint.index))
        .collect();
    node.extend(added.iter().cloned());
    fake.set_utxos(node);
    let parents: HashSet<(Hash, u32)> = added
        .iter()
        .map(|c| (c.outpoint.transaction_id, c.outpoint.index))
        .collect();
    assert!(
        !parents.is_empty(),
        "the last leg spends an earlier leg's output"
    );

    // The processor connects and is held before its start reaches the fold.
    let subscribe = fake.hold_daa_subscribe();
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    tokio::time::timeout(WAIT, async {
        while !engine.context().processor().is_connected() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("the processor reads connected");
    let _ = engine
        .prepare_send(
            payee(),
            SOMPI_PER_KAS,
            receive(),
            Arc::new(Unsigned),
            fake.rpc(ctl.clone()),
            None,
            &[],
        )
        .await;
    let spendable = engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set");
    assert!(
        spendable.iter().all(|entry| {
            let id = entry.outpoint.inner();
            !parents.contains(&(id.transaction_id, id.index))
        }),
        "an output the last leg spends was filed while that leg may land"
    );

    subscribe.add_permits(64);
    balance_where(&mut events, "the balance after the reopen", |_, _, _, _| {
        true
    })
    .await;
    assert_eq!(WALLET_CORE_PANICS.load(Ordering::SeqCst), panics_before);
    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// A merge of [`many_coins`] committed with every leg taken and none yet
/// accepted: the legs as the node received them.
async fn merge_in_flight(
    engine: &WalletEngine,
    fake: &Arc<FakeRpc>,
    ctl: &RpcCtl,
) -> Vec<RpcTransaction> {
    let prepared = engine
        .prepare_consolidate(receive(), &[], Arc::new(Unsigned), fake.rpc(ctl.clone()))
        .await
        .expect("a buildable merge");
    let legs = prepared.summary().tx_count as usize;
    assert!(legs >= 2, "the merge must be a chain, built {legs} leg(s)");
    let outcome = prepared.commit(None).await;
    assert_eq!(outcome.submitted as usize, legs, "{outcome:?}");
    fake.submitted()
}

/// Wait until the processor has tagged every one of `legs` accepted.
async fn until_tagged(engine: &WalletEngine, legs: &[RpcTransaction]) {
    let txids: Vec<Hash> = legs.iter().map(txid_of).collect();
    tokio::time::timeout(WAIT, async {
        loop {
            let outgoing = engine.context().processor().outgoing().clone();
            if txids.iter().all(|txid| {
                outgoing
                    .get(txid)
                    .is_some_and(|record| record.is_accepted())
            }) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("the legs' acceptance folded");
}

/// The node's coins once `legs` are accepted: the funded set less what they
/// spent, plus their outputs (at DAA `daa`).
fn after_landing(
    coins: &[RpcUtxosByAddressesEntry],
    legs: &[RpcTransaction],
    by_index: &std::collections::HashMap<u32, RpcUtxosByAddressesEntry>,
    daa: u64,
) -> (
    Vec<RpcUtxosByAddressesEntry>,
    Vec<RpcUtxosByAddressesEntry>,
    Vec<RpcUtxosByAddressesEntry>,
) {
    let (removed, added) = landing(legs, by_index, &receive(), daa);
    let gone: HashSet<u32> = removed.iter().map(|c| c.outpoint.index).collect();
    let mut node: Vec<RpcUtxosByAddressesEntry> = coins
        .iter()
        .filter(|c| !gone.contains(&c.outpoint.index))
        .cloned()
        .collect();
    node.extend(added.iter().cloned());
    (node, removed, added)
}

/// Whether any of `coins` is on the spendable list or pending.
async fn any_filed(engine: &WalletEngine, coins: &[RpcUtxosByAddressesEntry]) -> bool {
    let ids: HashSet<(Hash, u32)> = coins
        .iter()
        .map(|c| (c.outpoint.transaction_id, c.outpoint.index))
        .collect();
    let mature = engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set")
        .iter()
        .any(|entry| {
            let id = entry.outpoint.inner();
            ids.contains(&(id.transaction_id, id.index))
        });
    mature || engine.context().pending_utxo_size() > 0
}

/// **A parent accepted between the node's answer and the lock proves nothing
/// about its child.** The read is served before the chain's earlier legs are
/// accepted, and their acceptance is folded before the read takes the lock:
/// the answer lacks their output, and the last leg, which spends it, may
/// still land. It stays in flight, and a later read that lists the output
/// files no copy of it.
#[tokio::test(flavor = "multi_thread")]
async fn a_parent_accepted_between_the_answer_and_the_lock_proves_nothing() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, _events, store) =
        funded_with("answer-then-fold.kvlog", &fake, &ctl, coins.clone()).await;
    let sent = merge_in_flight(&engine, &fake, &ctl).await;
    let legs = sent.len();
    let last = txid_of(&sent[legs - 1]);
    let (node, removed, added) = after_landing(&coins, &sent[..legs - 1], &by_index, 999_000);

    let hold = fake.hold_scans();
    let epoch = fake.begin_epoch();
    let pull = tokio::spawn({
        let engine = engine.clone();
        async move { engine.rescan().await }
    });
    fake.wait_until("the pull's read at the node", WAIT, |f| {
        f.utxo_scans(epoch) >= 1
    })
    .await;
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(added.clone()),
            removed: Arc::new(removed),
        }))
        .await
            >= 1
    );
    until_tagged(&engine, &sent[..legs - 1]).await;
    // The read answers as the index stood before: the funded coins only.
    hold.add_permits(1);
    pull.await.expect("the pull's task").expect("the pull");
    assert!(
        engine
            .context()
            .processor()
            .outgoing()
            .get(&last)
            .is_some_and(|record| !record.is_accepted()),
        "the last leg was settled on an answer older than its parent's acceptance"
    );

    // The index now lists the parents' output, which the last leg spends.
    fake.set_utxos(node);
    hold.add_permits(64);
    engine.rescan().await.expect("the second pull");
    assert!(
        !any_filed(&engine, &added).await,
        "a coin the last leg spends was filed while it may land"
    );
    assert_eq!(WALLET_CORE_PANICS.load(Ordering::SeqCst), panics_before);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A send settled before its acceptance reaches the processor keeps its
/// record for it.** The node answers after the chain's earlier legs were
/// accepted, so the read settles them, and their `UtxosChanged` arrives after.
/// It must still find their records: without them the pin files the batch
/// output as a deposit (`context.rs:588-596`), spendable at its maturity while
/// the last leg, which spends it, may still land.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_settled_before_its_frame_keeps_its_record_for_it() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, _events, store) =
        funded_with("settled-before-frame.kvlog", &fake, &ctl, coins.clone()).await;
    let sent = merge_in_flight(&engine, &fake, &ctl).await;
    let legs = sent.len();
    let (node, removed, added) = after_landing(&coins, &sent[..legs - 1], &by_index, 1_000_001);

    // The index already shows the earlier legs accepted; the pull settles them.
    fake.set_utxos(node);
    engine.rescan().await.expect("the pull");
    // Their acceptance reaches the processor after.
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(added.clone()),
            removed: Arc::new(removed),
        }))
        .await
            >= 1
    );
    past_maturity(&fake).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(
        !any_filed(&engine, &added).await,
        "the batch output was filed as a deposit while the last leg may land"
    );
    assert_eq!(WALLET_CORE_PANICS.load(Ordering::SeqCst), panics_before);
    assert_eq!(engine.lane_deaths(), 0);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A read before the reopen withholds an accepted parent's output its last
/// leg spends.** The chain's earlier legs were accepted before the close, the
/// last was not. In the window before the reopen hands the sends back the
/// processor names none of them, and the node lists the parents' output,
/// which the pin never inserts; our own record of the last leg's submit keeps
/// what it spends out.
#[tokio::test(flavor = "multi_thread")]
async fn a_read_before_the_reopen_withholds_an_accepted_parents_output() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, mut events, store) =
        funded_with("window-accepted-parent.kvlog", &fake, &ctl, coins.clone()).await;
    let sent = merge_in_flight(&engine, &fake, &ctl).await;
    let legs = sent.len();
    let (node, removed, added) = after_landing(&coins, &sent[..legs - 1], &by_index, 999_000);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(added.clone()),
            removed: Arc::new(removed),
        }))
        .await
            >= 1
    );
    until_tagged(&engine, &sent[..legs - 1]).await;
    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");

    fake.set_utxos(node);
    let subscribe = fake.hold_daa_subscribe();
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    tokio::time::timeout(WAIT, async {
        while !engine.context().processor().is_connected() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("the processor reads connected");
    let _ = engine
        .prepare_send(
            payee(),
            SOMPI_PER_KAS,
            receive(),
            Arc::new(Unsigned),
            fake.rpc(ctl.clone()),
            None,
            &[],
        )
        .await;
    assert!(
        !any_filed(&engine, &added).await,
        "an output the last leg spends was filed while that leg may land"
    );

    subscribe.add_permits(64);
    balance_where(&mut events, "the balance after the reopen", |_, _, _, _| {
        true
    })
    .await;
    assert_eq!(WALLET_CORE_PANICS.load(Ordering::SeqCst), panics_before);
    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A kept leg's parent output, filed by a reopen's read, counts once.** The
/// chain's last leg waited out a reopen that settled the legs before it and
/// filed their output as pending; its register clears only the mature list
/// (`context.rs:254`), so that pending copy would count beside the leg's own
/// record and turn spendable at its maturity while the leg may land.
#[tokio::test(flavor = "multi_thread")]
async fn a_kept_legs_parent_filed_by_a_reopen_counts_once() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, mut events, store) =
        funded_with("kept-leg-reopened.kvlog", &fake, &ctl, coins.clone()).await;
    let prepared = engine
        .prepare_consolidate(receive(), &[], Arc::new(Unsigned), fake.rpc(ctl.clone()))
        .await
        .expect("a buildable merge");
    let legs = prepared.summary().tx_count as usize;
    assert!(legs >= 2, "the merge must be a chain, built {legs} leg(s)");
    let hold = fake.hold_submits();
    let commit = tokio::spawn(prepared.commit(None));
    for leg in 1..legs - 1 {
        fake.wait_until("a leg at the node", WAIT, |f| f.submitted().len() == leg)
            .await;
        hold.add_permits(1);
    }
    fake.wait_until("the last leg's parent at the node", WAIT, |f| {
        f.submitted().len() == legs - 1
    })
    .await;
    ctl.signal_close().await.expect("signal close");
    hold.add_permits(1);
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");

    let earlier = fake.submitted();
    let (node, _, added) = after_landing(&coins, &earlier, &by_index, 1_000_001);
    fake.set_utxos(node);
    fake.begin_epoch();
    hold.add_permits(64);
    ctl.signal_open().await.expect("signal reopen");
    let outcome = commit.await.expect("the send's task must not panic");
    assert_eq!(outcome.submitted as usize, legs, "{outcome:?}");

    assert!(
        !any_filed(&engine, &added).await,
        "the parents' output counts beside the last leg that spends it"
    );
    past_maturity(&fake).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(
        !any_filed(&engine, &added).await,
        "the parents' output turned spendable while the last leg may land"
    );
    assert_eq!(WALLET_CORE_PANICS.load(Ordering::SeqCst), panics_before);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A send accepted and purged while a read is out keeps its coins out.** The
/// read is served before the send is accepted; its acceptance is folded, and
/// the processor purges its record a hundred DAA later, all before the read
/// takes the lock. The answer still lists the coins it spent.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_purged_inside_the_read_keeps_its_coins_out() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded("purged-inside-read.kvlog", &fake, &ctl).await;
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    balance_where(
        &mut events,
        "the balance with the send in flight",
        |_, _, o, _| o > 0,
    )
    .await;
    let sent = fake.submitted().pop().expect("the payment at the node");
    let txid = txid_of(&sent);

    let hold = fake.hold_scans();
    let epoch = fake.begin_epoch();
    let pull = tokio::spawn({
        let engine = engine.clone();
        async move { engine.rescan().await }
    });
    fake.wait_until("the pull's read at the node", WAIT, |f| {
        f.utxo_scans(epoch) >= 1
    })
    .await;
    let (index, change) = output_to(&sent, &receive());
    let (unspent, spent) = split_by(&sent);
    let left = value_of(&unspent);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![output_coin(
                &receive(),
                txid,
                index,
                change,
                1_000_001
            )]),
            removed: Arc::new(spent),
        }))
        .await
            >= 1
    );
    balance_where(
        &mut events,
        "the balance at its acceptance",
        |_, _, o, _| o == 0,
    )
    .await;
    past_maturity(&fake).await;
    tokio::time::timeout(WAIT, async {
        while engine.context().processor().outgoing().get(&txid).is_some() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("the processor purged the accepted send");
    hold.add_permits(1);
    pull.await.expect("the pull's task").expect("the pull");

    let spendable: u64 = engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set")
        .iter()
        .map(|entry| entry.amount)
        .sum();
    assert_eq!(
        spendable,
        left + change,
        "a coin the purged send spent was filed back as spendable"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A read while a submit is out leaves that send to its submit, whatever
/// the submit then answers.** A conflict has already spent the send's coins at
/// the node, so the read sees them gone and the node then refuses the send.
/// Judged under the submit, its context record would be gone when the pin's
/// cancel reads it back (`context.rs:285`), a panic in the wallet framework.
#[tokio::test(flavor = "multi_thread")]
async fn a_read_during_a_refused_submit_leaves_that_send_to_its_submit() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, _events, store) = funded("read-under-refused-submit.kvlog", &fake, &ctl).await;
    let prepared = one_kas(&engine, &fake, &ctl).await;
    fake.answer_submits(SubmitAnswer::Fail(
        "RPC Server (remote error) -> transaction already spent by a transaction in the mempool"
            .to_string(),
    ));
    let hold = fake.hold_submits();
    let commit = tokio::spawn(prepared.commit(None));
    fake.wait_until("the submit at the node", WAIT, |f| f.submitted().len() == 1)
        .await;
    let sent = fake.submitted().pop().expect("the payment at the node");

    // Another spend of the same coins was accepted: the node no longer lists
    // them, at the address the read asks for.
    let (unspent, _) = split_by(&sent);
    fake.set_utxos(unspent);
    let _ = engine
        .prepare_send(
            payee(),
            SOMPI_PER_KAS,
            receive(),
            Arc::new(Unsigned),
            fake.rpc(ctl.clone()),
            None,
            &[],
        )
        .await;

    hold.add_permits(1);
    let outcome = commit.await.expect("the send's task must not panic");
    assert_eq!(outcome.submitted, 0, "{outcome:?}");
    assert!(outcome.error.is_some(), "{outcome:?}");
    assert_eq!(
        WALLET_CORE_PANICS.load(Ordering::SeqCst),
        panics_before,
        "a panic in the pinned wallet framework"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A send submitted and accepted while a read is out keeps its coins out.**
/// It is neither in the processor nor in our record when the read takes its
/// snapshot, and its acceptance is folded before the read takes the lock: the
/// answer, served before, still lists the coins it spent, and only its record
/// at the lock, accepted, names them.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_submitted_and_accepted_inside_a_read_keeps_its_coins_out() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded("submitted-inside-read.kvlog", &fake, &ctl).await;
    let prepared = one_kas(&engine, &fake, &ctl).await;

    let hold = fake.hold_scans();
    let epoch = fake.begin_epoch();
    let pull = tokio::spawn({
        let engine = engine.clone();
        async move { engine.rescan().await }
    });
    fake.wait_until("the pull's read at the node", WAIT, |f| {
        f.utxo_scans(epoch) >= 1
    })
    .await;
    let outcome = prepared.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let sent = fake.submitted().pop().expect("the payment at the node");
    let txid = txid_of(&sent);
    let (index, change) = output_to(&sent, &receive());
    let (unspent, spent) = split_by(&sent);
    let left = value_of(&unspent);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![output_coin(
                &receive(),
                txid,
                index,
                change,
                1_000_001
            )]),
            removed: Arc::new(spent),
        }))
        .await
            >= 1
    );
    // The acceptance's own balance: an earlier one (the prepare's read) also
    // shows nothing outgoing.
    balance_where(
        &mut events,
        "the balance at its acceptance",
        |m, _, o, _| o == 0 && m == left + change,
    )
    .await;
    // The read answers as the index stood before the send: its coins listed.
    hold.add_permits(1);
    pull.await.expect("the pull's task").expect("the pull");

    let spendable: u64 = engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set")
        .iter()
        .map(|entry| entry.amount)
        .sum();
    assert_eq!(
        spendable,
        left + change,
        "a coin the accepted send spent was filed back as spendable"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A send in its submit when a read begins, accepted and purged before the
/// read decides, keeps its coins out.** Only the processor named it then: our
/// record of the returned submits did not yet, and by the lock the processor
/// has purged it. The answer, served before its acceptance, lists the coins it
/// spent.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_in_its_submit_when_a_read_begins_keeps_its_coins_out() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded("submit-at-snapshot.kvlog", &fake, &ctl).await;
    let prepared = one_kas(&engine, &fake, &ctl).await;
    let submit = fake.hold_submits();
    let commit = tokio::spawn(prepared.commit(None));
    fake.wait_until("the submit at the node", WAIT, |f| f.submitted().len() == 1)
        .await;

    let scan = fake.hold_scans();
    let epoch = fake.begin_epoch();
    let pull = tokio::spawn({
        let engine = engine.clone();
        async move { engine.rescan().await }
    });
    fake.wait_until("the pull's read at the node", WAIT, |f| {
        f.utxo_scans(epoch) >= 1
    })
    .await;
    submit.add_permits(1);
    let outcome = commit.await.expect("the send's task must not panic");
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let sent = fake.submitted().pop().expect("the payment at the node");
    let txid = txid_of(&sent);
    let (index, change) = output_to(&sent, &receive());
    let (unspent, spent) = split_by(&sent);
    let left = value_of(&unspent);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![output_coin(
                &receive(),
                txid,
                index,
                change,
                1_000_001
            )]),
            removed: Arc::new(spent),
        }))
        .await
            >= 1
    );
    // The acceptance's own balance: an earlier one (the prepare's read) also
    // shows nothing outgoing.
    balance_where(
        &mut events,
        "the balance at its acceptance",
        |m, _, o, _| o == 0 && m == left + change,
    )
    .await;
    past_maturity(&fake).await;
    tokio::time::timeout(WAIT, async {
        while engine.context().processor().outgoing().get(&txid).is_some() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("the processor purged the accepted send");
    scan.add_permits(1);
    pull.await.expect("the pull's task").expect("the pull");

    let spendable: u64 = engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set")
        .iter()
        .map(|entry| entry.amount)
        .sum();
    assert_eq!(
        spendable,
        left + change,
        "a coin the purged send spent was filed back as spendable"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// A merge whose legs before the last were taken and accepted (their output
/// pending at the node, DAA 1_000_001) and whose last leg the node refused.
/// The earlier legs' output is spent by no send that may still land. Returns
/// once the fold has folded their acceptance (the unsettled figure their
/// output held falls to zero only then), not merely once the processor tagged
/// them.
async fn merge_with_its_last_leg_refused(
    engine: &WalletEngine,
    events: &mut tokio::sync::broadcast::Receiver<WalletEvent>,
    fake: &Arc<FakeRpc>,
    ctl: &RpcCtl,
    coins: &[RpcUtxosByAddressesEntry],
    by_index: &std::collections::HashMap<u32, RpcUtxosByAddressesEntry>,
) -> Vec<RpcUtxosByAddressesEntry> {
    let prepared = engine
        .prepare_consolidate(receive(), &[], Arc::new(Unsigned), fake.rpc(ctl.clone()))
        .await
        .expect("a buildable merge");
    let legs = prepared.summary().tx_count as usize;
    assert!(legs >= 2, "the merge must be a chain, built {legs} leg(s)");
    let mut answers = vec![SubmitAnswer::Accept; legs - 1];
    answers.push(SubmitAnswer::Fail(
        "RPC Server (remote error) -> the transaction was rejected".to_string(),
    ));
    fake.queue_submit_answers(answers);
    let outcome = prepared.commit(None).await;
    assert_eq!(outcome.submitted as usize, legs - 1, "{outcome:?}");
    balance_where(events, "the earlier legs in flight", |_, _, _, u| u > 0).await;
    let sent = fake.submitted();
    let earlier = &sent[..legs - 1];
    let (node, removed, added) = after_landing(coins, earlier, by_index, 1_000_001);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(added),
            removed: Arc::new(removed),
        }))
        .await
            >= 1
    );
    until_tagged(engine, earlier).await;
    balance_where(
        events,
        "the earlier legs' acceptance folded",
        |_, _, _, u| u == 0,
    )
    .await;
    node
}

/// **A close inside a read leaves no landed send's record for a promotion.**
/// The close clears the processor's records (`cleanup()`,
/// `processor.rs:609-615`) between the read's snapshot and its lock. The read
/// files the earlier legs' output as pending, and ticks run before the reopen
/// hands the sends back (`processor.rs:540-541`): a context record left for an
/// earlier leg would meet the pin's `unreachable!` at the output's promotion
/// (`context.rs:408-411`), a lane death.
#[tokio::test(flavor = "multi_thread")]
async fn a_close_inside_a_read_leaves_no_landed_send_for_a_promotion() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, mut events, store) =
        funded_with("close-inside-read.kvlog", &fake, &ctl, coins.clone()).await;
    let node =
        merge_with_its_last_leg_refused(&engine, &mut events, &fake, &ctl, &coins, &by_index).await;

    fake.set_utxos(node);
    let hold = fake.hold_scans();
    let epoch = fake.begin_epoch();
    let pull = tokio::spawn({
        let engine = engine.clone();
        async move { engine.rescan().await }
    });
    fake.wait_until("the pull's read at the node", WAIT, |f| {
        f.utxo_scans(epoch) >= 1
    })
    .await;
    engine
        .context()
        .processor()
        .cleanup()
        .await
        .expect("the processor's records cleared");
    hold.add_permits(64);
    pull.await.expect("the pull's task").expect("the pull");

    assert!(
        engine.context().pending_utxo_size() > 0,
        "the earlier legs' output was not filed as pending: nothing to promote"
    );
    past_maturity(&fake).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(
        WALLET_CORE_PANICS.load(Ordering::SeqCst),
        panics_before,
        "a panic in the pinned wallet framework"
    );
    assert_eq!(engine.lane_deaths(), 0);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}

/// **A read after a close, before the reopen, leaves no accepted send's record
/// for a promotion.** The processor names none of our sends then, so only our
/// own record of the acceptances the fold saw can discharge the context's.
#[tokio::test(flavor = "multi_thread")]
async fn a_read_after_a_close_leaves_no_accepted_send_for_a_promotion() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, mut events, store) =
        funded_with("read-after-close.kvlog", &fake, &ctl, coins.clone()).await;
    let node =
        merge_with_its_last_leg_refused(&engine, &mut events, &fake, &ctl, &coins, &by_index).await;

    fake.set_utxos(node);
    engine
        .context()
        .processor()
        .cleanup()
        .await
        .expect("the processor's records cleared");
    engine.rescan().await.expect("the pull");

    assert!(
        engine.context().pending_utxo_size() > 0,
        "the earlier legs' output was not filed as pending: nothing to promote"
    );
    past_maturity(&fake).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(
        WALLET_CORE_PANICS.load(Ordering::SeqCst),
        panics_before,
        "a panic in the pinned wallet framework"
    );
    assert_eq!(engine.lane_deaths(), 0);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    let _ = std::fs::remove_file(&store);
}
