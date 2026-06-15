import 'dart:async';

import 'package:flutter/foundation.dart';

import '../rust/api/error.dart';
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
