//! **Every panic in the process, recorded as shape** (PRE3-LANE, run 4's E1).
//!
//! A panic inside a task the pinned crates spawn is invisible to us: the pin
//! spawns with a bare `tokio::spawn` (workflow-core 0.18.0 `task.rs:37-43`)
//! and keeps no `JoinHandle` we could ask `JoinError::is_panic`, so the task
//! simply stops. F1 was exactly that — the `UtxoProcessor` loop panicked at
//! `processor.rs:394`, emitted no event, and the balance kept its last value at
//! full brightness until the app was killed.
//!
//! So the process installs ONE chained `std::panic::set_hook`
//! ([`install_panic_hook`]) that records each panic's **location, thread and
//! time**, wakes whoever is watching ([`panicked`]), and then calls the hook it
//! replaced (FRB's backtrace capture, then std's printer). The wallet lane's
//! supervisor (`wallet_sync.rs`) reads it: any panic is a reason to look at the
//! lane's own witnesses at once — its processor's ctl listener, its fold task —
//! and never a verdict by itself, because the wallet framework's code also runs
//! on tasks that are not the lane's (a send's submit, for one; `consensus-
//! auditor`, PRE3-LANE). The location, classed as in or out of the pinned
//! wallet framework, is shape for the log.
//!
//! **The payload never leaves this hook** (INV-1/2/3; PB-024). It is never read
//! here: not into a record, not into a log line, not into an `AppError`, not
//! onto the glass. The hooks chained after it are another matter: std's printer
//! at the end of the chain still writes the payload to stderr, as it did before
//! this hook existed, and on Android stderr reaches no log (`logging.rs` routes
//! only `android_logger` to logcat). A panic message is foreign text that can carry anything the
//! panicking code formatted. What is kept is shape only: a source path trimmed
//! to its crate-relative part (a compile-time constant, never user data), a
//! line number, a thread name and a clock.
//!
//! Prior art: Erlang/OTP's "let it crash" (a failure is recorded and the
//! supervisor restarts from a known state; the crash report names where, never
//! the process's private state), and the chaining discipline of
//! `std::panic::take_hook` (every hook that replaces another calls it).

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, Once};

/// How many recent panics the registry keeps for diagnostics.
const RECENT_KEPT: usize = 16;
/// Bounds on what a record keeps, so a hook never builds an unbounded string.
const LOCATION_CHARS: usize = 160;
const THREAD_CHARS: usize = 48;

/// One recorded panic, as shape.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PanicShape {
    /// 1, 2, 3 … in the order the hook saw them.
    pub seq: u64,
    /// `crate-relative/path.rs:LINE`, or `<unknown>`.
    pub location: String,
    /// Whether the location is inside the pinned wallet framework
    /// (`kaspa-wallet-core`) — see [`is_wallet_core`].
    pub wallet_core: bool,
    /// The panicking thread's name, or `<unnamed>`.
    pub thread: String,
    /// Wall clock at the hook, unix milliseconds.
    pub at_unix_ms: u64,
}

static SEQ: AtomicU64 = AtomicU64::new(0);
static RECENT: Mutex<VecDeque<PanicShape>> = Mutex::new(VecDeque::new());
static PANICKED: tokio::sync::Notify = tokio::sync::Notify::const_new();
static INSTALL: Once = Once::new();

/// Install the chained hook, once per process. Later calls are no-ops, so the
/// bridge's init can run twice (a hot restart) and a test can call it freely.
/// Install it AFTER anything else that sets a hook: the last one installed runs
/// first, and ours chains whatever was there.
///
/// [`record`] must not panic: std aborts the process on a panic raised while a
/// hook runs ("panicked while processing panic"), so nothing in it unwraps, and
/// its one lock is taken with `try_lock`. One exception it cannot avoid:
/// `std::thread::current()` panics once a thread's locals are torn down, so a
/// panic raised during that teardown aborts inside this hook — where std aborts
/// anyway, with only the chained hooks' messages lost (`ffi-leak-auditor`).
pub fn install_panic_hook() {
    INSTALL.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            record(info.location().map(|at| (at.file(), at.line())));
            previous(info);
        }));
    });
}

/// Record one panic. Separate from the hook so a test can drive it without
/// panicking. Never blocks: the ring is taken with `try_lock`, because a hook
/// runs on the panicking thread, which may already hold anything.
pub(crate) fn record(location: Option<(&str, u32)>) -> PanicShape {
    let seq = SEQ.fetch_add(1, Ordering::SeqCst) + 1;
    let wallet_core = location.is_some_and(|(file, _)| is_wallet_core(file));
    let location = location.map_or_else(
        || "<unknown>".to_string(),
        |(file, line)| {
            let mut at = format!("{}:{line}", trim_path(file));
            at.truncate(
                at.char_indices()
                    .nth(LOCATION_CHARS)
                    .map_or(at.len(), |(i, _)| i),
            );
            at
        },
    );
    let thread: String = std::thread::current()
        .name()
        .unwrap_or("<unnamed>")
        .chars()
        .take(THREAD_CHARS)
        .collect();
    let at_unix_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX));
    let shape = PanicShape {
        seq,
        location,
        wallet_core,
        thread,
        at_unix_ms,
    };
    if let Ok(mut recent) = RECENT.try_lock() {
        if recent.len() >= RECENT_KEPT {
            recent.pop_front();
        }
        recent.push_back(shape.clone());
    }
    // Shape only (INV-3): the payload is never read, so it cannot be logged.
    log::error!(
        "lane-health: panic #{seq} at {} on thread {} — payload withheld{}",
        shape.location,
        shape.thread,
        if wallet_core {
            " (in the pinned wallet framework)"
        } else {
            ""
        }
    );
    PANICKED.notify_waiters();
    shape
}

/// How many panics the process has seen.
pub fn panics_seen() -> u64 {
    SEQ.load(Ordering::SeqCst)
}

/// The newest panic recorded after `seq`, if the registry still holds it — the
/// supervisor names it beside a death it witnessed, as context. It is never
/// the verdict: a panic convicts a lane only through the lane's own witnesses
/// (`wallet_sync.rs`, `consensus-auditor` PRE3-LANE), because the wallet
/// framework's code runs on other tasks too.
pub(crate) fn panic_after(seq: u64) -> Option<PanicShape> {
    if SEQ.load(Ordering::SeqCst) <= seq {
        return None;
    }
    RECENT
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter()
        .rev()
        .find(|shape| shape.seq > seq)
        .cloned()
}

/// The most recent panics, oldest first — diagnostics and tests.
pub fn recent_panics() -> Vec<PanicShape> {
    RECENT
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter()
        .cloned()
        .collect()
}

/// Resolves on the next recorded panic. Create it BEFORE reading
/// [`panics_seen`], so a panic between the read and the await is not lost.
pub(crate) fn panicked() -> tokio::sync::futures::Notified<'static> {
    PANICKED.notified()
}

/// Is `file` inside the pinned wallet framework? Both source layouts cargo
/// uses: a git checkout (`…/<rev>/wallet/core/src/…`, today's pin) and a
/// registry crate directory (`…/kaspa-wallet-core-<version>/src/…`, the layout
/// the pin moves to when it comes from crates.io, D-348).
pub(crate) fn is_wallet_core(file: &str) -> bool {
    let file = file.replace('\\', "/");
    file.contains("wallet/core/src/") || file.contains("kaspa-wallet-core-")
}

/// The crate-relative part of a compile-time source path: never the build
/// machine's home directory, which a git or registry path would otherwise
/// carry into the log.
fn trim_path(file: &str) -> String {
    let file = file.replace('\\', "/");
    for marker in [".cargo/git/checkouts/", ".cargo/registry/src/"] {
        if let Some(at) = file.find(marker) {
            // checkouts/<repo-hash>/<rev>/<path> · src/<index>/<crate-version>/<path>
            let rest = &file[at + marker.len()..];
            let skip = if marker.contains("git") { 2 } else { 1 };
            return rest
                .splitn(skip + 1, '/')
                .nth(skip)
                .unwrap_or(rest)
                .to_string();
        }
    }
    if file.starts_with('/') {
        // An absolute path we do not recognise: its last three parts.
        let parts: Vec<&str> = file.rsplitn(4, '/').collect();
        return parts[..parts.len().min(3)]
            .iter()
            .rev()
            .copied()
            .collect::<Vec<_>>()
            .join("/");
    }
    file
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_wallet_framework_is_recognised_in_both_layouts() {
        assert!(is_wallet_core(
            "/home/u/.cargo/git/checkouts/rusty-kaspa-410e06d1fde91a92/01b532e/wallet/core/src/utxo/processor.rs"
        ));
        assert!(is_wallet_core(
            "/home/u/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/kaspa-wallet-core-2.1.0/src/utxo/processor.rs"
        ));
        assert!(!is_wallet_core("chain/src/wallet_sync.rs"));
        assert!(!is_wallet_core(
            "/home/u/.cargo/git/checkouts/rusty-kaspa-410e06d1fde91a92/01b532e/rpc/core/src/api/ctl.rs"
        ));
    }

    #[test]
    fn a_location_never_carries_the_build_machines_home() {
        assert_eq!(
            trim_path(
                "/home/user/.cargo/git/checkouts/rusty-kaspa-410e06d1fde91a92/01b532e/wallet/core/src/utxo/processor.rs"
            ),
            "wallet/core/src/utxo/processor.rs"
        );
        assert_eq!(
            trim_path(
                "/home/user/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/tokio-1.52.3/src/runtime/task/harness.rs"
            ),
            "tokio-1.52.3/src/runtime/task/harness.rs"
        );
        assert_eq!(
            trim_path("chain/src/wallet_sync.rs"),
            "chain/src/wallet_sync.rs"
        );
        assert_eq!(trim_path("/opt/build/x/y/z.rs"), "x/y/z.rs");
    }

    /// The hook records shape and chains the hook it replaced: a caught panic
    /// lands in the registry with its location, and the previous hook still
    /// runs (std's printer, here).
    #[test]
    fn a_panic_is_recorded_as_shape_and_the_previous_hook_still_runs() {
        install_panic_hook();
        let before = panics_seen();
        let caught = std::panic::catch_unwind(|| {
            panic!("a payload that must never be stored");
        });
        assert!(caught.is_err());
        assert!(panics_seen() > before, "the hook recorded nothing");
        let newest = recent_panics()
            .into_iter()
            .rev()
            .find(|shape| shape.location.contains("lane_health.rs"))
            .expect("this panic is in the registry");
        assert!(!newest.wallet_core);
        let stored = format!("{newest:?}");
        assert!(
            !stored.contains("must never be stored"),
            "the payload leaked into the record: {stored}"
        );
    }
}
