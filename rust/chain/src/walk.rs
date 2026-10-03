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

/// Pages one run may walk before it stops and re-seeds. A page is about four
/// minutes of chain at 10 BPS, so sixteen is about an hour: the acceptance
/// spine's own budget (`MAX_VCC_CATCHUP_PAGES`), so both walks recover the same
/// window and past it the same gap notice speaks. A spent budget lands on an
/// arm's mark ([`Walk::mark_arm`], which names what is still skipped), so the
/// skip is the part of the gap before the app could receive; past this arm's
/// mark it skips nothing. Priced on
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

/// How far behind the chain the committed cursor must be for its next page to
/// count as a **catch-up page** (LINK-Q4): one the link's clocks may see
/// holding the socket's heartbeat behind it. A tip page covers the second or
/// so since the last one, a few kilobytes. At today's ~28 MB of accepted
/// transactions per hour of chain at High verbosity (D-340, E2) a minute of
/// chain is ~470 KB, which crosses the nine-second silence deadline only on a
/// link slower than ~52 KB/s — the weak-air case the extension exists for,
/// while every tip page stays well clear of it. A cursor whose time this
/// session does not know (read from the file, or just landed) counts as
/// behind: the arm's first page is the catch-up.
const CATCH_UP_BEHIND_MS: u64 = 60_000;

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

    /// **The walk moved its cursor other than by folding**: it re-seeded at
    /// `to` (an arm's mark, or the node's sink) from the cursor `from` it could
    /// not walk on from (an unknown cursor, a spent budget, a page the node
    /// could not serve). **`to` may lie ahead of `from`, behind it, or off the
    /// chain**: a mark the chain reorganised away, a lagging node's sink, a mark
    /// carried across a lock. Mark landings happen at most once per mark, so at
    /// most two per arm; a sink re-seed can land behind once per failure streak,
    /// and a spent budget with no mark read once per arm (it sets `present`)
    /// (`consensus-auditor`, rounds 7 to 9). A matcher that must see every
    /// accepted transaction (P3.4's watcher) marks its state stale here and
    /// re-derives (a watcher that cannot hear a skip is a BLOCK at P3.4); and
    /// since the next page's `removed` list may name blocks it never folded
    /// (the node returns the start and its off-chain ancestors), un-accepting a
    /// block it never folded must be a no-op. Never called for a first seed,
    /// nor for a spent budget past the arm's mark: neither skips anything. The
    /// transport matcher has nothing to do; the skip reaches the log (the hub's
    /// gap notice is worked out once per start, so a mid-session skip stops
    /// there). An `arm` onto a different cursor file jumps without it: that is
    /// a new store, not a skip in this one.
    fn on_gap(&self, _from: Hash, _to: Hash) {}
}

/// Why a page call did not return a page.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum PageError {
    /// No socket was bound when the call was made: still dialing, or paused.
    /// Retried inside the run and never counted — the next publish pokes.
    NoSocket,
    /// The socket died, or was retired for a cause that judged the link (the
    /// silence swap, the watchdog), while the call was in flight. Counted
    /// like a timeout, and a new socket does not forgive it: a page too large
    /// for the link silences the socket's heartbeat, the silence deadline
    /// swaps the socket, and the page dies with it — on every socket, forever,
    /// if each publish restarted the count (`consensus-auditor`, LINK-Q3).
    SocketLost,
    /// The socket was retired under the call by our own hand — a pause, a
    /// repin, the user's swap or reconnect, a lane rebind (LINK-Q4). Says
    /// nothing about whether the page can be carried, so it is never counted:
    /// the run ends and the next publish pokes. In the field a tap's swap was
    /// counted as the page's failure (2026-09-29 00:01:04, L249).
    Displaced,
    /// The node did not answer inside [`WALK_PAGE_TIMEOUT`].
    TimedOut,
    /// The node answered with an error.
    Refused(String),
}

/// Classify a failed page call from the socket bound before and after it —
/// an identity comparison, never error text (the dialer's and the pin's words
/// for a dying socket are many and unpinned) — and, when the socket changed,
/// from the cause the monitor recorded for the one the call went out on
/// (`retired_judged`, LINK-Q4). An unknown cause counts, as before: the
/// conservative direction for the bound (L249).
fn page_error(
    before: Option<usize>,
    after: Option<usize>,
    retired_judged: impl FnOnce(usize) -> Option<bool>,
    error: String,
) -> PageError {
    match before {
        None => PageError::NoSocket,
        Some(socket) if after != before => match retired_judged(socket) {
            Some(false) => PageError::Displaced,
            Some(true) | None => PageError::SocketLost,
        },
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

    /// **The walk skipped from `from` to `to`** (LINK-Q4): what was accepted
    /// between them is not replayed from this node, so the user's gap notice
    /// must speak for it ([`WalkMatcher::on_gap`], routed here by the transport
    /// matcher). A default that does nothing, for a sink with no notice.
    fn skipped(&self, _from: Hash, _to: Hash) {}
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
    /// The arm's mark ([`Walk::mark_arm`]): the node's sink as an arm's walk
    /// begins. Production reads it exactly as [`Self::sink`]; a source with
    /// none (the default) leaves every re-seed at the sink of the moment.
    async fn mark(&self) -> std::result::Result<Hash, String> {
        Err("no mark".to_string())
    }
    /// The socket a page asked now would go out on, as an identity (LINK-Q4):
    /// recorded with the page in flight, so the link's clocks can tell a page
    /// on their own socket from one on a socket already gone. `None` for a
    /// source with no sockets (the tests' scripted chain).
    fn socket(&self) -> Option<usize> {
        None
    }
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
            Ok(Err(e)) => Err(page_error(
                before,
                self.0.bound_identity(),
                |socket| self.0.retired_judged(socket),
                e.to_string(),
            )),
            Err(_) => Err(PageError::TimedOut),
        }
    }

    fn socket(&self) -> Option<usize> {
        self.0.bound_identity()
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

    async fn mark(&self) -> std::result::Result<Hash, String> {
        self.sink().await
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

/// **Atomic and durable (PRE3-LOG, F47).** A bare `std::fs::write` truncates
/// before it writes, so a crash inside it left an empty or partial cursor,
/// which [`read_cursor`] reads as none: the walk seeded at the sink, no gap
/// age was ever computed, and the whole absence passed with no notice.
fn write_cursor(path: &Path, hash: &Hash) {
    if let Err(e) = crate::durable::atomic_write(path, hash.to_string().as_bytes()) {
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

/// **A page call in flight** (LINK-Q4) — what the link's silence and watchdog
/// clocks read so that our own load is never charged to a node's heartbeat
/// (`consensus-auditor` item 18, L70): a catch-up page on a weak link holds
/// every notification behind it on the one socket.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct PageInFlight {
    /// [`mono_ms`] when the call went out.
    pub(crate) sent_mono_ms: u64,
    /// The socket it went out on ([`ChainSource::socket`]).
    pub(crate) socket: Option<usize>,
    /// Asked [`CATCH_UP_BEHIND_MS`] or more behind the chain, or after a long
    /// page: large enough to hold the heartbeat behind it.
    pub(crate) catch_up: bool,
}

/// Records a page call for as long as it is in flight.
struct InFlightGuard<'a> {
    walk: &'a Walk,
}

impl<'a> InFlightGuard<'a> {
    fn new(walk: &'a Walk, socket: Option<usize>, catch_up: bool) -> Self {
        *walk
            .in_flight
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(PageInFlight {
            sent_mono_ms: mono_ms(),
            socket,
            catch_up,
        });
        Self { walk }
    }
}

impl Drop for InFlightGuard<'_> {
    fn drop(&mut self) {
        *self
            .walk
            .in_flight
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = None;
    }
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
    /// Landing points for a re-seed that skips ([`Walk::mark_arm`]): the node's
    /// sink as an arm's walk began, with the unix ms it was read. `carried` is
    /// the oldest one an earlier arm on this cursor file never reached (a lock
    /// came first); `own` is this arm's. Each is used once, and dropped when a
    /// folded page carries it or the walk reaches the tip.
    carried: Option<(Hash, u64)>,
    own: Option<(Hash, u64)>,
    /// This arm's own mark was read, or its window closed (the arm's first
    /// page answered): asked for at each run's start until then, and once more
    /// with that page.
    mark_read: bool,
    /// The walk is past this arm's own mark (a folded page carried it, a
    /// re-seed landed on it, or the walk reached the tip): all that is left
    /// was accepted while the app could receive, and a spent budget skips none
    /// of it.
    present: bool,
    /// A page reached the tip since this arm or the last new socket (LINK-Q4):
    /// the next page is a tip page, known without any clock. Cleared by an arm
    /// and by every socket published (the absence behind a reconnect is
    /// unknown); set by a commit at the tip and by a re-seed at the sink.
    at_tip: bool,
}

/// Where a re-seed that skips went ([`Walk::landing`]).
enum Landing {
    /// Landed on an arm's mark: the cursor it left and that cursor's time,
    /// the mark and the unix ms it was read. Written under the same lock that
    /// took the mark, so a hold cannot fall between the two (both auditors,
    /// round 7).
    Landed {
        was: Hash,
        was_time: Option<u64>,
        mark: Hash,
        at: u64,
    },
    /// Past this arm's own mark: nothing left to skip.
    Present,
    /// No mark: the node's sink, as before the marks.
    Sink,
}

/// What a skip did, for the run that asked.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Skipped {
    /// Landed on a mark: the node still owes the chain from it.
    Landed,
    /// Past this arm's mark with the budget spent: nothing skipped.
    Stayed,
    /// Re-seeded at the sink, or nothing to do (the arm changed).
    Other,
}

/// Why the walk cannot go on from its cursor as it is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Cause {
    /// The catch-up budget is spent.
    Budget,
    /// The node does not know the cursor, or could not serve its page.
    Failure,
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
    /// Our own hand retired the socket under the page: not counted.
    Displaced,
    /// Every attempt found no socket bound: not a failure of the page.
    NoSocket,
    Unreachable,
    Stopped,
}

/// The walk: one cursor, one task, one fetch at a time. See the module doc.
pub(crate) struct Walk {
    state: Mutex<State>,
    poke: Notify,
    /// The epoch whose walk has settled ([`Self::settle`]): the V2b fill waits
    /// on it so node truth folds first (D-074's order).
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
    /// The page call in flight, if any ([`PageInFlight`], LINK-Q4).
    in_flight: Mutex<Option<PageInFlight>>,
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
                carried: None,
                own: None,
                mark_read: false,
                present: false,
                at_tip: false,
            }),
            poke: Notify::new(),
            settled,
            matchers,
            last_progress_mono_ms: AtomicU64::new(0),
            running_since_mono_ms: AtomicU64::new(0),
            quiet_warned: AtomicBool::new(false),
            fold_gate: tokio::sync::Mutex::new(()),
            in_flight: Mutex::new(None),
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
            let same_store = s.path.as_ref() == Some(&path);
            if !same_store || s.cursor.is_none() {
                s.cursor = read_cursor(&path);
                s.cursor_time_ms = None;
                s.path = Some(path);
            }
            s.mode = Mode::Running;
            s.epoch += 1;
            s.failed_runs = 0;
            s.retry_after = None;
            // A lock that came before this store's last arm reached its mark
            // leaves that mark owed: the next arm lands there first, so what was
            // accepted while it walked is walked (`wallet-security-auditor`,
            // round 6). The older of the two is kept; another store carries none.
            s.carried = if same_store {
                s.carried.or(s.own)
            } else {
                None
            };
            s.own = None;
            s.mark_read = false;
            s.present = false;
            s.at_tip = false;
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

    /// The page call in flight, if any (LINK-Q4): read by the link's silence
    /// and watchdog clocks.
    pub(crate) fn page_in_flight(&self) -> Option<PageInFlight> {
        *self
            .in_flight
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }

    /// Tests: stage a page in flight, as a fetch would.
    #[cfg(test)]
    pub(crate) fn set_in_flight(&self, page: Option<PageInFlight>) {
        *self
            .in_flight
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = page;
    }

    /// May the next page be a catch-up page? Not once a page reached the tip
    /// under this arm and socket ([`State::at_tip`], no clock). Before that —
    /// the first page after an arm or a new socket — the device clock against
    /// the cursor block's own time decides: [`CATCH_UP_BEHIND_MS`] or more
    /// behind, or a time this session does not know. That comparison decides
    /// what the link's clocks forgive (one silence extension, a watchdog
    /// strike withheld as our own load), never what is folded; a phone clock
    /// far ahead can make that one first page read as a catch-up, which the
    /// extension bounds (`wallet-security-auditor`, LINK-Q4 round 1 note).
    fn behind(&self, epoch: u64) -> bool {
        let s = self.state();
        s.epoch == epoch
            && !s.at_tip
            && s.cursor_time_ms
                .is_none_or(|t| now_unix_ms().saturating_sub(t) >= CATCH_UP_BEHIND_MS)
    }

    /// The committed cursor (tests).
    #[cfg(test)]
    pub(crate) fn cursor(&self) -> Option<Hash> {
        self.state().cursor
    }

    /// Wait until the walk under `epoch` (or a later arm) has settled, for at
    /// most `within`; a budget that lands on a mark walks on unsettled
    /// ([`Self::settle`]). `false` on the timeout.
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
        self.mark_arm(source, epoch).await;
        // A re-seed the third failure owed but could not make: paid now,
        // before the page that has already failed three times is asked for
        // again — asking would kill the next socket the same way.
        if self.state().failed_runs >= MAX_FAILED_RUNS {
            let why = format!(
                "the node could not serve the page in {MAX_FAILED_RUNS} runs (the re-seed was \
                 owed: no sink could be read when the last one failed)"
            );
            self.skip(source, epoch, &why, Cause::Failure).await;
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
            // A page asked a minute or more behind the chain, or one after a
            // long page, can be large enough to hold the socket's heartbeat
            // behind it on a weak link; the link's clocks read this (LINK-Q4).
            let catch_up = pages > 0 || self.behind(epoch);
            let response = match self.fetch(source, epoch, from, catch_up).await {
                Fetched::Page(response) => response,
                Fetched::Unknown(error) => {
                    let why = format!(
                        "the node does not know cursor {from} ({})",
                        link::sanitize_node_text(&error)
                    );
                    self.skip(source, epoch, &why, Cause::Failure).await;
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
                // Our own hand (a pause, a repin, the user's swap): no pause,
                // no count — the next publish pokes (LINK-Q4).
                Fetched::Displaced => {
                    log::info!(
                        "walk: the page from {from} lost its socket to our own retirement (not \
                         the link's) — not counted; the next socket asks again"
                    );
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
            // A mark refused because no socket was bound yet (a warm resume
            // arms before the re-race binds) is asked for once more, now that
            // a page has proved the socket (`consensus-auditor`, round 6).
            self.mark_arm(source, epoch).await;
            let page = WalkPage::new(from, response);
            let long = page.added_len() >= WALK_TIP_PAGE_THRESHOLD;
            {
                let _fold = self.fold_gate.lock().await;
                // The fetch took time: fold only if the walk still runs under
                // this arm from the same committed cursor. Checked under the
                // gate, so a hold that `quiesce` waited out cannot be passed.
                if !self.still_at(epoch, from) {
                    break;
                }
                self.note_progress(epoch, from);
                // The fold's bookkeeping — the hold or the commit — happens
                // under the same gate, so `quiesce_intake` orders every write
                // a fold makes before any arm can run (`wallet-security-
                // auditor`, D-344 round 9). There is no await between the fold
                // and these writes, so no test can land an arm in the gap it
                // closes, and no mutant that reopens it can be seen red: the
                // ordering is carried by this block's shape, not by a test.
                if self.fold(&page).await == Verdict::Held {
                    self.hold_at(from);
                    break;
                }
                let at_tip = !long && page.aligned == page.added_len();
                self.commit(epoch, &page, long || pages > 0, at_tip);
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
                match self.skip(source, epoch, &why, Cause::Budget).await {
                    // The node still owes the chain from the mark: the next run
                    // walks on at once, and this arm is not settled until a run
                    // ends at the tip, so the V2b fill waits for node truth
                    // (D-074's order; both auditors, round 7).
                    Skipped::Landed => {
                        self.poke();
                        return;
                    }
                    Skipped::Stayed => self.poke(),
                    Skipped::Other => {}
                }
                break;
            }
        }
        self.settle(epoch);
    }

    /// A run begun under `epoch` has ended: at the tip, on a failure, at the
    /// sink, or with a budget spent past the arm's mark. A budget that lands on
    /// a mark does not settle: the node still owes the chain from it, and the
    /// next run walks on at once (D-074's order; both auditors, round 7).
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
    /// [`MAX_FAILED_RUNS`] skip ([`Self::skip`]: an arm's mark ahead, else the
    /// sink). The sink often cannot be read
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
            self.skip(source, epoch, &why, Cause::Failure).await;
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

    async fn fetch(
        &self,
        source: &dyn ChainSource,
        epoch: u64,
        from: Hash,
        catch_up: bool,
    ) -> Fetched {
        let mut last_error = String::new();
        let mut only_no_socket = true;
        for attempt in 0..WALK_PAGE_ATTEMPTS {
            if !self.still_at(epoch, from) {
                return Fetched::Stopped;
            }
            let asked = {
                let _in_flight = InFlightGuard::new(self, source.socket(), catch_up);
                source.page(from).await
            };
            match asked {
                Ok(response) => return Fetched::Page(response),
                // Never re-asked inside the run: the late reply may still be
                // streaming on the one socket (`consensus-auditor`, LINK-Q3).
                Err(PageError::TimedOut) => return Fetched::TimedOut,
                Err(PageError::SocketLost) => return Fetched::SocketLost,
                Err(PageError::Displaced) => return Fetched::Displaced,
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

    /// Move the committed cursor from the page's start to its last chain
    /// block, unless something else moved it meanwhile (an empty page at the
    /// tip moves nothing). **A mark the page carries is passed with it, and at
    /// the tip every mark, whatever the arm**: a fold that finishes
    /// after a hold still commits, and a mark it passed must never be carried
    /// to the next arm and landed on behind the cursor (both auditors, round
    /// 7). This arm's own mark passes the older one too and, under this arm,
    /// makes the rest present. Written at once when `force` or when the walk is
    /// no longer running (a hold already flushed the older value), else
    /// throttled.
    fn commit(&self, epoch: u64, page: &WalkPage, force: bool, at_tip: bool) {
        let mut s = self.state();
        if s.cursor != Some(page.from) {
            return;
        }
        let moved = if let Some((to, time_ms)) = page.last() {
            s.cursor = Some(to);
            s.cursor_time_ms = time_ms;
            true
        } else {
            false
        };
        // A mark AT the page's start is passed as well: the cursor stood on it,
        // so it was reached (`consensus-auditor`, D-344 round 9 — a carried mark
        // equal to the cursor survived the commit, fell behind it, and a spent
        // budget an hour later landed on it: one re-walk. The reason the case
        // was first declined covered only the arm's own mark.)
        let carries = |mark: Option<(Hash, u64)>| {
            mark.is_some_and(|(mark, _)| {
                mark == page.from || page.blocks().any(|(block, _)| block == mark)
            })
        };
        // At the tip every mark is behind the cursor, one no page can carry
        // included (reorganised away, or read at the cursor): the same rule,
        // under the same lock, whatever the arm (both auditors, round 8).
        if at_tip || carries(s.own) {
            s.own = None;
            s.carried = None;
            if s.epoch == epoch {
                s.present = true;
                s.at_tip |= at_tip;
            }
        } else if carries(s.carried) {
            s.carried = None;
        }
        if !moved {
            return;
        }
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

    /// **The arm's mark**: the node's sink as this arm's walk begins, the
    /// landing point for a re-seed that skips, so a skip is the part of the gap
    /// before the app could receive and not what was accepted after. Read at
    /// the start of each run of the arm until its first page answers (only
    /// when there is a cursor to replay from: a first seed skips nothing), and
    /// once more with that page if every read so far was refused (a warm
    /// resume arms before the socket binds, `consensus-auditor`, round 6);
    /// never after, so a node that answers pages and refuses its sink cannot
    /// make it a read per chain move on the funds lane's socket. Before the
    /// first page the reads ride the failed runs' pause. **Found by LINK-Q3's
    /// parity window** (2026-09-29): the dev install, closed about eleven
    /// hours, walked its oldest hour, and a message accepted during that
    /// catch-up was on the stream and never on the walk: the spent budget had
    /// re-seeded at the sink as it stood two minutes later. The old block scan
    /// never had this hole (its stream ran beside its catch-up).
    ///
    /// **What is still skipped** (both auditors, rounds 6 and 7), each named
    /// in the log when it happens:
    /// - the middle arm's window of a catch-up interrupted by two locks (two
    ///   landing points are kept, the oldest and the newest);
    /// - a carried mark when the process dies between the lock and the next
    ///   arm (marks live in memory; persisting one would carry a stale mark
    ///   into a file);
    /// - the present stretch beyond one budget when a lock falls after this
    ///   arm's mark was passed but before the tip (a long outage while armed);
    /// - the seconds between an unlock and the socket binding when the mark is
    ///   read with the first page, which count as absence;
    /// - whatever a sink re-seed passes when no mark could be read.
    async fn mark_arm(&self, source: &dyn ChainSource, epoch: u64) {
        {
            let s = self.state();
            if s.mode != Mode::Running || s.epoch != epoch || s.cursor.is_none() || s.mark_read {
                return;
            }
        }
        if let Ok(mark) = source.mark().await {
            let mut s = self.state();
            if s.mode == Mode::Running && s.epoch == epoch && !s.mark_read {
                s.own = Some((mark, now_unix_ms()));
                s.mark_read = true;
            }
        }
    }

    /// Where a skip goes: the oldest unreached mark (the one a lock left, then
    /// this arm's own), taken once; a mark at the cursor is reached, not a
    /// place to land. A landing is written here, under the lock that took the
    /// mark. After a failed run the pause stands: a timed-out reply may still
    /// be streaming on the one socket, and no sink read comes first any more to
    /// pace the next page (`consensus-auditor`, round 6). `None` when the arm
    /// changed under the run.
    fn landing(&self, epoch: u64, cause: Cause) -> Option<Landing> {
        let mut s = self.state();
        if s.mode != Mode::Running || s.epoch != epoch {
            return None;
        }
        let Some(cursor) = s.cursor else {
            return Some(Landing::Sink);
        };
        let mut next = s.carried.take().filter(|(mark, _)| *mark != cursor);
        if next.is_none() {
            if let Some(own) = s.own.take() {
                s.present = true;
                next = Some(own).filter(|(mark, _)| *mark != cursor);
            }
        }
        let Some((mark, at)) = next else {
            return Some(if s.present {
                Landing::Present
            } else {
                Landing::Sink
            });
        };
        let was_time = s.cursor_time_ms;
        s.cursor = Some(mark);
        s.cursor_time_ms = None;
        s.failed_runs = 0;
        if cause == Cause::Budget {
            s.retry_after = None;
        }
        Self::flush(&mut s);
        Some(Landing::Landed {
            was: cursor,
            was_time,
            mark,
            at,
        })
    }

    /// The walk cannot go on from its cursor as it is: a spent budget, a
    /// cursor the node does not know, or a page it could not serve. It lands on
    /// an arm's mark when one is ahead; past this arm's own mark a spent budget
    /// skips nothing, since all that is left was accepted while the app could
    /// receive (the next run walks on, at the bytes a live walk would have
    /// spent); otherwise it re-seeds at the sink and names the gap.
    async fn skip(&self, source: &dyn ChainSource, epoch: u64, why: &str, cause: Cause) -> Skipped {
        match self.landing(epoch, cause) {
            None => Skipped::Other,
            Some(Landing::Landed {
                was,
                was_time,
                mark,
                at,
            }) => {
                for matcher in &self.matchers {
                    matcher.on_gap(was, mark);
                }
                // Wording only, never a decision: the device clock against a
                // block's time (`consensus-auditor`, round 8), so the line
                // prints both and says which clock each is (round 9).
                match was_time {
                    Some(t) if t > at => log::warn!(
                        "walk: re-walking from an arm's mark {mark} — {why}; the cursor {was} looks \
                         already past it (its block's time {t} against the mark read at {at}, unix \
                         ms, the second by this device's clock: a mark the chain reorganised away, \
                         or a lagging node), so by those clocks this skips nothing"
                    ),
                    _ => {
                        let span = match was_time {
                            Some(t) => format!("{} min", at.saturating_sub(t) / 60_000),
                            None => "its length unknown to this session".to_string(),
                        };
                        log::warn!(
                            "walk: re-seeded at an arm's mark {mark} — {why}; messages accepted \
                             between {was} and that arm ({span}) are not replayed from this node, \
                             and everything accepted since is walked"
                        );
                    }
                }
                Skipped::Landed
            }
            Some(Landing::Present) if cause == Cause::Budget => {
                log::info!(
                    "walk: {why} past the arm's mark — nothing is skipped; the next run walks on"
                );
                Skipped::Stayed
            }
            Some(_) => {
                self.reseed(source, epoch, Some(why)).await;
                Skipped::Other
            }
        }
    }

    /// Put the cursor at the node's sink. With no cursor this is the first
    /// run (nothing to replay, and all that follows is live); otherwise `why`
    /// says what is being skipped and the log names the gap, as the old
    /// catch-up did. Every mark is behind the sink, so none is kept.
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
            s.carried = None;
            s.own = None;
            s.mark_read = true;
            s.present = true;
            s.at_tip = true;
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

    /// A page answered from `from` under `epoch`: the witness's stretch ends,
    /// and, still under that arm at that cursor, the failure streak ends and
    /// the mark's read window closes. The arm check keeps a hold and an arm
    /// that fell between the gate's check and here from handing the new arm a
    /// closed window (both auditors, round 8).
    fn note_progress(&self, epoch: u64, from: Hash) {
        self.last_progress_mono_ms
            .store(mono_ms(), Ordering::Relaxed);
        self.quiet_warned.store(false, Ordering::Relaxed);
        let mut s = self.state();
        if s.epoch != epoch || s.cursor != Some(from) {
            return;
        }
        s.failed_runs = 0;
        s.retry_after = None;
        // The mark is not asked for again under this arm: a node that answers
        // pages and refuses its sink would otherwise be asked on every chain
        // move (the pacing the sink read in `reseed` has, for the same spin).
        s.mark_read = true;
    }

    /// A socket was published: the witness's stretch starts clean. The
    /// failure streak does NOT: a page the link cannot carry kills socket
    /// after socket (its silence trips the swap), and forgiving it on every
    /// publish would ask for it forever (`consensus-auditor`, LINK-Q3). A run
    /// that found no socket at all was never counted.
    pub(crate) fn socket_published(&self) {
        self.quiet_warned.store(false, Ordering::Relaxed);
        // What happened while no socket was up is unknown: the next page's
        // size is the clock's to guess again (LINK-Q4).
        self.state().at_tip = false;
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
    /// **A skip reaches the user's gap notice** (LINK-Q4; IDEAS 2026-09-29):
    /// it used to stop at the log, because the hub's notice was worked out once
    /// per open from the cursor's age — so a skip inside the notice's window
    /// (a page the node could not serve three times), or any skip after the
    /// open, reached no one. The hub's sink hears it; with no sink armed there
    /// is no notice to speak (a first seed never skips).
    fn on_gap(&self, from: Hash, to: Hash) {
        let sink = self
            .sink
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        if let Some(sink) = sink {
            sink.skipped(from, to);
        }
    }

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
    /// Queued in place of a page: our own hand retired the socket under it.
    const DISPLACED: &str = "DISPLACED";

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
        /// The sink as an arm begins ([`ChainSource::mark`]); none by default,
        /// so every older test re-seeds at `sink` exactly as before.
        mark: Mutex<Option<Hash>>,
        mark_calls: AtomicU64,
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
                Some(Err(e)) if e == DISPLACED => Err(PageError::Displaced),
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
        async fn mark(&self) -> std::result::Result<Hash, String> {
            self.mark_calls.fetch_add(1, Ordering::SeqCst);
            self.mark
                .lock()
                .unwrap()
                .ok_or_else(|| "no mark".to_string())
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

    /// **F47: the cursor is replaced, never rewritten in place.** A bare
    /// write truncates the file and then fills it, and a crash between the two
    /// left an empty cursor that read as a first run. The durable write
    /// renames a finished file over the old one, which a test can see: the
    /// file is a new inode after every commit, holding the whole hash.
    #[test]
    fn the_cursor_is_replaced_whole_by_a_rename() {
        use std::os::unix::fs::MetadataExt;
        let dir = test_dir("cursor-rename");
        let path = dir.join("scan.cursor");
        write_cursor(&path, &h(1));
        let first = std::fs::metadata(&path).unwrap().ino();
        write_cursor(&path, &h(2));
        assert_ne!(
            std::fs::metadata(&path).unwrap().ino(),
            first,
            "a new file renamed over the old, not the old one truncated and refilled"
        );
        assert_eq!(read_cursor(&path), Some(h(2)));
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

    /// Queue `MAX_WALK_PAGES + 2` long pages chained from `from` (page `n`
    /// opens with chain block `h(first + n)`), so a run from it spends its
    /// budget; returns each page's last chain block.
    fn queue_long_gap(chain: &FakeChain, from: Hash, first: u8) -> Vec<Hash> {
        let mut from = from;
        let mut lasts = Vec::new();
        for n in 0..MAX_WALK_PAGES + 2 {
            let page = long_page(first + n as u8);
            let last = *page.added_chain_block_hashes.last().unwrap();
            chain.queue(from, Ok(page));
            lasts.push(last);
            from = last;
        }
        lasts
    }

    /// The page where a spent budget leaves the cursor.
    const BUDGET_END: usize = MAX_WALK_PAGES as usize - 1;

    /// **A spent budget lands on the arm's mark, never past what came after
    /// the arm** (LINK-Q3's parity window, 2026-09-29). The dev install, closed
    /// about eleven hours, walked its oldest hour; a message accepted during
    /// that catch-up was on the stream and never on the walk, because the
    /// budget re-seeded at the sink as it stood two minutes later. The mark is
    /// the sink read as the arm began: the walk lands there and walks on.
    #[tokio::test]
    async fn a_spent_budget_reseeds_at_the_arms_mark_and_walks_what_came_after() {
        let dir = test_dir("mark");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        write_cursor(&path, &h(1));
        let chain = FakeChain::default();
        *chain.mark.lock().unwrap() = Some(h(200)); // the sink as the arm began
        *chain.sink.lock().unwrap() = Some(h(250)); // the sink by the budget's end
        let lasts = queue_long_gap(&chain, h(1), 20);
        chain.queue(h(200), Ok(response(Vec::new(), blocks(201, 2))));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(path.clone());
        walk.run_to_tip(&chain).await;
        assert_eq!(
            walk.cursor(),
            Some(h(200)),
            "the budget lands on the arm's mark"
        );
        assert_eq!(read_cursor(&path), Some(h(200)));
        assert_eq!(
            recorder.gaps.lock().unwrap().clone(),
            vec![(lasts[BUDGET_END], h(200))]
        );
        walk.run_to_tip(&chain).await;
        assert_eq!(
            walk.cursor(),
            Some(h(202)),
            "what came after the arm is walked"
        );
        assert_eq!(
            recorder.seen.lock().unwrap().last().unwrap().clone(),
            (h(200), vec![], vec![h(201), h(202)])
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A cursor the node does not know lands on the mark too**, and the walk
    /// goes on from it.
    #[tokio::test]
    async fn an_unknown_cursor_reseeds_at_the_arms_mark() {
        let dir = test_dir("mark-unknown");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = FakeChain::default();
        *chain.mark.lock().unwrap() = Some(h(40));
        *chain.sink.lock().unwrap() = Some(h(90));
        chain.queue(
            h(1),
            Err(format!(
                "RPC Server (remote error) -> {}",
                ConsensusError::HeaderNotFound(h(1))
            )),
        );
        chain.queue(h(40), Ok(response(Vec::new(), blocks(41, 2))));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(40)));
        assert_eq!(recorder.gaps.lock().unwrap().clone(), vec![(h(1), h(40))]);
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(42)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A first page that never answers still lands on the mark read as the
    /// arm began** (the read at the run's start: without it no page answers,
    /// nothing is read, and the sink skips the minutes since the arm), and
    /// **the failed runs' pause stands after landing**: a timed-out reply may
    /// still be streaming, and no sink read comes first to pace the next page.
    #[tokio::test(start_paused = true)]
    async fn a_page_that_never_answers_still_lands_on_the_mark_and_keeps_the_pause() {
        let dir = test_dir("mark-never");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = FakeChain::default();
        *chain.mark.lock().unwrap() = Some(h(40));
        *chain.sink.lock().unwrap() = Some(h(88));
        for _ in 0..MAX_FAILED_RUNS {
            chain.queue(h(1), Err(LOST.to_string()));
        }
        chain.queue(h(40), Ok(response(Vec::new(), blocks(41, 2))));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        for run in 1..=MAX_FAILED_RUNS {
            walk.run_to_tip(&chain).await;
            if run < MAX_FAILED_RUNS {
                tokio::time::sleep(FAILED_RUN_BACKOFF_CAP).await;
            }
        }
        assert_eq!(
            walk.cursor(),
            Some(h(40)),
            "the third failure lands on the mark"
        );
        assert_eq!(recorder.gaps.lock().unwrap().clone(), vec![(h(1), h(40))]);
        walk.run_to_tip(&chain).await; // inside the third failure's pause
        assert_eq!(
            chain.calls().len(),
            MAX_FAILED_RUNS as usize,
            "the pause stands"
        );
        tokio::time::sleep(FAILED_RUN_BACKOFF_CAP).await;
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(42)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A scripted node whose sink cannot be read until a page has answered:
    /// the socket binds while the arm's first run waits for it (a warm resume).
    struct BindingChain {
        chain: FakeChain,
        answered: AtomicBool,
    }

    #[async_trait]
    impl ChainSource for BindingChain {
        async fn page(
            &self,
            from: Hash,
        ) -> std::result::Result<GetVirtualChainFromBlockV2Response, PageError> {
            let page = self.chain.page(from).await;
            if page.is_ok() {
                self.answered.store(true, Ordering::SeqCst);
            }
            page
        }
        async fn sink(&self) -> std::result::Result<Hash, String> {
            self.chain.sink().await
        }
        async fn mark(&self) -> std::result::Result<Hash, String> {
            if self.answered.load(Ordering::SeqCst) {
                Ok(h(200))
            } else {
                Err("link: no bound socket".to_string())
            }
        }
    }

    /// **A mark refused before the socket binds is read with the first page**
    /// (`consensus-auditor`, round 6): the arm's run starts before the re-race
    /// binds, the read is refused, and the page answers moments later.
    #[tokio::test(start_paused = true)]
    async fn a_mark_refused_before_the_socket_binds_is_read_with_the_first_page() {
        let dir = test_dir("mark-bind");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = BindingChain {
            chain: FakeChain::default(),
            answered: AtomicBool::new(false),
        };
        *chain.chain.sink.lock().unwrap() = Some(h(250));
        chain.chain.queue(h(1), Err(NOSOCKET.to_string()));
        queue_long_gap(&chain.chain, h(1), 20);
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        walk.run_to_tip(&chain).await;
        assert_eq!(
            walk.cursor(),
            Some(h(200)),
            "the mark read with the first page"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A mark passed mid-catch-up is reached, and the budget then skips
    /// nothing** (both auditors, round 6): landing on a passed mark would
    /// rewind the walk, and all that is left was accepted while the app could
    /// receive. The next run walks on.
    #[tokio::test]
    async fn a_mark_passed_mid_catch_up_is_reached_and_the_budget_skips_nothing() {
        let dir = test_dir("mark-mid");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = FakeChain::default();
        *chain.mark.lock().unwrap() = Some(h(20 + BUDGET_END as u8 - 1)); // in the page before the last
        *chain.sink.lock().unwrap() = Some(h(250));
        let lasts = queue_long_gap(&chain, h(1), 20);
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        walk.run_to_tip(&chain).await;
        assert_eq!(
            walk.cursor(),
            Some(lasts[BUDGET_END]),
            "nothing skipped, no rewind"
        );
        assert!(recorder.gaps.lock().unwrap().is_empty());
        walk.run_to_tip(&chain).await;
        assert_eq!(
            walk.cursor(),
            Some(*lasts.last().unwrap()),
            "the next run walks on"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **Past the mark, a page the node cannot serve re-seeds at the sink**,
    /// never back at the mark (`wallet-security-auditor`, round 6: that would
    /// re-ask pages beside the one that failed).
    #[tokio::test(start_paused = true)]
    async fn past_the_mark_a_failed_page_reseeds_at_the_sink() {
        let dir = test_dir("mark-past-fail");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = FakeChain::default();
        *chain.mark.lock().unwrap() = Some(h(20)); // in the first page
        *chain.sink.lock().unwrap() = Some(h(250));
        let first = long_page(20);
        let past = *first.added_chain_block_hashes.last().unwrap();
        chain.queue(h(1), Ok(first));
        for _ in 0..MAX_FAILED_RUNS {
            chain.queue(past, Err(LOST.to_string()));
        }
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        for run in 1..=MAX_FAILED_RUNS {
            walk.run_to_tip(&chain).await;
            if run < MAX_FAILED_RUNS {
                tokio::time::sleep(FAILED_RUN_BACKOFF_CAP).await;
            }
        }
        assert_eq!(walk.cursor(), Some(h(250)));
        assert_eq!(recorder.gaps.lock().unwrap().clone(), vec![(past, h(250))]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **Past the tip, a spent budget skips nothing**: the walk reached the
    /// tip, so every mark is behind it (one the chain reorganised away too,
    /// which no page ever carries), and a long stretch later (a socket down
    /// for an hour while the app stayed open) is walked, not skipped.
    #[tokio::test]
    async fn past_the_tip_a_spent_budget_skips_nothing() {
        let dir = test_dir("mark-tip");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = FakeChain::default();
        *chain.mark.lock().unwrap() = Some(h(199)); // reorganised away: in no page
        *chain.sink.lock().unwrap() = Some(h(250));
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 9)))); // to h(10): the tip
        let lasts = queue_long_gap(&chain, h(10), 20);
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(10)));
        assert!(
            walk.take_poke(Duration::from_millis(1)).await,
            "the arm's own poke"
        );
        walk.run_to_tip(&chain).await; // an hour of chain later
        assert_eq!(
            walk.cursor(),
            Some(lasts[BUDGET_END]),
            "nothing skipped, no rewind"
        );
        assert!(recorder.gaps.lock().unwrap().is_empty());
        assert!(
            walk.take_poke(Duration::from_millis(1)).await,
            "the next run walks on at once"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **Landing on the arm's own mark makes the rest present**: the mark is
    /// used once, and a second spent budget under the same arm walks on.
    #[tokio::test]
    async fn landing_on_the_arms_mark_makes_the_rest_present() {
        let dir = test_dir("mark-once");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = FakeChain::default();
        *chain.mark.lock().unwrap() = Some(h(200));
        *chain.sink.lock().unwrap() = Some(h(250));
        queue_long_gap(&chain, h(1), 20);
        let lasts = queue_long_gap(&chain, h(200), 60);
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(200)));
        walk.run_to_tip(&chain).await;
        assert_eq!(
            walk.cursor(),
            Some(lasts[BUDGET_END]),
            "the second budget skips nothing"
        );
        assert_eq!(recorder.gaps.lock().unwrap().len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A mark that is the cursor itself is not a place to land**: the page
    /// from the cursor failed three times and the arm's mark is that same
    /// block, so the re-seed goes to the sink rather than asking again.
    #[tokio::test(start_paused = true)]
    async fn a_mark_at_the_cursor_is_not_used() {
        let dir = test_dir("mark-cursor");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = FakeChain::default();
        *chain.mark.lock().unwrap() = Some(h(1));
        *chain.sink.lock().unwrap() = Some(h(88));
        for _ in 0..MAX_FAILED_RUNS {
            chain.queue(h(1), Err(LOST.to_string()));
        }
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        for _ in 0..MAX_FAILED_RUNS {
            walk.run_to_tip(&chain).await;
            tokio::time::sleep(FAILED_RUN_BACKOFF_CAP).await;
        }
        assert_eq!(walk.cursor(), Some(h(88)));
        assert_eq!(recorder.gaps.lock().unwrap().clone(), vec![(h(1), h(88))]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A catch-up a lock interrupted lands first on the mark that lock left**
    /// (`wallet-security-auditor`, round 6): with the lock grace at 0 every app
    /// switch is a re-arm, and landing only on the new arm's mark would skip
    /// what was accepted while the first arm walked. The new arm still reads
    /// its own, the second landing point.
    #[tokio::test]
    async fn an_interrupted_catch_up_lands_first_on_the_mark_its_lock_left() {
        let dir = test_dir("mark-carry");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        write_cursor(&path, &h(1));
        let chain = FakeChain::default();
        *chain.mark.lock().unwrap() = Some(h(40));
        *chain.sink.lock().unwrap() = Some(h(250));
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 2)))); // held
        let first = queue_long_gap(&chain, h(1), 20);
        let second = queue_long_gap(&chain, h(40), 100);
        chain.queue(h(60), Ok(response(Vec::new(), blocks(61, 2))));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        recorder.hold.store(true, Ordering::SeqCst);
        walk.arm(path.clone());
        walk.run_to_tip(&chain).await; // reads h(40), then the vault locks
        assert_eq!(walk.cursor(), Some(h(1)));
        recorder.hold.store(false, Ordering::SeqCst);
        *chain.mark.lock().unwrap() = Some(h(60));
        walk.arm(path);
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(40)), "first the mark the lock left");
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(60)), "then this arm's own");
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(62)));
        assert_eq!(
            recorder.gaps.lock().unwrap().clone(),
            vec![(first[BUDGET_END], h(40)), (second[BUDGET_END], h(60))]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **Each arm starts away**: the last arm reached the tip, the vault
    /// locked, and hours passed. The new arm could not read a mark, so its
    /// spent budget re-seeds at the sink and names the absence, rather than
    /// walking it as if the app had been open (the last arm's `present` must
    /// not survive into this one).
    #[tokio::test(start_paused = true)]
    async fn each_arm_starts_away_again() {
        let dir = test_dir("mark-away");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        write_cursor(&path, &h(1));
        let chain = FakeChain::default();
        *chain.mark.lock().unwrap() = Some(h(10));
        *chain.sink.lock().unwrap() = Some(h(250));
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 9)))); // to h(10): the tip
        let lasts = queue_long_gap(&chain, h(10), 20);
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(path.clone());
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(10)));
        walk.hold("test: locked for the night");
        *chain.mark.lock().unwrap() = None; // the new arm cannot read one
        walk.arm(path);
        walk.run_to_tip(&chain).await;
        assert_eq!(
            walk.cursor(),
            Some(h(250)),
            "the absence is skipped, and named"
        );
        assert_eq!(
            recorder.gaps.lock().unwrap().clone(),
            vec![(lasts[BUDGET_END], h(250))]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A budget landing leaves the arm unsettled and walks on at once**
    /// (D-074's order; both auditors, round 7): the node still owes the chain
    /// from the mark, and the V2b fill waits for node truth, so the arm settles
    /// only when a run ends at the tip.
    #[tokio::test]
    async fn a_budget_landing_leaves_the_arm_unsettled_and_walks_on() {
        let dir = test_dir("mark-settle");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = FakeChain::default();
        *chain.mark.lock().unwrap() = Some(h(200));
        *chain.sink.lock().unwrap() = Some(h(250));
        queue_long_gap(&chain, h(1), 20);
        chain.queue(h(200), Ok(response(Vec::new(), blocks(201, 2))));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        let epoch = walk.arm(dir.join("scan.cursor"));
        assert!(
            walk.take_poke(Duration::from_millis(1)).await,
            "the arm's own poke"
        );
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(200)));
        assert!(
            !walk.settled(epoch, Duration::from_millis(1)).await,
            "not settled at the mark"
        );
        assert!(
            walk.take_poke(Duration::from_millis(1)).await,
            "the next run walks on at once"
        );
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(202)));
        assert!(
            walk.settled(epoch, Duration::from_millis(1)).await,
            "settled at the tip"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Arm with the vault as `held` says (the recorder answers `Held`).
    fn arm_held(walk: &Walk, recorder: &Recorder, path: &Path, held: bool) {
        recorder.hold.store(held, Ordering::SeqCst);
        walk.arm(path.to_path_buf());
    }

    /// **A carried mark a page passes is dropped** (`wallet-security-auditor`,
    /// round 7): the lock's mark is passed mid-catch-up, and the spent budget
    /// lands on this arm's own mark, never back on the passed one.
    #[tokio::test]
    async fn a_carried_mark_a_page_passes_is_dropped() {
        let dir = test_dir("mark-carried-pass");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        write_cursor(&path, &h(1));
        let chain = FakeChain::default();
        *chain.mark.lock().unwrap() = Some(h(25)); // in the second arm's sixth page
        *chain.sink.lock().unwrap() = Some(h(250));
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 2)))); // held
        let lasts = queue_long_gap(&chain, h(1), 20);
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        arm_held(&walk, &recorder, &path, true);
        walk.run_to_tip(&chain).await;
        *chain.mark.lock().unwrap() = Some(h(200));
        arm_held(&walk, &recorder, &path, false);
        walk.run_to_tip(&chain).await;
        assert_eq!(
            walk.cursor(),
            Some(h(200)),
            "the arm's own mark, not the passed one"
        );
        assert_eq!(
            recorder.gaps.lock().unwrap().clone(),
            vec![(lasts[BUDGET_END], h(200))]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **Two locks keep the first arm's mark** (`wallet-security-auditor`,
    /// round 7): of the two landing points, the oldest unreached one is carried.
    #[tokio::test]
    async fn two_locks_keep_the_first_arms_mark() {
        let dir = test_dir("mark-two-locks");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        write_cursor(&path, &h(1));
        let chain = FakeChain::default();
        *chain.sink.lock().unwrap() = Some(h(250));
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 2)))); // held
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 2)))); // held again
        queue_long_gap(&chain, h(1), 100);
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        for mark in [40, 50] {
            *chain.mark.lock().unwrap() = Some(h(mark));
            arm_held(&walk, &recorder, &path, true);
            walk.run_to_tip(&chain).await;
        }
        *chain.mark.lock().unwrap() = Some(h(60));
        arm_held(&walk, &recorder, &path, false);
        walk.run_to_tip(&chain).await;
        assert_eq!(
            walk.cursor(),
            Some(h(40)),
            "the first arm's mark comes first"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **Reaching the arm's own mark drops the carried one too**, even one the
    /// chain reorganised away (no page ever carries it): past the own mark the
    /// budget skips nothing, and never rewinds onto the older mark.
    #[tokio::test]
    async fn reaching_the_arms_mark_drops_a_carried_one_no_page_carries() {
        let dir = test_dir("mark-carried-gone");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        write_cursor(&path, &h(1));
        let chain = FakeChain::default();
        *chain.mark.lock().unwrap() = Some(h(199)); // reorganised away: in no page
        *chain.sink.lock().unwrap() = Some(h(250));
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 2)))); // held
        let lasts = queue_long_gap(&chain, h(1), 20);
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        arm_held(&walk, &recorder, &path, true);
        walk.run_to_tip(&chain).await;
        *chain.mark.lock().unwrap() = Some(h(25)); // in the sixth page
        arm_held(&walk, &recorder, &path, false);
        walk.run_to_tip(&chain).await;
        assert_eq!(
            walk.cursor(),
            Some(lasts[BUDGET_END]),
            "nothing skipped, no rewind"
        );
        assert!(recorder.gaps.lock().unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A matcher that locks the vault while it folds the page carrying `mark`,
    /// and still answers `Folded` (the lock landed after the hub's last event,
    /// or the page had none).
    struct LocksOnMark {
        walk: Mutex<Option<std::sync::Weak<Walk>>>,
        mark: Hash,
    }

    impl WalkMatcher for LocksOnMark {
        fn fold_page<'a>(&'a self, page: &'a WalkPage) -> VerdictFuture<'a> {
            Box::pin(async move {
                if page.blocks().any(|(block, _)| block == self.mark) {
                    let walk = self.walk.lock().unwrap().clone();
                    if let Some(walk) = walk.and_then(|w| w.upgrade()) {
                        walk.hold("test: locked while the mark's page folds");
                    }
                }
                Verdict::Folded
            })
        }
    }

    /// **A mark a fold passes is dropped even when a lock lands during that
    /// fold** (`consensus-auditor`, round 7): the fold still commits, so the
    /// mark is behind the cursor and must not be carried to the next arm and
    /// landed on there.
    #[tokio::test]
    async fn a_mark_passed_by_a_fold_a_lock_interrupts_is_never_carried() {
        let dir = test_dir("mark-race");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        write_cursor(&path, &h(1));
        let chain = FakeChain::default();
        *chain.mark.lock().unwrap() = Some(h(25)); // in the sixth page
        *chain.sink.lock().unwrap() = Some(h(250));
        let first = queue_long_gap(&chain, h(1), 20);
        queue_long_gap(&chain, *first.last().unwrap(), 60);
        let recorder = Arc::new(Recorder::default());
        let locker = Arc::new(LocksOnMark {
            walk: Mutex::new(None),
            mark: h(25),
        });
        let walk = Walk::new(vec![
            recorder.clone() as Arc<dyn WalkMatcher>,
            locker.clone() as Arc<dyn WalkMatcher>,
        ]);
        *locker.walk.lock().unwrap() = Some(Arc::downgrade(&walk));
        walk.arm(path.clone());
        walk.run_to_tip(&chain).await;
        assert_eq!(
            walk.cursor(),
            Some(first[5]),
            "the fold that ended after the lock committed"
        );
        *chain.mark.lock().unwrap() = Some(h(200));
        walk.arm(path);
        walk.run_to_tip(&chain).await;
        assert_eq!(
            walk.cursor(),
            Some(h(200)),
            "never back onto the passed mark"
        );
        let tos: Vec<Hash> = recorder.gaps.lock().unwrap().iter().map(|g| g.1).collect();
        assert_eq!(tos, vec![h(200)]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A tip a lock interrupts still drops every mark** (both auditors, round
    /// 8): the lock lands inside the fold of the arm's tip page and the fold
    /// still answers, so the commit moves the cursor to the tip; a mark no page
    /// carries (reorganised away) is behind it all the same, and the next arm
    /// must never land on it.
    #[tokio::test]
    async fn a_tip_a_lock_interrupts_still_drops_every_mark() {
        let dir = test_dir("mark-tip-race");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        write_cursor(&path, &h(1));
        let chain = FakeChain::default();
        *chain.mark.lock().unwrap() = Some(h(199)); // reorganised away: in no page
        *chain.sink.lock().unwrap() = Some(h(250));
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 2)))); // the tip, to h(3)
        queue_long_gap(&chain, h(3), 20);
        let recorder = Arc::new(Recorder::default());
        let locker = Arc::new(LocksOnMark {
            walk: Mutex::new(None),
            mark: h(2),
        });
        let walk = Walk::new(vec![
            recorder.clone() as Arc<dyn WalkMatcher>,
            locker.clone() as Arc<dyn WalkMatcher>,
        ]);
        *locker.walk.lock().unwrap() = Some(Arc::downgrade(&walk));
        walk.arm(path.clone());
        walk.run_to_tip(&chain).await;
        assert_eq!(
            walk.cursor(),
            Some(h(3)),
            "the tip page committed after the lock"
        );
        *chain.mark.lock().unwrap() = Some(h(200));
        walk.arm(path);
        walk.run_to_tip(&chain).await;
        assert_eq!(
            walk.cursor(),
            Some(h(200)),
            "the arm's own mark, never h(199)"
        );
        let tos: Vec<Hash> = recorder.gaps.lock().unwrap().iter().map(|g| g.1).collect();
        assert_eq!(tos, vec![h(200)]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A carried mark a fold passes is dropped even when a lock lands during
    /// that fold** (`consensus-auditor`, round 8): the lock's mark is passed
    /// by a page whose fold a second lock interrupts; the third arm lands on
    /// the second arm's mark, never back on the passed one.
    #[tokio::test]
    async fn a_carried_mark_a_fold_a_lock_interrupts_passes_is_dropped() {
        let dir = test_dir("mark-carried-race");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        write_cursor(&path, &h(1));
        let chain = FakeChain::default();
        *chain.mark.lock().unwrap() = Some(h(25)); // passed in the second arm's sixth page
        *chain.sink.lock().unwrap() = Some(h(250));
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 2)))); // held
        let first = queue_long_gap(&chain, h(1), 20);
        queue_long_gap(&chain, *first.last().unwrap(), 60);
        let recorder = Arc::new(Recorder::default());
        let locker = Arc::new(LocksOnMark {
            walk: Mutex::new(None),
            mark: h(25),
        });
        let walk = Walk::new(vec![
            recorder.clone() as Arc<dyn WalkMatcher>,
            locker.clone() as Arc<dyn WalkMatcher>,
        ]);
        *locker.walk.lock().unwrap() = Some(Arc::downgrade(&walk));
        recorder.hold.store(true, Ordering::SeqCst);
        walk.arm(path.clone());
        walk.run_to_tip(&chain).await; // reads h(25), then the vault locks
        recorder.hold.store(false, Ordering::SeqCst);
        *chain.mark.lock().unwrap() = Some(h(150)); // in no page
        walk.arm(path.clone());
        walk.run_to_tip(&chain).await; // passes h(25) in a fold a lock interrupts
        assert_eq!(walk.cursor(), Some(first[5]));
        *chain.mark.lock().unwrap() = Some(h(200));
        walk.arm(path);
        walk.run_to_tip(&chain).await;
        assert_eq!(
            walk.cursor(),
            Some(h(150)),
            "the second arm's mark, never h(25)"
        );
        let tos: Vec<Hash> = recorder.gaps.lock().unwrap().iter().map(|g| g.1).collect();
        assert!(
            !tos.contains(&h(25)),
            "no landing on the passed mark: {tos:?}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A mark never crosses to another cursor file**: that is another store,
    /// not a gap in this one.
    #[tokio::test]
    async fn a_mark_never_crosses_to_another_cursor_file() {
        let dir = test_dir("mark-store");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("a.cursor"), &h(1));
        write_cursor(&dir.join("b.cursor"), &h(1));
        let chain = FakeChain::default();
        *chain.mark.lock().unwrap() = Some(h(40));
        *chain.sink.lock().unwrap() = Some(h(250));
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 2)))); // held
        queue_long_gap(&chain, h(1), 20);
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        recorder.hold.store(true, Ordering::SeqCst);
        walk.arm(dir.join("a.cursor"));
        walk.run_to_tip(&chain).await; // reads h(40) for store a, then locks
        recorder.hold.store(false, Ordering::SeqCst);
        *chain.mark.lock().unwrap() = None; // store b's arm cannot read one
        walk.arm(dir.join("b.cursor"));
        walk.run_to_tip(&chain).await;
        assert_eq!(
            walk.cursor(),
            Some(h(250)),
            "no mark from store a: the sink"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **The mark is read until the arm's first page answers, and never for a
    /// first seed**: after a read, or after that page, it is not asked for
    /// again (a node that answers pages and refuses its sink would otherwise be
    /// asked on every chain move, on the funds lane's socket).
    #[tokio::test]
    async fn the_mark_is_read_until_the_arms_first_page_and_never_for_a_first_seed() {
        let dir = test_dir("mark-reads");
        std::fs::create_dir_all(&dir).unwrap();
        let chain = FakeChain::default();
        *chain.sink.lock().unwrap() = Some(h(9));
        *chain.mark.lock().unwrap() = Some(h(9));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("seed.cursor"));
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(9)));
        walk.run_to_tip(&chain).await;
        assert_eq!(
            chain.mark_calls.load(Ordering::SeqCst),
            0,
            "a first seed reads no mark"
        );

        // Read at the run's start: not again under the same arm.
        write_cursor(&dir.join("read.cursor"), &h(1));
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 2))));
        let walk = walk_with(&recorder);
        walk.arm(dir.join("read.cursor"));
        walk.run_to_tip(&chain).await;
        walk.run_to_tip(&chain).await;
        assert_eq!(chain.mark_calls.load(Ordering::SeqCst), 1, "one read");

        // Refused: once at the start, once with the first page, then closed.
        *chain.mark.lock().unwrap() = None;
        write_cursor(&dir.join("refused.cursor"), &h(1));
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 2))));
        let walk = walk_with(&recorder);
        walk.arm(dir.join("refused.cursor"));
        walk.run_to_tip(&chain).await;
        walk.run_to_tip(&chain).await;
        walk.run_to_tip(&chain).await;
        assert_eq!(
            chain.mark_calls.load(Ordering::SeqCst),
            3,
            "a refused mark is asked for twice, never after the arm's first answered page"
        );
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
    /// never by its text — and, when the socket changed, by the cause the
    /// monitor recorded for the one the call went out on (LINK-Q4): a cause
    /// that judged the link counts, our own hand does not, an unknown one
    /// counts (the conservative direction for the bound, L249).
    #[test]
    fn a_page_failure_is_classified_by_the_socket_not_the_text() {
        let text = || "anything at all".to_string();
        let unknown = |_: usize| None;
        let judged = |_: usize| Some(true);
        let ours = |_: usize| Some(false);
        assert_eq!(page_error(None, None, unknown, text()), PageError::NoSocket);
        assert_eq!(page_error(None, Some(7), ours, text()), PageError::NoSocket);
        assert_eq!(
            page_error(Some(7), None, unknown, text()),
            PageError::SocketLost
        );
        assert_eq!(
            page_error(Some(7), Some(8), unknown, text()),
            PageError::SocketLost
        );
        assert_eq!(
            page_error(Some(7), None, judged, text()),
            PageError::SocketLost
        );
        assert_eq!(
            page_error(Some(7), Some(8), judged, text()),
            PageError::SocketLost
        );
        assert_eq!(
            page_error(Some(7), None, ours, text()),
            PageError::Displaced
        );
        assert_eq!(
            page_error(Some(7), Some(8), ours, text()),
            PageError::Displaced
        );
        let asked_about = std::cell::Cell::new(0);
        let _ = page_error(
            Some(7),
            Some(8),
            |socket| {
                asked_about.set(socket);
                Some(false)
            },
            text(),
        );
        assert_eq!(
            asked_about.get(),
            7,
            "the cause asked is the socket the call went out on"
        );
        assert_eq!(
            page_error(Some(7), Some(7), ours, text()),
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
        let epoch = walk.arm(test_dir("witness").join("scan.cursor"));
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
        walk.note_progress(epoch, h(1)); // the witness, whatever the cursor
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

    // ── LINK-Q4 ──────────────────────────────────────────────────────────────

    /// **A page our own hand's retirement killed is never counted** (L249's
    /// field line: a tap's `superseded` counted as the page's failure). More
    /// displacements than the failure bound, and the walk neither pauses nor
    /// skips; the next socket's page folds.
    #[tokio::test]
    async fn a_page_our_own_retirement_killed_is_never_counted() {
        let dir = test_dir("displaced");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let chain = FakeChain::default();
        *chain.sink.lock().unwrap() = Some(h(99));
        for _ in 0..=MAX_FAILED_RUNS {
            chain.queue(h(1), Err(DISPLACED.to_string()));
        }
        chain.queue(h(1), Ok(response(Vec::new(), blocks(2, 2))));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        walk.arm(dir.join("scan.cursor"));
        for _ in 0..=MAX_FAILED_RUNS {
            walk.run_to_tip(&chain).await;
            let s = walk.state();
            assert_eq!(s.failed_runs, 0, "not counted");
            assert!(s.retry_after.is_none(), "and no pause");
        }
        assert!(recorder.gaps.lock().unwrap().is_empty(), "nothing skipped");
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(3)), "the next socket's page folds");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A scripted chain that reads the walk's page-in-flight record from
    /// inside each page call, as the link's clocks would.
    struct Watching {
        walk: Mutex<Option<Arc<Walk>>>,
        chain: FakeChain,
        seen: Mutex<Vec<Option<PageInFlight>>>,
    }

    #[async_trait]
    impl ChainSource for Watching {
        async fn page(
            &self,
            from: Hash,
        ) -> std::result::Result<GetVirtualChainFromBlockV2Response, PageError> {
            let during = self
                .walk
                .lock()
                .unwrap()
                .as_ref()
                .and_then(|walk| walk.page_in_flight());
            self.seen.lock().unwrap().push(during);
            self.chain.page(from).await
        }
        async fn sink(&self) -> std::result::Result<Hash, String> {
            self.chain.sink().await
        }
        fn socket(&self) -> Option<usize> {
            Some(42)
        }
    }

    /// **The page in flight is recorded for the link's clocks, and only while
    /// it flies** (LINK-Q4): on the source's socket; a catch-up page when the
    /// cursor's time is unknown (read from the file) or a long page came before
    /// it in the run; a tip page when the cursor is a block this session folded
    /// seconds ago.
    #[tokio::test]
    async fn a_page_in_flight_is_recorded_with_whether_it_is_a_catch_up() {
        let dir = test_dir("in-flight");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        let source = Watching {
            walk: Mutex::new(Some(walk.clone())),
            chain: FakeChain::default(),
            seen: Mutex::new(Vec::new()),
        };
        let now = now_unix_ms();
        // A long page whose last block is recent: past it the cursor is not
        // behind, so only the long page before it makes the next a catch-up.
        let mut long = long_page(2);
        let mut entries = long.chain_block_accepted_transactions.as_ref().clone();
        entries.last_mut().unwrap().chain_block_header.timestamp = Some(now);
        long.chain_block_accepted_transactions = Arc::new(entries);
        let after_long = *long.added_chain_block_hashes.last().unwrap();
        source.chain.queue(h(1), Ok(long));
        source.chain.queue(
            after_long,
            Ok(response(
                Vec::new(),
                vec![chain_entry(h(3), now, Vec::new())],
            )),
        );
        source.chain.queue(
            h(3),
            Ok(response(
                Vec::new(),
                vec![chain_entry(h(4), now, Vec::new())],
            )),
        );
        walk.arm(dir.join("scan.cursor"));
        walk.run_to_tip(&source).await;
        assert_eq!(walk.page_in_flight(), None, "cleared once the call returns");
        walk.run_to_tip(&source).await;
        let seen: Vec<(Option<usize>, bool)> = source
            .seen
            .lock()
            .unwrap()
            .iter()
            .map(|page| {
                let page = page.expect("recorded during every call");
                (page.socket, page.catch_up)
            })
            .collect();
        assert_eq!(
            seen,
            vec![
                (Some(42), true),  // the arm's first page: the cursor's time unknown
                (Some(42), true),  // after a long page in the same run
                (Some(42), false), // a run from a block folded just now: the tip
            ]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **Once a page reached the tip, the next is a tip page without any
    /// clock** (`wallet-security-auditor`, round 1 note): a cursor whose block
    /// time reads an hour old (a phone clock far ahead) still asks a tip page
    /// after a page at the tip; a new socket hands the question back to the
    /// clock.
    #[tokio::test]
    async fn after_a_page_at_the_tip_the_next_is_a_tip_page_whatever_the_clock() {
        let dir = test_dir("tip-no-clock");
        std::fs::create_dir_all(&dir).unwrap();
        write_cursor(&dir.join("scan.cursor"), &h(1));
        let recorder = Arc::new(Recorder::default());
        let walk = walk_with(&recorder);
        let source = Watching {
            walk: Mutex::new(Some(walk.clone())),
            chain: FakeChain::default(),
            seen: Mutex::new(Vec::new()),
        };
        let an_hour_ago = now_unix_ms() - 3_600_000;
        source.chain.queue(
            h(1),
            Ok(response(
                Vec::new(),
                vec![chain_entry(h(2), an_hour_ago, Vec::new())],
            )),
        );
        source.chain.queue(
            h(2),
            Ok(response(
                Vec::new(),
                vec![chain_entry(h(3), an_hour_ago, Vec::new())],
            )),
        );
        walk.arm(dir.join("scan.cursor"));
        walk.run_to_tip(&source).await; // the arm's first page: reached the tip
        walk.run_to_tip(&source).await; // an old-looking cursor, but at the tip
        walk.socket_published();
        walk.run_to_tip(&source).await; // a new socket: the clock decides again
        let catch_up: Vec<bool> = source
            .seen
            .lock()
            .unwrap()
            .iter()
            .map(|page| page.expect("recorded").catch_up)
            .collect();
        assert_eq!(catch_up, vec![true, false, true]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Stage this arm's marks directly: `own` and `carried` as given, the
    /// mark's read window closed so the run reads none.
    fn stage_marks(walk: &Walk, own: Option<Hash>, carried: Option<Hash>) {
        let mut s = walk.state();
        s.own = own.map(|mark| (mark, 1));
        s.carried = carried.map(|mark| (mark, 1));
        s.mark_read = true;
    }

    /// **`at_tip`'s two halves** (`consensus-auditor`, D-344 round 9). An
    /// EMPTY page is the tip: every mark is behind the cursor, both dropped,
    /// the rest present. A SHORT page that does not line up is not: it is
    /// folded as far as it lines up, and the marks stand.
    #[tokio::test]
    async fn an_empty_page_is_the_tip_and_a_misaligned_short_page_is_not() {
        let dir = test_dir("at-tip");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");

        write_cursor(&path, &h(1));
        let chain = FakeChain::default(); // answers an empty page
        let walk = walk_with(&Arc::new(Recorder::default()));
        walk.arm(path.clone());
        stage_marks(&walk, Some(h(50)), Some(h(40)));
        walk.run_to_tip(&chain).await;
        {
            let s = walk.state();
            assert_eq!((s.own, s.carried), (None, None), "the tip drops every mark");
            assert!(s.present);
        }

        write_cursor(&path, &h(1));
        let chain = FakeChain::default();
        chain.queue(
            h(1),
            Ok(GetVirtualChainFromBlockV2Response {
                removed_chain_block_hashes: Arc::new(Vec::new()),
                added_chain_block_hashes: Arc::new(vec![h(2), h(3)]),
                chain_block_accepted_transactions: Arc::new(vec![
                    chain_entry(h(2), 200, Vec::new()),
                    chain_entry(h(9), 300, Vec::new()), // does not name h(3)
                ]),
            }),
        );
        let walk = walk_with(&Arc::new(Recorder::default()));
        walk.arm(path.clone());
        stage_marks(&walk, Some(h(50)), Some(h(40)));
        walk.run_to_tip(&chain).await;
        assert_eq!(walk.cursor(), Some(h(2)), "folded as far as it lines up");
        {
            let s = walk.state();
            assert_eq!(
                (s.own.map(|m| m.0), s.carried.map(|m| m.0)),
                (Some(h(50)), Some(h(40))),
                "not the tip: the marks stand"
            );
            assert!(!s.present);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A mark AT the page's start is passed by it** (`consensus-auditor`,
    /// round 9): a carried mark equal to the cursor used to survive a long
    /// page's commit and fall behind the cursor, where a spent budget later
    /// landed on it (one re-walk). The same for this arm's own mark.
    #[tokio::test]
    async fn a_mark_at_the_pages_start_is_passed_by_it() {
        let dir = test_dir("mark-at-from");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("scan.cursor");
        for (own, carried) in [(None, Some(h(1))), (Some(h(1)), None)] {
            write_cursor(&path, &h(1));
            let chain = FakeChain::default();
            let long = long_page(2);
            let after = *long.added_chain_block_hashes.last().unwrap();
            chain.queue(h(1), Ok(long));
            chain.queue(after, Err(TIMEOUT.to_string())); // the run stops here
            let walk = walk_with(&Arc::new(Recorder::default()));
            walk.arm(path.clone());
            stage_marks(&walk, own, carried);
            walk.run_to_tip(&chain).await;
            assert_eq!(walk.cursor(), Some(after));
            let s = walk.state();
            assert_eq!(
                (s.own, s.carried),
                (None, None),
                "a mark at the cursor the page left is passed ({own:?}, {carried:?})"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A sink that records the skips it hears.
    #[derive(Default)]
    struct SkipSink {
        skipped: Mutex<Vec<(Hash, Hash)>>,
    }

    impl MessageSink for SkipSink {
        fn fold(&self, _matches: Vec<TransportEvent>) -> VerdictFuture<'_> {
            Box::pin(async { Verdict::Folded })
        }
        fn skipped(&self, from: Hash, to: Hash) {
            self.skipped.lock().unwrap().push((from, to));
        }
    }

    /// **A skip reaches the user's gap notice** (LINK-Q4): the transport
    /// matcher hands the walk's `on_gap` to the hub's sink; with no sink armed
    /// there is no notice to speak and nothing is lost by saying nothing.
    #[test]
    fn a_skip_reaches_the_hubs_sink() {
        let (events, _) = broadcast::channel(4);
        let matcher = TransportMatcher::new(
            Prefix::Mainnet,
            events,
            Arc::new(Mutex::new(None)),
            Arc::new(DevAb::default()),
        );
        matcher.on_gap(h(1), h(2)); // no sink: a no-op
        let sink = Arc::new(SkipSink::default());
        matcher.set_sink(sink.clone());
        matcher.on_gap(h(3), h(4));
        assert_eq!(sink.skipped.lock().unwrap().clone(), vec![(h(3), h(4))]);
    }
}
