import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../rust/api/vault.dart' as vault_api;
import '../../services/vault_service.dart';
import '../biometric_copy.dart';
import '../error_text.dart';
import '../secret/masked_dots.dart';
import '../secret/secret_byte_buffer.dart';
import '../secret/secret_keyboard.dart';
import '../secret/secret_screen_guard.dart';
import '../theme/kv_window.dart';
import '../theme/tokens.dart';
import '../widgets/ceremony_mark.dart';
import '../widgets/kv_ceremony_page.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_keypad.dart';
import '../widgets/kv_loader.dart';
import '../widgets/kv_steps.dart';
import '../widgets/kv_two_pane.dart';

/// **Change the unlock secret — PIN ↔ passphrase — on an existing vault**
/// (REKEY-1): the re-seal D-312 built the pad choice for and deliberately left
/// to Settings.
///
/// One ceremony, four beats, on the shared [KvCeremonyPage]:
///
///  1. **Confirm** the current secret on the pad the vault keeps — and only
///     that pad, on the founder's ruling; the door's *other pad* exists for a
///     kind read before anything is proven, and this beat is behind the
///     unlock. Rust proves it (`vault_confirm_secret`) and drops the seed; a
///     wrong one costs what it costs at the door — the same lockout, no
///     separate budget.
///  2. **Choose** the new one — `O2`'s composition exactly as `create_screen`
///     draws it: the same pad switch, the same heading, the same refusals (a
///     PIN vault is phone-bound and the seal refuses otherwise).
///  3. **Repeat** it. *A divergence from the create ceremony, said out loud*:
///     create takes the secret once because the twelve words are on the table
///     beside it, freshly checked. A re-key's user has their words wherever
///     they put them months ago, and a slipped thumb here seals a wallet that
///     opens for nobody on this phone. Every phone's own change-PIN asks twice,
///     and so does this. The compare is in place, bytes against bytes, and a
///     mismatch wipes BOTH entries — the first may be the typo.
///  4. **Seal** — Rust re-opens the blob with the current secret, seals the
///     same seed under the new one, and replaces the file atomically
///     (`vault_reseal`). The old blob is readable at every instant until the
///     rename. Then the fingerprint offer where create ends with it (`O6`),
///     naming the new secret — offered only where Path A is not already on.
///
/// **It returns the kind it sealed** (`Navigator.pop(VaultInputKind)`), or
/// null when nothing changed — the caller names the new secret from that.
///
/// **What does not change, and why it is said here.** Path A wraps the
/// *seed*, not this file, so the fingerprint lane still opens the same wallet
/// after a re-key without being touched. The recovery words are untouched.
/// The resident vault is untouched. A re-key changes what the user types and
/// only that.
///
/// **Secrets never leave bytes** (INV-1/3): three [SecretByteBuffer]s, each
/// wiped on the step that spends it, on the way back, and on dispose. The
/// current secret is held across the chooser because the seal has to prove it
/// again — `vault_reseal` is self-contained on purpose, so that *you must
/// know the secret to change it* is a fact about the Rust function and not
/// about this screen having run the confirm beat first.
class RekeyScreen extends StatefulWidget {
  const RekeyScreen({
    super.key,
    this.confirm,
    this.reseal,
    this.inputKind,
    this.deviceBinding,
    this.biometricStatus,
    this.pathAState,
    this.enroll,
    this.checkAccessibility,
    this.setSecure,
  });

  /// Prove the current secret. Defaults to `VaultService.confirmSecret`.
  final Future<void> Function(Uint8List secret)? confirm;

  /// The re-seal: current, next, and the new pad. Defaults to
  /// `VaultService.resealVault`.
  final Future<void> Function(
    Uint8List current,
    Uint8List next,
    vault_api.VaultInputKind nextKind,
  )?
  reseal;

  /// Which pad the vault keeps (D-312). Defaults to the lane; any failure
  /// keeps the keyboard, the pad that can enter either secret.
  final Future<vault_api.VaultInputKind> Function()? inputKind;

  /// Whether this phone can hardware-bind the vault — a probe, not an
  /// install. Defaults to `VaultService.canDeviceBind`.
  final Future<bool> Function()? deviceBinding;

  /// The two biometric probes and the enrol ceremony, for the closing beat.
  final Future<String> Function()? biometricStatus;
  final Future<String> Function()? pathAState;
  final Future<bool> Function()? enroll;

  /// Forwarded to [SecretScreenGuard] (test seams).
  final Future<bool> Function()? checkAccessibility;
  final Future<void> Function({required bool enable})? setSecure;

  @override
  State<RekeyScreen> createState() => _RekeyScreenState();
}

enum _Step { confirm, choose, repeat, sealing, enrolling }

class _RekeyScreenState extends State<RekeyScreen> {
  final SecretByteBuffer _current = SecretByteBuffer();
  final SecretByteBuffer _next = SecretByteBuffer();
  final SecretByteBuffer _repeat = SecretByteBuffer();

  _Step _step = _Step.confirm;
  bool _busy = false;
  String? _message;
  bool _messageIsWarning = false;
  final GlobalKey _messageKey = GlobalKey();

  /// The pad each beat draws. The confirm beat draws the pad the vault keeps
  /// and only that (see [_confirmStep]); the chooser starts there too, because
  /// most people changing a PIN want another PIN, and its switch is one tap
  /// away in both directions.
  vault_api.VaultInputKind _confirmPad = vault_api.VaultInputKind.passphrase;
  vault_api.VaultInputKind _nextPad = vault_api.VaultInputKind.passphrase;

  /// Whether the header read has answered — with a kind, or with a failure
  /// that keeps the keyboard. Until it has, the confirm beat draws no pad.
  bool _padResolved = false;

  /// **What the vault keeps right now**, as read once at open — the noun for
  /// every sentence about the secret that has NOT changed. `_nextNoun` names
  /// the one being chosen; a failed seal on a passphrase vault whose user was
  /// choosing a PIN must say *your passphrase is unchanged*, not *your PIN*
  /// (`wallet-security-auditor`, REKEY-1). Null until read; the word that fits
  /// either secret stands in.
  vault_api.VaultInputKind? _vaultKind;

  /// The four beats, or three on a phone with nothing to offer at the end.
  int _steps = 3;
  String _biometricStatus = biometricUnknown;

  static const int _pinLength = 6;

  // ── seams resolved to the real lanes ─────────────────────────────────────
  Future<void> Function(Uint8List) get _confirmLane =>
      widget.confirm ?? VaultService.instance.confirmSecret;
  Future<void> Function(Uint8List, Uint8List, vault_api.VaultInputKind)
  get _resealLane =>
      widget.reseal ??
      (c, n, kind) => VaultService.instance.resealVault(c, n, inputKind: kind);
  Future<vault_api.VaultInputKind> Function() get _kindLane =>
      widget.inputKind ?? VaultService.instance.vaultInputKind;
  Future<bool> Function() get _bindingLane =>
      widget.deviceBinding ?? VaultService.instance.canDeviceBind;
  Future<String> Function() get _biometricLane =>
      widget.biometricStatus ?? VaultService.instance.biometricStatus;
  Future<String> Function() get _pathALane =>
      widget.pathAState ?? VaultService.instance.pathAState;
  Future<bool> Function() get _enrollLane =>
      widget.enroll ?? VaultService.instance.enrollBiometric;

  @override
  void initState() {
    super.initState();
    _resolvePad();
    _countSteps();
  }

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _resolvePad() async {
    vault_api.VaultInputKind kind;
    try {
      kind = await _kindLane();
    } catch (_) {
      // Keep the keyboard — the pad that can enter either secret — and say
      // the read is over, so the beat draws it.
      if (mounted) setState(() => _padResolved = true);
      return;
    }
    if (!mounted) return;
    setState(() {
      _vaultKind = kind;
      _confirmPad = kind;
      _nextPad = kind;
      _padResolved = true;
    });
  }

  /// **Ask, before the first dot is drawn, whether this phone has a fourth
  /// beat** — the same early probe `create_screen` runs, for the same reason:
  /// the indicator promises a total.
  ///
  /// The offer is made only where Path A is NOT already on. An enrolled
  /// fingerprint still opens the wallet after a re-key — it wraps the seed,
  /// not the file — so re-offering it would tell the user something had
  /// been reset when nothing was.
  Future<void> _countSteps() async {
    String status;
    String pathA;
    try {
      status = await _biometricLane();
      pathA = await _pathALane();
    } catch (_) {
      return; // unknown stays unknown, and unknown offers nothing
    }
    if (!mounted) return;
    setState(() {
      _biometricStatus = status;
      if (_offersEnrolStep(status, pathA)) _steps = 4;
    });
  }

  static bool _offersEnrolStep(String status, String pathA) =>
      pathA != pathAReady &&
      (status == biometricReady || status == biometricNoneEnrolled);

  bool get _confirmIsPin => _confirmPad == vault_api.VaultInputKind.digits;
  bool get _nextIsPin => _nextPad == vault_api.VaultInputKind.digits;
  String get _nextNoun => _nextIsPin ? 'PIN' : 'passphrase';
  String get _vaultNoun => switch (_vaultKind) {
    vault_api.VaultInputKind.digits => 'PIN',
    vault_api.VaultInputKind.passphrase => 'passphrase',
    null => secretNounDefault,
  };
  bool get _short => KvWindow.of(context).heightClass == KvHeightClass.short;

  /// Show a reason, scrolled into view — `create_screen._say`'s contract.
  void _say(String message, {bool warning = false}) {
    setState(() {
      _message = message;
      _messageIsWarning = warning;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _messageKey.currentContext;
      if (!mounted || ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: KvMotion.fast,
        curve: KvMotion.curve,
        alignment: 0.5,
      );
    });
  }

  // ── beat 1 · confirm ─────────────────────────────────────────────────────

  void _onConfirmChar(String c) {
    if (_current.length.value >= _pinLength || _busy) return;
    _current.appendChar(c);
    if (_current.length.value >= _pinLength) _afterSixth(_submitConfirm);
  }

  /// The sixth well has to be SEEN filled before the screen moves (BG-8) —
  /// `create_screen._advanceAfterPin`, verbatim in intent.
  Future<void> _afterSixth(VoidCallback commit) async {
    final instant = MediaQuery.disableAnimationsOf(context);
    await Future<void>.delayed(instant ? Duration.zero : KvMotion.fast);
    if (!mounted || _busy) return;
    commit();
  }

  Future<void> _submitConfirm() async {
    if (_busy) return;
    if (_current.isEmpty) {
      _say(
        _confirmIsPin
            ? 'Enter your PIN first.'
            : 'Enter your passphrase first.',
      );
      return;
    }
    if (_confirmIsPin && _current.length.value != _pinLength) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      // The lane wipes the throwaway copy; the live buffer stays for the seal.
      await _confirmLane(_current.snapshot());
      if (!mounted) return;
      setState(() {
        _busy = false;
        _step = _Step.choose;
      });
    } catch (e) {
      if (!mounted) return;
      // The wrong secret does not survive the attempt that spent it
      // (`wallet-security-auditor`, D-312).
      _current.wipe();
      setState(() => _busy = false);
      // A wrong secret is a quiet retry, as at the door (BG-9); a lockout or
      // a binding is a degraded state and wears `warn`, as the seal's own
      // refusals do — one tone per refusal, wherever it is met (`ux-auditor`).
      _say(
        _refusal(e, pin: _confirmIsPin),
        warning: isLockedOut(e) || isDeviceBinding(e),
      );
    }
  }

  /// The refusals a typed secret can meet — the lockout in the door's own
  /// words, the binding in this ceremony's, **the wrong-secret sentence only
  /// for the bridge's own wrong-secret error**, and everything else in Rust's
  /// words: a blob that could not be read or a lock that landed mid-call is
  /// not a fact about the secret, and saying *that is not your PIN* to a
  /// correct PIN is the failure the binding copy exists to avoid
  /// (`ux-auditor`, BG-11).
  ///
  /// **The door's binding sentence is not this screen's.** At the door the
  /// wallet is locked and *this phone cannot open it* is the truth. Here the
  /// wallet is OPEN in front of the user — the fingerprint opened it, or the
  /// Keystore hiccupped since — so the sentence says what is true from where
  /// they stand: nothing changed, the wallet is still open, and the way to a
  /// fresh setup if it keeps refusing (`wallet-security-auditor`, REKEY-1).
  String _refusal(Object e, {required bool pin}) {
    if (isLockedOut(e)) return lockedOutCopy;
    if (isDeviceBinding(e)) return _bindingRefusal;
    if (isWrongSecret(e)) {
      return pin
          ? 'That is not this wallet’s PIN. Your funds are safe — try again.'
          : 'That is not this wallet’s passphrase. Your funds are safe — '
                'try again.';
    }
    return displayError(e);
  }

  String get _bindingRefusal =>
      'This phone could not produce the hardware key that guards your '
      '$_vaultNoun. Nothing changed: your wallet is still open and your funds '
      'are safe. Try again later. If it keeps refusing, your recovery words '
      'are the way to a fresh setup.';

  // ── beat 2 · choose ──────────────────────────────────────────────────────

  void _onChooseChar(String c) {
    if (_next.length.value >= _pinLength || _busy) return;
    _next.appendChar(c);
    if (_next.length.value >= _pinLength) _afterSixth(_submitChoice);
  }

  /// **Change the pad, and refuse the PIN where it would be a downgrade** —
  /// `create_screen._setPad`. The check runs at the moment of choosing; Rust
  /// refuses it again at the seal (`refuse_unsafe_pin`).
  Future<void> _setNextPad(vault_api.VaultInputKind pad) async {
    if (_busy || pad == _nextPad) return;
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
    _next.wipe();
    setState(() {
      _nextPad = pad;
      _message = null;
    });
  }

  void _submitChoice() {
    if (_busy) return;
    if (_nextIsPin && _next.length.value != _pinLength) {
      _say('Enter all $_pinLength digits.');
      return;
    }
    if (_next.isEmpty) {
      _say('Enter a passphrase first.');
      return;
    }
    setState(() {
      _step = _Step.repeat;
      _message = null;
    });
  }

  // ── beat 3 · repeat ──────────────────────────────────────────────────────

  void _onRepeatChar(String c) {
    if (_repeat.length.value >= _pinLength || _busy) return;
    _repeat.appendChar(c);
    if (_repeat.length.value >= _pinLength) _afterSixth(_submitRepeat);
  }

  void _submitRepeat() {
    if (_busy) return;
    if (_repeat.isEmpty) {
      _say('Enter it again first.');
      return;
    }
    if (_nextIsPin && _repeat.length.value != _pinLength) return;
    if (!_repeat.matches(_next)) {
      // Both, because the FIRST entry may be the typo — the property the O5
      // rebuild retired for a screen with an eye, kept here where there is
      // none (D-312 §4).
      _next.wipe();
      _repeat.wipe();
      setState(() => _step = _Step.choose);
      _say('Those didn’t match. Choose it again.', warning: true);
      return;
    }
    _seal();
  }

  // ── beat 4 · seal, then the fingerprint offer ────────────────────────────

  Future<void> _seal() async {
    setState(() {
      _busy = true;
      _message = null;
      _step = _Step.sealing;
    });
    try {
      await _resealLane(_current.snapshot(), _next.snapshot(), _nextPad);
      // Nothing after the seal reads any of the three.
      _current.wipe();
      _next.wipe();
      _repeat.wipe();
      if (!mounted) return;
      if (_steps == 4) {
        setState(() {
          _busy = false;
          _step = _Step.enrolling;
        });
      } else {
        _finish();
      }
    } catch (e) {
      if (!mounted) return;
      _next.wipe();
      _repeat.wipe();
      setState(() {
        _busy = false;
        _step = _Step.choose;
      });
      // A refusal Rust can explain is surfaced verbatim: a PIN this phone
      // cannot bind, a PIN anyone would try first, a binding that went away
      // between the confirm and the seal. The pad goes back to the keyboard
      // with the first two, because that is the way out the sentence names.
      if (isDeviceBinding(e) || _isPinRefusal(e)) {
        _nextPad = vault_api.VaultInputKind.passphrase;
        _say(
          isDeviceBinding(e) ? _bindingRefusal : displayError(e),
          warning: true,
        );
        return;
      }
      if (isLockedOut(e)) {
        _say(lockedOutCopy, warning: true);
        return;
      }
      _say(
        'KaspaVerse could not change it. Your $_vaultNoun is unchanged and '
        'your funds are safe — try again.',
        warning: true,
      );
    }
  }

  bool _isPinRefusal(Object e) =>
      displayError(e).contains('PIN cannot be used here') ||
      displayError(e).contains('anyone would try');

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
      setState(() => _busy = false);
      // Backing out of the system prompt is a choice, not a failure.
      if (e.code != 'cancelled') _say(enrollFailureCopy(e.code, _nextNoun));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _say(enrollFailureCopy('failed', _nextNoun));
    }
  }

  /// Done. **The fact itself goes back, not a bool**: Security names the new
  /// secret from what this ceremony sealed, and re-reads the blob only to
  /// refresh the rest — a return value of `true` that let the caller re-read
  /// the kind it had just changed handed a failed read a way to keep the old
  /// noun over the new vault (`ux-auditor`, BG-8; L216).
  void _finish() {
    if (mounted) Navigator.of(context).pop(_nextPad);
  }

  // ── back ─────────────────────────────────────────────────────────────────

  void _handleBack() {
    if (_busy) return;
    switch (_step) {
      case _Step.confirm:
        Navigator.of(context).pop(null);
      case _Step.choose:
        // Back is one beat: the confirmed secret is re-asked, because a
        // secret should not sit confirmed under a screen nobody is on.
        _current.wipe();
        _next.wipe();
        setState(() {
          _step = _Step.confirm;
          _message = null;
        });
      case _Step.repeat:
        _repeat.wipe();
        _next.wipe();
        setState(() {
          _step = _Step.choose;
          _message = null;
        });
      case _Step.sealing:
      case _Step.enrolling:
        // The seal is in flight or done; the text action is the way out.
        break;
    }
  }

  // ── composition ──────────────────────────────────────────────────────────

  static const int _beatConfirm = 0;
  static const int _beatChoose = 1;
  static const int _beatRepeat = 2;
  static const int _beatEnrol = 3;

  Widget _bar(int index, {bool back = true}) => KvTopBar(
    title: 'Change PIN or passphrase',
    centre: KvSteps(count: _steps, index: index),
    onBack: back && !_busy ? _handleBack : null,
  );

  Widget _page({
    required int step,
    required List<Widget> children,
    Widget? foot,
    Widget? bleed,
    bool centred = false,
    bool guarded = true,
    bool back = true,
    String? guardTitle,
  }) {
    final page = KvCeremonyPage(
      bar: _bar(step, back: back),
      foot: foot,
      bleed: bleed,
      centred: centred,
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

  Widget _heading(String text, {TextAlign align = TextAlign.start}) =>
      KvCeremonyPage.heading(context, text, align: align);

  /// The explainer drops at `short`; the heading is the question (§3a).
  Widget _sub(String text, {TextAlign align = TextAlign.start}) {
    if (_short) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: KvSpace.sm),
      child: Text(text, style: _body, textAlign: align),
    );
  }

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

  Widget _wells(SecretByteBuffer buffer, {required bool pin}) => MaskedDots(
    length: buffer.length,
    slots: pin ? _pinLength : null,
    emptyHint: 'Type it on the keyboard below',
  );

  /// Both pads are the one [KvKeypad] primitive (D-189); the number pad keeps
  /// the gutter and the keyboard does not — `create_screen._keypad`'s reason.
  Widget _keypad({
    required bool pin,
    required void Function(String) onChar,
    required VoidCallback onBackspace,
  }) => pin
      ? KvColumn(
          child: KvKeypad.pin(
            onChar: _busy ? (_) {} : onChar,
            onBackspace: _busy ? () {} : onBackspace,
          ),
        )
      : SecretKeyboard(
          onChar: _busy ? (_) {} : onChar,
          onBackspace: _busy ? () {} : onBackspace,
        );

  /// The keypad and its caption, full-bleed (`O2`, and `create_screen`'s
  /// reasoning for `inkMeta` over the render's `etch`).
  Widget _bleed({
    required bool pin,
    required void Function(String) onChar,
    required VoidCallback onBackspace,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _keypad(pin: pin, onChar: onChar, onBackspace: onBackspace),
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
  );

  /// **One act, one pair of names** (BG-21) — the door's and the create
  /// ceremony's strings, unchanged.
  static String _padSwitchLabel({required bool pin}) =>
      pin ? 'Use a keyboard passphrase' : 'Use a 6-digit PIN';

  Widget _padSwitch({required bool pin, required VoidCallback onTap}) =>
      Padding(
        padding: const EdgeInsets.only(top: KvSpace.s, bottom: KvSpace.sm),
        child: Center(
          child: KvTextAction(
            label: _padSwitchLabel(pin: pin),
            onTap: _busy ? null : onTap,
          ),
        ),
      );

  /// The three typing beats share one shape: heading, sub, wells, reason,
  /// the pad switch where the beat has one, and a commit pill on the keyboard
  /// path only — the sixth digit is the PIN path's commit (`O2`).
  Widget _typingBeat({
    required int step,
    required bool pin,
    required SecretByteBuffer buffer,
    required String heading,
    String? sub,
    required String commitLabel,
    required VoidCallback onCommit,
    required void Function(String) onChar,
    Widget? padSwitch,
  }) => _page(
    step: step,
    guardTitle: pin ? 'your PIN' : 'your passphrase',
    children: [
      _heading(heading),
      if (sub != null) _sub(sub),
      if (!_short) ...[
        const SizedBox(height: KvSpace.xl),
        Center(child: _wells(buffer, pin: pin)),
      ],
      _reason(),
      if (_short && padSwitch != null) padSwitch,
    ],
    foot: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_short)
          Padding(
            padding: const EdgeInsets.only(bottom: KvSpace.sm),
            child: Center(child: _wells(buffer, pin: pin)),
          ),
        if (!pin)
          Padding(
            padding: const EdgeInsets.only(bottom: KvSpace.sm),
            child: KvAction(
              label: commitLabel,
              primary: true,
              onTap: onCommit,
              disabledReason: _busy ? 'Checking…' : null,
            ),
          ),
        if (!_short && padSwitch != null) padSwitch,
      ],
    ),
    bleed: _bleed(pin: pin, onChar: onChar, onBackspace: buffer.backspace),
  );

  /// **No pad switch here, on the founder's word** (2026-09-11, on glass:
  /// *"why should there be 'Use a 6 digit pin' when i want to enter current
  /// passphrase … there will never be a current pin if the user set a
  /// passphrase"*). The door offers the other pad because it reads the kind
  /// before anything is proven (D-312). This beat sits behind the unlock: the
  /// vault is open, its header authenticated, and a corrupted kind byte would
  /// open with neither pad. The pad is decided by the vault's own header byte
  /// — the one thing that can say *digits* is a file that was sealed as a
  /// PIN, so a passphrase vault is never shown the number pad. The one case a
  /// switch would have covered — the kind READ failing — is covered by the
  /// fallback: the keyboard, which can type a PIN (its symbols page carries
  /// the digits), so a PIN user is never stranded. **And no pad is drawn
  /// until the read has answered** ([_padResolved]): a keyboard flashed at a
  /// PIN user for a frame would look like exactly the bug this guards.
  Widget _confirmStep() {
    if (!_padResolved) {
      return _page(
        step: _beatConfirm,
        guardTitle: 'your secret',
        children: const [],
      );
    }
    return _typingBeat(
      step: _beatConfirm,
      pin: _confirmIsPin,
      buffer: _current,
      heading: _confirmIsPin
          ? 'Enter your current PIN'
          : 'Enter your current passphrase',
      commitLabel: 'Next',
      onCommit: _submitConfirm,
      onChar: _confirmIsPin ? _onConfirmChar : _current.appendChar,
    );
  }

  Widget _chooseStep() => _typingBeat(
    step: _beatChoose,
    pin: _nextIsPin,
    buffer: _next,
    heading: _nextIsPin
        ? 'Choose an unlock PIN'
        : 'Choose an unlock passphrase',
    // `O2`'s sentences without their onboarding tail — nothing here has just
    // been written down. The keyboard branch does not claim the phone
    // (`consensus-auditor`, D-312).
    sub: _nextIsPin
        ? 'Six digits. It opens this app on this phone only — it is not your '
              'recovery phrase.'
        : 'It unlocks this app — it is not your recovery phrase.',
    commitLabel: 'Next',
    onCommit: _submitChoice,
    onChar: _nextIsPin ? _onChooseChar : _next.appendChar,
    padSwitch: _padSwitch(
      pin: _nextIsPin,
      onTap: () => _setNextPad(
        _nextIsPin
            ? vault_api.VaultInputKind.passphrase
            : vault_api.VaultInputKind.digits,
      ),
    ),
  );

  Widget _repeatStep() => _typingBeat(
    step: _beatRepeat,
    pin: _nextIsPin,
    buffer: _repeat,
    heading: _nextIsPin ? 'Enter the PIN again' : 'Enter the passphrase again',
    sub: 'Once more, so a slip cannot lock you out.',
    commitLabel: _nextIsPin ? 'Set PIN' : 'Set passphrase',
    onCommit: _submitRepeat,
    onChar: _nextIsPin ? _onRepeatChar : _repeat.appendChar,
  );

  /// Two KDFs on the founder's phone is about a second and a half; the
  /// screen says what it is doing rather than holding a filled pad still.
  Widget _sealingStep() => _page(
    step: _beatRepeat,
    guarded: false,
    back: false,
    centred: true,
    children: [
      const Center(child: KvLoader()),
      const SizedBox(height: KvSpace.l),
      // Full width, as the enrol beat's sub is: the page's column is
      // `start`-aligned, so a bare centred `Text` shrink-wraps to the gutter
      // under a centred loader (`ux-auditor`, second pass).
      SizedBox(
        width: double.infinity,
        child: Text(
          'Saving your new $_nextNoun…',
          style: _body,
          textAlign: TextAlign.center,
        ),
      ),
    ],
  );

  /// `O6`, as `create_screen._enroll` draws it — the same mark pair, the same
  /// question, the same two ways on — with the text action naming the secret
  /// the vault now keeps.
  Widget _enrollStep() {
    final ready = _biometricStatus == biometricReady;
    return _page(
      step: _beatEnrol,
      guarded: false,
      back: false,
      centred: true,
      children: [
        if (!_short) ...[
          const SizedBox(height: KvSpace.xl),
          const Center(child: CeremonyMarkPair()),
          const SizedBox(height: KvSpace.xl),
        ],
        _heading(
          ready ? 'Open with biometrics?' : 'Biometrics, when you want them',
          align: TextAlign.center,
        ),
        if (!ready)
          SizedBox(
            width: double.infinity,
            child: _sub(
              biometricUnavailableCopy(_biometricStatus, _nextNoun),
              align: TextAlign.center,
            ),
          ),
        _reason(),
      ],
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
              label: ready
                  ? (_nextIsPin ? 'PIN only' : 'Passphrase only')
                  : 'Done',
              onTap: _busy ? null : _finish,
            ),
          ),
          const SizedBox(height: KvSpace.s),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Done or in flight: the phone's back leaves as the text action does,
        // and never mid-seal.
        if (_step == _Step.enrolling && !_busy) {
          _finish();
        } else if (_step != _Step.sealing) {
          _handleBack();
        }
      },
      child: switch (_step) {
        _Step.confirm => _confirmStep(),
        _Step.choose => _chooseStep(),
        _Step.repeat => _repeatStep(),
        _Step.sealing => _sealingStep(),
        _Step.enrolling => _enrollStep(),
      },
    );
  }
}
