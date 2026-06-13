import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// What set of keys the [SecretKeyboard] offers.
enum SecretKeyboardMode {
  /// Lowercase a–z only — the restore word-picker filter (BIP39 words are
  /// lowercase, no spaces). No shift, no symbols.
  lowercaseLetters,

  /// Full ASCII — passphrase / extra-word entry (letters with shift, digits,
  /// symbols). Create extra words are ASCII-only anyway (D-031.5).
  fullAscii,
}

/// A custom on-screen keyboard that drives a [SecretByteBuffer] WITHOUT the
/// system IME (§0.7) and without ever forming a Dart `String` of the secret
/// (INV-3). Each key tap emits a single character to [onChar]; the buffer turns
/// it into bytes. No key ever reads back what was typed — the keyboard is
/// write-only into the buffer.
class SecretKeyboard extends StatefulWidget {
  const SecretKeyboard({
    super.key,
    required this.onChar,
    required this.onBackspace,
    this.mode = SecretKeyboardMode.fullAscii,
  });

  final ValueChanged<String> onChar;
  final VoidCallback onBackspace;
  final SecretKeyboardMode mode;

  static const List<String> _letterRows = [
    'qwertyuiop',
    'asdfghjkl',
    'zxcvbnm',
  ];
  static const List<String> _symbolRows = [
    '1234567890',
    r'@#$%&*-_+=',
    '!?.,/:;()',
  ];

  @override
  State<SecretKeyboard> createState() => _SecretKeyboardState();
}

class _SecretKeyboardState extends State<SecretKeyboard> {
  bool _shift = false;
  bool _symbols = false;

  bool get _full => widget.mode == SecretKeyboardMode.fullAscii;

  void _tapLetter(String lower) {
    widget.onChar(_shift ? lower.toUpperCase() : lower);
    if (_shift) setState(() => _shift = false); // sticky-once shift
  }

  @override
  Widget build(BuildContext context) {
    final showingSymbols = _full && _symbols;
    final rows = showingSymbols
        ? SecretKeyboard._symbolRows
        : SecretKeyboard._letterRows;
    return Container(
      color: KvColor.surface,
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.xs,
        vertical: KvSpace.s,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: KvSpace.xs),
              child: Row(
                children: [
                  for (final ch in row.split(''))
                    _Key(
                      label: showingSymbols
                          ? ch
                          : (_shift ? ch.toUpperCase() : ch),
                      onTap: () =>
                          showingSymbols ? widget.onChar(ch) : _tapLetter(ch),
                    ),
                ],
              ),
            ),
          _controlRow(),
        ],
      ),
    );
  }

  Widget _controlRow() {
    return Row(
      children: [
        if (_full && !_symbols)
          _Key(
            label: '⇧',
            flex: 3,
            active: _shift,
            onTap: () => setState(() => _shift = !_shift),
          ),
        if (_full)
          _Key(
            label: _symbols ? 'ABC' : '123',
            flex: 3,
            onTap: () => setState(() => _symbols = !_symbols),
          ),
        _Key(label: '⌫', flex: 3, onTap: widget.onBackspace),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({
    required this.label,
    required this.onTap,
    this.flex = 2,
    this.active = false,
  });

  final String label;
  final VoidCallback onTap;
  final int flex;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: KvSpace.xs / 2),
        child: Material(
          color: active ? KvColor.glow : KvColor.surfaceAlt,
          borderRadius: BorderRadius.circular(KvRadius.data),
          child: InkWell(
            borderRadius: BorderRadius.circular(KvRadius.data),
            onTap: onTap,
            child: Container(
              height: KvSpace.touchTarget,
              alignment: Alignment.center,
              child: Text(
                label,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: active ? KvColor.primary : KvColor.textPrimary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
