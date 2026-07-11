import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/vault_service.dart';
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
    this.biometricAvailable,
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

  /// Is a biometric available to enroll (Path-A offer after seal)?
  final Future<bool> Function()? biometricAvailable;

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
  Future<bool> Function() get _biometricLane =>
      widget.biometricAvailable ?? _probeBiometric;
  Future<bool> Function() get _enrollLane => widget.enroll ?? _runEnroll;

  static Future<bool> _probeBiometric() async {
    final ok = await VaultService.ceremony.invokeMethod<bool>(
      'biometricAvailable',
    );
    return ok ?? false;
  }

  static Future<bool> _runEnroll() async {
    final ok = await VaultService.ceremony.invokeMethod<bool>(
      'enrollBiometric',
    );
    return ok ?? false;
  }

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
      if (!mounted) return;
      final canBiometric = await _safeBiometricProbe();
      if (!mounted) return;
      if (canBiometric) {
        setState(() {
          _busy = false;
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

  Future<bool> _safeBiometricProbe() async {
    try {
      return await _biometricLane();
    } catch (_) {
      return false; // enrollment is optional — Path B already works
    }
  }

  Future<void> _enrollNow() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await _enrollLane();
    } catch (_) {
      // Optional — Path B works regardless; just move on to home.
    }
    _finish();
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Almost done'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(KvSpace.gutter),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CeremonyMark(Icons.fingerprint),
                const SizedBox(height: KvSpace.l),
                Text(
                  'Unlock with your fingerprint?',
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: KvSpace.s),
                Text(
                  'Add a fingerprint to unlock quickly next time. Your passphrase '
                  'still works as a backup.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: KvColor.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: KvSpace.xl),
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
                  child: const Text('Not now'),
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
    );
  }
}
