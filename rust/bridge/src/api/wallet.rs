//! Wallet sync across the FFI: balance + activity for the vault's derived
//! address window, over the wRPC client SHARED with the DAG monitor (P1 §0.8 /
//! D-005 — one client, one `UtxoProcessor`). DTOs only (INV-2: `Result`, never
//! a panic). `u64` sompi crosses as Dart `BigInt` (L3); KAS conversion is a
//! render-layer concern, never here.
//!
//! INV-9 — balance and maturity come from the pinned crates via
//! [`kaspaverse_chain::WalletEngine`]; this module only maps the chain-layer
//! event onto a DTO and folds (plain assignment, like `dag.rs`).
//!
//! INV-1 — the engine watches PUBLIC addresses derived inside `vault.rs`
//! (`vault::derive_wallet_addresses`); the seed/keychain never reach this
//! module. INV-3 — the activity store is an app-private file of public chain
//! data, owned by the chain layer.

use std::collections::HashMap;
#[cfg(test)]
use std::sync::atomic::AtomicUsize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, PoisonError};

use kaspaverse_chain::{
    AcceptanceEvent, ActivityDirection as ChainDirection, ActivityMaturity as ChainMaturity,
    NetworkId, NetworkType, TxStatus, WalletActivityRecord, WalletEngine, WalletEvent,
};
use tokio::sync::broadcast::{self, error::RecvError};

use crate::api::error::AppError;
use crate::api::{dag, vault};
use crate::frb_generated::StreamSink;

/// The trailing gap kept beyond the highest address known to hold funds — the
/// BIP44 gap-of-20 plus headroom. No longer the whole story: it is the *minimum*
/// window and the margin added past a discovery hit, never a ceiling.
pub(crate) const GAP_LIMIT: u32 = 30;

/// How deep a discovery pass probes per branch before it needs a reason to go
/// further. Sized to swallow an ordinary external-wallet history in one pass
/// (the case that motivated this: a Kaspium-used wallet sitting at change index
/// 77), while staying two `get_balances_by_addresses` round trips per branch.
/// Deeper than this is reachable, but only on evidence — see
/// [`discovery_depth_for`].
pub(crate) const DISCOVERY_DEPTH: u32 = 256;

/// The watch/sign window as `(receive, change)` — the SINGLE source for both
/// branches. The sync engine's initial scan, the transport key window and every
/// send's signer registration call this, so the watched set and the signer can
/// never drift (risk #5): funds you can see are funds you can spend.
///
/// Each branch is `GAP_LIMIT` past its discovered high-water mark, floored at
/// `GAP_LIMIT`. Change additionally floors at the send cursor (D-041) so a fresh
/// change address is always signable even before any discovery has run.
///
/// Superseded `change_window()`, which was `max(GAP_LIMIT, change_cursor + 1)`.
/// That looked like a widening rule and was not: `change_cursor` counts *our own*
/// broadcasts, so a wallet restored from another client read 0 and got a 30-wide
/// window regardless of how deep its real history went.
pub(crate) fn wallet_window() -> (u32, u32) {
    let (receive_hi, change_hi) = vault::scan_high_water();
    window_from(receive_hi, change_hi, vault::change_cursor())
}

/// The window arithmetic, split out from its disk reads so it can be tested
/// directly. This is where the defect lived — the old rule was a formula that
/// looked like widening and was not — so it is the part that gets asserted.
///
/// The persisted marks are **counts, not indices**: `receive_seen` is how many
/// indices must be covered, i.e. `highest_funded + 1`, and `0` means nothing has
/// been found. That distinction is load-bearing and was got wrong first time —
/// as a bare index, `0` means both "nothing found" and "index 0 is funded", and
/// a fresh wallet came out one address wider than the gap limit.
///
/// Both branches are capped at [`MAX_WINDOW`]. Saturating arithmetic alone is
/// not a defence here: it stops the window WRAPPING to something tiny but
/// happily returns `u32::MAX`, and every consumer scales linearly in this
/// number — a window is a derivation count. Wide and narrow are both fatal; the
/// first version of this function defended one and shipped a passing test that
/// blessed the other.
pub(crate) fn window_from(receive_seen: u32, change_seen: u32, change_cursor: u32) -> (u32, u32) {
    let receive = GAP_LIMIT
        .max(receive_seen.saturating_add(GAP_LIMIT))
        .min(MAX_WINDOW);
    let change = GAP_LIMIT
        .max(change_seen.saturating_add(GAP_LIMIT))
        .max(change_cursor.saturating_add(1))
        .min(MAX_WINDOW);
    (receive, change)
}

/// The ceiling on a derived window — the mark ceiling plus the gap always kept
/// past it.
///
/// It must sit **above** the index space the persisted counts can name, never
/// on it. A window is a COUNT: `build_wallet_signer` registers `0..count`, so a
/// ceiling equal to the highest index [`next_change_index`] can return would
/// hand out a change address one past the last signable one. The send would
/// succeed, return change to an address neither watched nor spendable, and the
/// cursor would keep naming that same dead index on every send after it. Fixing
/// an abort by opening a fund-loss path at the same boundary is not a fix.
///
/// The cursor is the taller of the two inputs (`MAX_CHANGE_CURSOR` 100 000
/// against `MAX_SCAN_MARK` 2048), so this is its ceiling plus one.
pub(crate) const MAX_WINDOW: u32 = vault::MAX_CHANGE_CURSOR + 1;

/// The two ceilings are one fact in two modules: a mark is
/// `highest_funded_index + 1` and a pass probes at most
/// [`MANUAL_DISCOVERY_DEPTH`] indices, so `vault::MAX_SCAN_MARK` must be exactly
/// what the DEEPEST pass can produce. Raise a probe depth without raising the
/// mark ceiling and every mark past it reads back as UNSET: the scan reports
/// success, the marks silently vanish, and the next call opens on the gap limit
/// — Track 1's original defect wearing a fresh button.
///
/// Pinned to the MANUAL depth, not the automatic one, because that is now the
/// deeper of the two. The first version of this assert named
/// `MAX_DISCOVERY_DEPTH`, and it would have kept passing while a *separate*
/// manual constant walked straight past it — the obvious shape, and the one the
/// deliverable's own wording suggested.
const _: () = assert!(vault::MAX_SCAN_MARK == MANUAL_DISCOVERY_DEPTH);
const _: () = assert!(MAX_DISCOVERY_DEPTH <= MANUAL_DISCOVERY_DEPTH);

/// A window is `mark + GAP_LIMIT` and [`window_from`] caps it at [`MAX_WINDOW`].
/// If the deepest producible mark plus the gap could exceed that cap, the cap
/// would silently narrow a window discovery had just proven — the same class of
/// bug from the other end.
const _: () = assert!(MANUAL_DISCOVERY_DEPTH + GAP_LIMIT <= MAX_WINDOW);

/// The next change index to hand out — the send cursor (D-041), floored at what
/// discovery found.
///
/// D-041's property is *fresh change per send*, and on a restored wallet the
/// cursor alone cannot deliver it: `change.cursor` counts broadcasts THIS app
/// made, so a wallet whose external history already reaches index 77 reads 0 and
/// the next send returns change to change/0 — an address that history already
/// spent from, linking the new transaction to it. Discovery knows better, so the
/// cursor is floored at the discovered mark (a count, so it is already the
/// next-unused index).
///
/// The bound is discovery's bound: it sees only *funded* addresses, so this
/// floors at the highest index still holding coins, not the highest ever used.
/// Strictly better than the cursor alone, not perfect.
pub(crate) fn next_change_index() -> u32 {
    vault::change_cursor().max(vault::scan_high_water().1)
}

/// Who asked for a discovery pass — and therefore how deep it may probe and how
/// long it may take.
///
/// The depth is a PARAMETER of the pass, not a property of the module. It was a
/// module constant while only the unlock path ever scanned, and that is exactly
/// why a wallet deeper than one automatic pass had no way to grow: the caller
/// with a user watching a spinner and the caller holding the unlock path open
/// have opposite budgets, and one number cannot serve both.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ScanReach {
    /// The unlock path's own pass. Bounded so the wallet opens promptly.
    Automatic,
    /// The user tapped "scan for more addresses" and is watching it run.
    Manual,
}

impl ScanReach {
    /// How deep to probe a branch, given what is already known about it.
    ///
    /// Automatic: always at least [`DISCOVERY_DEPTH`], always [`GAP_LIMIT`] past
    /// anything already found — so a wallet that has grown keeps growing instead
    /// of pinning itself at the last scan's edge — capped at
    /// [`MAX_DISCOVERY_DEPTH`].
    ///
    /// Manual: flat [`MANUAL_DISCOVERY_DEPTH`]. A user who asks us to look
    /// harder is not asking for `known + 30`; the whole point of the control is
    /// to reach past what the automatic rule can justify.
    pub(crate) fn depth_for(self, seen: u32) -> u32 {
        match self {
            ScanReach::Automatic => DISCOVERY_DEPTH
                .max(seen.saturating_add(GAP_LIMIT))
                .min(MAX_DISCOVERY_DEPTH),
            ScanReach::Manual => MANUAL_DISCOVERY_DEPTH,
        }
    }

    /// The whole pass's deadline. See [`DISCOVERY_PASS_TIMEOUT`] and
    /// [`MANUAL_SCAN_TIMEOUT`] for why they are not the same number.
    fn deadline(self) -> std::time::Duration {
        match self {
            ScanReach::Automatic => DISCOVERY_PASS_TIMEOUT,
            ScanReach::Manual => MANUAL_SCAN_TIMEOUT,
        }
    }
}

/// The deepest a single MANUAL pass will probe — the "scan for more addresses"
/// control's reach.
///
/// 2048 is 16 [`kaspaverse_chain::discovery::PROBE_BATCH`] chunks per branch,
/// with the branches concurrent, so a healthy node answers the whole thing in
/// seconds. It is ~26× the deepest real index this project has actually met on
/// chain (change/78, the founder's own wallet) and 4× what an automatic pass
/// will reach on its own.
///
/// Raising it is a TWO-line change, not one: `vault::MAX_SCAN_MARK` is the
/// ceiling a mark is validated against, and a mark this pass can produce but the
/// reader rejects reads back as UNSET. The compile assert above makes that a
/// build failure rather than a field report.
pub(crate) const MANUAL_DISCOVERY_DEPTH: u32 = 2048;

/// The deepest a single automatic pass will probe.
///
/// A window is derived once and held; a probe depth is **round trips on the
/// unlock path**, and the two must not share a ceiling. `MAX_WINDOW` as the cap
/// made the pass `ceil(100_000/128) = 782` sequential chunks — at
/// `PROBE_TIMEOUT` each, over two hours of a blocked gate, reachable from the
/// same corrupt bytes the mark validation exists for. At 512 the pass is at most
/// 4 chunks per branch, and the branches run concurrently.
///
/// A wallet genuinely deeper than this stops growing automatically, which is
/// the already-recorded bound: deeper than one pass reaches is the manual
/// "scan deeper" control's job (Track 2), not the unlock path's.
pub(crate) const MAX_DISCOVERY_DEPTH: u32 = 512;

/// A signer registered over the CURRENT window — the one call every send path
/// uses. Exists so the window reaches the signer as a single fact rather than as
/// two arguments each caller re-derives: three call sites previously passed
/// `(GAP_LIMIT, change_window())` by hand, and any one of them drifting from the
/// watched set would make a visible UTXO unspendable.
pub(crate) fn wallet_signer() -> Result<kaspaverse_core::VaultSigner, AppError> {
    let (receive, change) = wallet_window();
    vault::build_wallet_signer(receive, change)
}

// ── Address discovery ─────────────────────────────────────────────────────

/// Discovery's process-wide state. The async mutex makes the *pass itself* the
/// critical section, which is the point: a consumer that arrives mid-pass waits
/// for it and then reads a post-discovery window, instead of racing past and
/// freezing the pre-discovery one (the transport hub did exactly that — it
/// reached the window after only local store work, ahead of the probe).
///
/// The wait is bounded, and has to be, because callers block on it: one pass is
/// two `PROBE_TIMEOUT`s per branch at the default depth, and the branches run
/// concurrently — ≤ 20 s worst case, typically well under a second.
static DISCOVERY: tokio::sync::Mutex<Discovery> = tokio::sync::Mutex::const_new(Discovery {
    attempted: false,
    succeeded: false,
});

struct Discovery {
    /// A pass has RUN — success or failure. Opens the gate.
    attempted: bool,
    /// A pass has actually reached the node and read BOTH branches. Until this
    /// is true, every `Connected` (and every pull-to-refresh) tries again.
    ///
    /// This flag is the fix for the defect that blocked the first version of
    /// this change: `start()` only *initiates* the connect, and at the pin a
    /// call on a socket that is still dialling returns `NotConnected`
    /// immediately (`workflow-rpc client/mod.rs:479-480`). So a cold boot, a
    /// fast biometric unlock or a captive portal made discovery fail in
    /// milliseconds, and the one-shot cell then resolved on the stale 30-wide
    /// window for the entire process — byte-for-byte the bug being fixed, with
    /// one `log::warn!` as its only trace.
    succeeded: bool,
}

/// [`Discovery::succeeded`], mirrored where a reader that must not block can see
/// it.
///
/// The fold loop publishes a snapshot on every chain event and owes the glass its
/// next frame; it cannot take an async mutex that a 30 s network pass may be
/// holding. One writer ([`record_pass`], already under the guard), many lock-free
/// readers. `Relaxed` is the right ordering: this bit guards no other memory —
/// it is the whole payload, and a reader one event late simply paints the notice
/// for one more frame.
static DISCOVERY_PROVEN: AtomicBool = AtomicBool::new(false);

/// Has any discovery pass reached the node and read BOTH branches this process?
///
/// `false` means the watched window is the last known-good one and may be short —
/// the wallet is painting a balance it cannot vouch for. That is the state the
/// `discovery_incomplete` snapshot field exists to make visible, rather than
/// leaving a *confidently wrong number* on the glass.
pub(crate) fn discovery_proven() -> bool {
    DISCOVERY_PROVEN.load(Ordering::Relaxed)
}

/// The window to derive, watch and register — read only after the first
/// discovery pass has had its turn.
///
/// Every consumer that FREEZES a window for the session calls this. Callers that
/// merely read the live window (a send's signer) call [`wallet_window`]
/// directly: by then the gate is long open, and a send must never block on a
/// network probe.
/// Waiting here is bounded by whatever holds the gate, and there are now THREE
/// holders:
///
/// - the first pass — `DISCOVERY_PASS_TIMEOUT` (30 s);
/// - a retry, which also holds it across its re-registration — plus
///   `EXTEND_WATCH_TIMEOUT` (40 s total);
/// - the user's manual [`deep_scan`], which takes the same guard with `lock()`
///   and holds it across both halves — `MANUAL_SCAN_TIMEOUT` +
///   `EXTEND_WATCH_TIMEOUT` (**190 s**).
///
/// A retry can only exist once `snapshots()` has started the engine, so the sync
/// engine's own call is never the one that waits behind one — only the transport
/// hub's, which is fire-and-forget. The manual scan can only be tapped from a
/// screen that exists after the engine is up, so the same holds for it. This
/// enumeration is load-bearing (wallet-security item 13: the written cannot-block
/// proof has to stay true) and said 40 s while the third holder was 190.
pub(crate) async fn window_after_discovery() -> (u32, u32) {
    {
        let mut state = DISCOVERY.lock().await;
        if !state.attempted {
            // Outcome deliberately dropped: this caller cannot fail the open —
            // offline, a captive portal and a dead node all have to end in a
            // usable wallet on the last known-good window. `record_pass` has
            // already logged it and armed the retry.
            let _ = run_discovery_pass(&mut state, ScanReach::Automatic).await;
        }
    }
    wallet_window()
}

/// Try discovery again while no pass has yet succeeded, and — if the window
/// grew — register the widening with the LIVE engine.
///
/// That second half is what makes the retry real. Widening the persisted marks
/// only changes what a *future* process watches; the running `UtxoContext`
/// reports UTXOs for the addresses registered with it and nothing else, so
/// without the re-registration the funds stay invisible for this whole session
/// on a wallet that has just proved where they are.
///
/// Detached by every caller (the fold loop must keep painting, the pull gesture
/// must keep its own budget), so it reports through the log, not a return value.
///
/// The `DISCOVERY` guard is held across the **whole** thing — pass AND
/// re-registration — not just the pass. Releasing it early left two overlapping
/// retries free to interleave: the second widens to `W2` and publishes, then the
/// first publishes the `W1` it read before that, and `extend_watch`'s
/// refuse-to-narrow guard passes because it too read `previous` early. The
/// signer survives that (it reads the monotonic marks, never the watch set), so
/// it is not fund loss — but the engine re-registers from `watch` on every
/// `UtxoProcStart`, so the lost addresses go deaf to live deposits until
/// relaunch, and change arriving there is misread as a deposit. Under the guard,
/// `try_lock` makes the second retry the no-op it was always meant to be.
pub(crate) async fn retry_discovery_if_unproven() {
    // `try_lock`, not `lock`: a pass already in flight IS the retry. Waiting
    // would queue one spawn per reconnect, and a link that flaps every
    // `RACE_RETRY_DELAY` (3 s) against a node slow enough to need retrying
    // would grow that queue without bound — every entry then running a full
    // pass against the same sick node.
    let Ok(mut state) = DISCOVERY.try_lock() else {
        return;
    };
    if state.succeeded {
        return;
    }
    let before = wallet_window();
    // Outcome deliberately dropped — this is detached fire-and-forget by every
    // caller, so the log is its only report and a failure just leaves `succeeded`
    // false for the next `Connected` to retry.
    let _ = run_discovery_pass(&mut state, ScanReach::Automatic).await;
    republish_window(before).await;
}

/// Tell everything that FROZE a window that the window just grew.
///
/// The shared half of every pass that can widen — the retry above and the manual
/// deep scan below. Extracted rather than copied on purpose: a second widening
/// mechanism is exactly the drift this module already paid for once, and the two
/// consumers below must never diverge in which of them gets told.
///
/// **Must be called with the `DISCOVERY` guard still held.** Releasing it before
/// this ran left two overlapping passes free to interleave: the second widens to
/// `W2` and publishes, then the first publishes the `W1` it read before that, and
/// `extend_watch`'s refuse-to-narrow guard passes because it too read `previous`
/// early. The signer survives that (it reads the monotonic marks, never the watch
/// set), so it is not fund loss — but the engine re-registers from `watch` on
/// every `UtxoProcStart`, so the lost addresses go deaf to live deposits until
/// relaunch, and change arriving there is misread as a deposit.
///
/// Returns whether the window actually grew, which is the only thing a caller
/// with a user watching can honestly report.
/// The pass → republish ordering, with the pass injected so a test can drive the
/// error path and still observe that the widening was published.
///
/// Exists because the property that matters — *republish happens even when the
/// pass fails* — is invisible from `deep_scan`'s return value: the `Err` looks
/// identical either way, and the damage shows up a session later as a balance
/// that is quietly short.
async fn finish_scan(
    before: (u32, u32),
    pass: impl std::future::Future<Output = Result<(u32, u32), AppError>>,
) -> Result<(u32, u32, bool), AppError> {
    let outcome = pass.await;
    let widened = republish_window(before).await;
    let (receive_seen, change_seen) = outcome?;
    Ok((receive_seen, change_seen, widened))
}

/// How many times [`republish_window`] has run — the observable the widening
/// seam otherwise lacks. Both consumers are no-ops in a test process (no engine,
/// no transport hub), so without this a test asserting on their effects passes
/// whether or not they were called at all.
#[cfg(test)]
static REPUBLISH_CALLS: AtomicUsize = AtomicUsize::new(0);

async fn republish_window(before: (u32, u32)) -> bool {
    #[cfg(test)]
    REPUBLISH_CALLS.fetch_add(1, Ordering::Relaxed);
    let after = wallet_window();
    let widened = after != before;
    // Both consumers are told UNCONDITIONALLY, and `widened` is only the report.
    //
    // The delta is measured against the caller's `before` — the marks — not
    // against what the engine actually watches, and those two can disagree: any
    // path that grows the marks without completing a re-registration (a
    // `derive_wallet_addresses` that hits the §0.11 lock mid-pass, an
    // `extend_watch` that times out) leaves a widening the marks already contain.
    // Gated on the delta, every later pass then reads that leak as `before`, sees
    // nothing to do, and the engine stays narrow for the life of the process.
    //
    // Both calls are idempotent and cheap in the state that matters:
    // `widen_key_window` early-returns when the slots already cover the window,
    // and `extend_watch` answers `Ok(0)` when nothing is new. The real cost is
    // the derivation below, and it is bounded by who reaches here — retries only
    // run while no pass has succeeded, and the manual scan is a user tap with a
    // spinner (consensus-auditor, Track 2).
    if widened {
        log::info!(
            "wallet: discovery widened the window from {before:?} to {after:?} — re-registering"
        );
    }
    // Both consumers that FROZE a window get told, and neither is allowed to
    // skip the other: an early return here once left the messaging hub on the
    // narrow window whenever the sync engine happened not to be up yet.
    //
    // The messaging hub froze the same window (its watched set and key slots);
    // a widening it never hears about leaves a real address watched with no key
    // slot behind it — a message we can never decrypt.
    super::transport::widen_key_window(after);
    let Some(engine) = engine_handle() else {
        // No engine yet: `snapshots()` has not started one, so it will derive
        // from the widened marks when it does. Nothing to re-register.
        return widened;
    };
    match vault::derive_wallet_addresses(after.0, after.1) {
        Ok((addresses, change_addresses)) => {
            match tokio::time::timeout(
                EXTEND_WATCH_TIMEOUT,
                engine.extend_watch(addresses, change_addresses),
            )
            .await
            {
                Ok(Ok(0)) => {}
                Ok(Ok(added)) => log::info!(
                    "wallet: {added} newly discovered addresses registered with the live engine"
                ),
                // Not silent, and not lost: `extend_watch` publishes the wider
                // set before registering, so the next `UtxoProcStart` or any
                // pull-to-refresh re-asks the node for it.
                Ok(Err(e)) => log::warn!(
                    "wallet: widened window not registered ({e}) — a refresh or reconnect re-asks"
                ),
                Err(_) => log::warn!(
                    "wallet: widened window registration timed out — a refresh or reconnect re-asks"
                ),
            }
        }
        Err(e) => log::warn!(
            "wallet: widened window not derivable ({}) — vault locked",
            e.message
        ),
    }
    widened
}

/// What a manual scan found — the honest report the Settings control renders.
///
/// Marks are COUNTS (`highest_funded_index + 1`), the same form the window
/// arithmetic and the persisted file use; `0` means nothing funded was found on
/// that branch, never "index 0 is funded". See [`window_from`] for why.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeepScanReport {
    /// Indices probed per branch.
    pub depth: u32,
    pub receive_seen: u32,
    pub change_seen: u32,
    /// The watch/sign window actually grew — the wallet now sees more than it did
    /// before the tap. `false` is the ordinary, *successful* "nothing new out
    /// there", and the control must say so rather than implying a failure.
    pub widened: bool,
}

/// Probe far deeper than an automatic pass will, at the user's explicit request —
/// the "scan for more addresses" control.
///
/// **Why this exists.** An automatic pass is capped at [`MAX_DISCOVERY_DEPTH`] so
/// the unlock path cannot be held for minutes by a large persisted mark, which
/// means a wallet whose funded indices run past that — pushed there by another
/// client while this app was closed — never widens on its own. This is the manual
/// lever for exactly that case, and it takes its depth as a parameter rather than
/// inheriting the automatic cap.
///
/// **It reuses the one widening seam.** The pass and the re-registration are the
/// same code the automatic retry runs ([`republish_window`]); a second widening
/// mechanism is precisely the drift this module has already paid for once.
///
/// Requires an unlocked vault (it derives addresses) — Settings is only reachable
/// unlocked, and a locked vault errors honestly rather than reporting an empty
/// scan as success.
///
/// **Republish before `?`, always.** A failed pass is not an empty one:
/// `persist_from_probe` keeps whatever came back and persists it even when the
/// other branch errored, because the marks are monotonic and a discarded widening
/// is one we have to pay to probe for again. So an `Err` here routinely arrives
/// with the marks ALREADY grown, and returning early would strand that widening
/// in the marks with nothing told — signer wide, watch narrow, the exact drift
/// [`wallet_window`] exists to make impossible. Worse, it is self-confirming: the
/// next scan reads the grown marks as `before`, sees no delta, and reports
/// "nothing new found" over funds it has just made invisible for the session.
///
/// That ordering lives in [`finish_scan`] rather than inline, because a rule
/// spelled out only in a comment is a rule with no test (consensus-auditor,
/// Track 2 — the first fix was correct and its regression guard could not fail).
pub async fn deep_scan() -> Result<DeepScanReport, AppError> {
    // `lock`, not `try_lock`. The automatic retry uses `try_lock` because a pass
    // already in flight IS the retry and queueing them against a sick node grows
    // without bound. Here a user has tapped a control and is watching it: the
    // honest behaviour is to wait for the pass in front and then run, never to
    // return "done" having done nothing.
    let mut state = DISCOVERY.lock().await;
    let before = wallet_window();
    let (receive_seen, change_seen, widened) =
        finish_scan(before, run_discovery_pass(&mut state, ScanReach::Manual)).await?;
    log::info!(
        "wallet: manual deep scan to depth {MANUAL_DISCOVERY_DEPTH} — \
         marks receive={receive_seen} change={change_seen}, widened={widened}"
    );
    Ok(DeepScanReport {
        depth: MANUAL_DISCOVERY_DEPTH,
        receive_seen,
        change_seen,
        widened,
    })
}

/// The whole pass's deadline, and therefore the whole gate's: the longest the
/// sync engine and the messaging hub can be held before they open on the last
/// known-good window.
///
/// Three times the codebase's single-call tier (`SOFT_RESCAN_TIMEOUT`,
/// `PAGE_TIMEOUT`, `BIND_ENVELOPE_TIMEOUT` are all 10 s), because a pass is a
/// multi-call operation: at `MAX_DISCOVERY_DEPTH` it is 4 chunks per branch with
/// the branches concurrent, and a healthy node answers each in well under a
/// second. Only a sick one gets anywhere near this — and against a sick node the
/// right answer is to open the wallet and retry, not to keep waiting.
const DISCOVERY_PASS_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// The engine's registration budget for a late widening — the
/// `SOFT_RESCAN_TIMEOUT` pattern, for the same reason: `extend_watch` reaches
/// `get_utxos_by_addresses`, which is pin-bounded at ≈65 s and nothing of ours.
/// Detached, so a timeout costs a log line; the next `UtxoProcStart` or pull
/// re-asks for the set, which `extend_watch` has already published.
const EXTEND_WATCH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// The manual scan's deadline. Deliberately NOT [`DISCOVERY_PASS_TIMEOUT`]: that
/// number is the longest the UNLOCK PATH may be held, and nothing is held here —
/// the vault is already open and a user is watching the control run.
///
/// [`MANUAL_DISCOVERY_DEPTH`] is 16 chunks per branch, so against a node slow
/// enough to spend a full `PROBE_TIMEOUT` on each of them the branch alone would
/// take 160 s. This is that worst case plus headroom; a healthy node finishes in
/// seconds and never approaches it.
const MANUAL_SCAN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(180);

/// Run one pass and record what it means.
///
/// Never fails upward: discovery failing must not stop the wallet from opening —
/// offline, a captive portal and a dead node all have to end in a usable wallet
/// on the last known-good window. It must only leave `succeeded` false so
/// something tries again.
///
/// Returns the pass outcome so a caller with a user watching can report it. The
/// automatic callers ignore it — for them the log IS the report.
async fn run_discovery_pass(
    state: &mut Discovery,
    reach: ScanReach,
) -> Result<(u32, u32), AppError> {
    state.attempted = true;
    let monitor = match dag::shared_monitor().await {
        Ok(monitor) => monitor,
        Err(e) => {
            log::warn!(
                "wallet: address discovery has no client yet ({}) — will retry on connect",
                e.message
            );
            return Err(e);
        }
    };
    // One deadline for the WHOLE pass, on top of the per-probe one. Both
    // consumers block on this gate, so the guarantee that matters to them is
    // "the wallet opens within N seconds", not "each round trip is bounded":
    // per-call deadlines alone multiply by the chunk count, which scales with
    // the persisted mark. Partial findings are lost when it fires (the probes
    // are dropped) — the retry re-asks, and a window that widens late is now
    // harmless.
    let outcome = match tokio::time::timeout(
        reach.deadline(),
        discover_and_persist_window(&monitor.rpc(), reach),
    )
    .await
    {
        Ok(outcome) => outcome,
        Err(_) => Err(AppError::msg(format!(
            "discovery pass exceeded its {} s deadline",
            reach.deadline().as_secs()
        ))),
    };
    match &outcome {
        Ok((receive_seen, change_seen)) => log::info!(
            "wallet: address discovery complete — funded marks receive={receive_seen} change={change_seen}"
        ),
        // `.message` deliberately, not the whole error: AppError's contract is
        // that the message is secret-free by construction (api/error.rs), and
        // liblog reaches logcat on every build flavour (L53/D-076).
        Err(e) => log::warn!(
            "wallet: address discovery incomplete ({}) — keeping the last known window, will retry",
            e.message
        ),
    }
    record_pass(state, &outcome);
    outcome
}

/// Fold a pass outcome into the gate.
///
/// `attempted` opens the gate for everyone waiting on it, whatever happened —
/// an offline wallet must still open. `succeeded` is the flag that stops the
/// retries, and ONLY a complete pass sets it: that asymmetry is the whole fix.
/// It never clears, so a later failure can never re-arm retries against a window
/// already proven.
fn record_pass(state: &mut Discovery, outcome: &Result<(u32, u32), AppError>) {
    state.attempted = true;
    let was_proven = state.succeeded;
    state.succeeded |= outcome.is_ok();
    // The lock-free mirror the fold path reads. Written under the guard, like
    // the field it mirrors, so the two can never disagree.
    DISCOVERY_PROVEN.store(state.succeeded, Ordering::Relaxed);
    if state.succeeded && !was_proven {
        // The honesty notice is keyed on this bit, and a pass that proves the
        // window without changing it produces no chain event — so without this
        // the glass would keep warning about a window we have just vouched for
        // until something unrelated happened to tick.
        republish_latest();
    }
}

/// Probe both branches for funded addresses and record the high-water marks.
///
/// **When it runs.** Once per process, before the window is frozen — plus a
/// retry on every `Connected` and every pull-to-refresh until one pass
/// succeeds. NOT on every unlock: a resident Android process that is
/// backgrounded and foregrounded for days re-probes only if it reconnects. That
/// is a real bound and it is stated here rather than in a comment that claims
/// otherwise, because a wallet is a shared object — the founder's own case had
/// Kaspium advancing the change branch between our sessions.
///
/// **Monotonic and best-effort.** The marks only ever grow: a probe that finds
/// nothing — including one that failed because the node was unreachable — must
/// never shrink a window that previously found funds, or a flaky connection
/// would strand coins we had already learned to watch. `Err` means *incomplete,
/// try again*, never *narrow the window*.
async fn discover_and_persist_window(
    rpc: &kaspaverse_chain::Rpc,
    reach: ScanReach,
) -> Result<(u32, u32), AppError> {
    // Two independent questions about the chain, so they are asked
    // CONCURRENTLY — halving what a caller waits on the gate. `join!`, never
    // `try_join!`: `try_join!` returns on the first error and DROPS the other
    // branch, discarding an answer we would have kept — the marks are
    // monotonic, so a half-answer can only widen, and a widening thrown away is
    // one we have to pay to probe for again.
    persist_from_probe(reach, |receive, change| async move {
        tokio::join!(
            kaspaverse_chain::discovery::highest_funded_index(rpc, &receive),
            kaspaverse_chain::discovery::highest_funded_index(rpc, &change),
        )
    })
    .await
}

/// The derive → probe → record half of a pass, with the probe injected (the
/// `history_fill::walk_pages` pattern). Split out because the behaviour that
/// matters here — *a failed pass must leave the window recoverable, and the next
/// one must widen it* — is precisely what cannot be tested against a real
/// socket, and shipping it untested is how this defect got here.
async fn persist_from_probe<P, Fut>(reach: ScanReach, probe: P) -> Result<(u32, u32), AppError>
where
    P: FnOnce(Vec<kaspaverse_chain::Address>, Vec<kaspaverse_chain::Address>) -> Fut,
    Fut: std::future::Future<
        Output = (
            kaspaverse_chain::Result<Option<u32>>,
            kaspaverse_chain::Result<Option<u32>>,
        ),
    >,
{
    let (known_receive, known_change) = vault::scan_high_water();
    let depth_receive = reach.depth_for(known_receive);
    let depth_change = reach.depth_for(known_change);
    // A pass may legitimately probe SHALLOWER than what is already known, now
    // that the two ceilings differ: an automatic pass stops at
    // `MAX_DISCOVERY_DEPTH` while a manual scan can have pushed a mark all the
    // way to `MANUAL_DISCOVERY_DEPTH`. That is not a narrowing — `mark` below
    // takes `known.max(found + 1)` and `set_scan_high_water` maxes again, so a
    // shallow pass over a deep wallet re-verifies the shallow part and leaves the
    // deep mark standing.
    //
    // The assert that used to sit here read `depth >= known`. It was true only
    // while `MAX_SCAN_MARK == MAX_DISCOVERY_DEPTH` made it true by construction,
    // and raising the mark ceiling for the manual scan would have made it fire on
    // the next automatic pass over exactly the deep wallet the manual scan
    // exists for — a debug-build panic reachable from a shipped control.
    debug_assert!(
        depth_receive <= MANUAL_DISCOVERY_DEPTH && depth_change <= MANUAL_DISCOVERY_DEPTH
    );

    // The branches are named explicitly — no slicing a concatenation on the
    // strength of a comment about its layout.
    let (receive, change) = vault::derive_wallet_branches(depth_receive, depth_change)?;
    let (found_receive, found_change) = probe(receive, change).await;

    // Index → count (`highest + 1`); nothing found stays at the known mark. See
    // `window_from` for why the persisted form is a count and not an index.
    // Whatever DID come back is kept even when the other branch failed: the
    // marks are monotonic, so a half-answer can only widen, and a widening
    // thrown away is a widening we have to pay for again.
    let mark = |known: u32, found: &kaspaverse_chain::Result<Option<u32>>| match found {
        Ok(Some(index)) => known.max(index.saturating_add(1)),
        _ => known,
    };
    let receive_seen = mark(known_receive, &found_receive);
    let change_seen = mark(known_change, &found_change);

    if (receive_seen, change_seen) != (known_receive, known_change) {
        // A failed persist is not a failed pass: `set_scan_high_water` records
        // the marks in memory as well, so THIS session already watches the
        // right window and only the next launch pays for a re-probe. The old
        // shape returned here and left the caller re-reading the stale marks
        // off disk — discarding a correct scan on exactly the restored wallet
        // this mechanism exists for.
        if let Err(e) = vault::set_scan_high_water(receive_seen, change_seen) {
            log::warn!(
                "wallet: discovery marks not persisted ({}) — this session still uses them",
                e.message
            );
        }
    }

    match (found_receive, found_change) {
        (Ok(_), Ok(_)) => Ok((receive_seen, change_seen)),
        (Err(e), _) | (_, Err(e)) => Err(AppError::chain(e)),
    }
}

/// **The one network this wallet is on** (P1: mainnet, fixed for the install).
///
/// Named once because two readers must never disagree: the engine that folds
/// maturity is started on it, and [`maturity_thresholds`] reads the pin's
/// `NetworkParams` for it. Two literals here would let the glass quote devnet
/// thresholds over a mainnet balance, which is precisely the class of split
/// D-249 caught in the UI.
fn wallet_network_id() -> NetworkId {
    NetworkId::new(NetworkType::Mainnet)
}

/// The maturity thresholds the wallet applies, crossing the FFI as **data**.
///
/// D-249: UX-R3 **must not hardcode** 100 or 1,000. Both live on the pinned
/// side (`user_transaction_maturity_period_daa`,
/// `coinbase_transaction_maturity_period_daa`) and reach the glass through
/// here, so the burial ladder's rungs and the gauge's ceiling are the
/// library's numbers on every build rather than a transcription of them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MaturityParamsDto {
    /// Depth at which a payment from someone else becomes spendable — the
    /// `Settled` rung for an ordinary row.
    pub user_daa: u64,
    /// Depth at which a mined coinbase output matures — the `Settled` rung for
    /// a coinbase row, and the gauge's ceiling when `is_coinbase` is set.
    pub coinbase_daa: u64,
    // **The stasis window does not cross.** `MaturityParams` carries it on the
    // Rust side, where a reader of the struct can see the third number without
    // looking it up — but nothing in `lib/` renders it, and a field on the FFI
    // surface that nobody reads is surface for its own sake
    // (`consensus-auditor`, UX-R3).
}

/// Read the pin's maturity thresholds for this wallet's network.
///
/// Synchronous and I/O-free by construction (the library answers from its own
/// statics), so the app can seed the ladder before it paints a first frame and
/// no surface ever has to render a rung against a threshold it does not have.
#[flutter_rust_bridge::frb(sync)]
pub fn maturity_thresholds() -> Result<MaturityParamsDto, AppError> {
    let params = kaspaverse_chain::maturity_params(wallet_network_id()).map_err(AppError::chain)?;
    Ok(MaturityParamsDto {
        user_daa: params.user_daa,
        coinbase_daa: params.coinbase_daa,
    })
}

/// Direction of an activity row (mapped from the wallet framework's typed
/// transaction data). Receive-only at P1.5; outgoing/change rows arrive with
/// send (P1.6).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActivityDirection {
    Incoming,
    Outgoing,
    Change,
}

/// Maturity of an activity row. `Pending`/`Confirmed` come from wallet-core
/// (`TransactionRecord::maturity()` at the live DAA — never our own
/// threshold; INV-9). `Accepted` is the V1 acceptance-spine overlay: the
/// chain accepted the txid (VirtualChainChanged, node-read) but wallet-core
/// hasn't folded it yet — this kills the "Pending" lie the V0 baselines
/// measured (≥15 s past on-chain acceptance). V1 renders it on the existing
/// confirmed chip (semantically identical for spends); V2's three-state chip
/// differentiates. `Unknown` is the V2b cold-start honesty state (finding
/// 13): a receive folded before the processor has live DAA is unresolvable —
/// it renders quiet (no chip), never a fake Pending streaming a huge counter.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MaturityState {
    Pending,
    Accepted,
    Confirmed,
    Unknown,
}

/// One activity row crossing the FFI. `*_sompi` / DAA stay `u64` (Dart `BigInt`,
/// L3); public chain data only.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActivityRecord {
    pub txid: String,
    pub value_sompi: u64,
    pub unixtime_msec: Option<u64>,
    pub block_daa_score: u64,
    /// DAA score at which the DAG accepted this spend (`None` for a receive or a
    /// not-yet-accepted spend) — the honest anchor for a send's confirmation-
    /// depth counter (`current_daa − accepted_daa_score`), where
    /// `block_daa_score` on a send is submit time and would overstate.
    pub accepted_daa_score: Option<u64>,
    pub direction: ActivityDirection,
    pub is_coinbase: bool,
    /// **Who this spend paid**, in bech32 — the single output of our own
    /// transaction that is not our change. `None` on a receive, on a
    /// multi-recipient send, and on a compounding leg; the chain layer's
    /// `counterparty_of` documents why a receive can never carry one. Public
    /// chain data (INV-3): an address, never a name — the address book joins
    /// a name to it on the Dart side, and BG-15 keeps the address visible.
    pub counterparty_address: Option<String>,
    /// The network fee this transaction paid, in sompi — `None` on a receive,
    /// which did not pay it. See the chain layer's field for why that is an
    /// absence rather than a zero.
    pub fee_sompi: Option<u64>,
    pub maturity: MaturityState,
    /// V2 chip honesty: the tracker has seen no acceptance for this SUBMITTED
    /// txid past the stall threshold (Send-sourced watches only — V1 signal
    /// #3). Rides alongside `maturity` (a stalled row is still Pending);
    /// never persisted — recomputed from the live overrides on every fold.
    pub stalled: bool,
}

/// Live wallet state, streamed on every change. Balances are `Option` so the UI
/// can tell "not synced yet" (`None` → DS-1 unknown `—`) from a real, live zero
/// (`Some(0)` → an empty wallet shows `0.00000000`, never unknown). A plain
/// struct, not an enum-with-fields (FRB DTO note, `dag.rs`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct WalletSnapshot {
    pub connected: bool,
    /// Between `UtxoProcStart` and the first balance — the initial scan.
    pub syncing: bool,
    /// The connected node has no UTXO index (INV-8 honest degrade).
    pub utxo_index_missing: bool,
    /// No address-discovery pass has reached the node this process, so the
    /// watched window is the last known-good one and **may be short** — the
    /// balance below it is computed over fewer addresses than the wallet might
    /// actually hold.
    ///
    /// The sibling of [`Self::utxo_index_missing`], and it exists for the same
    /// reason: without it the wallet paints a *confidently wrong number*, which
    /// this project treats as worse than a visible unknown. The retry machinery
    /// makes the state narrow and transient, but narrow-and-transient is a
    /// probability argument, not honesty.
    pub discovery_incomplete: bool,
    pub mature_sompi: Option<u64>,
    pub pending_sompi: Option<u64>,
    pub outgoing_sompi: Option<u64>,
    /// Newest-first, capped by the chain layer.
    pub activity: Vec<ActivityRecord>,
    pub error: Option<String>,
}

/// The process-lifetime sync engine, kept alive here (its broadcast Sender must
/// outlive the fold task). One vault per process at P1 (a created/restored vault
/// is fixed for the install; switching needs a restart — documented).
static ENGINE: Mutex<Option<WalletEngine>> = Mutex::new(None);

/// Snapshot fan-out, created once; every Dart subscription (incl. after a hot
/// restart) re-attaches to it.
static SNAPSHOTS: tokio::sync::OnceCell<broadcast::Sender<WalletSnapshot>> =
    tokio::sync::OnceCell::const_new();
/// Latest folded state, so a fresh subscriber paints immediately.
static LATEST: Mutex<Option<WalletSnapshot>> = Mutex::new(None);

/// Stamp the process-wide truths no `WalletEvent` carries, record, and fan out.
///
/// The one publish point. It exists because the fold loop has two of them (a
/// chain event and an acceptance event) and `discovery_incomplete` belongs to
/// neither — it is read from the discovery gate, not folded from a message. Two
/// hand-written copies of "stamp, store, send" is one place for a future third
/// publish site to forget a field.
fn publish(current: &mut WalletSnapshot, fan_out: &broadcast::Sender<WalletSnapshot>) {
    current.discovery_incomplete = !discovery_proven();
    *LATEST.lock().unwrap_or_else(PoisonError::into_inner) = Some(current.clone());
    let _ = fan_out.send(current.clone());
}

/// Re-serve the last folded snapshot because a process-wide truth changed.
///
/// Discovery proving out is not a chain event, so nothing else would push the
/// cleared notice to the glass; on a wallet whose window did not change, the next
/// chain event could be minutes away. A no-op before the engine has folded
/// anything.
fn republish_latest() {
    let Some(fan_out) = SNAPSHOTS.get() else {
        return;
    };
    let Some(mut snapshot) = latest_snapshot() else {
        return;
    };
    publish(&mut snapshot, fan_out);
}

/// The live sync engine handle, for send construction (P1.6 [`crate::api::send`]).
/// `None` until the home screen has subscribed (the engine starts lazily on the
/// first subscribe) — a send before then errors honestly.
pub(crate) fn engine_handle() -> Option<WalletEngine> {
    ENGINE
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
}

/// The latest folded snapshot, for send's "insufficient vs still-confirming"
/// classification (reads `pending`/`mature` — nothing recomputed, INV-9).
pub(crate) fn latest_snapshot() -> Option<WalletSnapshot> {
    LATEST
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
}

fn map_activity(record: WalletActivityRecord) -> ActivityRecord {
    ActivityRecord {
        txid: record.txid,
        value_sompi: record.value_sompi,
        unixtime_msec: record.unixtime_msec,
        block_daa_score: record.block_daa_score,
        accepted_daa_score: record.accepted_daa_score,
        direction: match record.direction {
            ChainDirection::Incoming => ActivityDirection::Incoming,
            ChainDirection::Outgoing => ActivityDirection::Outgoing,
            ChainDirection::Change => ActivityDirection::Change,
        },
        is_coinbase: record.is_coinbase,
        counterparty_address: record.counterparty_address,
        fee_sompi: record.fee_sompi,
        maturity: match record.maturity {
            ChainMaturity::Pending => MaturityState::Pending,
            ChainMaturity::Confirmed => MaturityState::Confirmed,
            ChainMaturity::Unknown => MaturityState::Unknown,
        },
        stalled: false,
    }
}

/// The V1 acceptance overlay: what the tracker knows about a txid, folded
/// onto the wallet-core maturity. Rules (V1 design, founder-nodded):
/// tracker Accepted upgrades Pending but never downgrades a wallet-core
/// Confirmed; tracker Confirmed (blue-score depth, node-read) confirms;
/// Displaced drops the row to Pending — even from Confirmed — because its
/// accepting block left the selected chain (honesty over comfort; wallet-core
/// converges via its own reorg handling). Submitted/Stalled change nothing
/// here (stall surfaces in V3). An `Unknown` row (V2b — no live DAA yet)
/// upgrades on the same rules: the tracker's node-read knowledge is exactly
/// what resolves the cold-start unknown.
fn overlaid(current: MaturityState, status: &TxStatus) -> MaturityState {
    match status {
        TxStatus::Accepted { .. } => match current {
            MaturityState::Confirmed => MaturityState::Confirmed,
            _ => MaturityState::Accepted,
        },
        TxStatus::Confirmed { .. } => MaturityState::Confirmed,
        TxStatus::Displaced => MaturityState::Pending,
        TxStatus::Submitted | TxStatus::Stalled { .. } => current,
    }
}

/// Apply the tracker overrides to every matching activity row (cheap: the
/// list is capped by the chain layer, the map by the tracker's watch cap).
/// `stalled` is recomputed for EVERY row — a row whose override cleared
/// (acceptance landed, or the watch pruned) must drop the flag, never wear
/// it stale.
fn apply_overrides(snapshot: &mut WalletSnapshot, overrides: &HashMap<String, TxStatus>) {
    for row in &mut snapshot.activity {
        let status = overrides.get(&row.txid);
        if let Some(status) = status {
            row.maturity = overlaid(row.maturity, status);
        }
        row.stalled = matches!(status, Some(TxStatus::Stalled { .. }));
    }
}

/// Fold an absolute chain-layer event into the snapshot — plain assignment
/// (INV-9: nothing computed here; balance/maturity already decided by the pin).
fn fold(snapshot: &mut WalletSnapshot, event: WalletEvent) {
    match event {
        WalletEvent::Connected { .. } => {
            snapshot.connected = true;
            snapshot.error = None;
        }
        WalletEvent::Disconnected => snapshot.connected = false,
        WalletEvent::Syncing => snapshot.syncing = true,
        WalletEvent::UtxoIndexMissing { .. } => snapshot.utxo_index_missing = true,
        WalletEvent::Balance {
            mature,
            pending,
            outgoing,
        } => {
            // A real balance arrived (even all-zero): sync resolved. An empty
            // wallet becomes a live `Some(0)`, never unknown / skeleton-forever.
            snapshot.mature_sompi = Some(mature);
            snapshot.pending_sompi = Some(pending);
            snapshot.outgoing_sompi = Some(outgoing);
            snapshot.syncing = false;
            // We computed a balance, so the node's index works — clear any
            // stale degrade flag from a previous (bad) node.
            snapshot.utxo_index_missing = false;
        }
        WalletEvent::Activity(records) => {
            snapshot.activity = records.into_iter().map(map_activity).collect();
        }
        WalletEvent::Error(message) => snapshot.error = Some(message),
    }
}

/// Initialise (once) the shared sync engine over the shared wRPC client and the
/// snapshot fan-out. Requires an unlocked vault (address derivation) — the
/// caller (post-unlock home screen) guarantees this.
async fn snapshots() -> Result<&'static broadcast::Sender<WalletSnapshot>, AppError> {
    SNAPSHOTS
        .get_or_try_init(|| async {
            // Bind to the SAME wRPC client the DAG monitor uses (§0.8 / D-005).
            let monitor = dag::shared_monitor().await?;

            // Discovery runs BEFORE the window is fixed, because the window is
            // what it produces. A wallet restored from another client can hold
            // funds far past the default gap — the case this exists for had them
            // at change index 77 against a 30-wide window, invisible AND
            // unspendable. The gate is shared with the transport hub so the two
            // can never freeze different windows, and it never fails the open:
            // a pass that could not reach the node leaves the last known-good
            // window in place and arms the retry below.
            //
            // Derive the public watch set from the unlocked vault (INV-1: the
            // seed never leaves vault.rs). The change subset lets the engine
            // tell our own returning change from a real deposit.
            let (receive_count, change_count) = window_after_discovery().await;
            let (addresses, change_addresses) =
                vault::derive_wallet_addresses(receive_count, change_count)?;
            let engine = WalletEngine::new(
                monitor.rpc(),
                wallet_network_id(),
                vault::wallet_store_path()?,
            )
            .map_err(AppError::chain)?;

            let mut events = engine.subscribe();
            engine
                .start(addresses, change_addresses)
                .await
                .map_err(AppError::chain)?;
            // Keep the engine alive for the process (its Sender feeds `events`).
            *ENGINE.lock().unwrap_or_else(PoisonError::into_inner) = Some(engine);

            // V1 consumer #1: the acceptance tracker's events overlay the
            // snapshot the instant the chain answers — the wallet no longer
            // waits for wallet-core to notice (the V0 ≥15 s "Pending" lie).
            // Soft dependency: a tracker bootstrap failure degrades to the
            // pre-V1 behavior, never blocks the wallet.
            let tracker = match super::dag::shared_tracker().await {
                Ok(tracker) => Some(tracker),
                Err(e) => {
                    log::warn!(
                        "wallet: acceptance tracker unavailable ({}) — status overlay off",
                        e.message
                    );
                    None
                }
            };
            let mut acceptance_rx = tracker.as_ref().map(|t| t.subscribe());

            let (sender, _) = broadcast::channel(64);
            let fan_out = sender.clone();
            tokio::spawn(async move {
                let mut current = WalletSnapshot::default();
                // txid → last tracker status; entries clear when the tracker
                // prunes a watch (status() = None → wallet-core truth resumes).
                let mut overrides: HashMap<String, TxStatus> = HashMap::new();
                loop {
                    tokio::select! {
                        event = events.recv() => {
                            match event {
                                Ok(event) => {
                                    if matches!(event, WalletEvent::Balance { .. }) {
                                        // V1 span: a real sync completed — the
                                        // resume→resynced row pairs this with
                                        // the last `resume_start`.
                                        kaspaverse_chain::spans::mark("wallet_balance");
                                    }
                                    if matches!(
                                        event,
                                        WalletEvent::Connected { .. } | WalletEvent::Syncing
                                    ) {
                                        // The socket the first pass could not
                                        // reach is usable now. BOTH events,
                                        // because at the pin they cover
                                        // different paths: `Connect` is
                                        // broadcast only from the
                                        // `RpcState::Connected` arm, and
                                        // `UtxoProcessor::start()` on an
                                        // ALREADY-connected client calls
                                        // `handle_connect()` directly without
                                        // it (`processor.rs:704-705, 717-723`)
                                        // — which is the normal path here,
                                        // since the chain service connects at
                                        // app start and the engine starts after
                                        // unlock. `Syncing` is our forward of
                                        // `UtxoProcStart`, which
                                        // `handle_connect_impl` fires on both
                                        // (`processor.rs:541`). Hanging the
                                        // retry on the one event that does not
                                        // arrive is how the original defect
                                        // would have survived its own fix.
                                        //
                                        // Detached: the fold loop owes the
                                        // glass its next frame, not a network
                                        // probe. A no-op once a pass has
                                        // succeeded, and a no-op while one is
                                        // in flight.
                                        tokio::spawn(retry_discovery_if_unproven());
                                    }
                                    let refresh_rows = matches!(event, WalletEvent::Activity(_));
                                    fold(&mut current, event);
                                    // Restart heal (2026-07-09 sitting): after a
                                    // restart wallet-core re-files old sends as
                                    // Pending (IDEAS:206) and no tracker EVENT
                                    // will fire for an already-settled watch —
                                    // so on every activity refresh, PULL the
                                    // tracker's answer for any Pending row the
                                    // overrides can't explain.
                                    if refresh_rows {
                                        if let Some(tracker) = tracker.as_ref() {
                                            for row in &current.activity {
                                                if row.maturity == MaturityState::Pending
                                                    && !overrides.contains_key(&row.txid)
                                                {
                                                    if let Some(status) = tracker.status(&row.txid) {
                                                        overrides.insert(row.txid.clone(), status);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    apply_overrides(&mut current, &overrides);
                                    // Counts only (INV-3). The V2 sitting saw
                                    // live sends recorded by the chain layer
                                    // yet missing on the glass — this line +
                                    // the receiver count convict which side
                                    // of the fan-out dropped them.
                                    if refresh_rows {
                                        log::info!(
                                            "wallet: activity fold rows={} receivers={}",
                                            current.activity.len(),
                                            fan_out.receiver_count()
                                        );
                                    }
                                    publish(&mut current, &fan_out);
                                }
                                // Lagged: values are absolute — skipping ahead is safe.
                                Err(RecvError::Lagged(_)) => continue,
                                Err(RecvError::Closed) => break,
                            }
                        }
                        acceptance = async {
                            // Guarded by `if` below — unwrap is unreachable otherwise.
                            acceptance_rx.as_mut().unwrap().recv().await
                        }, if acceptance_rx.is_some() => {
                            match acceptance {
                                Ok(event) => {
                                    let txid = match &event {
                                        AcceptanceEvent::Accepted { txid }
                                        | AcceptanceEvent::Confirmed { txid, .. }
                                        | AcceptanceEvent::Displaced { txid }
                                        | AcceptanceEvent::DisplacedElapsed { txid }
                                        | AcceptanceEvent::Stalled { txid, .. } => txid.clone(),
                                        // A transport-only signal about a tx
                                        // this lane never watched — it carries
                                        // no wallet status to re-read.
                                        AcceptanceEvent::SenderResolvable { .. } => continue,
                                    };
                                    // Re-read the tracker's CURRENT status (the
                                    // event is a change signal, not the state).
                                    match tracker.as_ref().and_then(|t| t.status(&txid)) {
                                        Some(status) => {
                                            overrides.insert(txid, status);
                                        }
                                        None => {
                                            overrides.remove(&txid);
                                        }
                                    }
                                    apply_overrides(&mut current, &overrides);
                                    publish(&mut current, &fan_out);
                                }
                                Err(RecvError::Lagged(_)) => continue,
                                Err(RecvError::Closed) => {
                                    acceptance_rx = None;
                                }
                            }
                        }
                    }
                }
            });
            Ok(sender)
        })
        .await
}

/// The latest folded snapshot as a PULL (V2 sitting: the founder's
/// swipe-to-refresh; also the stream-freeze diagnostic — a pull that shows a
/// row the stream missed convicts the delivery lane, not the fold). `None`
/// until the engine has folded anything.
pub fn wallet_snapshot_now() -> Option<WalletSnapshot> {
    latest_snapshot().map(|mut snapshot| {
        // Re-stamped, not served as recorded: the pull is the glass asking for
        // the truth NOW, and discovery may have proven out since the last fold.
        snapshot.discovery_incomplete = !discovery_proven();
        snapshot
    })
}

/// A Dart-side display-state marker routed through the ONE build-flavor-proof
/// log lane (L53 — profile builds drop Dart prints). Markers are OUR OWN
/// short state constants + counts, never content (INV-3); clamped defensively.
pub fn ui_mark(marker: String) {
    let m: String = marker.chars().take(64).collect();
    log::info!("glass: {m}");
}

/// Subscribe to live wallet snapshots (balance + activity) for the unlocked
/// vault's addresses. The first call starts the sync engine; later calls share
/// it. Errors if the vault is locked (the Dart side retries after unlock).
pub async fn subscribe_wallet_updates(sink: StreamSink<WalletSnapshot>) -> Result<(), AppError> {
    let sender = snapshots().await?;
    // Subscribe while holding LATEST: the fold task updates LATEST *before*
    // broadcasting (same lock), so everything on `receiver` is >= the snapshot
    // we deliver first — values never regress on (re)attach (mirrors dag.rs).
    let (mut receiver, latest) = {
        let guard = LATEST.lock().unwrap_or_else(PoisonError::into_inner);
        (sender.subscribe(), guard.clone())
    };
    if let Some(snapshot) = latest {
        let _ = sink.add(snapshot);
    }
    log::info!("wallet: snapshot subscriber attached");
    tokio::spawn(async move {
        loop {
            match receiver.recv().await {
                Ok(snapshot) => {
                    if sink.add(snapshot).is_err() {
                        // Dart listener gone (e.g. hot restart). Logged so a
                        // glass that stops updating is diagnosable from the
                        // liblog lane (V2 sitting: live send rows missing).
                        log::warn!("wallet: snapshot sink detached — forwarding stopped");
                        break;
                    }
                }
                Err(RecvError::Lagged(_)) => continue,
                Err(RecvError::Closed) => break,
            }
        }
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── the address window (the 2026-08-12 fund-visibility defect) ──────────
    //
    // The bug in one line: the change window was `max(GAP_LIMIT, change_cursor + 1)`,
    // and `change_cursor` counts sends THIS app broadcast. A wallet restored from
    // another client reads 0 there however deep its real history goes, so the
    // window stayed 30 while funds sat far past it — invisible, and because the
    // signer shares this seam, unspendable too.

    #[test]
    fn a_fresh_wallet_watches_exactly_the_gap_limit() {
        assert_eq!(window_from(0, 0, 0), (GAP_LIMIT, GAP_LIMIT));
    }

    #[test]
    fn a_funded_change_index_past_the_old_window_is_covered() {
        // The founder's wallet, 2026-08-12: Kaspium had advanced the change
        // branch to index 77 while our window was 30. This is the regression.
        // Discovery reports index 77, which persists as a count of 78.
        let (_, change) = window_from(0, 78, 0);
        assert!(
            change > 77,
            "change window {change} must cover the funded index 77"
        );
        assert_eq!(change, 78 + GAP_LIMIT);
    }

    #[test]
    fn index_zero_funded_is_distinguishable_from_nothing_found() {
        // The bug this pair pins: as a bare index, 0 means both "nothing" and
        // "index 0 has funds". As a count it cannot.
        assert_eq!(window_from(0, 0, 0).0, GAP_LIMIT, "nothing found");
        assert_eq!(window_from(1, 0, 0).0, 1 + GAP_LIMIT, "index 0 funded");
    }

    #[test]
    fn the_old_rule_is_what_this_replaces() {
        // Pin the defect so nobody reintroduces it: with a restored wallet the
        // send-counter is 0, and the superseded formula returned a 30-wide
        // window that cannot see index 77.
        let restored_wallet_cursor = 0u32; // never advanced — we broadcast nothing
        let superseded = GAP_LIMIT.max(restored_wallet_cursor.saturating_add(1));
        assert_eq!(superseded, GAP_LIMIT);
        assert!(superseded <= 77, "the old rule could not reach index 77");
    }

    #[test]
    fn both_branches_widen_independently() {
        let (receive, change) = window_from(46, 13, 0);
        assert_eq!(receive, 46 + GAP_LIMIT);
        assert_eq!(change, 13 + GAP_LIMIT);
        // Receive used to be hard-pinned at GAP_LIMIT with no widening path at
        // all — strictly worse than change. It grows now.
        assert!(receive > GAP_LIMIT);
    }

    #[test]
    fn the_send_cursor_still_floors_the_change_branch() {
        // D-041 must survive: a fresh change address is signable the moment the
        // cursor names it, even before any discovery pass has run.
        let (_, change) = window_from(0, 0, 200);
        assert_eq!(change, 201);
    }

    #[test]
    fn a_garbage_window_input_is_bounded_not_merely_saturated() {
        // This test used to assert `u32::MAX` in → `u32::MAX` out and call it
        // safe because it does not NARROW the watch set. Both directions are
        // fatal, and this was the one that shipped defended-as-correct: the
        // window is a derivation count, so `u32::MAX` is `Vec::with_capacity`
        // of ~137 GB plus that many BIP32 derivations under the VAULT mutex —
        // `handle_alloc_error`, SIGABRT, and a wallet that re-reads the same
        // eight bytes and aborts again on every launch.
        //
        // The live defence is at the reader (`vault::persisted_count` reads an
        // impossible count as UNSET); this is the backstop under it, and it is
        // the reason the backstop cannot itself be the index ceiling.
        let (receive, change) = window_from(u32::MAX, u32::MAX, u32::MAX);
        assert_eq!(receive, MAX_WINDOW);
        assert_eq!(change, MAX_WINDOW);
    }

    #[test]
    fn the_ceiling_never_bites_a_window_a_real_wallet_can_reach() {
        // The bound must be a corruption backstop, not a policy limit. The
        // reachable space is small and exactly known: a mark is at most what one
        // pass can produce, and a cursor is one per send.
        let (receive, change) = window_from(vault::MAX_SCAN_MARK, vault::MAX_SCAN_MARK, 0);
        assert_eq!(receive, vault::MAX_SCAN_MARK + GAP_LIMIT);
        assert_eq!(change, vault::MAX_SCAN_MARK + GAP_LIMIT);
        let (_, change_at_cursor_ceiling) = window_from(0, 0, vault::MAX_CHANGE_CURSOR);
        assert_eq!(change_at_cursor_ceiling, vault::MAX_CHANGE_CURSOR + 1);
        // An earlier version of this test asserted headroom at mark 5 000 and
        // called it "a window a real wallet can reach" — `MAX_DISCOVERY_DEPTH`,
        // added in the same commit, had already made 5 000 unreachable. A test
        // that blesses headroom the code no longer has is worse than no test.
        const { assert!(vault::MAX_SCAN_MARK >= DISCOVERY_DEPTH) };
    }

    #[test]
    fn discovery_probes_at_least_the_default_depth_and_always_past_what_it_found() {
        let auto = ScanReach::Automatic;
        assert_eq!(auto.depth_for(0), DISCOVERY_DEPTH);
        assert_eq!(auto.depth_for(78), DISCOVERY_DEPTH, "still within default");
        // Past the default depth the scan keeps growing rather than pinning
        // itself at the last scan's edge.
        assert_eq!(auto.depth_for(400), 400 + GAP_LIMIT);
        // …but a probe depth is round trips on the unlock path, so it stops at
        // its own ceiling rather than the window's. Sharing the window's made
        // one pass 782 sequential chunks — over two hours of a blocked gate,
        // from four corrupt bytes.
        assert_eq!(auto.depth_for(u32::MAX), MAX_DISCOVERY_DEPTH);
        assert!(auto.depth_for(MAX_DISCOVERY_DEPTH) <= MAX_DISCOVERY_DEPTH);
        // And a depth is never wider than a window can hold it.
        const { assert!(MAX_DISCOVERY_DEPTH < MAX_WINDOW) };
    }

    #[test]
    fn the_manual_reach_ignores_the_automatic_cap_and_never_shrinks_with_what_is_known() {
        let manual = ScanReach::Manual;
        // Flat, by design: a user who taps "scan for more addresses" is not
        // asking for `known + GAP`, they are asking us to look past what the
        // automatic rule can justify. So the answer never depends on `seen` —
        // including at the extremes, where a `min`/`max` pair written the
        // ordinary way would quietly reintroduce the automatic ceiling.
        for seen in [0, 78, MAX_DISCOVERY_DEPTH, MANUAL_DISCOVERY_DEPTH, u32::MAX] {
            assert_eq!(manual.depth_for(seen), MANUAL_DISCOVERY_DEPTH);
        }
        // The manual reach is strictly the deeper of the two — the property the
        // whole control exists for.
        assert!(manual.depth_for(0) > ScanReach::Automatic.depth_for(u32::MAX));
    }

    #[test]
    fn a_mark_from_the_deepest_manual_scan_is_a_value_the_reader_still_believes() {
        // THE landmine, asserted at the exact boundary the compile asserts
        // cannot reach: `persisted_count` reads anything above `MAX_SCAN_MARK`
        // as UNSET, so a manual scan that finds funds deep writes a mark that
        // reads back as 0 — the scan reports success, the marks vanish, and the
        // wallet reopens on the gap limit.
        //
        // The const asserts pin the two ceilings to each other. What they cannot
        // express is the CONSEQUENCE: that a mark this pass can actually produce
        // still derives a wide window rather than collapsing to `GAP_LIMIT`.
        let deepest_mark = MANUAL_DISCOVERY_DEPTH; // highest_funded_index + 1
        let (receive, change) = window_from(deepest_mark, deepest_mark, 0);
        assert_eq!(receive, deepest_mark + GAP_LIMIT);
        assert_eq!(change, deepest_mark + GAP_LIMIT);
        assert_ne!(
            receive, GAP_LIMIT,
            "a collapsed window is the defect itself"
        );
    }

    #[test]
    fn the_change_index_is_floored_at_what_discovery_found() {
        // C3 / D-041: `change.cursor` counts OUR broadcasts, so a restored
        // wallet reads 0 and would hand out change/0 — an index its external
        // history already spent from, linking the new tx to that history and
        // defeating the fresh-per-send property outright. The pure rule, with
        // the disk reads factored out:
        let floor = |cursor: u32, change_seen: u32| cursor.max(change_seen);
        assert_eq!(floor(0, 78), 78, "restored wallet: discovery wins");
        assert_eq!(
            floor(120, 78),
            120,
            "our own sends went deeper: cursor wins"
        );
        assert_eq!(floor(0, 0), 0, "a genuinely fresh wallet still starts at 0");
    }

    // ── the retry (the BLOCK: discovery vs a socket that is not up yet) ─────

    /// What the pin returns from a call made while the socket is still dialling
    /// (`workflow-rpc client/mod.rs:479-480`) — immediately, in milliseconds.
    fn not_connected() -> kaspaverse_chain::ChainError {
        kaspaverse_chain::ChainError::Message(
            "address discovery probe failed: WebSocket not connected".into(),
        )
    }

    /// Run `body` against a real unlocked vault in a fresh temp dir (shared
    /// harness — takes the same serializer the vault's own global-state tests
    /// use), so discovery derives real addresses and persists real marks.
    ///
    /// A plain `#[test]` + `block_on` rather than `#[tokio::test]`: that
    /// serializer is a std `Mutex`, and holding its guard across the awaits of
    /// an async test body is precisely the `await_holding_lock` shape this
    /// codebase refuses everywhere else. From sync code the guard never crosses
    /// an await.
    fn with_unlocked_vault<F>(body: impl FnOnce() -> F)
    where
        F: std::future::Future<Output = ()>,
    {
        let (_guard, _dir) = vault::tests::enter();
        vault::tests::seal_test_vault(b"discovery-test".to_vec(), vault::tests::cheap_params());
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("test runtime")
            .block_on(body());
    }

    #[test]
    fn a_probe_that_fails_before_the_socket_is_up_still_widens_on_the_retry() {
        with_unlocked_vault(|| async {
            let mut gate = Discovery {
                attempted: false,
                succeeded: false,
            };

            // Cold unlock. `start()` only INITIATES the connect, so the first probe
            // dies in milliseconds against a socket that is still dialling. The old
            // shape ended here: one `log::warn!`, a resolved OnceCell, and the
            // narrow window for the rest of the process — the original bug, silent.
            let first = persist_from_probe(ScanReach::Automatic, |_, _| async {
                (Err(not_connected()), Err(not_connected()))
            })
            .await;
            record_pass(&mut gate, &first);
            assert!(first.is_err());
            assert!(
                gate.attempted,
                "the gate must open anyway — an offline wallet still has to open"
            );
            assert!(
                !gate.succeeded,
                "but nothing was proven, so the retry must still be armed"
            );
            assert_eq!(
                wallet_window(),
                (GAP_LIMIT, GAP_LIMIT),
                "a failed probe leaves the last known-good window, never a narrower one"
            );

            // `WalletEvent::Connected` arrives. Because the pass never succeeded,
            // the retry runs — and this time the node answers: change index 77.
            let second = persist_from_probe(ScanReach::Automatic, |_, _| async {
                (Ok(None), Ok(Some(77)))
            })
            .await;
            record_pass(&mut gate, &second);
            assert_eq!(second.unwrap(), (0, 78), "marks persist as counts");
            assert!(gate.succeeded, "a complete pass disarms the retry");
            let (_, change) = wallet_window();
            assert_eq!(change, 78 + GAP_LIMIT);
            assert!(
                change > 77,
                "the funded index is inside the window that is watched AND signed"
            );
        });
    }

    #[test]
    fn an_automatic_pass_over_a_deep_manual_mark_re_verifies_without_narrowing() {
        with_unlocked_vault(|| async {
            // The state a manual scan leaves behind: a mark PAST what any
            // automatic pass will ever probe. The two ceilings used to be equal,
            // so this state was unreachable and the code silently assumed it
            // could not happen — `persist_from_probe` asserted `depth >= known`.
            // Raising `MAX_SCAN_MARK` for the deep scan makes it reachable, and
            // the very next launch runs an automatic pass over it.
            let deep = MAX_DISCOVERY_DEPTH + 1;
            vault::set_scan_high_water(deep, deep).unwrap();
            let proven = wallet_window();
            assert_eq!(proven, (deep + GAP_LIMIT, deep + GAP_LIMIT));

            // The automatic pass now probes shallower than the mark — by design,
            // since its depth is round trips on the unlock path. It sees nothing
            // out there (the shallow addresses are empty) and must leave the deep
            // mark completely alone.
            let shallow = persist_from_probe(ScanReach::Automatic, |receive, change| async move {
                assert_eq!(receive.len() as u32, MAX_DISCOVERY_DEPTH);
                assert_eq!(change.len() as u32, MAX_DISCOVERY_DEPTH);
                (Ok(None), Ok(None))
            })
            .await;

            assert_eq!(shallow.unwrap(), (deep, deep), "the deep mark stands");
            assert_eq!(
                wallet_window(),
                proven,
                "a shallow re-verification narrowed a window a deep scan had proven"
            );
        });
    }

    #[test]
    fn the_widening_report_is_the_delta_and_never_gates_the_republish() {
        // `republish_window` returns whether the window grew, but must TELL the
        // consumers either way. The delta is measured against the caller's marks,
        // not against what the engine actually watches, and those disagree
        // whenever a previous republish leaked (a lock mid-derive, a timed-out
        // `extend_watch`). Gated on the delta, that leak is invisible forever:
        // every later pass reads it as `before` and does nothing.
        //
        // Asserted on the CALL COUNT, not on the return value. Both consumers are
        // unobservable no-ops in a test process — no engine, no transport hub —
        // so a test that checked only the `bool` would pass with the early return
        // put straight back (consensus-auditor, Track 2 re-audit).
        with_unlocked_vault(|| async {
            let before = wallet_window();
            let calls = REPUBLISH_CALLS.load(Ordering::Relaxed);
            assert!(
                !republish_window(before).await,
                "an unchanged window reports false…"
            );
            assert_eq!(
                REPUBLISH_CALLS.load(Ordering::Relaxed),
                calls + 1,
                "…and still tells the consumers"
            );
            vault::set_scan_high_water(0, 78).unwrap();
            assert!(republish_window(before).await, "a grown one reports true");
        });
    }

    #[test]
    fn a_manual_scan_that_fails_still_publishes_the_widening_it_persisted() {
        // The BLOCK, asserted through the seam `deep_scan` actually uses.
        //
        // The first attempt at this test drove `persist_from_probe` directly and
        // proved only the PREMISE — that an `Err` arrives with the marks already
        // grown. Reverting `deep_scan` to `run_discovery_pass(...).await?` left
        // it green. A regression guard that cannot fail on its own defect is the
        // L86 shape: a passing test certifying the wrong end of the axis.
        with_unlocked_vault(|| async {
            let before = wallet_window();
            let calls = REPUBLISH_CALLS.load(Ordering::Relaxed);

            // A pass that widened the receive branch and then failed on change —
            // the ordinary partial outcome on a flaky link, not a corner case.
            let outcome = finish_scan(before, async {
                let out = persist_from_probe(ScanReach::Manual, |_, _| async {
                    (Ok(Some(900)), Err(not_connected()))
                })
                .await;
                assert!(out.is_err(), "the pass failed…");
                assert_ne!(wallet_window(), before, "…having already widened");
                out
            })
            .await;

            assert!(outcome.is_err(), "the error still reaches the caller");
            assert_eq!(
                REPUBLISH_CALLS.load(Ordering::Relaxed),
                calls + 1,
                "the widening was persisted and never published — signer wide, \
                 watch narrow, and the next scan reports 'nothing new found'"
            );
        });
    }

    #[test]
    fn a_failure_after_a_success_can_never_narrow_the_window() {
        with_unlocked_vault(|| async {
            let mut gate = Discovery {
                attempted: false,
                succeeded: false,
            };

            let good = persist_from_probe(ScanReach::Automatic, |_, _| async {
                (Ok(Some(12)), Ok(Some(77)))
            })
            .await;
            record_pass(&mut gate, &good);
            let proven = wallet_window();
            assert_eq!(proven, (13 + GAP_LIMIT, 78 + GAP_LIMIT));

            // The socket drops. A pass that finds nothing — or cannot ask — must
            // never shrink a window that already found funds, or a flaky connection
            // would strand coins we had learned to watch.
            let bad = persist_from_probe(ScanReach::Automatic, |_, _| async {
                (Err(not_connected()), Ok(None))
            })
            .await;
            record_pass(&mut gate, &bad);
            assert!(bad.is_err());
            assert!(gate.succeeded, "the earlier proof stands");
            assert_eq!(wallet_window(), proven);
        });
    }

    #[test]
    fn one_branch_answering_is_kept_even_when_the_other_fails() {
        // A half-answer can only ever WIDEN (the marks are monotonic), so
        // throwing it away just means paying to probe for it again. The pass
        // still reports incomplete, so the retry stays armed.
        with_unlocked_vault(|| async {
            let mut gate = Discovery {
                attempted: false,
                succeeded: false,
            };

            let half = persist_from_probe(ScanReach::Automatic, |_, _| async {
                (Ok(Some(40)), Err(not_connected()))
            })
            .await;
            record_pass(&mut gate, &half);
            assert!(
                half.is_err(),
                "incomplete: the change branch never answered"
            );
            assert!(!gate.succeeded, "so the retry is still armed");
            let (receive, change) = wallet_window();
            assert_eq!(
                receive,
                41 + GAP_LIMIT,
                "the receive branch's answer is kept"
            );
            assert_eq!(change, GAP_LIMIT, "the change branch learned nothing");
        });
    }

    #[test]
    fn the_signable_window_always_covers_the_change_index_it_hands_out() {
        // The invariant that makes C3 safe to apply: whatever index the send
        // path takes, the signer's window must already reach it, or the fix
        // would create the very "visible but unspendable" state this track
        // exists to kill. Both sides read the same two numbers.
        //
        // The last four pairs are the ones the first version of this test
        // missed: five hand-picked values, none near the ceiling the clamp had
        // just introduced. `MAX_SCAN_MARK` is exactly what a CORRUPT
        // `change.cursor` or `scan.window` reads back as once clamped, and at
        // that value a window also clamped to `MAX_SCAN_MARK` covers
        // `0..=MAX_SCAN_MARK-1` — one short of the index it hands out. The send
        // would have succeeded and returned change to an address that is
        // neither watched nor signable, on every send thereafter.
        for (cursor, change_seen) in [
            (0u32, 0u32),
            (0, 78),
            (120, 78),
            (78, 120),
            (5, 3),
            (vault::MAX_SCAN_MARK, 0),
            (0, vault::MAX_SCAN_MARK),
            (vault::MAX_SCAN_MARK, vault::MAX_SCAN_MARK),
            (vault::MAX_SCAN_MARK - 1, vault::MAX_SCAN_MARK),
        ] {
            let index = cursor.max(change_seen);
            let (_, window) = window_from(0, change_seen, cursor);
            assert!(
                window > index,
                "change window {window} must cover the index {index} it hands out"
            );
        }
    }

    fn row(daa: u64) -> WalletActivityRecord {
        WalletActivityRecord {
            txid: "a".repeat(64),
            value_sompi: 1_000,
            unixtime_msec: Some(1),
            block_daa_score: daa,
            accepted_daa_score: None,
            direction: ChainDirection::Incoming,
            is_coinbase: false,
            maturity: ChainMaturity::Pending,
            counterparty_address: None,
            fee_sompi: None,
        }
    }

    #[test]
    fn empty_wallet_balance_is_a_live_zero_not_unknown() {
        let mut snapshot = WalletSnapshot::default();
        assert_eq!(snapshot.mature_sompi, None, "starts unknown");
        fold(&mut snapshot, WalletEvent::Syncing);
        assert!(snapshot.syncing);

        fold(
            &mut snapshot,
            WalletEvent::Balance {
                mature: 0,
                pending: 0,
                outgoing: 0,
            },
        );
        // The critical bar: a synced empty wallet is Some(0) (live zero), not
        // None (unknown), and no longer syncing.
        assert_eq!(snapshot.mature_sompi, Some(0));
        assert_eq!(snapshot.pending_sompi, Some(0));
        assert!(!snapshot.syncing);
    }

    #[test]
    fn folds_balance_and_retains_it_across_disconnect() {
        let mut snapshot = WalletSnapshot::default();
        fold(&mut snapshot, WalletEvent::Connected { url: None });
        fold(
            &mut snapshot,
            WalletEvent::Balance {
                mature: 12_300_000_000,
                pending: 5_000_000,
                outgoing: 0,
            },
        );
        assert!(snapshot.connected);
        assert_eq!(snapshot.mature_sompi, Some(12_300_000_000));
        assert_eq!(snapshot.pending_sompi, Some(5_000_000));

        // A dropped link clears `connected` but keeps last-known balance (DS-1
        // dims it with its age; never blanks to unknown).
        fold(&mut snapshot, WalletEvent::Disconnected);
        assert!(!snapshot.connected);
        assert_eq!(snapshot.mature_sompi, Some(12_300_000_000));
    }

    #[test]
    fn utxo_index_missing_sets_then_clears_on_a_real_balance() {
        let mut snapshot = WalletSnapshot::default();
        fold(&mut snapshot, WalletEvent::UtxoIndexMissing { url: None });
        assert!(
            snapshot.utxo_index_missing,
            "honest degrade flag set (INV-8)"
        );

        // Resolver rotates to an indexed node → a balance arrives → flag clears.
        fold(
            &mut snapshot,
            WalletEvent::Balance {
                mature: 1,
                pending: 0,
                outgoing: 0,
            },
        );
        assert!(!snapshot.utxo_index_missing);
    }

    /// The V1 overlay law: tracker truth upgrades Pending the instant the
    /// chain answers, never downgrades wallet-core Confirmed (except a real
    /// displacement, which must read Pending again — honesty over comfort).
    #[test]
    fn acceptance_overlay_upgrades_never_downgrades_except_displacement() {
        use MaturityState::*;
        // Accepted upgrades Pending, leaves Confirmed alone.
        assert_eq!(
            overlaid(
                Pending,
                &TxStatus::Accepted {
                    blue_depth: 3,
                    accepted_unix_ms: 0
                }
            ),
            Accepted
        );
        assert_eq!(
            overlaid(
                Confirmed,
                &TxStatus::Accepted {
                    blue_depth: 3,
                    accepted_unix_ms: 0
                }
            ),
            Confirmed
        );
        // Tracker-confirmed (blue-score depth, node-read) confirms.
        assert_eq!(
            overlaid(
                Pending,
                &TxStatus::Confirmed {
                    blue_depth: 120,
                    accepted_unix_ms: 0
                }
            ),
            Confirmed
        );
        // Displacement drops ANY state to Pending.
        assert_eq!(overlaid(Confirmed, &TxStatus::Displaced), Pending);
        assert_eq!(overlaid(Accepted, &TxStatus::Displaced), Pending);
        // Submitted/Stalled change nothing at this surface.
        assert_eq!(overlaid(Pending, &TxStatus::Submitted), Pending);
        assert_eq!(
            overlaid(Confirmed, &TxStatus::Stalled { waited_ms: 90_000 }),
            Confirmed
        );
    }

    #[test]
    fn overrides_apply_to_matching_rows_and_survive_activity_refolds() {
        let mut snapshot = WalletSnapshot::default();
        fold(&mut snapshot, WalletEvent::Activity(vec![row(100)]));
        let txid = snapshot.activity[0].txid.clone();
        assert_eq!(snapshot.activity[0].maturity, MaturityState::Pending);

        let mut overrides = HashMap::new();
        overrides.insert(
            txid,
            TxStatus::Accepted {
                blue_depth: 1,
                accepted_unix_ms: 0,
            },
        );
        apply_overrides(&mut snapshot, &overrides);
        assert_eq!(snapshot.activity[0].maturity, MaturityState::Accepted);

        // A fresh Activity fold resets rows from wallet-core — re-applying
        // the overrides (as the task does after every fold) restores truth.
        let mut unwatched = row(50);
        unwatched.txid = "b".repeat(64);
        fold(
            &mut snapshot,
            WalletEvent::Activity(vec![row(100), unwatched]),
        );
        assert_eq!(snapshot.activity[0].maturity, MaturityState::Pending);
        apply_overrides(&mut snapshot, &overrides);
        assert_eq!(snapshot.activity[0].maturity, MaturityState::Accepted);
        assert_eq!(
            snapshot.activity[1].maturity,
            MaturityState::Pending,
            "unwatched rows untouched"
        );
    }

    #[test]
    fn folds_activity_and_maps_fields() {
        let mut snapshot = WalletSnapshot::default();
        fold(
            &mut snapshot,
            WalletEvent::Activity(vec![row(100), row(50)]),
        );
        assert_eq!(snapshot.activity.len(), 2);
        let first = &snapshot.activity[0];
        assert_eq!(first.direction, ActivityDirection::Incoming);
        assert_eq!(first.maturity, MaturityState::Pending);
        assert_eq!(first.value_sompi, 1_000);
        assert_eq!(first.txid.len(), 64);
        assert!(!first.is_coinbase);
    }
}
