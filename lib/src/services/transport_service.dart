import 'dart:async';

import 'package:flutter/foundation.dart';

import '../rust/api/error.dart';
import '../rust/api/transport.dart';
import '../rust/api/wallet.dart' show uiMark;

/// Owns the app's single subscription to the bridge transport-event stream
/// (P2.1 raw receive) — one `ciph_msg:` match per event, straight off the
/// BlockAdded scan.
///
/// FRB streams are single-subscription (L4): exactly one listener attaches
/// here, for the app's lifetime; consumers watch [events]. This is the LIVE
/// WIRE only — a bounded, newest-first window for the P2.1 dev surface. The
/// encrypted message store (P2.3) owns real history; nothing here persists.
///
/// Battery posture: nothing to manage here — the scan runs in Rust on the
/// shared socket and pauses/resumes with `ChainService`'s grace-drop (D-053);
/// a background app simply has no socket to scan on.
class TransportService {
  TransportService._();

  static final TransportService instance = TransportService._();

  /// Test seam: tests swap in a fake stream so no native library is needed.
  @visibleForTesting
  static Stream<TransportEventDto> Function() streamFactory =
      subscribeTransportEvents;

  /// Live-window cap — enough to eyeball the wire on the dev panel without
  /// growing unbounded on a busy day.
  static const int maxEvents = 50;

  /// Newest-first window of matches seen since app start (bounded, deduped).
  final ValueNotifier<List<TransportEventDto>> events = ValueNotifier(
    const <TransportEventDto>[],
  );

  /// Last bridge error message, null while healthy.
  final ValueNotifier<String?> error = ValueNotifier(null);

  StreamSubscription<TransportEventDto>? _subscription;

  /// Consumer apply-echo through the ONE build-flavor-proof log lane (three
  /// lights, V3/L55). Counts/flags only — never payload bodies (§4). Never
  /// throws.
  @visibleForTesting
  static Future<void> Function(String marker) uiMarkFn = (marker) =>
      uiMark(marker: marker);

  void _mark(String marker) {
    try {
      unawaited(uiMarkFn(marker).catchError((_) {}));
    } catch (_) {
      // Native lib absent (widget tests) — silence is fine.
    }
  }

  /// Idempotent: the first call attaches the app-lifetime subscription.
  void start() {
    _subscription ??= streamFactory().listen(
      _apply,
      onError: (Object e) {
        error.value = e is AppError ? e.message : e.toString();
      },
      // Detach light only (no blind re-attach — L55: lights precede heals).
      // The message store's catch-up remains this lane's pull twin.
      onDone: () {
        _subscription = null;
        _mark('transport stream done');
      },
    );
  }

  void _apply(TransportEventDto event) {
    // Three-lights apply echo: pairs with the producer's
    // "dag-monitor: transport emit matches=N receivers=M".
    _mark('transport apply txid=${event.txid != null}');
    final current = events.value;
    // Display dedup: a DAG can include the same tx in more than one block, so
    // the scan may legitimately emit one match twice. The wire stays raw
    // (Rust passes every match); this window shows each tx once. The P2.3
    // store dedups properly by txid; id-less events (exotic) pass through.
    if (event.txid != null && current.any((e) => e.txid == event.txid)) {
      return;
    }
    events.value = [event, ...current.take(maxEvents - 1)];
    error.value = null;
  }

  @visibleForTesting
  Future<void> reset() async {
    await _subscription?.cancel();
    _subscription = null;
    events.value = const <TransportEventDto>[];
    error.value = null;
  }
}
