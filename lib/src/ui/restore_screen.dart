import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/vault_service.dart';
import 'secret/bip39_wordlist.dart';
import 'secret/secret_byte_buffer.dart';
import 'secret/secret_keyboard.dart';
import 'secret/secret_screen_guard.dart';
import 'theme/tokens.dart';
import 'widgets/haptics.dart';

enum _Step { words, extraWord, preview, passphrase }

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
      if (mounted) Navigator.of(context).pop(); // shell now shows home
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = 'Could not restore. Your funds are safe — try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
      return const Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: KvColor.primaryMuted,
        ),
      );
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
    }
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
                Wrap(
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
                const Spacer(),
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
                if (complete)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => setState(() => _step = _Step.extraWord),
                      child: const Text('Continue'),
                    ),
                  )
                else if (_filter.isNotEmpty)
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
        if (!complete)
          SecretKeyboard(
            mode: SecretKeyboardMode.lowercaseLetters,
            onChar: (c) => setState(() => _filter += c),
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
