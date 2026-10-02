//! App-level bridge plumbing.

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Install OUR log sink first (L40 repayment — `log:` → `workflow-log`,
    // the sink that provably reaches logcat): if FRB's default utils also try
    // to install a logger, first-one-wins, and theirs is the one L40 proved
    // never surfaced our lines.
    crate::logging::install();
    // LINK-Q2: hand the chain crate the socket witness's platform half.
    // Inert until a dev flags file says `on=1`.
    #[cfg(any(target_os = "android", target_os = "linux"))]
    crate::sockstat::install();
    // Default utilities - feel free to customize
    flutter_rust_bridge::setup_default_user_utils();
    // PRE3-LANE: every panic in the process is recorded as shape (location,
    // thread, time — never its payload) so the wallet lane's supervisor sees a
    // pinned task die. LAST, because FRB's utils above install a hook of their
    // own (its backtrace capture): ours chains it, so both still run.
    kaspaverse_chain::lane_health::install_panic_hook();
}
