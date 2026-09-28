//! `log`-facade sink installation (repays L40 — twice).
//!
//! History: no sink was ever installed for the `log` facade, so every
//! `log::info!` in chain/bridge was a silent no-op on device (L40). The
//! first repayment forwarded into the pinned crates' `workflow-log`, which
//! provably reached logcat — on DEBUG builds. The V1 sitting (2026-07-09)
//! proved profile builds drop that lane too, and Flutter's Dart print lane
//! with it, so on Android the facade now sinks straight into liblog via
//! `android_logger` (the fallback the D-073 findings register pre-sanctioned
//! — item 6): logcat visibility on EVERY build flavor, tag `kaspaverse`.
//! Host builds (tests, tools) keep the workflow-log forwarder.
//!
//! INV-3 note: these are sinks, not data sources — the no-secrets-in-log-
//! lines discipline lives at the call sites, which log public chain data
//! only (audited per phase; the V1 wallet-security audit enumerated every
//! line the `log` facade carries). The `pinned` target is a second lane, of
//! THIRD-PARTY lines: CONN-F1's wallet-security audit (2026-09-26) enumerated
//! what it can carry at rusty-kaspa 01b532e / workflow-* 0.18.0 / tungstenite
//! 0.23.0, and because that answer moves with the pin, `pin-bump-ritual`
//! re-enumerates it at every bump.

// Braced (not a unit struct) so FRB's whole-crate type scan doesn't emit a
// skip-warning for it — same layout, zero cost.
#[cfg(not(target_os = "android"))]
struct WorkflowLogForwarder {}

#[cfg(not(target_os = "android"))]
impl log::Log for WorkflowLogForwarder {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::Level::Info
    }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let line = format!("{}: {}", record.target(), record.args());
        match record.level() {
            log::Level::Error => workflow_log::log_error!("{line}"),
            log::Level::Warn => workflow_log::log_warn!("{line}"),
            _ => workflow_log::log_info!("{line}"),
        }
    }

    fn flush(&self) {}
}

#[cfg(not(target_os = "android"))]
static LOG_FORWARDER: WorkflowLogForwarder = WorkflowLogForwarder {};

/// **Why a socket died, in the pinned client's own words** (CONN-F1, §11).
///
/// The pinned websocket dispatcher already names the end of every socket —
/// `WebSocket error: {e}` on a read error, `WebSocket connection closed` on a
/// clean close, `WebSocket dispatcher error: {e}` on a failed write — and so
/// does the wRPC layer above it. But it says so at `workflow_log` trace, and
/// workflow-log's native lane is `println!`, which Android discards: a
/// `ctl-drop` has only ever reached our tag as a bare fact, so a node closing
/// us, a path resetting us and a radio timing us out all read the same.
///
/// This sink lifts exactly those two families and drops everything else it
/// sees. The filter renders at most [`HEAD`] bytes of a line before deciding,
/// so our writer never renders a trace line from any other pinned module past
/// its head (a `Display` that built its own `String` first would still render
/// in full; none on the native path does); the families it passes carry node URLs and transport error text —
/// public facts, never key or payload material (INV-3) — sanitised and
/// rate-capped, because a node can shape both.
#[cfg(target_os = "android")]
struct PinnedCloseSink {
    /// Paced by our own dial loop.
    socket: RateGate,
    /// Paced by the node — one line per bad frame it sends — so it gets its
    /// own budget and a flood cannot push out the close reason itself.
    rpc: RateGate,
}

/// At most this many pinned lines reach the tag per [`PINNED_WINDOW_SECS`];
/// the rest are counted and the count is said once, with the next line that
/// passes in a later window. A node sets the rate of `wRPC error` lines (one
/// per bad frame it sends), and a flood would evict the very capture this
/// lane exists to feed (L65).
#[cfg(any(target_os = "android", test))]
const PINNED_LINES_PER_WINDOW: u32 = 30;
#[cfg(any(target_os = "android", test))]
const PINNED_WINDOW_SECS: u64 = 60;

/// The cap, kept pure so it is tested against a clock the test holds.
/// Relaxed atomics: two threads racing a window roll can miscount a line,
/// never block one — a log cap does not need to be exact.
#[cfg(any(target_os = "android", test))]
struct RateGate {
    window: std::sync::atomic::AtomicU64,
    passed: std::sync::atomic::AtomicU32,
    suppressed: std::sync::atomic::AtomicU32,
}

#[cfg(any(target_os = "android", test))]
#[derive(Debug, PartialEq, Eq)]
enum Admit {
    /// Log it — and first say how many the last window swallowed, if any.
    Pass {
        suppressed_before: u32,
    },
    Drop,
}

#[cfg(any(target_os = "android", test))]
impl RateGate {
    const fn new() -> Self {
        Self {
            window: std::sync::atomic::AtomicU64::new(0),
            passed: std::sync::atomic::AtomicU32::new(0),
            suppressed: std::sync::atomic::AtomicU32::new(0),
        }
    }

    fn admit(&self, now_unix: u64) -> Admit {
        use std::sync::atomic::Ordering::Relaxed;
        let window = now_unix / PINNED_WINDOW_SECS;
        let mut suppressed_before = 0;
        if self.window.swap(window, Relaxed) != window {
            self.passed.store(0, Relaxed);
            suppressed_before = self.suppressed.swap(0, Relaxed);
        }
        if self.passed.fetch_add(1, Relaxed) < PINNED_LINES_PER_WINDOW {
            Admit::Pass { suppressed_before }
        } else {
            self.suppressed.fetch_add(1, Relaxed);
            Admit::Drop
        }
    }
}

#[cfg(any(target_os = "android", test))]
const HEAD: usize = 16;

/// The first [`HEAD`] bytes of a formatted line. Refusing the write past
/// that is what stops `fmt::write` from rendering the rest.
#[cfg(any(target_os = "android", test))]
struct Head {
    buf: [u8; HEAD],
    len: usize,
}

#[cfg(any(target_os = "android", test))]
impl std::fmt::Write for Head {
    fn write_str(&mut self, s: &str) -> std::fmt::Result {
        let take = s.len().min(HEAD - self.len);
        self.buf[self.len..self.len + take].copy_from_slice(&s.as_bytes()[..take]);
        self.len += take;
        if self.len == HEAD {
            Err(std::fmt::Error)
        } else {
            Ok(())
        }
    }
}

/// The exact heads the sink passes — every close reason the pinned client
/// can state, enumerated at the pin (wallet-security, CONN-F1). A head the
/// pin grows later fails CLOSED: a new third-party trace line reaches liblog
/// only after someone has read what it carries.
///
/// What they admit at the pin, by call site (ffi-leak, CONN-F1): workflow-
/// websocket's `WebSocket error: {e}`, `… connection closed`, `… connection
/// timeout while connecting to {url}`, `… dispatcher error: {e}`, `… failed
/// to connect to {url}: {e}` and `… failed to get session URL: {e}`;
/// workflow-rpc's ``wRPC error: `{err}` ``; and any wallet-core
/// `log_error!("{err}")` whose error text happens to open with one of these.
/// All transport error text, URLs or node text — the `{e}` text is shaped by
/// tungstenite and, beneath it, the vendored tokio-tungstenite dialer and
/// rustls/webpki (certificate text, never secret material) — sanitised and
/// capped. A new
/// call site behind an OLD head is not failed closed by this list; that is
/// what `tests::the_enumeration_is_bound_to_the_versions_it_read` is for.
#[cfg(any(target_os = "android", test))]
const SOCKET_HEADS: [&[u8]; 4] = [
    b"WebSocket error:",
    b"WebSocket connec",
    b"WebSocket dispat",
    b"WebSocket failed",
];
#[cfg(any(target_os = "android", test))]
const RPC_HEAD: &[u8] = b"wRPC error: `";

/// Which budget a passed line draws on.
#[cfg(any(target_os = "android", test))]
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
enum Lane {
    Socket,
    Rpc,
}

/// Which lane a pinned-crate line belongs to — `None` for everything that is
/// not one of the enumerated close reasons.
#[cfg(any(target_os = "android", test))]
fn close_lane(args: &std::fmt::Arguments<'_>) -> Option<Lane> {
    let mut head = Head {
        buf: [0; HEAD],
        len: 0,
    };
    let _ = std::fmt::write(&mut head, *args);
    let head = &head.buf[..head.len];
    if head.starts_with(RPC_HEAD) {
        Some(Lane::Rpc)
    } else if SOCKET_HEADS.iter().any(|passed| head.starts_with(passed)) {
        Some(Lane::Socket)
    } else {
        None
    }
}

/// A passed line, rendered no further than [`CAPPED`] bytes: this runs under
/// workflow-log's lock, so a long line must not hold it while it renders.
/// Four times the sanitiser's 200-char cap leaves room for what it strips.
#[cfg(any(target_os = "android", test))]
const CAPPED: usize = 800;

#[cfg(any(target_os = "android", test))]
struct Capped(String);

#[cfg(any(target_os = "android", test))]
impl std::fmt::Write for Capped {
    fn write_str(&mut self, s: &str) -> std::fmt::Result {
        let room = CAPPED.saturating_sub(self.0.len());
        let mut take = s.len().min(room);
        while !s.is_char_boundary(take) {
            take -= 1;
        }
        self.0.push_str(&s[..take]);
        if take < s.len() {
            Err(std::fmt::Error)
        } else {
            Ok(())
        }
    }
}

/// Runs while workflow-log holds its global `SINK` mutex, so two rules:
/// nothing in here may panic out (a poisoned `SINK` would make every pinned
/// log call panic inside the link's own tasks — a wallet that can never
/// reconnect), and nothing in here may log back INTO workflow_log. That is
/// why this sink and the host's `WorkflowLogForwarder`, which does exactly
/// that, are never compiled together.
#[cfg(target_os = "android")]
impl workflow_log::Sink for PinnedCloseSink {
    fn write(
        &self,
        _target: Option<&str>,
        _level: workflow_log::Level,
        args: &std::fmt::Arguments<'_>,
    ) -> bool {
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.forward(args)));
        // Consumed either way: the alternative is `println!`, which goes
        // nowhere on this platform.
        true
    }
}

#[cfg(target_os = "android")]
impl PinnedCloseSink {
    fn forward(&self, args: &std::fmt::Arguments<'_>) {
        let gate = match close_lane(args) {
            Some(Lane::Socket) => &self.socket,
            Some(Lane::Rpc) => &self.rpc,
            None => return,
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        if let Admit::Pass { suppressed_before } = gate.admit(now) {
            if suppressed_before > 0 {
                log::info!(
                    target: "pinned",
                    "{suppressed_before} pinned line(s) suppressed in an earlier window"
                );
            }
            // Node-controlled text can ride these lines (a URL, a peer's
            // error), and liblog splits on newlines: the house sanitiser
            // keeps a node from forging an evidence line (link.rs item 16).
            let mut line = Capped(String::new());
            let _ = std::fmt::write(&mut line, *args);
            log::info!(
                target: "pinned",
                "{}",
                kaspaverse_chain::link::sanitize_node_text(&line.0)
            );
        }
    }
}

/// Install the platform sink. Idempotent (a hot restart re-runs bridge
/// init): a second install errors/no-ops and that is fine — ours is already
/// there. Must run BEFORE anything else that might install a logger
/// (first-one-wins; the alternative is the one L40 proved never reached
/// logcat).
pub(crate) fn install() {
    #[cfg(target_os = "android")]
    {
        android_logger::init_once(
            android_logger::Config::default()
                .with_max_level(log::LevelFilter::Info)
                .with_tag("kaspaverse"),
        );
        // Trace, so the dispatcher's lines reach the sink at all; the sink
        // passes two families and swallows the rest.
        workflow_log::set_log_level(workflow_log::LevelFilter::Trace);
        workflow_log::pipe(Some(std::sync::Arc::new(PinnedCloseSink {
            socket: RateGate::new(),
            rpc: RateGate::new(),
        })));
        // Once per bridge init: the first line only a build carrying this
        // sink can emit, so a persistent capture can be windowed on it (L74).
        log::info!("log: pinned close reasons armed, capped (CONN-F1)");
        // LINK-Q1's own window token (L74): the heartbeat moved to the DAA
        // tick and the silence deadline exists only from this build on, so a
        // re-soak beside CONN-F1's arm B windows on this line. The number is
        // read from the constant, never restated.
        log::info!(
            "log: heartbeat on the DAA tick, silence deadline {}s (LINK-Q1)",
            kaspaverse_chain::link::SILENCE_DEADLINE.as_secs()
        );
        // LINK-Q2's window token (L74): Nagle off at the dialer and the dev
        // A/B seam exist only from this build on.
        log::info!("log: nagle off at the dialer, dev A/B seam present (LINK-Q2)");
        // LINK-Q3's window token (L74): messages from accepted transactions,
        // no full-block stream, exist only from this build on.
        log::info!("log: messages from accepted transactions, no block stream (LINK-Q3)");
    }
    #[cfg(not(target_os = "android"))]
    {
        if log::set_logger(&LOG_FORWARDER).is_ok() {
            log::set_max_level(log::LevelFilter::Info);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fmt;

    /// Renders nothing and panics if asked to — the proof a line was never
    /// formatted past its head.
    struct Unrendered {}
    impl fmt::Display for Unrendered {
        fn fmt(&self, _: &mut fmt::Formatter<'_>) -> fmt::Result {
            panic!("rendered past the head");
        }
    }

    #[test]
    fn passes_the_two_close_families() {
        let e = "IO error: Connection reset by peer (os error 104)";
        assert!(close_lane(&format_args!("WebSocket error: {e}")).is_some());
        assert!(close_lane(&format_args!("WebSocket connection closed")).is_some());
        assert!(close_lane(&format_args!("wRPC error: `{e}`")).is_some());
        assert!(close_lane(&format_args!(
            "WebSocket failed to connect to {}: {e}",
            "wss://node.example/borsh"
        ))
        .is_some());
        assert!(close_lane(&format_args!("WebSocket dispatcher error: {e}")).is_some());
    }

    #[test]
    fn a_node_paced_line_draws_on_its_own_budget() {
        assert_eq!(
            close_lane(&format_args!(
                "wRPC error: `{}`",
                "response handler for id 7 not found"
            )),
            Some(Lane::Rpc)
        );
        assert_eq!(
            close_lane(&format_args!("WebSocket connection closed")),
            Some(Lane::Socket)
        );
    }

    #[test]
    fn drops_every_other_pinned_line() {
        assert!(close_lane(&format_args!("UtxoProcessor: {}", 7)).is_none());
        assert!(close_lane(&format_args!("WebSocketX")).is_none());
        assert!(
            close_lane(&format_args!(
                "WebSocket handshake unable to send completion"
            ))
            .is_none(),
            "a head nobody enumerated fails closed"
        );
        assert!(close_lane(&format_args!("wRPC error during protocol disconnect")).is_none());
        assert!(close_lane(&format_args!("")).is_none());
    }

    #[test]
    fn the_cap_passes_a_window_then_counts_what_it_swallowed() {
        let gate = RateGate::new();
        let t = 1_790_000_040; // a window boundary (divisible by 60)
        for _ in 0..PINNED_LINES_PER_WINDOW {
            assert!(matches!(gate.admit(t), Admit::Pass { .. }));
        }
        assert_eq!(gate.admit(t + 1), Admit::Drop);
        assert_eq!(gate.admit(t + 59), Admit::Drop);
        assert_eq!(
            gate.admit(t + 60),
            Admit::Pass {
                suppressed_before: 2
            },
            "the next window says what the last one swallowed, once"
        );
        assert_eq!(
            gate.admit(t + 61),
            Admit::Pass {
                suppressed_before: 0
            }
        );
    }

    /// The enumeration above was read at exactly these versions. Any move —
    /// a pin bump or a plain `cargo update` of a crates.io dep — reds this
    /// test until someone re-reads what the passed heads now carry and
    /// updates both the list and this test (`pin-bump-ritual` Step 4).
    #[test]
    fn the_enumeration_is_bound_to_the_versions_it_read() {
        let lock = include_str!("../../Cargo.lock");
        for (name, version) in [
            ("workflow-websocket", "0.18.0"),
            ("workflow-rpc", "0.18.0"),
            ("workflow-log", "0.18.0"),
            ("tungstenite", "0.23.0"),
        ] {
            assert!(
                lock.contains(&format!("name = \"{name}\"\nversion = \"{version}\"\n")),
                "{name} moved off {version}: re-enumerate the pinned lane's heads \
                 (INV-3, pin-bump-ritual Step 4)"
            );
            assert_eq!(
                lock.matches(&format!("name = \"{name}\"\n")).count(),
                1,
                "a second {name} in the lock: re-enumerate the pinned lane's heads \
                 (INV-3, pin-bump-ritual Step 4)"
            );
        }
        // The whole workflow-* family moves together, and any of it can grow a
        // line that opens with a runtime value — bind all of it, not the three.
        let family: Vec<&str> = lock
            .split("[[package]]")
            .filter(|package| package.contains("\nname = \"workflow-"))
            .collect();
        assert!(!family.is_empty());
        for package in family {
            assert!(
                package.contains("\nversion = \"0.18.0\"\n"),
                "a workflow-* crate moved off 0.18.0: re-enumerate the pinned lane's heads \
                 (INV-3, pin-bump-ritual Step 4)"
            );
        }
        assert!(
            lock.contains("rusty-kaspa.git?rev=01b532e8b553523216471682649693af92f0fd16"),
            "the rusty-kaspa pin moved: re-enumerate the pinned lane's heads \
             (INV-3, pin-bump-ritual Step 4)"
        );
    }

    #[test]
    fn a_passed_line_renders_no_further_than_its_cap_and_never_splits_a_char() {
        let long = "é".repeat(CAPPED); // two bytes each: twice the cap
        let mut line = Capped(String::new());
        assert!(fmt::write(&mut line, format_args!("x{long}{}", Unrendered {})).is_err());
        assert!(line.0.len() <= CAPPED && line.0.len() >= CAPPED - 1);
        assert!(line.0.starts_with('x'));
    }

    #[test]
    fn a_line_outside_the_families_is_never_rendered_past_its_head() {
        assert!(close_lane(&format_args!("a pinned trace line {}", Unrendered {})).is_none());
    }
}
