import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../rust/api/vault.dart' as vault_api;
import '../services/vault_service.dart';
import 'biometric_copy.dart';
import 'error_text.dart';
import 'extra_word_copy.dart';
import 'secret/masked_dots.dart';
import 'secret/secret_byte_buffer.dart';
import 'secret/secret_keyboard.dart';
import 'secret/secret_screen_guard.dart';
import 'secret/word_parts.dart';
import 'theme/kv_window.dart';
import 'theme/tokens.dart';
import 'widgets/ceremony_mark.dart';
import 'widgets/kv_ceremony_page.dart';
import 'widgets/kv_chrome.dart';
import 'widgets/kv_keypad.dart';
import 'widgets/kv_loader.dart';
import 'widgets/kv_notice.dart';
import 'widgets/kv_rows.dart';
import 'widgets/kv_steps.dart';
import 'widgets/kv_toggle.dart';
import 'widgets/kv_two_pane.dart';

/// The create-wallet ceremony (P1.4 deliverable 2; D-037/D-038/D-039). Drives the
/// two-step bridge end to end:
///
///   beginCreate → native FLAG_SECURE reveal + verify ([RevealActivity], over the
///   ceremony channel — words never cross to Dart, INV-1) → set passphrase →
///   optional ASCII extra word (typed twice and matched, because it is
///   seed-determining) → sealAndPersist (leaves the vault unlocked) → optional
///   biometric enroll → pop (the shell then shows home).
///
/// The passphrase + extra-word steps are §0.6 secret screens: [SecretScreenGuard]
/// (FLAG_SECURE + a11y refusal), [SecretByteBuffer] (never a Dart `String`,
/// INV-3), the no-IME [SecretKeyboard] (§0.7). Backing out, a failed verify, or a
/// dropped ceremony all abandon and return to onboarding — never a half-made
/// wallet. Every platform interaction is an injected seam so the flow is
/// unit-testable without a device (the native reveal + biometric prove on glass).
class CreateScreen extends StatefulWidget {
  const CreateScreen({
    super.key,
    this.begin,
    this.reveal,
    this.abandon,
    this.seal,
    this.biometricStatus,
    this.enroll,
    this.deviceBinding,
    this.wordCount,
    this.checkAccessibility,
    this.setSecure,
  });

  /// Begin a fresh ceremony (dropping any stale one first). Defaults to the lane.
  final Future<void> Function()? begin;

  /// Run the native reveal + verify; true once the quiz passes.
  final Future<bool> Function()? reveal;

  /// Drop the held ceremony on cancel. Idempotent.
  final Future<void> Function()? abandon;

  /// Seal the held ceremony under a passphrase (+ optional ASCII extra word).
  ///
  /// **[inputKind] is the third argument because the seal really does take a
  /// third thing now** (D-312): what the user typed the secret on is written
  /// into the blob header, so it is part of the seal rather than a preference
  /// beside it. A seam that hid it would be a seam that could not prove it.
  final Future<void> Function(
    Uint8List passphrase,
    Uint8List extraWord,
    vault_api.VaultInputKind inputKind,
  )?
  seal;

  /// How many words the ceremony drew (D-312's `12 | 24`). Defaults to the
  /// lane, which asks Rust; the native control is what moves it.
  final Future<int> Function()? wordCount;

  /// Why Path A is or is not offerable after the seal — a REASON, not a bool.
  ///
  /// This used to be `Future<bool>`, and that was the defect: `none_enrolled`
  /// (the phone has a sensor, the user just has not registered a fingerprint
  /// with Android) collapsed to the same `false` as `no_hardware`, so the offer
  /// silently vanished and nothing said why. On the most common phone state, the
  /// feature appeared not to exist.
  final Future<String> Function()? biometricStatus;

  /// Run the biometric enroll ceremony; true once Path A is set up.
  final Future<bool> Function()? enroll;

  /// Whether this phone can hardware-bind the vault (D-312) — the precondition
  /// for offering a 6-digit PIN at all. Defaults to the real Keystore lane.
  final Future<bool> Function()? deviceBinding;

  /// Forwarded to [SecretScreenGuard] (test seams).
  final Future<bool> Function()? checkAccessibility;
  final Future<void> Function({required bool enable})? setSecure;

  @override
  State<CreateScreen> createState() => _CreateScreenState();
}

/// **How many recovery words the create ceremony draws unless the user says
/// otherwise.**
///
/// Twelve, and D-312 did not change that — it changed only whether 24 is
/// reachable, on `O3`'s own `12 | 24` control. **24 words does not make a Kaspa
/// wallet harder to break**: 12 is 128 bits, which already saturates
/// secp256k1's ~128-bit effective security. No copy on this path may say or
/// imply otherwise.
///
/// This constant is the DEFAULT and the fallback. The live count is
/// [_CreateScreenState._wordCount], read back from the ceremony after the
/// native reveal, because every string on `O5` names the extra word by its
/// ORDINAL — a 13th word for twelve, a 25th for twenty-four — and a wrong
/// ordinal is a wrong instruction on the one piece of paper that restores the
/// wallet.
const int createWordCount = 12;

/// **One extra-word step, not two** (D-312, `O5`'s input contract).
///
/// The word used to be typed on one screen and confirmed on the next, with a
/// mismatch wiping both and bouncing back. `O5` draws both boxes at once and
/// the founder asked for the render: the screen has to say *this word gets
/// typed twice* before the first keystroke rather than after it (F17), and the
/// primary has to stay dead until the two actually match (F19). Neither is
/// expressible in a two-step model, so the two steps became one.
enum _Step { preparing, passphrase, extraWord, enrolling }

class _CreateScreenState extends State<CreateScreen>
    with WidgetsBindingObserver {
  final SecretByteBuffer _passphrase = SecretByteBuffer();
  final SecretByteBuffer _extraWord = SecretByteBuffer();

  /// The confirm-repeat of the extra word. A second buffer is a second secret:
  /// it enters once, inward, as bytes, is compared in place, and is wiped at
  /// the seal, on the way back, and on dispose (INV-1/3).
  ///
  /// Why this step exists at all: unlike the passphrase — which is mistypeable
  /// and still recoverable, because the quiz-verified twelve words plus the
  /// extra word the user *meant* still restore the wallet — the extra word is
  /// seed-determining. It is the BIP39 PBKDF2 salt
  /// (`vault.rs` `ceremony.into_seed`), so one wrong character seals a wallet
  /// that the user's own written backup can never reproduce. It is typed
  /// exactly once, ever; the native reveal quiz covers the twelve words only
  /// and runs before this word exists; there is no delete-wallet path and the
  /// vault refuses to seal over an existing blob, so the backup cannot even be
  /// tested by restoring over the top. Nothing downstream would ever say so.
  final SecretByteBuffer _extraWordConfirm = SecretByteBuffer();

  _Step _step = _Step.preparing;
  bool _busy = false;
  String? _message;

  /// **Where to scroll to when the extra word is switched on.**
  ///
  /// Raising the switch adds a caps label, two 56 dp fields and the notice
  /// plate under a keypad that is already up, so the plate lands below the
  /// fold — the founder had to scroll to find the one sentence on the screen
  /// that says the word cannot be recovered. Scrolling the NOTICE to the
  /// bottom of the viewport brings everything above it into view with it,
  /// which is exactly what he asked for: "shows whats above it".
  final GlobalKey _noticeKey = GlobalKey();

  /// Anchor for [_say], so a reason beat can prove it is on screen rather than
  /// merely in the tree.
  final GlobalKey _messageKey = GlobalKey();

  /// Whether the current beat is a WARNING rather than an instruction.
  ///
  /// The two read differently and should look different: "Enter the extra word,
  /// or tap Skip" is guidance, while "those didn't match" is the app telling you
  /// something went wrong on the screen that decides whether your backup works.
  /// `KvColor.error` is reserved for fund risk and destruction, so this is
  /// `warning` — the degraded tier, not the destructive one.
  bool _messageIsWarning = false;
  bool _sealed = false; // ceremony consumed — don't abandon on dispose

  /// Why Path A is (un)available, resolved once after the seal. Drives whether
  /// the enrol step offers a button or an explanation.
  String _biometricStatus = 'unknown';

  /// **Whether the user has asked for an extra word** — `O5`'s switch.
  ///
  /// Off by default, which is both the render's own state and the safe one:
  /// the word is seed-determining and unrecoverable, so it is opted INTO. It
  /// governs only whether the two fields are on the glass; nothing about what
  /// is sealed changes, because an untouched buffer and a wiped one are the
  /// same empty `Uint8List` at the seal.
  bool _use25th = false;

  /// **Which field has the keyboard, and whether there is a keyboard at all.**
  ///
  /// `null` collapses the pad — `O5` draws no keyboard, and the founder read
  /// the always-up pad as the screen having no room left to say anything (F18).
  /// Tapping a field raises it; tapping the body or scrolling drops it, which
  /// is the contract a system IME would give for free and this one has to draw.
  int? _field;

  /// **The revealed extra word, composed ONCE per hold** (D-312 §3).
  ///
  /// Non-null only while the eye is pressed. It is held here rather than being
  /// composed in `build` because `build` runs many times during a gesture, and
  /// each call would mint another unwipeable `String` instead of one
  /// (`ffi-leak-auditor`). Never a sticky toggle — see
  /// [SecretByteBuffer.revealWhileHeld] for the whole fence.
  String? _revealedExtra;

  /// **Which pad the unlock secret is typed on** — the founder's D-312 choice.
  ///
  /// The keyboard is the default because it is what every existing wallet has
  /// and because it is the pad that can enter either secret. Picking the PIN is
  /// a deliberate act, and it is refused outright on a phone that cannot
  /// hardware-bind the vault: six digits with no binding is 10^6 candidates at
  /// ~679 ms each for anyone who lifts the file, which is a real downgrade from
  /// the passphrase it would replace. The rule lives in Rust (`binding_for`) so
  /// it holds for every caller; [_setPad] enforces it HERE as well, because a
  /// user must find out at the moment they choose rather than at the seal, with
  /// their recovery words already written down.
  vault_api.VaultInputKind _pad = vault_api.VaultInputKind.passphrase;
  bool get _isPin => _pad == vault_api.VaultInputKind.digits;

  /// **The live phrase length**, read back from the ceremony once the native
  /// reveal has verified it (D-312). It starts at the default and only ever
  /// moves because the user moved `O3`'s control.
  int _wordCount = createWordCount;

  /// `O2` draws six wells. The number is the render's and the KDF does not care
  /// — what makes six safe is the device binding, not the count.
  static const int _pinLength = 6;

  // ── seams resolved to the real lanes ─────────────────────────────────────
  Future<void> Function() get _beginLane =>
      widget.begin ??
      () async {
        // Drop any stale held ceremony, then begin fresh (idempotent abandon).
        await VaultService.instance.abandonCreate();
        await VaultService.instance.beginCreate();
      };
  // The seam keeps its no-argument shape so every injected test double still
  // fits; the step count is closed over instead of being a parameter.
  Future<bool> Function() get _revealLane =>
      widget.reveal ??
      () => VaultService.instance.revealAndVerify(steps: _steps);
  Future<void> Function() get _abandonLane =>
      widget.abandon ?? VaultService.instance.abandonCreate;
  Future<void> Function(Uint8List, Uint8List, vault_api.VaultInputKind)
  get _sealLane =>
      widget.seal ??
      (p, x, kind) =>
          VaultService.instance.sealAndPersist(p, x, inputKind: kind);

  /// Whether this phone can hardware-bind the vault (D-312) — a PROBE, not an
  /// install: asking leaves nothing resident. Injected so the PIN's
  /// precondition is testable without a Keystore.
  Future<bool> Function() get _bindingLane =>
      widget.deviceBinding ?? VaultService.instance.canDeviceBind;
  // Both biometric lanes go through VaultService, never straight to the static
  // ceremony channel. That routing is the fix for the lifecycle race: the §0.11
  // auto-lock suppression is an INSTANCE flag on the service, so a caller that
  // reaches past it cannot be covered by it *by construction* — which is exactly
  // what this screen used to do, on the one ceremony that runs against an
  // unlocked vault and therefore needed it most.
  Future<String> Function() get _biometricLane =>
      widget.biometricStatus ?? VaultService.instance.biometricStatus;
  Future<bool> Function() get _enrollLane =>
      widget.enroll ?? VaultService.instance.enrollBiometric;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _runReveal());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // **A hold does not survive leaving the app.** Nothing guarantees a pointer
    // cancel is delivered when the platform takes the window away, so without
    // this the screen could come back with the extra word legible and no finger
    // down — which would make [SecretByteBuffer.revealWhileHeld]'s "only while
    // held" fence untrue. `restore_screen` latched the identical case shut for
    // the recovery words; this is the same latch on the same class of secret.
    if (state != AppLifecycleState.resumed && _revealedExtra != null) {
      setState(() => _revealedExtra = null);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _passphrase.dispose();
    _extraWord.dispose();
    _extraWordConfirm.dispose();
    // Back-gesture out of the flow before sealing: drop the held ceremony.
    // Fire-and-forget; idempotent Rust-side.
    if (!_sealed) _abandonLane();
    super.dispose();
  }

  // ── flow ─────────────────────────────────────────────────────────────────

  /// **Ask, before the first dot is drawn, whether this phone has a fifth
  /// beat.**
  ///
  /// The enrol step is conditional — `_offersEnrolStep` — and the indicator
  /// promises a total. Probing after the seal, which is where the flow already
  /// asks, would mean three screens counting to five on a phone that stops at
  /// four. The probe is the same cheap platform query, run once more and
  /// early; a probe that cannot answer leaves the count at four, and if the
  /// post-seal answer then disagrees the enrol step raises it before it draws
  /// itself, so the number is never wrong on a screen that is showing.
  Future<void> _countSteps() async {
    final status = await _safeBiometricProbe();
    if (!mounted) return;
    if (_offersEnrolStep(status)) setState(() => _steps = 5);
  }

  Future<void> _runReveal() async {
    try {
      // **Awaited now, not fired and forgotten.** The native reveal draws the
      // indicator too, and it is handed the total at launch — so a probe still
      // in flight would put four dots on a five-beat phone for the two screens
      // that cannot be corrected later. The probe is one cheap platform query.
      await _countSteps();
      await _beginLane();
      final verified = await _revealLane();
      if (!mounted) return;
      if (verified) {
        // The user may have taken `O3`'s 24 on the native screen; every `O5`
        // string is about to name the extra word by its ordinal.
        //
        // **Caught HERE and not inside the lane**, because the enclosing
        // `catch` abandons the ceremony — and a ceremony the user has already
        // written down and passed a quiz on must not be thrown away because a
        // count read hiccupped. Twelve is both the default and the safe guess:
        // it is what `begin_create` drew unless the user moved the control.
        var count = createWordCount;
        try {
          count =
              await (widget.wordCount ??
                  VaultService.instance.ceremonyWordCount)();
        } catch (_) {
          // keep the default
        }
        if (!mounted) return;
        setState(() {
          _wordCount = count;
          _step = _Step.passphrase;
        });
      } else {
        await _abandonLane();
        if (mounted) _popWith('Backup not confirmed — no wallet was created.');
      }
    } catch (_) {
      await _abandonLane();
      if (mounted) _popWith('Could not start the backup. Please try again.');
    }
  }

  /// Show a reason, and make sure it is actually READABLE.
  ///
  /// Position alone could not carry this. Above the buttons the beat is in the
  /// right place by §12's error anatomy, but on a 360×640 phone at 1.3× the
  /// heading and subtitle already fill the viewport on their own — the scroll
  /// area is only ~360 dp once the fixed keyboard takes its 224 — so wherever
  /// the message sits in the column, it can start below the fold. A user who
  /// mistyped the confirm would see the step revert and the dots reset, with
  /// the explanation off-screen: present, findable by a test, and invisible.
  /// Scrolling it into view is the part that holds at any text scale.
  void _say(String message, {bool warning = false}) {
    setState(() {
      _message = message;
      _messageIsWarning = warning;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _messageKey.currentContext;
      if (!mounted || ctx == null) return;
      // Decelerate, no overshoot — a custody surface (BG-9).
      Scrollable.ensureVisible(
        ctx,
        duration: KvMotion.fast,
        curve: KvMotion.out,
        alignment: 0.5,
      );
    });
  }

  void _submitPassphrase() {
    if (_isPin && _passphrase.length.value != _pinLength) {
      _say('Enter all $_pinLength digits.');
      return;
    }
    if (_passphrase.isEmpty) {
      _say('Enter a passphrase first.');
      return;
    }
    setState(() {
      _step = _Step.extraWord;
      _message = null;
    });
  }

  /// **The gate — and it is a LIVE one now** (`O5`'s F19).
  ///
  /// The primary used to enable on the first field alone and advance to a
  /// second screen, so the app asked *are you sure?* after the decision rather
  /// than before it. The founder's words: *"feels kinda not intuitive to what
  /// people are used too."* Both fields are on the glass and the pill is dead
  /// until they match, which is the shape every password form on the phone
  /// already has.
  ///
  /// **[SecretByteBuffer.matches] compares in place** — neither buffer is copied
  /// out and nothing becomes a Dart `String` (INV-1/3). What is new, and is
  /// said here rather than left to be noticed, is that this now runs on **every
  /// keystroke** instead of once at a commit. It early-returns on a length
  /// mismatch and is not constant-time, and it is not claimed to be: both
  /// operands are the same user's own bytes on their own device, typed by their
  /// own thumb, and there is no attacker positioned to time a comparison
  /// between two things they would have to already hold.
  bool get _extraWordReady =>
      !_extraWord.isEmpty && _extraWord.matches(_extraWordConfirm);

  /// **What replaced the wipe-both-and-bounce, and where it is said.**
  ///
  /// The old flow wiped BOTH buffers on a mismatch, so a user could not
  /// "correct" the copy until it matched a first entry that was itself the
  /// typo. That protection is retired here, deliberately and on the founder's
  /// ruling, and two things replace it: the eye, which lets the word be read
  /// back against the paper rather than guessed at, and a live gate that never
  /// lets a mismatch reach the seal in the first place. Recorded rather than
  /// dropped quietly — it was a real property (D-312, `wallet-security`).
  ///
  /// **The reason lives in the pill and nowhere else.** A disabled [KvAction]
  /// paints its `disabledReason` AS its label, so a second line under the
  /// fields saying the same thing would be two objects with one job (BG-21) —
  /// and the pill is pinned, so its copy is on the glass at every geometry
  /// without a scroll or a reachability test to prove it.
  String? get _extraWordReason {
    if (_busy) return 'Creating your wallet…';
    if (!_use25th || _extraWordReady) return null;
    return _extraWord.isEmpty
        ? 'Type your extra word in both boxes first'
        : 'The two boxes do not match yet';
  }

  Future<void> _doSeal() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await _sealLane(_passphrase.snapshot(), _extraWord.snapshot(), _pad);
      _sealed = true; // ceremony consumed; the vault is now unlocked
      // Consumed — wipe now, not at dispose. The enrol step holds this screen
      // for an unbounded time (and, since the honest-degrade fix, keeps holding
      // it after a FAILED enrolment instead of popping), across a window that
      // deliberately spans an app-background. Nothing after the seal reads
      // either buffer (wallet-security-auditor, Track 2).
      _passphrase.wipe();
      _extraWord.wipe();
      _extraWordConfirm.wipe();
      if (!mounted) return;
      final status = await _safeBiometricProbe();
      if (!mounted) return;
      if (_offersEnrolStep(status)) {
        setState(() {
          _busy = false;
          _biometricStatus = status;
          // The early probe could not answer and this one can: raise the total
          // before the step that IS the fifth beat paints itself.
          _steps = 5;
          _step = _Step.enrolling;
        });
      } else {
        _finish();
      }
    } catch (e) {
      if (!mounted) return;
      if (e.toString().contains('no create ceremony')) {
        // The ceremony was dropped (backgrounded for safety) — can't recover.
        await _abandonLane();
        if (mounted) {
          _popWith('Your setup session ended for safety. Please start again.');
        }
      } else {
        setState(() => _busy = false);
        // **A refusal Rust can explain is surfaced verbatim.** Two of them are
        // actionable and "try again" is the wrong answer to both: a PIN this
        // phone cannot hardware-bind, and a PIN anyone would guess first. The
        // generic line sent the user to retry a choice that would be refused
        // identically forever (`wallet-security-auditor`, D-312).
        //
        // The pad goes back to the keyboard with them, because that is the way
        // out the sentence is telling them to take.
        if (isDeviceBinding(e) || _isPinRefusal(e)) {
          if (isDeviceBinding(e)) _pad = vault_api.VaultInputKind.passphrase;
          _passphrase.wipe();
          setState(() => _step = _Step.passphrase);
          _say(displayError(e), warning: true);
          return;
        }
        // Through `_say` like every other beat on this screen. A seal failure
        // is the LAST one that can afford to be off-screen: it is the reason
        // the wallet does not exist yet.
        _say(
          'Could not finish creating your wallet. Your funds are safe — try again.',
          warning: true,
        );
      }
    }
  }

  /// Ask the platform why Path A is or is not offerable. A probe that cannot run
  /// at all is `unknown`, never a confident "no".
  Future<String> _safeBiometricProbe() async {
    try {
      return await _biometricLane();
    } catch (_) {
      // The old shape returned `false` here and the offer disappeared without a
      // word. `unknown` is the honest reading of a question we could not ask,
      // and it routes to the same silent finish — but through a state Settings
      // can re-ask later, rather than a verdict.
      return 'unknown';
    }
  }

  /// Does the create flow stop for the enrol step at all?
  ///
  /// Only for the two states a user can do something about: `ready` (offer the
  /// button) and `none_enrolled` (tell them how to get there, then continue).
  /// A phone with no usable sensor gets no step — an unavoidable dead end
  /// tacked onto a wallet's first minute is noise, and Settings tells the whole
  /// truth to anyone who looks.
  static bool _offersEnrolStep(String status) =>
      status == biometricReady || status == biometricNoneEnrolled;

  Future<void> _enrollNow() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await _enrollLane();
      _finish();
    } on PlatformException catch (e) {
      if (!mounted) return;
      // Backing out of the system prompt is a CHOICE, not a failure — no
      // message, just return to the step so "Not now" is still there.
      setState(() {
        _busy = false;
        _message = null;
      });
      if (e.code != 'cancelled') _say(enrollFailureCopy(e.code));
    } catch (_) {
      // Never swallowed to a silent pop again: that is what made enrolment
      // present as "I tapped it and nothing happened". The user stays on the
      // step, is told what happened, and can retry or skip.
      if (!mounted) return;
      setState(() => _busy = false);
      _say(enrollFailureCopy('failed'));
    }
  }

  void _finish() {
    // The status stream has flipped unlocked; popping reveals home beneath.
    if (mounted) Navigator.of(context).pop();
  }

  void _popWith(String msg) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    messenger?.showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Re-enter the native reveal WITHOUT re-beginning the ceremony.
  ///
  /// The words are still held Rust-side — nothing is sealed until the
  /// passphrase step commits — so going back to look at them is a re-open, not
  /// a restart. Calling [_runReveal] here would call `beginCreate` a second
  /// time on a lane that is already open.
  Future<void> _reopenReveal() async {
    final verified = await _revealLane();
    if (!mounted) return;
    if (verified) {
      setState(() => _step = _Step.passphrase);
    } else {
      // Backing out of the WORDS screen still means abandoning: that is the
      // first beat, and there is nothing behind it but Welcome.
      await _abandonLane();
      if (mounted) _popWith('Backup not confirmed — no wallet was created.');
    }
  }

  void _handleBack() {
    switch (_step) {
      case _Step.preparing:
        Navigator.of(
          context,
        ).pop(); // leave create (dispose abandons if !sealed)
      case _Step.passphrase:
        // **Back is one step, not the whole ceremony** (founder, UX-R6 glass
        // beat — he raised it twice). This popped straight out to Welcome, so
        // a user who had already written down twelve words and passed the
        // quiz lost all of it by pressing the system back button once. The
        // step before the passphrase is the words, so that is where it goes;
        // the quiz is re-taken because the reveal screen always re-arms it,
        // which is D-136's rule and not a cost worth breaking it for.
        unawaited(_reopenReveal());
      case _Step.extraWord:
        // **The buffer does not survive the step it belongs to.** Backing out
        // kept it loaded and re-entering APPENDED, so a user who retyped had
        // `word+word` in field one. It cannot reach the seal — the confirm is
        // wiped on every back and every mismatch, so a doubled entry always
        // mismatches a single one — but what it produced was a warning whose
        // stated cause was false (*"Those didn't match"* when the real cause
        // was a field that silently doubled), and the wipe then destroyed the
        // evidence. `restore_screen` has the same shape with no confirm gate
        // behind it, which is where it was a BLOCK (`wallet-security-auditor`,
        // UX-R6).
        _extraWord.wipe();
        _extraWordConfirm.wipe();
        // **And the passphrase too, which is not tidiness — it is the only way
        // back.** On the PIN path the wells arrive full, `_onPinChar` early-
        // returns at six, and there is no `Next` because the sixth digit is the
        // commit: a user who backed up here was standing on a screen with no
        // way forward at all. The same trap catches a seal that Rust refused
        // (`wallet-security-auditor`, D-312).
        _passphrase.wipe();
        setState(() {
          _step = _Step.passphrase;
          _field = null;
          _revealedExtra = null;
          _message = null;
        });
      case _Step.enrolling:
        _finish(); // vault already created — just go home
    }
  }

  // ── views ──────────────────────────────────────────────────────────────
  //
  // **The ceremony's five beats, and where each one is drawn** (`O2`–`O6`).
  //
  //   1 · Your recovery words   RevealActivity   (native, FLAG_SECURE)
  //   2 · Prove it              RevealActivity   (native)
  //   3 · Choose a passphrase   `O2`, below
  //   4 · Add a 13th word?      `O5`, below
  //   5 · Open with biometrics? `O6`, below
  //
  // **The renders number the passphrase FIRST and this build runs it third**,
  // and the indicator states the order the build actually has rather than the
  // one the picture draws. Reordering the ceremony would move when the held
  // seed exists relative to passphrase entry, which is a change to the
  // ceremony and not to its skin — said in the sitting, not decided here.

  /// How many beats this ceremony has **for this phone**.
  ///
  /// Four when the device can never offer enrolment, five when it can. The
  /// probe that answers it runs before the first Flutter beat draws (see
  /// [_countSteps]) precisely so the number is true from the first dot: a
  /// fixed five would have promised a step that a phone with no sensor never
  /// reaches, which is what *progress that never lies* forbids.
  int _steps = 4;

  /// **The beats are fixed; only the TOTAL is probed.**
  ///
  /// They were `_steps - 3 / -2 / -1`, anchored to the END of the ceremony —
  /// which is right on a five-beat phone and wrong on a four-beat one. With no
  /// biometric hardware the passphrase drew *2 of 4*, repeating the beat the
  /// native quiz had just been, and the last screen the user ever saw said
  /// *3 of 4* with the fourth dot unlit (`ux-auditor` BLOCK, UX-R6).
  ///
  /// The two native beats always happen, so the Flutter beats are 3, 4 and 5
  /// — zero-based 2, 3, 4 — whatever the total turns out to be.
  static const int _beatPassphrase = 2;
  static const int _beatExtraWord = 3;
  static const int _beatEnrol = 4;

  Widget _bar(int index) => KvTopBar(
    title: 'Create wallet',
    centre: KvSteps(
      // A four-beat phone never reaches the enrol beat, so the clamp is a
      // belt on an assertion rather than a correction of a real reading.
      count: _steps,
      index: index >= _steps ? _steps - 1 : index,
    ),
    // The passphrase and extra-word beats are the last place backing out is
    // still free — the ceremony is held in Rust and `dispose` abandons it. At
    // the enrol beat the wallet exists, and `null` draws the chevron in
    // `etch`: the way out is closed and the control says so rather than
    // looking live (BG-12).
    onBack: _step == _Step.enrolling ? null : _handleBack,
  );

  /// The screen's own scaffold: ground, bar, clamped column, pinned foot.
  /// The ceremony's page, on the shared [KvCeremonyPage] shape (UX-R7) —
  /// this method now supplies only the two things that are this screen's: the
  /// step bar, and the secret guard around it.
  Widget _page({
    required int step,
    required List<Widget> children,
    Widget? foot,
    Widget? bleed,
    bool centred = false,
    VoidCallback? onTapOutside,
    bool guarded = true,
    String? guardTitle,
  }) {
    final page = KvCeremonyPage(
      bar: _bar(step),
      foot: foot,
      bleed: bleed,
      centred: centred,
      onTapOutside: onTapOutside,
      children: children,
    );
    if (!guarded) return page;
    return SecretScreenGuard(
      title: guardTitle,
      setSecure: widget.setSecure,
      checkAccessibility: widget.checkAccessibility,
      child: page,
    );
  }

  static const TextStyle _body = TextStyle(
    fontFamily: KvFont.ui,
    fontSize: 15,
    height: 22 / 15,
    color: KvColor.inkDim,
  );

  /// **A smaller register at `short`.** `display` is a phone-portrait rung; at
  /// 915 × 412 the body is ~42 dp and a 34 dp line with a descender is cut at
  /// the fold — type clipped through its glyphs, which is the thing BG-14
  /// refuses. §3a's `short` class is the chrome giving way, and this is the
  /// chrome: the heading keeps its job at `barTitle`'s size.
  /// One copy, on [KvCeremonyPage] (UX-R7). It was identical here, in
  /// `restore_screen` and in `passphrase_unlock_screen`.
  TextStyle get _headingStyle => KvCeremonyPage.headingStyle(context);

  Widget _heading(String text, {TextAlign align = TextAlign.start}) =>
      Text(text, style: _headingStyle, textAlign: align);

  /// **§3a's `short` class: phone landscape, where the chrome gives way.**
  ///
  /// The law's own row for `< 480` dp of height says *onboarding illustration
  /// discs drop*, and the reason generalises: at 915 × 412 a ceremony's bar,
  /// its pinned keyboard and its foot take 383 of the 412, leaving ~110 dp of
  /// body. Spent on a `display` heading and a four-line explainer, that body
  /// shows the user nothing they did not already know and hides the one thing
  /// the screen is about — the words they have entered.
  ///
  /// So at `short` the **explainer drops** and the heading stays. The
  /// explainer is the sentence you read once; the heading is what the screen
  /// is asking, and `O6`'s heading IS the question. Nothing is clipped either
  /// way — the body scrolls — this is about what the first 110 dp are spent
  /// on. Found in the 915 × 412 frame, which is the geometry that finds it.
  bool get _short => KvWindow.of(context).heightClass == KvHeightClass.short;

  Widget _sub(String text, {TextAlign align = TextAlign.start}) {
    if (_short) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: KvSpace.sm),
      child: Text(text, style: _body, textAlign: align),
    );
  }

  /// The reason beat, above the controls and scrolled into view by [_say].
  Widget _reason() {
    final message = _message;
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: KvSpace.m),
      child: Text(
        message,
        key: _messageKey,
        style: _body.copyWith(
          color: _messageIsWarning ? KvColor.warn : KvColor.inkDim,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: switch (_step) {
        _Step.preparing => _preparing(),
        _Step.passphrase => _passphraseStep(),
        _Step.extraWord => _extraWordStep(),
        _Step.enrolling => _enroll(),
      },
    );
  }

  Widget _preparing() => Scaffold(
    backgroundColor: KvColor.abyss,
    body: SafeArea(
      child: Column(
        children: [
          // **The indicator starts here, not three screens in.** The founder
          // found the dots first appearing on the passphrase step, because
          // everything before it was either this spinner or one of the two
          // native screens — so the ceremony seemed to begin at step 3 of 5.
          // The native pair now draw their own; this is the first beat.
          //
          // **Back stays off here, as it was.** `_bar` wires `_handleBack`,
          // and this screen is the window where `beginCreate` is in flight —
          // a back press across it would race the lane it is opening.
          KvTopBar(
            title: 'Create wallet',
            centre: KvSteps(count: _steps, index: 0),
            onBack: null,
          ),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const KvLoader(),
                  const SizedBox(height: KvSpace.l),
                  Text('Preparing your recovery words…', style: _body),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  // ── `O2 · Passphrase` ────────────────────────────────────────────────────

  /// `O2`'s wells. **Six rings on the PIN path, a growing run on the keyboard
  /// path** — a slot only draws empty when the app knows the total, which is
  /// exactly the difference between the two secrets (see [MaskedDots.slots]).
  Widget _wells() => MaskedDots(
    length: _passphrase.length,
    slots: _isPin ? _pinLength : null,
    emptyHint: 'Type it on the keyboard below',
  );

  /// **The render's number pad, and the pad the render does not draw.**
  ///
  /// `O2` draws six wells and a number pad; until D-312 this build drew one dot
  /// per character and the full-ASCII keyboard, because narrowing the wells to a
  /// million possibilities is a change to what they ACCEPT and that was never a
  /// design sitting's call. The founder made it — and made it a *choice*, which
  /// is why both pads are here rather than one replacing the other.
  ///
  /// Both are the same [KvKeypad] primitive (D-189). Neither goes near the
  /// system IME, and neither accumulates: a press emits one character into the
  /// buffer and the pad reads nothing back (INV-3).
  Widget _keypad() => _isPin
      // **The number pad keeps the gutter; the keyboard does not.** The founder
      // read a strip of ground down each side of the ALPHANUMERIC pad as
      // unfinished, and it is nearly full-width so the strip was all there was
      // to see. `O2`'s number pad is three wide keys and is drawn inset — at 4×
      // its leftmost cap starts where the content column does — so here the air
      // is the composition rather than a leftover (D-259).
      ? KvColumn(
          child: KvKeypad.pin(
            onChar: _busy ? (_) {} : _onPinChar,
            onBackspace: _busy ? () {} : _passphrase.backspace,
          ),
        )
      : SecretKeyboard(
          onChar: _busy ? (_) {} : _passphrase.appendChar,
          onBackspace: _busy ? () {} : _passphrase.backspace,
        );

  /// **A digit, and the sixth one commits.**
  ///
  /// `O2` has no commit control on the PIN path — six wells fill and the screen
  /// moves on, which is what every lock screen on the phone already does. The
  /// keyboard path keeps its `Next`, because an any-length secret has no moment
  /// the app can infer.
  void _onPinChar(String c) {
    if (_passphrase.length.value >= _pinLength) return;
    _passphrase.appendChar(c);
    if (_passphrase.length.value >= _pinLength) _advanceAfterPin();
  }

  Future<void> _advanceAfterPin() async {
    // The sixth well has to be SEEN filled before the screen changes. Committing
    // in the same frame as the keystroke reads as the app skipping a beat, and
    // on a pad that echoes nothing the wells are the only evidence a key
    // registered at all (BG-8).
    final instant = MediaQuery.disableAnimationsOf(context);
    await Future<void>.delayed(instant ? Duration.zero : KvMotion.fast);
    if (!mounted || !_isPin || _busy) return;
    // Backspaced inside the gap: the user changed their mind, and a commit
    // scheduled a frame ago must not overrule them.
    if (_passphrase.length.value < _pinLength) return;
    _submitPassphrase();
  }

  /// **Change the pad, and refuse the PIN where it would be a downgrade.**
  ///
  /// The check runs HERE, at the moment of choosing, and not only at the seal:
  /// finding out that a PIN is impossible while your twelve words are already
  /// written down is a worse place to learn it. Rust refuses it again at the
  /// seal (`binding_for`), because a rule that lives only in a screen is a rule
  /// the next screen will not have.
  Future<void> _setPad(vault_api.VaultInputKind pad) async {
    if (_busy || pad == _pad) return;
    if (pad == vault_api.VaultInputKind.digits) {
      final bound = await _bindingLane();
      if (!mounted) return;
      if (!bound) {
        _say(
          'This phone cannot lock a PIN to its own hardware, so six digits '
          'would be far easier to break than a passphrase. Keep the keyboard.',
          warning: true,
        );
        return;
      }
    }
    // A half-typed secret does not survive the pad that was typing it
    // (INV-1/3), and the two pads do not share an alphabet anyway.
    _passphrase.wipe();
    setState(() {
      _pad = pad;
      _message = null;
    });
  }

  /// Whether Rust refused the seal for the PIN's own shape or its binding —
  /// both are refusals only a different CHOICE resolves, never a retry.
  bool _isPinRefusal(Object e) =>
      displayError(e).contains('PIN cannot be used here') ||
      displayError(e).contains('anyone would try');

  /// BG-11: the label names what you GET, not the mechanism you operate.
  String get _padSwitchLabel =>
      _isPin ? 'Use a keyboard passphrase' : 'Use a 6-digit PIN';

  /// The offer of the other pad. One widget, two homes — the pinned foot
  /// everywhere there is room for it, the scrolling body at `short`.
  Widget _padSwitch() => Padding(
    padding: const EdgeInsets.only(top: KvSpace.s, bottom: KvSpace.sm),
    child: Center(
      child: KvTextAction(
        label: _padSwitchLabel,
        onTap: _busy
            ? null
            : () => _setPad(
                _isPin
                    ? vault_api.VaultInputKind.passphrase
                    : vault_api.VaultInputKind.digits,
              ),
      ),
    ),
  );

  Widget _passphraseStep() => _page(
    step: _beatPassphrase,
    guardTitle: _isPin ? 'your PIN' : 'your passphrase',
    children: [
      _heading('Choose an unlock passphrase'),
      _sub(
        _isPin
            // `O2`'s own lead sentence, with our tail: the render says "that
            // comes next" because it drew the passphrase BEFORE the words, and
            // this build draws the words first (§4 of the glass prompt).
            ? 'Six digits. It opens this app on this phone only — it is not '
                  'your recovery phrase; those are the words you have just '
                  'written down.'
            // **The keyboard branch does not claim the phone.** A PIN vault
            // is always device-bound — the seal refuses otherwise — so `O2`'s
            // *on this phone only* is true there. A passphrase vault seals
            // WITHOUT the binding when the Keystore is unavailable, and on
            // that phone the same sentence is false: the file plus the
            // passphrase opens the wallet anywhere. So this branch says only
            // what is always true (`consensus-auditor`, D-312).
            : 'It unlocks this app — it is not your recovery phrase; those '
                  'are the words you have just written down.',
      ),
      // **At `short` the wells ride the foot.** 412 dp of landscape less a bar
      // and a pinned keypad leaves the body ~60 dp: the heading was cut
      // through its glyphs at the viewport edge and the dot run never drew at
      // all — and on a keyboard that echoes nothing, the dots are the ONLY
      // signal a key registered (`ux-auditor` BLOCK, UX-R6; BG-8).
      if (!_short) ...[
        const SizedBox(height: KvSpace.xl),
        Center(child: _wells()),
      ],
      _reason(),
      if (_short) _padSwitch(),
    ],
    foot: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_short)
          Padding(
            padding: const EdgeInsets.only(bottom: KvSpace.sm),
            child: Center(child: _wells()),
          ),
        // **The commit sits above the keyboard, not under the wells.**
        //
        // `O2` has no commit control at all — it takes six digits and advances
        // itself on the sixth, which the PIN path now does. The keyboard
        // path's secret is any length, so there has to be a control that says
        // *done*, and the render cannot say where it goes. It goes where `O7`
        // puts the same decision: pinned above the keys, in the thumb arc
        // (BG-12), rather than 300 dp up the screen in the air the render
        // leaves between the wells and the pad.
        if (!_isPin)
          Padding(
            padding: const EdgeInsets.only(bottom: KvSpace.sm),
            child: KvAction(
              label: 'Next',
              primary: true,
              onTap: _submitPassphrase,
            ),
          ),
        // **Plain text, never a pill** — the same law the `O5` skip follows:
        // the way to the other pad does not compete with the act it is an
        // alternative to. On the PIN path it is the only control on the
        // screen, which is exactly what `O2` draws.
        //
        // **And it leaves the pinned foot at `short`.** 52 dp of target plus
        // its air is 64, and this screen's whole landscape budget is ~30: with
        // it in the foot, 915 × 412 overflowed by 34 dp at 1.0× and 75 at 1.3×
        // — on the one geometry whose previous overflow this file's own
        // comments record being cleared by stripping every scrap of padding
        // (`ux-auditor` BLOCK, D-312). At `short` it rides the body with the
        // reason beat instead, where it scrolls like everything else.
        if (!_short) _padSwitch(),
      ],
    ),
    // **The keypad is full-bleed; its caption is not.** See [_page]'s `bleed`.
    bleed: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _keypad(),
        // `O2` measured: `etch`, 12 dp, centred under the pad. It is the one
        // sentence that says why this keyboard looks unlike the phone's.
        // **It drops at `short`, and the heading is why.** 412 dp of
        // landscape less a bar, a pill and a 220 dp keypad leaves ~76: with
        // this line the screen's own heading scrolled out entirely and the
        // passphrase step said nothing about what it was asking for. Of the
        // two, the caption is the one whose subject is visible anyway — the
        // keyboard is on the glass, in the app, plainly not the phone's — and
        // the heading is the archetype's *one instruction*.
        //
        // **`inkMeta`, and this is the one place the build wins over the
        // render.** `O2` sets this line in `etch`, which measures **2.53:1 on
        // `abyss`** — under the 3:1 non-text floor and far under 4.5. `etch` is
        // decorative by definition (§1.3), and this string is the screen's
        // sovereignty disclosure: it is the sentence that says why this
        // keyboard looks unlike the phone's. §4's `KvSectionHeader` gloss row
        // already settled the identical case in the same words — *`etch` on an
        // information-bearing string is a BG-14 refusal* (`ux-auditor` BLOCK,
        // UX-R6).
        if (!_short)
          KvColumn(
            child: const Padding(
              padding: EdgeInsets.only(bottom: KvSpace.s),
              child: Text(
                'In-app keypad — the system keyboard never sees this',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 12,
                  height: 16 / 12,
                  color: KvColor.inkMeta,
                ),
              ),
            ),
          ),
      ],
    ),
  );

  // ── `O5 · 13th | 25th word` ──────────────────────────────────────────────

  /// **One screen, two fields, one act — which is what the render draws.**
  ///
  /// Three findings of the founder's, and they are one interaction rather than
  /// three (D-312 §4):
  ///
  /// * **F17 — both boxes are on the glass from the start, disabled.** They are
  ///   what tells you *this word gets typed twice* BEFORE you have committed to
  ///   typing it once. Showing them only after the switch meant the screen kept
  ///   that until it was too late to matter.
  /// * **F18 — the keypad is collapsed until a box is tapped.** Ours is not a
  ///   system IME, so this is a layout contract to draw rather than a flag to
  ///   set: [_field] holds the focus, tapping a field takes it, and tapping the
  ///   body or scrolling gives it back.
  /// * **F19 — the primary is dead until the second box matches the first.**
  ///   See [_extraWordReady], and [_extraWordHint] for what replaced the old
  ///   wipe-both-and-bounce.
  ///
  /// **And the render's eye is built now** (§3), which it was not, on an INV-3
  /// fence modelled on D-039/D-136 — [SecretByteBuffer.revealWhileHeld] carries
  /// the whole argument. The double entry stays beside it: the founder asked
  /// for both, and they catch different mistakes. The eye catches a word you
  /// typed wrong twice the same way; the second box catches a word your thumb
  /// slipped on once.
  Widget _extraWordStep() {
    final buffer = _field == 1 ? _extraWordConfirm : _extraWord;
    return _page(
      step: _beatExtraWord,
      guardTitle: 'your recovery words',
      // **Centred.** With the switch off this screen is a heading, a toggle and
      // a lot of ground; the founder asked for the toggle, the fields and the
      // notice to sit in the middle of it rather than pinned under the
      // heading. With the switch on the block outgrows the room and the same
      // slot simply scrolls (see [_noticeKey]).
      centred: true,
      // Anywhere that is not a field drops the keyboard — F18's other half.
      // Without it the pad could be raised and never lowered, which is worse
      // than one that is always up.
      onTapOutside: _field == null ? null : () => setState(() => _field = null),
      children: [
        _heading(extraWordHeading(_wordCount)),
        _sub(extraWordExplainer(_wordCount)),
        const SizedBox(height: KvSpace.l),
        KvRowContainer(
          children: [
            KvToggle(
              on: _use25th,
              title: extraWordToggle(_wordCount),
              sub: 'Also called a BIP39 passphrase',
              onChanged: _busy ? null : _setUseExtraWord,
              // A disabled control always says why, in words (BG-12).
              disabledReason: _busy
                  ? 'Your wallet is being created — this can no longer change.'
                  : null,
            ),
          ],
        ),
        // **`KvSectionHeader` owns the air around a caps label.** A
        // `SizedBox` → `KvRuledLabel` → `SizedBox` sandwich is the shape
        // D-277 named as the defect — three stacked gap constants per label
        // — and a caller adds none of its own.
        KvSectionHeader('Your ${extraWordOrdinal(_wordCount)} word'),
        KvSecretField(
          length: _extraWord.length,
          active: _field == 0,
          enabled: _use25th && !_busy,
          placeholder: 'Type it here',
          onTap: () => _focusField(0),
          revealed: _revealedExtra,
          // The eye is on the FIRST field only, which is where `O5` draws it.
          // On the second it would defeat the second box's whole job: a copy
          // you can read off the screen above it is not a second entry.
          onReveal: _use25th && !_busy
              ? (on) => setState(() {
                  _revealedExtra = on && !_extraWord.isEmpty
                      ? _extraWord.revealWhileHeld()
                      : null;
                })
              : null,
        ),
        const SizedBox(height: KvSpace.s10),
        KvSecretField(
          length: _extraWordConfirm.length,
          active: _field == 1,
          enabled: _use25th && !_busy,
          placeholder: 'Type it again',
          onTap: () => _focusField(1),
        ),
        // **The amber plate belongs to the word, so it waits for the word.**
        //
        // F17 asked for the two BOXES up front — they are what says *this gets
        // typed twice* before you commit to typing it once. Lifting the
        // warning out with them made the screen caution, in `warnTint`, about
        // a word nobody had opted into: BG-4's own test is *would this mark
        // still be drawn if the content changed so it were false*, and it was
        // being drawn exactly then (`ux-auditor`, D-312). `O5` draws the plate
        // only in the switch-on state.
        //
        // **It eases open** (BG-24): a plate arriving between two frames is a
        // section appearing with no motion that accounts for it.
        AnimatedSize(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : KvMotion.calm,
          curve: KvMotion.curve,
          alignment: Alignment.topCenter,
          child: !_use25th
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: KvSpace.m),
                  // His wording, on glass. "Separately" is the load-bearing
                  // change: the old line said *the same paper*, which is
                  // exactly the mistake — an extra word written beside the
                  // twelve it is supposed to protect defeats the decoy
                  // property entirely (vault_architecture §4).
                  child: KvNotice(
                    key: _noticeKey,
                    lead:
                        'Write it down separately apart from the words. '
                        'Do not forget it!',
                    text: 'KaspaVerse cannot recover it.',
                    tail: 'Case and spaces matter!',
                  ),
                ),
        ),
        _reason(),
      ],
      // **Both acts are pinned, like every other screen in this group.** They
      // were in the scrolling body while the keyboard was pinned under them,
      // so `Continue with 13th word` and `Skip` were off-screen at four of the
      // five frames — and at the floor and at `short` the visible body ended
      // mid-way through the switch's sub-line, leaving a keyboard with no
      // field on the glass to type into. Its two siblings and all three of
      // restore's steps already did the opposite, which is what made it a
      // BG-21 finding as well as a BG-12 one (`ux-auditor` BLOCK, UX-R6).
      foot: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KvAction(
            label: _primaryLabel(),
            primary: true,
            onTap: _busy ? () {} : _advanceExtraWord,
            // F19: dead until the two boxes agree, and it says which of the
            // two things it is waiting for rather than simply refusing.
            disabledReason: _extraWordReason,
          ),
          if (_use25th)
            // **Plain text, never a pill.** Founder ruling, carried into this
            // render: the way past an optional step does not compete with the
            // act it is optional to.
            Center(
              child: KvTextAction(
                label: extraWordSkip(_wordCount),
                onTap: _busy ? null : _skipExtraWord,
              ),
            )
          else
            const SizedBox(height: KvSpace.sm),
        ],
      ),
      // F18: no field has the keyboard, so there is no keyboard. `O5` draws
      // the screen this way and it is the only way the notice fits above the
      // fold on a 640 dp phone.
      bleed: _field == null
          ? null
          : SecretKeyboard(
              onChar: _busy
                  ? (_) {}
                  : (c) => setState(() => buffer.appendChar(c)),
              onBackspace: _busy ? () {} : () => setState(buffer.backspace),
            ),
    );
  }

  /// BG-11: the label names the act. With the switch on there is exactly ONE
  /// act left on this screen, so `O5`'s own label is the whole of it — the old
  /// two-step flow needed a `Continue` and then a `Create wallet` because it
  /// had two.
  String _primaryLabel() {
    if (_busy) return 'Creating…';
    if (!_use25th) return 'Continue — $_wordCount words only';
    return extraWordContinue(_wordCount);
  }

  void _setUseExtraWord(bool on) {
    // Turning it off drops whatever was typed. A half-entered secret does not
    // survive the switch that says there is no secret (INV-1/3).
    if (!on) {
      _extraWord.wipe();
      _extraWordConfirm.wipe();
    }
    setState(() {
      _use25th = on;
      _step = _Step.extraWord;
      _field = null; // F18: the pad stays down until a box is tapped
      _revealedExtra = null;
      _message = null;
    });
    if (!on) return;
    _keepTheNoticeInView();
  }

  /// **Bring the amber plate back into view after anything shrinks the
  /// viewport.**
  ///
  /// His finding, and then my own regression of it. He asked for the notice to
  /// be scrolled to when the switch is thrown, *"so whats above it stays in
  /// view"* — and F18 then made the keypad rise on a field tap, which takes
  /// ~236 dp out of the same viewport and pushes the plate straight back under
  /// the pinned foot. So both events call this, not just the switch: the plate
  /// is the one sentence on the screen that says the word cannot be recovered,
  /// and it does not get to be the thing that scrolls away.
  ///
  /// Seated at the BOTTOM of the viewport (`alignment: 1`), so the fields and
  /// the switch above it come into view with it rather than scrolling off.
  void _keepTheNoticeInView() {
    // After the frame that builds the fields, and after `AnimatedSize` has
    // settled — asking to scroll to a box that is still growing lands short.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Read the accessibility flag BEFORE the gap — the context is not ours
      // to use on the far side of an await.
      final instant = MediaQuery.disableAnimationsOf(context);
      await Future<void>.delayed(instant ? Duration.zero : KvMotion.calm);
      // `box.mounted`, not this State's — the context being scrolled to is
      // the one that has to still be in the tree.
      final box = _noticeKey.currentContext;
      if (box == null || !box.mounted) return;
      await Scrollable.ensureVisible(
        box,
        alignment: 1,
        duration: instant ? Duration.zero : KvMotion.calm,
        curve: KvMotion.curve,
      );
    });
  }

  /// Take the keyboard, and keep the notice where he asked for it.
  void _focusField(int which) {
    final raising = _field == null;
    setState(() => _field = which);
    if (raising && _use25th) _keepTheNoticeInView();
  }

  void _advanceExtraWord() {
    if (!_use25th) {
      _extraWord.wipe();
      _extraWordConfirm.wipe();
      _doSeal();
      return;
    }
    if (!_extraWordReady) return; // the pill is dead; nothing to say twice
    _doSeal();
  }

  void _skipExtraWord() {
    _extraWordConfirm.wipe();
    _extraWord.wipe();
    _revealedExtra = null;
    _doSeal();
  }

  // ── `O6 · Biometrics` ────────────────────────────────────────────────────

  /// **Outside the guard, and the chrome says the wallet exists.**
  ///
  /// The step runs after the seal and holds no secret; BG-10's FLAG_SECURE list
  /// is locked at five screens (D-028) and a sixth would exclude screen-reader
  /// users from a step with nothing to hide. Its mirror in `restore_screen` is
  /// outside too, and the two ceremonies must not disagree about whether the
  /// identical step is a secret screen.
  Widget _enroll() {
    final ready = _biometricStatus == biometricReady;
    return _page(
      step: _beatEnrol,
      guarded: false,
      centred: true,
      children: [
        // §3a's own words for this class: *onboarding illustration discs
        // drop*. They are 104 dp of picture on a 412 dp screen whose question
        // and two answers are what matter.
        if (!_short) ...[
          const SizedBox(height: KvSpace.xl),
          const Center(child: CeremonyMarkPair()),
          const SizedBox(height: KvSpace.xl),
        ],
        SizedBox(
          width: double.infinity,
          child: _heading(
            ready ? 'Open with biometrics?' : 'Biometrics, when you want them',
            align: TextAlign.center,
          ),
        ),
        // **Nothing under the question when the answer is a yes/no.**
        // *Open with biometrics?* is the whole ask, and the founder said so on
        // glass. The paragraph that used to sit here explained that keys stay
        // in hardware either way — true, and already the promise the whole app
        // makes, so restating it under a two-button choice only slowed the
        // choice down. The `not ready` copy STAYS: that one is actionable
        // (*enrol a fingerprint in Android Settings*) and is the only thing on
        // the screen that says why there is no offer.
        if (!ready)
          SizedBox(
            width: double.infinity,
            child: _sub(
              biometricUnavailableCopy(_biometricStatus),
              align: TextAlign.center,
            ),
          ),
        _reason(),
      ],
      // The two ways on live in the thumb arc, which is where `O6` draws them
      // and where the rest of this group now puts its commit.
      foot: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ready)
            KvAction(
              label: _busy ? 'Setting up…' : 'Use biometrics',
              primary: true,
              onTap: _busy ? () {} : _enrollNow,
              disabledReason: _busy ? 'Setting up…' : null,
            ),
          Center(
            child: KvTextAction(
              label: ready ? 'Passphrase only' : 'Continue',
              onTap: _busy ? null : _finish,
            ),
          ),
          const SizedBox(height: KvSpace.s),
        ],
      ),
    );
  }
}
