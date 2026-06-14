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

  /// True while the native reveal Activity owns the foreground (D-039). It pauses
  /// Flutter on purpose; suppress the §0.11 auto-lock for that window or we would
  /// drop the very create ceremony being revealed.
  bool _ceremonyHandoffActive = false;

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

  /// Unlock via passphrase (Path B). Same single-call-site + finally-wipe
  /// contract as [sealAndPersist].
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

  /// Run the native FLAG_SECURE reveal + verify surface (D-037/D-039) for the
  /// held create ceremony. Returns true once the user has revealed the 12 words
  /// and passed the verify quiz; false on back-out, a11y refusal, or error. The
  /// words are read by native Kotlin over the JNI lane and NEVER cross this call
  /// (INV-1) — only the boolean verdict returns. The native Activity pauses
  /// Flutter, so this suppresses the §0.11 auto-lock for the handoff (the native
  /// surface is the ceremony's guardian meanwhile — it drops on background).
  Future<bool> revealAndVerify() async {
    _ceremonyHandoffActive = true;
    try {
      final ok = await ceremony.invokeMethod<bool>('revealAndVerify');
      return ok ?? false;
    } finally {
      _ceremonyHandoffActive = false;
    }
  }

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
    // A native reveal handoff (D-039) pauses Flutter on purpose; the
    // RevealActivity guards the in-progress ceremony for its own lifetime, so
    // don't drop it here. No unlocked vault exists pre-seal — nothing else to lock.
    if (_ceremonyHandoffActive) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(vault_api.lockVault());
    }
  }
}
