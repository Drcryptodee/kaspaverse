//! Wallet UTXO sync — balance + activity for a derived address set, over the
//! wRPC client SHARED with the P0 [`DagMonitor`] (P1 §0.8 / D-005: one
//! `UtxoProcessor`, one `UtxoContext`, joining the monitor's connection — never
//! a second socket, so the header DAA and the wallet's maturity DAA can never
//! diverge).
//!
//! INV-9 — every byte of UTXO/balance/maturity logic is consumed from the
//! pinned `kaspa-wallet-core` (rev `cfafeb4c` = v2.0.1, D-058), never re-implemented.
//! The wiring mirrors the worked example `wallet/core/src/utxo/test.rs:9`
//! (processor → context → scan_and_register) and the subscription loop in
//! `wallet/core/src/api/transport.rs:210` (`multiplexer().channel()` →
//! `receiver.recv()`). Balance fields pass through verbatim from
//! `Events::Balance` (`utxo/balance.rs:97`); the direction/maturity of an
//! activity row come from `TransactionRecord`'s own helpers
//! (`storage/transaction/record.rs:391/411/418`) — nothing is computed locally.
//!
//! INV-3 — the activity store persists only public chain data (txids, amounts,
//! DAA scores) to an app-private file; no secret type is reachable from this
//! module (it never sees a seed or keychain — the bridge hands it public
//! [`Address`]es only).

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError};

use borsh::{BorshDeserialize, BorshSerialize};
use kaspa_addresses::{Address, Prefix};
use kaspa_txscript::extract_script_pub_key_address;
use kaspa_wallet_core::events::Events;
use kaspa_wallet_core::rpc::Rpc;
use kaspa_wallet_core::storage::transaction::{TransactionData, TransactionId, TransactionRecord};
use kaspa_wallet_core::utxo::{
    Maturity, NetworkParams, UtxoContext, UtxoContextBinding, UtxoProcessor,
};
use kaspa_wrpc_client::prelude::{NetworkId, NetworkType};
use tokio::sync::{broadcast, oneshot};

use crate::error::{ChainError, Result};

/// **The maturity thresholds this wallet actually applies**, read from the
/// pinned wallet framework's own `NetworkParams` for the network in hand.
///
/// INV-9 in its plainest form: `100` and `1,000` are **not** typed anywhere in
/// this project. They are `user_transaction_maturity_period_daa` and
/// `coinbase_transaction_maturity_period_daa`, both `AtomicU64` fields the
/// library exposes per network (`wallet/core/src/utxo/settings.rs`), and both
/// are read here so that a re-pin which changes either one changes what the
/// glass says on the same build. D-249 made this a bridge concern precisely
/// because the UI had been carrying its own copies of the pair.
///
/// The pin's devnet values (`10 / 100`) are a live reminder of why: they are
/// exactly the numbers D-248 mistook for arbitrary.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MaturityParams {
    /// A payment someone else sends us is excluded from the spendable balance
    /// and from coin selection until it is this many DAA deep (D-251: this is
    /// wallet-core's client-side policy, not a consensus rule).
    pub user_daa: u64,
    /// A mined coinbase output matures at this depth — and this one IS
    /// consensus (`coinbase_maturity`), mirrored by the library.
    pub coinbase_daa: u64,
    /// The window before a coinbase is even counted as pending. Carried so a
    /// reader of this struct never has to look the third number up separately.
    pub coinbase_stasis_daa: u64,
}

/// Read [`MaturityParams`] for a network. Pure, no I/O, no lock held across an
/// await — the library's own statics answer it.
///
/// **A testnet id without a supported suffix is refused here rather than left
/// to a caller's discipline** (`consensus-auditor`, UX-R3): `NetworkParams::from`
/// `panic!`s on it, and this is a `pub fn` reached from a `#[frb(sync)]` bridge
/// entry point — a panic must never cross that boundary (INV-2). Unreachable
/// today, since the wallet is mainnet-only, and that is exactly when a guard is
/// cheap to add and expensive to have skipped.
pub fn maturity_params(network_id: NetworkId) -> Result<MaturityParams> {
    let supported = match network_id.network_type {
        NetworkType::Testnet => matches!(network_id.suffix, Some(10) | Some(12)),
        _ => true,
    };
    if !supported {
        return Err(ChainError::Message(format!(
            "no maturity parameters for network {network_id}"
        )));
    }
    let params = NetworkParams::from(network_id);
    Ok(MaturityParams {
        user_daa: params.user_transaction_maturity_period_daa(),
        coinbase_daa: params.coinbase_transaction_maturity_period_daa(),
        coinbase_stasis_daa: params.coinbase_transaction_stasis_period_daa(),
    })
}

/// Most rows the feed carries — "recent activity", not full history (§0.10).
const ACTIVITY_CAP: usize = 100;

/// Direction of an activity row, mapped from the wallet-core
/// [`TransactionData`] variant. Receive-only at P1.5; `Outgoing`/`Change`
/// rows appear once send lands (P1.6).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivityDirection {
    Incoming,
    Outgoing,
    Change,
}

/// Maturity of an activity row, from `TransactionRecord::maturity()` evaluated
/// at the latest DAA (`record.rs:391` — Pending until the DAA-based maturity
/// period elapses, then Confirmed). Stasis collapses into Pending (coinbase
/// stasis is never surfaced as a user row).
///
/// `Unknown` is the V2b honesty state (finding 13): a receive folded while the
/// processor has NO live DAA yet (the cold-start boot emit) cannot be
/// classified — calling it Pending made hours-settled history masquerade as
/// in-flight and stream huge counters. Unknown renders quiet; the first
/// DAA-bearing fold (or the V1 acceptance overlay) resolves it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivityMaturity {
    Pending,
    Confirmed,
    Unknown,
}

/// A single activity row — the chain-layer projection of a wallet-core
/// [`TransactionRecord`]. Plain public fields; the bridge maps this 1:1 onto
/// the FFI DTO (wallet-core types never reach the FFI surface).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WalletActivityRecord {
    pub txid: String,
    pub value_sompi: u64,
    pub unixtime_msec: Option<u64>,
    pub block_daa_score: u64,
    /// DAA score at which the DAG ACCEPTED this spend (`None` for a receive, or
    /// a spend not yet accepted). The honest anchor for a send's confirmation-
    /// depth counter — `current_daa − accepted_daa_score` is true depth from
    /// acceptance, where `block_daa_score` on a send is only submit time and
    /// would overstate. Surfaced from `TransactionData::Outgoing` (pin).
    pub accepted_daa_score: Option<u64>,
    pub direction: ActivityDirection,
    pub is_coinbase: bool,
    pub maturity: ActivityMaturity,
    /// **Who the money went to** — the one output of OUR OWN spend that is not
    /// our change, in bech32. `None` on a receive, and that absence is a fact
    /// about the pin rather than a gap in this code: see [`counterparty_of`].
    pub counterparty_address: Option<String>,
    /// **What the network charged for this transaction**, in sompi — the pin's
    /// own `fees` field on a spend we originated. `None` on a receive, because
    /// a receive did not pay it: the sender did, and the amount that reached us
    /// is already net of it. Rendering `0` there would be a confident wrong
    /// number about someone's money (`S9` draws the row on a spend).
    pub fee_sompi: Option<u64>,
}

/// A folded wallet event. Values are absolute (like [`crate::DagEvent`]), so the
/// bridge's snapshot fold is plain assignment (INV-9 — nothing computed there).
#[derive(Debug, Clone, PartialEq)]
pub enum WalletEvent {
    /// wRPC (re)connected; `url` is the resolver-picked endpoint.
    Connected { url: Option<String> },
    /// wRPC disconnected (the shared client keeps retrying).
    Disconnected,
    /// `UtxoProcStart` — the processor is initialised; the initial scan begins.
    Syncing,
    /// The connected node has no UTXO index — sync cannot proceed on it
    /// (INV-8: surface honestly, never a silent zero).
    UtxoIndexMissing { url: Option<String> },
    /// Absolute balance (sompi). Receiving this — even all-zero — means a real
    /// sync completed: an empty wallet resolves to a live `0`, never unknown.
    Balance {
        mature: u64,
        pending: u64,
        outgoing: u64,
    },
    /// The full current activity list, newest-first (capped at [`ACTIVITY_CAP`]).
    Activity(Vec<WalletActivityRecord>),
    /// A non-fatal processor error (safe to surface; safe to ignore).
    Error(String),
}

/// The amount a wallet-originated send displays: the PAYMENT that left the wallet
/// (`payment_value`), or — for a sweep with no payment output — the net outflow
/// (inputs − change). NEVER the change that returns to us. Pure; unit-tested.
fn spend_value(payment_value: Option<u64>, aggregate_input: u64, change_value: u64) -> u64 {
    payment_value.unwrap_or_else(|| aggregate_input.saturating_sub(change_value))
}

/// True iff every UTXO sits at one of our CHANGE addresses (and there is at
/// least one). A UTXO at a change address is always our own change returning —
/// never a deposit, since change addresses are internal and never handed out.
/// Pure; unit-tested. An unknown (`None`) address is NOT assumed to be change.
fn all_change_addresses(addresses: &[Option<Address>], change_set: &HashSet<Address>) -> bool {
    !addresses.is_empty()
        && addresses
            .iter()
            .all(|a| a.as_ref().is_some_and(|a| change_set.contains(a)))
}

/// A record wallet-core classifies as a receive (an inbound deposit or an
/// externally-observed credit). The two shapes a re-scan can wrongly attach to
/// one of OUR txids after losing outgoing context.
fn is_incoming_data(record: &TransactionRecord) -> bool {
    matches!(
        record.transaction_data(),
        TransactionData::Incoming { .. } | TransactionData::External { .. }
    )
}

/// A spend shape that carries the network **fee** on the pin's own typed data.
///
/// `TransactionData::Change` is the odd one out and it is the *terminal* shape
/// of every send that returns change: at acceptance the processor emits BOTH a
/// fresh `Outgoing` (`handle_utxo_removed` → `new_outgoing`) and a `Change`
/// (`handle_utxo_added` → `new_change`), and `new_change` has **no `fees`
/// field**. Letting the second overwrite the first therefore erased the fee at
/// the moment the send was accepted, and — because the replayed log holds the
/// `Change` — no historical send ever showed one again (`consensus-auditor`,
/// UX-R3).
fn carries_fee(record: &TransactionRecord) -> bool {
    matches!(
        record.transaction_data(),
        TransactionData::Outgoing { .. }
            | TransactionData::Batch { .. }
            | TransactionData::TransferOutgoing { .. }
    )
}

/// A record wallet-core classifies as a spend WE originated. If we already hold
/// a txid in one of these shapes, that txid is ours — a later incoming
/// re-report of it is stale context, never a new deposit ([`ActivityStore::upsert`]).
fn is_outgoing_data(record: &TransactionRecord) -> bool {
    matches!(
        record.transaction_data(),
        TransactionData::Outgoing { .. }
            | TransactionData::Change { .. }
            | TransactionData::Batch { .. }
            | TransactionData::TransferOutgoing { .. }
    )
}

/// Whether a record is our own change re-reported as an incoming deposit. After
/// a restart, wallet-core loses its in-memory "this was my send" context, so a
/// re-scan files our returning change as an `Incoming` (`context.rs`
/// handle_utxo_added, `outgoing()` = None). Such a record is NOT a deposit — its
/// UTXOs are all at our change addresses (device find 2026-06-15). The txid-
/// provenance guard in [`ActivityStore::upsert`] now catches the same class when
/// the returning change lands on the conversation-bound RECEIVE address (D2);
/// this address-set check remains for a cold re-scan that never saw the send.
fn is_own_change(record: &TransactionRecord, change_set: &HashSet<Address>) -> bool {
    let utxos = match record.transaction_data() {
        TransactionData::Incoming { utxo_entries, .. }
        | TransactionData::External { utxo_entries, .. } => utxo_entries,
        // Outgoing/Change/Batch are handled as sends; only an incoming-classified
        // record can be our misfiled change.
        _ => return false,
    };
    let addresses: Vec<Option<Address>> = utxos.iter().map(|u| u.address.clone()).collect();
    all_change_addresses(&addresses, change_set)
}

/// **Who the money went to, for a spend WE originated** — or `None`, honestly.
///
/// ## Which output is "to", and the premise that was wrong
///
/// **Every output that is not at one of OUR OWN addresses is a payment, and
/// there must be exactly one of them.**
///
/// The first cut of this said *"not at one of our own **change** addresses"*,
/// reasoning that change is the only output a send makes to itself. **D-067
/// broke that construction and `consensus-auditor` caught it**:
/// `payment_change_address()` is `Branch::Receive, 0` — this wallet's change
/// goes *home* to the receive branch so the address stays funded for the next
/// `input[0]` — while `change_set` is built from the change branch alone
/// (`derive_wallet_addresses` returns `(receive ++ change, change)`). So an
/// ordinary payment presented **two** non-change outputs, the loop found a
/// second payment and returned `None`, and the field was empty on every
/// ordinary send. The tests missed it because they paid change to a change-set
/// address — a shape production never produces.
///
/// Classifying against the **whole watched window** fixes it whichever branch
/// change lands on, and it is the set that actually means *ours*.
///
/// Two payment outputs is a send with two recipients and has no single
/// counterparty; zero means every output came home, which is a send that paid
/// nobody outside this wallet. Both answer `None` rather than picking a
/// favourite — a row that names the wrong recipient is worse than one that
/// names none, because the name is what a user checks a repeat send against.
///
/// ## Why a receive carries none
///
/// A receive's counterparty would be an **input**, and the *record* does not
/// hold one: `TransactionData::Incoming` / `External` carry `utxo_entries`,
/// which are the outputs paid **to us**. So it cannot be answered from the
/// record the way a spend's can, and this function says nothing rather than
/// guessing.
///
/// **That is a limit of the record, not of the app** (`consensus-auditor`): the
/// node can answer it — `resolve_return_address` already asks
/// `get_utxo_return_address` for `input[0]`'s previous-output address at the
/// accepting chain block, and `WalletEngine::activity_daa_score` exists to feed
/// it exactly that. Naming a sender is therefore a *second lookup* someone may
/// choose to spend, not a door that is closed. It is not spent here.
///
/// The address is derived with `extract_script_pub_key_address` — the same call
/// the receive scan and `send.rs` use — at the prefix of the record's **own**
/// `network_id`, never a prefix assumed here.
fn counterparty_of(record: &TransactionRecord, ours: &HashSet<Address>) -> Option<String> {
    let transaction = match record.transaction_data() {
        TransactionData::Outgoing { transaction, .. }
        | TransactionData::TransferOutgoing { transaction, .. }
        | TransactionData::Change { transaction, .. } => transaction,
        // Batch is the compounding leg of a chained send: it pays no one but
        // the next leg, so naming a recipient for it would be a fiction.
        // Incoming / External / Reorg / Stasis carry no inputs at all.
        _ => return None,
    };
    let prefix = Prefix::from(record.network_id().network_type);
    let mut payment: Option<String> = None;
    for output in transaction.outputs.iter() {
        let address = match extract_script_pub_key_address(&output.script_public_key, prefix) {
            Ok(address) => address,
            // A script we cannot render as an address is not a counterparty we
            // can name. It is also not proof there is only one payment, so it
            // counts as one: an unnamed second recipient must still collapse
            // the answer to `None`.
            Err(_) => return None,
        };
        if ours.contains(&address) {
            continue;
        }
        if payment.is_some() {
            // Two recipients on one transaction — no single counterparty.
            return None;
        }
        payment = Some(address.to_string());
    }
    payment
}

/// Project a wallet-core record onto a row, classifying with the record's own
/// helpers (INV-9). `current_daa_score` drives maturity — pass the processor's
/// live DAA so a reloaded Pending row promotes the instant the chain advances.
/// `None` (no DAA yet — the pre-connect boot emit) classifies receives as
/// [`ActivityMaturity::Unknown`], never a guessed Pending (finding 13: the
/// cold-start confirmation storm was `unwrap_or(0)` here — with DAA 0 every
/// settled receive re-pended and the glass streamed its huge DAA distance).
fn map_record(
    record: &TransactionRecord,
    current_daa_score: Option<u64>,
    ours: &HashSet<Address>,
) -> WalletActivityRecord {
    // A transaction the wallet ORIGINATED (a send) reaches us as TWO records on
    // one txid: an `Outgoing` (pending, on submit) and — when the change UTXO
    // confirms — a `Change` record (wallet-core, context.rs:handle_utxo_added).
    // Both must render as ONE outgoing row showing the PAYMENT (`payment_value`),
    // never the change that returns to us (== the new balance; not a receive).
    // And a send is Confirmed the moment the DAG ACCEPTS it (`accepted_daa_score`)
    // — NOT when its change UTXO separately matures (that left sends stuck on
    // "Pending" until the next event). `record.value()` (= change for a `Change`
    // record) is wrong for this row; we read the typed data instead.
    // The fee is on the typed data for every shape we originated, and on none
    // of the shapes we merely received (INV-9 — read, never computed here: an
    // inputs-minus-outputs subtraction would be a second implementation of a
    // number the library already holds).
    let fee_sompi = match record.transaction_data() {
        TransactionData::Outgoing { fees, .. }
        | TransactionData::Batch { fees, .. }
        | TransactionData::TransferOutgoing { fees, .. } => Some(*fees),
        // `Change` is the same txid re-reported once its change UTXO confirms
        // and it carries no `fees` field at the pin — so a send whose feed row
        // arrives in that shape has no fee to state, and says nothing rather
        // than a zero.
        _ => None,
    };
    let (direction, value_sompi, spend_accepted, accepted_daa_score) =
        match record.transaction_data() {
            TransactionData::Outgoing {
                payment_value,
                aggregate_input_value,
                change_value,
                accepted_daa_score,
                ..
            }
            | TransactionData::Change {
                payment_value,
                aggregate_input_value,
                change_value,
                accepted_daa_score,
                ..
            }
            | TransactionData::TransferOutgoing {
                payment_value,
                aggregate_input_value,
                change_value,
                accepted_daa_score,
                ..
            } => (
                ActivityDirection::Outgoing,
                spend_value(*payment_value, *aggregate_input_value, *change_value),
                Some(accepted_daa_score.is_some()),
                *accepted_daa_score,
            ),
            // Internal compounding leg of a >100k-mass chained send.
            TransactionData::Batch {
                aggregate_input_value,
                accepted_daa_score,
                ..
            } => (
                ActivityDirection::Change,
                *aggregate_input_value,
                Some(accepted_daa_score.is_some()),
                *accepted_daa_score,
            ),
            // Incoming / External / TransferIncoming: a receive (Reorg/Stasis never
            // reach the feed — the engine tombstones / ignores them).
            _ => (ActivityDirection::Incoming, record.value(), None, None),
        };

    let maturity = match (spend_accepted, current_daa_score) {
        // A spend: Confirmed once the DAG accepts it; Pending until then.
        // (Acceptance is persisted in the record — no live DAA needed.)
        (Some(accepted), _) if accepted => ActivityMaturity::Confirmed,
        (Some(_), _) => ActivityMaturity::Pending,
        // A receive: matures over the UTXO maturity period (INV-9 — the record's
        // own helper at the live DAA, never our own threshold).
        (None, Some(daa)) => match record.maturity(daa) {
            Maturity::Confirmed => ActivityMaturity::Confirmed,
            Maturity::Pending | Maturity::Stasis => ActivityMaturity::Pending,
        },
        // A receive with no live DAA: honestly unresolved (finding 13).
        (None, None) => ActivityMaturity::Unknown,
    };

    WalletActivityRecord {
        txid: record.id().to_string(),
        value_sompi,
        unixtime_msec: record.unixtime_msec(),
        block_daa_score: record.block_daa_score(),
        accepted_daa_score,
        direction,
        is_coinbase: record.is_coinbase(),
        maturity,
        counterparty_address: counterparty_of(record, ours),
        fee_sompi,
    }
}

/// One persisted frame in the append-only activity log. `Upsert` carries a full
/// wallet-core record (its own borsh codec, with a storage magic/version);
/// `Remove` is a reorg tombstone keyed by txid (so replay reconstructs a
/// removal without rewriting the file).
#[derive(BorshSerialize, BorshDeserialize)]
enum StoreFrame {
    // Boxed: borsh serializes `Box<T>` byte-identically to `T` (no on-disk
    // change), and it keeps the enum small (clippy::large_enum_variant — the
    // record is ~400 bytes, the tombstone 32).
    Upsert(Box<TransactionRecord>),
    Remove(TransactionId),
}

/// Length-prefix a frame for the append-only log: `[u32 LE len][borsh body]`.
fn frame_bytes(frame: &StoreFrame) -> Result<Vec<u8>> {
    let body = borsh::to_vec(frame)
        .map_err(|e| crate::error::ChainError::Message(format!("activity encode: {e}")))?;
    let mut out = Vec::with_capacity(4 + body.len());
    out.extend_from_slice(&(body.len() as u32).to_le_bytes());
    out.extend_from_slice(&body);
    Ok(out)
}

/// Replay an append-only log into the live record set (last-write-wins per txid;
/// tombstones remove). Tolerates a torn final frame (a crash mid-append loses at
/// most the last record, which the next live event re-emits) and a corrupt body
/// (stops, keeping everything decoded so far).
fn replay(bytes: &[u8]) -> HashMap<TransactionId, TransactionRecord> {
    let mut records = HashMap::new();
    let mut cursor = bytes;
    while cursor.len() >= 4 {
        let len = u32::from_le_bytes([cursor[0], cursor[1], cursor[2], cursor[3]]) as usize;
        cursor = &cursor[4..];
        if cursor.len() < len {
            break; // torn tail — stop
        }
        let (body, rest) = cursor.split_at(len);
        cursor = rest;
        match StoreFrame::try_from_slice(body) {
            Ok(StoreFrame::Upsert(record)) => {
                let id = *record.id();
                records.insert(id, *record);
            }
            Ok(StoreFrame::Remove(id)) => {
                records.remove(&id);
            }
            Err(_) => break, // corrupt frame — keep what we have
        }
    }
    records
}

/// Append-only activity store in an app-private file (§0.10). Public chain data
/// only (INV-3). The in-memory map is the source of truth for the feed; the
/// file is its durable replay log.
struct ActivityStore {
    path: PathBuf,
    records: HashMap<TransactionId, TransactionRecord>,
}

impl ActivityStore {
    /// Load by replaying the log; a missing file is an empty store.
    fn load(path: PathBuf) -> Result<Self> {
        let records = match std::fs::read(&path) {
            Ok(bytes) => replay(&bytes),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => HashMap::new(),
            Err(e) => return Err(e.into()),
        };
        Ok(Self { path, records })
    }

    fn append(&self, frame: &StoreFrame) -> Result<()> {
        use std::io::Write;
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        file.write_all(&frame_bytes(frame)?)?;
        file.sync_all()?;
        Ok(())
    }

    /// Returns whether the record was written (`false` = refused by the
    /// provenance guard below) so the caller's log line can say which — the
    /// finding-8 discriminating lane (V2).
    fn upsert(&mut self, record: TransactionRecord) -> Result<bool> {
        // Provenance guard (D2/P4): once we hold a txid as a SEND we originated
        // (Outgoing / Change / Batch / TransferOutgoing), a later re-scan that
        // re-reports the SAME txid as an Incoming/External deposit is the
        // lost-outgoing-context phenomenon (context.rs handle_utxo_added, restart
        // re-scan), NOT a new receive — refuse the downgrade. Without this,
        // conversation change returning to the bound RECEIVE address (source
        // discipline routes it there, so the address stays funded for the next
        // input[0]) would surface as a phantom "received" row after a restart.
        // The address-set heuristic ([`is_own_change`]) can't catch it — the
        // bound address is a receive address, and marking receive addresses
        // internal would hide REAL deposits to them. Txid provenance is exact:
        // a genuine deposit or a counterpart's bond refund carries THEIR txid,
        // never one we already filed as outgoing.
        if is_incoming_data(&record) {
            if let Some(existing) = self.records.get(record.id()) {
                if is_outgoing_data(existing) {
                    return Ok(false);
                }
            }
        }
        // **Fee guard (UX-R3, `consensus-auditor`): a `Change` never overwrites
        // a richer shape for the same txid.**
        //
        // `Change` carries the same `transaction`, `payment_value`,
        // `change_value` and `accepted_daa_score` as the `Outgoing` it follows,
        // and one field less — `fees`. Both arrive from a single
        // `handle_utxo_changed` at acceptance, removed-then-added, so the held
        // record is already the accepted one and is strictly the better of the
        // two. Refusing the downgrade keeps the fee without recomputing it,
        // which is what INV-9 asks for: an inputs-minus-outputs subtraction here
        // would be a second implementation of a number the library holds.
        //
        // A send discovered only by a cold re-scan still arrives as a bare
        // `Change` with nothing held, is stored normally, and honestly has no
        // fee to state — the row says nothing rather than zero.
        if matches!(record.transaction_data(), TransactionData::Change { .. }) {
            if let Some(existing) = self.records.get(record.id()) {
                if carries_fee(existing) {
                    return Ok(false);
                }
            }
        }
        self.append(&StoreFrame::Upsert(Box::new(record.clone())))?;
        self.records.insert(*record.id(), record);
        Ok(true)
    }

    fn remove(&mut self, id: &TransactionId) -> Result<()> {
        if self.records.remove(id).is_some() {
            self.append(&StoreFrame::Remove(*id))?;
        }
        Ok(())
    }

    /// Newest-first rows, capped, with maturity resolved at `current_daa_score`
    /// (`None` — no live DAA yet — resolves receives as Unknown, finding 13).
    /// Hides any record that is our own returning change misfiled as an incoming
    /// (cleans entries a pre-fix restart re-scan may have already persisted).
    /// `change_set` decides which rows are our own misfiled change; `ours` — the
    /// **whole** watched window — decides which output of a spend is the payee.
    /// They are different sets on purpose and the difference is load-bearing:
    /// this wallet's change comes home to a RECEIVE address (D-067), so the
    /// change subset cannot tell a payee from our own change.
    fn list(
        &self,
        current_daa_score: Option<u64>,
        change_set: &HashSet<Address>,
        ours: &HashSet<Address>,
    ) -> Vec<WalletActivityRecord> {
        let mut records: Vec<&TransactionRecord> = self
            .records
            .values()
            .filter(|record| !is_own_change(record, change_set))
            .collect();
        records.sort_by(|a, b| {
            b.block_daa_score()
                .cmp(&a.block_daa_score())
                .then(b.unixtime_msec().cmp(&a.unixtime_msec()))
        });
        records
            .into_iter()
            .take(ACTIVITY_CAP)
            .map(|record| map_record(record, current_daa_score, ours))
            .collect()
    }
}

struct Inner {
    processor: UtxoProcessor,
    context: UtxoContext,
    events: broadcast::Sender<WalletEvent>,
    store: Mutex<ActivityStore>,
    event_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    shutdown: Mutex<Option<oneshot::Sender<()>>>,
    /// The watched address window — kept so [`WalletEngine::rescan`] can re-ask
    /// the node for the SAME set the balance reflects, and so a reconnect
    /// re-registers the CURRENT window rather than the one `start()` happened to
    /// be given (public strings only, INV-3).
    ///
    /// `Arc` because the fold task reads it on every event and
    /// [`WalletEngine::extend_watch`] replaces it wholesale: readers take a
    /// cheap snapshot, never a lock held across an await.
    watch: Mutex<Arc<Vec<Address>>>,
    /// The change subset of [`Inner::watch`] — a UTXO here is our own returning
    /// change, never a deposit (D-043). Widens with the watch set, or a change
    /// address discovered after `start()` would be filed as an incoming deposit.
    change_set: Mutex<Arc<HashSet<Address>>>,
}

/// Drives one [`UtxoProcessor`] + [`UtxoContext`] over a shared [`Rpc`], folding
/// the wallet framework's event stream into [`WalletEvent`]s and persisting
/// observed records. Clone-able; one engine per unlocked vault.
#[derive(Clone)]
pub struct WalletEngine {
    inner: Arc<Inner>,
}

impl WalletEngine {
    /// Bind a processor to the shared `rpc` (from [`crate::DagMonitor::rpc`]).
    /// One `UtxoContext` = one account (P1 §0.8). `store_path` is an app-private
    /// file for the activity log (INV-3).
    pub fn new(rpc: Rpc, network_id: NetworkId, store_path: PathBuf) -> Result<Self> {
        let processor = UtxoProcessor::new(Some(rpc), Some(network_id), None, None);
        let context = UtxoContext::new(&processor, UtxoContextBinding::default());
        let store = ActivityStore::load(store_path)?;
        let (events, _) = broadcast::channel(256);
        Ok(Self {
            inner: Arc::new(Inner {
                processor,
                context,
                events,
                store: Mutex::new(store),
                event_task: Mutex::new(None),
                shutdown: Mutex::new(None),
                watch: Mutex::new(Arc::new(Vec::new())),
                change_set: Mutex::new(Arc::new(HashSet::new())),
            }),
        })
    }

    /// A snapshot of the current watched window. Taken by value (an `Arc` bump)
    /// so no lock is ever held across an await — `clippy::await_holding_lock`.
    fn watched(&self) -> Arc<Vec<Address>> {
        self.inner
            .watch
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// A snapshot of the current change subset. Same discipline as
    /// [`WalletEngine::watched`].
    fn change_set(&self) -> Arc<HashSet<Address>> {
        self.inner
            .change_set
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// A new receiver onto the folded event fan-out.
    pub fn subscribe(&self) -> broadcast::Receiver<WalletEvent> {
        self.inner.events.subscribe()
    }

    /// The spendable UTXO source, for send construction (P1.6 [`crate::send`]).
    /// A clone shares the SAME underlying context (Arc) — the exact watched set
    /// the balance reflects, so a send spends only what the UI shows as mature.
    pub fn context(&self) -> UtxoContext {
        self.inner.context.clone()
    }

    /// DAA score at which a recorded activity tx was accepted — for incoming
    /// records this is the UTXO entry's acceptance score (wallet-core
    /// `new_incoming_impl`, pin record.rs:496: `utxos[0].utxo.block_daa_score`),
    /// which is exactly what the node's `get_utxo_return_address` lookup keys
    /// on (P2.3 sender resolution). `None` while the pipeline has not yet
    /// recorded the tx — the caller surfaces "still confirming", never guesses.
    pub fn activity_daa_score(&self, txid: &str) -> Option<u64> {
        let id: TransactionId = txid.parse().ok()?;
        self.inner
            .store
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .records
            .get(&id)
            .map(|record| record.block_daa_score())
    }

    /// What `txid` actually PAID US, in sompi — `None` unless we hold it as a
    /// receive.
    ///
    /// For an incoming record the pinned crate sets `value` to
    /// `aggregate_input_value`, the sum of the UTXO amounts credited to our own
    /// `UtxoContext` (`wallet/core/src/storage/transaction/record.rs:488-518`
    /// @ `cfafeb4`) — so this is node truth about value received, not a claim
    /// from a payload. Deliberately `None` for anything [`is_incoming_data`]
    /// rejects: `value` means something different on a record we originated
    /// (change, or the aggregate we spent), and reading it as a receive is how
    /// a self-send would look like someone paying us.
    ///
    /// Exists because accepting a handshake SPENDS: it refunds a bond nobody
    /// had checked was ever received.
    pub fn activity_value_sompi(&self, txid: &str) -> Option<u64> {
        let id: TransactionId = txid.parse().ok()?;
        self.inner
            .store
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .records
            .get(&id)
            .filter(|record| is_incoming_data(record))
            .map(|record| record.value())
    }

    /// Start watching `addresses` (the derived receive+change window — public
    /// strings derived by the bridge from the unlocked vault; this layer never
    /// sees a secret). Spawns the fold task and starts the processor; if the
    /// shared client is already connected the processor fires `UtxoProcStart`
    /// immediately (`processor.rs:704`), which triggers the initial scan.
    ///
    /// Must be called from within a tokio runtime (FRB's). `change_addresses` is
    /// the change subset of `addresses` — used to recognise our own returning
    /// change (a UTXO there is never a deposit) so a restart re-scan doesn't
    /// misfile it as an incoming.
    pub async fn start(
        &self,
        addresses: Vec<Address>,
        change_addresses: Vec<Address>,
    ) -> Result<()> {
        // Register on the Events multiplexer BEFORE start() so a synchronous
        // UtxoProcStart on an already-connected client is buffered, not missed.
        let channel = self.inner.processor.multiplexer().channel();
        let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
        *self
            .inner
            .shutdown
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(shutdown_tx);

        // The window lives in `Inner`, not in this task's captures: discovery
        // can widen it after start (`extend_watch`), and a fold task holding a
        // private copy would keep re-registering the narrow set on every
        // reconnect — the widening would silently undo itself.
        *self
            .inner
            .watch
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Arc::new(addresses);
        *self
            .inner
            .change_set
            .lock()
            .unwrap_or_else(PoisonError::into_inner) =
            Arc::new(change_addresses.into_iter().collect());

        // Emit the PERSISTED activity once at start (2026-07-09 V1 sitting
        // find): record events are the only other emission trigger, and a
        // boot where every UTXO is settled own-change fires none — the list
        // rendered "No recent activity" while activity.kvlog held the full
        // history. Earlier boots masked this behind instant Discovery events.
        self.emit_activity(&self.change_set());

        let engine = self.clone();
        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    // Drain events before honoring shutdown (mirrors the
                    // upstream biased select in processor.rs:710).
                    biased;
                    msg = channel.receiver.recv() => {
                        match msg {
                            Ok(event) => engine.handle_event(*event).await,
                            Err(_) => break, // multiplexer closed
                        }
                    }
                    _ = &mut shutdown_rx => break,
                }
            }
            // Hold the channel for the whole loop so the multiplexer keeps our
            // subscription registered; drop it explicitly on exit.
            drop(channel);
        });
        *self
            .inner
            .event_task
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(task);

        self.inner.processor.start().await?;
        Ok(())
    }

    /// In-place node re-ask (V6 soft pull-refresh, amending the V3 pull heal
    /// — register item 12): re-fetch the watched window's UTXO set over the
    /// LIVE connection using the pin's own scan primitive — the same
    /// `scan_and_register_addresses` call the `UtxoProcStart` arm makes
    /// (INV-9; the known-address filter only gates the subscription half,
    /// the UTXO fetch always runs the full list). No socket drop, no
    /// `UtxoProcStart`, no beacon flicker; Balance/Discovery events flow
    /// through the normal fold. Errs when the engine hasn't started or the
    /// processor has no live DAA — callers treat an `Err` as "soft path
    /// unavailable" and escalate to the hard reconnect.
    pub async fn rescan(&self) -> Result<()> {
        let addresses = self.watched();
        if addresses.is_empty() {
            return Err(ChainError::Message("wallet engine not started".into()));
        }
        let count = addresses.len();
        self.inner
            .context
            .scan_and_register_addresses(addresses.as_ref().clone(), None)
            .await?;
        log::info!("wallet-sync: in-place rescan re-asked the node for {count} addresses");
        Ok(())
    }

    /// Widen the watched window to `addresses` and register the newly-added
    /// ones. Returns how many addresses were added (0 = the window already
    /// covered them).
    ///
    /// **Why this exists.** Address discovery runs against a socket that may not
    /// be up yet, so the window `start()` freezes can be the pre-discovery one.
    /// When a later pass finds funds deeper than that, widening the *derivation*
    /// alone is a half-fix: the `UtxoContext` only reports UTXOs for addresses
    /// registered with it, so the coins stay invisible until the next process.
    /// Watch ⊆ sign still holds — the signer is rebuilt per send from the same
    /// persisted marks, and those only grow.
    ///
    /// Additive at the pin, and safe on overlap either way: the context filters
    /// out addresses it already holds (`context.rs:704-727`) and
    /// `extend_from_scan` inserts only vacant UTXO ids (`context.rs:447-480`).
    ///
    /// The wider set is published BEFORE the network call, so a registration
    /// that fails (e.g. the processor has no DAA yet — `MissingDaaScore`) still
    /// heals: the next `UtxoProcStart` and every `rescan()` re-ask the node for
    /// whatever `watch` currently holds.
    pub async fn extend_watch(
        &self,
        addresses: Vec<Address>,
        change_addresses: Vec<Address>,
    ) -> Result<usize> {
        let previous = self.watched();
        if previous.is_empty() {
            return Err(ChainError::Message("wallet engine not started".into()));
        }
        // Structurally a WIDENING, not a replacement. The caller derives the new
        // set from marks that only grow, so `previous ⊆ addresses` holds today —
        // but "holds today by convention" is exactly what made the original
        // window bug possible, and the cost of being wrong here is a watched
        // address dropped from the set the balance reflects. Refuse instead.
        let proposed: HashSet<&Address> = addresses.iter().collect();
        if let Some(dropped) = previous.iter().find(|a| !proposed.contains(a)) {
            return Err(ChainError::Message(format!(
                "refusing to narrow the watch window: {} would be dropped",
                dropped.short(8)
            )));
        }
        let known: HashSet<&Address> = previous.iter().collect();
        let added: Vec<Address> = addresses
            .iter()
            .filter(|a| !known.contains(*a))
            .cloned()
            .collect();
        if added.is_empty() {
            return Ok(0);
        }
        let (total, count) = (addresses.len(), added.len());
        *self
            .inner
            .watch
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Arc::new(addresses);
        *self
            .inner
            .change_set
            .lock()
            .unwrap_or_else(PoisonError::into_inner) =
            Arc::new(change_addresses.into_iter().collect());
        self.inner
            .context
            .scan_and_register_addresses(added, None)
            .await?;
        log::info!(
            "wallet-sync: watch window widened by {count} to {total} addresses (late discovery)"
        );
        Ok(count)
    }

    /// Stop the processor and drain the fold task (e.g. on vault lock — the
    /// shared wRPC socket stays up, owned by the DagMonitor).
    pub async fn stop(&self) -> Result<()> {
        self.inner.processor.stop().await?;
        // Take both handles out from under their locks BEFORE awaiting — never
        // hold a std MutexGuard across an await (clippy::await_holding_lock;
        // mirrors dag_monitor.rs:148).
        let shutdown = self
            .inner
            .shutdown
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(tx) = shutdown {
            let _ = tx.send(());
        }
        let task = self
            .inner
            .event_task
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(task) = task {
            let _ = task.await;
        }
        Ok(())
    }

    fn emit(&self, event: WalletEvent) {
        // Fails only with zero receivers — fine to drop.
        let _ = self.inner.events.send(event);
    }

    /// The processor's live DAA — `None` until it has connected and synced
    /// (never a fabricated 0: with DAA 0 every receive classifies Pending,
    /// the finding-13 storm).
    fn current_daa(&self) -> Option<u64> {
        self.inner.processor.current_daa_score()
    }

    fn emit_activity(&self, change_set: &HashSet<Address>) {
        let daa = self.current_daa();
        // **The whole watched window, not the change subset** — see
        // [`counterparty_of`]. Built here rather than held in `Inner` because
        // `watch` widens mid-session (`extend_watch`) and a cached set would go
        // stale exactly when discovery found the addresses that matter; the
        // build is a few dozen clones beside a fold that already re-derives an
        // address per output.
        let ours: HashSet<Address> = self.watched().iter().cloned().collect();
        let list = self
            .inner
            .store
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .list(daa, change_set, &ours);
        self.emit(WalletEvent::Activity(list));
    }

    /// Fold one wallet-framework event. The watched window and its change
    /// subset are read from `Inner` per event rather than captured at start:
    /// discovery may widen them mid-session and every arm below must see the
    /// current fact, not the one this task was born with.
    async fn handle_event(&self, event: Events) {
        let addresses = self.watched();
        let addresses = addresses.as_slice();
        let change_set = self.change_set();
        let change_set = change_set.as_ref();
        match event {
            Events::UtxoProcStart => {
                self.emit(WalletEvent::Syncing);
                log::info!(
                    "wallet-sync: utxo-proc start — scanning {} addresses",
                    addresses.len()
                );
                // Re-arm the LIVE UtxosChanged subscription on THIS connection
                // (V4 sitting conviction, D-083). The pin's per-connect listener
                // subscribes ONLY VirtualDaaScoreChanged (processor.rs:624);
                // UtxosChanged is issued inside register_addresses — but the
                // context filters against its own address set (context.rs:714),
                // which SURVIVES a disconnect (cleanup() clears the processor
                // map, not the context set), so on every reconnect the filtered
                // list is empty and the node is never re-subscribed: the wallet
                // goes deaf to live deposits after the first drop. Calling the
                // processor-level register_addresses directly is unconditional
                // (map insert + start_notify while connected) and idempotent
                // node-side; the context scan below then extends UTXO state.
                let arc_addresses: Vec<Arc<Address>> =
                    addresses.iter().cloned().map(Arc::new).collect();
                match self
                    .inner
                    .processor
                    .register_addresses(arc_addresses, &self.inner.context)
                    .await
                {
                    // Logged on success ONLY (wallet-security audit nit): a
                    // failed re-arm must never print an "armed" line — this
                    // lane exists to diagnose exactly that deafness.
                    Ok(()) => log::info!(
                        "wallet-sync: live utxos-changed re-armed for {} addresses",
                        addresses.len()
                    ),
                    Err(e) => self.emit(WalletEvent::Error(e.to_string())),
                }
                // Register the address window and fetch the initial UTXO set;
                // this drives Discovery + Balance events (the latter even for an
                // empty wallet → a live zero). DAA is already stored by
                // handle_connect_impl (processor.rs:529) before UtxoProcStart.
                if let Err(e) = self
                    .inner
                    .context
                    .scan_and_register_addresses(addresses.to_vec(), None)
                    .await
                {
                    self.emit(WalletEvent::Error(e.to_string()));
                }
            }
            Events::Connect { url, .. } => self.emit(WalletEvent::Connected { url }),
            Events::Disconnect { .. } => self.emit(WalletEvent::Disconnected),
            Events::UtxoIndexNotEnabled { url } => {
                log::warn!(
                    "wallet-sync: node has no UTXO index ({host:?}) — degrading honestly (INV-8)",
                    host = url.as_deref().map(crate::link::endpoint_host)
                );
                self.emit(WalletEvent::UtxoIndexMissing { url });
            }
            Events::Balance { balance, .. } => {
                let (mature, pending, outgoing) = balance
                    .map(|b| (b.mature, b.pending, b.outgoing))
                    .unwrap_or((0, 0, 0));
                // Public chain data (sompi) — lets a "stuck/wrong balance" report
                // be diagnosed from logcat; never a secret (INV-3).
                log::info!(
                    "wallet-sync: balance mature={mature} pending={pending} outgoing={outgoing} sompi"
                );
                self.emit(WalletEvent::Balance {
                    mature,
                    pending,
                    outgoing,
                });
            }
            Events::Pending { record }
            | Events::Maturity { record }
            | Events::Discovery { record } => {
                // Our own change re-reported as an incoming deposit (a restart
                // re-scan lost the outgoing context) is never a deposit — don't
                // record it (the spend's own record already represents the tx).
                //
                // Every verdict is logged (public chain data, INV-3): the V1
                // sitting's live-deposit miss (finding 8) was undiagnosable
                // because this arm was silent — balance lines proved the fold
                // task alive, but nothing said whether a record event ever
                // arrived or which guard ate it.
                let txid = record.id().to_string();
                if is_own_change(&record, change_set) {
                    log::info!(
                        "wallet-sync: record txid={txid} verdict=own-change (not a deposit)"
                    );
                    return;
                }
                let written = {
                    let mut store = self
                        .inner
                        .store
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner);
                    match store.upsert(record) {
                        Ok(written) => written,
                        Err(e) => {
                            log::warn!("wallet-sync: activity append failed: {e}");
                            false
                        }
                    }
                };
                log::info!(
                    "wallet-sync: record txid={txid} verdict={}",
                    if written {
                        "recorded"
                    } else {
                        "provenance-refused"
                    }
                );
                self.emit_activity(change_set);
            }
            Events::Reorg { record } => {
                log::info!("wallet-sync: reorg — removing tx {}", record.id());
                {
                    let mut store = self
                        .inner
                        .store
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner);
                    if let Err(e) = store.remove(record.id()) {
                        log::warn!("wallet-sync: activity tombstone failed: {e}");
                    }
                }
                self.emit_activity(change_set);
            }
            // Coinbase stasis is never a user row (events.rs:185).
            Events::Stasis { .. } => {}
            // The witness for D-101's armed trigger. `UtxoProcError` is the
            // processor's CONNECT-negotiation failure (pin `processor.rs`
            // emits it only from `handle_connect`'s error arm and the ctl
            // task's connect handler) — the one case whose automatic recovery
            // R4 deliberately did not wire, because the pin's own
            // force-disconnect is no longer reachable through the link's
            // stable handle. It must be greppable in OUR lane, naming the
            // endpoint, or the trigger cannot fire from a capture: the pin's
            // own error line carries neither endpoint nor bind.
            Events::UtxoProcError { message } => {
                // HOST only (§19 drain). `RpcCtl::descriptor()` is the FULL wRPC
                // URL — the pin sets it from `options.url` verbatim
                // (`client.rs:243,443`) — so a token-auth path segment would
                // land in logcat here too. The D-101 trigger greps for the
                // endpoint being NAMED, which the host still does.
                let endpoint = self
                    .inner
                    .processor
                    .try_rpc_ctl()
                    .and_then(|ctl| ctl.descriptor());
                log::warn!(
                    "wallet-sync: processor connect negotiation failed on {} — \
                     the wallet lane is dark on this socket until it drops or the \
                     user reconnects (D-101 trigger)",
                    endpoint
                        .as_deref()
                        .map_or("<no endpoint>", crate::link::endpoint_host)
                );
                self.emit(WalletEvent::Error(message))
            }
            Events::Error { message } => self.emit(WalletEvent::Error(message)),
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaspa_wallet_core::storage::Binding;
    use kaspa_wallet_core::utxo::UtxoContextId;
    use kaspa_wrpc_client::prelude::{NetworkId, NetworkType};

    fn incoming(id_byte: u8, value: u64, daa: u64) -> TransactionRecord {
        record(
            id_byte,
            value,
            daa,
            TransactionData::Incoming {
                utxo_entries: vec![],
                aggregate_input_value: value,
            },
        )
    }

    /// An Outgoing record for `id_byte` — a send WE originated. Minimal empty
    /// `Transaction` (the classifier reads the variant + values, not the tx).
    fn outgoing(id_byte: u8, payment: u64, daa: u64) -> TransactionRecord {
        use kaspa_consensus_core::subnets::SUBNETWORK_ID_NATIVE;
        use kaspa_consensus_core::tx::Transaction as CoreTx;
        let tx = CoreTx::new(0, vec![], vec![], 0, SUBNETWORK_ID_NATIVE, 0, vec![]);
        record(
            id_byte,
            payment,
            daa,
            TransactionData::Outgoing {
                fees: 1000,
                aggregate_input_value: payment + 5000,
                aggregate_output_value: payment,
                transaction: tx,
                payment_value: Some(payment),
                change_value: 4000,
                accepted_daa_score: Some(daa),
                utxo_entries: vec![],
            },
        )
    }

    fn record(id_byte: u8, value: u64, daa: u64, data: TransactionData) -> TransactionRecord {
        TransactionRecord {
            id: TransactionId::from_bytes([id_byte; 32]),
            unixtime_msec: Some(1_700_000_000_000 + daa),
            value,
            binding: Binding::Custom(UtxoContextId::default()),
            block_daa_score: daa,
            network_id: NetworkId::new(NetworkType::Mainnet),
            transaction_data: data,
            note: None,
            metadata: None,
        }
    }

    /// An Outgoing record whose transaction pays the given addresses.
    fn outgoing_paying(id_byte: u8, to: &[(&Address, u64)]) -> TransactionRecord {
        use kaspa_consensus_core::subnets::SUBNETWORK_ID_NATIVE;
        use kaspa_consensus_core::tx::{Transaction as CoreTx, TransactionOutput};
        use kaspa_txscript::pay_to_address_script;
        let outputs: Vec<TransactionOutput> = to
            .iter()
            .map(|(a, v)| TransactionOutput::new(*v, pay_to_address_script(a)))
            .collect();
        let tx = CoreTx::new(0, vec![], outputs, 0, SUBNETWORK_ID_NATIVE, 0, vec![]);
        record(
            id_byte,
            1_000,
            10,
            TransactionData::Outgoing {
                fees: 1234,
                aggregate_input_value: 10_000,
                aggregate_output_value: 9_000,
                transaction: tx,
                payment_value: Some(1_000),
                change_value: 8_000,
                accepted_daa_score: Some(10),
                utxo_entries: vec![],
            },
        )
    }

    fn mainnet_address(tag: u8) -> Address {
        Address::new(
            Prefix::Mainnet,
            kaspa_addresses::Version::PubKey,
            &[tag; 32],
        )
    }

    #[test]
    fn maturity_params_are_the_pin_s_own_numbers() {
        // INV-9 in its plainest form: these are read from the library's
        // `NetworkParams`, not typed by us. Mainnet is 100 / 1,000 (+500
        // stasis); devnet's 10 / 100 is the pair D-248 mistook for arbitrary.
        let mainnet = maturity_params(NetworkId::new(NetworkType::Mainnet)).unwrap();
        assert_eq!(mainnet.user_daa, 100);
        assert_eq!(mainnet.coinbase_daa, 1_000);
        assert_eq!(mainnet.coinbase_stasis_daa, 500);

        let devnet = maturity_params(NetworkId::new(NetworkType::Devnet)).unwrap();
        assert_eq!(devnet.user_daa, 10);
        assert_eq!(devnet.coinbase_daa, 100);
        assert_ne!(
            mainnet.user_daa, devnet.user_daa,
            "the read must vary by network, or it is a constant with extra steps"
        );

        // **A testnet suffix the library has no parameters for is REFUSED, not
        // panicked through a `#[frb(sync)]` boundary** (INV-2). `NetworkId::new`
        // panics on a bare testnet before we are reached at all, so the case
        // this guard actually owns is a well-formed id with an unsupported
        // suffix — which is what `NetworkParams::from` panics on.
        assert!(maturity_params(NetworkId::with_suffix(NetworkType::Testnet, 99)).is_err());
        assert!(maturity_params(NetworkId::with_suffix(NetworkType::Testnet, 10)).is_ok());
    }

    #[test]
    fn counterparty_is_the_one_output_that_is_not_ours() {
        let payee = mainnet_address(1);
        let change = mainnet_address(2);
        let ours: HashSet<Address> = [change.clone()].into_iter().collect();

        let rec = outgoing_paying(9, &[(&payee, 1_000), (&change, 8_000)]);
        assert_eq!(
            counterparty_of(&rec, &ours),
            Some(payee.to_string()),
            "the payment output is the counterparty; our own output is not"
        );
    }

    #[test]
    fn change_coming_home_to_a_receive_address_is_still_ours() {
        // **The defect `consensus-auditor` BLOCKed, as a test.** D-067 sends
        // this wallet's change HOME to `receive/0`, so the change-branch subset
        // does not contain it — classifying against that subset left an
        // ordinary payment with two "non-change" outputs and no counterparty at
        // all. This is the production shape: change at a RECEIVE address, and a
        // change subset that does not mention it.
        let payee = mainnet_address(1);
        let receive_zero = mainnet_address(7);
        let change_branch = mainnet_address(2);

        let ours: HashSet<Address> = [receive_zero.clone(), change_branch.clone()]
            .into_iter()
            .collect();
        let change_subset: HashSet<Address> = [change_branch].into_iter().collect();
        assert!(
            !change_subset.contains(&receive_zero),
            "precondition: change comes home OUTSIDE the change branch (D-067)"
        );

        let rec = outgoing_paying(15, &[(&payee, 1_000), (&receive_zero, 8_000)]);
        assert_eq!(
            counterparty_of(&rec, &ours),
            Some(payee.to_string()),
            "an ordinary send must name its payee"
        );
        assert_eq!(
            counterparty_of(&rec, &change_subset),
            None,
            "and this is what the change subset alone would have answered"
        );
    }

    #[test]
    fn two_recipients_have_no_single_counterparty() {
        let a = mainnet_address(1);
        let b = mainnet_address(3);
        let change = mainnet_address(2);
        let ours: HashSet<Address> = [change.clone()].into_iter().collect();

        let rec = outgoing_paying(10, &[(&a, 500), (&b, 500), (&change, 8_000)]);
        assert_eq!(
            counterparty_of(&rec, &ours),
            None,
            "a row that names the WRONG recipient is worse than one that names none"
        );
    }

    #[test]
    fn a_send_entirely_to_our_own_addresses_names_nobody() {
        // Every output came home. There is no counterparty outside this wallet
        // to name, and inventing one from our own address set would be a row
        // claiming a payee that does not exist.
        let mine = mainnet_address(7);
        let change = mainnet_address(2);
        let ours: HashSet<Address> = [mine.clone(), change.clone()].into_iter().collect();
        let rec = outgoing_paying(16, &[(&mine, 1_000), (&change, 8_000)]);
        assert_eq!(counterparty_of(&rec, &ours), None);
    }

    #[test]
    fn a_sweep_that_kept_nothing_back_has_no_change_and_one_payee() {
        let payee = mainnet_address(1);
        let rec = outgoing_paying(11, &[(&payee, 9_000)]);
        assert_eq!(
            counterparty_of(&rec, &HashSet::new()),
            Some(payee.to_string()),
        );
    }

    #[test]
    fn a_receive_has_no_counterparty_and_that_is_the_pin_s_shape() {
        // `TransactionData::Incoming` holds the outputs paid TO US; the funding
        // inputs are not in the record at any point, so the sender is not
        // knowable from the RECORD. (The node can answer it — see the doc.)
        let rec = incoming(12, 500, 10);
        assert_eq!(counterparty_of(&rec, &HashSet::new()), None);
    }

    /// A `Change` record for the SAME txid as an `Outgoing` — the terminal
    /// shape wallet-core emits when the change UTXO confirms. It carries no
    /// `fees` field at the pin.
    fn change_leg(id_byte: u8, to: &[(&Address, u64)]) -> TransactionRecord {
        use kaspa_consensus_core::subnets::SUBNETWORK_ID_NATIVE;
        use kaspa_consensus_core::tx::{Transaction as CoreTx, TransactionOutput};
        use kaspa_txscript::pay_to_address_script;
        let outputs: Vec<TransactionOutput> = to
            .iter()
            .map(|(a, v)| TransactionOutput::new(*v, pay_to_address_script(a)))
            .collect();
        let tx = CoreTx::new(0, vec![], outputs, 0, SUBNETWORK_ID_NATIVE, 0, vec![]);
        record(
            id_byte,
            1_000,
            10,
            TransactionData::Change {
                aggregate_input_value: 10_000,
                aggregate_output_value: 9_000,
                transaction: tx,
                payment_value: Some(1_000),
                change_value: 8_000,
                accepted_daa_score: Some(10),
                utxo_entries: vec![],
            },
        )
    }

    #[test]
    fn a_change_leg_never_erases_the_fee_of_the_send_it_follows() {
        // **The defect `consensus-auditor` found, as a test.** At acceptance the
        // processor emits an `Outgoing` (carrying `fees`) and then a `Change`
        // (carrying none) for one txid, both through `handle_utxo_changed`. With
        // the later one overwriting the earlier, the fee showed for the mempool
        // window and vanished at exactly the moment the send was accepted — and
        // because the replayed log held the `Change`, no historical send ever
        // showed a fee again.
        let payee = mainnet_address(1);
        let dir = std::env::temp_dir().join(format!("kv-wsync-fee-{}", std::process::id()));
        let path = dir.join("activity.kvlog");
        let _ = std::fs::remove_file(&path);
        let mut store = ActivityStore::load(path.clone()).unwrap();

        assert!(store
            .upsert(outgoing_paying(0xF1, &[(&payee, 1_000)]))
            .unwrap());
        assert!(
            !store.upsert(change_leg(0xF1, &[(&payee, 1_000)])).unwrap(),
            "the poorer terminal shape is refused, not written"
        );

        let rows = store.list(Some(50), &HashSet::new(), &HashSet::new());
        assert_eq!(rows.len(), 1, "one send, one row");
        assert_eq!(rows[0].fee_sompi, Some(1234), "the fee survives acceptance");
        assert_eq!(
            rows[0].counterparty_address,
            Some(payee.to_string()),
            "and so does everything else the richer record carried"
        );

        // A send discovered ONLY by a cold re-scan arrives as a bare `Change`
        // with nothing held: it is stored normally and honestly has no fee.
        let _ = std::fs::remove_file(&path);
        let mut cold = ActivityStore::load(path).unwrap();
        assert!(cold.upsert(change_leg(0xF2, &[(&payee, 1_000)])).unwrap());
        let rows = cold.list(Some(50), &HashSet::new(), &HashSet::new());
        assert_eq!(
            rows[0].fee_sompi, None,
            "nothing to state, so it states nothing"
        );
    }

    #[test]
    fn the_fee_is_the_pin_s_own_field_and_a_receive_has_none() {
        let payee = mainnet_address(1);
        let spend = map_record(
            &outgoing_paying(13, &[(&payee, 1_000)]),
            Some(50),
            &HashSet::new(),
        );
        assert_eq!(
            spend.fee_sompi,
            Some(1234),
            "read from TransactionData::Outgoing::fees, never recomputed"
        );
        let deposit = map_record(&incoming(14, 500, 10), Some(50), &HashSet::new());
        assert_eq!(
            deposit.fee_sompi, None,
            "a receive did not pay the fee — the sender did, and a zero here \
             would be a confident wrong number"
        );
    }

    #[test]
    fn replay_applies_upserts_and_tombstones() {
        let a = incoming(1, 100, 10);
        let b = incoming(2, 200, 20);
        let mut log = Vec::new();
        log.extend(frame_bytes(&StoreFrame::Upsert(Box::new(a.clone()))).unwrap());
        log.extend(frame_bytes(&StoreFrame::Upsert(Box::new(b.clone()))).unwrap());
        log.extend(frame_bytes(&StoreFrame::Remove(*a.id())).unwrap());

        let records = replay(&log);
        assert_eq!(records.len(), 1, "the tombstoned record is gone");
        assert!(records.contains_key(b.id()));
        assert!(!records.contains_key(a.id()));
    }

    #[test]
    fn replay_overwrites_in_place_on_reupsert() {
        // A Pending then a Maturity for the same txid: last write wins, one row.
        let pending = incoming(7, 500, 100);
        let matured = incoming(7, 500, 100);
        let mut log = Vec::new();
        log.extend(frame_bytes(&StoreFrame::Upsert(Box::new(pending))).unwrap());
        log.extend(frame_bytes(&StoreFrame::Upsert(Box::new(matured))).unwrap());
        assert_eq!(replay(&log).len(), 1);
    }

    #[test]
    fn replay_tolerates_a_torn_tail() {
        let a = incoming(1, 100, 10);
        let mut log = frame_bytes(&StoreFrame::Upsert(Box::new(a.clone()))).unwrap();
        // A second frame that claims 40 bytes but only 3 follow (crash mid-append).
        log.extend_from_slice(&40u32.to_le_bytes());
        log.extend_from_slice(&[9, 9, 9]);

        let records = replay(&log);
        assert_eq!(records.len(), 1, "the intact first frame survives");
        assert!(records.contains_key(a.id()));
    }

    #[test]
    fn map_record_classifies_incoming_and_maturity() {
        // Mainnet user-tx maturity period is 100 DAA (utxo/settings.rs).
        let rec = incoming(3, 1_234, 1_000);

        let pending = map_record(&rec, Some(1_050), &HashSet::new());
        assert_eq!(pending.direction, ActivityDirection::Incoming);
        assert_eq!(pending.maturity, ActivityMaturity::Pending);
        assert_eq!(pending.value_sompi, 1_234);
        assert!(!pending.is_coinbase);
        assert_eq!(pending.block_daa_score, 1_000);
        assert_eq!(pending.txid.len(), 64, "txid is 32-byte hash hex");

        let confirmed = map_record(&rec, Some(1_200), &HashSet::new());
        assert_eq!(confirmed.maturity, ActivityMaturity::Confirmed);

        // Finding 13 (the cold-start confirmation storm): NO live DAA must
        // resolve a receive as Unknown — never a guessed Pending that lets
        // hours-settled history stream in-flight counters at boot.
        let unknown = map_record(&rec, None, &HashSet::new());
        assert_eq!(unknown.maturity, ActivityMaturity::Unknown);
    }

    #[test]
    fn a_send_displays_the_payment_not_the_returning_change() {
        // The device bug (2026-06-15): a 0.42 KAS send whose ~0.39 change returns
        // to us must show 0.42 — never the change (which equals the new balance).
        // wallet-core's `Change` record has `value() == change_value`, so we must
        // read `payment_value` from the typed data instead.
        let payment = 42_000_000; // 0.42 KAS sent
        let change = 39_284_000; // ~0.393 KAS returned as change
        let input = payment + change + 716_000; // inputs cover payment + change + fee
        assert_eq!(
            spend_value(Some(payment), input, change),
            payment,
            "a send shows the payment, not the change"
        );
        // A sweep (no payment output) shows the net outflow = inputs − change.
        assert_eq!(spend_value(None, input, change), input - change);
    }

    #[test]
    fn own_change_addresses_are_recognised_not_treated_as_deposits() {
        // The device bug (2026-06-15): after a restart, wallet-core re-files our
        // returning change as an `Incoming`. A UTXO at a CHANGE address is never
        // a deposit (change addresses are internal, never handed out).
        let change = Address::try_from(
            "kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692",
        )
        .unwrap();
        let receive = Address::try_from(
            "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf",
        )
        .unwrap();
        let change_set: HashSet<Address> = [change.clone()].into_iter().collect();

        assert!(
            all_change_addresses(&[Some(change.clone())], &change_set),
            "a UTXO at our change address is our own change"
        );
        assert!(
            !all_change_addresses(&[Some(receive)], &change_set),
            "a UTXO at a receive address is a real deposit"
        );
        assert!(
            !all_change_addresses(&[Some(change), None], &change_set),
            "an unknown-address UTXO is never assumed to be our change"
        );
        assert!(
            !all_change_addresses(&[], &change_set),
            "no UTXOs ⇒ not our change"
        );
    }

    /// The bond check's load-bearing half: `activity_value_sompi` answers ONLY
    /// for records wallet-core classifies as a receive.
    ///
    /// Accepting a handshake refunds 0.2 KAS to an address resolved from the
    /// counterparty's own transaction. Nothing verified that transaction ever
    /// paid us, so a dust transaction carrying a handshake payload earned the
    /// refund — defection paid (D-019). The guard is only as good as this
    /// accessor, and the trap is `value`: on a record WE originated it is the
    /// payment or the aggregate we spent, so reading it as a receive would let
    /// one of our own sends vouch for a stranger.
    #[test]
    fn activity_value_answers_for_receives_and_refuses_for_our_own_sends() {
        // Exactly the handshake bond, paid to us.
        let deposit = incoming(0xB0, 20_000_000, 2_000);
        // A send of OURS whose `value` is large enough to pass a naive check.
        let ours = outgoing(0xB1, 20_000_000, 2_001);

        let value_of = |r: &TransactionRecord| -> Option<u64> {
            Some(r).filter(|r| is_incoming_data(r)).map(|r| r.value())
        };

        assert_eq!(
            value_of(&deposit),
            Some(20_000_000),
            "a receive reports what it paid us"
        );
        assert_eq!(
            value_of(&ours),
            None,
            "a record WE originated is not evidence that anyone paid us"
        );
        assert!(
            value_of(&incoming(0xB2, 1_000, 2_002)).unwrap() < 20_000_000,
            "a dust receive is below the bond — the accept path must refuse it"
        );
    }

    /// Finding 8 (V2): the app-side live-deposit path, gate by gate. A genuine
    /// external deposit — an `Incoming` record whose UTXO sits at a RECEIVE
    /// address, under a txid we never originated — passes `is_own_change`,
    /// passes the provenance guard, is written, and renders in `list`. Pins
    /// that a live-arrival row loss is NOT this filter stack as written (the
    /// device lane's verdict logs discriminate the rest).
    #[test]
    fn a_live_external_deposit_passes_every_guard() {
        use kaspa_consensus_core::tx::ScriptPublicKey;
        use kaspa_wallet_core::storage::transaction::UtxoRecord;

        let receive = Address::try_from(
            "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf",
        )
        .unwrap();
        let change = Address::try_from(
            "kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692",
        )
        .unwrap();
        let change_set: HashSet<Address> = [change].into_iter().collect();

        // A 5 KAS deposit to our receive address (the 2026-07-09 live shape).
        let deposit = record(
            11,
            500_000_000,
            2_000,
            TransactionData::Incoming {
                utxo_entries: vec![UtxoRecord {
                    address: Some(receive),
                    index: 0,
                    amount: 500_000_000,
                    script_public_key: ScriptPublicKey::default(),
                    is_coinbase: false,
                }],
                aggregate_input_value: 500_000_000,
            },
        );

        assert!(
            !is_own_change(&deposit, &change_set),
            "a receive-address deposit is never own change"
        );

        let dir = std::env::temp_dir().join(format!("kv-wsync-dep-{}", std::process::id()));
        let path = dir.join("activity.kvlog");
        let _ = std::fs::remove_file(&path);
        let mut store = ActivityStore::load(path.clone()).unwrap();
        assert!(
            store.upsert(deposit).unwrap(),
            "a fresh external txid is written, never provenance-refused"
        );

        let rows = store.list(Some(2_050), &change_set, &change_set);
        assert_eq!(rows.len(), 1, "the deposit renders");
        assert_eq!(rows[0].direction, ActivityDirection::Incoming);
        assert_eq!(rows[0].value_sompi, 500_000_000);
        assert_eq!(rows[0].maturity, ActivityMaturity::Pending);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn list_is_newest_first_and_capped() {
        let dir = std::env::temp_dir().join(format!("kv-wsync-{}", std::process::id()));
        let path = dir.join("activity.kvlog");
        let _ = std::fs::remove_file(&path);
        let mut store = ActivityStore::load(path.clone()).unwrap();

        // Insert out of order; expect newest (highest DAA) first.
        store.upsert(incoming(1, 10, 30)).unwrap();
        store.upsert(incoming(2, 20, 10)).unwrap();
        store.upsert(incoming(3, 30, 20)).unwrap();

        let rows = store.list(Some(1_000_000), &HashSet::new(), &HashSet::new());
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0].block_daa_score, 30);
        assert_eq!(rows[1].block_daa_score, 20);
        assert_eq!(rows[2].block_daa_score, 10);
        assert_eq!(rows[0].maturity, ActivityMaturity::Confirmed);

        // Reload from disk → the same three survive (replay round-trip).
        let reloaded = ActivityStore::load(path.clone()).unwrap();
        assert_eq!(reloaded.records.len(), 3);

        let _ = std::fs::remove_file(&path);
    }

    /// F46 (product-audit run 3): the test above is named `..._and_capped` and
    /// inserts THREE records against a cap of 100 — the cap in its own name was
    /// never exercised, and could be raised, lowered or deleted with the suite
    /// green. This is the half that can actually fail.
    ///
    /// It also pins WHICH rows survive: `.take(ACTIVITY_CAP)` runs after a
    /// newest-first sort, so the cut must keep the newest and drop the oldest.
    /// A cut on the wrong side of the sort would hide a user's live payments
    /// behind their history and still leave the count right.
    #[test]
    fn the_cap_keeps_the_newest_and_drops_the_rest() {
        let dir = std::env::temp_dir().join(format!("kv-wsync-cap-{}", std::process::id()));
        let path = dir.join("activity.kvlog");
        let _ = std::fs::remove_file(&path);
        let mut store = ActivityStore::load(path.clone()).unwrap();

        // Comfortably over the bound, inserted OLDEST first so a cut that
        // ignored the sort would keep exactly the wrong end.
        let over = ACTIVITY_CAP + 17;
        for i in 0..over {
            // `incoming(id_byte, value, daa)` — the id_byte varies so every
            // record is a DISTINCT txid (the store is a last-write-wins map
            // keyed on txid, so a repeated byte would silently upsert one row
            // and the cap would never be reached).
            store
                .upsert(incoming(i as u8, 1_000, (i as u64 + 1) * 10))
                .unwrap();
        }
        assert_eq!(
            store.records.len(),
            over,
            "the STORE keeps everything — only the feed is bounded"
        );

        let rows = store.list(Some(1_000_000), &HashSet::new(), &HashSet::new());
        assert_eq!(rows.len(), ACTIVITY_CAP, "the feed is cut to the cap");
        assert_eq!(
            rows[0].block_daa_score,
            over as u64 * 10,
            "the newest row survives the cut"
        );
        assert_eq!(
            rows[ACTIVITY_CAP - 1].block_daa_score,
            (over - ACTIVITY_CAP + 1) as u64 * 10,
            "the cut takes the OLDEST rows, not the newest"
        );

        let _ = std::fs::remove_file(&path);
    }

    /// The D2 provenance guard: once a txid is a SEND we originated, a restart
    /// re-scan re-reporting that SAME txid as an incoming deposit is refused —
    /// so conversation change returning to the bound RECEIVE address (source
    /// discipline) never surfaces as a phantom "received" row. A DIFFERENT
    /// txid (a real deposit / a counterpart's bond refund) is unaffected.
    #[test]
    fn incoming_never_downgrades_an_originated_send() {
        let dir = std::env::temp_dir().join(format!("kv-wsync-guard-{}", std::process::id()));
        let path = dir.join("activity.kvlog");
        let _ = std::fs::remove_file(&path);
        let mut store = ActivityStore::load(path.clone()).unwrap();

        // We sent tx 7 (a comm; change returns to our receive address).
        store.upsert(outgoing(7, 20_000, 100)).unwrap();
        // Restart re-scan re-reports tx 7's returning change as an Incoming.
        store.upsert(incoming(7, 4_000, 120)).unwrap();

        // The row stays our outgoing send — not a phantom deposit.
        let rows = store.list(Some(1_000_000), &HashSet::new(), &HashSet::new());
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].direction, ActivityDirection::Outgoing);

        // A genuine deposit under a DIFFERENT txid is untouched by the guard.
        store.upsert(incoming(9, 50_000, 130)).unwrap();
        let rows = store.list(Some(1_000_000), &HashSet::new(), &HashSet::new());
        let deposit = rows
            .iter()
            .find(|r| r.direction == ActivityDirection::Incoming);
        assert!(deposit.is_some(), "a real deposit still shows");

        // The guard survives a reload (the rejected incoming was never appended).
        let reloaded = ActivityStore::load(path.clone()).unwrap();
        assert!(is_outgoing_data(
            reloaded
                .records
                .get(&TransactionId::from_bytes([7; 32]))
                .unwrap()
        ));

        let _ = std::fs::remove_file(&path);
    }
}
