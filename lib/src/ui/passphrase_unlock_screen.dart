import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../rust/api/vault.dart' as vault_api;
import '../services/vault_service.dart';
import 'secret/masked_dots.dart';
import 'secret/secret_byte_buffer.dart';
import 'secret/secret_keyboard.dart';
import 'secret/secret_screen_guard.dart';
import 'error_text.dart';
import 'theme/kv_window.dart';
import 'theme/tokens.dart';
import 'widgets/kv_ceremony_page.dart';
import 'widgets/kv_chrome.dart';
import 'widgets/kv_keypad.dart';

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
    this.inputKind,
    this.checkAccessibility,
    this.setSecure,
  });

  /// Test seam: run the unlock. Defaults to the real `VaultService` lane.
  final Future<void> Function(Uint8List passphrase)? unlock;

  /// **Which pad this vault was sealed with** (D-312). Defaults to the lane,
  /// which reads the blob header and answers `passphrase` on any failure.
  final Future<vault_api.VaultInputKind> Function()? inputKind;

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

  /// **The pad this screen offers FIRST — never the pad it allows.**
  ///
  /// It starts on the keyboard and moves to the number pad only if the vault
  /// says so, because that is the safe direction: an alphanumeric pad can enter
  /// a PIN, and a number pad cannot enter a passphrase. Drawing digits at
  /// somebody whose secret has letters in it would lock them out of their own
  /// wallet while they were holding the correct answer, so [_padSwitchLabel] is
  /// on the glass in **both** states and the byte in the header is advice.
  vault_api.VaultInputKind _pad = vault_api.VaultInputKind.passphrase;
  bool get _isPin => _pad == vault_api.VaultInputKind.digits;

  static const int _pinLength = 6;

  @override
  void initState() {
    super.initState();
    _resolvePad();
  }

  Future<void> _resolvePad() async {
    final read = widget.inputKind ?? VaultService.instance.vaultInputKind;
    // **Caught here, in the screen that draws the pad.** The rule is the safe
    // direction and it belongs to the surface it protects: on ANY failure —
    // no blob, a malformed header, a channel that did not answer — this stays
    // on the keyboard, because the alphanumeric pad can enter a PIN and the
    // number pad cannot enter a passphrase. A wrong guess this way costs a tap;
    // the other way locks somebody out of their own wallet while they are
    // holding the correct secret.
    vault_api.VaultInputKind kind;
    try {
      kind = await read();
    } catch (_) {
      return; // keep the default
    }
    if (!mounted) return;
    setState(() => _pad = kind);
  }

  @override
  void dispose() {
    _buffer.dispose();
    super.dispose();
  }

  /// A digit, and the sixth one unlocks — the render's own contract, and the
  /// one every lock screen on the phone already keeps.
  void _onPinChar(String c) {
    if (_buffer.length.value >= _pinLength || _busy) return;
    _buffer.appendChar(c);
    if (_buffer.length.value >= _pinLength) _submit();
  }

  void _switchPad() {
    // A half-typed secret does not survive the pad that was typing it, and the
    // two pads do not share an alphabet (INV-1/3).
    _buffer.wipe();
    setState(() {
      _pad = _isPin
          ? vault_api.VaultInputKind.passphrase
          : vault_api.VaultInputKind.digits;
      _message = null;
    });
  }

  /// **One act, one pair of names.** The create and restore ceremonies offer
  /// the same swap and must not call it something else: two names for one act
  /// is the same object wearing two faces (BG-21; `ux-auditor`, D-312).
  String get _padSwitchLabel =>
      _isPin ? 'Use a keyboard passphrase' : 'Use a 6-digit PIN';

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
        // **The wrong secret does not survive the attempt that spent it.** On
        // the PIN path this is not only INV-3 hygiene: the wells stay full,
        // `_onPinChar` early-returns at six, and there is no commit control —
        // so a failed attempt left a pad every press of which did nothing, and
        // a wrong six digits resident in the buffer inviting a retry that could
        // not happen (`wallet-security-auditor`, D-312). The keyboard path
        // clears too, because retyping from scratch is what a user does after a
        // refusal anyway.
        _buffer.wipe();
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
    // **Not "wrong passphrase" — the secret may be perfectly correct.** A
    // device-bound vault (D-312) is unopenable on any phone but the one that
    // sealed it, and telling somebody to try again would be telling them to
    // keep retyping the right answer. The way out is the recovery words, and
    // the copy says so instead of hiding it behind a retry.
    if (isDeviceBinding(e)) {
      return 'This wallet is locked to the phone that made it, and this phone '
          'cannot open it. Restore from your recovery words instead — your '
          'funds are safe.';
    }
    return _isPin
        ? 'That PIN did not unlock the vault. Your funds are safe — try again.'
        : 'That passphrase did not unlock the vault. Your funds are safe — try again.';
  }

  bool get _short => KvWindow.of(context).heightClass == KvHeightClass.short;

  Widget _commitPill() => KvAction(
    label: 'Unlock',
    primary: true,
    onTap: _submit,
    disabledReason: _busy ? 'Unlocking\u2026' : null,
  );

  Widget _switchAction() =>
      KvTextAction(label: _padSwitchLabel, onTap: _busy ? null : _switchPad);

  @override
  Widget build(BuildContext context) {
    return SecretScreenGuard(
      title: _isPin ? 'your PIN' : 'your passphrase',
      setSecure: widget.setSecure,
      checkAccessibility: widget.checkAccessibility,
      // **The shared ceremony shape** (UX-R7). This screen used to own an
      // `AppBar`, a `FilledButton` and `theme.textTheme` — the last corner of
      // the group still speaking Material — while its two siblings kept the
      // house page. Three ceremonies with two scaffolds is the drift BG-21
      // exists to stop, so the scaffold was extracted rather than copied a
      // third time.
      child: KvCeremonyPage(
        bar: KvTopBar(
          title: 'Unlock',
          onBack: () => Navigator.of(context).pop(),
        ),
        centred: true,
        // The PIN path unlocks itself on the sixth digit, so it needs no
        // commit; the keyboard path's secret has no length the app can infer,
        // so it does.
        //
        // **At `short` the pad switch joins the foot.** 412 dp of landscape
        // less a bar and a pinned keyboard leaves the body ~77 dp, and the
        // switch — the control that gets a PIN-vault owner onto a keyboard and
        // back — sat below that fold with nothing saying to scroll. That is
        // the shape of UX-R6's `O5` BLOCK one screen over. The foot is not
        // scrolled, so it is the seat that survives the geometry.
        foot: _short
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_isPin) _commitPill(),
                  Center(child: _switchAction()),
                ],
              )
            : (_isPin ? null : _commitPill()),
        bleed: _isPin
            // `O2`'s number pad is drawn inset — see `create_screen._keypad`
            // for why this one and not the other.
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
                child: KvKeypad.pin(
                  onChar: _onPinChar,
                  onBackspace: _buffer.backspace,
                ),
              )
            : SecretKeyboard(
                onChar: (c) => _buffer.appendChar(c),
                onBackspace: _buffer.backspace,
              ),
        children: [
          Text(
            _isPin ? 'Enter your PIN' : 'Enter your passphrase',
            style: KvCeremonyPage.headingStyle(context),
          ),
          const SizedBox(height: KvSpace.l),
          Align(
            alignment: Alignment.centerLeft,
            child: MaskedDots(
              length: _buffer.length,
              slots: _isPin ? _pinLength : null,
            ),
          ),
          if (_message != null) ...[
            const SizedBox(height: KvSpace.m),
            Text(
              _message!,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 15,
                height: 22 / 15,
                color: KvColor.inkDim,
              ),
            ),
          ],
          const SizedBox(height: KvSpace.s),
          // **Centred, as its two siblings centre it** (BG-21: the identical
          // control in three ceremonies is one composition). It is also what
          // keeps `KvTextAction`'s own 8 dp of horizontal padding invisible —
          // the part sits inside `KvColumn`, which has already applied the
          // gutter, so left-aligned it drew its label 8 dp inside every other
          // line on the screen (`ux-auditor`, UX-R7; L195).
          if (!_short) Center(child: _switchAction()),
        ],
      ),
    );
  }
}
