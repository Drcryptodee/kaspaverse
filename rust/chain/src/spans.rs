//! spans — session-scoped performance span markers (hardening V1,
//! findings-register item 6, founder-ratified 2026-07-08).
//!
//! The V0 sitting proved profile builds are logcat-silent for the log lanes
//! (L40 extended), so the observability surface here is DATA, not log lines:
//! a bounded ring buffer of `(marker, txid?, unix_ms)` the bridge exposes as
//! a queryable FFI surface. Dart-side printing reaches logcat on every build
//! flavor, and the perf harness reads the same query.
//!
//! INV-3: markers carry a marker name, an optional txid (public chain data),
//! and a timestamp — nothing else may ever be recorded here. No secret, no
//! address, no payload byte has any business in this module.
//!
//! Markers in use (the three `pending — method: V1 tracker timestamps`
//! baseline rows + the submit→accepted decomposition):
//! - `connect_start` / `wss_connected`  → cold-connect span
//! - `first_daa`                        → time-to-first-DAA span
//! - `resume_start`                     → resume→resynced span (pairs with
//!   the next `wallet_balance`)
//! - `wallet_balance`                   → a real sync completed
//! - `submit_ok(txid)`                  → node acked the submit RPC
//! - `accepted(txid)`                   → VCC reported acceptance
//! - `open_gap_min`                     → gap-age at open (value in txid slot)

use std::collections::VecDeque;
use std::sync::Mutex;

/// Ring capacity — a session's worth of markers (a busy sitting produces a
/// few dozen; 256 is generous headroom, and the ring drops oldest-first).
const CAP: usize = 256;

/// One recorded marker. `detail` is a txid or a small public value; never
/// anything secret (module law above).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpanMarker {
    pub marker: String,
    pub detail: Option<String>,
    pub unix_ms: u64,
}

static SPANS: Mutex<VecDeque<SpanMarker>> = Mutex::new(VecDeque::new());

fn now_unix_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn push(marker: &str, detail: Option<String>) {
    let unix_ms = now_unix_ms();
    // Twin lane: every marker also emits one `log` line (the bridge sinks
    // the facade into liblog on Android — L40-proof on every build flavor).
    // Same public fields as the queryable surface, nothing more (INV-3).
    match &detail {
        Some(d) => log::info!(target: "kv-span", "kv-span {unix_ms} {marker} {d}"),
        None => log::info!(target: "kv-span", "kv-span {unix_ms} {marker}"),
    }
    let mut ring = SPANS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if ring.len() >= CAP {
        ring.pop_front();
    }
    ring.push_back(SpanMarker {
        marker: marker.to_string(),
        detail,
        unix_ms,
    });
}

/// Record a bare marker.
pub fn mark(marker: &str) {
    push(marker, None);
}

/// Record a marker carrying a txid (or another small PUBLIC value).
pub fn mark_with(marker: &str, detail: &str) {
    push(marker, Some(detail.to_string()));
}

/// The ring's current contents, oldest first — the bridge's query surface.
pub fn snapshot() -> Vec<SpanMarker> {
    SPANS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter()
        .cloned()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_in_order_and_caps_the_ring() {
        // Note: the ring is process-global; use distinctive markers so this
        // test stays independent of anything else the suite records.
        mark("t-first");
        mark_with("t-submit_ok", &"a".repeat(64));
        let snap = snapshot();
        let first = snap.iter().position(|s| s.marker == "t-first").unwrap();
        let second = snap.iter().position(|s| s.marker == "t-submit_ok").unwrap();
        assert!(first < second, "oldest first");
        assert_eq!(snap[second].detail.as_deref(), Some(&*"a".repeat(64)));
        assert!(snap[second].unix_ms >= snap[first].unix_ms);

        for i in 0..CAP + 10 {
            mark(&format!("t-flood-{i}"));
        }
        let snap = snapshot();
        assert_eq!(snap.len(), CAP, "ring caps, dropping oldest");
        assert!(!snap.iter().any(|s| s.marker == "t-first"));
    }
}
