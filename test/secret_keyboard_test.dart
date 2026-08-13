import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/secret/secret_keyboard.dart';

/// F7. The app promises an any-character extra word on restore
/// (`vault.rs:817-819`), and the no-IME keyboard is the ONLY way to type one —
/// there is no other input path, by §0.7 design. So the promise is only as wide
/// as this key inventory, and it was 14 characters short. The one that bit was
/// **space**: ordinary in a BIP39 passphrase, and with no key at all a wallet
/// restorable in any other BIP39 client could not be restored here.
///
/// Asserted by TAPPING, never by reading the constant back — a test that reads
/// the same table the widget builds from proves only that the table equals
/// itself. This walks every page the way a thumb does.
void main() {
  const controls = {'⇧', '123', 'ABC', '#+=', '⌫', 'space'};

  List<String> characterKeys(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(
          of: find.byType(SecretKeyboard),
          matching: find.byType(Text),
        ),
      )
      .map((t) => t.data ?? '')
      .where((s) => s.isNotEmpty && !controls.contains(s))
      .toList();

  Future<void> tapEveryCharacterKey(WidgetTester tester) async {
    for (final label in characterKeys(tester)) {
      await tester.tap(find.text(label).first);
      await tester.pump();
    }
  }

  testWidgets('full-ASCII mode reaches all 95 printable ASCII characters', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final typed = <String>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SecretKeyboard(onChar: typed.add, onBackspace: () {}),
        ),
      ),
    );

    await tapEveryCharacterKey(tester); // a–z
    final lowercase = characterKeys(tester);
    for (final letter in lowercase) {
      // Shift is sticky-once, so it has to be re-armed for every capital.
      await tester.tap(find.text('⇧'));
      await tester.pump();
      await tester.tap(find.text(letter.toUpperCase()).first);
      await tester.pump();
    }
    await tester.tap(find.text('space'));
    await tester.pump();

    await tester.tap(find.text('123'));
    await tester.pump();
    await tapEveryCharacterKey(tester); // digits + first symbol page

    await tester.tap(find.text('#+='));
    await tester.pump();
    await tapEveryCharacterKey(tester); // the 13 that had no key at all

    final printable = {
      for (var c = 0x20; c <= 0x7E; c++) String.fromCharCode(c),
    };
    expect(
      printable.difference(typed),
      isEmpty,
      reason:
          'unreachable printable ASCII — a passphrase using one of these '
          'cannot be typed, and so cannot be restored',
    );
    expect(typed, contains(' '), reason: 'space, the one that actually bit');
  });

  testWidgets('the word picker stays lowercase-only — no space, no symbols', (
    tester,
  ) async {
    final typed = <String>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SecretKeyboard(
            mode: SecretKeyboardMode.lowercaseLetters,
            onChar: typed.add,
            onBackspace: () {},
          ),
        ),
      ),
    );

    // BIP39 words are single lowercase tokens: a space or a symbol here could
    // only ever be a mistake, so the wider inventory must NOT leak in.
    expect(find.text('space'), findsNothing);
    expect(find.text('123'), findsNothing);
    expect(find.text('⇧'), findsNothing);

    await tapEveryCharacterKey(tester);
    expect(typed, hasLength(26));
    expect(typed.every((c) => RegExp('^[a-z]\$').hasMatch(c)), isTrue);
  });
}
