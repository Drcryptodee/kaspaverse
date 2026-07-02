//! `log`-facade → `workflow-log` forwarder (repays L40).
//!
//! No sink was ever installed for the `log` facade, so every `log::info!` in
//! chain/bridge was a silent no-op on device — while the pinned kaspa crates'
//! own `workflow-log` provably reaches Android logcat. This module bridges the
//! two. Lives OUTSIDE `api/` (it is plumbing, not bridge API — FRB parses
//! everything under `api/`).
//!
//! INV-3 note: this adds a sink, not a data source — the no-secrets-in-log-
//! lines discipline lives at the call sites, which log public chain data only
//! (audited per phase).

// Braced (not a unit struct) so FRB's whole-crate type scan doesn't emit a
// skip-warning for it — same layout, zero cost.
struct WorkflowLogForwarder {}

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

static LOG_FORWARDER: WorkflowLogForwarder = WorkflowLogForwarder {};

/// Install the forwarder. Idempotent (a hot restart re-runs bridge init): a
/// second `set_logger` errors and that is fine — ours is already there. Must
/// run BEFORE anything else that might install a logger (first-one-wins; the
/// alternative is the one L40 proved never reached logcat).
pub(crate) fn install() {
    if log::set_logger(&LOG_FORWARDER).is_ok() {
        log::set_max_level(log::LevelFilter::Info);
    }
}
