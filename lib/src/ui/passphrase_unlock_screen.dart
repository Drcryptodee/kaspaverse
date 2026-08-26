import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/vault_service.dart';
import 'secret/masked_dots.dart';
import 'secret/secret_byte_buffer.dart';
import 'secret/secret_keyboard.dart';
import 'secret/secret_screen_guard.dart';
import 'error_text.dart';
import 'theme/tokens.dart';

/// The §0.6 passphrase unlock screen (P1.4 deliverable 3) — the Path-B lane the
/// shell's biometric-first [UnlockSurface] hands off to. FLAG_SECURE + a11y
/// refusal via [SecretScreenGuard]; the passphrase is captured by a
/// [SecretByteBuffer] (never a Dart `String`, INV-3) typed on the no-IME
/// [SecretKeyboard] (§0.7), handed to the existing `VaultService` lane as a
/// throwaway `Uint8List` wiped in `finally` (INV-1 sentence two). Vault-calm
/// throughout (BG-9) — a wrong passphrase is a quiet retry, not an alarm.
///
/// On success the status stream flips to unlocked and the shell swaps to home,
/// so this pops itself; failures show a neutral, lockout-aware line.
class PassphraseUnlockScreen extends StatefulWidget {
  const PassphraseUnlockScreen({
    super.key,
    this.unlock,
    this.checkAccessibility,
    this.setSecure,
  });

  /// Test seam: run the unlock. Defaults to the real `VaultService` lane.
  final Future<void> Function(Uint8List passphrase)? unlock;

  /// Forwarded to [SecretScreenGuard] (test seams).
  final Future<bool> Function()? checkAccessibility;
  final Future<void> Function({required bool enable})? setSecure;

  @override
  State<PassphraseUnlockScreen> createState() => _PassphraseUnlockScreenState();
}

class _PassphraseUnlockScreenState extends State<PassphraseUnlockScreen> {
  final SecretByteBuffer _buffer = SecretByteBuffer();
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _buffer.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_buffer.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final unlock = widget.unlock ?? VaultService.instance.unlockWithPassphrase;
    try {
      await unlock(_buffer.snapshot()); // lane wipes the throwaway copy
      // Success: the status stream flips unlocked; the shell shows home beneath
      // this route, so we pop. The live buffer is wiped in dispose().
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = _calmError(e);
        });
      }
    }
  }

  /// The bridge already phrases lockout ("too many attempts — locked out for Ns")
  /// and auth failure plainly; surface those, else a neutral fallback. Never
  /// alarm — the copy reassures, matching the §3 rule that red means fund risk.
  String _calmError(Object e) {
    // Matched on the EXTRACTED message. Against an FRB-decoded AppError,
    // `e.toString()` is the literal "Instance of 'AppError'", so this branch
    // never fired and a rate-limited user was told their passphrase was wrong
    // instead of that they were locked out (run 1, F8).
    if (isLockedOut(e)) {
      return 'Too many attempts. Wait a moment, then try again — your funds are safe.';
    }
    return 'That passphrase did not unlock the vault. Your funds are safe — try again.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SecretScreenGuard(
      title: 'your passphrase',
      setSecure: widget.setSecure,
      checkAccessibility: widget.checkAccessibility,
      child: Scaffold(
        appBar: AppBar(title: const Text('Unlock vault')),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(KvSpace.gutter),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Enter your passphrase',
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: KvSpace.l),
                      MaskedDots(length: _buffer.length),
                      const SizedBox(height: KvSpace.l),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _busy ? null : _submit,
                          child: Text(_busy ? 'Unlocking…' : 'Unlock'),
                        ),
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
              SecretKeyboard(
                onChar: (c) => _buffer.appendChar(c),
                onBackspace: _buffer.backspace,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
