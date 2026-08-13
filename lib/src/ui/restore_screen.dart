import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/vault_service.dart';
import 'biometric_copy.dart';
import 'secret/bip39_wordlist.dart';
import 'secret/secret_byte_buffer.dart';
import 'secret/secret_keyboard.dart';
import 'secret/secret_screen_guard.dart';
import 'theme/tokens.dart';
import 'widgets/ceremony_mark.dart';
import 'widgets/haptics.dart';
import 'widgets/kv_loader.dart';

/// The restore ceremony's steps.
///
/// `enrolling` is the one that was missing, and its absence was the whole
/// defect: the create ceremony ended `seal → biometric offer → home`, restore
/// ended `commit → home`, and Path A had no other door in the entire app. A
/// restored wallet could therefore never enable fingerprint unlock — a shipped,
/// device-proven, fully-working native lane that no user could reach.
enum _Step { words, extraWord, preview, passphrase, enrolling }

/// Restore flow (P1.4 deliverable 2). §0.6/§0.7: FLAG_SECURE + a11y refusal via
/// [SecretScreenGuard]; seed words are PICKED from the in-app filtered wordlist
/// (no system IME) and captured as the ordered list of wordlist INDICES — the
/// assembled phrase is only ever bytes for the bridge, never a Dart `String`
/// (INV-3). Validation is Rust-side (INV-9). The derived first address is shown
/// before commit so a typo'd word opens a visibly-different wallet rather than a
/// silent empty one — the decoy/poisoning UX trap (wallet-security + ux).
///
/// Restore accepts 12 AND 24 words and ANY-UTF-8 extra word (the compatibility
/// path; ASCII is the create-only rule, D-031.5) — the address preview is the
/// safety net for a normalization mismatch.
class RestoreScreen extends StatefulWidget {
  const RestoreScreen({
    super.key,
    this.wordlist,
    this.preview,
    this.commit,
    this.biometricStatus,
    this.enroll,
    this.checkAccessibility,
    this.setSecure,
  });

  /// Test seams.
  final Bip39Wordlist? wordlist;
  final Future<String> Function(Uint8List phrase, Uint8List extra)? preview;
  final Future<void> Function(
    Uint8List phrase,
    Uint8List extra,
    Uint8List pass,
  )?
  commit;

  /// Why Path A is or is not offerable after the commit — a reason, not a bool
  /// (see `biometric_copy.dart`). Defaults to the lane.
  final Future<String> Function()? biometricStatus;

  /// Run the enrolment ceremony; throws [PlatformException] with a stable code.
  final Future<bool> Function()? enroll;

  final Future<bool> Function()? checkAccessibility;
  final Future<void> Function({required bool enable})? setSecure;

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  Bip39Wordlist? _wordlist;
  int _target = 12;
  final List<int> _indices = []; // selected wordlist indices — the secret order
  String _filter = ''; // transient prefix (a public-word search query)
  final SecretByteBuffer _extra = SecretByteBuffer();
  final SecretByteBuffer _passphrase = SecretByteBuffer();
  _Step _step = _Step.words;
  String? _previewAddress;
  bool _busy = false;
  String? _message;

  /// Why Path A is (un)available, resolved once after the commit.
  String _biometricStatus = 'unknown';

  @override
  void initState() {
    super.initState();
    final injected = widget.wordlist;
    if (injected != null) {
      _wordlist = injected;
    } else {
      Bip39Wordlist.load().then((w) {
        if (mounted) setState(() => _wordlist = w);
      });
    }
  }

  @override
  void dispose() {
    _extra.dispose();
    _passphrase.dispose();
    // The picked words ARE the phrase. A back-gesture out of the flow left them
    // resident until the next GC saw fit; `SecretByteBuffer` was wiped here and
    // this list was not.
    //
    // PARTIAL, and said so: `_indices` grows by `add`, so reallocation leaves
    // earlier backing stores holding prefix copies that `clear()` cannot reach.
    // Same class as `_assemblePhrase`'s growable buffer. Both are pre-existing
    // and both need a fixed-length allocation to close properly — backlogged
    // with a trigger rather than half-done here (ffi-leak-auditor, Track 2).
    _indices.clear();
    super.dispose();
  }

  // ── phrase assembly (bytes only — never a full-phrase String) ────────────
  Uint8List _assemblePhrase() {
    final out = <int>[];
    for (var k = 0; k < _indices.length; k++) {
      if (k > 0) out.add(0x20); // space
      out.addAll(_wordlist!.words[_indices[k]].codeUnits); // ASCII BIP39 words
    }
    return Uint8List.fromList(out); // service wipes this throwaway copy
  }

  // ── words step actions ───────────────────────────────────────────────────
  void _select(String word) {
    final idx = _wordlist!.indexOf(word);
    if (idx < 0 || _indices.length >= _target) return;
    KvHaptic.selection(); // word-select (§7)
    setState(() {
      _indices.add(idx);
      _filter = '';
    });
  }

  void _wordsBackspace() {
    setState(() {
      if (_filter.isNotEmpty) {
        _filter = _filter.substring(0, _filter.length - 1);
      } else if (_indices.isNotEmpty) {
        _indices.removeLast();
      }
    });
  }

  Future<void> _runPreview() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final preview = widget.preview ?? VaultService.instance.restorePreview;
    try {
      final addr = await preview(_assemblePhrase(), _extra.snapshot());
      if (mounted) {
        setState(() {
          _previewAddress = addr;
          _step = _Step.preview;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message =
              'Those words are not a valid recovery phrase. Check each word and '
              'try again.';
        });
      }
    }
  }

  Future<void> _runCommit() async {
    if (_passphrase.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final commit = widget.commit ?? VaultService.instance.restoreAndPersist;
    try {
      await commit(
        _assemblePhrase(),
        _extra.snapshot(),
        _passphrase.snapshot(),
      );
      // Consumed. Wipe BEFORE the enrol step, not at dispose.
      //
      // Until this step existed a successful commit popped within milliseconds
      // and `dispose` did it. The enrol offer holds the screen for an unbounded
      // time — deliberately spanning an app-background, since the biometric
      // prompt pauses Flutter — and `_indices` is the complete mnemonic as
      // BIP39 wordlist indices. Nothing reachable from `_Step.enrolling` reads
      // any of the three (wallet-security-auditor, Track 2).
      _extra.wipe();
      _passphrase.wipe();
      _indices.clear();
      if (!mounted) return;
      // The vault is now sealed and unlocked — the same state the create flow
      // reaches after its seal, so it gets the same offer. This used to pop
      // straight home, which is why a restored wallet could never enable Path A.
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
      if (mounted) {
        setState(() {
          _busy = false;
          _message = 'Could not restore. Your funds are safe — try again.';
        });
      }
    }
  }

  // ── Path A offer, mirroring create_screen.dart ───────────────────────────
  // Routed through VaultService, never the static ceremony channel, so the
  // §0.11 auto-lock suppression actually covers the prompt (the instance-flag
  // reason spelled out in create_screen).

  Future<String> _safeBiometricProbe() async {
    try {
      final probe =
          widget.biometricStatus ?? VaultService.instance.biometricStatus;
      return await probe();
    } catch (_) {
      return 'unknown'; // a question we could not ask is not a "no"
    }
  }

  /// Stop for the enrol step only where the user can act: `ready` (offer it) or
  /// `none_enrolled` (say how to get there). See `create_screen.dart`.
  static bool _offersEnrolStep(String status) =>
      status == biometricReady || status == biometricNoneEnrolled;

  Future<void> _runEnroll() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final enroll = widget.enroll ?? VaultService.instance.enrollBiometric;
      await enroll();
      _finish();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = e.code == 'cancelled' ? null : enrollFailureCopy(e.code);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = enrollFailureCopy('failed');
      });
    }
  }

  /// The wallet exists and is unlocked; popping reveals home beneath.
  void _finish() {
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // OUTSIDE the guard. The enrol step runs after the wallet is committed and
    // holds no secret, and DS-7's FLAG_SECURE + accessibility-refusal list is
    // locked at five screens (D-028) — extending it to a sixth would exclude
    // screen-reader users from a step that has nothing to hide. Its mirror in
    // `create_screen` is outside too, and the two ceremonies must not disagree
    // about whether the identical step is a secret screen (ux-auditor).
    //
    // The chrome differs for the same reason: this step must not claim the
    // restore is still under way, and it suppresses the back arrow that one
    // step earlier meant *abandon the restore*.
    if (_step == _Step.enrolling) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Almost done'),
          automaticallyImplyLeading: false,
        ),
        body: SafeArea(child: _enrollStep()),
      );
    }
    return SecretScreenGuard(
      title: 'your recovery words',
      setSecure: widget.setSecure,
      checkAccessibility: widget.checkAccessibility,
      child: Scaffold(
        appBar: AppBar(title: const Text('Restore wallet')),
        body: SafeArea(child: _body()),
      ),
    );
  }

  Widget _body() {
    if (_wordlist == null) {
      return const Center(child: KvLoader());
    }
    switch (_step) {
      case _Step.words:
        return _wordsStep();
      case _Step.extraWord:
        return _extraWordStep();
      case _Step.preview:
        return _previewStep();
      case _Step.passphrase:
        return _passphraseStep();
      case _Step.enrolling:
        return _enrollStep();
    }
  }

  // ── step: the Path-A offer (mirrors create_screen.dart's `_enroll`) ───────
  Widget _enrollStep() {
    final theme = Theme.of(context);
    final ready = _biometricStatus == biometricReady;
    // Scrollable. At 1.3× on a 360×640 phone this step overflowed by
    // 206 px with a failure message showing — `enrollFailureCopy` AND
    // the "Not now" exit laid out entirely off-screen, so tapping
    // Enable and failing produced no visible change at all. That is
    // verbatim the defect the honest-degrade fix was written to end
    // (ux-auditor, Track 2 re-audit).
    // `Center` inside a `SingleChildScrollView` is a vertical no-op — the scroll
    // view hands its child unbounded height — so the overflow fix alone would
    // top-align this step in every case, leaving ~182 dp of dead space below
    // "Not now" on a 411×731 phone. The min-height constraint restores the
    // centring while keeping the overflow escape (ux-auditor, Track 2 re-audit).
    return LayoutBuilder(
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
                      onPressed: _busy ? null : _runEnroll,
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
    );
  }

  // ── step: pick words ──────────────────────────────────────────────────────
  Widget _wordsStep() {
    final theme = Theme.of(context);
    final suggestions = _wordlist!.startingWith(_filter);
    final complete = _indices.length == _target;
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(KvSpace.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Word ${_indices.length + (complete ? 0 : 1)} of $_target',
                      style: theme.textTheme.titleMedium,
                    ),
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 12, label: Text('12')),
                        ButtonSegment(value: 24, label: Text('24')),
                      ],
                      selected: {_target},
                      onSelectionChanged: _indices.isEmpty
                          ? (s) {
                              KvHaptic.selection(); // toggle (§7)
                              setState(() => _target = s.first);
                            }
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: KvSpace.m),
                // The picked words are the part that GROWS (up to 24 chips, and
                // more at large text scale), so they take the slack and scroll
                // inside it. A `Spacer` here made the growth overflow instead:
                // once chips + the bottom block exceeded the step, the content
                // that could not be seen was silently clipped — on the surface
                // where the user is checking a recovery phrase word by word.
                Expanded(
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: KvSpace.s,
                      runSpacing: KvSpace.s,
                      children: [
                        for (var k = 0; k < _indices.length; k++)
                          Chip(
                            label: Text(
                              '${k + 1}. ${_wordlist!.words[_indices[k]]}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: KvSpace.m),
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: KvSpace.s),
                    child: Text(
                      _message!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: KvColor.textSecondary,
                      ),
                    ),
                  ),
                if (complete) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: KvSpace.s),
                    child: Text(
                      'All $_target words are in. Use ⌫ to change the last one.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: KvColor.textSecondary,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => setState(() => _step = _Step.extraWord),
                      child: const Text('Continue'),
                    ),
                  ),
                ] else if (_filter.isNotEmpty)
                  SizedBox(
                    height: KvSpace.touchTarget,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final w in suggestions)
                          Padding(
                            padding: const EdgeInsets.only(right: KvSpace.s),
                            child: ActionChip(
                              label: Text(w, style: theme.textTheme.bodyLarge),
                              onPressed: () => _select(w),
                            ),
                          ),
                      ],
                    ),
                  )
                else
                  Text(
                    'Type each word, then tap it from the suggestions.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: KvColor.textTertiary,
                    ),
                  ),
              ],
            ),
          ),
        ),
        // Rendered while there is anything to UNDO, not only while there is
        // something left to add. Its ⌫ is the only caller of `_wordsBackspace`,
        // and unmounting it at exactly `complete` took away the sole way to
        // un-pick a word — so the preview trap's own remedy button, "Go back and
        // fix a word", returned the user to a step where no word could be
        // changed (product-audit run 1, F5).
        // Always mounted once a word has been picked — its ⌫ is the only
        // caller of `_wordsBackspace`, so unmounting it at `complete` took away
        // the sole way to un-pick a word and left the preview trap's own
        // "Go back and fix a word" remedy pointing at a step that could not fix
        // one (product-audit run 1, F5).
        //
        // Letters are inert once complete: the suggestion strip is not rendered
        // there, so a keystroke would silently fill `_filter` and then have to
        // be drained by ⌫ before it reached a word — a stretch where nothing
        // the user does responds, which is the defect wearing a smaller hat.
        SecretKeyboard(
          mode: SecretKeyboardMode.lowercaseLetters,
          onChar: complete ? (_) {} : (c) => setState(() => _filter += c),
          onBackspace: _wordsBackspace,
        ),
      ],
    );
  }

  // ── step: optional extra word ─────────────────────────────────────────────
  Widget _extraWordStep() {
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(KvSpace.gutter),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Extra word (optional)',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: KvSpace.s),
                Text(
                  'If you protected this wallet with a 13th/25th word, enter it. '
                  'Leave blank if you did not — the address on the next screen '
                  'will confirm you got it right.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: KvColor.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: KvSpace.l),
                ValueListenableBuilder<int>(
                  valueListenable: _extra.length,
                  builder: (context, n, _) => Text(
                    n == 0 ? 'No extra word' : '$n characters entered',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: KvColor.textTertiary,
                    ),
                  ),
                ),
                const SizedBox(height: KvSpace.l),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy ? null : _runPreview,
                    child: Text(_busy ? 'Checking…' : 'Show my address'),
                  ),
                ),
              ],
            ),
          ),
        ),
        SecretKeyboard(
          onChar: (c) => _extra.appendChar(c),
          onBackspace: _extra.backspace,
        ),
      ],
    );
  }

  // ── step: address preview (the decoy/typo trap) ───────────────────────────
  Widget _previewStep() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(KvSpace.gutter),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('Is this your wallet?', style: theme.textTheme.headlineSmall),
          const SizedBox(height: KvSpace.s),
          Text(
            'These words open the wallet at the address below. If it is not the '
            'one you expect, a word or the extra word is wrong — go back and fix '
            'it.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: KvColor.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: KvSpace.l),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(KvSpace.m),
            decoration: BoxDecoration(
              color: KvColor.surfaceAlt,
              borderRadius: BorderRadius.circular(KvRadius.data),
            ),
            child: SelectableText(
              _chunkAddress(_previewAddress ?? ''),
              style: theme.textTheme.bodyLarge?.copyWith(
                color: KvColor.primary,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: KvSpace.l),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => setState(() => _step = _Step.passphrase),
              child: const Text('This is my wallet'),
            ),
          ),
          const SizedBox(height: KvSpace.sm),
          TextButton(
            onPressed: () => setState(() {
              _step = _Step.words;
              _previewAddress = null;
            }),
            child: const Text('Go back and fix a word'),
          ),
        ],
      ),
    );
  }

  // ── step: set passphrase, then commit ─────────────────────────────────────
  Widget _passphraseStep() {
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(KvSpace.gutter),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('Set a passphrase', style: theme.textTheme.headlineSmall),
                const SizedBox(height: KvSpace.s),
                Text(
                  'This passphrase encrypts the wallet on THIS device. You will '
                  'enter it to unlock.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: KvColor.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: KvSpace.l),
                ValueListenableBuilder<int>(
                  valueListenable: _passphrase.length,
                  builder: (context, n, _) => Text(
                    n == 0 ? 'Use the keyboard below' : '$n characters',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: KvColor.textTertiary,
                    ),
                  ),
                ),
                const SizedBox(height: KvSpace.l),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy ? null : _runCommit,
                    child: Text(_busy ? 'Restoring…' : 'Restore wallet'),
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
          onChar: (c) => _passphrase.appendChar(c),
          onBackspace: _passphrase.backspace,
        ),
      ],
    );
  }

  /// DS-8: a confirm surface shows the FULL address, chunked in groups of 4.
  String _chunkAddress(String addr) {
    final parts = addr.split(':');
    final prefix = parts.length > 1 ? '${parts.first}:' : '';
    final payload = parts.length > 1 ? parts.sublist(1).join(':') : addr;
    final buf = StringBuffer(prefix);
    for (var i = 0; i < payload.length; i += 4) {
      if (i > 0) buf.write(' ');
      buf.write(payload.substring(i, (i + 4).clamp(0, payload.length)));
    }
    return buf.toString();
  }
}
