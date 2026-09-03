import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/format.dart';
import 'package:kaspaverse/src/ui/secret/secret_keyboard.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/widgets/kv_glyph.dart';
import 'package:kaspaverse/src/ui/widgets/kv_keypad.dart';

/// **The ONE keypad, in its two skins** (D-189). The amount pad IS the
/// passphrase keyboard wearing a plain skin: one muscle memory, one codepath
/// for a leak audit to read, and an amount that inherits the no-system-IME
/// guarantee (§0.7) rather than being promised it separately.
///
/// The point of these tests is the word *one*. Anything that could drift the
/// two skins into two keyboards — a second emit path, a skin that accumulates
/// what it typed, a press that does not feel the same — is asserted against
/// here rather than in either caller.
Widget _host(Widget child) => MaterialApp(
  theme: kvDarkTheme(),
  home: Scaffold(body: child),
);

void main() {
  /// A cap that is a **drawn mark** rather than type. Shift and backspace stopped
  /// being findable by their glyph at D-229: BG-25 put glyph ownership in the app,
  /// and `'⌫'` was a codepoint `JetBrainsMono` has no entry for. Every assertion
  /// below is the same assertion — only the locator moved.
  Finder mark(KvGlyph m) =>
      find.byWidgetPredicate((w) => w is KvGlyphIcon && w.mark == m);

  group('one primitive, two skins', () {
    testWidgets('both skins render through the same key cap', (tester) async {
      // The structural claim behind "one codepath to audit": the amount pad is
      // not a look-alike of the secret keyboard, it IS it. If a future edit
      // gave either its own key widget, this stops being true and this test is
      // what notices.
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              KvKeypad.amount(onChar: (_) {}, onBackspace: () {}),
              const Expanded(
                child: SecretKeyboard(onChar: _swallow, onBackspace: _nothing),
              ),
            ],
          ),
        ),
      );
      expect(find.byType(KvKeypad), findsNWidgets(2));
      // The plain skin's twelve caps and the secret skin's forty-one, all
      // through one widget type.
      final caps = find
          .descendant(of: find.byType(KvKeypad), matching: find.byType(InkWell))
          .evaluate()
          .length;
      expect(caps, greaterThan(40));
    });

    testWidgets('a key emits exactly one character, and the pad keeps none of '
        'it', (tester) async {
      // INV-3's shape at the widget layer: the keypad is write-only. It has no
      // field holding what was typed and no way to read one back, which is
      // what lets the secret skin drive a `SecretByteBuffer` without a Dart
      // `String` of the secret ever existing.
      final typed = <String>[];
      await tester.pumpWidget(
        _host(KvKeypad.amount(onChar: typed.add, onBackspace: () {})),
      );
      for (final k in ['1', '2', '.', '5']) {
        await tester.tap(find.text(k));
        await tester.pump();
      }
      expect(typed, ['1', '2', '.', '5']);
      // The pad renders no accumulation of its own — the caller owns the value.
      expect(find.text('12.5'), findsNothing);
    });

    testWidgets('every press is a selectionClick (§6)', (tester) async {
      final haptics = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        _host(KvKeypad.amount(onChar: (_) {}, onBackspace: () {})),
      );
      await tester.tap(find.text('7'));
      await tester.pump();
      await tester.tap(mark(KvGlyph.backspace));
      await tester.pump();
      expect(haptics, [
        'HapticFeedbackType.selectionClick',
        'HapticFeedbackType.selectionClick',
      ]);
    });

    testWidgets('the amount pad offers digits, a point and a backspace — and '
        'nothing else', (tester) async {
      // An amount has no other characters, so the plain skin has no shift, no
      // symbol page and nothing to switch. A key that cannot appear in a
      // number cannot be pressed into one.
      await tester.pumpWidget(
        _host(KvKeypad.amount(onChar: (_) {}, onBackspace: () {})),
      );
      for (final k in ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '.']) {
        expect(find.text(k), findsOneWidget, reason: 'missing "$k"');
      }
      expect(mark(KvGlyph.backspace), findsOneWidget, reason: 'missing erase');
      expect(find.text('space'), findsNothing);
      expect(mark(KvGlyph.shift), findsNothing);
      expect(find.text('ABC'), findsNothing);
    });

    testWidgets('every cap is a named button of at least the target size', (
      tester,
    ) async {
      // BG-12/§0.6: 48dp is the floor, and a cap whose glyph is a symbol says
      // a word instead of the symbol.
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(KvKeypad.amount(onChar: (_) {}, onBackspace: () {})),
      );
      // `.trim()`: a typed cap merges into the node under the spoken label,
      // leaving a trailing newline. A drawn cap contributes nothing to speak,
      // which is BG-25 paying an accessibility dividend rather than costing one.
      expect(
        tester.getSemantics(mark(KvGlyph.backspace)).label.trim(),
        'Backspace',
      );
      expect(tester.getSemantics(find.text('.')).label.trim(), 'Decimal point');
      expect(
        tester.getSemantics(find.text('7')).flagsCollection.isButton,
        isTrue,
      );
      for (final (name, cap) in [
        ('7', find.text('7')),
        ('.', find.text('.')),
        ('erase', mark(KvGlyph.backspace)),
      ]) {
        final size = tester.getSize(
          find.ancestor(of: cap, matching: find.byType(InkWell)).first,
        );
        expect(size.height, greaterThanOrEqualTo(48), reason: 'cap "$name"');
      }
      handle.dispose();
    });
  });

  group('the secret skin keeps its layout', () {
    testWidgets('shift is sticky-once and the cap shows the case it types', (
      tester,
    ) async {
      // The cap and the emitted character are the same string by construction,
      // so a shifted key can never print one case and type the other.
      final typed = <String>[];
      await tester.pumpWidget(
        _host(SecretKeyboard(onChar: typed.add, onBackspace: () {})),
      );
      await tester.tap(mark(KvGlyph.shift));
      await tester.pump();
      expect(find.text('Q'), findsOneWidget);
      await tester.tap(find.text('Q'));
      await tester.pump();
      expect(typed, ['Q']);
      // Sticky ONCE: the next letter is lowercase again.
      expect(find.text('q'), findsOneWidget);
      await tester.tap(find.text('q'));
      await tester.pump();
      expect(typed, ['Q', 'q']);
    });

    testWidgets('the word picker stays lowercase-only — no space, no symbols', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const SecretKeyboard(
            onChar: _swallow,
            onBackspace: _nothing,
            mode: SecretKeyboardMode.lowercaseLetters,
          ),
        ),
      );
      expect(mark(KvGlyph.shift), findsNothing);
      expect(find.text('123'), findsNothing);
      expect(find.text('space'), findsNothing);
      expect(mark(KvGlyph.backspace), findsOneWidget);
    });
  });

  // ── the grammar of money entry ────────────────────────────────────────────
  // Pure functions, so the rules a keypad enforces are readable without a
  // widget. They are [sompiFromKas]'s rules, applied at the keystroke instead
  // of at the parse: a pad that lets you type a ninth decimal and then refuses
  // the whole amount has taught the user nothing.

  group('amountKeyPress', () {
    test('digits append', () {
      expect(amountKeyPress('', '1'), '1');
      expect(amountKeyPress('1', '2'), '12');
    });

    test('a leading zero is replaced, never extended', () {
      expect(amountKeyPress('0', '5'), '5');
      expect(amountKeyPress('0.', '5'), '0.5');
      expect(amountKeyPress('10', '0'), '100');
    });

    test('there is only ever one decimal point, and a leading one is 0.', () {
      expect(amountKeyPress('', '.'), '0.');
      expect(amountKeyPress('12', '.'), '12.');
      expect(amountKeyPress('12.4', '.'), '12.4');
    });

    test('the ninth decimal is refused, not floored away', () {
      // Sompi cannot hold finer than 1e-8 KAS. `sompiFromKas` REJECTS such a
      // string outright, so taking the keystroke would leave the user with an
      // amount the wallet will not parse and no clue which digit did it.
      expect(amountKeyPress('1.12345678', '9'), '1.12345678');
      expect(amountKeyPress('1.1234567', '8'), '1.12345678');
    });

    test(
      'an amount past the u64 sompi ceiling is refused at the keystroke',
      () {
        // `amount_sompi` crosses the FFI as a `u64`, and the encoder ends in
        // `ByteData.setUint64` — which truncates mod 2^64 and throws NOTHING.
        // `184467440737.09551616` KAS would cross as 0. A number silently
        // becoming a different number is BG-5's exact prohibition
        // (`consensus-auditor`, UX-4).
        expect(sompiFromKas('184467440737.09551615'), maxSompi);
        expect(sompiFromKas('184467440737.09551616'), isNull);
        // The pad refuses the key rather than letting the amount become
        // unparseable several presses later.
        expect(amountKeyPress('18446744073.70955161', '5'), isNotNull);
        var typed = '';
        for (final k in '99999999999999999999'.split('')) {
          typed = amountKeyPress(typed, k);
        }
        expect(sompiFromKas(typed), isNotNull);
        expect(sompiFromKas(typed)! <= maxSompi, isTrue);
      },
    );

    test('a non-key changes nothing', () {
      expect(amountKeyPress('12', 'x'), '12');
      expect(amountKeyPress('12', ''), '12');
    });

    test('every reachable string parses (or is empty)', () {
      // The closure property that makes this a grammar rather than a filter:
      // pressing keys can never build a string `sompiFromKas` refuses.
      var current = '';
      for (final k in '9.1234567890'.split('')) {
        current = amountKeyPress(current, k);
        if (current.isNotEmpty && current != '0.') {
          expect(
            sompiFromKas(current),
            isNotNull,
            reason: '"$current" is reachable but unparseable',
          );
        }
      }
      expect(current, '9.12345678');
    });
  });

  group('amountBackspace', () {
    test('removes the last character', () {
      expect(amountBackspace('12.4'), '12.');
      expect(amountBackspace('12.'), '12');
    });

    test('a lone leading zero goes all the way back to empty', () {
      // "0." backspaced would leave a bare "0" the user never typed — it was
      // the point that put it there.
      expect(amountBackspace('0.'), '');
      expect(amountBackspace(''), '');
    });
  });

  group('groupTypedAmount', () {
    test('groups the integer part and leaves the fraction as typed', () {
      expect(groupTypedAmount('1284'), '1,284');
      expect(groupTypedAmount('1284.5'), '1,284.5');
      expect(groupTypedAmount('1284.'), '1,284.');
      expect(groupTypedAmount(''), '');
    });

    test('the grouped form is display only — the canonical string parses', () {
      // `sompiFromKas` rejects grouping commas, so the value that is parsed is
      // never the one that was grouped (§15).
      expect(sompiFromKas(groupTypedAmount('1284.5')), isNull);
      expect(sompiFromKas('1284.5'), BigInt.from(128450000000));
    });
  });
}

void _swallow(String _) {}
void _nothing() {}
