//! App-level bridge plumbing.

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Install OUR log sink first (L40 repayment — `log:` → `workflow-log`,
    // the sink that provably reaches logcat): if FRB's default utils also try
    // to install a logger, first-one-wins, and theirs is the one L40 proved
    // never surfaced our lines.
    crate::logging::install();
    // Default utilities - feel free to customize
    flutter_rust_bridge::setup_default_user_utils();
}
