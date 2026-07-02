import 'dart:async';

import 'package:flutter/widgets.dart';

import '../rust/api/dag.dart';
import '../rust/api/error.dart';

/// Owns the app's single subscription to the bridge DAG stream.
///
/// FRB streams are single-subscription (L4): exactly one listener attaches
/// here, for the app's lifetime; everything downstream watches the exposed
/// [ValueNotifier]s instead of the stream.
///
/// It also owns the connection's **battery posture** (PERFORMANCE_BUDGET,
/// implemented at the P1.5 re-audit): ~[graceDuration] after the app
/// backgrounds, the wRPC socket is dropped (no invisible always-on stream);
/// on resume it reconnects — preferring the last-good endpoint, so the
/// resume-to-live span stays inside the ≤2 s budget.
class ChainService with WidgetsBindingObserver {
  ChainService._();

  static final ChainService instance = ChainService._();

  /// Test seam: tests swap in a fake stream so no native library is needed.
  @visibleForTesting
  static Stream<DagSnapshot> Function() streamFactory = subscribeDagUpdates;

  /// Test seams for the lifecycle bridge calls (no native library in tests).
  @visibleForTesting
  static Future<void> Function() pauseBridge = dagPause;
  @visibleForTesting
  static Future<void> Function() resumeBridge = dagResume;

  /// Background window before the socket is dropped (PERFORMANCE_BUDGET:
  /// "after 30 s grace"). Tests shorten it.
  @visibleForTesting
  static Duration graceDuration = const Duration(seconds: 30);

  final ValueNotifier<bool> connected = ValueNotifier(false);
  final ValueNotifier<String?> endpoint = ValueNotifier(null);

  /// Scores stay [BigInt] end-to-end — they exceed 2^53 (L3); format only
  /// at render.
  final ValueNotifier<BigInt?> virtualDaaScore = ValueNotifier(null);
  final ValueNotifier<BigInt?> sinkBlueScore = ValueNotifier(null);

  /// Last bridge error message, null while healthy.
  final ValueNotifier<String?> error = ValueNotifier(null);

  /// Wall-clock of the last *fresh* snapshot (connected + a real score). Drives
  /// the StatusBeacon stale state (DS-1); null until the first fresh tip.
  final ValueNotifier<DateTime?> lastUpdate = ValueNotifier(null);

  StreamSubscription<DagSnapshot>? _subscription;
  Timer? _graceTimer;
  bool _droppedByGrace = false;

  /// Idempotent: the first call attaches the app-lifetime subscription and
  /// registers the lifecycle observer for the background grace-drop.
  void start() {
    if (_subscription == null) {
      WidgetsBinding.instance.addObserver(this);
    }
    _subscription ??= streamFactory().listen(
      _apply,
      onError: (Object e) {
        error.value = e is AppError ? e.message : e.toString();
      },
    );
  }

  /// Battery posture (PERFORMANCE_BUDGET): background → after [graceDuration],
  /// drop the socket; resume → cancel the pending drop, and reconnect iff we
  /// dropped it (never bounce a healthy connection). The vault's own lifecycle
  /// lock (§0.11, VaultService) is independent and unaffected.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _graceTimer ??= Timer(graceDuration, () {
        _graceTimer = null;
        _droppedByGrace = true;
        unawaited(
          pauseBridge().catchError((Object e) {
            // A failed drop leaves the old (working) behavior — log-and-live.
            debugPrint('chain: grace-drop failed: $e');
          }),
        );
      });
    } else if (state == AppLifecycleState.resumed) {
      _graceTimer?.cancel();
      _graceTimer = null;
      if (_droppedByGrace) {
        _droppedByGrace = false;
        unawaited(
          resumeBridge().catchError((Object e) {
            error.value = e is AppError ? e.message : e.toString();
          }),
        );
      }
    }
  }

  void _apply(DagSnapshot snapshot) {
    connected.value = snapshot.connected;
    endpoint.value = snapshot.endpoint;
    // Retain last-known scores when a snapshot carries none — a dropped link
    // emits nulls, and DS-1 dims last-known data with its age rather than
    // blanking it to unknown ("—"). A genuine first-connect simply has no
    // prior value to retain, so it still reads "—".
    if (snapshot.virtualDaaScore != null) {
      virtualDaaScore.value = snapshot.virtualDaaScore;
    }
    if (snapshot.sinkBlueScore != null) {
      sinkBlueScore.value = snapshot.sinkBlueScore;
    }
    // Freshness clock for the stale beacon: only a connected snapshot bearing
    // real chain data resets it. Silence or a dropped link lets age grow.
    if (snapshot.connected && snapshot.virtualDaaScore != null) {
      lastUpdate.value = DateTime.now();
    }
    error.value = null;
  }

  @visibleForTesting
  Future<void> reset() async {
    await _subscription?.cancel();
    _subscription = null;
    _graceTimer?.cancel();
    _graceTimer = null;
    _droppedByGrace = false;
    connected.value = false;
    endpoint.value = null;
    virtualDaaScore.value = null;
    sinkBlueScore.value = null;
    error.value = null;
    lastUpdate.value = null;
  }
}
