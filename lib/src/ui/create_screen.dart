import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/vault_service.dart';
import 'biometric_copy.dart';
import 'secret/masked_dots.dart';
import 'secret/secret_byte_buffer.dart';
import 'secret/secret_keyboard.dart';
import 'secret/secret_screen_guard.dart';
import 'theme/tokens.dart';
import 'widgets/ceremony_mark.dart';
import 'widgets/kv_loader.dart';

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

  Future<void> _runReveal() async {
    try {
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
      // Decelerate, no overshoot — a custody surface (DS-5).
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
      // (ux-auditor, DS-3).
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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: switch (_step) {
        _Step.preparing => _preparing(),
        _Step.passphrase => _secretStep(
          title: 'your passphrase',
          heading: 'Set a passphrase',
          subtitle:
              'This encrypts your wallet on this device. Enter it each time to '
              'unlock — choose something only you know.',
          buffer: _passphrase,
          mark: Icons.lock_outline, // unlocks the app ON THIS DEVICE
          primaryLabel: 'Next',
          onPrimary: _submitPassphrase,
        ),
        _Step.extraWord => _secretStep(
          title: 'your recovery words',
          heading: 'Add an extra word? (optional)',
          subtitle:
              'An advanced option: a 13th word, known only to you, adds another '
              'layer. You will need it every time you restore, so write it down '
              'too. Leave it empty to skip. (Letters, digits and symbols only.)',
          buffer: _extraWord,
          // Keyed and warning-tinted: this one becomes part of the wallet, and
          // getting it wrong is the failure the confirm step exists to catch.
          mark: Icons.vpn_key_outlined,
          markTint: KvColor.warning,
          primaryLabel: _busy ? 'Creating…' : 'Next',
          onPrimary: _busy ? null : _submitExtraWord,
          secondaryLabel: 'Skip',
          onSecondary: _busy
              ? null
              : () {
                  _extraWord.wipe();
                  _doSeal();
                },
        ),
        _Step.extraWordConfirm => _secretStep(
          title: 'your recovery words',
          heading: 'Type the extra word again',
          // Read it BACK from the written record, not from memory. Two entries
          // typed seconds apart from the same short-term memory prove only that
          // the user can repeat themselves — and a wallet is restored from what
          // they wrote down, not from what they remembered this minute. Asking
          // them to read it back is the difference between checking the typing
          // and checking the backup, and it costs nothing.
          subtitle:
              'Read it back from where you wrote it down and type it again. '
              'This word becomes part of your wallet, so if what you wrote is '
              'not what you typed, those words will not bring your wallet back.',
          buffer: _extraWordConfirm,
          mark: Icons.vpn_key_outlined, // same secret, same mark
          markTint: KvColor.warning,
          primaryLabel: _busy ? 'Creating…' : 'Create wallet',
          onPrimary: _busy ? null : _confirmExtraWord,
        ),
        _Step.enrolling => _enroll(),
      },
    );
  }

  Widget _preparing() {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create wallet'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const KvLoader(),
              const SizedBox(height: KvSpace.l),
              Text(
                'Preparing your recovery words…',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: KvColor.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _secretStep({
    required String title,
    required String heading,
    required String subtitle,
    required SecretByteBuffer buffer,
    required String primaryLabel,
    required VoidCallback? onPrimary,
    // The two secret steps were the same screen twice — same chrome, same dots,
    // same keyboard — so nothing but the heading said whether you were typing
    // the thing that unlocks this phone or the thing your written backup
    // depends on. The mark carries that difference at a glance.
    required IconData mark,
    Color? markTint,
    String? secondaryLabel,
    VoidCallback? onSecondary,
  }) {
    final theme = Theme.of(context);
    return SecretScreenGuard(
      title: title,
      setSecure: widget.setSecure,
      checkAccessibility: widget.checkAccessibility,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Create wallet'),
          leading: BackButton(onPressed: _handleBack),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(KvSpace.gutter),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // INLINE with the heading, not a disc above it. The
                        // disc read well and cost ~88 dp, which pushed `Skip`
                        // off a 600 dp-tall viewport — the same below-the-fold
                        // class this screen was just fixed for. A tinted glyph
                        // beside the title separates the two steps at a glance
                        // and costs no vertical space at all.
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            ExcludeSemantics(
                              child: Icon(
                                mark,
                                size: KvSpace.l,
                                color: markTint ?? KvColor.primaryMuted,
                              ),
                            ),
                            const SizedBox(width: KvSpace.s),
                            Flexible(
                              child: Text(
                                heading,
                                style: theme.textTheme.headlineSmall,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: KvSpace.s),
                        Text(
                          subtitle,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: KvColor.textSecondary,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: KvSpace.l),
                        MaskedDots(length: buffer.length),
                        // The reason beat sits ABOVE the buttons, not after
                        // them. Below, it started ~416 dp down a 360 dp
                        // viewport (the keyboard is fixed and takes 224 dp of
                        // the 584), so on a 360×640 handset it was off-screen
                        // at 1.0× and on the V60 at ~1.3×. A user who mistyped
                        // the confirm saw the step revert and the dots reset
                        // with nothing saying why — verbatim the defect
                        // 3227d32 was written to end, and the same class as
                        // the enroll-overflow fix further down this file.
                        // Moving it here also lands "Enter a passphrase first."
                        // and "or tap Skip", which had the same problem
                        // (ux-auditor, DS-3/§12).
                        if (_message != null) ...[
                          const SizedBox(height: KvSpace.m),
                          Text(
                            _message!,
                            key: _messageKey,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: _messageIsWarning
                                  ? KvColor.warning
                                  : KvColor.textSecondary,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                        const SizedBox(height: KvSpace.l),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: onPrimary,
                            child: Text(primaryLabel),
                          ),
                        ),
                        if (secondaryLabel != null) ...[
                          const SizedBox(height: KvSpace.s),
                          TextButton(
                            onPressed: onSecondary,
                            child: Text(secondaryLabel),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              SecretKeyboard(
                onChar: buffer.appendChar,
                onBackspace: buffer.backspace,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _enroll() {
    final theme = Theme.of(context);
    // `none_enrolled` reaches this step deliberately: nothing is broken, the
    // phone simply has no fingerprint registered yet, and the user can fix that
    // in a minute. Showing the step with the reason beats vanishing — and it
    // names Settings, so "Not now" is never a one-way door again.
    final ready = _biometricStatus == biometricReady;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Almost done'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        // Scrollable. At 1.3× on a 360×640 phone this step overflowed by
        // 206 px with a failure message showing — `enrollFailureCopy` AND
        // the "Not now" exit laid out entirely off-screen, so tapping
        // Enable and failing produced no visible change at all. That is
        // verbatim the defect the honest-degrade fix was written to end
        // (ux-auditor, Track 2 re-audit).
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(KvSpace.gutter),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - KvSpace.gutter * 2,
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CeremonyMark(Icons.fingerprint),
                    const SizedBox(height: KvSpace.l),
                    Text(
                      ready
                          ? 'Unlock with your fingerprint?'
                          : 'Fingerprint unlock, when you want it',
                      style: theme.textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: KvSpace.s),
                    Text(
                      ready
                          ? 'Add a fingerprint to unlock quickly next time. Your '
                                'passphrase still works as a backup.'
                          : biometricUnavailableCopy(_biometricStatus),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: KvColor.textSecondary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    // Above the buttons and key'd, the same anatomy as
                    // `_secretStep` — this step overflowed by 206 px once
                    // already (Track 2), and a reason laid out after the
                    // controls is the shape that hid it.
                    if (_message != null) ...[
                      const SizedBox(height: KvSpace.m),
                      Text(
                        _message!,
                        key: _messageKey,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: KvColor.textSecondary,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: KvSpace.xl),
                    if (ready)
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _busy ? null : _enrollNow,
                          child: Text(
                            _busy ? 'Setting up…' : 'Enable fingerprint unlock',
                          ),
                        ),
                      ),
                    const SizedBox(height: KvSpace.s),
                    TextButton(
                      onPressed: _busy ? null : _finish,
                      child: Text(ready ? 'Not now' : 'Continue'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
