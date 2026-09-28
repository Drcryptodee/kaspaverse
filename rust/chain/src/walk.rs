//! walk — messages from ACCEPTED transactions (LINK-Q3, D-344).
//!
//! **What moved.** Until LINK-Q3 the message intake read full blocks off the
//! `BlockAdded` stream (P2 §0.3, ratified at D-062): every block, every
//! transaction, ten frames a second, 97 % of what the app downloaded (LINK-Q2,
//! D-340). The founder approved stream-less on one socket (D-340). The intake
//! now reads what the chain ACCEPTED, from `GetVirtualChainFromBlockV2` at High
//! verbosity, the lowest level that carries a payload (pin
//! `rpc/core/src/convert/verbosity.rs`, `include_payload: High`), fetched from
//! a persisted cursor whenever the socket's `VirtualChainChanged` says the chain
//! moved. **Only accepted transactions become messages:** one included in a
//! block but never accepted is never shown. That is the more correct set
//! (frames stay hints, P2 §0.3) and P3.4's own semantics (acceptance, never
//! sighting). The price, measured by LINK-Q2's E2: a message appears when the
//! network accepts it, about 1.4 s after a block first carried it.
//!
//! **One cursor, one fetch per chain move, matchers over what was accepted.**
//! A chain move pokes the walk; pokes that land while a page is in flight
//! coalesce into one more fetch ([`Notify`]'s stored permit), so the walk asks
//! for one page at a time on the funds lane's socket (a timed-out reply may
//! still be streaming when the next run starts; failed runs pause for it).
//! Each page goes to every
//! [`WalkMatcher`] in chain order, the transport prefix today and P3.4's Cov-ID
//! matcher next (its row 1: no second subscription). **The cursor commits only
//! when every matcher has folded the page.** A matcher that cannot fold
//! (the vault is locked) holds the page: the cursor stays at the page's start,
//! the walk stops, and the next arm replays it. The same walk is the catch-up:
//! a cold open, a reconnect and an unlock all resume from the committed cursor,
//! so a gap is replayed by construction (product-audit run 2, F4).
//!
//! **Prior art (D-343).** An at-least-once resumable consumer: the committed
//! offset of Kafka's consumer groups (commit after processing, so a crash or a
//! refusal replays rather than loses), made safe to replay by idempotent
//! processing (the transport store's dedupe by txid, the Outbox pattern's
//! consumer side). This repo's own instance is the acceptance spine
//! (`acceptance.rs`): a cursor on the same socket's `VirtualChainChanged`, a
//! node-paged catch-up, a re-seed at the sink when the node cannot answer for
//! the cursor, all copied here rather than re-invented.
//!
//! **What the node guarantees, read at the pin** (INV-9, `01b532e`):
//! - `calculate_chain_path(from, sink)` (`consensus/src/processes/
//!   traversal_manager.rs:34-60`): `removed` is `from` and its selected-chain
//!   ancestors that are no longer chain ancestors of the sink, newest first;
//!   `added` is the chain from their common ancestor up to the sink, oldest
//!   first. A cursor that left the chain is reported removed on the next page,
//!   so a reorg arrives inside the page itself. A start that was never a chain
//!   block is accepted the same way (its off-chain ancestors are the `removed`
//!   half), which is why a cursor written by the old block scan still works.
//! - A page covers at most `mergeset_size_limit × 10` merged blocks
//!   (`rpc/service/src/service.rs:1381`), about 2,480 at 10 BPS or four minutes
//!   of chain, and `added` is truncated to the chain blocks whose acceptance
//!   data the page carries (`:1411`), so the two lists line up.
//! - Each accepted transaction's `verbose_data.block_hash` and `block_time` are
//!   the merged block that CARRIED it (`rpc/service/src/converter/
//!   consensus.rs:538-566`): the same carrying-block facts the stream gave.
//! - A cursor the node does not know is refused with `cannot find header <hash>`
//!   (`ConsensusError::HeaderNotFound`, `consensus/src/consensus/mod.rs:444`) or
//!   `the queried hash does not have retention root on its chain` (`:863`).
//!
//! **INV-3/8:** the cursor is a public block hash in an app-private file; every
//! read is one node RPC on the one socket; no indexer anywhere on this path.

use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use kaspa_addresses::Prefix;
use kaspa_consensus_core::errors::consensus::ConsensusError;
use kaspa_consensus_core::Hash;
use kaspa_rpc_core::api::rpc::RpcApi;
use kaspa_rpc_core::{
    GetVirtualChainFromBlockV2Response, RpcChainBlockAcceptedTransactions, RpcDataVerbosityLevel,
};
use tokio::sync::{broadcast, mpsc, watch, Notify};

use crate::acceptance::{TrackerFeed, WalkAcceptance, WalkBatch};
use crate::dag_monitor::mono_ms;
use crate::devab::DevAb;
use crate::link;
use crate::transport::{self, TransportEvent};

/// The verbosity the walk asks for: the lowest that carries a payload
/// (`include_payload: High` at the pin). It also carries each accepting chain
/// block's hash, time, DAA and blue score (Low), which the tracker needs.
const WALK_VERBOSITY: RpcDataVerbosityLevel = RpcDataVerbosityLevel::High;

/// Pages one run may walk before it stops and re-seeds at the sink. A page is
/// about four minutes of chain at 10 BPS, so sixteen is about an hour: the
/// acceptance spine's own budget (`MAX_VCC_CATCHUP_PAGES`), so both walks
/// recover the same window and past it the same gap notice speaks. Priced on
/// LINK-Q2's E2 (D-340): accepted transactions at High cost about 28 MB per
/// hour of chain on today's quiet mainnet, so a spent budget is about 30 MB;
/// the 48-page `get_blocks` catch-up it replaces fetched twenty minutes of FULL
/// blocks, about 145 MB at 12,110 B a block. Both grow with transaction volume.
/// Derived, not copied, so the two walks cannot drift apart (`consensus-auditor`).
const MAX_WALK_PAGES: u32 = crate::acceptance::MAX_VCC_CATCHUP_PAGES;

/// A page that added fewer chain blocks than this reached the tip (the
/// acceptance spine's `VCC_TIP_PAGE_THRESHOLD`: an is-empty test chases the tip
/// through the whole budget, observed live 2026-07-09).
const WALK_TIP_PAGE_THRESHOLD: usize = crate::acceptance::VCC_TIP_PAGE_THRESHOLD;

/// Attempts per page across a still-dialing or briefly flaky socket, and the
/// pause between them (the acceptance spine's `VCC_PAGE_ATTEMPTS` and delay).
const WALK_PAGE_ATTEMPTS: u32 = crate::acceptance::VCC_PAGE_ATTEMPTS;
const WALK_RETRY_DELAY: Duration = crate::acceptance::VCC_PAGE_RETRY_DELAY;

/// Failed runs from one cursor before the walk stops asking for that page. A
/// run fails when the node does not answer the page inside [`WALK_PAGE_TIMEOUT`]
/// or the socket dies under it (one attempt either way: that page is never
/// re-asked inside the run), or every one of its [`WALK_PAGE_ATTEMPTS`] ends
/// without a page and at least one was a refusal the walk does not recognise.
/// A run that found no socket at all is not a failure. After the third, the
/// walk re-seeds at the sink and names the gap — at once if the sink answers,
/// else as a debt the next run pays before it asks for the page again.
/// Without a bound, a page too large for the link (the node sets its size; the
/// request cannot shrink it) would be re-asked on every chain move forever, and
/// live messages, which sit beyond the stuck cursor, would stop with it
/// (`consensus-auditor`, LINK-Q3).
const MAX_FAILED_RUNS: u32 = 3;

/// The pause after a failed run, doubled per failure up to the cap: a
/// timed-out reply may still be streaming on the one socket (dropping the
/// future does not stop the node), so the walk does not ask again at the
/// chain's pace. A page answered, a re-seed or a new arm starts the count
/// again; a new socket does not (see [`PageError::SocketLost`]).
const FAILED_RUN_BACKOFF: Duration = Duration::from_secs(2);
const FAILED_RUN_BACKOFF_CAP: Duration = Duration::from_secs(60);

/// Our own bound on one page call, at the wRPC transport's own sweep (60 s,
/// `workflow-rpc 0.18.0 client/mod.rs:151-152`), named so a call that never
/// answers cannot hold the walk past it.
const WALK_PAGE_TIMEOUT: Duration = Duration::from_secs(60);

/// At most one cursor write this often while live, the old stream cursor's
/// throttle: a killed app replays at most this much chain, and the store's
/// dedupe by txid absorbs it. Catch-up pages, holds and re-seeds write at once.
const CURSOR_MIN_WRITE_SECS: u64 = 3;

/// The pin's text for a start hash whose chain does not carry the retention
/// root (`consensus/src/consensus/mod.rs:863` @ `01b532e`). A string literal
/// the pin does not export, so it is quoted here and a test holds the quote.
const RETENTION_ROOT_OFF_CHAIN: &str = "does not have retention root on its chain";

// ── The page and its consumers ───────────────────────────────────────────────

/// One page of the walk, validated. [`WalkPage::blocks`] pairs every added
/// chain block with the transactions it accepted and stops at the first entry
/// whose header does not name the block beside it: the node truncates the two
/// lists together, and a page that does not line up is not trusted past the
/// point where it stops.
pub struct WalkPage {
    /// The committed cursor this page was fetched from.
    pub from: Hash,
    response: GetVirtualChainFromBlockV2Response,
    aligned: usize,
}

impl WalkPage {
    fn new(from: Hash, response: GetVirtualChainFromBlockV2Response) -> Self {
        let aligned = response
            .added_chain_block_hashes
            .iter()
            .zip(response.chain_block_accepted_transactions.iter())
            .take_while(|(hash, entry)| entry.chain_block_header.hash == Some(**hash))
            .count();
        Self {
            from,
            response,
            aligned,
        }
    }

    /// Chain blocks that left the selected chain since [`Self::from`], newest
    /// first (the pin's order).
    pub fn removed(&self) -> &[Hash] {
        &self.response.removed_chain_block_hashes
    }

    /// Added chain blocks in chain order, each with what it accepted.
    pub fn blocks(&self) -> impl Iterator<Item = (Hash, &RpcChainBlockAcceptedTransactions)> {
        self.response
            .added_chain_block_hashes
            .iter()
            .copied()
            .zip(self.response.chain_block_accepted_transactions.iter())
            .take(self.aligned)
    }

    /// The chain block the cursor moves to once this page is folded, and its
    /// time when the node sent it.
    fn last(&self) -> Option<(Hash, Option<u64>)> {
        let index = self.aligned.checked_sub(1)?;
        let entry = &self.response.chain_block_accepted_transactions[index];
        Some((
            self.response.added_chain_block_hashes[index],
            entry.chain_block_header.timestamp,
        ))
    }

    /// How many chain blocks the node added: the tip test reads the node's
    /// count, not how far we trusted it.
    fn added_len(&self) -> usize {
        self.response.added_chain_block_hashes.len()
    }
}

/// What a consumer did with a page.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Everything in the page that concerns it is folded: the cursor may pass.
    Folded,
    /// Something that may be ours could not be folded (the vault is locked):
    /// the cursor stays at the page's start and the walk stops until re-armed.
    Held,
}

/// A consumer's answer, boxed so an implementer needs no macro crate (the
/// bridge carries none).
pub type VerdictFuture<'a> = Pin<Box<dyn Future<Output = Verdict> + Send + 'a>>;

/// A consumer of the walk's pages: the seam P3.4's Cov-ID matcher joins
/// (`P3_covenant_engine_ACTIVE.md` §P3.4 row 1, "no second subscription").
/// Every matcher sees every page in chain order, and the cursor commits only
/// when all of them answer [`Verdict::Folded`]. **A page can arrive twice** (a
/// held page is replayed, a re-seed can move the cursor back), so a matcher's
/// fold must be idempotent. **One cursor is one readiness**: a matcher that
/// holds stalls every matcher.
pub trait WalkMatcher: Send + Sync {
    fn fold_page<'a>(&'a self, page: &'a WalkPage) -> VerdictFuture<'a>;

    /// **The walk skipped chain**: it re-seeded at the node's sink `to` from
    /// the cursor `from` it could not walk on from (an unknown cursor, a spent
    /// budget, a page the node could not serve). Never called for a first seed,
    /// which skips nothing. A matcher that must see every accepted transaction
    /// — P3.4's watcher — marks its state stale here (`consensus-auditor`: a
    /// watcher that cannot hear a skip is a BLOCK at P3.4). The transport
    /// matcher has nothing to do; the skip reaches the log (the hub's gap
    /// notice is worked out once per start, so a mid-session skip stops there).
    /// An `arm` onto a different cursor file jumps without it: that is a new
    /// store, not a skip in this one.
    fn on_gap(&self, _from: Hash, _to: Hash) {}
}

/// Why a page call did not return a page.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum PageError {
    /// No socket was bound when the call was made: still dialing, or paused.
    /// Retried inside the run and never counted — the next publish pokes.
    NoSocket,
    /// The socket died or was replaced while the call was in flight. Counted
    /// like a timeout, and a new socket does not forgive it: a page too large
    /// for the link silences the socket's heartbeat, the silence deadline
    /// swaps the socket, and the page dies with it — on every socket, forever,
    /// if each publish restarted the count (`consensus-auditor`, LINK-Q3).
    SocketLost,
    /// The node did not answer inside [`WALK_PAGE_TIMEOUT`].
    TimedOut,
    /// The node answered with an error.
    Refused(String),
}

/// Classify a failed page call from the socket bound before and after it —
/// an identity comparison, never error text (the dialer's and the pin's words
/// for a dying socket are many and unpinned).
fn page_error(before: Option<usize>, after: Option<usize>, error: String) -> PageError {
    match before {
        None => PageError::NoSocket,
        Some(_) if after != before => PageError::SocketLost,
        Some(_) => PageError::Refused(error),
    }
}

/// The node, through the link's stable handle (production).
pub(crate) struct LinkSource(pub(crate) Arc<crate::link_rpc::LinkRpc>);

/// The message hub's side of the walk (the bridge implements it): one page's
/// transport matches, in chain order. `Held` when the vault locked under the
/// fold; the page is then replayed at the next arm.
pub trait MessageSink: Send + Sync {
    fn fold(&self, matches: Vec<TransportEvent>) -> VerdictFuture<'_>;
}

/// Where pages come from: the node through the link's stable handle in
/// production, a scripted chain in the tests.
#[async_trait]
pub(crate) trait ChainSource: Send + Sync {
    async fn page(
        &self,
        from: Hash,
    ) -> std::result::Result<GetVirtualChainFromBlockV2Response, PageError>;
    async fn sink(&self) -> std::result::Result<Hash, String>;
}

#[async_trait]
impl ChainSource for LinkSource {
    async fn page(
        &self,
        from: Hash,
    ) -> std::result::Result<GetVirtualChainFromBlockV2Response, PageError> {
        let before = self.0.bound_identity();
        match tokio::time::timeout(
            WALK_PAGE_TIMEOUT,
            self.0
                .get_virtual_chain_from_block_v2(from, Some(WALK_VERBOSITY), None),
        )
        .await
        {
            Ok(Ok(response)) => Ok(response),
            Ok(Err(e)) => Err(page_error(before, self.0.bound_identity(), e.to_string())),
            Err(_) => Err(PageError::TimedOut),
        }
    }

    /// Bounded at our boundary like a page (`consensus-auditor`,
    /// `wallet-security-auditor` item 13): the stable handle has no deadline
    /// of its own, and a sink that never answers would stall the only task.
    async fn sink(&self) -> std::result::Result<Hash, String> {
        match tokio::time::timeout(WALK_PAGE_TIMEOUT, self.0.get_sink()).await {
            Ok(Ok(sink)) => Ok(sink.sink),
            Ok(Err(e)) => Err(e.to_string()),
            Err(_) => Err(format!("no answer in {} s", WALK_PAGE_TIMEOUT.as_secs())),
        }
    }
}

/// Did the node refuse the cursor itself (pruned, unknown, or on a chain
/// without the retention root) rather than fail to answer? Read from the pin's
/// own error text, which reaches the client inside `RpcError::RpcSubsystem`
/// (every server-side error does, pin `rpc/macros/src/wrpc/client.rs:74`).
/// Only this answer re-seeds; any other failure keeps the cursor.
fn cursor_unknown(error: &str) -> bool {
    let zero = Hash::default().to_string();
    let missing = ConsensusError::HeaderNotFound(Hash::default()).to_string();
    let missing = missing.trim_end_matches(zero.as_str()).trim_end();
    error.contains(missing) || error.contains(RETENTION_ROOT_OFF_CHAIN)
}

/// Read a persisted cursor (a block hash in hex). A missing or corrupt file
/// reads as none, and the walk seeds at the sink.
pub(crate) fn read_cursor(path: &Path) -> Option<Hash> {
    let text = std::fs::read_to_string(path).ok()?;
    text.trim().parse::<Hash>().ok()
}

fn write_cursor(path: &Path, hash: &Hash) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Err(e) = std::fs::write(path, hash.to_string()) {
        log::warn!("walk: cursor write failed: {e}");
    }
}

fn now_unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn now_unix_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

// ── The walk ─────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mode {
    /// Nobody consumes: not armed yet (no unlocked hub), or held.
    Idle,
    /// Armed: pages are fetched, folded and committed.
    Running,
}

struct State {
    mode: Mode,
    /// The committed cursor: every page up to and including this chain block
    /// has been folded by every matcher. `None` until seeded.
    cursor: Option<Hash>,
    /// Where the cursor persists, once the hub has armed the walk.
    path: Option<PathBuf>,
    /// Unix seconds of the last write, for [`CURSOR_MIN_WRITE_SECS`].
    written_at: u64,
    /// The committed chain block's own time, when this process folded it: how
    /// a re-seed names the gap it skips.
    cursor_time_ms: Option<u64>,
    /// Bumped by every arm and hold. A run that began under another epoch
    /// stops at its next step: its consumer changed under it.
    epoch: u64,
    /// Consecutive failed runs from the committed cursor ([`MAX_FAILED_RUNS`]);
    /// a page answered, a re-seed or an arm clears it; a new socket does not.
    failed_runs: u32,
    /// No run starts before this after a failed one ([`FAILED_RUN_BACKOFF`]).
    retry_after: Option<tokio::time::Instant>,
}

enum Step {
    Stop,
    Seed,
    From(Hash),
}

enum Fetched {
    Page(GetVirtualChainFromBlockV2Response),
    Unknown(String),
    TimedOut,
    SocketLost,
    /// Every attempt found no socket bound: not a failure of the page.
    NoSocket,
    Unreachable,
    Stopped,
}

/// The walk: one cursor, one task, one fetch at a time. See the module doc.
pub(crate) struct Walk {
    state: Mutex<State>,
    poke: Notify,
    /// The epoch of the last run that ended, whatever it found: the V2b fill
    /// waits on it so node truth folds first (D-074's order).
    settled: watch::Sender<u64>,
    matchers: Vec<Arc<dyn WalkMatcher>>,
    /// [`mono_ms`] at the last page the node answered (0 = none): the witness.
    last_progress_mono_ms: AtomicU64,
    /// [`mono_ms`] at the last arm, so a fresh arm starts a fresh stretch.
    running_since_mono_ms: AtomicU64,
    /// The witness has spoken for the current stretch.
    quiet_warned: AtomicBool,
    /// Held for the whole of a page's fold: [`Self::quiesce`] waits on it, and
    /// a fold re-checks the hold under it, so once `hold` + `quiesce` return no
    /// fold is running and none can start (the hub's restart needs its store
    /// to have one writer).
    fold_gate: tokio::sync::Mutex<()>,
}

impl Walk {
    pub(crate) fn new(matchers: Vec<Arc<dyn WalkMatcher>>) -> Arc<Self> {
        let (settled, _) = watch::channel(0);
        Arc::new(Self {
            state: Mutex::new(State {
                mode: Mode::Idle,
                cursor: None,
                path: None,
                written_at: 0,
                cursor_time_ms: None,
                epoch: 0,
                failed_runs: 0,
                retry_after: None,
            }),
            poke: Notify::new(),
            settled,
            matchers,
            last_progress_mono_ms: AtomicU64::new(0),
            running_since_mono_ms: AtomicU64::new(0),
            quiet_warned: AtomicBool::new(false),
            fold_gate: tokio::sync::Mutex::new(()),
        })
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// **Arm the intake**: pages are fetched and folded from the committed
    /// cursor at `path` (read now when this process has none for that path).
    /// Returns the epoch a caller can wait on with [`Self::settled`].
    pub(crate) fn arm(&self, path: PathBuf) -> u64 {
        let (epoch, cursor) = {
            let mut s = self.state();
            if s.path.as_ref() != Some(&path) || s.cursor.is_none() {
                s.cursor = read_cursor(&path);
                s.cursor_time_ms = None;
                s.path = Some(path);
            }
            s.mode = Mode::Running;
            s.epoch += 1;
            s.failed_runs = 0;
            s.retry_after = None;
            (s.epoch, s.cursor)
        };
        self.running_since_mono_ms
            .store(mono_ms(), Ordering::Relaxed);
        self.quiet_warned.store(false, Ordering::Relaxed);
        match cursor {
            Some(cursor) => log::info!("walk: intake armed at {cursor} (LINK-Q3)"),
            None => log::info!("walk: intake armed with no cursor — seeds at the sink (LINK-Q3)"),
        }
        self.poke.notify_one();
        epoch
    }

    /// **Hold the intake** (the vault locked): no fetch starts until the next
    /// arm, and the committed cursor is written now, so a process that dies
    /// while held replays from it.
    pub(crate) fn hold(&self, why: &str) {
        let cursor = {
            let mut s = self.state();
            if s.mode == Mode::Idle {
                return;
            }
            s.mode = Mode::Idle;
            s.epoch += 1;
            Self::flush(&mut s);
            s.cursor
        };
        match cursor {
            Some(cursor) => {
                log::info!("walk: intake held at {cursor} ({why}) — the next arm replays from here")
            }
            None => log::info!("walk: intake held before any cursor ({why})"),
        }
    }

    /// Wait for a fold in progress to end. After [`Self::hold`], this returns
    /// once no fold is running, and none can start until the next arm.
    pub(crate) async fn quiesce(&self) {
        drop(self.fold_gate.lock().await);
    }

    /// The chain moved, a socket came up, or the intake was armed: one more
    /// fetch, coalesced with any other poke that lands before it starts.
    pub(crate) fn poke(&self) {
        self.poke.notify_one();
    }

    pub(crate) fn is_running(&self) -> bool {
        self.state().mode == Mode::Running
    }

    /// The committed cursor (tests).
    #[cfg(test)]
    pub(crate) fn cursor(&self) -> Option<Hash> {
        self.state().cursor
    }

    /// Wait until a run begun under `epoch` (or a later one) has ended, for at
    /// most `within`. `false` on the timeout.
    pub(crate) async fn settled(&self, epoch: u64, within: Duration) -> bool {
        let mut rx = self.settled.subscribe();
        tokio::time::timeout(within, rx.wait_for(|done| *done >= epoch))
            .await
            .is_ok_and(|r| r.is_ok())
    }

    /// The task: one run per poke, for as long as the process lives.
    pub(crate) async fn run(self: Arc<Self>, source: Arc<dyn ChainSource>) {
        loop {
            self.poke.notified().await;
            self.run_to_tip(&*source).await;
        }
    }

    /// Walk from the committed cursor until the tip, a hold, the budget, or a
    /// node that cannot answer.
    pub(crate) async fn run_to_tip(&self, source: &dyn ChainSource) {
        let (epoch, backing_off) = {
            let s = self.state();
            if s.mode != Mode::Running {
                return;
            }
            let backing_off = s
                .retry_after
                .is_some_and(|at| tokio::time::Instant::now() < at);
            (s.epoch, backing_off)
        };
        if backing_off {
            // A failed run's pause: this poke is dropped, and a later one
            // (the chain moves every second or so) runs once it has passed.
            self.settle(epoch);
            return;
        }
        // A re-seed the third failure owed but could not make: paid now,
        // before the page that has already failed three times is asked for
        // again — asking would kill the next socket the same way.
        if self.state().failed_runs >= MAX_FAILED_RUNS {
            let why = format!(
                "the node could not serve the page in {MAX_FAILED_RUNS} runs (the re-seed was \
                 owed: no sink could be read when the last one failed)"
            );
            self.reseed(source, epoch, Some(&why)).await;
            self.settle(epoch);
            return;
        }
        let mut pages = 0u32;
        loop {
            let from = match self.step(epoch) {
                Step::Stop => break,
                Step::Seed => {
                    self.reseed(source, epoch, None).await;
                    break;
                }
                Step::From(from) => from,
            };
            let response = match self.fetch(source, epoch, from).await {
                Fetched::Page(response) => response,
                Fetched::Unknown(error) => {
                    let why = format!(
                        "the node does not know cursor {from} ({})",
                        link::sanitize_node_text(&error)
                    );
                    self.reseed(source, epoch, Some(&why)).await;
                    break;
                }
                Fetched::TimedOut => {
                    let kind = format!("no answer in {} s", WALK_PAGE_TIMEOUT.as_secs());
                    self.failed_run(source, epoch, from, &kind).await;
                    break;
                }
                Fetched::SocketLost => {
                    self.failed_run(source, epoch, from, "the socket died under the page")
                        .await;
                    break;
                }
                Fetched::Unreachable => {
                    self.failed_run(source, epoch, from, "no page after every attempt")
                        .await;
                    break;
                }
                // Nothing bound: no pause, no count — the next publish pokes.
                Fetched::NoSocket | Fetched::Stopped => break,
            };
            let page = WalkPage::new(from, response);
            let verdict = {
                let _fold = self.fold_gate.lock().await;
                // The fetch took time: fold only if the walk still runs under
                // this arm from the same committed cursor. Checked under the
                // gate, so a hold that `quiesce` waited out cannot be passed.
                if !self.still_at(epoch, from) {
                    break;
                }
                self.note_progress();
                self.fold(&page).await
            };
            if verdict == Verdict::Held {
                self.hold_at(from);
                break;
            }
            let long = page.added_len() >= WALK_TIP_PAGE_THRESHOLD;
            if let Some((last, time_ms)) = page.last() {
                self.commit(from, last, time_ms, long || pages > 0);
            }
            if page.aligned < page.added_len() {
                log::warn!(
                    "walk: the page from {from} lines up for {} of {} chain blocks — folded that far",
                    page.aligned,
                    page.added_len()
                );
                break;
            }
            pages += 1;
            if !long {
                break;
            }
            if pages >= MAX_WALK_PAGES {
                let why = format!(
                    "the catch-up budget ({MAX_WALK_PAGES} pages, about an hour of chain) is spent"
                );
                self.reseed(source, epoch, Some(&why)).await;
                break;
            }
        }
        self.settle(epoch);
    }

    /// A run begun under `epoch` has ended, whatever it found.
    fn settle(&self, epoch: u64) {
        self.settled.send_if_modified(|done| {
            if *done < epoch {
                *done = epoch;
                true
            } else {
                false
            }
        });
    }

    /// A run from `from` failed: keep the cursor, pause the next run, and after
    /// [`MAX_FAILED_RUNS`] re-seed at the sink. The sink often cannot be read
    /// at that moment (the page's socket has just died and nothing is bound
    /// yet), so an unmade re-seed stays owed and the next run pays it before
    /// the page is asked for again (`consensus-auditor`, round 3).
    async fn failed_run(&self, source: &dyn ChainSource, epoch: u64, from: Hash, kind: &str) {
        let (failed, pause) = {
            let mut s = self.state();
            // A failure that outlived its arm (a lock and an unlock during the
            // call) is not this arm's to count (`wallet-security-auditor`).
            if s.mode != Mode::Running || s.epoch != epoch || s.cursor != Some(from) {
                return;
            }
            s.failed_runs += 1;
            let pause = FAILED_RUN_BACKOFF
                .saturating_mul(1 << s.failed_runs.saturating_sub(1).min(8))
                .min(FAILED_RUN_BACKOFF_CAP);
            s.retry_after = Some(tokio::time::Instant::now() + pause);
            (s.failed_runs, pause)
        };
        log::info!(
            "walk: run {failed} from {from} failed ({kind}) — the cursor is kept, the next run \
             waits {} s",
            pause.as_secs()
        );
        if failed >= MAX_FAILED_RUNS {
            let why =
                format!("the node could not serve the page from {from} in {failed} runs ({kind})");
            self.reseed(source, epoch, Some(&why)).await;
        }
    }

    fn step(&self, epoch: u64) -> Step {
        let s = self.state();
        if s.mode != Mode::Running || s.epoch != epoch {
            return Step::Stop;
        }
        match s.cursor {
            Some(cursor) => Step::From(cursor),
            None => Step::Seed,
        }
    }

    /// Is the walk still running under `epoch` from the committed `from`?
    fn still_at(&self, epoch: u64, from: Hash) -> bool {
        matches!(self.step(epoch), Step::From(cursor) if cursor == from)
    }

    async fn fetch(&self, source: &dyn ChainSource, epoch: u64, from: Hash) -> Fetched {
        let mut last_error = String::new();
        let mut only_no_socket = true;
        for attempt in 0..WALK_PAGE_ATTEMPTS {
            if !self.still_at(epoch, from) {
                return Fetched::Stopped;
            }
            match source.page(from).await {
                Ok(response) => return Fetched::Page(response),
                // Never re-asked inside the run: the late reply may still be
                // streaming on the one socket (`consensus-auditor`, LINK-Q3).
                Err(PageError::TimedOut) => return Fetched::TimedOut,
                Err(PageError::SocketLost) => return Fetched::SocketLost,
                Err(PageError::Refused(error)) if cursor_unknown(&error) => {
                    return Fetched::Unknown(error)
                }
                // Still dialing: wait for the socket inside the run.
                Err(PageError::NoSocket) => {
                    if attempt + 1 < WALK_PAGE_ATTEMPTS {
                        tokio::time::sleep(WALK_RETRY_DELAY).await;
                    }
                }
                Err(PageError::Refused(error)) => {
                    only_no_socket = false;
                    // Node-controlled text, sanitized before any log lane (L167).
                    log::debug!(
                        "walk: page attempt {attempt} from {from} failed ({})",
                        link::sanitize_node_text(&error)
                    );
                    last_error = error;
                    if attempt + 1 < WALK_PAGE_ATTEMPTS {
                        tokio::time::sleep(WALK_RETRY_DELAY).await;
                    }
                }
            }
        }
        if only_no_socket {
            log::info!(
                "walk: no socket for the page from {from} — the cursor is kept for the next"
            );
            return Fetched::NoSocket;
        }
        log::info!(
            "walk: no page from {from} after {WALK_PAGE_ATTEMPTS} attempts ({}) — the cursor is kept",
            link::sanitize_node_text(&last_error)
        );
        Fetched::Unreachable
    }

    async fn fold(&self, page: &WalkPage) -> Verdict {
        for matcher in &self.matchers {
            if matcher.fold_page(page).await == Verdict::Held {
                return Verdict::Held;
            }
        }
        Verdict::Folded
    }

    /// Move the committed cursor from `from` to `to`, unless something else
    /// moved it meanwhile. Written at once when `force` or when the walk is no
    /// longer running (a hold already flushed the older value), else throttled.
    fn commit(&self, from: Hash, to: Hash, time_ms: Option<u64>, force: bool) {
        let mut s = self.state();
        if s.cursor != Some(from) {
            return;
        }
        s.cursor = Some(to);
        s.cursor_time_ms = time_ms;
        let now = now_unix_secs();
        if force
            || s.mode != Mode::Running
            || now.saturating_sub(s.written_at) >= CURSOR_MIN_WRITE_SECS
        {
            Self::flush(&mut s);
        }
    }

    fn flush(s: &mut State) {
        if let (Some(path), Some(cursor)) = (s.path.as_ref(), s.cursor) {
            write_cursor(path, &cursor);
            s.written_at = now_unix_secs();
        }
    }

    /// A matcher could not fold the page from `from`: stop here and keep it.
    fn hold_at(&self, from: Hash) {
        {
            let mut s = self.state();
            s.mode = Mode::Idle;
            s.epoch += 1;
            Self::flush(&mut s);
        }
        log::info!(
            "walk: a page from {from} could not be folded — held there, the next arm replays it"
        );
    }

    /// Put the cursor at the node's sink. With no cursor this is the first
    /// run (nothing to replay); otherwise `why` says what is being skipped and
    /// the log names the gap, as the old catch-up did.
    async fn reseed(&self, source: &dyn ChainSource, epoch: u64, why: Option<&str>) {
        let sink = match source.sink().await {
            Ok(sink) => sink,
            Err(e) => {
                // Paced (a flat [`FAILED_RUN_BACKOFF`], never shortening a
                // longer pause already set): a node that refuses its sink fast
                // would otherwise be asked on every chain move, a spin on the
                // funds lane's socket (`wallet-security-auditor`, round 4). The
                // arm check keeps an old arm's failure from pausing a new one.
                {
                    let mut s = self.state();
                    if s.mode == Mode::Running && s.epoch == epoch {
                        let pause = tokio::time::Instant::now() + FAILED_RUN_BACKOFF;
                        s.retry_after = Some(s.retry_after.map_or(pause, |at| at.max(pause)));
                    }
                }
                log::info!(
                    "walk: could not read the sink ({}) — the cursor is kept",
                    link::sanitize_node_text(&e)
                );
                return;
            }
        };
        let (was, was_time) = {
            let mut s = self.state();
            if s.mode != Mode::Running || s.epoch != epoch {
                return;
            }
            let was = (s.cursor, s.cursor_time_ms);
            s.cursor = Some(sink);
            s.cursor_time_ms = None;
            s.failed_runs = 0;
            s.retry_after = None;
            Self::flush(&mut s);
            was
        };
        if let Some(from) = was {
            for matcher in &self.matchers {
                matcher.on_gap(from, sink);
            }
        }
        match (was, why) {
            (None, _) => log::info!("walk: seeded at the sink {sink} — nothing to replay"),
            (Some(was), Some(why)) => {
                let gap = match was_time {
                    Some(t) => format!(
                        "messages accepted in the {} min since {was} are not replayed from this node",
                        now_unix_ms().saturating_sub(t) / 60_000
                    ),
                    None => format!(
                        "messages accepted since {was} (its time unknown to this session) are not \
                         replayed from this node"
                    ),
                };
                log::warn!("walk: re-seeded at the sink {sink} — {why}; {gap}");
            }
            (Some(was), None) => log::warn!("walk: re-seeded at the sink {sink} from {was}"),
        }
    }

    /// A page answered: the witness's stretch and the failure streak end.
    fn note_progress(&self) {
        self.last_progress_mono_ms
            .store(mono_ms(), Ordering::Relaxed);
        self.quiet_warned.store(false, Ordering::Relaxed);
        let mut s = self.state();
        s.failed_runs = 0;
        s.retry_after = None;
    }

    /// A socket was published: the witness's stretch starts clean. The
    /// failure streak does NOT: a page the link cannot carry kills socket
    /// after socket (its silence trips the swap), and forgiving it on every
    /// publish would ask for it forever (`consensus-auditor`, LINK-Q3). A run
    /// that found no socket at all was never counted.
    pub(crate) fn socket_published(&self) {
        self.quiet_warned.store(false, Ordering::Relaxed);
    }

    /// Tests: was the walk poked (consuming the stored permit)?
    #[cfg(test)]
    pub(crate) async fn take_poke(&self, within: Duration) -> bool {
        tokio::time::timeout(within, self.poke.notified())
            .await
            .is_ok()
    }

    /// Tests: has the witness spoken for the current stretch?
    #[cfg(test)]
    pub(crate) fn witness_spoke(&self) -> bool {
        self.quiet_warned.load(Ordering::Relaxed)
    }

    /// Tests: pin the stretch's start, as a published socket's clock would.
    #[cfg(test)]
    pub(crate) fn set_running_since(&self, mono: u64) {
        self.running_since_mono_ms.store(mono, Ordering::Relaxed);
    }

    /// **D-334's witness, re-aimed at the walk** (LINK-Q3). The node keeps
    /// ticking on a published socket while the walk has had no page answered
    /// for the stall line: a node that dropped our `VirtualChainChanged` scope,
    /// or refuses the call, leaves messages late on this socket. Once per
    /// stretch, no verdict. Silent while the intake is held or not yet armed:
    /// there the stillness is by design.
    pub(crate) fn note_ticks(&self, host: &str, connected_mono: u64, now_mono: u64) {
        if connected_mono == 0 || !self.is_running() {
            return;
        }
        let since = connected_mono
            .max(self.running_since_mono_ms.load(Ordering::Relaxed))
            .max(self.last_progress_mono_ms.load(Ordering::Relaxed));
        let quiet_secs = now_mono.saturating_sub(since) / 1000;
        if quiet_secs >= link::WATCHDOG_STALL_SECS
            && !self.quiet_warned.swap(true, Ordering::Relaxed)
        {
            log::warn!(
                "link: {} has ticked for {quiet_secs}s while the message walk had no page \
                 answered — messages may be late on this socket (no verdict)",
                link::sanitize_node_text(host)
            );
        }
    }
}

// ── The transport matcher ────────────────────────────────────────────────────

/// **P2.1's scan, moved onto accepted transactions.** `ciph_msg:` and
/// `kchat:` payloads by the same [`transport::parse_payload_in`]; the matches
/// go to the observers (the dev wire view) and are folded by the hub; their
/// acceptance goes to the tracker. Only matches ever leave the chain crate.
pub(crate) struct TransportMatcher {
    prefix: Prefix,
    events: broadcast::Sender<TransportEvent>,
    tracker: Arc<Mutex<Option<mpsc::UnboundedSender<TrackerFeed>>>>,
    devab: Arc<DevAb>,
    sink: Mutex<Option<Arc<dyn MessageSink>>>,
}

impl TransportMatcher {
    pub(crate) fn new(
        prefix: Prefix,
        events: broadcast::Sender<TransportEvent>,
        tracker: Arc<Mutex<Option<mpsc::UnboundedSender<TrackerFeed>>>>,
        devab: Arc<DevAb>,
    ) -> Arc<Self> {
        Arc::new(Self {
            prefix,
            events,
            tracker,
            devab,
            sink: Mutex::new(None),
        })
    }

    /// The hub that folds from now on (set at every arm, before the walk runs).
    pub(crate) fn set_sink(&self, sink: Arc<dyn MessageSink>) {
        *self.sink.lock().unwrap_or_else(PoisonError::into_inner) = Some(sink);
    }

    /// Hand the tracker what this page removed and what it accepted of ours.
    /// AFTER the fold, on purpose: a watch or a sender lookup the fold just
    /// registered is then already there when the tracker reads these facts, and
    /// one registered later (a sender resolved afterwards) finds them in the
    /// tracker's bounded memory (`acceptance.rs`, `fold_walk`).
    fn feed_tracker(&self, removed: &[Hash], accepted: Vec<WalkAcceptance>) {
        if removed.is_empty() && accepted.is_empty() {
            return;
        }
        let sender = self
            .tracker
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        if let Some(sender) = sender {
            let _ = sender.send(TrackerFeed::Walk(WalkBatch {
                removed_chain_block_hashes: Arc::new(removed.to_vec()),
                accepted,
            }));
        }
    }
}

impl WalkMatcher for TransportMatcher {
    fn fold_page<'a>(&'a self, page: &'a WalkPage) -> VerdictFuture<'a> {
        Box::pin(async move {
            let (matches, accepted) = scan_page(page, self.prefix);
            let verdict = if matches.is_empty() {
                Verdict::Folded
            } else {
                // LINK-Q3's parity window: inert unless the dev flags are on.
                self.devab.on_walk_matches(&matches);
                // Three-lights producer line (V3/L55): counts only, never a
                // body (§4). `info`: the liblog lane is Info-max (L53).
                log::info!(
                    "walk: transport emit matches={} receivers={}",
                    matches.len(),
                    self.events.receiver_count()
                );
                for event in &matches {
                    // Observers only; zero of them is fine.
                    let _ = self.events.send(event.clone());
                }
                let sink = self
                    .sink
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                match sink {
                    Some(sink) => sink.fold(matches).await,
                    // Matches and nobody to fold them: never pass them.
                    None => Verdict::Held,
                }
            };
            self.feed_tracker(page.removed(), accepted);
            verdict
        })
    }
}

/// The page's transport matches in chain order, and for each chain block that
/// accepted any, its facts and their txids. Pure over the page.
fn scan_page(page: &WalkPage, prefix: Prefix) -> (Vec<TransportEvent>, Vec<WalkAcceptance>) {
    let mut matches = Vec::new();
    let mut accepted = Vec::new();
    for (block, entry) in page.blocks() {
        let mut txids = Vec::new();
        for tx in &entry.accepted_transactions {
            if let Some(event) = transport::scan_accepted(tx, prefix) {
                if let Some(txid) = tx.verbose_data.as_ref().and_then(|v| v.transaction_id) {
                    txids.push(txid);
                }
                matches.push(event);
            }
        }
        if txids.is_empty() {
            continue;
        }
        let header = &entry.chain_block_header;
        match (header.blue_score, header.daa_score, header.timestamp) {
            (Some(blue_score), Some(daa_score), Some(timestamp_ms)) => {
                accepted.push(WalkAcceptance {
                    accepting_block: block,
                    blue_score,
                    daa_score,
                    timestamp_ms,
                    txids,
                })
            }
            _ => log::info!(
                "walk: chain block {block} came without its blue score, DAA score or time — \
                 {} acceptance(s) not handed to the tracker",
                txids.len()
            ),
        }
    }
    (matches, accepted)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use kaspa_rpc_core::{
        RpcOptionalHeader, RpcOptionalTransaction, RpcOptionalTransactionOutput,
        RpcOptionalTransactionVerboseData,
    };
    use std::collections::{HashMap, VecDeque};

    pub(crate) fn h(n: u8) -> Hash {
        Hash::from_bytes([n; 32])
    }

    fn test_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kv-walk-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    /// A message transaction as V2 at High sends it: payload, one output to
    /// `address`, the carrying block in its verbose data.
    pub(crate) fn message_tx(txid: Hash, payload: &[u8], carrying: Hash) -> RpcOptionalTransaction {
        let address = kaspa_addresses::Address::try_from(
            // Upstream gen1 mainnet vector (the transport tests' `DEST`).
            "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf",
        )
        .expect("a valid address");
        RpcOptionalTransaction {
            version: None,
            inputs: Vec::new(),
            outputs: vec![RpcOptionalTransactionOutput {
                value: Some(20_000_000),
                script_public_key: Some(kaspa_txscript::pay_to_address_script(&address)),
                verbose_data: None,
                covenant: None,
            }],
            lock_time: None,
            subnetwork_id: None,
            gas: None,
            payload: Some(payload.to_vec()),
            storage_mass: None,
            verbose_data: Some(RpcOptionalTransactionVerboseData {
                transaction_id: Some(txid),
                hash: None,
                compute_mass: None,
                block_hash: Some(carrying),
                block_time: Some(1_700_000_000_000),
            }),
        }
    }

    fn plain_tx(txid: Hash) -> RpcOptionalTransaction {
        let mut tx = message_tx(txid, b"just a transfer", h(0xEE));
        tx.payload = Some(Vec::new());
        tx
    }

    pub(crate) fn chain_entry(
        block: Hash,
        time_ms: u64,
        txs: Vec<RpcOptionalTransaction>,
    ) -> RpcChainBlockAcceptedTransactions {
        RpcChainBlockAcceptedTransactions {
            chain_block_header: RpcOptionalHeader {
                hash: Some(block),
                timestamp: Some(time_ms),
                daa_score: Some(1_000 + time_ms),
                blue_score: Some(500 + time_ms),
                ..Default::default()
            },
            accepted_transactions: txs,
        }
    }

    pub(crate) fn response(
        removed: Vec<Hash>,
        added: Vec<RpcChainBlockAcceptedTransactions>,
    ) -> GetVirtualChainFromBlockV2Response {
        GetVirtualChainFromBlockV2Response {
            removed_chain_block_hashes: Arc::new(removed),
            added_chain_block_hashes: Arc::new(
                added
                    .iter()
                    .map(|e| e.chain_block_header.hash.expect("a hash"))
                    .collect(),
            ),
            chain_block_accepted_transactions: Arc::new(added),
        }
    }

    /// Queued in place of a page: the node does not answer inside the timeout.
    const TIMEOUT: &str = "TIMEOUT";
    /// Queued in place of a page: no socket was bound when the call was made.
    const NOSOCKET: &str = "NOSOCKET";
    /// Queued in place of a page: the socket died under the call.
    const LOST: &str = "LOST";

    /// A scripted node: answers each `from` with the pages queued for it, in
    /// order, else an empty page at the tip; knows a sink; records every call.
    #[derive(Default)]
    struct FakeChain {
        pages: Mutex<
            HashMap<
                Hash,
                VecDeque<std::result::Result<GetVirtualChainFromBlockV2Response, String>>,
            >,
        >,
        sink: Mutex<Option<Hash>>,
        calls: Mutex<Vec<Hash>>,
    }

    impl FakeChain {
        fn queue(
            &self,
            from: Hash,
            page: std::result::Result<GetVirtualChainFromBlockV2Response, String>,
        ) {
            self.pages
                .lock()
                .unwrap()
                .entry(from)
                .or_default()
                .push_back(page);
        }
        fn calls(&self) -> Vec<Hash> {
            self.calls.lock().unwrap().clone()
        }
    }

    #[async_trait]
    impl ChainSource for FakeChain {
        async fn page(
            &self,
            from: Hash,
        ) -> std::result::Result<GetVirtualChainFromBlockV2Response, PageError> {
            self.calls.lock().unwrap().push(from);
            match self
                .pages
                .lock()
                .unwrap()
                .get_mut(&from)
                .and_then(VecDeque::pop_front)
            {
                // A queued `TIMEOUT` is the node not answering in time.
                Some(Err(e)) if e == TIMEOUT => Err(PageError::TimedOut),
                Some(Err(e)) if e == NOSOCKET => Err(PageError::NoSocket),
                Some(Err(e)) if e == LOST => Err(PageError::SocketLost),
                Some(Err(e)) => Err(PageError::Refused(e)),
                Some(Ok(page)) => Ok(page),
                None => Ok(response(Vec::new(), Vec::new())),
            }
        }
        async fn sink(&self) -> std::result::Result<Hash, String> {
            self.sink
                .lock()
                .unwrap()
                .ok_or_else(|| "no sink".to_string())
        }
    }

    /// What a recorder saw of one page: where it started, what it removed,
    /// which chain blocks it folded.
    type Seen = (Hash, Vec<Hash>, Vec<Hash>);

    /// A matcher that records every page it saw and answers as told.
    #[derive(Default)]
    struct Recorder {
        seen: Mutex<Vec<Seen>>,
        hold: AtomicBool,
        gaps: Mutex<Vec<(Hash, Hash)>>,
    }

    impl WalkMatcher for Recorder {
        fn fold_page<'a>(&'a self, page: &'a WalkPage) -> VerdictFuture<'a> {
            Box::pin(async move {
                self.seen.lock().unwrap().push((
                    page.from,
                    page.removed().to_vec(),
                    page.blocks().map(|(b, _)| b).collect(),
                ));
                if self.hold.load(Ordering::SeqCst) {
                    Verdict::Held
                } else {
                    Verdict::Folded
                }
            })
        }
        fn on_gap(&self, from: Hash, to: Hash) {
            self.gaps.lock().unwrap().push((from, to));
        }
    }

    fn walk_with(recorder: &Arc<Recorder>) -> Arc<Walk> {
        Walk::new(vec![recorder.clone() as Arc<dyn WalkMatcher>])
    }

    /// Chain blocks `first..first+n` as page entries, one per 100 ms.
    fn blocks(first: u8, n: u8) -> Vec<RpcChainBlockAcceptedTransactions> {
        (first..first + n)
            .map(|b| chain_entry(h(b), u64::from(b) * 100, Vec::new()))
            .collect()
    }

    /// A long page: at least the tip threshold, so the run keeps going.
    fn long_page(first: u8) -> GetVirtualChainFromBlockV2Response {
        let mut added = blocks(first, 1);
        added.extend((0..WALK_TIP_PAGE_THRESHOLD as u32).map(|i| {
            let mut bytes = [first; 32];
            bytes[0..4].copy_from_slice(&i.to_le_bytes());
            chain_entry(Hash::from_bytes(bytes), 1, Vec::new())
        }));
        response(Vec::new(), added)
    }

    /// **The first arm seeds at the sink and replays nothing** (no prior
    /// session could have missed anything), and the seed is written at once.
    #[tokio::test]
    async fn the_first_arm_seeds_at_the_sink() {
        let dir = test_dir("seed");
        let chain = FakeChain::default();
        *chain.sink.lock().unwrap() = Some(h(9));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(9)));
        assert_eq!(read_cursor(&dir.join("scan.cursor")), Some(h(9)));
        assert!(chain.calls().is_empty(), "a seed fetches no page");
        assert!(recorder.seen.lock().unwrap().is_empty());
        assert!(
            recorder.gaps.lock().unwrap().is_empty(),
            "a first seed skips nothing"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A live page commits its last chain block**, in chain order, and the
    /// next run starts from it.
    #[tokio::test]
    async fn a_page_is_folded_then_its_last_block_committed() {
        let dir = test_dir("live");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = FakeChain::default();
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 3))));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(4)));
        assert_eq!(
            recorder.seen.lock().unwrap().clone(),
            vec![(h(1), vec![], vec![h(2), h(3), h(4)])]
        );
        walk.run_to_tip(&chain).await;
        assert_eq!(
            chain.calls(),
            vec![h(1), h(4)],
            "the next run starts at the commit"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **The locked vault holds the cursor** (deliverable 4). A matcher that
    /// cannot fold stops the walk at the page's START: nothing after it is
    /// fetched, the cursor file says where to resume, and the next arm replays
    /// the same page. Mutation: committing on `Held` reds the second assert.
    #[tokio::test]
    async fn a_held_page_keeps_its_start_and_the_next_arm_replays_it() {
        let dir = test_dir("held");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        write_cursor(&path, &h(1));
        let chain = FakeChain::default();
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 2))));
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 2))));
        let recorder = Arc::new(Recorder::default());
        recorder.hold.store(true, Ordering::SeqCst);
        let walk = walk_with(&recorder);
        walk.arm(path.clone());
        walk.run_to_tip(&chain).await;
        assert!(!walk.is_running(), "a held page stops the walk");
        assert_eq!(
            walk.cursor(),
            Some(h(1)),
            "the cursor stays at the page's start"
        );
        assert_eq!(read_cursor(&path), Some(h(1)));
        walk.run_to_tip(&chain).await;
        assert_eq!(chain.calls(), vec![h(1)], "no fetch while held");

        recorder.hold.store(false, Ordering::SeqCst);
        walk.arm(path.clone());
        walk.run_to_tip(&chain).await;
        assert_eq!(
            chain.calls(),
            vec![h(1), h(1)],
            "the arm replays the held page"
        );
        assert_eq!(walk.cursor(), Some(h(3)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A hold that lands during a fetch discards the page** rather than
    /// folding it for a consumer that has gone (the vault locked mid-call).
    #[tokio::test]
    async fn a_hold_during_a_fetch_folds_nothing() {
        struct HoldingChain {
            walk: Mutex<Option<Arc<Walk>>>,
        }
        #[async_trait]
        impl ChainSource for HoldingChain {
            async fn page(
                &self,
                _from: Hash,
            ) -> std::result::Result<GetVirtualChainFromBlockV2Response, PageError> {
                if let Some(walk) = self.walk.lock().unwrap().as_ref() {
                    walk.hold("test: the vault locked mid-call");
                }
                Ok(response(Vec::new(), blocks(2, 2)))
            }
            async fn sink(&self) -> std::result::Result<Hash, String> {
                Ok(h(9))
            }
        }
        let dir = test_dir("hold-fetch");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        let chain = HoldingChain {
            walk: Mutex::new(Some(walk.clone())),
        };
        walk.arm(dir.join("scan.cursor"));
        walk.run_to_tip(&chain).await;
        assert!(
            recorder.seen.lock().unwrap().is_empty(),
            "folded after a hold"
        );
        assert_eq!(walk.cursor(), Some(h(1)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A reconnect gap is replayed by construction** (product-audit run 2,
    /// F4; what the old `ReplayGap` guarded). While the socket is down every
    /// page call fails and the cursor stays where the last fold left it; when
    /// the socket is back, the next run walks the gap from there. No bound is
    /// taken at the drop and none can be read too late: the cursor never moves
    /// past anything unfolded.
    #[tokio::test(start_paused = true)]
    async fn a_reconnect_gap_is_replayed_from_the_committed_cursor() {
        let dir = test_dir("reconnect");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = FakeChain::default();
        // The node could name a sink: a walk that re-seeded on a dead socket
        // would take it and skip the gap, so the test can see that go wrong.
        *chain.sink.lock().unwrap() = Some(h(99));
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 1))));
        for _ in 0..WALK_PAGE_ATTEMPTS {
            chain.queue(h(2), Err(NOSOCKET.to_string()));
        }
        chain.queue(h(2), Ok(response(Vec::new(), blocks(3, 4))));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(2)));
        walk.run_to_tip(&chain).await; // the socket is down: eight failures
        assert_eq!(walk.cursor(), Some(h(2)), "a dead socket moves nothing");
        walk.socket_published(); // reconnected: a new socket
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(6)));
        let seen = recorder.seen.lock().unwrap().clone();
        assert_eq!(
            seen.last().unwrap().2,
            vec![h(3), h(4), h(5), h(6)],
            "the whole gap"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **`hold` + `quiesce` leave no fold running and none able to start** —
    /// the hub restarts on a store with one writer. A run whose fetch returns
    /// after the hold folds nothing.
    #[tokio::test]
    async fn after_hold_and_quiesce_no_fold_runs() {
        struct SlowChain {
            walk: Mutex<Option<Arc<Walk>>>,
            entered: Notify,
            release: Notify,
        }
        #[async_trait]
        impl ChainSource for SlowChain {
            async fn page(
                &self,
                _from: Hash,
            ) -> std::result::Result<GetVirtualChainFromBlockV2Response, PageError> {
                self.entered.notify_one();
                self.release.notified().await;
                Ok(response(Vec::new(), blocks(2, 1)))
            }
            async fn sink(&self) -> std::result::Result<Hash, String> {
                Ok(h(9))
            }
        }
        let dir = test_dir("quiesce");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        let chain = Arc::new(SlowChain {
            walk: Mutex::new(None),
            entered: Notify::new(),
            release: Notify::new(),
        });
        *chain.walk.lock().unwrap() = Some(walk.clone());
        walk.arm(dir.join("scan.cursor"));
        let run = {
            let (walk, chain) = (walk.clone(), chain.clone());
            tokio::spawn(async move { walk.run_to_tip(&*chain).await })
        };
        chain.entered.notified().await; // the fetch is in flight
        walk.hold("test: the hub restarts");
        walk.quiesce().await;
        chain.release.notify_one(); // the fetch returns after the hold
        run.await.unwrap();
        assert!(
            recorder.seen.lock().unwrap().is_empty(),
            "a fold ran after hold + quiesce"
        );
        assert_eq!(walk.cursor(), Some(h(1)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **`quiesce` waits out a fold in flight**: the hub restarting on a new
    /// store must not share it with the previous hub's last page. Mutation: a
    /// `quiesce` that does not take the gate returns while the fold runs.
    #[tokio::test]
    async fn quiesce_waits_for_a_fold_in_flight() {
        struct Blocking {
            entered: Notify,
            release: Notify,
            done: AtomicBool,
        }
        impl WalkMatcher for Blocking {
            fn fold_page<'a>(&'a self, _page: &'a WalkPage) -> VerdictFuture<'a> {
                Box::pin(async move {
                    self.entered.notify_one();
                    self.release.notified().await;
                    self.done.store(true, Ordering::SeqCst);
                    Verdict::Folded
                })
            }
        }
        let dir = test_dir("quiesce-fold");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = Arc::new(FakeChain::default());
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 1))));
        let matcher = Arc::new(Blocking {
            entered: Notify::new(),
            release: Notify::new(),
            done: AtomicBool::new(false),
        });
        let walk = Walk::new(vec![matcher.clone() as Arc<dyn WalkMatcher>]);
        walk.arm(dir.join("scan.cursor"));
        let run = {
            let (walk, chain) = (walk.clone(), chain.clone());
            tokio::spawn(async move { walk.run_to_tip(&*chain).await })
        };
        matcher.entered.notified().await; // the fold is in flight
        walk.hold("test: the hub restarts");
        let quiesced = {
            let walk = walk.clone();
            tokio::spawn(async move { walk.quiesce().await })
        };
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(
            !quiesced.is_finished(),
            "quiesce returned while a fold was in flight"
        );
        matcher.release.notify_one();
        quiesced.await.unwrap();
        assert!(
            matcher.done.load(Ordering::SeqCst),
            "quiesce returned before the fold ended"
        );
        run.await.unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **Catch-up is the same walk** (deliverable 3): long pages follow each
    /// other without a poke, forced to disk each time, and the first short page
    /// ends the run.
    #[tokio::test]
    async fn long_pages_walk_on_and_a_short_page_ends_the_run() {
        let dir = test_dir("catchup");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        write_cursor(&path, &h(1));
        let chain = FakeChain::default();
        let first = long_page(10);
        let first_last = *first.added_chain_block_hashes.last().unwrap();
        chain.queue(h(1), Ok(first));
        chain.queue(first_last, Ok(response(Vec::new(), blocks(40, 2))));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(path.clone());
        walk.run_to_tip(&chain).await;
        assert_eq!(chain.calls(), vec![h(1), first_last]);
        assert_eq!(walk.cursor(), Some(h(41)));
        assert_eq!(
            read_cursor(&path),
            Some(h(41)),
            "catch-up pages write at once"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **The budget ends a long gap at the sink, naming it**, rather than
    /// walking an unbounded download on the funds lane's socket.
    #[tokio::test]
    async fn a_spent_budget_reseeds_at_the_sink() {
        let dir = test_dir("budget");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        write_cursor(&path, &h(1));
        let chain = FakeChain::default();
        *chain.sink.lock().unwrap() = Some(h(250));
        let mut from = h(1);
        for n in 0..MAX_WALK_PAGES + 2 {
            let page = long_page(20 + n as u8);
            let last = *page.added_chain_block_hashes.last().unwrap();
            chain.queue(from, Ok(page));
            from = last;
        }
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(path.clone());
        walk.run_to_tip(&chain).await;
        assert_eq!(chain.calls().len(), MAX_WALK_PAGES as usize);
        assert_eq!(walk.cursor(), Some(h(250)));
        assert_eq!(read_cursor(&path), Some(h(250)));
        let gaps = recorder.gaps.lock().unwrap().clone();
        assert_eq!(gaps.len(), 1, "the skip is told to every matcher");
        assert_eq!(gaps[0].1, h(250));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A cursor the node does not know re-seeds at the sink** (pruned, or
    /// never on this chain); **a node that cannot answer keeps the cursor.**
    /// The two must never be confused: re-seeding on a dead socket would skip
    /// the very gap the walk exists to replay.
    #[tokio::test(start_paused = true)]
    async fn only_an_unknown_cursor_reseeds() {
        let dir = test_dir("unknown");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        write_cursor(&path, &h(1));
        let chain = FakeChain::default();
        *chain.sink.lock().unwrap() = Some(h(77));
        for _ in 0..WALK_PAGE_ATTEMPTS {
            chain.queue(h(1), Err(NOSOCKET.to_string()));
        }
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(path.clone());
        walk.run_to_tip(&chain).await;
        assert_eq!(chain.calls().len(), WALK_PAGE_ATTEMPTS as usize);
        assert_eq!(
            walk.cursor(),
            Some(h(1)),
            "an unreachable node keeps the cursor"
        );

        // A bound socket that refuses the page for a reason the walk does not
        // recognise (a dying client, a node mid-IBD) keeps the cursor too: it
        // is a failed run, never a re-seed (`wallet-security-auditor`, W4).
        for _ in 0..WALK_PAGE_ATTEMPTS {
            chain.queue(
                h(1),
                Err(
                    "RPC Server (remote error) -> Consensus is in transitional IBD state"
                        .to_string(),
                ),
            );
        }
        walk.run_to_tip(&chain).await;
        assert_eq!(chain.calls().len(), 2 * WALK_PAGE_ATTEMPTS as usize);
        assert_eq!(
            walk.cursor(),
            Some(h(1)),
            "a refusing node keeps the cursor"
        );
        assert!(recorder.gaps.lock().unwrap().is_empty());

        let refused = format!(
            "RPC Server (remote error) -> {}",
            ConsensusError::HeaderNotFound(h(1))
        );
        chain.queue(h(1), Err(refused));
        tokio::time::sleep(FAILED_RUN_BACKOFF_CAP).await; // the failed run's pause
        walk.run_to_tip(&chain).await;
        assert_eq!(
            walk.cursor(),
            Some(h(77)),
            "an unknown cursor re-seeds at the sink"
        );
        assert_eq!(read_cursor(&path), Some(h(77)));
        assert_eq!(recorder.gaps.lock().unwrap().clone(), vec![(h(1), h(77))]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A page the node does not answer in time ends the run** — one call,
    /// never the retry loop (its late reply may still be streaming on the one
    /// socket) — and the next run waits out the pause, whatever pokes land.
    #[tokio::test(start_paused = true)]
    async fn a_timed_out_page_ends_the_run_and_waits_before_asking_again() {
        let dir = test_dir("timeout");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = FakeChain::default();
        *chain.sink.lock().unwrap() = Some(h(88));
        chain.queue(h(1), Err(TIMEOUT.to_string()));
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 1))));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        walk.run_to_tip(&chain).await;
        assert_eq!(
            chain.calls().len(),
            1,
            "a timed-out page is asked once per run"
        );
        assert_eq!(walk.cursor(), Some(h(1)));
        walk.run_to_tip(&chain).await; // a poke inside the pause
        assert_eq!(chain.calls().len(), 1, "no call inside the pause");
        tokio::time::sleep(FAILED_RUN_BACKOFF).await;
        walk.run_to_tip(&chain).await;
        assert_eq!(chain.calls().len(), 2);
        assert_eq!(walk.cursor(), Some(h(2)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A page the node cannot serve re-seeds after three runs, naming the
    /// gap** (`consensus-auditor`, LINK-Q3): the node answers its sink, so it is
    /// alive and simply cannot carry the page; without the bound the walk
    /// would ask forever and live messages would stop behind the cursor.
    #[tokio::test(start_paused = true)]
    async fn a_page_the_node_cannot_serve_three_runs_reseeds_naming_the_gap() {
        let dir = test_dir("unservable");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = FakeChain::default();
        *chain.sink.lock().unwrap() = Some(h(88));
        for _ in 0..MAX_FAILED_RUNS {
            chain.queue(h(1), Err(TIMEOUT.to_string()));
        }
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        for run in 1..=MAX_FAILED_RUNS {
            walk.run_to_tip(&chain).await;
            let want = if run < MAX_FAILED_RUNS { h(1) } else { h(88) };
            assert_eq!(walk.cursor(), Some(want), "after failed run {run}");
            tokio::time::sleep(FAILED_RUN_BACKOFF_CAP).await;
        }
        assert_eq!(recorder.gaps.lock().unwrap().clone(), vec![(h(1), h(88))]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A new socket does not forgive a page the link cannot carry**
    /// (`consensus-auditor`, LINK-Q3, the heartbeat variant). A page too large
    /// for the link silences the socket's ticks, the silence deadline swaps the
    /// socket, and the page dies with it: every call publishes a new socket and
    /// fails. The count survives the publishes, so the third failed run
    /// re-seeds and names the gap, where a count reset on every publish would
    /// ask forever.
    #[tokio::test(start_paused = true)]
    async fn a_new_socket_does_not_forgive_a_page_the_link_cannot_carry() {
        struct SwappingChain {
            walk: Mutex<Option<Arc<Walk>>>,
            calls: AtomicU64,
        }
        #[async_trait]
        impl ChainSource for SwappingChain {
            async fn page(
                &self,
                _from: Hash,
            ) -> std::result::Result<GetVirtualChainFromBlockV2Response, PageError> {
                self.calls.fetch_add(1, Ordering::SeqCst);
                if let Some(walk) = self.walk.lock().unwrap().as_ref() {
                    walk.socket_published(); // the swap lands mid-call
                }
                Err(PageError::SocketLost)
            }
            async fn sink(&self) -> std::result::Result<Hash, String> {
                Ok(h(88))
            }
        }
        let dir = test_dir("streak");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        let chain = SwappingChain {
            walk: Mutex::new(Some(walk.clone())),
            calls: AtomicU64::new(0),
        };
        walk.arm(dir.join("scan.cursor"));
        for _ in 0..MAX_FAILED_RUNS {
            walk.run_to_tip(&chain).await;
            tokio::time::sleep(FAILED_RUN_BACKOFF_CAP).await;
        }
        assert_eq!(
            chain.calls.load(Ordering::SeqCst),
            u64::from(MAX_FAILED_RUNS),
            "one call per run"
        );
        assert_eq!(walk.cursor(), Some(h(88)), "the third lost page re-seeds");
        assert_eq!(recorder.gaps.lock().unwrap().clone(), vec![(h(1), h(88))]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A run that found no socket at all is never counted**: nothing was
    /// asked of any node (still dialing, or paused). However many such runs,
    /// the cursor stays, nothing re-seeds, and no pause holds the next run.
    #[tokio::test(start_paused = true)]
    async fn a_run_with_no_socket_is_never_counted() {
        let dir = test_dir("nosocket");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = FakeChain::default();
        *chain.sink.lock().unwrap() = Some(h(88));
        for _ in 0..(MAX_FAILED_RUNS + 1) * WALK_PAGE_ATTEMPTS {
            chain.queue(h(1), Err(NOSOCKET.to_string()));
        }
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 1))));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        for _ in 0..=MAX_FAILED_RUNS {
            walk.run_to_tip(&chain).await;
        }
        assert_eq!(walk.cursor(), Some(h(1)));
        assert!(recorder.gaps.lock().unwrap().is_empty());
        walk.run_to_tip(&chain).await; // the socket is back: no pause to wait out
        assert_eq!(walk.cursor(), Some(h(2)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A failed call is classified by the socket bound before and after it,
    /// never by its text.
    #[test]
    fn a_page_failure_is_classified_by_the_socket_not_the_text() {
        let text = || "anything at all".to_string();
        assert_eq!(page_error(None, None, text()), PageError::NoSocket);
        assert_eq!(page_error(None, Some(7), text()), PageError::NoSocket);
        assert_eq!(page_error(Some(7), None, text()), PageError::SocketLost);
        assert_eq!(page_error(Some(7), Some(8), text()), PageError::SocketLost);
        assert_eq!(
            page_error(Some(7), Some(7), text()),
            PageError::Refused(text())
        );
    }

    /// **A failure that outlived its arm is not counted** (`wallet-security-
    /// auditor`): the vault locked and unlocked while a page call hung; its
    /// late timeout must not pause the new arm's replay.
    #[tokio::test(start_paused = true)]
    async fn a_failure_from_a_previous_arm_is_not_counted() {
        struct RearmingChain {
            walk: Mutex<Option<Arc<Walk>>>,
            path: PathBuf,
            calls: AtomicU64,
        }
        #[async_trait]
        impl ChainSource for RearmingChain {
            async fn page(
                &self,
                _from: Hash,
            ) -> std::result::Result<GetVirtualChainFromBlockV2Response, PageError> {
                if self.calls.fetch_add(1, Ordering::SeqCst) == 0 {
                    if let Some(walk) = self.walk.lock().unwrap().as_ref() {
                        walk.hold("test: locked mid-call");
                        walk.arm(self.path.clone());
                    }
                    return Err(PageError::TimedOut);
                }
                Ok(response(Vec::new(), blocks(2, 1)))
            }
            async fn sink(&self) -> std::result::Result<Hash, String> {
                Ok(h(88))
            }
        }
        let dir = test_dir("rearm");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        write_cursor(&path, &h(1));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        let chain = RearmingChain {
            walk: Mutex::new(Some(walk.clone())),
            path: path.clone(),
            calls: AtomicU64::new(0),
        };
        walk.arm(path);
        walk.run_to_tip(&chain).await; // the old arm's call times out late
        walk.run_to_tip(&chain).await; // the new arm's run: no pause inherited
        assert_eq!(chain.calls.load(Ordering::SeqCst), 2);
        assert_eq!(walk.cursor(), Some(h(2)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **An owed re-seed is paid before the page is asked for again**
    /// (`consensus-auditor`, round 3). The third lost page fails at a moment
    /// nothing is bound, so the sink cannot be read and the re-seed is owed;
    /// the next run pays it without asking for the page a fourth time.
    /// Mutation: dropping the owed branch asks the page again (four calls).
    #[tokio::test(start_paused = true)]
    async fn an_owed_reseed_is_paid_before_the_page_is_asked_again() {
        struct LosingChain {
            calls: AtomicU64,
            lost_just_now: AtomicBool,
        }
        #[async_trait]
        impl ChainSource for LosingChain {
            async fn page(
                &self,
                _from: Hash,
            ) -> std::result::Result<GetVirtualChainFromBlockV2Response, PageError> {
                self.calls.fetch_add(1, Ordering::SeqCst);
                self.lost_just_now.store(true, Ordering::SeqCst);
                Err(PageError::SocketLost)
            }
            async fn sink(&self) -> std::result::Result<Hash, String> {
                // Right after a lost socket nothing is bound yet.
                if self.lost_just_now.swap(false, Ordering::SeqCst) {
                    return Err("link: no bound socket".to_string());
                }
                Ok(h(88))
            }
        }
        let dir = test_dir("owed");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = LosingChain {
            calls: AtomicU64::new(0),
            lost_just_now: AtomicBool::new(false),
        };
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        for _ in 0..=MAX_FAILED_RUNS {
            walk.run_to_tip(&chain).await;
            tokio::time::sleep(FAILED_RUN_BACKOFF_CAP).await;
        }
        assert_eq!(
            chain.calls.load(Ordering::SeqCst),
            u64::from(MAX_FAILED_RUNS),
            "the page is not asked for after the third loss"
        );
        assert_eq!(walk.cursor(), Some(h(88)), "the owed re-seed was paid");
        assert_eq!(recorder.gaps.lock().unwrap().clone(), vec![(h(1), h(88))]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A re-seed that straddles a lock and an unlock pays nothing for the old
    /// arm** (`wallet-security-auditor`, round 4). The debt is owed; the vault
    /// locks and unlocks while the sink read is out; the answer lands under
    /// the new arm and must not move its cursor — the unlock promised to replay
    /// from there. The new arm asks for the page again instead.
    #[tokio::test(start_paused = true)]
    async fn a_reseed_across_a_rearm_pays_nothing_for_the_old_arm() {
        struct RearmOnSink {
            walk: Mutex<Option<Arc<Walk>>>,
            path: PathBuf,
            calls: AtomicU64,
            lost_just_now: AtomicBool,
        }
        #[async_trait]
        impl ChainSource for RearmOnSink {
            async fn page(
                &self,
                _from: Hash,
            ) -> std::result::Result<GetVirtualChainFromBlockV2Response, PageError> {
                self.calls.fetch_add(1, Ordering::SeqCst);
                self.lost_just_now.store(true, Ordering::SeqCst);
                Err(PageError::SocketLost)
            }
            async fn sink(&self) -> std::result::Result<Hash, String> {
                if self.lost_just_now.swap(false, Ordering::SeqCst) {
                    return Err("link: no bound socket".to_string());
                }
                if let Some(walk) = self.walk.lock().unwrap().as_ref() {
                    walk.hold("test: locked during the sink read");
                    walk.arm(self.path.clone());
                }
                Ok(h(88))
            }
        }
        let dir = test_dir("reseed-rearm");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        write_cursor(&path, &h(1));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        let chain = RearmOnSink {
            walk: Mutex::new(Some(walk.clone())),
            path: path.clone(),
            calls: AtomicU64::new(0),
            lost_just_now: AtomicBool::new(false),
        };
        walk.arm(path);
        for _ in 0..MAX_FAILED_RUNS {
            walk.run_to_tip(&chain).await;
            tokio::time::sleep(FAILED_RUN_BACKOFF_CAP).await;
        }
        walk.run_to_tip(&chain).await; // the owed re-seed; the arm changes under it
        assert_eq!(
            walk.cursor(),
            Some(h(1)),
            "the old arm's debt moved the new arm's cursor"
        );
        assert!(recorder.gaps.lock().unwrap().is_empty());
        walk.run_to_tip(&chain).await; // the new arm asks for the page again
        assert_eq!(
            chain.calls.load(Ordering::SeqCst),
            u64::from(MAX_FAILED_RUNS) + 1
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A failed sink read that outlives its arm does not pause the new arm**
    /// (both auditors, round 5): the vault locks and unlocks while the owed
    /// re-seed's sink read is out, and the read then fails. The new arm's first
    /// run must ask for its page at once, not sit out the old arm's pause.
    #[tokio::test(start_paused = true)]
    async fn a_failed_sink_read_across_a_rearm_does_not_pause_the_new_arm() {
        struct RearmThenFail {
            walk: Mutex<Option<Arc<Walk>>>,
            path: PathBuf,
            calls: AtomicU64,
            lost_just_now: AtomicBool,
        }
        #[async_trait]
        impl ChainSource for RearmThenFail {
            async fn page(
                &self,
                _from: Hash,
            ) -> std::result::Result<GetVirtualChainFromBlockV2Response, PageError> {
                self.calls.fetch_add(1, Ordering::SeqCst);
                self.lost_just_now.store(true, Ordering::SeqCst);
                Err(PageError::SocketLost)
            }
            async fn sink(&self) -> std::result::Result<Hash, String> {
                if !self.lost_just_now.swap(false, Ordering::SeqCst) {
                    if let Some(walk) = self.walk.lock().unwrap().as_ref() {
                        walk.hold("test: locked during the sink read");
                        walk.arm(self.path.clone());
                    }
                }
                Err("link: no bound socket".to_string())
            }
        }
        let dir = test_dir("sink-fail-rearm");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        write_cursor(&path, &h(1));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        let chain = RearmThenFail {
            walk: Mutex::new(Some(walk.clone())),
            path: path.clone(),
            calls: AtomicU64::new(0),
            lost_just_now: AtomicBool::new(false),
        };
        walk.arm(path);
        for _ in 0..MAX_FAILED_RUNS {
            walk.run_to_tip(&chain).await;
            tokio::time::sleep(FAILED_RUN_BACKOFF_CAP).await;
        }
        walk.run_to_tip(&chain).await; // the owed read: re-armed under it, then fails
        walk.run_to_tip(&chain).await; // no sleep: the new arm is not paused
        assert_eq!(
            chain.calls.load(Ordering::SeqCst),
            u64::from(MAX_FAILED_RUNS) + 1,
            "the new arm sat out the old arm's pause"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A failed sink read never shortens a longer pause**: the third
    /// failure's pause (8 s) stands, though its re-seed's sink read failed
    /// and asked for only a flat 2 s.
    #[tokio::test(start_paused = true)]
    async fn a_failed_sink_read_never_shortens_the_third_failures_pause() {
        struct Counting {
            pages: AtomicU64,
            sinks: AtomicU64,
        }
        #[async_trait]
        impl ChainSource for Counting {
            async fn page(
                &self,
                _from: Hash,
            ) -> std::result::Result<GetVirtualChainFromBlockV2Response, PageError> {
                self.pages.fetch_add(1, Ordering::SeqCst);
                Err(PageError::SocketLost)
            }
            async fn sink(&self) -> std::result::Result<Hash, String> {
                self.sinks.fetch_add(1, Ordering::SeqCst);
                Err("link: no bound socket".to_string())
            }
        }
        let dir = test_dir("pause-max");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = Counting {
            pages: AtomicU64::new(0),
            sinks: AtomicU64::new(0),
        };
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        for run in 1..=MAX_FAILED_RUNS {
            walk.run_to_tip(&chain).await;
            if run < MAX_FAILED_RUNS {
                tokio::time::sleep(FAILED_RUN_BACKOFF_CAP).await;
            }
        }
        let (pages, sinks) = (
            chain.pages.load(Ordering::SeqCst),
            chain.sinks.load(Ordering::SeqCst),
        );
        tokio::time::sleep(FAILED_RUN_BACKOFF + Duration::from_secs(1)).await;
        walk.run_to_tip(&chain).await; // inside the third failure's longer pause
        assert_eq!(chain.pages.load(Ordering::SeqCst), pages);
        assert_eq!(
            chain.sinks.load(Ordering::SeqCst),
            sinks,
            "the pause was shortened"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **An unpaid re-seed is paced** (`wallet-security-auditor`, round 4): a
    /// node that refuses its sink fast is asked once per pause, not on every
    /// chain move.
    #[tokio::test(start_paused = true)]
    async fn an_unpaid_reseed_is_paced() {
        struct NoSink {
            sink_calls: AtomicU64,
        }
        #[async_trait]
        impl ChainSource for NoSink {
            async fn page(
                &self,
                _from: Hash,
            ) -> std::result::Result<GetVirtualChainFromBlockV2Response, PageError> {
                Err(PageError::SocketLost)
            }
            async fn sink(&self) -> std::result::Result<Hash, String> {
                self.sink_calls.fetch_add(1, Ordering::SeqCst);
                Err("RPC Server (remote error) -> busy".to_string())
            }
        }
        let dir = test_dir("reseed-paced");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = NoSink {
            sink_calls: AtomicU64::new(0),
        };
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        for _ in 0..MAX_FAILED_RUNS {
            walk.run_to_tip(&chain).await;
            tokio::time::sleep(FAILED_RUN_BACKOFF_CAP).await;
        }
        let before = chain.sink_calls.load(Ordering::SeqCst);
        for _ in 0..5 {
            walk.run_to_tip(&chain).await; // five chain moves inside one pause
        }
        assert_eq!(
            chain.sink_calls.load(Ordering::SeqCst) - before,
            1,
            "an unpaid re-seed asked the sink on every chain move"
        );
        assert_eq!(walk.cursor(), Some(h(1)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The tip test at its edge: one short of the threshold ends the run, the
    /// threshold itself walks on.
    #[tokio::test]
    async fn the_tip_test_reads_the_threshold_exactly() {
        let page_of = |first: u8, n: usize| {
            let added: Vec<_> = (0..n as u32)
                .map(|i| {
                    let mut bytes = [first; 32];
                    bytes[0..4].copy_from_slice(&i.to_le_bytes());
                    chain_entry(Hash::from_bytes(bytes), 1, Vec::new())
                })
                .collect();
            response(Vec::new(), added)
        };
        for (n, runs_on) in [
            (WALK_TIP_PAGE_THRESHOLD - 1, false),
            (WALK_TIP_PAGE_THRESHOLD, true),
        ] {
            let dir = test_dir(&format!("tip-{n}"));
            std::fs::create_dir_all(&dir).unwrap();
            write_cursor(&dir.join("scan.cursor"), &h(1));
            let chain = FakeChain::default();
            chain.queue(h(1), Ok(page_of(0x61, n)));
            let recorder = Arc::new(Recorder::default());
            let walk = walk_with(&recorder);
            walk.arm(dir.join("scan.cursor"));
            walk.run_to_tip(&chain).await;
            assert_eq!(
                chain.calls().len(),
                if runs_on { 2 } else { 1 },
                "a page of {n}"
            );
            let _ = std::fs::remove_dir_all(&dir);
        }
    }

    /// **The quoted node text is bound to the pin it was read at** (INV-9,
    /// `consensus-auditor`): [`RETENTION_ROOT_OFF_CHAIN`] and every node line
    /// this module cites were read at `01b532e`. Any move of the pin reds this
    /// until someone re-reads them (`pin-bump-ritual` Step 4).
    #[test]
    fn the_quoted_node_text_is_bound_to_the_pin_it_was_read_at() {
        let lock = include_str!("../../Cargo.lock");
        assert!(
            lock.contains("rusty-kaspa.git?rev=01b532e8b553523216471682649693af92f0fd16"),
            "the rusty-kaspa pin moved: re-read RETENTION_ROOT_OFF_CHAIN at \
             consensus/src/consensus/mod.rs and the module doc's citations"
        );
    }

    /// The classification reads the PIN's own words: the Display of
    /// `ConsensusError::HeaderNotFound` and the quoted retention-root text,
    /// bare or inside the client's wrapper. Nothing else re-seeds.
    #[test]
    fn the_unknown_cursor_is_read_from_the_pins_own_errors() {
        let header = ConsensusError::HeaderNotFound(h(3)).to_string();
        assert!(cursor_unknown(&header));
        assert!(cursor_unknown(&format!(
            "RPC Server (remote error) -> {header}"
        )));
        let retention =
            ConsensusError::General("the queried hash does not have retention root on its chain")
                .to_string();
        assert!(cursor_unknown(&retention));
        for other in [
            "link: no bound socket",
            "no answer in 60 s",
            "RPC Server (remote error) -> Consensus is in transitional IBD state",
            &ConsensusError::BlockNotFound(h(3)).to_string(),
            "",
        ] {
            assert!(!cursor_unknown(other), "{other:?} re-seeded");
        }
    }

    /// **A reorg arrives inside the page**: the cursor block left the chain,
    /// the node reports it removed, and the new chain is folded after it.
    #[tokio::test]
    async fn a_page_that_removes_the_cursor_folds_the_new_chain() {
        let dir = test_dir("reorg");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(5));
        let chain = FakeChain::default();
        chain.queue(h(5), Ok(response(vec![h(5), h(4)], blocks(14, 2))));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        walk.run_to_tip(&chain).await;
        assert_eq!(
            recorder.seen.lock().unwrap().clone(),
            vec![(h(5), vec![h(5), h(4)], vec![h(14), h(15)])]
        );
        assert_eq!(walk.cursor(), Some(h(15)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A page that does not line up is trusted only as far as it does**:
    /// the fold sees the aligned prefix and the cursor stops at its end.
    #[tokio::test]
    async fn a_misaligned_page_is_trusted_only_to_where_it_lines_up() {
        let dir = test_dir("misaligned");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let mut page = response(Vec::new(), blocks(2, 3));
        let mut accepted = (*page.chain_block_accepted_transactions).clone();
        accepted[1].chain_block_header.hash = Some(h(0xAA));
        page.chain_block_accepted_transactions = Arc::new(accepted);
        let chain = FakeChain::default();
        chain.queue(h(1), Ok(page));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        walk.run_to_tip(&chain).await;
        assert_eq!(recorder.seen.lock().unwrap()[0].2, vec![h(2)]);
        assert_eq!(walk.cursor(), Some(h(2)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **Pokes coalesce**: however many land while a fetch is in flight, the
    /// task makes exactly one more run, then waits. On a real clock, so a
    /// walk that spins without waiting for a poke, or fetches once per poke,
    /// shows as a count far past two.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn pokes_during_a_run_coalesce_into_one_more_fetch() {
        struct GatedChain {
            calls: AtomicU64,
            entered: Notify,
            release: Notify,
        }
        #[async_trait]
        impl ChainSource for GatedChain {
            async fn page(
                &self,
                _from: Hash,
            ) -> std::result::Result<GetVirtualChainFromBlockV2Response, PageError> {
                if self.calls.fetch_add(1, Ordering::SeqCst) == 0 {
                    self.entered.notify_one();
                    self.release.notified().await;
                }
                Ok(response(Vec::new(), Vec::new()))
            }
            async fn sink(&self) -> std::result::Result<Hash, String> {
                Ok(h(9))
            }
        }
        let dir = test_dir("coalesce");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = Arc::new(GatedChain {
            calls: AtomicU64::new(0),
            entered: Notify::new(),
            release: Notify::new(),
        });
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        let task = tokio::spawn(walk.clone().run(chain.clone() as Arc<dyn ChainSource>));
        chain.entered.notified().await; // the first fetch is in flight
        for _ in 0..50 {
            walk.poke();
        }
        chain.release.notify_one();
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert_eq!(
            chain.calls.load(Ordering::SeqCst),
            2,
            "fifty pokes during a fetch must make exactly one more"
        );
        walk.poke();
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert_eq!(
            chain.calls.load(Ordering::SeqCst),
            3,
            "a later poke, one more"
        );
        task.abort();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **The witness speaks once per stretch** when the node ticks while no
    /// page is answered, and never while the intake is held or unarmed.
    #[test]
    fn the_witness_speaks_once_while_running_and_never_while_held() {
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        let stall = link::WATCHDOG_STALL_SECS * 1000;
        walk.note_ticks("ivy.example", 1, 1 + stall);
        assert!(
            !walk.quiet_warned.load(Ordering::Relaxed),
            "unarmed: silent"
        );
        walk.arm(test_dir("witness").join("scan.cursor"));
        walk.running_since_mono_ms.store(1, Ordering::Relaxed);
        walk.note_ticks("ivy.example", 1, stall);
        assert!(
            !walk.quiet_warned.load(Ordering::Relaxed),
            "under the stall line"
        );
        walk.note_ticks("ivy.example", 1, 1 + stall);
        assert!(
            walk.quiet_warned.load(Ordering::Relaxed),
            "a stretch the length of the stall line"
        );
        walk.note_progress();
        assert!(
            !walk.quiet_warned.load(Ordering::Relaxed),
            "a page answered re-arms it"
        );
        walk.hold("test");
        walk.note_ticks("ivy.example", 1, u64::MAX);
        assert!(
            !walk.quiet_warned.load(Ordering::Relaxed),
            "held: silent by design"
        );
        walk.note_ticks("ivy.example", 0, u64::MAX);
        assert!(!walk.quiet_warned.load(Ordering::Relaxed));
    }

    /// The witness's clock is the monitor's, which counts from 1, so a socket
    /// published at the clock's very first reading still has a stretch
    /// (L232: the sentinel 0 is unreachable by the clock it guards).
    #[test]
    fn a_socket_published_at_the_clocks_first_reading_has_a_stretch() {
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(test_dir("witness-first").join("scan.cursor"));
        walk.running_since_mono_ms.store(1, Ordering::Relaxed);
        walk.note_ticks("ivy.example", 1, 1 + link::WATCHDOG_STALL_SECS * 1000);
        assert!(walk.quiet_warned.load(Ordering::Relaxed));
    }

    /// **The transport matcher**: the same prefix scan over accepted
    /// transactions, in chain order; the acceptance of each match handed on
    /// with its chain block's own facts; a plain transfer ignored.
    #[test]
    fn the_transport_scan_reads_accepted_transactions_in_chain_order() {
        let page = WalkPage::new(
            h(1),
            response(
                Vec::new(),
                vec![
                    chain_entry(
                        h(2),
                        200,
                        vec![
                            plain_tx(h(20)),
                            message_tx(h(21), b"ciph_msg:1:comm:abc:x", h(0x31)),
                        ],
                    ),
                    chain_entry(h(3), 300, vec![plain_tx(h(22))]),
                    chain_entry(
                        h(4),
                        400,
                        vec![message_tx(h(23), b"kchat:1:handshake:y", h(0x32))],
                    ),
                ],
            ),
        );
        let (matches, accepted) = scan_page(&page, Prefix::Mainnet);
        let txids: Vec<Option<String>> = matches.iter().map(|m| m.txid.clone()).collect();
        assert_eq!(
            txids,
            vec![Some(h(21).to_string()), Some(h(23).to_string())]
        );
        assert_eq!(
            matches[0].block_hash,
            Some(h(0x31).to_string()),
            "the carrying block"
        );
        assert_eq!(accepted.len(), 2);
        assert_eq!(accepted[0].accepting_block, h(2));
        assert_eq!(accepted[0].txids, vec![h(21)]);
        assert_eq!(
            (
                accepted[0].blue_score,
                accepted[0].daa_score,
                accepted[0].timestamp_ms
            ),
            (700, 1_200, 200),
            "the ACCEPTING block's own facts"
        );
        assert_eq!(accepted[1].accepting_block, h(4));
    }
}
