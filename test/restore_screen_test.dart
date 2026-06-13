import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/restore_screen.dart';
import 'package:kaspaverse/src/ui/secret/bip39_wordlist.dart';
import 'package:kaspaverse/src/ui/secret/secret_keyboard.dart';

// Deliverable 2 (restore + decoy/typo address preview). Render smoke through the
// guard with injected seams; the restore CORRECTNESS (vectors, decoy property)
// is proven Rust-side, the full UX is the device pass.
void main() {
  const wordlist = Bip39Wordlist.forTest([
    'abandon',
    'ability',
    'able',
    'about',
    'zoo',
  ]);

  testWidgets('renders the word picker (lowercase keyboard + 12/24 toggle)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RestoreScreen(
          wordlist: wordlist,
          setSecure: ({required bool enable}) async {},
          checkAccessibility: () async => false,
          preview: (phrase, extra) async => 'kaspa:qtestaddress',
          commit: (phrase, extra, pass) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Word 1 of 12'), findsOneWidget);
    expect(find.byType(SecretKeyboard), findsOneWidget);
    // The 12/24 word-count toggle is present.
    expect(find.widgetWithText(SegmentedButton<int>, '24'), findsOneWidget);
  });

  testWidgets('refuses to render under an active accessibility service', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RestoreScreen(
          wordlist: wordlist,
          setSecure: ({required bool enable}) async {},
          checkAccessibility: () async => true,
          preview: (phrase, extra) async => 'kaspa:q',
          commit: (phrase, extra, pass) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SecretKeyboard), findsNothing);
    expect(find.text('Secure screen paused'), findsOneWidget);
  });
}
