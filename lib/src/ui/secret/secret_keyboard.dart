import 'package:flutter/material.dart';

import '../widgets/kv_glyph.dart';
import '../widgets/kv_keypad.dart';

/// What set of keys the [SecretKeyboard] offers.
enum SecretKeyboardMode {
  /// Lowercase a–z only — the restore word-picker filter (BIP39 words are
  /// lowercase, no spaces). No shift, no symbols.
  lowercaseLetters,

  /// Full ASCII — passphrase / extra-word entry (letters with shift, digits,
  /// symbols). Create extra words are ASCII-only anyway (D-031.5).
  fullAscii,
}

/// The secret skin of the one keypad (D-189): a custom on-screen keyboard that
/// drives a [SecretByteBuffer] WITHOUT the system IME (§0.7) and without ever
/// forming a Dart `String` of the secret (INV-3).
///
/// **This file owns the LAYOUT and nothing else.** The caps, the press feel,
/// the haptic and the write-only emit path are [KvKeypad]'s, which the amount
/// pad also renders through — one primitive, two skins, one codepath for a
/// leak audit to read. Each key tap emits a single character to [onChar]; the
/// buffer turns it into bytes. No key ever reads back what was typed.
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

  /// Two symbol pages, and between them every printable ASCII character.
  ///
  /// This used to be one page of 29 symbols, reaching 81 of the 95 printable
  /// ASCII codepoints — and the app promises an any-character extra word on
  /// restore. The one that actually bit was **space**, which is ordinary in a
  /// BIP39 passphrase and had no key at all, so a wallet restorable in any
  /// other BIP39 client could not be restored here (product-audit run 1, F7).
  static const List<List<String>> _symbolPages = [
    ['1234567890', r'@#$%&*-_+=', '!?.,/:;()'],
    [r'''"'<>''', '[]{}', r'\^`|~'],
  ];

  @override
  State<SecretKeyboard> createState() => _SecretKeyboardState();
}

class _SecretKeyboardState extends State<SecretKeyboard> {
  bool _shift = false;
  bool _symbols = false;
  int _symbolPage = 0;

  bool get _full => widget.mode == SecretKeyboardMode.fullAscii;

  /// Sticky-once shift. It lives here rather than in [KvKeypad] because it is
  /// a property of THIS layout — the amount pad has no shift to hold, and a
  /// primitive that carried one would be carrying a skin's state.
  void _emit(String ch) {
    widget.onChar(ch);
    if (_shift) setState(() => _shift = false);
  }

  @override
  Widget build(BuildContext context) {
    final showingSymbols = _full && _symbols;
    final rows = showingSymbols
        ? SecretKeyboard._symbolPages[_symbolPage]
        : SecretKeyboard._letterRows;
    return KvKeypad(
      skin: KvKeypadSkin.secret,
      onChar: showingSymbols ? widget.onChar : _emit,
      rows: [
        for (final row in rows)
          [
            for (final ch in row.split(''))
              KvKey.char(
                showingSymbols || !_shift ? ch : ch.toUpperCase(),
                // The cap shows the case that will be typed; on a shifted
                // letter row the emitted character IS the cap, so the two can
                // never disagree.
              ),
          ],
        _controlRow(),
      ],
    );
  }

  List<KvKey> _controlRow() => [
    if (_full && !_symbols)
      KvKey.command(
        'Shift',
        mark: KvMark.shift,
        flex: 3,
        active: _shift,
        onTap: () => setState(() => _shift = !_shift),
      ),
    if (_full && _symbols)
      KvKey.command(
        _symbolPage == 0 ? '#+=' : '123',
        flex: 3,
        semantics: 'More symbols',
        onTap: () => setState(() => _symbolPage = _symbolPage == 0 ? 1 : 0),
      ),
    if (_full)
      KvKey.command(
        _symbols ? 'ABC' : '123',
        flex: 3,
        semantics: _symbols ? 'Letters' : 'Numbers and symbols',
        onTap: () => setState(() {
          _symbols = !_symbols;
          _symbolPage = 0; // always re-enter symbols on the first page
        }),
      ),
    // Only on the full-ASCII keyboard: BIP39 words are single lowercase
    // tokens, so a space in the word picker could only ever be a mistake.
    if (_full) KvKey.command('space', flex: 6, onTap: () => widget.onChar(' ')),
    KvKey.command(
      'Backspace',
      mark: KvMark.backspace,
      flex: 3,
      onTap: widget.onBackspace,
    ),
  ];
}
