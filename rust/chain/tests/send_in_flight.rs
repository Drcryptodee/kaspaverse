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
    Address, ChainError, Hash, PreparedSend, WalletEngine, WalletEvent, LANE_HOLD_WITHIN,
    LANE_STEP_WITHIN,
};
use support::{remove_store, FakeRpc, SubmitAnswer};

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

/// A second payee outside the wallet.
fn payee_two() -> Address {
    Address::new(
        kaspa_addresses::Prefix::Mainnet,
        kaspa_addresses::Version::PubKey,
        &[0x42; 32],
    )
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
    remove_store(&store);
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

/// `sompi` to `to`, change home to the receive address.
async fn kas_to(
    engine: &WalletEngine,
    fake: &Arc<FakeRpc>,
    ctl: &RpcCtl,
    to: Address,
    sompi: u64,
) -> PreparedSend {
    engine
        .prepare_send(
            to,
            sompi,
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
    remove_store(&store);
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
    remove_store(&store);
}

/// The outpoints a transaction spends.
fn spends(transaction: &RpcTransaction) -> HashSet<(Hash, u32)> {
    transaction
        .inputs
        .iter()
        .map(|input| {
            (
                input.previous_outpoint.transaction_id,
                input.previous_outpoint.index,
            )
        })
        .collect()
}

/// **A retry after a send that got no answer conflicts with it.** The first
/// may still land: the pin's cancel put its coin back on the spendable list,
/// and the coins that arrived since are what the policy draws (two small ones
/// ride first, then the largest), so a retry of the same payment built from
/// them lands beside the first. While the first's fate is unknown, a build
/// that pays the same destination spends its coin, so at most one of the two
/// can land.
#[tokio::test(flavor = "multi_thread")]
async fn a_retry_after_a_send_with_no_answer_conflicts_with_it() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let held = coin(&receive(), 0x51, 10 * SOMPI_PER_KAS);
    let (engine, mut events, store) =
        funded_with("retry-conflicts.kvlog", &fake, &ctl, vec![held.clone()]).await;
    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let first = fake.submitted().pop().expect("the first at the node");

    // Coins arrive: one larger than the first's, two smaller.
    let arrived = vec![
        coin(&receive(), 0x63, 50 * SOMPI_PER_KAS),
        coin(&receive(), 0x64, 3 * SOMPI_PER_KAS / 10),
        coin(&receive(), 0x65, 4 * SOMPI_PER_KAS / 10),
    ];
    let mut node = vec![held];
    node.extend(arrived.iter().cloned());
    fake.set_utxos(node);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(arrived),
            removed: Arc::new(vec![]),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the deposits folded", |m, _, _, _| {
        m == 607 * SOMPI_PER_KAS / 10
    })
    .await;

    fake.answer_submits(SubmitAnswer::Accept);
    let retry = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((retry.submitted, retry.error.clone()), (1, None));
    let second = fake.submitted().pop().expect("the retry at the node");
    assert!(
        !spends(&first).is_disjoint(&spends(&second)),
        "the retry spends none of the first's coins: both can land"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A retry the node takes is no news of the first, even when it is the
/// same transaction.** Built from the same one coin with the same fee and
/// change, the retry has the first's txid (a txid leaves out signatures), so
/// its own record names that txid; it proves nothing about the first submit,
/// and the next payment to the address builds.
#[tokio::test(flavor = "multi_thread")]
async fn an_identical_retry_the_node_takes_is_no_news_of_the_first() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let held = coin(&receive(), 0x51, 10 * SOMPI_PER_KAS);
    let (engine, mut events, store) =
        funded_with("identical-retry.kvlog", &fake, &ctl, vec![held.clone()]).await;
    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let first = fake.submitted().pop().expect("the first at the node");

    fake.answer_submits(SubmitAnswer::Accept);
    let retry = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((retry.submitted, retry.error.clone()), (1, None));
    let second = fake.submitted().pop().expect("the retry at the node");
    assert_eq!(
        txid_of(&first),
        txid_of(&second),
        "the retry is the same transaction"
    );
    balance_where(&mut events, "the retry in flight", |_, _, o, _| {
        o == SOMPI_PER_KAS
    })
    .await;
    let deposit = coin(&receive(), 0x66, 5 * SOMPI_PER_KAS);
    fake.set_utxos(vec![held, deposit.clone()]);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![deposit]),
            removed: Arc::new(vec![]),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the deposit folded", |m, _, _, _| {
        m >= 5 * SOMPI_PER_KAS
    })
    .await;
    let refusal = one_kas_refusal(&engine, &fake, &ctl).await;
    assert!(refusal.is_none(), "{refusal:?}");

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **The same when the retry's submit straddles a lane rebuild:** the retired
/// lane folds the retry's record, and the node's answer alone tells the
/// commit that the leg with its txid is this send now.
#[tokio::test(flavor = "multi_thread")]
async fn an_identical_retry_across_a_rebuild_is_no_news_of_the_first() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let held = coin(&receive(), 0x51, 10 * SOMPI_PER_KAS);
    let (engine, mut events, store) = funded_with(
        "identical-retry-rebuild.kvlog",
        &fake,
        &ctl,
        vec![held.clone()],
    )
    .await;
    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let first = fake.submitted().pop().expect("the first at the node");

    fake.answer_submits(SubmitAnswer::Accept);
    let prepared = one_kas(&engine, &fake, &ctl).await;
    let hold = fake.hold_submits();
    let commit = tokio::spawn(prepared.commit(None));
    fake.wait_until("the retry at the node", WAIT, |f| f.submitted().len() == 2)
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
    let retry = commit.await.expect("the send's task must not panic");
    assert_eq!((retry.submitted, retry.error.clone()), (1, None));
    let second = fake.submitted().pop().expect("the retry at the node");
    assert_eq!(
        txid_of(&first),
        txid_of(&second),
        "the retry is the same transaction"
    );

    let epoch = fake.begin_epoch();
    ctl.signal_open().await.expect("signal open");
    fake.wait_until("the reopen's read at the node", WAIT, |f| {
        f.utxo_scans(epoch) >= 1
    })
    .await;
    tokio::time::timeout(WAIT, async {
        while !engine.lane_up() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the rebuilt lane serves");
    let deposit = coin(&receive(), 0x66, 5 * SOMPI_PER_KAS);
    fake.set_utxos(vec![held, deposit.clone()]);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![deposit]),
            removed: Arc::new(vec![]),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the deposit folded", |m, _, _, _| {
        m >= 5 * SOMPI_PER_KAS
    })
    .await;
    let refusal = one_kas_refusal(&engine, &fake, &ctl).await;
    assert!(refusal.is_none(), "{refusal:?}");

    tokio::time::timeout(LANE_STEP_WITHIN * 2, engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// Whether `coin` is on the spendable list.
async fn spendable_holds(engine: &WalletEngine, coin: &RpcUtxosByAddressesEntry) -> bool {
    engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set")
        .iter()
        .any(|entry| {
            let id = entry.outpoint.inner();
            (id.transaction_id, id.index) == (coin.outpoint.transaction_id, coin.outpoint.index)
        })
}

/// A send with no answer, then coins arriving that the policy draws first,
/// then the socket closing and opening again (with the processor dying at its
/// next negotiation when `rebuild`): while the reopen's read is held, the fee
/// figure is asked for the same payment. Returns the first send and the retry.
async fn retry_after_a_reopen(rebuild: bool, name: &str) -> (RpcTransaction, RpcTransaction) {
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let held = coin(&receive(), 0x51, 10 * SOMPI_PER_KAS);
    let (engine, mut events, store) = funded_with(name, &fake, &ctl, vec![held.clone()]).await;
    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let first = fake.submitted().pop().expect("the first at the node");
    let arrived = vec![
        coin(&receive(), 0x63, 50 * SOMPI_PER_KAS),
        coin(&receive(), 0x64, 3 * SOMPI_PER_KAS / 10),
        coin(&receive(), 0x65, 4 * SOMPI_PER_KAS / 10),
    ];
    let mut node = vec![held.clone()];
    node.extend(arrived.iter().cloned());
    fake.set_utxos(node);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(arrived),
            removed: Arc::new(vec![]),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the deposits folded", |m, _, _, _| {
        m == 607 * SOMPI_PER_KAS / 10
    })
    .await;

    if rebuild {
        fake.panic_on_daa_subscribes(1);
    }
    let scan = fake.hold_scans();
    ctl.signal_close().await.expect("signal close");
    let epoch = fake.begin_epoch();
    ctl.signal_open().await.expect("signal open");
    fake.wait_until("the reopen's read at the node", WAIT, |f| {
        f.utxo_scans(epoch) >= 1
    })
    .await;
    // The first send's coin is off the spendable list until that read files
    // it again; the fee figure is asked meanwhile.
    let _ = engine.fee_preview(payee(), receive(), SOMPI_PER_KAS, &[]);
    scan.add_permits(usize::MAX >> 4);
    tokio::time::timeout(WAIT, async {
        while !spendable_holds(&engine, &held).await {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the reopen's read filed the first send's coin");
    if rebuild {
        assert!(engine.lanes_built() >= 2, "the lane was not rebuilt");
    }

    fake.answer_submits(SubmitAnswer::Accept);
    let retry = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((retry.submitted, retry.error.clone()), (1, None));
    let second = fake.submitted().pop().expect("the retry at the node");
    tokio::time::timeout(LANE_STEP_WITHIN * 2, engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
    (first, second)
}

/// **A send with no answer is not forgotten while its coin is briefly off the
/// spendable list.** A reopen takes a cancelled leg's coin out until its read
/// files it again, which is the moment after the dropped socket that left the
/// send unanswered; the fee figure, asked meanwhile, must not retire it, or
/// the retry would be built from other coins and both could land.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_with_no_answer_is_not_forgotten_across_a_reopen() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let (first, second) = retry_after_a_reopen(false, "unknown-across-reopen.kvlog").await;
    assert!(
        !spends(&first).is_disjoint(&spends(&second)),
        "the retry spends none of the first's coins: both can land"
    );
}

/// **The same across a lane rebuild**, whose fresh context holds no coin at all
/// until its first read.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_with_no_answer_is_not_forgotten_across_a_rebuild() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let (first, second) = retry_after_a_reopen(true, "unknown-across-rebuild.kvlog").await;
    assert!(
        !spends(&first).is_disjoint(&spends(&second)),
        "the retry spends none of the first's coins: both can land"
    );
}

/// **A retry after a reopen whose read failed still conflicts with a send
/// that got no answer.** The reopen takes the first send's coin out until its
/// read files it again; that read fails, the lane serves anyway, and the
/// retry's own change scan reads only its change address, not the coin's.
/// Off the spendable list, the coin still leads the retry: nothing proved it
/// spent.
#[tokio::test(flavor = "multi_thread")]
async fn a_retry_after_a_failed_reopen_read_still_conflicts() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let held = coin(&change(), 0x51, 10 * SOMPI_PER_KAS);
    let (engine, mut events, store) =
        funded_with("retry-failed-reopen.kvlog", &fake, &ctl, vec![held.clone()]).await;
    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let first = fake.submitted().pop().expect("the first at the node");
    let arrived = vec![
        coin(&receive(), 0x63, 50 * SOMPI_PER_KAS),
        coin(&receive(), 0x64, 3 * SOMPI_PER_KAS / 10),
        coin(&receive(), 0x65, 4 * SOMPI_PER_KAS / 10),
    ];
    let mut node = vec![held.clone()];
    node.extend(arrived.iter().cloned());
    fake.set_utxos(node);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(arrived),
            removed: Arc::new(vec![]),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the deposits folded", |m, _, _, _| {
        m == 607 * SOMPI_PER_KAS / 10
    })
    .await;

    fake.fail_scans(1);
    ctl.signal_close().await.expect("signal close");
    let epoch = fake.begin_epoch();
    ctl.signal_open().await.expect("signal open");
    fake.wait_until("the reopen's read at the node", WAIT, |f| {
        f.utxo_scans(epoch) >= 1
    })
    .await;
    // The reopen's read took the failure, not a later one.
    read_failed(&mut events).await;
    assert!(
        !spendable_holds(&engine, &held).await,
        "the failed read filed the coin after all"
    );

    fake.answer_submits(SubmitAnswer::Accept);
    let retry = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((retry.submitted, retry.error.clone()), (1, None));
    let second = fake.submitted().pop().expect("the retry at the node");
    assert!(
        !spends(&first).is_disjoint(&spends(&second)),
        "the retry spends none of the first's coins: both can land"
    );

    tokio::time::timeout(LANE_STEP_WITHIN * 2, engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// A send with no answer spends one coin at `change()`, old enough for any
/// synced node's index to list it;
/// coins the policy prefers arrive; a reopen's read fails, so that coin is off
/// the spendable list; then the node stops listing it (spent while it was
/// off). Returns the first send's coin and the retry's inputs.
async fn retry_after_an_unseen_spend(name: &str) -> (RpcUtxosByAddressesEntry, RpcTransaction) {
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let mut held = coin(&change(), 0x51, 10 * SOMPI_PER_KAS);
    held.utxo_entry.block_daa_score = 900_000;
    let (engine, mut events, store) = funded_with(name, &fake, &ctl, vec![held.clone()]).await;
    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let arrived = vec![
        coin(&receive(), 0x63, 50 * SOMPI_PER_KAS),
        coin(&receive(), 0x64, 3 * SOMPI_PER_KAS / 10),
        coin(&receive(), 0x65, 4 * SOMPI_PER_KAS / 10),
    ];
    let mut node = vec![held.clone()];
    node.extend(arrived.iter().cloned());
    fake.set_utxos(node);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(arrived.clone()),
            removed: Arc::new(vec![]),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the deposits folded", |m, _, _, _| {
        m == 607 * SOMPI_PER_KAS / 10
    })
    .await;
    fake.fail_scans(1);
    ctl.signal_close().await.expect("signal close");
    let epoch = fake.begin_epoch();
    ctl.signal_open().await.expect("signal open");
    fake.wait_until("the reopen's read at the node", WAIT, |f| {
        f.utxo_scans(epoch) >= 1
    })
    .await;
    // The reopen's read took the failure, not a later one.
    read_failed(&mut events).await;
    // Spent while it was off the list: no frame could say so.
    fake.set_utxos(arrived);
    fake.answer_submits(SubmitAnswer::Accept);
    let retry = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((retry.submitted, retry.error.clone()), (1, None));
    let second = fake.submitted().pop().expect("the retry at the node");
    tokio::time::timeout(LANE_STEP_WITHIN * 2, engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
    (held, second)
}

/// **A coin spent while it was off the spendable list does not lead the
/// retry.** No frame could say so, so the retry's own read asks the address
/// of every coin a send of the same payment holds: the node no longer lists
/// it, and the send of unknown fate is settled before its coin would lead a
/// build the node refuses.
#[tokio::test(flavor = "multi_thread")]
async fn a_coin_spent_while_off_the_list_does_not_lead_the_retry() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let (held, second) = retry_after_an_unseen_spend("unseen-spend.kvlog").await;
    assert!(
        !spends(&second).contains(&(held.outpoint.transaction_id, held.outpoint.index)),
        "the retry led with a coin the node no longer lists"
    );
}

/// A send lands and its change comes home at DAA 1_000_001 (the pin matures
/// an outgoing send's change at once); a send from that change gets no answer;
/// coins the policy prefers arrive; the node stops listing the change; the
/// processor's score reaches `tick`; a retry. Returns the change and the
/// retry's inputs.
async fn retry_after_a_young_coin_goes_missing(
    tick: u64,
    name: &str,
) -> (RpcUtxosByAddressesEntry, RpcTransaction) {
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded_with(
        name,
        &fake,
        &ctl,
        vec![coin(&receive(), 0x51, 10 * SOMPI_PER_KAS)],
    )
    .await;
    // A send lands; its change comes home at once, created at DAA 1_000_001.
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let landed = fake.submitted().pop().expect("the first payment");
    let (index, value) = output_to(&landed, &receive());
    let (_, spent) = split_by(&landed);
    let young = output_coin(&receive(), txid_of(&landed), index, value, 1_000_001);
    fake.set_utxos(vec![young.clone()]);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![young.clone()]),
            removed: Arc::new(spent),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the change filed", |m, _, o, _| {
        m == value && o == 0
    })
    .await;

    // A send from that change gets no answer; coins the policy prefers arrive.
    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let arrived = vec![
        coin(&receive(), 0x63, 50 * SOMPI_PER_KAS),
        coin(&receive(), 0x64, 3 * SOMPI_PER_KAS / 10),
        coin(&receive(), 0x65, 4 * SOMPI_PER_KAS / 10),
    ];
    fake.set_utxos(arrived.clone());
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(arrived),
            removed: Arc::new(vec![]),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the deposits folded", |m, _, _, _| {
        m == value + 507 * SOMPI_PER_KAS / 10
    })
    .await;
    // The node no longer lists the change: it was spent, or it is a node we
    // reconnected to that trails the one whose frame filed it. The retry's
    // own read asks its address.
    assert!(
        fake.deliver(Notification::VirtualDaaScoreChanged(
            VirtualDaaScoreChangedNotification {
                virtual_daa_score: tick,
            },
        ))
        .await
            >= 1
    );
    tokio::time::timeout(WAIT, async {
        while engine.context().processor().current_daa_score() < Some(tick) {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("the processor at the tick");
    fake.answer_submits(SubmitAnswer::Accept);
    let retry = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((retry.submitted, retry.error.clone()), (1, None));
    let second = fake.submitted().pop().expect("the retry at the node");

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
    (young, second)
}

/// **A young coin missing from the answer still leads.** Its absence proves
/// nothing while it is younger than the pin's maturity window (100 DAA on
/// mainnet): a node may not index it yet. The read's score is the last one
/// inside the window.
#[tokio::test(flavor = "multi_thread")]
async fn a_young_coin_missing_from_the_answer_still_leads_the_retry() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let (young, second) =
        retry_after_a_young_coin_goes_missing(1_000_100, "young-unlisted.kvlog").await;
    assert!(
        spends(&second).contains(&(young.outpoint.transaction_id, young.outpoint.index)),
        "a young coin's absence retired the send of unknown fate"
    );
}

/// **The same coin missing one DAA later no longer leads:** past the window
/// every synced node lists it, so its absence retires the send of unknown
/// fate before its coin would lead a build the node refuses.
#[tokio::test(flavor = "multi_thread")]
async fn a_coin_missing_past_the_maturity_window_no_longer_leads() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let (young, second) =
        retry_after_a_young_coin_goes_missing(1_000_101, "past-window-unlisted.kvlog").await;
    assert!(
        !spends(&second).contains(&(young.outpoint.transaction_id, young.outpoint.index)),
        "the retry led with a coin the node no longer lists"
    );
}

/// **A retry that also gets no answer still anchors the coins it led with.**
/// The first send's two young coins, taken out of the map by a reopen whose
/// read failed and missing from a trailing node's answer since, lead the
/// retry and are still out of the map when its cancel looks; they are the
/// retry's coins all the same. Once the first send's third coin is gone, the
/// first send can never land, and the next attempt must still conflict with
/// the retry.
#[tokio::test(flavor = "multi_thread")]
async fn a_retry_with_no_answer_still_anchors_the_coins_it_led_with() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded_with(
        "retry-unanswered-twice.kvlog",
        &fake,
        &ctl,
        vec![coin(&receive(), 0x51, 10 * SOMPI_PER_KAS)],
    )
    .await;
    // A send to ourselves lands: both its outputs come home young.
    let outcome = kas_to(&engine, &fake, &ctl, receive(), 4 * SOMPI_PER_KAS)
        .await
        .commit(None)
        .await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let landed = fake.submitted().pop().expect("the send to ourselves");
    let txid = txid_of(&landed);
    let young: Vec<RpcUtxosByAddressesEntry> = landed
        .outputs
        .iter()
        .enumerate()
        .map(|(index, output)| output_coin(&receive(), txid, index as u32, output.value, 1_000_001))
        .collect();
    assert_eq!(young.len(), 2, "a payment and its change");
    let homed: u64 = young.iter().map(|c| c.utxo_entry.amount).sum();
    let (_, spent) = split_by(&landed);
    let mut old = coin(&change(), 0x52, 2 * SOMPI_PER_KAS / 10);
    old.utxo_entry.block_daa_score = 900_000;
    let mut node = young.clone();
    node.push(old.clone());
    fake.set_utxos(node.clone());
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(node),
            removed: Arc::new(spent),
        }))
        .await
            >= 1
    );
    balance_where(
        &mut events,
        "the send home and a deposit filed",
        |m, _, o, _| m == homed + 2 * SOMPI_PER_KAS / 10 && o == 0,
    )
    .await;

    // The first send needs all three coins and gets no answer.
    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let outcome = kas_to(&engine, &fake, &ctl, payee(), 9 * SOMPI_PER_KAS)
        .await
        .commit(None)
        .await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let first = fake.submitted().pop().expect("the first send at the node");
    let id = |c: &RpcUtxosByAddressesEntry| (c.outpoint.transaction_id, c.outpoint.index);
    assert!(
        young
            .iter()
            .chain([&old])
            .all(|c| spends(&first).contains(&id(c))),
        "the first send spends all three coins"
    );
    let arrived = vec![
        coin(&receive(), 0x63, 50 * SOMPI_PER_KAS),
        coin(&receive(), 0x64, 3 * SOMPI_PER_KAS / 10),
        coin(&receive(), 0x65, 4 * SOMPI_PER_KAS / 10),
    ];
    // The node trails: it does not list the young coins yet.
    let mut node = vec![old.clone()];
    node.extend(arrived.iter().cloned());
    fake.set_utxos(node);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(arrived.clone()),
            removed: Arc::new(vec![]),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the deposits folded", |m, _, _, _| {
        m == homed + 509 * SOMPI_PER_KAS / 10
    })
    .await;
    // The socket drops; the reopen's read fails, so the map holds none of the
    // first send's coins until a read files them, and none files a young coin
    // the node does not list.
    fake.fail_scans(1);
    ctl.signal_close().await.expect("signal close");
    let epoch = fake.begin_epoch();
    ctl.signal_open().await.expect("signal open");
    fake.wait_until("the reopen's read at the node", WAIT, |f| {
        f.utxo_scans(epoch) >= 1
    })
    .await;
    // The reopen's read took the failure, not a later one.
    read_failed(&mut events).await;

    // The retry leads with the young coins, needs no third, and gets no
    // answer either.
    let retry = kas_to(&engine, &fake, &ctl, payee(), 9 * SOMPI_PER_KAS)
        .await
        .commit(None)
        .await;
    assert!(retry.unanswered.is_some(), "{retry:?}");
    let second = fake.submitted().pop().expect("the retry at the node");
    assert_eq!(
        spends(&second),
        young.iter().map(id).collect::<HashSet<_>>(),
        "the retry spends the young coins alone"
    );

    // The first send's third coin is gone: it can never land. The retry can.
    fake.set_utxos(arrived);
    fake.answer_submits(SubmitAnswer::Accept);
    let third = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((third.submitted, third.error.clone()), (1, None));
    let third = fake
        .submitted()
        .pop()
        .expect("the third attempt at the node");
    assert!(
        young.iter().any(|c| spends(&third).contains(&id(c))),
        "the third attempt spends none of the retry's coins: both can land"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// One KAS to the payee, prepared only: the refusal, if any.
async fn one_kas_refusal(
    engine: &WalletEngine,
    fake: &Arc<FakeRpc>,
    ctl: &RpcCtl,
) -> Option<ChainError> {
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
        .err()
}

/// **A payment waits while another send of ours holds every coin of an
/// unanswered payment to the same address.** A payment to someone else drew
/// that send's coin; a retry could conflict with neither, and both it and the
/// first could land. It is refused until the other payment settles, then
/// builds.
#[tokio::test(flavor = "multi_thread")]
async fn a_retry_waits_while_another_payment_holds_the_unanswered_sends_coins() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let held = coin(&receive(), 0x51, 10 * SOMPI_PER_KAS);
    let (engine, mut events, store) = funded_with(
        "retry-waits-on-holder.kvlog",
        &fake,
        &ctl,
        vec![held.clone()],
    )
    .await;
    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let _first = fake.submitted().pop().expect("the first at the node");

    // A payment to someone else draws the only coin, the first send's.
    fake.answer_submits(SubmitAnswer::Accept);
    let other = kas_to(&engine, &fake, &ctl, payee_two(), SOMPI_PER_KAS)
        .await
        .commit(None)
        .await;
    assert_eq!((other.submitted, other.error.clone()), (1, None));
    let other = fake
        .submitted()
        .pop()
        .expect("the other payment at the node");
    let id = |c: &RpcUtxosByAddressesEntry| (c.outpoint.transaction_id, c.outpoint.index);
    assert!(
        spends(&other).contains(&id(&held)),
        "the other payment draws the first's coin"
    );

    let arrived = vec![
        coin(&receive(), 0x63, 50 * SOMPI_PER_KAS),
        coin(&receive(), 0x64, 3 * SOMPI_PER_KAS / 10),
        coin(&receive(), 0x65, 4 * SOMPI_PER_KAS / 10),
    ];
    let mut node = vec![held.clone()];
    node.extend(arrived.iter().cloned());
    fake.set_utxos(node);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(arrived.clone()),
            removed: Arc::new(vec![]),
        }))
        .await
            >= 1
    );
    // The pin counts the other payment's change as spendable from its submit.
    let (index, value) = output_to(&other, &receive());
    balance_where(&mut events, "the deposits folded", |m, _, o, _| {
        m == value + 507 * SOMPI_PER_KAS / 10 && o == SOMPI_PER_KAS
    })
    .await;
    assert!(
        matches!(
            one_kas_refusal(&engine, &fake, &ctl).await,
            Some(ChainError::PaymentStillSettling)
        ),
        "a retry built while another payment holds the first's coins"
    );

    // The other payment lands: the first can no longer land, and the retry
    // builds.
    let change = output_coin(&receive(), txid_of(&other), index, value, 1_000_001);
    let mut node = vec![change.clone()];
    node.extend(arrived.iter().cloned());
    fake.set_utxos(node);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![change]),
            removed: Arc::new(vec![held]),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the other payment landed", |m, _, o, _| {
        m == value + 507 * SOMPI_PER_KAS / 10 && o == 0
    })
    .await;
    let retry = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((retry.submitted, retry.error.clone()), (1, None));

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// A send with no answer whose coin leaves: when `landed`, the send itself
/// spent it and its change comes home to the receive address, otherwise a
/// conflict spent it; with `frame` the node says so, otherwise only a read
/// finds it. A deposit arrives either way. Returns the engine's refusal of
/// the next payment to the same address, and whether the one after that
/// builds.
async fn retry_after_an_unanswered_send_left(
    landed: bool,
    frame: bool,
    name: &str,
) -> (Option<ChainError>, bool) {
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let held = coin(&receive(), 0x51, 10 * SOMPI_PER_KAS);
    let (engine, mut events, store) = funded_with(name, &fake, &ctl, vec![held.clone()]).await;
    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let first = fake.submitted().pop().expect("the first at the node");

    let (index, value) = output_to(&first, &receive());
    let change = output_coin(&receive(), txid_of(&first), index, value, 1_000_001);
    let deposit = coin(&receive(), 0x66, 5 * SOMPI_PER_KAS);
    let mut listed = vec![deposit.clone()];
    if landed {
        listed.push(change.clone());
    }
    fake.set_utxos(listed.clone());
    let (added, removed) = if frame {
        (listed, vec![held])
    } else {
        (vec![deposit], vec![])
    };
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(added),
            removed: Arc::new(removed),
        }))
        .await
            >= 1
    );
    // A balance only this frame produces: the first send's coin gone (a
    // frame) or still held (a read finds it), the deposit in.
    let expected = if frame {
        5 * SOMPI_PER_KAS + if landed { value } else { 0 }
    } else {
        15 * SOMPI_PER_KAS
    };
    balance_where(&mut events, "the frame folded", |m, p, _, _| {
        m + p == expected
    })
    .await;
    let refusal = one_kas_refusal(&engine, &fake, &ctl).await;
    fake.answer_submits(SubmitAnswer::Accept);
    let again = engine
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
    let builds = match again {
        Ok(prepared) => prepared.commit(None).await.submitted == 1,
        Err(_) => false,
    };

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
    (refusal, builds)
}

/// **A retry after an unanswered payment that landed says so, once.** The
/// node's frame removes its coin (which alone proves nothing: a conflict
/// could have spent it) and adds its change, a record of its own
/// transaction. The next payment to the same address is refused with that
/// news; the one after it builds.
#[tokio::test(flavor = "multi_thread")]
async fn a_retry_after_a_payment_that_went_through_says_so_once() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let (refusal, builds) =
        retry_after_an_unanswered_send_left(true, true, "went-through-frame.kvlog").await;
    assert!(
        matches!(refusal, Some(ChainError::EarlierPaymentWentThrough)),
        "{refusal:?}"
    );
    assert!(builds, "the payment after the notice did not build");
}

/// **The same when only a read finds it:** a frame missed, the retry's own
/// read lists the first send's change, and a node's index holds accepted
/// transactions only.
#[tokio::test(flavor = "multi_thread")]
async fn a_retry_after_a_payment_a_read_finds_went_through_says_so_once() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let (refusal, builds) =
        retry_after_an_unanswered_send_left(true, false, "went-through-read.kvlog").await;
    assert!(
        matches!(refusal, Some(ChainError::EarlierPaymentWentThrough)),
        "{refusal:?}"
    );
    assert!(builds, "the payment after the notice did not build");
}

/// **A conflict spending the unanswered payment's coin says nothing of it.**
/// The frame removes the coin and adds no output of the send: another
/// spend took it, the send can never land, and the next payment builds with
/// no notice.
#[tokio::test(flavor = "multi_thread")]
async fn a_retry_after_a_conflict_took_the_unanswered_payments_coin_builds() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let (refusal, builds) =
        retry_after_an_unanswered_send_left(false, true, "conflict-took-it.kvlog").await;
    assert!(refusal.is_none(), "{refusal:?}");
    assert!(builds, "the payment after the conflict did not build");
}

/// **A cancelled leg's coin a frame had already spent is not spendable.** The
/// coin went between the build and the submit (another wallet on this seed
/// spent it); the pin's cancel puts every input of the leg back on the
/// spendable list, this one with no entry in its map, so no frame could ever
/// take it back.
#[tokio::test(flavor = "multi_thread")]
async fn a_cancelled_legs_coin_spent_before_its_register_is_not_spendable() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let only = coin(&receive(), 0x51, 10 * SOMPI_PER_KAS);
    let (engine, mut events, store) =
        funded_with("cancel-phantom.kvlog", &fake, &ctl, vec![only.clone()]).await;
    let prepared = one_kas(&engine, &fake, &ctl).await;
    fake.set_utxos(vec![]);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![]),
            removed: Arc::new(vec![only.clone()]),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the coin spent elsewhere", |m, _, _, _| m == 0).await;

    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let outcome = prepared.commit(None).await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    assert!(
        !spendable_holds(&engine, &only).await,
        "a coin spent elsewhere reads spendable after the cancel"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A payment to another destination leaves a send of unknown fate alone
/// when it can.** Its coin, back on the spendable list, is drawn last, so an
/// unrelated payment does not race it by accident. "When it can": the
/// Generator itself pulls up to two inputs per output to lower storage mass
/// (`generator.rs:838-852` @ `01b532e`), so the coin stays out only while
/// enough others come before it. Here it is the smallest coin, which the
/// policy would otherwise send first as a rider.
#[tokio::test(flavor = "multi_thread")]
async fn another_payment_draws_a_send_of_unknown_fate_last() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let held = coin(&receive(), 0x51, 2 * SOMPI_PER_KAS);
    let (engine, mut events, store) =
        funded_with("unknown-drawn-last.kvlog", &fake, &ctl, vec![held.clone()]).await;
    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let first = fake.submitted().pop().expect("the first at the node");

    let arrived: Vec<RpcUtxosByAddressesEntry> = (0x61..=0x64)
        .map(|n| coin(&receive(), n, 20 * SOMPI_PER_KAS))
        .collect();
    let mut node = vec![held];
    node.extend(arrived.iter().cloned());
    fake.set_utxos(node);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(arrived),
            removed: Arc::new(vec![]),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the deposits folded", |m, _, _, _| {
        m == 82 * SOMPI_PER_KAS
    })
    .await;
    fake.answer_submits(SubmitAnswer::Accept);
    let other = engine
        .prepare_send(
            change(),
            SOMPI_PER_KAS,
            receive(),
            Arc::new(Unsigned),
            fake.rpc(ctl.clone()),
            None,
            &[],
        )
        .await
        .expect("a buildable send")
        .commit(None)
        .await;
    assert_eq!((other.submitted, other.error.clone()), (1, None));
    let second = fake
        .submitted()
        .pop()
        .expect("the other payment at the node");
    assert!(
        spends(&first).is_disjoint(&spends(&second)),
        "an unrelated payment drew the coin of a send of unknown fate"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A message sent again after one with no answer conflicts with it, from
/// the conversation's own address.** A message's input[0] is its sender's
/// identity, so the coin of the first leads the pinned block it belongs to;
/// without it the pinned block's largest coin would lead.
#[tokio::test(flavor = "multi_thread")]
async fn a_message_sent_again_after_no_answer_conflicts_from_its_own_address() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let held = coin(&receive(), 0x51, 10 * SOMPI_PER_KAS);
    let (engine, mut events, store) =
        funded_with("message-retry.kvlog", &fake, &ctl, vec![held.clone()]).await;
    let pinned = |engine: &WalletEngine| {
        let engine = engine.clone();
        async move {
            engine
                .context()
                .get_utxos(None, None)
                .await
                .expect("the spendable set")
                .into_iter()
                .map(Into::into)
                .collect::<Vec<kaspa_wallet_core::utxo::UtxoEntryReference>>()
        }
    };
    // A message is a self-send to the conversation's bound address (its
    // destination is its source), anchored by its conversation.
    let message = |priority| {
        engine.prepare_send_pinned(
            receive(),
            SOMPI_PER_KAS / 5,
            priority,
            receive(),
            Arc::new(Unsigned),
            fake.rpc(ctl.clone()),
            Some(b"ciph_msg:1:comm:hello".to_vec()),
            &[],
            Some("conversation:a".to_string()),
        )
    };
    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let outcome = message(pinned(&engine).await)
        .await
        .expect("a buildable message")
        .commit(None)
        .await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let first = fake.submitted().pop().expect("the first at the node");

    let arrived = vec![
        coin(&receive(), 0x63, 50 * SOMPI_PER_KAS),
        coin(&receive(), 0x64, 3 * SOMPI_PER_KAS / 10),
        coin(&receive(), 0x65, 4 * SOMPI_PER_KAS / 10),
    ];
    let mut node = vec![held.clone()];
    node.extend(arrived.iter().cloned());
    fake.set_utxos(node);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(arrived),
            removed: Arc::new(vec![]),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the deposits folded", |m, _, _, _| {
        m == 607 * SOMPI_PER_KAS / 10
    })
    .await;
    fake.answer_submits(SubmitAnswer::Accept);
    let retry = message(pinned(&engine).await)
        .await
        .expect("a buildable message")
        .commit(None)
        .await;
    assert_eq!((retry.submitted, retry.error.clone()), (1, None));
    let second = fake.submitted().pop().expect("the retry at the node");
    assert!(
        !spends(&first).is_disjoint(&spends(&second)),
        "the message sent again spends none of the first's coins: both can land"
    );
    let lead = &second.inputs[0].previous_outpoint;
    assert_eq!(
        (lead.transaction_id, lead.index),
        (held.outpoint.transaction_id, held.outpoint.index),
        "input[0] is not the first's coin at the conversation's address"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// The latest activity rows the engine publishes within `within`, read off
/// the event stream.
async fn activity_within(
    events: &mut tokio::sync::broadcast::Receiver<WalletEvent>,
    within: Duration,
) -> Vec<Vec<kaspaverse_chain::WalletActivityRecord>> {
    let mut seen = Vec::new();
    let _ = tokio::time::timeout(within, async {
        loop {
            match events.recv().await {
                Ok(WalletEvent::Activity(list)) => seen.push(list),
                Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(e) => panic!("wallet event stream closed: {e}"),
            }
        }
    })
    .await;
    seen
}

/// **A send that lost to a conflict is purged, and never reads Confirmed.**
/// It spends two coins; another spend of one of them lands (another wallet on
/// this seed). The pin raises the send's `Maturity` for the removal whoever
/// spent the coin (`context.rs:631-660`), with an accepted score, and never
/// tags it, so its record stays and keeps its other coin off the spendable
/// list until a restart, and the activity reads it as Confirmed.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_that_lost_to_a_conflict_is_purged_and_never_reads_confirmed() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (one, two) = (
        coin(&receive(), 0x51, 6 * SOMPI_PER_KAS / 10),
        coin(&receive(), 0x52, 6 * SOMPI_PER_KAS / 10),
    );
    let (engine, mut events, store) = funded_with(
        "lost-to-conflict.kvlog",
        &fake,
        &ctl,
        vec![one.clone(), two.clone()],
    )
    .await;
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let sent = fake.submitted().pop().expect("the send at the node");
    let txid = txid_of(&sent);
    assert_eq!(spends(&sent).len(), 2, "the send must spend both coins");

    // A conflict spends one of them and lands; the send cannot land any more.
    fake.set_utxos(vec![two.clone()]);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![]),
            removed: Arc::new(vec![one]),
        }))
        .await
            >= 1
    );
    let rows = activity_within(&mut events, Duration::from_millis(500)).await;
    assert!(
        rows.iter().flatten().all(|row| row.txid != txid.to_string()
            || row.maturity != kaspaverse_chain::ActivityMaturity::Confirmed),
        "a send that lost to a conflict read Confirmed"
    );
    assert!(
        engine.context().processor().outgoing().get(&txid).is_none(),
        "the lost send's record was kept"
    );
    assert!(
        spendable_holds(&engine, &two).await,
        "the lost send's other coin stayed off the spendable list"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// Whether some published activity list reads `txid` Confirmed.
fn reads_confirmed(rows: &[Vec<kaspaverse_chain::WalletActivityRecord>], txid: Hash) -> bool {
    rows.iter().flatten().any(|row| {
        row.txid == txid.to_string()
            && row.maturity == kaspaverse_chain::ActivityMaturity::Confirmed
    })
}

/// **A payment that landed reads Confirmed** (the control beside the two
/// tests above): its frame removes the coins it spent and adds its change,
/// which tags it.
#[tokio::test(flavor = "multi_thread")]
async fn a_payment_that_landed_reads_confirmed() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded("landed-confirmed.kvlog", &fake, &ctl).await;
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let sent = fake.submitted().pop().expect("the send at the node");
    let txid = txid_of(&sent);
    let (index, change) = output_to(&sent, &receive());
    let (_, spent) = split_by(&sent);
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
    let rows = activity_within(&mut events, Duration::from_millis(500)).await;
    assert!(
        reads_confirmed(&rows, txid),
        "a landed payment did not read Confirmed"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A sweep that landed reads Confirmed.** It leaves no change, so its frame
/// only removes the coins it spent and nothing tags it; every coin it spends is
/// gone and no other send of ours spends them.
#[tokio::test(flavor = "multi_thread")]
async fn a_sweep_that_landed_reads_confirmed() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded("sweep-confirmed.kvlog", &fake, &ctl).await;
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
    let sent = fake.submitted().pop().expect("the sweep at the node");
    let txid = txid_of(&sent);
    assert_eq!(
        output_to_opt(&sent, &receive()),
        None,
        "the sweep left change"
    );
    let (_, spent) = split_by(&sent);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![]),
            removed: Arc::new(spent),
        }))
        .await
            >= 1
    );
    let rows = activity_within(&mut events, Duration::from_millis(500)).await;
    assert!(
        reads_confirmed(&rows, txid),
        "a landed sweep did not read Confirmed"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A send a read settled never reads Confirmed from the frame after.** The
/// node no longer lists its coin, so the read settles it, unable to say
/// whether it landed or a conflict did; the conflict's own frame then reaches
/// the processor inside the purge window, and the pin raises the send's
/// `Maturity` with an accepted score.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_a_read_settled_never_reads_confirmed_from_the_frame_after() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let only = coin(&receive(), 0x51, 10 * SOMPI_PER_KAS);
    let (engine, mut events, store) =
        funded_with("read-settled-frame.kvlog", &fake, &ctl, vec![only.clone()]).await;
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let txid = txid_of(&fake.submitted().pop().expect("the send at the node"));

    fake.set_utxos(vec![]);
    engine.rescan().await.expect("the pull");
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![]),
            removed: Arc::new(vec![only]),
        }))
        .await
            >= 1
    );
    let rows = activity_within(&mut events, Duration::from_millis(500)).await;
    assert!(
        rows.iter().flatten().all(|row| row.txid != txid.to_string()
            || row.maturity != kaspaverse_chain::ActivityMaturity::Confirmed),
        "a send the read settled read Confirmed on the frame after"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
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
    remove_store(&store);
}

/// **A send whose submit fails while the processor's handler is stuck still
/// comes back.** A frame arrives while the submit is out and waits for the
/// notification lock; the submit fails, the pin cancels the leg, and the frame's
/// handler then takes the lock and never lets go (it waits on a dead sync
/// monitor). The check of the cancelled leg's coins waits on that lock bounded,
/// like every wait on it, so the commit returns and the leg is still recorded as
/// one with no answer. Paused time.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_failed_submit_behind_a_stuck_handler_still_comes_back() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    fake.report_unsynced(1);
    fake.panic_on_sync_status(1);
    let ctl = RpcCtl::new();
    let (engine, _events, store) = funded("stuck-after-cancel.kvlog", &fake, &ctl).await;
    fake.wait_until("the sync monitor's poll", WAIT, |f| {
        f.sync_status_calls() >= 1
    })
    .await;
    let prepared = one_kas(&engine, &fake, &ctl).await;
    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let submit = fake.hold_submits();
    let commit = tokio::spawn(prepared.commit(None));
    fake.wait_until("the submit at the node", WAIT, |f| f.submitted().len() == 1)
        .await;
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![]),
            removed: Arc::new(vec![]),
        }))
        .await
            >= 1
    );
    tokio::time::sleep(Duration::from_millis(100)).await;
    submit.add_permits(1);
    let outcome = tokio::time::timeout(LANE_HOLD_WITHIN * 2, commit)
        .await
        .expect("the send never came back")
        .expect("the send's task must not panic");
    assert!(outcome.unanswered.is_some(), "{outcome:?}");

    tokio::time::timeout(LANE_STEP_WITHIN * 2, engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A send in flight across a lane rebuild keeps its coins out until it
/// lands.** The node took it and has not accepted it, so its index still
/// lists the coins it spends. The rebuilt lane starts with a fresh context and
/// reads the node: knowing nothing of the send, it would file those coins as
/// spendable, and a send drawing on them would be refused (or pay twice, were
/// the first to be dropped). Once the send lands, a read files its change,
/// even when its frame was missed.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_in_flight_across_a_rebuild_keeps_its_coins_out_until_it_lands() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, _) = many_coins();
    let (engine, mut events, store) =
        funded_with("rebuild-in-flight.kvlog", &fake, &ctl, coins.clone()).await;
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let sent = fake.submitted().pop().expect("the send at the node");
    let txid = txid_of(&sent);
    let gone = spends(&sent);
    let (spent, unspent): (Vec<_>, Vec<_>) = coins
        .into_iter()
        .partition(|c| gone.contains(&(c.outpoint.transaction_id, c.outpoint.index)));
    let left = value_of(&unspent);
    assert!(!spent.is_empty() && left > 0);

    // The processor dies at its next negotiation: the lane is rebuilt, and
    // reads the node, which still lists every coin.
    fake.panic_on_daa_subscribes(1);
    ctl.signal_close().await.expect("signal close");
    let epoch = fake.begin_epoch();
    ctl.signal_open().await.expect("signal open");
    tokio::time::timeout(WAIT, async {
        while engine.lanes_built() < 2 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the lane rebuilt");
    fake.wait_until("the rebuilt lane's read", WAIT, |f| {
        f.utxo_scans(epoch) >= 1
    })
    .await;
    let filed = tokio::time::timeout(WAIT, async {
        loop {
            let sum: u64 = engine
                .context()
                .get_utxos(None, None)
                .await
                .expect("the spendable set")
                .iter()
                .map(|entry| entry.amount)
                .sum();
            if sum > 0 {
                return sum;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the rebuilt lane filed the node's coins");
    assert_eq!(
        filed, left,
        "the rebuilt lane filed the coins a send in flight spends"
    );
    // The send belongs to the replaced lane's context: the new processor is
    // not handed it, and the new lane's reads judge it from the node's answer.
    assert!(engine.context().processor().outgoing().get(&txid).is_none());
    for coin in &spent {
        assert!(!spendable_holds(&engine, coin).await);
    }

    // It lands, and its frame is missed: the next read judges it from the
    // node's answer and files its change.
    let (index, change) = output_to(&sent, &receive());
    let landed = output_coin(&receive(), txid, index, change, 900_000);
    let mut node = unspent.clone();
    node.push(landed.clone());
    fake.set_utxos(node);
    engine.rescan().await.expect("the pull");
    assert!(
        spendable_holds(&engine, &landed).await,
        "the landed send's change was withheld as if it were still in flight"
    );
    let _ = (&mut events, &spent);

    tokio::time::timeout(LANE_STEP_WITHIN * 2, engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
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
    remove_store(&store);
}

/// The output of a submitted transaction that pays `to`: its index and value.
fn output_to(transaction: &RpcTransaction, to: &Address) -> (u32, u64) {
    output_to_opt(transaction, to).expect("an output to the address")
}

/// The output paying `to`, if any.
fn output_to_opt(transaction: &RpcTransaction, to: &Address) -> Option<(u32, u64)> {
    transaction
        .outputs
        .iter()
        .enumerate()
        .find_map(|(index, output)| {
            (extract_script_pub_key_address(&output.script_public_key, to.prefix).ok()? == *to)
                .then_some((index as u32, output.value))
        })
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
    remove_store(&store);
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
    remove_store(&store);
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
    past_maturity_handled(&fake, &engine).await;
    assert_eq!(WALLET_CORE_PANICS.load(Ordering::SeqCst), panics_before);
    assert_eq!(engine.lane_deaths(), 0);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
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
    remove_store(&store);
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
    remove_store(&store);
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
    remove_store(&store);
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

/// [`past_maturity`], then wait until the processor's handler has finished
/// that tick and everything delivered before it: the handler takes the
/// notification lock's write side for each frame in turn
/// (`processor.rs:636-637` @ `01b532e`) and stores a tick's score first
/// (`:263-264`), so once the score is in, the read side is free only after
/// the tick's promotions.
async fn past_maturity_handled(fake: &FakeRpc, engine: &WalletEngine) {
    let processor = engine.context().processor().clone();
    assert!(
        processor.current_daa_score() < Some(1_000_200),
        "the processor is already past the tick: waiting for it proves nothing"
    );
    past_maturity(fake).await;
    tokio::time::timeout(WAIT, async {
        while processor.current_daa_score() < Some(1_000_200) {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        drop(processor.notification_lock().await);
    })
    .await
    .expect("the processor handled the tick");
}

/// Wait until the wallet lane has begun a close after `before` closes: from
/// then on it admits no submit until the next open.
async fn close_begun(engine: &WalletEngine, before: u64) {
    tokio::time::timeout(WAIT, async {
        while engine.closes_begun() <= before {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("the lane began the close");
}

/// Wait for the error a read that the fake failed reports
/// ([`FakeRpc::fail_scans`]).
async fn read_failed(events: &mut tokio::sync::broadcast::Receiver<WalletEvent>) {
    next_event(
        events,
        WAIT,
        |e| matches!(e, WalletEvent::Error(text) if text.contains("the UTXO index is unavailable")),
    )
    .await
    .expect("the read failed");
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
    remove_store(&store);
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
    remove_store(&store);
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
    remove_store(&store);
}

/// **A batch leg that lands and is purged while the reopen's read is out is
/// folded as landed.** The reopen hands the pin back the leg, untagged; its
/// outputs' frame tags it while the fold waits on the read, and a tick purges
/// it before the fold meets its `Maturity`. Our copy shares the tag: the leg
/// leaves the sends in flight, so nothing reads unsettled and a read files
/// its output.
#[tokio::test(flavor = "multi_thread")]
async fn a_batch_leg_purged_while_the_reopen_reads_is_folded_as_landed() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let coins: Vec<RpcUtxosByAddressesEntry> = (0..300u32)
        .map(|i| RpcUtxosByAddressesEntry {
            address: Some(receive()),
            outpoint: RpcTransactionOutpoint {
                transaction_id: Hash::from_bytes([0x72; 32]),
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
    let (engine, mut events, store) =
        funded_with("batch-purged-in-read.kvlog", &fake, &ctl, coins).await;
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
                1_000_000,
            ));
        }
    }
    let outputs: u64 = added.iter().map(|c| c.utxo_entry.amount).sum();

    // The socket drops before the batch lands; the reopen's read is held.
    let scan = fake.hold_scans();
    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");
    let epoch = fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    fake.wait_until("the reopen's read at the node", WAIT, |f| {
        f.utxo_scans(epoch) >= 1
    })
    .await;

    // While it is out, the batch lands and a tick purges its record.
    fake.set_utxos(added.clone());
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(added),
            removed: Arc::new(removed),
        }))
        .await
            >= 1
    );
    assert!(
        fake.deliver(Notification::VirtualDaaScoreChanged(
            VirtualDaaScoreChangedNotification {
                virtual_daa_score: 1_000_101,
            },
        ))
        .await
            >= 1
    );
    scan.add_permits(usize::MAX >> 4);

    balance_where(
        &mut events,
        "the batch leg out of the sends in flight",
        |_, _, _, u| u == 0,
    )
    .await;
    engine.rescan().await.expect("the pull");
    balance_where(&mut events, "the batch output filed", |m, p, _, u| {
        m + p == outputs && u == 0
    })
    .await;
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
    remove_store(&store);
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
    remove_store(&store);
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
    remove_store(&store);
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
    remove_store(&store);
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
    past_maturity_handled(&fake, &engine).await;
    assert_eq!(WALLET_CORE_PANICS.load(Ordering::SeqCst), panics_before);
    assert_eq!(engine.lane_deaths(), 0);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
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
    remove_store(&store);
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
    remove_store(&store);
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
    remove_store(&store);
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
    remove_store(&store);
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
    remove_store(&store);
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
    remove_store(&store);
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
    remove_store(&store);
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
    remove_store(&store);
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
    let closes = engine.closes_begun();
    ctl.signal_close().await.expect("signal close");
    close_begun(&engine, closes).await;
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
    remove_store(&store);
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
    remove_store(&store);
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
    remove_store(&store);
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
    past_maturity_handled(&fake, &engine).await;
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
    remove_store(&store);
}

/// **A send a read settles keeps its record past a stalled handler.** The
/// read settles the chain's earlier legs by tagging them accepted; the
/// processor purges a tagged record a hundred DAA after its tag. Its handler
/// stalls with ticks queued behind it while the read is out, so the score the
/// read holds trails what the processor reaches once it resumes. Tagged at
/// that score, the records are purged by the next tick, before the legs' own
/// `UtxosChanged`, which then files their batch output as a deposit beside
/// the last leg that spends it. The handler's stall: a frame stops the sync
/// monitor while its poll waits on the node (`processor.rs:647-649`,
/// `sync.rs:47-55` @ `01b532e`).
#[tokio::test(flavor = "multi_thread")]
async fn a_send_a_read_settles_keeps_its_record_past_a_stalled_handler() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    fake.report_unsynced(1);
    let poll = fake.hold_sync_status();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, _events, store) =
        funded_with("settled-past-a-stall.kvlog", &fake, &ctl, coins.clone()).await;
    fake.wait_until("the sync monitor's poll", WAIT, |f| {
        f.sync_status_calls() >= 1
    })
    .await;
    let sent = merge_in_flight(&engine, &fake, &ctl).await;
    let legs = sent.len();
    let (node, removed, added) = after_landing(&coins, &sent[..legs - 1], &by_index, 1_000_001);

    // A frame takes the handler into the sync monitor's stop, which waits on
    // the poll; 150 ticks queue behind it.
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![]),
            removed: Arc::new(vec![]),
        }))
        .await
            >= 1
    );
    for virtual_daa_score in 1_000_001..=1_000_150 {
        assert!(
            fake.deliver(Notification::VirtualDaaScoreChanged(
                VirtualDaaScoreChangedNotification { virtual_daa_score },
            ))
            .await
                >= 1
        );
    }
    // The index shows the earlier legs accepted: the read settles them, at
    // the score it read before waiting for the lock.
    fake.set_utxos(node);
    let reads = fake.utxo_scans_all();
    let pull = tokio::spawn({
        let engine = engine.clone();
        async move { engine.rescan().await }
    });
    // Its score is read as its answer comes back, with no wait in between.
    fake.wait_until("the pull's read at the node", WAIT, |f| {
        f.utxo_scans_all() > reads
    })
    .await;
    poll.add_permits(usize::MAX >> 4);
    pull.await.expect("the pull's task").expect("the pull");

    // The next tick, then the legs' own acceptance.
    assert!(
        fake.deliver(Notification::VirtualDaaScoreChanged(
            VirtualDaaScoreChangedNotification {
                virtual_daa_score: 1_000_151,
            },
        ))
        .await
            >= 1
    );
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(added.clone()),
            removed: Arc::new(removed),
        }))
        .await
            >= 1
    );
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
    remove_store(&store);
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
    remove_store(&store);
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
    let closes = engine.closes_begun();
    ctl.signal_close().await.expect("signal close");
    close_begun(&engine, closes).await;
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
    past_maturity_handled(&fake, &engine).await;
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
    remove_store(&store);
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
    remove_store(&store);
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
    remove_store(&store);
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
    remove_store(&store);
}

/// **A send submitted, accepted and purged while a read is out keeps its
/// coins out.** It starts after the read's snapshot, so neither our record of
/// the returned submits nor the processor names it then, and by the lock the
/// processor has purged it: it is in no view the read takes. The answer,
/// served before its acceptance, lists the coins it spent, and they stay
/// filed through reconnects; every send drawing on them is refused.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_submitted_accepted_and_purged_inside_a_read_keeps_its_coins_out() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) =
        funded("submitted-purged-inside-read.kvlog", &fake, &ctl).await;
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
        "a coin the purged send spent was filed back as spendable"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
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
    remove_store(&store);
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
    past_maturity_handled(&fake, &engine).await;
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
    remove_store(&store);
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
    past_maturity_handled(&fake, &engine).await;
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
    remove_store(&store);
}

/// The activity log and the two send records beside it, as bytes on disk.
fn store_bytes(store: &std::path::Path) -> Vec<(std::path::PathBuf, Vec<u8>)> {
    [
        store.to_path_buf(),
        kaspaverse_chain::sends_path(store),
        kaspaverse_chain::spent_path(store),
    ]
    .into_iter()
    .filter_map(|path| Some((path.clone(), std::fs::read(&path).ok()?)))
    .collect()
}

/// Stop `engine` and start another on a copy of the store's files as they
/// stand now, as a relaunch of the app does: a new path, so nothing in this
/// process's memory carries over; a fresh socket; and the start's read filed
/// before this returns (its balance follows `Syncing`, `wallet_sync.rs`'s
/// start arm).
async fn relaunched(
    engine: WalletEngine,
    fake: &Arc<FakeRpc>,
    store: &std::path::Path,
) -> Relaunched {
    let files = store_bytes(store);
    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    drop(engine);
    relaunched_from(files, fake, store).await
}

/// Start an engine on `files` (taken from the store at `store`) copied to a
/// new path beside it, as a new process finds them after a crash.
async fn relaunched_from(
    files: Vec<(std::path::PathBuf, Vec<u8>)>,
    fake: &Arc<FakeRpc>,
    store: &std::path::Path,
) -> Relaunched {
    static RUN: AtomicUsize = AtomicUsize::new(0);
    let next = store.with_file_name(format!(
        "{}-run{}.kvlog",
        store
            .file_stem()
            .and_then(|stem| stem.to_str())
            .unwrap_or("store"),
        RUN.fetch_add(1, Ordering::SeqCst)
    ));
    remove_store(&next);
    for (path, bytes) in files {
        let to = if path == store {
            next.clone()
        } else if path == kaspaverse_chain::sends_path(store) {
            kaspaverse_chain::sends_path(&next)
        } else {
            kaspaverse_chain::spent_path(&next)
        };
        std::fs::write(to, bytes).expect("the copied store");
    }
    let ctl = RpcCtl::new();
    let engine = WalletEngine::new(
        fake.rpc(ctl.clone()),
        NetworkId::new(NetworkType::Mainnet),
        next.clone(),
    )
    .expect("the relaunched engine");
    let mut events = engine.subscribe();
    engine
        .start(vec![receive(), change()], vec![change()])
        .await
        .expect("engine start");
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal open");
    next_event(&mut events, WAIT, |e| matches!(e, WalletEvent::Syncing))
        .await
        .expect("the relaunched lane's start");
    balance_where(&mut events, "the start's read filed", |_, _, _, _| true).await;
    (engine, events, ctl, next)
}

/// A relaunched engine, its events, its socket and its store.
type Relaunched = (
    WalletEngine,
    tokio::sync::broadcast::Receiver<WalletEvent>,
    RpcCtl,
    std::path::PathBuf,
);

/// Three 10 KAS coins at the receive address: a one-KAS send draws two (the
/// Generator tops a small payment up against storage mass,
/// `generator.rs:838-852` @ `01b532e`) and leaves one.
fn three_coins() -> Vec<RpcUtxosByAddressesEntry> {
    [0x51u8, 0x52, 0x53]
        .into_iter()
        .map(|n| coin(&receive(), n, 10 * SOMPI_PER_KAS))
        .collect()
}

/// `coins` split into those `sent` leaves and those it spends.
fn left_and_spent(
    coins: &[RpcUtxosByAddressesEntry],
    sent: &RpcTransaction,
) -> (Vec<RpcUtxosByAddressesEntry>, Vec<RpcUtxosByAddressesEntry>) {
    let spent = spends(sent);
    coins
        .iter()
        .cloned()
        .partition(|c| !spent.contains(&(c.outpoint.transaction_id, c.outpoint.index)))
}

/// **A send in flight across a relaunch keeps its coin out until it lands.**
/// The node took it and the app ends before its acceptance; the node's index
/// still lists the coin it spends (the send waits in a mempool, which the
/// index does not see). The relaunched wallet files the other coin and not
/// that one, and once the send's own output arrives it holds nothing back.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_in_flight_across_a_relaunch_keeps_its_coin_out() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let coins = three_coins();
    let (engine, _events, store) =
        funded_with("relaunch-sent.kvlog", &fake, &ctl, coins.clone()).await;
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let sent = fake.submitted().pop().expect("the payment at the node");
    let txid = txid_of(&sent);
    let (left, spent) = left_and_spent(&coins, &sent);
    assert_eq!(left.len(), 1, "the send leaves one coin");

    let (engine, mut events, _ctl, _) = relaunched(engine, &fake, &store).await;
    for coin in &spent {
        assert!(
            !spendable_holds(&engine, coin).await,
            "the relaunch filed a coin a send in flight spends"
        );
    }
    assert!(spendable_holds(&engine, &left[0]).await);

    // It lands: its coin goes and its change comes home.
    let (index, change) = output_to(&sent, &receive());
    let homed = output_coin(&receive(), txid, index, change, 1_000_001);
    fake.set_utxos(vec![left[0].clone(), homed.clone()]);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![homed]),
            removed: Arc::new(spent.clone()),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the change home", |m, p, _, _| {
        m == 10 * SOMPI_PER_KAS && p == change
    })
    .await;
    past_maturity(&fake).await;
    let matured = balance_where(&mut events, "the change matured", |m, _, _, _| {
        m == 10 * SOMPI_PER_KAS + change
    })
    .await;
    assert_eq!(matured, (10 * SOMPI_PER_KAS + change, 0, 0, 0));
    assert_eq!(WALLET_CORE_PANICS.load(Ordering::SeqCst), panics_before);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A send with no answer still anchors the retry after a relaunch.** The
/// first payment got no answer and the app ends; coins the policy prefers
/// arrive. A retry of the same payment from the relaunched wallet spends the
/// first's coin, so at most one of the two can land.
#[tokio::test(flavor = "multi_thread")]
async fn a_leg_of_unknown_fate_across_a_relaunch_still_anchors_the_retry() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let held = coin(&receive(), 0x51, 10 * SOMPI_PER_KAS);
    let (engine, _events, store) =
        funded_with("relaunch-unknown.kvlog", &fake, &ctl, vec![held.clone()]).await;
    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let first = fake.submitted().pop().expect("the first at the node");

    // Coins arrive while the app is closed: one larger, two smaller.
    let arrived = vec![
        coin(&receive(), 0x63, 50 * SOMPI_PER_KAS),
        coin(&receive(), 0x64, 3 * SOMPI_PER_KAS / 10),
        coin(&receive(), 0x65, 4 * SOMPI_PER_KAS / 10),
    ];
    let mut node = vec![held];
    node.extend(arrived);
    fake.set_utxos(node);
    let (engine, _events, ctl, _) = relaunched(engine, &fake, &store).await;

    fake.answer_submits(SubmitAnswer::Accept);
    let retry = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((retry.submitted, retry.error.clone()), (1, None));
    let second = fake.submitted().pop().expect("the retry at the node");
    assert!(
        !spends(&first).is_disjoint(&spends(&second)),
        "the retry after a relaunch spends none of the first's coins: both can land"
    );

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A deposit still pending at a close matures after the reopen.** The close
/// clears the processor's pending map and not the context's
/// (`processor.rs:609-615` @ `01b532e`); the reopen's read skips a coin the
/// context's map holds (`context.rs:457`), and the processor promotes only
/// what its own map holds (`:272-283`).
#[tokio::test(flavor = "multi_thread")]
async fn a_deposit_pending_at_a_close_matures_after_the_reopen() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded("pending-across-close.kvlog", &fake, &ctl).await;
    // A deposit at the node's own DAA score: pending for the maturity window.
    let deposit = output_coin(
        &receive(),
        Hash::from_bytes([0x66; 32]),
        0,
        5 * SOMPI_PER_KAS,
        1_000_000,
    );
    let mut node = vec![
        coin(&receive(), 0x51, 10 * SOMPI_PER_KAS),
        coin(&receive(), 0x52, 10 * SOMPI_PER_KAS),
    ];
    node.push(deposit.clone());
    fake.set_utxos(node);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![deposit]),
            removed: Arc::new(vec![]),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the deposit pending", |m, p, _, _| {
        m == 20 * SOMPI_PER_KAS && p == 5 * SOMPI_PER_KAS
    })
    .await;

    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    next_event(&mut events, WAIT, |e| matches!(e, WalletEvent::Syncing))
        .await
        .expect("the reopen's start");
    balance_where(&mut events, "the reopen's read filed", |m, p, _, _| {
        m == 20 * SOMPI_PER_KAS && p == 5 * SOMPI_PER_KAS
    })
    .await;

    past_maturity(&fake).await;
    let matured = balance_where(&mut events, "the deposit matured", |m, _, _, _| {
        m == 25 * SOMPI_PER_KAS
    })
    .await;
    assert_eq!(matured, (25 * SOMPI_PER_KAS, 0, 0, 0));
    assert_eq!(WALLET_CORE_PANICS.load(Ordering::SeqCst), panics_before);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A reopen onto a node whose index trails our own acceptance files no coin
/// we spent.** The send landed and its record was purged a hundred DAA after
/// (`processor.rs:336-349` @ `01b532e`); the reopen reaches a node that has
/// not yet reached that acceptance: it reports an older virtual DAA score and
/// still lists the coin the send spent, with no `UtxosChanged` to come for it
/// until it catches up.
#[tokio::test(flavor = "multi_thread")]
async fn a_reopen_onto_a_trailing_node_files_no_coin_we_spent() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let coins = three_coins();
    let (engine, mut events, store) =
        funded_with("trailing-node.kvlog", &fake, &ctl, coins.clone()).await;
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let sent = fake.submitted().pop().expect("the payment at the node");
    let txid = txid_of(&sent);
    let (left, spent) = left_and_spent(&coins, &sent);
    assert_eq!(left.len(), 1, "the send leaves one coin");
    let (index, change) = output_to(&sent, &receive());
    let homed = output_coin(&receive(), txid, index, change, 1_000_001);
    fake.set_utxos(vec![left[0].clone(), homed.clone()]);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![homed]),
            removed: Arc::new(spent.clone()),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the send landed", |m, _, o, _| {
        o == 0 && m == 10 * SOMPI_PER_KAS + change
    })
    .await;
    // Past the purge of the send's record.
    past_maturity_handled(&fake, &engine).await;

    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");
    // The node at the reopen trails: before the send's acceptance.
    fake.set_virtual_daa_score(999_000);
    let mut trailing = left.clone();
    trailing.extend(spent.iter().cloned());
    fake.set_utxos(trailing);
    let epoch = fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    next_event(&mut events, WAIT, |e| matches!(e, WalletEvent::Syncing))
        .await
        .expect("the reopen's start");
    fake.wait_until("the reopen's read at the node", WAIT, |f| {
        f.utxo_scans(epoch) >= 1
    })
    .await;
    balance_where(&mut events, "the reopen's read filed", |_, _, _, _| true).await;
    for coin in &spent {
        assert!(
            !spendable_holds(&engine, coin).await,
            "a trailing node's listing of a coin we spent was filed as spendable"
        );
    }
    assert!(spendable_holds(&engine, &left[0]).await);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A close that has begun admits no further leg.** The close claims the
/// submit fence from a task of its own, which a busy scheduler can run after
/// the chain's next leg is ready to go: here that claim is held back. The leg
/// released in that window is not admitted (the close has begun, so the lane
/// is not ready) and, with the close unable to finish, is refused at its bound
/// with nothing broadcast. Without the hold it reaches the node and holds the
/// close behind it. Paused time: every wait resolves in a fixed order.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_close_that_has_begun_admits_no_further_leg() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, _) = many_coins();
    let (engine, _events, store) = funded_with("close-begun.kvlog", &fake, &ctl, coins).await;
    let prepared = engine
        .prepare_consolidate(receive(), &[], Arc::new(Unsigned), fake.rpc(ctl.clone()))
        .await
        .expect("a buildable merge");
    let legs = prepared.summary().tx_count as usize;
    assert!(legs >= 2, "the merge must be a chain, built {legs} leg(s)");
    let hold = fake.hold_submits();
    let commit = tokio::spawn(prepared.commit(None));
    fake.wait_until("the first leg at the node", WAIT, |f| {
        f.submitted().len() == 1
    })
    .await;
    let claims = engine.hold_close_claims();
    let closes = engine.closes_begun();
    ctl.signal_close().await.expect("signal close");
    close_begun(&engine, closes).await;
    hold.add_permits(1);
    let outcome = tokio::time::timeout(LANE_HOLD_WITHIN * 2, commit)
        .await
        .expect("the next leg was admitted after the close began and held it")
        .expect("the send's task must not panic");
    assert_eq!(outcome.submitted, 1, "{outcome:?}");
    assert!(
        outcome.error.is_some() && outcome.unanswered.is_none(),
        "{outcome:?}"
    );
    assert_eq!(
        fake.submitted().len(),
        1,
        "a leg reached the node after the close began"
    );

    claims.add_permits(64);
    hold.add_permits(64);
    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A leg in its submit when the app dies still anchors the retry.** Its
/// record is on disk before the request leaves: a copy of the store taken while
/// the node holds the submit, as a crash at that instant leaves it, comes back
/// as a leg that may have left, and a retry of the same payment spends its coin.
#[tokio::test(flavor = "multi_thread")]
async fn a_leg_in_its_submit_at_a_crash_still_anchors_the_retry() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let held = coin(&receive(), 0x51, 10 * SOMPI_PER_KAS);
    let (engine, _events, store) =
        funded_with("crash-in-submit.kvlog", &fake, &ctl, vec![held.clone()]).await;
    let hold = fake.hold_submits();
    let prepared = one_kas(&engine, &fake, &ctl).await;
    let commit = tokio::spawn(prepared.commit(None));
    fake.wait_until("the submit at the node", WAIT, |f| f.submitted().len() == 1)
        .await;
    // The crash: what is on disk while the request is at the node.
    let files = store_bytes(&store);
    let first = fake.submitted().pop().expect("the first at the node");

    let arrived = vec![
        coin(&receive(), 0x63, 50 * SOMPI_PER_KAS),
        coin(&receive(), 0x64, 3 * SOMPI_PER_KAS / 10),
        coin(&receive(), 0x65, 4 * SOMPI_PER_KAS / 10),
    ];
    let mut node = vec![held];
    node.extend(arrived);
    fake.set_utxos(node);
    let (relaunched, _events, ctl_two, _) = relaunched_from(files, &fake, &store).await;
    hold.add_permits(64);
    let _ = commit.await;
    let retry = one_kas(&relaunched, &fake, &ctl_two)
        .await
        .commit(None)
        .await;
    assert_eq!((retry.submitted, retry.error.clone()), (1, None));
    let second = fake.submitted().pop().expect("the retry at the node");
    assert!(
        !spends(&first).is_disjoint(&spends(&second)),
        "the retry after a crash in the submit spends none of its coins: both can land"
    );

    for engine in [engine, relaunched] {
        tokio::time::timeout(Duration::from_secs(10), engine.stop())
            .await
            .expect("stop inside its bound")
            .expect("stop");
    }
    remove_store(&store);
}

/// **The notice that an unanswered payment went through survives a
/// relaunch.** The node's frame proves it landed; the app ends before the
/// person retries; the relaunched wallet refuses the retry once with the
/// news, as it would have without the relaunch.
#[tokio::test(flavor = "multi_thread")]
async fn a_payment_proven_landed_is_named_after_a_relaunch() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let held = coin(&receive(), 0x51, 10 * SOMPI_PER_KAS);
    let (engine, mut events, store) = funded_with(
        "landed-notice-relaunch.kvlog",
        &fake,
        &ctl,
        vec![held.clone()],
    )
    .await;
    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let first = fake.submitted().pop().expect("the first at the node");
    let (index, value) = output_to(&first, &receive());
    let change = output_coin(&receive(), txid_of(&first), index, value, 1_000_001);
    let deposit = coin(&receive(), 0x66, 5 * SOMPI_PER_KAS);
    fake.set_utxos(vec![deposit.clone(), change.clone()]);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![deposit, change]),
            removed: Arc::new(vec![held]),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the frame folded", |m, p, _, _| {
        m + p == 5 * SOMPI_PER_KAS + value
    })
    .await;

    let (engine, _events, ctl, _) = relaunched(engine, &fake, &store).await;
    fake.answer_submits(SubmitAnswer::Accept);
    let refusal = one_kas_refusal(&engine, &fake, &ctl).await;
    assert!(
        matches!(refusal, Some(ChainError::EarlierPaymentWentThrough)),
        "{refusal:?}"
    );
    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A send carried across a relaunch and unaccepted for a day is of unknown
/// fate, not free.** The node that took it keeps an RPC submit for good, so
/// it may still land: its coin returns to the spendable list (nothing stays
/// stuck), drawn last by other builds and spent first by a payment to the
/// same address, so the two conflict.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_carried_for_a_day_anchors_and_is_not_freed() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let held = coin(&receive(), 0x51, 10 * SOMPI_PER_KAS);
    let (engine, _events, store) =
        funded_with("carried-a-day.kvlog", &fake, &ctl, vec![held.clone()]).await;
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let first = fake.submitted().pop().expect("the first at the node");
    let arrived = vec![
        coin(&receive(), 0x63, 50 * SOMPI_PER_KAS),
        coin(&receive(), 0x64, 3 * SOMPI_PER_KAS / 10),
        coin(&receive(), 0x65, 4 * SOMPI_PER_KAS / 10),
    ];
    let mut node = vec![held.clone()];
    node.extend(arrived);
    fake.set_utxos(node);

    let (engine, _events, _ctl, next) = relaunched(engine, &fake, &store).await;
    assert!(
        !spendable_holds(&engine, &held).await,
        "a carried send's coin was filed inside its day"
    );
    // A day passes: the record's own times, aged.
    let path = kaspaverse_chain::sends_path(&next);
    let mut record: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&path).expect("the legs file")).expect("json");
    let legs = record["legs"].as_array_mut().expect("legs");
    assert_eq!(legs.len(), 1, "{legs:?}");
    assert_eq!(legs[0]["state"], "sent");
    legs[0]["since_unix_ms"] = serde_json::json!(1);
    legs[0]["since_daa"] = serde_json::json!(0);
    std::fs::write(&path, serde_json::to_vec(&record).expect("json")).expect("aged");

    let (engine, _events, ctl, _) = relaunched(engine, &fake, &next).await;
    assert!(
        spendable_holds(&engine, &held).await,
        "a send unaccepted for a day kept its coin out for good"
    );
    // Another payment draws it last; one to the same address leads with it.
    let other = kas_to(&engine, &fake, &ctl, payee_two(), SOMPI_PER_KAS)
        .await
        .commit(None)
        .await;
    assert_eq!((other.submitted, other.error.clone()), (1, None));
    let other = fake.submitted().pop().expect("the other payment");
    let id = (held.outpoint.transaction_id, held.outpoint.index);
    assert!(!spends(&other).contains(&id), "another payment led with it");
    let retry = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((retry.submitted, retry.error.clone()), (1, None));
    let retry = fake.submitted().pop().expect("the retry");
    assert!(
        !spends(&first).is_disjoint(&spends(&retry)),
        "a payment to the same address after a day does not conflict with the first"
    );
    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A leg whose record cannot be written is not sent.** The write comes
/// before the request; a failure there (here the store's folder turns
/// read-only after the start, as a full or failing disk refuses a write)
/// refuses the leg with nothing broadcast, in the words approved for it.
#[tokio::test(flavor = "multi_thread")]
async fn a_leg_whose_record_cannot_be_written_is_not_sent() {
    use std::os::unix::fs::PermissionsExt;
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let folder = tmp("unwritable");
    let _ = std::fs::remove_dir_all(&folder);
    std::fs::create_dir_all(&folder).expect("the store's folder");
    let (engine, _events, store) = funded("unwritable/activity.kvlog", &fake, &ctl).await;
    let prepared = one_kas(&engine, &fake, &ctl).await;
    std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o555)).expect("read-only");
    let outcome = prepared.commit(None).await;
    std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o755))
        .expect("writable again");
    assert_eq!(outcome.submitted, 0, "{outcome:?}");
    assert_eq!(
        outcome.error.as_deref(),
        Some("This phone could not save the send first. Try again."),
        "{outcome:?}"
    );
    assert!(outcome.unanswered.is_none(), "{outcome:?}");
    assert!(fake.submitted().is_empty(), "a leg left without its record");
    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
    let _ = std::fs::remove_dir_all(&folder);
}

/// **A young coin a trailing node has not indexed yet proves nothing.** A
/// send spends the change of an earlier one (at the node's own score); a
/// reopen reaches a node that does not list that change yet. The send may
/// still land, so it is not settled, and when the node lists the change its
/// coin stays out.
#[tokio::test(flavor = "multi_thread")]
async fn a_young_input_a_trailing_node_does_not_list_settles_nothing() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded_with(
        "young-input-trailing.kvlog",
        &fake,
        &ctl,
        vec![coin(&receive(), 0x51, 10 * SOMPI_PER_KAS)],
    )
    .await;
    // A send lands; its change is home at once, created at DAA 1_000_001.
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let landed = fake.submitted().pop().expect("the first payment");
    let (index, value) = output_to(&landed, &receive());
    let (_, spent) = split_by(&landed);
    let young = output_coin(&receive(), txid_of(&landed), index, value, 1_000_001);
    fake.set_utxos(vec![young.clone()]);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![young.clone()]),
            removed: Arc::new(spent),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the change home", |m, _, o, _| {
        m == value && o == 0
    })
    .await;
    // A send from that change; the node takes it.
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let second = fake.submitted().pop().expect("the second payment");
    assert!(spends(&second).contains(&(young.outpoint.transaction_id, young.outpoint.index)));
    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");

    // The node at the reopen has not indexed the change yet.
    fake.set_utxos(vec![]);
    let epoch = fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    fake.wait_until("the reopen's read", WAIT, |f| f.utxo_scans(epoch) >= 1)
        .await;
    next_event(&mut events, WAIT, |e| matches!(e, WalletEvent::Syncing))
        .await
        .expect("the reopen's start");
    balance_where(&mut events, "the reopen's read filed", |_, _, _, _| true).await;

    // It indexes it; the second send is still in a mempool. A pull.
    fake.set_utxos(vec![young.clone()]);
    engine.rescan().await.expect("the pull");
    assert!(
        !spendable_holds(&engine, &young).await,
        "a coin a send in flight spends was filed after a trailing node's absence settled it"
    );
    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A merge accepted whole while the socket was down is settled by the
/// reopen's read.** Its later legs spend outputs of its earlier ones, which
/// the pin's Generator builds with no score of their own
/// (`UNACCEPTED_DAA_SCORE`, `wallet/core/src/tx/generator/generator.rs:1233` @
/// `01b532e`): their absence counts once the leg that created them is settled
/// in the same read, parents first. The merged coin is then filed and nothing
/// stays unsettled.
#[tokio::test(flavor = "multi_thread")]
async fn a_merge_accepted_while_closed_is_settled_by_the_reopen() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, mut events, store) = funded_with(
        "merge-landed-while-closed.kvlog",
        &fake,
        &ctl,
        coins.clone(),
    )
    .await;
    let sent = merge_in_flight(&engine, &fake, &ctl).await;
    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");

    // Every leg landed while the socket was down.
    let (node, _, added) = after_landing(&coins, &sent, &by_index, 1_000_001);
    assert_eq!(added.len(), 1, "a merge ends in one coin");
    let merged = added[0].utxo_entry.amount;
    fake.set_utxos(node);
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    next_event(&mut events, WAIT, |e| matches!(e, WalletEvent::Syncing))
        .await
        .expect("the reopen's start");
    let settled = balance_where(
        &mut events,
        "the merge settled by the reopen",
        |m, p, _, u| u == 0 && m + p == merged,
    )
    .await;
    assert_eq!(settled.0 + settled.1, merged);

    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A chain carried across a relaunch keeps every coin it spends out, and
/// settles parents first when it lands.** The merge's legs all reached the
/// node; the app ends before any acceptance. The relaunched wallet files none
/// of the coins the legs spend; once every leg has landed, a pull settles the
/// whole chain from the answer alone and the merged coin is counted.
#[tokio::test(flavor = "multi_thread")]
async fn a_chain_carried_across_a_relaunch_settles_parents_first() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, _events, store) =
        funded_with("chain-relaunch.kvlog", &fake, &ctl, coins.clone()).await;
    let sent = merge_in_flight(&engine, &fake, &ctl).await;
    let spent: HashSet<(Hash, u32)> = sent.iter().flat_map(spends).collect();

    let (engine, mut events, _ctl, _) = relaunched(engine, &fake, &store).await;
    let filed = engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set");
    assert!(
        filed.iter().all(|entry| {
            let id = entry.outpoint.inner();
            !spent.contains(&(id.transaction_id, id.index))
        }),
        "the relaunch filed a coin a carried leg spends"
    );

    let (node, _, added) = after_landing(&coins, &sent, &by_index, 1_000_001);
    let merged = added[0].utxo_entry.amount;
    fake.set_utxos(node);
    engine.rescan().await.expect("the pull");
    let settled = balance_where(
        &mut events,
        "the chain settled by the pull",
        |m, p, _, u| u == 0 && m + p == merged,
    )
    .await;
    assert_eq!(settled.0 + settled.1, merged);
    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// A merge's legs all landed and its merged coin was then spent elsewhere, so
/// the node lists neither the coins the merge spent nor the coin it made: the
/// final leg can be judged only through the batch outputs it spent, whose
/// creators this same answer settles.
fn after_landing_and_spent(
    coins: &[RpcUtxosByAddressesEntry],
    legs: &[RpcTransaction],
    by_index: &std::collections::HashMap<u32, RpcUtxosByAddressesEntry>,
) -> Vec<RpcUtxosByAddressesEntry> {
    let (node, _, added) = after_landing(coins, legs, by_index, 1_000_001);
    let made: HashSet<(Hash, u32)> = added
        .iter()
        .map(|coin| (coin.outpoint.transaction_id, coin.outpoint.index))
        .collect();
    node.into_iter()
        .filter(|coin| !made.contains(&(coin.outpoint.transaction_id, coin.outpoint.index)))
        .collect()
}

/// **A carried chain whose final coin is not listed settles through its
/// parents.** Relaunched after every leg landed and the merged coin was spent
/// elsewhere: the first read settles the earlier legs from their own coins,
/// and the final leg from the batch outputs they made, in one read. Nothing
/// stays carried, so nothing counts as coming home.
#[tokio::test(flavor = "multi_thread")]
async fn a_carried_chain_settles_through_its_parents_when_its_coin_is_gone() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, _events, store) =
        funded_with("chain-relaunch-spent.kvlog", &fake, &ctl, coins.clone()).await;
    let sent = merge_in_flight(&engine, &fake, &ctl).await;
    fake.set_utxos(after_landing_and_spent(&coins, &sent, &by_index));
    let files = store_bytes(&store);
    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    drop(engine);

    // The start's read is the one that must settle it.
    let ctl = RpcCtl::new();
    let next = store.with_file_name("chain-relaunch-spent-run.kvlog");
    remove_store(&next);
    for (path, bytes) in files {
        let to = if path == store {
            next.clone()
        } else if path == kaspaverse_chain::sends_path(&store) {
            kaspaverse_chain::sends_path(&next)
        } else {
            kaspaverse_chain::spent_path(&next)
        };
        std::fs::write(to, bytes).expect("the copied store");
    }
    let engine = WalletEngine::new(
        fake.rpc(ctl.clone()),
        NetworkId::new(NetworkType::Mainnet),
        next.clone(),
    )
    .expect("the relaunched engine");
    let mut events = engine.subscribe();
    engine
        .start(vec![receive(), change()], vec![change()])
        .await
        .expect("engine start");
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal open");
    next_event(&mut events, WAIT, |e| matches!(e, WalletEvent::Syncing))
        .await
        .expect("the relaunched lane's start");
    let first = balance_where(&mut events, "the start's read filed", |_, _, _, _| true).await;
    assert_eq!(
        first,
        (0, 0, 0, 0),
        "a carried leg the answer settles still counts as coming home"
    );
    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
    remove_store(&next);
}

/// **The same on the reopen:** a merge accepted whole while the socket was
/// down, its merged coin spent elsewhere since, is settled by the reopen's
/// read through its parents, with nothing left unsettled.
#[tokio::test(flavor = "multi_thread")]
async fn a_merge_whose_coin_is_gone_is_settled_by_the_reopen_through_its_parents() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, mut events, store) =
        funded_with("merge-gone-while-closed.kvlog", &fake, &ctl, coins.clone()).await;
    let sent = merge_in_flight(&engine, &fake, &ctl).await;
    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");
    fake.set_utxos(after_landing_and_spent(&coins, &sent, &by_index));
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    next_event(&mut events, WAIT, |e| matches!(e, WalletEvent::Syncing))
        .await
        .expect("the reopen's start");
    let settled = balance_where(
        &mut events,
        "the merge settled by the reopen",
        |_, _, o, u| u == 0 && o == 0,
    )
    .await;
    assert_eq!(settled, (0, 0, 0, 0));
    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A cancelled leg's input that another chain of ours built is checked like
/// any other.** A chained payment's final leg, spending only the batch outputs
/// of its earlier legs, gets no answer: a leg of unknown fate. A retry to the
/// same payee leads with those batch outputs and gets no answer either. The
/// pin's cancel puts every input of the retry back on the spendable list
/// (`context.rs:280-291` @ `01b532e`), whether or not the context ever held
/// it; a batch output the context never held must come off again.
#[tokio::test(flavor = "multi_thread")]
async fn a_cancelled_retrys_batch_output_input_does_not_read_as_spendable() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, _) = many_coins();
    let (engine, _events, store) =
        funded_with("retry-on-batch-output.kvlog", &fake, &ctl, coins).await;
    let prepared = kas_to(&engine, &fake, &ctl, payee(), 100 * SOMPI_PER_KAS).await;
    let legs = prepared.summary().tx_count as usize;
    assert!(
        legs >= 2,
        "the payment must be a chain, built {legs} leg(s)"
    );
    let mut answers = vec![SubmitAnswer::Accept; legs - 1];
    answers.push(SubmitAnswer::Fail("WebSocket disconnected".into()));
    fake.queue_submit_answers(answers);
    let outcome = prepared.commit(None).await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let sent = fake.submitted();
    let earlier: HashSet<Hash> = sent[..legs - 1].iter().map(txid_of).collect();
    let last = sent.last().expect("the final leg");
    let batch: Vec<(Hash, u32)> = spends(last)
        .into_iter()
        .filter(|(txid, _)| earlier.contains(txid))
        .collect();
    assert_eq!(
        batch.len(),
        spends(last).len(),
        "the final leg must spend only its earlier legs' outputs"
    );

    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let retry = kas_to(&engine, &fake, &ctl, payee(), 100 * SOMPI_PER_KAS)
        .await
        .commit(None)
        .await;
    assert!(retry.unanswered.is_some(), "{retry:?}");
    let led = fake
        .submitted()
        .last()
        .cloned()
        .expect("the retry at the node");
    assert!(
        spends(&led).iter().any(|coin| batch.contains(coin)),
        "the retry did not lead with the batch outputs"
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
    assert!(
        batch.iter().all(|coin| !spendable.contains(coin)),
        "a batch output no context holds reads as spendable after the cancel"
    );
    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A cancelled retry never writes a batch output's scoreless copy over the
/// one a read filed.** A chained payment's earlier legs land and a read files
/// their batch outputs, young, as pending; its final leg got no answer. A retry
/// to the same payee leads with those outputs as its chain built them (no score
/// of their own, `UNACCEPTED_DAA_SCORE`) and is cancelled. Written over the
/// filed entry, that copy overflows the pin's maturity sum at the next tick
/// (`wallet/core/src/utxo/reference.rs:44` @ `01b532e`); left beside it, the
/// coin counts twice. Neither may happen: the cancel takes the coin out
/// whole, and the next read files it once at its own score.
#[tokio::test(flavor = "multi_thread")]
async fn a_cancelled_retry_takes_out_a_filed_batch_output_until_the_next_read() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, mut events, store) = funded_with(
        "retry-on-filed-batch-output.kvlog",
        &fake,
        &ctl,
        coins.clone(),
    )
    .await;
    let prepared = kas_to(&engine, &fake, &ctl, payee(), 100 * SOMPI_PER_KAS).await;
    let legs = prepared.summary().tx_count as usize;
    assert!(
        legs >= 2,
        "the payment must be a chain, built {legs} leg(s)"
    );
    let mut answers = vec![SubmitAnswer::Accept; legs - 1];
    answers.push(SubmitAnswer::Fail("WebSocket disconnected".into()));
    fake.queue_submit_answers(answers);
    let outcome = prepared.commit(None).await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let sent = fake.submitted();

    // The earlier legs land; a read files their outputs, young.
    let (node, _, made) = after_landing(&coins, &sent[..legs - 1], &by_index, 1_000_001);
    assert!(!made.is_empty(), "the earlier legs made batch outputs");
    fake.set_utxos(node);
    engine.rescan().await.expect("the pull");
    let filed_pending = engine.context().pending_utxo_size();
    assert!(
        filed_pending >= made.len(),
        "the read did not file the batch outputs"
    );

    fake.answer_submits(SubmitAnswer::Fail("WebSocket disconnected".into()));
    let retry = kas_to(&engine, &fake, &ctl, payee(), 100 * SOMPI_PER_KAS)
        .await
        .commit(None)
        .await;
    assert!(retry.unanswered.is_some(), "{retry:?}");
    let made_ids: HashSet<(Hash, u32)> = made
        .iter()
        .map(|c| (c.outpoint.transaction_id, c.outpoint.index))
        .collect();
    let led = fake.submitted().last().cloned().expect("the retry");
    assert!(
        spends(&led).iter().any(|coin| made_ids.contains(coin)),
        "the retry did not lead with the filed batch outputs"
    );

    // A tick, and past maturity: no panic, and each coin counted once.
    past_maturity_handled(&fake, &engine).await;
    assert_eq!(
        WALLET_CORE_PANICS.load(Ordering::SeqCst),
        panics_before,
        "a panic in the pinned wallet framework"
    );
    engine.rescan().await.expect("the pull after the tick");
    let mature = engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set");
    for coin in &made_ids {
        let copies = mature
            .iter()
            .filter(|entry| {
                let id = entry.outpoint.inner();
                (id.transaction_id, id.index) == *coin
            })
            .count();
        assert_eq!(copies, 1, "a batch output counted {copies} times");
    }
    assert_eq!(
        engine.context().pending_utxo_size(),
        0,
        "a pending copy of a batch output stayed beside the mature one"
    );
    let _ = &mut events;
    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A retry that lost to a conflict gives back the batch outputs it led
/// with.** A chained payment's final leg got no answer; its earlier legs land,
/// a read files their batch outputs and they mature. A retry to the same payee
/// leads with them (as its chain built them, with no score of their own) plus
/// coins of its own, and the node takes it. Another spend of one of its own
/// coins lands first: the retry can never land. Its inputs return to the
/// spendable list, the batch outputs among them once a read files them again
/// at their own score.
async fn retry_lost_to_a_conflict(matured: bool, name: &str) {
    let panics_before = WALLET_CORE_PANICS.load(Ordering::SeqCst);
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (coins, by_index) = many_coins();
    let (engine, _events, store) = funded_with(name, &fake, &ctl, coins.clone()).await;
    let prepared = kas_to(&engine, &fake, &ctl, payee(), 100 * SOMPI_PER_KAS).await;
    let legs = prepared.summary().tx_count as usize;
    assert!(
        legs >= 2,
        "the payment must be a chain, built {legs} leg(s)"
    );
    let mut answers = vec![SubmitAnswer::Accept; legs - 1];
    answers.push(SubmitAnswer::Fail("WebSocket disconnected".into()));
    fake.queue_submit_answers(answers);
    let outcome = prepared.commit(None).await;
    assert!(outcome.unanswered.is_some(), "{outcome:?}");
    let sent = fake.submitted();

    // The earlier legs land; a read files their outputs; they mature.
    let (node, _, made) = after_landing(&coins, &sent[..legs - 1], &by_index, 1_000_001);
    let made_ids: HashSet<(Hash, u32)> = made
        .iter()
        .map(|c| (c.outpoint.transaction_id, c.outpoint.index))
        .collect();
    let made_value: u64 = made.iter().map(|c| c.utxo_entry.amount).sum();
    fake.set_utxos(node.clone());
    engine.rescan().await.expect("the pull");
    if matured {
        past_maturity_handled(&fake, &engine).await;
    }

    // A retry larger than the batch outputs: it leads with them and draws
    // coins of its own.
    fake.answer_submits(SubmitAnswer::Accept);
    let retry = kas_to(
        &engine,
        &fake,
        &ctl,
        payee(),
        made_value + 20 * SOMPI_PER_KAS,
    )
    .await
    .commit(None)
    .await;
    assert_eq!(
        (retry.submitted, retry.error.clone()),
        (1, None),
        "{retry:?}"
    );
    let r = fake.submitted().last().cloned().expect("the retry");
    let r_spends = spends(&r);
    assert!(
        made_ids.iter().all(|coin| r_spends.contains(coin)),
        "the retry did not lead with every batch output"
    );
    let own = coins
        .iter()
        .find(|c| r_spends.contains(&(c.outpoint.transaction_id, c.outpoint.index)))
        .cloned()
        .expect("the retry draws a coin of its own");
    let gone = (own.outpoint.transaction_id, own.outpoint.index);

    // Another spend of that coin lands: the retry can never land.
    let after_conflict: Vec<RpcUtxosByAddressesEntry> = node
        .iter()
        .filter(|c| {
            (c.outpoint.transaction_id, c.outpoint.index)
                != (own.outpoint.transaction_id, own.outpoint.index)
        })
        .cloned()
        .collect();
    fake.set_utxos(after_conflict);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![]),
            removed: Arc::new(vec![own]),
        }))
        .await
            >= 1
    );
    // The conflict's own effect: the retry's other coins are spendable again.
    let others: Vec<(Hash, u32)> = coins
        .iter()
        .map(|c| (c.outpoint.transaction_id, c.outpoint.index))
        .filter(|id| r_spends.contains(id) && *id != gone)
        .collect();
    assert!(
        !others.is_empty(),
        "the retry spends other coins of its own"
    );
    tokio::time::timeout(WAIT, async {
        loop {
            let listed: HashSet<(Hash, u32)> = engine
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
            if others.iter().all(|id| listed.contains(id)) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("the retry judged lost to the conflict");
    if !matured {
        // Still young: they went back pending, at their own score, and mature
        // at the next tick past the window with no overflow.
        let mature: HashSet<(Hash, u32)> = engine
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
        assert!(
            made_ids.iter().all(|coin| !mature.contains(coin)),
            "a young batch output went back mature"
        );
        assert!(engine.context().pending_utxo_size() >= made_ids.len());
        past_maturity_handled(&fake, &engine).await;
        assert_eq!(engine.context().pending_utxo_size(), 0);
    }
    // Once a read files them, the batch outputs are spendable again, once each.
    engine.rescan().await.expect("the pull after the conflict");
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
    assert!(
        made_ids.iter().all(|coin| spendable.contains(coin)),
        "a batch output the lost retry led with is in no list"
    );
    let listed = engine
        .context()
        .get_utxos(None, None)
        .await
        .expect("the spendable set");
    for coin in &made_ids {
        let copies = listed
            .iter()
            .filter(|entry| {
                let id = entry.outpoint.inner();
                (id.transaction_id, id.index) == *coin
            })
            .count();
        assert_eq!(copies, 1, "a batch output counted {copies} times");
    }
    // At their own score: never the scoreless copy the retry carried.
    assert!(
        listed
            .iter()
            .filter(|entry| {
                let id = entry.outpoint.inner();
                made_ids.contains(&(id.transaction_id, id.index))
            })
            .all(|entry| entry.block_daa_score == 1_000_001),
        "a batch output filed at the retry's scoreless copy"
    );
    assert_eq!(WALLET_CORE_PANICS.load(Ordering::SeqCst), panics_before);
    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}

/// **A retry that lost to a conflict gives back the batch outputs it led
/// with**, once they have matured: as a read files them again.
#[tokio::test(flavor = "multi_thread")]
async fn a_retry_lost_to_a_conflict_gives_back_the_batch_outputs_it_led_with() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    retry_lost_to_a_conflict(true, "retry-lost-batch-output.kvlog").await;
}

/// **The same while they are young**: they go back pending at their own
/// score, never with the scoreless copy the retry carried, and mature at the
/// next tick past the window.
#[tokio::test(flavor = "multi_thread")]
async fn a_retry_lost_to_a_conflict_gives_back_young_batch_outputs_pending() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    retry_lost_to_a_conflict(false, "retry-lost-young-batch-output.kvlog").await;
}

/// **A send whose own change a read lists has landed, however young the coin it
/// spent.** It spends the change of an earlier send, too young for a node's
/// absence to prove anything; it lands while the socket is down. The reopen's
/// read lists its change (a node's index holds accepted transactions only): it
/// is settled as landed, its change is filed, and the young coin it spent is
/// kept as spent, so a node that has not reached that acceptance cannot hand it
/// back as spendable.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_whose_change_a_read_lists_has_landed_though_its_input_is_young() {
    let _serial = SERIAL.lock().await;
    count_wallet_core_panics();
    let fake = mainnet_fake();
    let ctl = RpcCtl::new();
    let (engine, mut events, store) = funded_with(
        "listed-landed-young.kvlog",
        &fake,
        &ctl,
        vec![coin(&receive(), 0x51, 10 * SOMPI_PER_KAS)],
    )
    .await;
    // A send lands; its change is home at once, created at DAA 1_000_001.
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let first = fake.submitted().pop().expect("the first payment");
    let (index, value) = output_to(&first, &receive());
    let (_, spent) = split_by(&first);
    let young = output_coin(&receive(), txid_of(&first), index, value, 1_000_001);
    fake.set_utxos(vec![young.clone()]);
    assert!(
        fake.deliver(Notification::UtxosChanged(UtxosChangedNotification {
            added: Arc::new(vec![young.clone()]),
            removed: Arc::new(spent),
        }))
        .await
            >= 1
    );
    balance_where(&mut events, "the change home", |m, _, o, _| {
        m == value && o == 0
    })
    .await;
    // A send from that change; it lands while the socket is down.
    let outcome = one_kas(&engine, &fake, &ctl).await.commit(None).await;
    assert_eq!((outcome.submitted, outcome.error.clone()), (1, None));
    let second = fake.submitted().pop().expect("the second payment");
    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");
    let (index, change) = output_to(&second, &receive());
    let homed = output_coin(&receive(), txid_of(&second), index, change, 1_000_002);
    fake.set_utxos(vec![homed.clone()]);
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    next_event(&mut events, WAIT, |e| matches!(e, WalletEvent::Syncing))
        .await
        .expect("the reopen's start");
    balance_where(
        &mut events,
        "the second send settled by its listed change",
        |m, p, o, u| o == 0 && u == 0 && m + p == change,
    )
    .await;

    // Past the window, the pin purges its record of the send
    // (`processor.rs:336-349` @ `01b532e`): only the kept spent coin remains.
    past_maturity_handled(&fake, &engine).await;
    // A node that has not reached that acceptance lists the young coin again.
    ctl.signal_close().await.expect("signal close");
    next_event(&mut events, WAIT, |e| {
        matches!(e, WalletEvent::Disconnected)
    })
    .await
    .expect("the processor's disconnect");
    fake.set_virtual_daa_score(1_000_000);
    fake.set_utxos(vec![young.clone()]);
    fake.begin_epoch();
    ctl.signal_open().await.expect("signal reopen");
    next_event(&mut events, WAIT, |e| matches!(e, WalletEvent::Syncing))
        .await
        .expect("the trailing reopen's start");
    // Young at that node's score, a coin filed by mistake would be pending:
    // the read's own balance shows it either way.
    let trailing = balance_where(&mut events, "the trailing read filed", |_, _, _, _| true).await;
    assert_eq!(
        trailing,
        (change, 0, 0, 0),
        "a trailing node handed back a coin a landed send of ours spent"
    );
    assert!(!spendable_holds(&engine, &young).await);
    tokio::time::timeout(Duration::from_secs(10), engine.stop())
        .await
        .expect("stop inside its bound")
        .expect("stop");
    remove_store(&store);
}
