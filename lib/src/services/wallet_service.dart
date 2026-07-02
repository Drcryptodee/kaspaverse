import 'dart:async';

import 'package:flutter/foundation.dart';

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

  StreamSubscription<WalletSnapshot>? _subscription;

  /// Idempotent: the first call (post-unlock) attaches the app-lifetime
  /// subscription, which starts the Rust sync engine.
  void start() {
    _subscription ??= streamFactory().listen(
      _apply,
      onError: (Object e) {
        error.value = e is AppError ? e.message : e.toString();
      },
    );
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
