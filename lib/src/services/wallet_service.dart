import 'dart:async';

import 'package:flutter/foundation.dart';

import '../rust/api/dag.dart' show dagResync;
import '../rust/api/error.dart';
import '../rust/api/send.dart';
import '../rust/api/wallet.dart';

/// Owns the app's single subscription to the bridge wallet stream (L4): balance
/// + activity for the unlocked vault's derived addresses. Mirrors
/// [ChainService] — one app-lifetime listener, state exposed as
/// [ValueNotifier]s that the wallet home watches.
///
/// Started post-unlock (the stream derives addresses from the unlocked vault);
/// the first listen also starts the Rust sync engine over the shared wRPC
/// client (§0.8).
class WalletService {
  WalletService._();

  static final WalletService instance = WalletService._();

  /// Test seam: tests swap in a fake stream so no native library is needed.
  @visibleForTesting
  static Stream<WalletSnapshot> Function() streamFactory =
      subscribeWalletUpdates;

  /// Shared wRPC link is up.
  final ValueNotifier<bool> connected = ValueNotifier(false);

  /// Initial scan in progress (between `UtxoProcStart` and the first balance).
  final ValueNotifier<bool> syncing = ValueNotifier(false);

  /// INV-8 honest degrade: the connected node has no UTXO index.
  final ValueNotifier<bool> utxoIndexMissing = ValueNotifier(false);

  /// Balances in sompi ([BigInt], L3). `null` until the first sync (DS-1
  /// unknown `—`); then a real value — `BigInt.zero` for an empty wallet is a
  /// live zero, never unknown.
  final ValueNotifier<BigInt?> mature = ValueNotifier(null);
  final ValueNotifier<BigInt?> pending = ValueNotifier(null);
  final ValueNotifier<BigInt?> outgoing = ValueNotifier(null);

  /// Newest-first activity rows (public chain data; §0.10).
  final ValueNotifier<List<ActivityRecord>> activity = ValueNotifier(const []);

  /// Last bridge/stream error message, null while healthy.
  final ValueNotifier<String?> error = ValueNotifier(null);

  /// Wall-clock of the last synced balance — the freshness clock (DS-1); null
  /// until the first balance.
  final ValueNotifier<DateTime?> lastUpdate = ValueNotifier(null);

  @visibleForTesting
  static Future<WalletSnapshot?> Function() snapshotNowFn = walletSnapshotNow;

  /// V3 register item 12: the pull heal's DETECTION half — ask the NODE
  /// (a forced reconnect + rescan through the race; rate-limited in Rust).
  /// Returns true when a resync was actually triggered.
  @visibleForTesting
  static Future<bool> Function() resyncFn = dagResync;

  /// Backoff before the onDone re-attach (register item 10 heal); tests
  /// shorten it.
  @visibleForTesting
  static Duration reattachDelay = const Duration(seconds: 1);

  /// Display-state marker through the Rust liblog lane (L53: the only
  /// build-flavor-proof lane — Dart prints die on profile/release). Never
  /// throws: in tests (no native lib) it becomes a no-op.
  @visibleForTesting
  static Future<void> Function(String marker) uiMarkFn = (marker) =>
      uiMark(marker: marker);

  void _mark(String marker) {
    try {
      // Fire-and-forget; a failed marker must never break the pipeline.
      unawaited(uiMarkFn(marker).catchError((_) {}));
    } catch (_) {
      // Native lib absent (widget tests) — silence is fine.
    }
  }

  /// Pull the latest folded snapshot and apply it — the DELIVERY heal
  /// (founder request, V2 sitting): bypasses the stream entirely, so the
  /// glass can always self-serve the truth the fold already holds. Local
  /// only — never node traffic; the freshness watchdog calls this each
  /// connected-but-quiet tick (register item 10).
  Future<void> refreshLocal() async {
    try {
      final snapshot = await snapshotNowFn();
      if (snapshot != null) _apply(snapshot);
    } on AppError catch (e) {
      error.value = e.message;
    }
  }

  /// The swipe-to-refresh pull heal, both halves (V3 register item 12):
  /// re-serve the fold NOW (delivery), then force a node resync (detection —
  /// a deposit the store never saw needs the node re-asked, not the fold
  /// re-read). The resync is rate-limited on the Rust side, so pull-spam
  /// degrades to re-serve-only, never socket-bouncing.
  Future<void> refreshNow() async {
    await refreshLocal();
    try {
      final resynced = await resyncFn();
      _mark(resynced ? 'pull resync' : 'pull resync window — re-serve only');
    } on AppError catch (e) {
      error.value = e.message;
    } catch (_) {
      // Native lib absent (widget tests) — the local half already ran.
    }
  }

  /// Wall-clock of the last [_apply] (stream OR pull) — the freshness
  /// watchdog's quiet detector (wired in main.dart). Null until the first.
  DateTime? lastApply;

  StreamSubscription<WalletSnapshot>? _subscription;
  Timer? _reattachTimer;
  bool _everApplied = false;
  bool _stopped = false;
  int _reattachAttempts = 0;

  /// Backoff ceiling for repeated re-attach failures (wallet-security audit:
  /// a locked-vault error→done loop must decay, not spin at 1 Hz forever).
  static const Duration _reattachCap = Duration(seconds: 60);

  /// Idempotent: the first call (post-unlock) attaches the app-lifetime
  /// subscription, which starts the Rust sync engine.
  void start() {
    _stopped = false;
    _subscription ??= streamFactory().listen(
      _apply,
      onError: (Object e) {
        error.value = e is AppError ? e.message : e.toString();
      },
      onDone: _onStreamDone,
    );
  }

  /// Register item 10 heal (shipped WITH the lane fully instrumented, V3): a
  /// stream that ENDS mid-session is re-attached after [reattachDelay] — the
  /// restart/Reconnect "kick" the V2 sitting needed, done by the service
  /// itself. Guarded: never before the engine proved live (a pre-unlock error
  /// stream would loop), never after [reset] (test teardown). Repeated deaths
  /// (e.g. a background-locked vault refusing the re-subscribe) back off
  /// exponentially to [_reattachCap]; a successful apply resets the ladder.
  void _onStreamDone() {
    _subscription = null;
    if (_stopped || !_everApplied) return;
    var delay = reattachDelay * (1 << _reattachAttempts.clamp(0, 10));
    if (delay > _reattachCap) delay = _reattachCap;
    _reattachAttempts++;
    _mark('stream done — re-attach in ${delay.inMilliseconds}ms');
    _reattachTimer?.cancel();
    _reattachTimer = Timer(delay, () {
      _reattachTimer = null;
      if (!_stopped) start();
    });
  }

  // ── Send (P1.6) ──────────────────────────────────────────────────────────
  // Request/response over the bridge, not the stream. Test seams (like
  // [streamFactory]) let widget tests run without the native library.

  @visibleForTesting
  static Future<SendSummaryDto> Function(String destination, BigInt amountSompi)
  sendPrepareFn = (destination, amountSompi) =>
      sendPrepare(destination: destination, amountSompi: amountSompi);

  @visibleForTesting
  static Future<SendOutcomeDto> Function(BigInt nonce) sendCommitFn = (nonce) =>
      sendCommit(nonce: nonce);

  @visibleForTesting
  static Future<void> Function() sendAbandonFn = sendAbandon;

  @visibleForTesting
  static Future<BigInt?> Function() sendMinimumFn = sendMinimum;

  /// Phase 1: build + stash the send in Rust; returns the Rust-decoded summary
  /// the confirm renders (B7). Throws [AppError] on a bad address / shortfall.
  Future<SendSummaryDto> prepareSend(String destination, BigInt amountSompi) =>
      sendPrepareFn(destination, amountSompi);

  /// The smallest currently-sendable amount (sompi) for the wallet's live coin
  /// shape — the KIP-9 floor probed from the pinned Generator (D-054). Advisory
  /// display; `prepareSend` stays the single authority.
  Future<BigInt?> minimumSendable() => sendMinimumFn();

  /// Phase 2: sign + broadcast the stashed plan `nonce`. Returns the outcome
  /// (final txid, or a typed partial result — B6).
  Future<SendOutcomeDto> commitSend(BigInt nonce) => sendCommitFn(nonce);

  /// Drop a stashed-but-unconfirmed send (confirm dismissed).
  Future<void> abandonSend() => sendAbandonFn();

  void _apply(WalletSnapshot snapshot) {
    // The V2 stream-freeze diagnostic: if the bridge logs a fold this line
    // doesn't echo, the Dart delivery lane dropped it (counts only, INV-3).
    _mark('apply rows=${snapshot.activity.length}');
    _everApplied = true;
    _reattachAttempts = 0; // a live lane resets the backoff ladder
    lastApply = DateTime.now();
    connected.value = snapshot.connected;
    syncing.value = snapshot.syncing;
    utxoIndexMissing.value = snapshot.utxoIndexMissing;
    // The snapshot is cumulative — the Rust fold retains balances across events,
    // so a value never regresses to null once seen. Assign directly.
    mature.value = snapshot.matureSompi;
    pending.value = snapshot.pendingSompi;
    outgoing.value = snapshot.outgoingSompi;
    activity.value = snapshot.activity;
    error.value = snapshot.error;
    // Freshness clock: a connected snapshot bearing a real balance is fresh.
    if (snapshot.connected && snapshot.matureSompi != null) {
      lastUpdate.value = DateTime.now();
    }
  }

  @visibleForTesting
  Future<void> reset() async {
    _stopped = true;
    _everApplied = false;
    _reattachAttempts = 0;
    lastApply = null;
    _reattachTimer?.cancel();
    _reattachTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    connected.value = false;
    syncing.value = false;
    utxoIndexMissing.value = false;
    mature.value = null;
    pending.value = null;
    outgoing.value = null;
    activity.value = const [];
    error.value = null;
    lastUpdate.value = null;
  }
}
