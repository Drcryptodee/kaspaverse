import 'dart:async';

import 'package:flutter/services.dart';
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

  /// Test seams for the foreground watchdog (P3/D-068): the liveness pull and
  /// the forced reconnect. `stalled` carries the caller's evidence: the
  /// watchdog passes true (30 s block silence — a pending strike the Rust race
  /// commits only with network-alive proof, V3 demotion); the manual button
  /// passes false (bouncing a healthy node must never demote it).
  @visibleForTesting
  static Future<DagStatusDto> Function() statusFn = dagStatus;
  @visibleForTesting
  static Future<void> Function(bool stalled) reconnectFn = (stalled) =>
      dagReconnect(stalled: stalled);

  /// OS network signal relay (C5/D-089): MainActivity's
  /// `ConnectivityManager` default-network callback arrives on this channel;
  /// the handler forwards the bool to Rust, which owns ALL semantics
  /// (redial / log-only / passive). Pure relay — no policy lives in Dart.
  static const MethodChannel _networkChannel = MethodChannel(
    'org.kaspaverse.app/network',
  );

  /// Test seam for the network-signal bridge call (no native lib in tests).
  @visibleForTesting
  static Future<void> Function(bool available) networkChangedBridge =
      (available) => dagNetworkChanged(available: available);

  /// V1 observability seam: the Rust span-marker pull (hardening V1, findings
  /// item 6). NOTE the build-flavor-proof `kv-span` lane is Rust's own
  /// twin-emit through liblog (D-076/L53) — the [_dumpNewSpans] debugPrint
  /// below is a debug-build courtesy duplicate, dead on profile/release
  /// (L53 proved Dart prints silent there).
  @visibleForTesting
  static Future<List<SpanMarkerDto>> Function() spansFn = perfSpans;

  /// Background window before the socket is dropped (PERFORMANCE_BUDGET:
  /// "after 30 s grace"). Tests shorten it.
  @visibleForTesting
  static Duration graceDuration = const Duration(seconds: 30);

  /// Foreground watchdog cadence and stall threshold (P3/D-068). A healthy
  /// mainnet delivers ~10 blocks/s, so a block-age past [watchdogStallSecs]
  /// while foreground means the wRPC socket died silently (the midnight DAA
  /// stall) — the watchdog forces a reconnect. Generous enough not to fire on
  /// brief hiccups; tests shorten both.
  @visibleForTesting
  static Duration watchdogPeriod = const Duration(seconds: 10);
  @visibleForTesting
  static int watchdogStallSecs = 30;

  /// V3 freshness watchdog (register item 10's second heal): when the link is
  /// up but the WALLET lane has applied nothing for this long, the tick pulls
  /// the fold's latest via [onWalletQuiet] — a cheap local re-serve that heals
  /// a dropped stream delivery within one tick, and never touches the node.
  @visibleForTesting
  static int walletQuietSecs = 30;

  /// Wired in main.dart (WalletService.refreshLocal / .lastApply); null = off
  /// (tests, or before wiring). Callbacks, not imports: this service stays
  /// ignorant of the wallet lane's type.
  void Function()? onWalletQuiet;
  DateTime? Function()? walletLastApply;

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

  /// True while a reconnect is in flight (watchdog-triggered OR the manual
  /// Reconnect button). The honest-liveness indicator — never a silent stall.
  final ValueNotifier<bool> reconnecting = ValueNotifier(false);

  StreamSubscription<DagSnapshot>? _subscription;
  Timer? _graceTimer;
  bool _droppedByGrace = false;
  Timer? _watchdogTimer;
  bool _foreground = true;

  /// Idempotent: the first call attaches the app-lifetime subscription and
  /// registers the lifecycle observer for the background grace-drop, and arms
  /// the foreground liveness watchdog.
  void start() {
    if (_subscription == null) {
      WidgetsBinding.instance.addObserver(this);
      // OS network signal (C5): native → Dart → Rust, a pure relay. The
      // signal is an accelerator, never load-bearing — a failed forward is
      // swallowed (the watchdog and the race's own retry still recover).
      _networkChannel.setMethodCallHandler((call) async {
        if (call.method == 'networkChanged' && call.arguments is bool) {
          try {
            await networkChangedBridge(call.arguments as bool);
          } catch (_) {}
        }
        return null;
      });
    }
    _subscription ??= streamFactory().listen(
      _apply,
      onError: (Object e) {
        error.value = e is AppError ? e.message : e.toString();
      },
    );
    _watchdogTimer ??= Timer.periodic(watchdogPeriod, (_) => _watchdogTick());
  }

  /// Foreground liveness check (P3/D-068): pull the honest block-age; if the
  /// chain has gone quiet past the stall threshold while we're foreground, the
  /// socket is silently dead — force a reconnect rather than let the DAA readout
  /// freeze. Skipped while backgrounded (the grace-drop owns the socket then)
  /// or while a reconnect is already in flight.
  Future<void> _watchdogTick() async {
    await _dumpNewSpans();
    if (!_foreground || _droppedByGrace || reconnecting.value) return;
    final DagStatusDto status;
    try {
      status = await statusFn();
    } catch (_) {
      return; // a failed pull is not itself evidence of a stall
    }
    final age = status.lastBlockAgeSecs;
    if (age != null && age.toInt() > watchdogStallSecs) {
      // Watchdog evidence: the node went quiet on us — a pending strike.
      await reconnect(stalled: true);
      return;
    }
    // Connected-but-quiet wallet lane → pull the fold's latest (local
    // re-serve). Ships now that the delivery lane is instrumented end-to-end
    // (L55): it heals a diagnosed disease, it can't mask one — every heal
    // paints through the same 'apply' echo the diagnostics watch.
    final lastApply = walletLastApply?.call();
    if (status.connected &&
        lastApply != null &&
        DateTime.now().difference(lastApply).inSeconds > walletQuietSecs) {
      onWalletQuiet?.call();
    }
  }

  /// How many span markers have already been printed (the Rust ring is
  /// oldest-first; a session produces a few dozen against its 256 cap, so
  /// index-tracking is safe for a sitting).
  int _spansPrinted = 0;

  /// Print any NEW Rust span markers, one line each:
  /// `kv-span UNIX_MS MARKER [DETAIL]`. Public chain data only (INV-3:
  /// marker names, txids, timestamps). Debug-build courtesy ONLY — on
  /// profile/release these debugPrints are silent (L53); the lines that
  /// reach logcat there are Rust's own twin-emits at mark time (D-076).
  Future<void> _dumpNewSpans() async {
    try {
      final spans = await spansFn();
      for (var i = _spansPrinted; i < spans.length; i++) {
        final s = spans[i];
        final detail = s.detail == null ? '' : ' ${s.detail}';
        debugPrint('kv-span ${s.unixMs} ${s.marker}$detail');
      }
      _spansPrinted = spans.length;
    } catch (_) {
      // Spans are observability, never load-bearing — a failed pull is noise.
    }
  }

  /// Force a fresh connection and surface the honest indicator while it runs —
  /// the watchdog's recovery and the sheet's Reconnect button. Idempotent under
  /// the [reconnecting] guard (a second press is ignored until the first ends).
  /// [stalled] = the caller holds failure evidence (watchdog only).
  Future<void> reconnect({bool stalled = false}) async {
    if (reconnecting.value) return;
    reconnecting.value = true;
    try {
      await reconnectFn(stalled);
      error.value = null;
    } on AppError catch (e) {
      error.value = e.message;
    } catch (e) {
      error.value = e.toString();
    } finally {
      reconnecting.value = false;
    }
  }

  /// Battery posture (PERFORMANCE_BUDGET): background → after [graceDuration],
  /// drop the socket; resume → cancel the pending drop, and reconnect iff we
  /// dropped it (never bounce a healthy connection). The vault's own lifecycle
  /// lock (§0.11, VaultService) is independent and unaffected.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _foreground = false;
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
      _foreground = true;
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
    _networkChannel.setMethodCallHandler(null);
    _graceTimer?.cancel();
    _graceTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _droppedByGrace = false;
    _foreground = true;
    onWalletQuiet = null;
    walletLastApply = null;
    connected.value = false;
    endpoint.value = null;
    virtualDaaScore.value = null;
    sinkBlueScore.value = null;
    error.value = null;
    lastUpdate.value = null;
    reconnecting.value = false;
  }
}
