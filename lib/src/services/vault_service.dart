import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../rust/api/error.dart';
import '../rust/api/vault.dart' as vault_api;
import '../ui/secret/bip39_wordlist.dart';

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

  /// How many native ceremony surfaces currently own the foreground (D-039).
  /// Those surfaces can pause Flutter on purpose; the §0.11 auto-lock is
  /// suppressed for that window or we would drop the very ceremony being run.
  ///
  /// A DEPTH, not a bool. Three prompt-bearing ceremonies route through
  /// [runCeremony] now — reveal, enrol and the Path-A unlock — and a
  /// bool would let an inner ceremony's return clear the guard while an outer one
  /// was still on screen — exposing exactly the window the guard exists to cover.
  /// Modal UI makes overlap unreachable today; the counter costs one line and
  /// stops that from being a fact a future entry point has to re-discover.
  int _ceremonyDepth = 0;

  bool get _ceremonyHandoffActive => _ceremonyDepth > 0;

  /// A lifecycle lock arrived DURING a ceremony handoff and has not been resolved
  /// yet. Deferred, never discarded — see [runCeremony].
  bool _lockDeferred = false;

  /// When the app last left the foreground, or null while it is up. The auto-lock
  /// grace (D-133) is measured from here.
  DateTime? _pausedAt;
  Timer? _graceTimer;

  /// When the vault must be locked by, if it is still open. Monotonic: see
  /// [_scheduleLock] for why only bringing it forward is safe.
  DateTime? _lockDeadline;

  /// Is the app currently in the foreground, as last reported by the framework?
  bool _foreground = true;

  /// How long a completed ceremony's proof-of-presence may hold the vault open
  /// while the app is still backgrounded.
  ///
  /// Presence is proof that the user is *there*, not a promise they will come
  /// back. Without this bound, a ceremony that completed while the app never
  /// returned to the foreground left the vault open indefinitely — outside
  /// [maxLockGraceSecs], which is the ceiling that keeps the grace a grace and
  /// not an off switch. Long enough for a `resumed` to land after a system prompt
  /// dismisses, short enough that the worst case is measured in seconds. Tests
  /// shorten it (the `WalletService.reattachDelay` seam).
  @visibleForTesting
  static Duration presenceWindow = const Duration(seconds: 10);

  /// Auto-lock grace in seconds, read from Rust at [start] and refreshed by
  /// [setLockGraceSecs]. `0` — lock immediately — is both the default and the
  /// value any unreadable setting falls back to.
  int _lockGraceSecs = 0;

  /// Test seam for "now" (default wall-clock), matching `HomeScreen.clock`.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  /// Bridge seams, swapped in tests (the `messaging_service` pattern: one static
  /// per bridge fn, so a widget/unit test never needs the native library).
  @visibleForTesting
  static Future<void> Function() lockVaultFn = () async =>
      vault_api.lockVault();
  @visibleForTesting
  static Future<int> Function() readLockGraceFn = vault_api.vaultLockGraceSecs;
  @visibleForTesting
  static Future<void> Function(int secs) writeLockGraceFn = (secs) =>
      vault_api.setVaultLockGraceSecs(secs: secs);

  /// The current auto-lock grace, for the Settings row to render.
  final ValueNotifier<int> lockGraceSecs = ValueNotifier(0);

  /// The longest grace the app will honour — mirrors `vault::MAX_LOCK_GRACE_SECS`.
  /// A ceiling is what keeps this a grace period rather than an off switch.
  static const int maxLockGraceSecs = 900;

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
    await _loadLockGrace();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _loadLockGrace() async {
    try {
      _lockGraceSecs = (await readLockGraceFn()).clamp(0, maxLockGraceSecs);
    } catch (_) {
      // A setting we cannot read is not a reason to weaken the lock — fall back
      // to the strictest value, exactly as the Rust reader does.
      _lockGraceSecs = 0;
    }
    lockGraceSecs.value = _lockGraceSecs;
  }

  /// Re-read the persisted grace, the way [start] does. Exists so a test can
  /// prove the fallback direction of an unreadable setting without standing up
  /// the whole service.
  @visibleForTesting
  Future<void> reloadLockGraceForTest() => _loadLockGrace();

  /// Change the auto-lock grace (D-133). Clamped here as well as Rust-side —
  /// the ceiling is a custody property and must not depend on one caller.
  Future<void> setLockGraceSecs(int secs) async {
    final clamped = secs.clamp(0, maxLockGraceSecs);
    await writeLockGraceFn(clamped);
    _lockGraceSecs = clamped;
    lockGraceSecs.value = clamped;
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
  Future<bool> revealAndVerify() => runCeremony(() async {
    final decoys = await _quizDecoys();
    return await ceremony.invokeMethod<bool>('revealAndVerify', {
          'decoys': decoys,
        }) ??
        false;
  });

  /// Candidate decoy words for the native verify quiz.
  ///
  /// **Public data going IN, never a secret coming out.** These are plain BIP39
  /// wordlist entries the app already ships as an asset; the recovery words
  /// themselves stay on the JNI lane and never touch this channel (INV-1). The
  /// native side drops any candidate that collides with one of the user's own
  /// words before it reaches the board.
  ///
  /// Dart supplies them because Dart is where the wordlist already lives —
  /// asking Kotlin to carry a second copy would have meant a second asset to
  /// keep honest.
  ///
  /// Failure is deliberately not fatal: with no decoys the native board is
  /// simply the phrase itself — D-136's all-12 board, the strongest case, just
  /// undiluted. A wallet must not become uncreatable because an asset read
  /// hiccupped.
  ///
  /// The sample is drawn with NO knowledge of the user's words, and the native
  /// side filters collisions. That split is deliberate: filtering here would
  /// make the list a partial oracle on the phrase.
  Future<List<String>> _quizDecoys() async {
    try {
      final wordlist = await Bip39Wordlist.load();
      // DISTINCT pool. `picked` is a Set, so bounding the loop on
      // `wordlist.words.length` would spin forever on an asset with fewer than
      // `_quizDecoyCount` unique entries — a hang on the UI isolate, mid
      // create-ceremony. Nothing verifies the asset's contents at runtime, so
      // the loop must not assume them.
      final pool = wordlist.words.toSet().toList();
      if (pool.isEmpty) return const [];
      final rng = Random.secure();
      final picked = <String>{};
      // A few more than the board can hold, since the native side discards any
      // that collide with the user's twelve.
      while (picked.length < _quizDecoyCount && picked.length < pool.length) {
        picked.add(pool[rng.nextInt(pool.length)]);
      }
      return picked.toList();
    } catch (_) {
      return const [];
    }
  }

  static const int _quizDecoyCount = 24;

  /// Write [bytes] to a destination the user picks in the system document
  /// picker, offering [name]. Returns the destination, or null if they backed
  /// out — the destination is what makes a later "open" possible WITHOUT
  /// copying decrypted content into app storage to have something to point at.
  ///
  /// **Deliberately NOT a [runCeremony] handoff, and that is the whole point.**
  /// The other native surfaces are wrapped because they pause Flutter and must
  /// come back to an unlocked vault. This one must not be: the bytes are
  /// already decrypted and handed to Kotlin BEFORE the picker opens, so the
  /// write cannot land on a locked vault and needs no suspension.
  ///
  /// Wrapping it would be actively worse. Every existing ceremony is
  /// self-terminating — the biometric prompt times out, the reveal drops on
  /// background — but the document picker is another app the user can sit in,
  /// or walk away from, indefinitely. Suspending §0.11 across it would hold the
  /// vault open for an unbounded window, which is exactly the ceiling D-133
  /// exists to enforce. So the lock arms normally: leave the app in the picker
  /// long enough and you come back to a locked wallet, with the file saved.
  ///
  /// The bytes are decrypted message content (§0.4). They go to the chosen
  /// destination and nowhere else, and are never logged.
  ///
  /// Throws [PlatformException] on a real failure (`failed`, `busy`); a user
  /// cancel is NOT an error and returns null.
  Future<String?> saveFile(String name, Uint8List bytes) async {
    try {
      return await ceremony.invokeMethod<String>('saveFile', {
        'name': name,
        'bytes': bytes,
      });
    } on PlatformException catch (e) {
      if (e.code == 'cancelled') return null;
      rethrow;
    }
  }

  /// Open an already-saved file with whatever the phone has for it.
  ///
  /// [uri] is the destination the user themselves chose, so nothing is copied
  /// anywhere to make this work — no second unencrypted copy of message
  /// content exists (§0.4). [mime] comes from the extension Rust scrubbed,
  /// never from the sender's claim.
  ///
  /// Returns false when the device has nothing that can open the type — a fact
  /// about the phone, not a failure, and the caller says so plainly.
  Future<bool> openFile(String uri, String mime) async =>
      await ceremony.invokeMethod<bool>('openFile', {
        'uri': uri,
        'mime': mime,
      }) ??
      false;

  /// Open an https link the user asked for, in whatever browser the phone has
  /// (UX-5, the explorer exit).
  ///
  /// **The URL is built and validated in Rust** — `prefs_explorer_tx_url` /
  /// `prefs_explorer_address_url` run the stored template through
  /// `validate_template`, which requires `https://`, refuses credentials in the
  /// authority and requires the identifier to sit in the PATH. Nothing here
  /// parses or concatenates a URL; this method is a pipe, and the native side
  /// re-checks the scheme rather than trusting what reached it.
  ///
  /// It sits on the ceremony channel with the other platform ceremonies for the
  /// reason `getFilesDir` does: no new plugin, for a job that is one intent.
  /// This is a **deliberate, user-initiated egress** — the app never phones
  /// home (INV-8), and the exit that fires this discloses the destination and
  /// what it hands over before the user taps it.
  ///
  /// Returns false when the phone has no browser at all — a fact about the
  /// device, not a failure, and the caller says so plainly.
  Future<bool> openUrl(String url) async =>
      await ceremony.invokeMethod<bool>('openUrl', {'url': url}) ?? false;

  /// Run a native ceremony that may pause Flutter, with the §0.11 auto-lock held
  /// open across it and **resolved honestly afterwards**.
  ///
  /// Every native custody surface must go through here. That is not style: the
  /// guard is an instance field on this service, so a caller that reaches past it
  /// to the static [ceremony] channel cannot be covered by it *by construction* —
  /// which is exactly what enrolment used to do, and why the suppression that
  /// existed never applied to the one ceremony that most needed it.
  ///
  /// **Deferring, not discarding.** [revealAndVerify] could simply suppress,
  /// because no unlocked vault exists before the seal — there was nothing to
  /// lose. Enrolment runs against an *unlocked* vault, so a blanket suppression
  /// would mean: user taps enrol, the prompt appears, the user switches apps, and
  /// the wallet is still open when they come back. That is a custody downgrade
  /// wearing a bug fix's clothes.
  ///
  /// So a lock that arrives mid-ceremony is held and then settled on evidence:
  ///
  /// > **A completed biometric ceremony is itself proof of user presence** — the
  /// > user just put a finger on the sensor. A cancel, an error or a timeout
  /// > proves nothing, so the deferred lock is honoured the moment it ends.
  ///
  /// In the bad case (the prompt itself stops the activity on some device) that
  /// degrades to "you are enrolled, now unlock" rather than "nothing happened".
  ///
  /// **Presence is bounded.** Proof that the user was there is not a promise
  /// they will come back, so a completed ceremony that leaves the app still in
  /// the background arms [_presenceWindow] rather than clearing the lock
  /// outright. Without that bound the one path through here that skips
  /// `_armLock` could hold the vault open past [maxLockGraceSecs] — the ceiling
  /// that is the whole reason the grace is a grace and not an off switch.
  @visibleForTesting
  Future<bool> runCeremony(Future<bool> Function() body) async {
    _ceremonyDepth++;
    var authenticated = false;
    try {
      authenticated = await body();
      return authenticated;
    } finally {
      _ceremonyDepth = _ceremonyDepth > 0 ? _ceremonyDepth - 1 : 0;
      // An outer ceremony is still on screen — it owns the resolution.
      if (!_ceremonyHandoffActive) {
        final deferred = _lockDeferred;
        _lockDeferred = false;
        if (_foreground) {
          // The app is in front of the user again, so the pause that triggered
          // the deferral was the PROMPT'S own window transition, not a
          // departure — there is nothing to act on, whatever the outcome was.
          //
          // Arming here regardless of outcome was a spurious-lock bug: after a
          // cancel the countdown ran on into the foreground and locked the
          // wallet mid-use ~a grace later, reachable from the ordinary "tap
          // Enable fingerprint, change your mind" path.
          if (deferred || authenticated) _cancelGrace();
        } else if (deferred) {
          // Still away. Presence buys a BOUNDED window; anything else honours
          // the lock the lifecycle asked for.
          if (authenticated) {
            _armPresenceWatchdog();
          } else {
            _armLock();
          }
        }
      }
    }
  }

  // ── Path A: the biometric lane (P1.2 native, D-036) ──────────────────────
  // Routed through the service so [runCeremony] can cover them and so every
  // caller (create, restore, settings) shares one honest surface. Only booleans
  // and status strings cross — the seed goes over JNI, never here (INV-1).

  /// Why Path A is or is not offerable right now: `ready`, `none_enrolled`,
  /// `no_hardware`, `unavailable`, `security_update_required`, `unknown`.
  ///
  /// Deliberately not a bool. `none_enrolled` — the user has no fingerprint set
  /// up in Android Settings — is the common case on a fresh phone and the only
  /// one they can act on; as a bool it was indistinguishable from "this hardware
  /// cannot", and the enrolment offer simply vanished without a word.
  Future<String> biometricStatus() async =>
      await ceremony.invokeMethod<String>('biometricStatus') ?? 'unknown';

  /// Path A is enrolled **and usable right now**.
  ///
  /// Not "a blob file exists": a new fingerprint permanently invalidates the
  /// Keystore key while leaving the blob on disk, and reporting that as enrolled
  /// is what put a live-looking unlock button over a dead lane (run 1, F4).
  Future<bool> pathAEnrolled() async =>
      await ceremony.invokeMethod<bool>('pathAEnrolled') ?? false;

  /// Path-A enrolment state with its reason: `none`, `ready`, `invalidated`.
  ///
  /// `invalidated` is the one that needs saying out loud — the user's fingerprint
  /// stopped opening the wallet because they changed their fingerprints, which is
  /// the design working (§0.5), but it looks exactly like a broken wallet unless
  /// the app says so and offers the re-enrol.
  Future<String> pathAState() async =>
      await ceremony.invokeMethod<String>('pathAState') ?? 'none';

  /// Run the enrolment ceremony. Throws [PlatformException] with a stable code
  /// (`cancelled`, `lockout`, `vault`, `keystore`, `failed`) — never swallowed,
  /// so the caller can tell a user's own cancel from a real failure.
  Future<bool> enrollBiometric() => runCeremony(
    () async => await ceremony.invokeMethod<bool>('enrollBiometric') ?? false,
  );

  /// Run the Path-A unlock ceremony. Same error contract as [enrollBiometric].
  Future<bool> unlockBiometric() => runCeremony(
    () async => await ceremony.invokeMethod<bool>('unlockBiometric') ?? false,
  );

  /// Forget the Path-A enrolment (Keystore key + blob). Path B remains the
  /// recovery lane, so this is reversible by re-enrolling — never fund loss.
  Future<void> clearBiometric() =>
      ceremony.invokeMethod<void>('clearBiometric');

  /// Public build identity for the About section: `version`, `build`,
  /// `signature` (SHA-256 of the signing certificate, lowercase hex).
  Future<Map<String, String>> packageInfo() async {
    final info = await ceremony.invokeMapMethod<String, String>('packageInfo');
    return info ?? const {};
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
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      _resumed();
      return;
    }
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached) {
      return;
    }
    _foreground = false;
    // Stamped before the ceremony check, so a handoff cannot erase the fact that
    // the app left — only delay what is done about it.
    _pausedAt ??= clock();
    // A native ceremony (D-039 reveal, or a biometric prompt) pauses Flutter on
    // purpose; the native surface guards the in-progress ceremony for its own
    // lifetime. Deferred, not dropped — [runCeremony] settles it.
    if (_ceremonyHandoffActive) {
      _lockDeferred = true;
      return;
    }
    _armLock();
  }

  /// Apply the auto-lock policy for an app that has left the foreground.
  ///
  /// At the default grace of 0 this is the pre-D-133 behaviour exactly: lock now.
  ///
  /// The timer runs for what is LEFT of the grace, measured from when the app
  /// actually departed — not a fresh full grace from now. Re-arming from now is
  /// reachable and fails open: `paused` at t0 arms 900 s, Android destroys the
  /// activity at t0+880, `detached` cancels and re-arms another 900 s, and the
  /// vault stays open for roughly twice [maxLockGraceSecs] — the ceiling failing
  /// at exactly the moment it is supposed to hold. (wallet-security-auditor.)
  void _armLock() => _scheduleLock(
    (_pausedAt ?? clock()).add(Duration(seconds: _lockGraceSecs)),
  );

  /// Bound a completed ceremony's proof of presence while the app is still away.
  ///
  /// The one path that skips [_armLock] on a deferred lock. If the app comes
  /// back, [_resumed] cancels this and the user carries on unlocked — which is
  /// the point of the presence rule. If it never comes back, this locks anyway,
  /// so presence can buy seconds, never an unbounded open vault.
  void _armPresenceWatchdog() => _scheduleLock(clock().add(presenceWindow));

  /// Schedule the lock for [deadline], **or sooner**.
  ///
  /// One entry point, and it is monotonic: a later call can only bring the lock
  /// forward, never push it out. That rule is the whole mechanism, because both
  /// ways of losing it are reachable and both fail open:
  ///
  /// - `paused` at t0 arms 900 s; Android destroys the activity at t0+880 and
  ///   `detached` re-armed a fresh 900 s → ~2× [maxLockGraceSecs].
  /// - A completed ceremony arms the 10 s presence watchdog; a following
  ///   `detached` cancelled it and armed the full grace → presence, the TIGHTER
  ///   bound, erased by the looser one it exists to replace.
  ///
  /// Both are the same bug wearing different clothes, so they get one fix
  /// (wallet-security-auditor, Track 2 re-audit).
  void _scheduleLock(DateTime deadline) {
    final existing = _lockDeadline;
    final effective = existing != null && existing.isBefore(deadline)
        ? existing
        : deadline;
    _lockDeadline = effective;
    _graceTimer?.cancel();
    _graceTimer = null;
    final left = effective.difference(clock());
    if (left <= Duration.zero) {
      _lockNow();
      return;
    }
    // A timer armed while backgrounded must not fire against a user who came
    // back in the meantime — [_resumed] owns that decision, with the wall clock.
    _graceTimer = Timer(left, () {
      if (!_foreground) _lockNow();
    });
  }

  /// Back in the foreground: either the grace expired while we were away, or it
  /// did not.
  ///
  /// **The wall-clock comparison here is the real enforcement, not the timer.**
  /// A backgrounded Dart isolate can be frozen or dozed by the OS, so
  /// [_graceTimer] is best-effort — it locks a still-running process promptly,
  /// and this catches every case where it never got to fire. Trusting the timer
  /// alone would mean a phone that slept through the grace came back unlocked.
  void _resumed() {
    // A ceremony still owns the foreground, so this resume is part of ITS
    // window — `runCeremony`'s `finally` settles the lock on evidence. Without
    // this line, the default grace of 0 makes `elapsed >= 0` unconditionally
    // true, so a resume delivered before the ceremony's future completes locks
    // the vault while the prompt is still up: exactly the path the deferral
    // exists to hold. (wallet-security-auditor — latent, because AndroidX
    // usually resolves the ceremony first, but that is message ordering, not a
    // guarantee.)
    if (_ceremonyHandoffActive) return;
    final left = _pausedAt;
    final deadline = _lockDeadline;
    _cancelGrace();
    if (left == null && deadline == null) return;
    // The deadline is authoritative whenever one is set: [_scheduleLock] has
    // already folded in the grace and any tighter presence bound, and consulting
    // the raw grace *as well* would re-lock a vault a completed ceremony had
    // just vouched for (at the default grace of 0, `elapsed >= 0` is always
    // true). The departure stamp is the fallback for a pause whose timer never
    // got armed at all.
    final now = clock();
    final due = deadline ?? left!.add(Duration(seconds: _lockGraceSecs));
    if (!now.isBefore(due)) _lockNow();
  }

  void _cancelGrace() {
    _pausedAt = null;
    _lockDeadline = null;
    _graceTimer?.cancel();
    _graceTimer = null;
  }

  void _lockNow() {
    _cancelGrace();
    unawaited(lockVaultFn());
  }
}
