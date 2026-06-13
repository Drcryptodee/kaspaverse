import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../rust/api/error.dart';
import '../rust/api/vault.dart' as vault_api;

/// Owns the app's single subscription to the bridge vault-status stream and
/// the lifecycle kill switch (P1 §0.11: backgrounding drops vault state).
///
/// Same single-subscription pattern as [ChainService] (L4): one listener for
/// the app's lifetime; downstream watches the [ValueNotifier]s. Only DTOs
/// cross here — the vault's secrets live and die in Rust (INV-1/2/3).
class VaultService with WidgetsBindingObserver {
  VaultService._();

  static final VaultService instance = VaultService._();

  /// The ceremony channel MainActivity owns (FLAG_SECURE, a11y gate,
  /// biometric ceremony, app-private dir). Booleans and paths only.
  static const MethodChannel ceremony = MethodChannel(
    'org.kaspaverse.app/ceremony',
  );

  /// Latest vault status DTO (null until the stream paints the first one).
  final ValueNotifier<vault_api.VaultStatus?> status = ValueNotifier(null);

  /// Last vault-lane error message, null while healthy.
  final ValueNotifier<String?> error = ValueNotifier(null);

  StreamSubscription<vault_api.VaultStatus>? _subscription;

  /// Idempotent: hands Rust the app-private directory (INV-3 — the sealed
  /// blob's home), attaches the app-lifetime status subscription, and
  /// registers the lifecycle observer.
  Future<void> start() async {
    if (_subscription != null) return;
    try {
      final dir = await ceremony.invokeMethod<String>('getFilesDir');
      await vault_api.initVault(appPrivateDir: dir!);
    } catch (e) {
      // Boot must survive a platform gap (e.g. host-side widget tests have
      // no MethodChannel); the vault lane reports unavailable instead.
      error.value = 'vault init failed: $e';
      return;
    }
    _subscription = vault_api.vaultStatusStream().listen(
      (s) {
        status.value = s;
        error.value = null;
      },
      onError: (Object e) {
        error.value = e is AppError ? e.message : e.toString();
      },
    );
    WidgetsBinding.instance.addObserver(this);
  }

  /// Create the vault (Path B). The ONE Dart call site for the passphrase
  /// lane: every future ceremony screen routes through here, never the raw
  /// bridge fn, so the L9 wipe below covers them all. The caller's buffer is
  /// zeroed in `finally` — a throw between use and wipe cannot leak (INV-1
  /// sentence two).
  Future<void> createVault(
    Uint8List passphrase, {
    vault_api.VaultKdfParams? params,
  }) async {
    try {
      // Default = the P1.2 on-device tuned point (192 MiB / 3 / 1,
      // PERFORMANCE_BUDGET.md); the blob header records what was used.
      final p = params ?? await vault_api.VaultKdfParams.tuned();
      await vault_api.createVault(passphrase: passphrase, params: p);
    } finally {
      passphrase.fillRange(0, passphrase.length, 0);
    }
  }

  /// Unlock via passphrase (Path B). Same single-call-site + finally-wipe
  /// contract as [createVault].
  Future<void> unlockWithPassphrase(Uint8List passphrase) async {
    try {
      await vault_api.unlockWithPassphrase(passphrase: passphrase);
    } finally {
      passphrase.fillRange(0, passphrase.length, 0);
    }
  }

  // ── P1.4 create ceremony + restore (D-037 / D-038) ──────────────────────
  // The held phrase lives in Rust; the native reveal/verify surface reads it
  // over the JNI lane (D-037) — it NEVER crosses these FRB calls. The buffers
  // these methods wipe are per-call throwaways: a secret-screen owns its source
  // of truth as wordlist INDICES (never the assembled phrase as a String) and
  // hands a fresh copy to each call, so the finally-wipe below cannot orphan it.

  /// Begin a create ceremony: Rust generates + holds the 12 words for the native
  /// reveal/verify surface. No secret crosses this call.
  Future<void> beginCreate() => vault_api.beginCreate();

  /// Abandon an in-progress create ceremony (cancel / back-gesture). Idempotent.
  /// (Backgrounding also drops it: the lifecycle [lockVault] does, Rust-side.)
  Future<void> abandonCreate() => vault_api.abandonCreate();

  /// Seal the held ceremony's seed under [passphrase] (+ optional ASCII
  /// [extraWord]) and persist. Both throwaway buffers are zeroed in `finally`
  /// (INV-1 sentence two) — a throw between use and wipe cannot leak.
  Future<void> sealAndPersist(
    Uint8List passphrase,
    Uint8List extraWord, {
    vault_api.VaultKdfParams? params,
  }) async {
    try {
      final p = params ?? await vault_api.VaultKdfParams.tuned();
      await vault_api.sealAndPersist(
        passphrase: passphrase,
        extraWord: extraWord,
        params: p,
      );
    } finally {
      passphrase.fillRange(0, passphrase.length, 0);
      extraWord.fillRange(0, extraWord.length, 0);
    }
  }

  /// Derive the first receive address from a candidate restore phrase WITHOUT
  /// persisting (deliverable 2 — the decoy/typo preview). Throwaway buffers wiped
  /// in `finally`; the returned address is public (INV-2 permits it to cross).
  Future<String> restorePreview(Uint8List phrase, Uint8List extraWord) async {
    try {
      return await vault_api.restorePreview(
        phrase: phrase,
        extraWord: extraWord,
      );
    } finally {
      phrase.fillRange(0, phrase.length, 0);
      extraWord.fillRange(0, extraWord.length, 0);
    }
  }

  /// Restore-commit: restore from [phrase] (+ optional [extraWord]), seal under
  /// [passphrase], persist, unlock. All three throwaway buffers wiped in
  /// `finally`.
  Future<void> restoreAndPersist(
    Uint8List phrase,
    Uint8List extraWord,
    Uint8List passphrase, {
    vault_api.VaultKdfParams? params,
  }) async {
    try {
      final p = params ?? await vault_api.VaultKdfParams.tuned();
      await vault_api.restoreAndPersist(
        phrase: phrase,
        extraWord: extraWord,
        passphrase: passphrase,
        params: p,
      );
    } finally {
      phrase.fillRange(0, phrase.length, 0);
      extraWord.fillRange(0, extraWord.length, 0);
      passphrase.fillRange(0, passphrase.length, 0);
    }
  }

  /// The lifecycle kill switch (P1.2 deliverable 4): backgrounding or detach
  /// drops the Rust `UnlockedVault`. Lock contract is D-031.4 — "no new
  /// operation can start", not "instant erasure": an in-flight sign completes
  /// and the seed dies on its release. Rust logs `vault locked` (logcat) —
  /// the on-device acceptance evidence.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(vault_api.lockVault());
    }
  }
}
