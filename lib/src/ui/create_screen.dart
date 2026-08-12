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
///   optional ASCII extra word → sealAndPersist (leaves the vault unlocked) →
///   optional biometric enroll → pop (the shell then shows home).
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

enum _Step { preparing, passphrase, extraWord, enrolling }

class _CreateScreenState extends State<CreateScreen> {
  final SecretByteBuffer _passphrase = SecretByteBuffer();
  final SecretByteBuffer _extraWord = SecretByteBuffer();

  _Step _step = _Step.preparing;
  bool _busy = false;
  String? _message;
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

  void _submitPassphrase() {
    if (_passphrase.isEmpty) {
      setState(() => _message = 'Enter a passphrase first.');
      return;
    }
    setState(() {
      _step = _Step.extraWord;
      _message = null;
    });
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
        setState(() {
          _busy = false;
          _message =
              'Could not finish creating your wallet. Your funds are safe — try again.';
        });
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
        _message = e.code == 'cancelled' ? null : enrollFailureCopy(e.code);
      });
    } catch (_) {
      // Never swallowed to a silent pop again: that is what made enrolment
      // present as "I tapped it and nothing happened". The user stays on the
      // step, is told what happened, and can retry or skip.
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = enrollFailureCopy('failed');
      });
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
          primaryLabel: _busy ? 'Creating…' : 'Create wallet',
          onPrimary: _busy ? null : _doSeal,
          secondaryLabel: 'Skip',
          onSecondary: _busy
              ? null
              : () {
                  _extraWord.wipe();
                  _doSeal();
                },
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
                        Text(
                          heading,
                          style: theme.textTheme.headlineSmall,
                          textAlign: TextAlign.center,
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
                        if (_message != null) ...[
                          const SizedBox(height: KvSpace.m),
                          Text(
                            _message!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: KvColor.textSecondary,
                            ),
                            textAlign: TextAlign.center,
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
                    if (_message != null) ...[
                      const SizedBox(height: KvSpace.m),
                      Text(
                        _message!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: KvColor.textSecondary,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
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
