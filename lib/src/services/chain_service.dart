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
    virtualDaaScore.value = snapshot.virtualDaaScore;
    sinkBlueScore.value = snapshot.sinkBlueScore;
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
  }
}
