import 'dart:async';

import 'package:flutter/foundation.dart';

import '../rust/api/dag.dart';
import '../rust/api/error.dart';

/// Owns the app's single subscription to the bridge DAG stream.
///
/// FRB streams are single-subscription (L4): exactly one listener attaches
/// here, for the app's lifetime; everything downstream watches the exposed
/// [ValueNotifier]s instead of the stream.
class ChainService {
  ChainService._();

  static final ChainService instance = ChainService._();

  /// Test seam: tests swap in a fake stream so no native library is needed.
  @visibleForTesting
  static Stream<DagSnapshot> Function() streamFactory = subscribeDagUpdates;

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

  /// Idempotent: the first call attaches the app-lifetime subscription.
  void start() {
    _subscription ??= streamFactory().listen(
      _apply,
      onError: (Object e) {
        error.value = e is AppError ? e.message : e.toString();
      },
    );
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
    connected.value = false;
    endpoint.value = null;
    virtualDaaScore.value = null;
    sinkBlueScore.value = null;
    error.value = null;
    lastUpdate.value = null;
  }
}
