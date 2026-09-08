import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/vault_service.dart';
import 'biometric_copy.dart';
import 'extra_word_copy.dart';
import 'secret/masked_dots.dart';
import 'secret/secret_byte_buffer.dart';
import 'secret/secret_keyboard.dart';
import 'secret/secret_screen_guard.dart';
import 'secret/word_parts.dart';
import 'theme/kv_window.dart';
import 'theme/tokens.dart';
import 'widgets/ceremony_mark.dart';
import 'widgets/kv_chrome.dart';
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
  final Future<void> Function(Uint8List passphrase, Uint8List extraWord)? seal;

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

  /// Forwarded to [SecretScreenGuard] (test seams).
  final Future<bool> Function()? checkAccessibility;
  final Future<void> Function({required bool enable})? setSecure;

  @override
  State<CreateScreen> createState() => _CreateScreenState();
}

/// **How many recovery words the create ceremony draws.**
///
/// Twelve, decided by `RevealActivity` (D-037) and carried here because every
/// string on `O5` has to name the extra word by its ORDINAL — a 13th word for
/// twelve, a 25th for twenty-four — and nothing on the channel reports it.
/// `create_screen_test` pins the strings this constant produces, so a native
/// change to 24 that forgot this line fails a test rather than telling a user
/// to write down a 13th word for a phrase with twenty-four.
const int createWordCount = 12;

enum _Step { preparing, passphrase, extraWord, extraWordConfirm, enrolling }

class _CreateScreenState extends State<CreateScreen> {
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

  // ── seams resolved to the real lanes ─────────────────────────────────────
  Future<void> Function() get _beginLane =>
      widget.begin ??
      () async {
        // Drop any stale held ceremony, then begin fresh (idempotent abandon).
        await VaultService.instance.abandonCreate();
        await VaultService.instance.beginCreate();
      };
  Future<bool> Function() get _revealLane =>
      widget.reveal ?? VaultService.instance.revealAndVerify;
  Future<void> Function() get _abandonLane =>
      widget.abandon ?? VaultService.instance.abandonCreate;
  Future<void> Function(Uint8List, Uint8List) get _sealLane =>
      widget.seal ?? (p, x) => VaultService.instance.sealAndPersist(p, x);
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _runReveal());
  }

  @override
  void dispose() {
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
      unawaited(_countSteps());
      await _beginLane();
      final verified = await _revealLane();
      if (!mounted) return;
      if (verified) {
        setState(() => _step = _Step.passphrase);
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
    if (_passphrase.isEmpty) {
      _say('Enter a passphrase first.');
      return;
    }
    setState(() {
      _step = _Step.extraWord;
      _message = null;
    });
  }

  /// Leaving the extra-word entry. Empty is not sealed from here — `Skip` owns
  /// that path and says so — so the primary never means two different things.
  /// A non-empty word must be typed a second time before it can determine a
  /// seed. Mirrors [_submitPassphrase]: the button stays live and an invalid
  /// state answers with a message rather than a dead control.
  void _submitExtraWord() {
    if (_extraWord.isEmpty) {
      _say('Enter the extra word, or tap Skip.');
      return;
    }
    setState(() {
      _step = _Step.extraWordConfirm;
      _message = null;
    });
  }

  /// The gate. On a mismatch BOTH buffers are wiped and the user re-enters from
  /// the start: a mismatch means one of the two is wrong and neither the user
  /// nor the app can see which, so letting them retype only the confirm would
  /// invite them to "correct" the copy until it matches a first entry that was
  /// itself the typo. Nothing is compared or held as a Dart `String`.
  void _confirmExtraWord() {
    if (!_extraWord.matches(_extraWordConfirm)) {
      _extraWord.wipe();
      _extraWordConfirm.wipe();
      setState(() => _step = _Step.extraWord);
      // Says what Skip now MEANS, because by this point the entry step has
      // already told them to write the word down. Bouncing back puts an
      // unchanged "Skip" under their thumb, and taking it would seal a wallet
      // with no extra word while their paper record says there is one — a
      // mismatch they could not detect and could not test, since there is no
      // delete path and the vault refuses to seal over an existing blob
      // (ux-auditor, BG-6).
      _say(
        "Those didn't match. Enter the extra word again, then confirm it — or "
        'tap Skip to create your wallet with no extra word, and cross it off '
        'your backup.',
        warning: true,
      );
      return;
    }
    _doSeal();
  }

  Future<void> _doSeal() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await _sealLane(_passphrase.snapshot(), _extraWord.snapshot());
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

  void _handleBack() {
    switch (_step) {
      case _Step.preparing:
      case _Step.passphrase:
        Navigator.of(
          context,
        ).pop(); // leave create (dispose abandons if !sealed)
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
        setState(() {
          _step = _Step.passphrase;
          _message = null;
        });
      case _Step.extraWordConfirm:
        // Back to the entry to re-type it; the half-typed confirm is a secret
        // and does not survive the step it belongs to.
        _extraWordConfirm.wipe();
        setState(() {
          _step = _Step.extraWord;
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
  Widget _page({
    required int step,
    required List<Widget> children,
    Widget? foot,
    bool guarded = true,
    String? guardTitle,
  }) {
    final page = Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        child: Column(
          children: [
            _bar(step),
            Expanded(
              child: KvColumn(
                child: SingleChildScrollView(
                  // **No air at `short`.** 48 dp of top-and-bottom padding is
                  // right on a phone and is more than the whole body at
                  // 915 × 412, where a bar, a pinned pill and a 220 dp keypad
                  // leave ~42: with it the heading scrolled out and the
                  // passphrase step said nothing about what it was asking for
                  // (`ux-auditor` BLOCK, UX-R6).
                  padding: EdgeInsets.symmetric(
                    vertical: _short ? 0 : KvSpace.l,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: children,
                  ),
                ),
              ),
            ),
            // The keyboard is inside the column's gutter, not full-bleed:
            // `O7` seats its caps at x 29 against content at 25, which is
            // `KvKeypad`'s own 4 dp of side air and nothing more. A part
            // inside a clamped column owns no horizontal air of its own
            // (L195).
            if (foot != null) KvColumn(child: foot),
          ],
        ),
      ),
    );
    if (!guarded) return page;
    return SecretScreenGuard(
      title: guardTitle,
      setSecure: widget.setSecure,
      checkAccessibility: widget.checkAccessibility,
      child: page,
    );
  }

  /// §2 `display`, the onboarding rung: Jakarta 30 / 34, 800, −0.025em.
  static const TextStyle _display = TextStyle(
    fontFamily: KvFont.ui,
    fontSize: 30,
    height: 34 / 30,
    fontWeight: FontWeight.w800,
    fontVariations: KvWeight.w800,
    letterSpacing: -0.75,
    color: KvColor.ink,
  );

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
  TextStyle get _headingStyle => _short
      ? const TextStyle(
          fontFamily: KvFont.ui,
          fontSize: 18,
          height: 22 / 18,
          fontWeight: FontWeight.w700,
          fontVariations: KvWeight.w700,
          letterSpacing: -0.18,
          color: KvColor.ink,
        )
      : _display;

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
        _Step.extraWord || _Step.extraWordConfirm => _extraWordStep(),
        _Step.enrolling => _enroll(),
      },
    );
  }

  Widget _preparing() => Scaffold(
    backgroundColor: KvColor.abyss,
    body: SafeArea(
      child: Column(
        children: [
          KvTopBar(title: 'Create wallet', onBack: null),
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

  /// `O2`'s wells: one 18 dp `primary` disc a character, the render's own.
  Widget _wells() => MaskedDots(
    length: _passphrase.length,
    emptyHint: 'Type it on the keyboard below',
  );

  /// **The render draws six wells and a number pad; this build draws one dot
  /// per character and the full-ASCII keyboard, and that is deliberate.**
  ///
  /// `O2`'s sub-line reads *Six digits*, which is a six-digit numeric unlock
  /// code. The passphrase this screen actually takes is any length and any
  /// printable ASCII — it is the Argon2id input that wraps the seed — and
  /// narrowing it to a million possibilities is a change to what the wells
  /// ACCEPT, which is the one thing about this screen a design sitting may not
  /// move. The render's FORM is kept: the same 18 dp `primary` wells it draws
  /// filled, the same in-app pad, the same footer sentence. Only the fixed six
  /// empty rings are absent, because with no target length an empty well would
  /// be a slot that does not exist.
  Widget _passphraseStep() => _page(
    step: _beatPassphrase,
    guardTitle: 'your passphrase',
    children: [
      _heading('Choose an unlock passphrase'),
      _sub(
        'It opens this app on this phone only — it is not your recovery '
        'phrase; those are the words you have just written down.',
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
        // itself on the sixth. This build's passphrase is any length, so there
        // has to be a control that says *done*, and the render cannot say
        // where it goes. It goes where `O7` puts the same decision: pinned
        // above the keys, in the thumb arc (BG-12), rather than 300 dp up the
        // screen in the air the render leaves between the wells and the pad.
        Padding(
          padding: const EdgeInsets.only(bottom: KvSpace.sm),
          child: KvAction(
            label: 'Next',
            primary: true,
            onTap: _submitPassphrase,
          ),
        ),
        SecretKeyboard(
          onChar: _busy ? (_) {} : _passphrase.appendChar,
          onBackspace: _busy ? () {} : _passphrase.backspace,
        ),
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
          const Padding(
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
      ],
    ),
  );

  // ── `O5 · 13th | 25th word` ──────────────────────────────────────────────

  /// **One screen, two fields — which is what the render draws.**
  ///
  /// The build has two steps here and keeps them: `extraWord` types the word,
  /// `extraWordConfirm` types it again, and a mismatch wipes BOTH and returns
  /// to the first. Nothing about that moves. What changes is that the second
  /// field is now on the glass from the start, quiet, so the screen says
  /// *this word gets typed twice* before the first keystroke rather than
  /// after it.
  ///
  /// **The render's reveal eye is not built, and INV-3 is the reason.**
  /// `SecretByteBuffer` exposes a length and nothing else — that is the whole
  /// point of the class — so painting the typed characters would mean the
  /// extra word becoming a Dart `String`. The check the eye would have given
  /// is already here and stronger: the word is typed a second time and
  /// compared in place, which catches a typo the eye would have invited the
  /// user to read past.
  Widget _extraWordStep() {
    final confirming = _step == _Step.extraWordConfirm;
    final buffer = confirming ? _extraWordConfirm : _extraWord;
    return _page(
      step: _beatExtraWord,
      guardTitle: 'your recovery words',
      children: [
        _heading(extraWordHeading(createWordCount)),
        _sub(extraWordExplainer(createWordCount)),
        const SizedBox(height: KvSpace.l),
        KvRowContainer(
          children: [
            KvToggle(
              on: _use25th,
              title: extraWordToggle(createWordCount),
              sub: 'Also called a BIP39 passphrase',
              onChanged: _busy ? null : _setUseExtraWord,
              // A disabled control always says why, in words (BG-12).
              disabledReason: _busy
                  ? 'Your wallet is being created — this can no longer change.'
                  : null,
            ),
          ],
        ),
        // **It eases open** (BG-24): a caps label, two 56 dp fields and the
        // notice plate arriving between two frames is a section appearing with
        // no motion that accounts for it. Same idiom the node screen's own
        // toggle-revealed section already uses.
        AnimatedSize(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : KvMotion.calm,
          curve: KvMotion.curve,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_use25th) ...[
                // **`KvSectionHeader` owns the air around a caps label.** A
                // `SizedBox` → `KvRuledLabel` → `SizedBox` sandwich is the
                // shape D-277 named as the defect — three stacked gap
                // constants per label — and a caller adds none of its own.
                KvSectionHeader(
                  'Your ${extraWordOrdinal(createWordCount)} word',
                ),
                KvSecretField(
                  length: _extraWord.length,
                  active: !confirming,
                  placeholder: 'Type it here',
                ),
                const SizedBox(height: KvSpace.s10),
                KvSecretField(
                  length: _extraWordConfirm.length,
                  active: confirming,
                  placeholder: 'Type it again',
                ),
                const SizedBox(height: KvSpace.m),
                const KvNotice(
                  lead: 'Write it on the same paper, apart from the words.',
                  text: 'KaspaVerse cannot recover it. Case and spaces matter.',
                ),
              ],
            ],
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
            label: _primaryLabel(confirming),
            primary: true,
            onTap: _busy ? () {} : () => _advanceExtraWord(confirming),
            disabledReason: _busy ? 'Creating your wallet…' : null,
          ),
          if (_use25th)
            // **Plain text, never a pill.** Founder ruling, carried into this
            // render: the way past an optional step does not compete with the
            // act it is optional to.
            Center(
              child: KvTextAction(
                label: extraWordSkip(createWordCount),
                onTap: _busy ? null : _skipExtraWord,
              ),
            )
          else
            const SizedBox(height: KvSpace.sm),
          // **Inert while the seal is in flight.** `_doSeal` wipes all three
          // buffers the instant the seal returns and then `await`s the
          // biometric probe with this step still mounted; an ungated key press
          // writes extra-word bytes back in AFTER the wipe, across the
          // unbounded, background-spanning enrol window the early wipe exists
          // to close (`ffi-leak-auditor`, UX-R6).
          if (_use25th)
            SecretKeyboard(
              onChar: _busy ? (_) {} : buffer.appendChar,
              onBackspace: _busy ? () {} : buffer.backspace,
            ),
        ],
      ),
    );
  }

  String _primaryLabel(bool confirming) {
    if (_busy) return 'Creating…';
    if (!_use25th) return 'Continue — $createWordCount words only';
    return confirming ? 'Create wallet' : extraWordContinue(createWordCount);
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
      _message = null;
    });
  }

  void _advanceExtraWord(bool confirming) {
    if (!_use25th) {
      _extraWord.wipe();
      _doSeal();
      return;
    }
    confirming ? _confirmExtraWord() : _submitExtraWord();
  }

  void _skipExtraWord() {
    _extraWordConfirm.wipe();
    _extraWord.wipe();
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
        SizedBox(
          width: double.infinity,
          child: _sub(
            ready
                ? 'Face, fingerprint — whatever this phone offers. Your keys '
                      'stay sealed in its hardware either way; this only opens '
                      'the app faster.'
                : biometricUnavailableCopy(_biometricStatus),
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
