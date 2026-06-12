//! Hello-DAG stream across the FFI. DTOs only (P0 §0.2): chain types never
//! cross the bridge; `u64` scores arrive in Dart as `BigInt` (L3); errors
//! cross as `Result`, never panics (INV-2).
//!
//! DTO shape note: a plain struct, not an enum-with-fields — FRB 2.12 maps
//! data-carrying Rust enums onto Dart via the `freezed` package, and pulling
//! that codegen ceremony into every build isn't worth it for one DTO.

use std::sync::Mutex;

use kaspaverse_chain::{DagEvent, DagMonitor};
use tokio::sync::broadcast::{self, error::RecvError};

use crate::frb_generated::StreamSink;

/// Live view of the DAG tip as seen over wRPC, streamed on every change.
/// Scores stay `u64` end-to-end (they exceed 2^53 — Dart sees `BigInt`, L3).
#[derive(Clone, Default)]
pub struct DagSnapshot {
    pub connected: bool,
    /// Node endpoint picked by the PNN resolver (`None` until first connect).
    pub endpoint: Option<String>,
    pub virtual_daa_score: Option<u64>,
    pub sink_blue_score: Option<u64>,
}

/// Error type crossing the FFI (INV-2: `Result`, never a panic).
#[derive(Debug)]
pub struct AppError {
    pub message: String,
}

impl AppError {
    fn chain(e: kaspaverse_chain::ChainError) -> Self {
        Self {
            message: e.to_string(),
        }
    }
}

/// Snapshot fan-out, created once per process; every Dart subscription
/// (including after a hot restart) re-attaches to it.
static SNAPSHOTS: tokio::sync::OnceCell<broadcast::Sender<DagSnapshot>> =
    tokio::sync::OnceCell::const_new();
/// Latest folded state, so a fresh subscriber paints without waiting for the
/// next on-chain tick.
static LATEST: Mutex<Option<DagSnapshot>> = Mutex::new(None);

/// Events carry absolute values, so folding is plain assignment (INV-9:
/// nothing is computed locally).
fn fold(snapshot: &mut DagSnapshot, event: DagEvent) {
    match event {
        DagEvent::Connected { url } => {
            snapshot.connected = true;
            snapshot.endpoint = url;
        }
        DagEvent::Disconnected => snapshot.connected = false,
        DagEvent::VirtualDaaScore(value) => snapshot.virtual_daa_score = Some(value),
        DagEvent::SinkBlueScore(value) => snapshot.sink_blue_score = Some(value),
    }
}

/// First call connects to mainnet and spawns the folder task; the monitor's
/// own event task keeps the connection alive for the life of the process.
async fn snapshots() -> Result<&'static broadcast::Sender<DagSnapshot>, AppError> {
    SNAPSHOTS
        .get_or_try_init(|| async {
            let monitor = DagMonitor::mainnet().map_err(AppError::chain)?;
            // Subscribe before start() so the first Connected is not missed.
            let mut events = monitor.subscribe();
            monitor.start().await.map_err(AppError::chain)?;
            let (sender, _) = broadcast::channel(64);
            let fan_out = sender.clone();
            tokio::spawn(async move {
                let mut current = DagSnapshot::default();
                loop {
                    match events.recv().await {
                        Ok(event) => {
                            fold(&mut current, event);
                            *LATEST.lock().unwrap() = Some(current.clone());
                            // Send fails only with zero subscribers — fine.
                            let _ = fan_out.send(current.clone());
                        }
                        // Lagged: folder fell behind the event buffer; values
                        // are absolute, so skipping ahead is safe.
                        Err(RecvError::Lagged(_)) => continue,
                        Err(RecvError::Closed) => break,
                    }
                }
            });
            Ok(sender)
        })
        .await
}

/// Subscribe to live DAG snapshots from mainnet. The first call connects;
/// later calls share the same connection. Each stream ends only when its
/// Dart listener goes away.
pub async fn subscribe_dag_updates(sink: StreamSink<DagSnapshot>) -> Result<(), AppError> {
    let mut receiver = snapshots().await?.subscribe();
    let latest = LATEST.lock().unwrap().clone();
    if let Some(snapshot) = latest {
        let _ = sink.add(snapshot);
    }
    // Runs on FRB's tokio runtime; exits when the Dart listener goes away
    // (sink.add fails) — e.g. on hot restart, leaving the connection up.
    tokio::spawn(async move {
        loop {
            match receiver.recv().await {
                Ok(snapshot) => {
                    if sink.add(snapshot).is_err() {
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

    #[test]
    fn folds_events_into_snapshot() {
        let mut snapshot = DagSnapshot::default();
        fold(
            &mut snapshot,
            DagEvent::Connected {
                url: Some("wss://node.example/borsh".into()),
            },
        );
        fold(&mut snapshot, DagEvent::VirtualDaaScore(458_174_109));
        fold(&mut snapshot, DagEvent::SinkBlueScore(456_290_012));
        assert!(snapshot.connected);
        assert_eq!(
            snapshot.endpoint.as_deref(),
            Some("wss://node.example/borsh")
        );
        assert_eq!(snapshot.virtual_daa_score, Some(458_174_109));
        assert_eq!(snapshot.sink_blue_score, Some(456_290_012));

        // Disconnect keeps the last-seen scores but drops the link flag.
        fold(&mut snapshot, DagEvent::Disconnected);
        assert!(!snapshot.connected);
        assert_eq!(snapshot.virtual_daa_score, Some(458_174_109));
    }
}
