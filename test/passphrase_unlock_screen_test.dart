import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/passphrase_unlock_screen.dart';
import 'package:kaspaverse/src/ui/secret/secret_keyboard.dart';

// Deliverable 3 (§0.6 passphrase unlock). Render smoke through the guard — the
// byte-capture path is unit-tested by SecretByteBuffer; the on-glass UX + lane
// are the device pass.
void main() {
  testWidgets('renders the prompt + no-IME keyboard past the guard', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        // The app mounts `KvWindow` at its root and the keypad reads its
        // height class for §3a's `short` key size; `KvWindow.of` asserts
        // rather than guessing (UX-R6).
        builder: (context, page) => KvWindow(child: page!),
        home: PassphraseUnlockScreen(
          setSecure: ({required bool enable}) async {},
          checkAccessibility: () async => false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Enter your passphrase'), findsOneWidget);
    expect(find.byType(SecretKeyboard), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Unlock'), findsOneWidget);
  });

  testWidgets('refuses to render under an active accessibility service', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        // The app mounts `KvWindow` at its root and the keypad reads its
        // height class for §3a's `short` key size; `KvWindow.of` asserts
        // rather than guessing (UX-R6).
        builder: (context, page) => KvWindow(child: page!),
        home: PassphraseUnlockScreen(
          setSecure: ({required bool enable}) async {},
          checkAccessibility: () async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SecretKeyboard), findsNothing);
    expect(find.text('Secure screen paused'), findsOneWidget);
  });
}
