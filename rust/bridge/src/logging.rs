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
//! line this sink will carry).

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
    }
    #[cfg(not(target_os = "android"))]
    {
        if log::set_logger(&LOG_FORWARDER).is_ok() {
            log::set_max_level(log::LevelFilter::Info);
        }
    }
}
