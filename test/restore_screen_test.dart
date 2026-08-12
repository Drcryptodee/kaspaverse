import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  // ── Track 2: the enrolment gap ──────────────────────────────────────────
  //
  // Until now this file contained ZERO references to "biometric" or "enroll" —
  // the tests encoded the gap exactly as the app did. A restored wallet could
  // never enable fingerprint unlock, because `_runCommit` popped straight home
  // and `_Step` had no `enrolling` member at all.

  /// Drive the whole restore ceremony up to the commit, with every seam injected.
  Future<void> restoreTo(
    WidgetTester tester, {
    required Future<String> Function() biometricStatus,
    Future<bool> Function()? enroll,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => Navigator.of(ctx).push(
                  MaterialPageRoute<void>(
                    builder: (_) => RestoreScreen(
                      wordlist: wordlist,
                      setSecure: ({required bool enable}) async {},
                      checkAccessibility: () async => false,
                      preview: (phrase, extra) async => 'kaspa:qtestaddress',
                      commit: (phrase, extra, pass) async {},
                      biometricStatus: biometricStatus,
                      enroll: enroll,
                    ),
                  ),
                ),
                child: const Text('home'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();

    // 12 words, PICKED from the filtered suggestions — the phrase is never
    // typed, and never exists as a Dart String (INV-3).
    for (var i = 0; i < 12; i++) {
      await tester.tap(find.text('a')); // filter prefix
      await tester.pumpAndSettle();
      await tester.tap(find.text('abandon')); // the suggestion chip
      await tester.pumpAndSettle();
    }
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Show my address'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'This is my wallet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('a')); // passphrase "a"
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Restore wallet'));
    await tester.pumpAndSettle();
  }

  testWidgets('a restored wallet is OFFERED biometric enrolment', (
    tester,
  ) async {
    var enrollCalls = 0;
    await restoreTo(
      tester,
      biometricStatus: () async => 'ready',
      enroll: () async => ++enrollCalls > 0,
    );

    // THE regression. Before Track 2 this pumped straight past to home.
    expect(find.text('Unlock with your fingerprint?'), findsOneWidget);

    await tester.tap(find.text('Enable fingerprint unlock'));
    await tester.pumpAndSettle();
    expect(enrollCalls, 1);
    expect(find.text('home'), findsOneWidget); // enrolled → popped to home
  });

  testWidgets(
    'no fingerprint on the phone is EXPLAINED, never silently skipped',
    (tester) async {
      await restoreTo(tester, biometricStatus: () async => 'none_enrolled');

      // The silent-skip defect: `none_enrolled` used to collapse to the same
      // `false` as "no sensor", so the step vanished and nothing said why. It is
      // the commonest state on a fresh phone and the only one a user can fix.
      expect(find.textContaining('Android Settings'), findsOneWidget);
      expect(find.text('Enable fingerprint unlock'), findsNothing);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
    },
  );

  testWidgets('a phone with no sensor is not detained by a dead-end step', (
    tester,
  ) async {
    await restoreTo(tester, biometricStatus: () async => 'no_hardware');
    // Nothing actionable to say, so the ceremony ends where it always did.
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('a CANCELLED enrolment is not reported as a failure', (
    tester,
  ) async {
    await restoreTo(
      tester,
      biometricStatus: () async => 'ready',
      enroll: () async => throw PlatformException(code: 'cancelled'),
    );
    await tester.tap(find.text('Enable fingerprint unlock'));
    await tester.pumpAndSettle();

    // Backing out of a system prompt is a CHOICE. No banner, and the offer is
    // still there — a wallet that shows an error for this is lying.
    expect(find.textContaining("didn't complete"), findsNothing);
    expect(find.text('Enable fingerprint unlock'), findsOneWidget);
  });

  testWidgets('a FAILED enrolment says so instead of silently going home', (
    tester,
  ) async {
    await restoreTo(
      tester,
      biometricStatus: () async => 'ready',
      enroll: () async => throw PlatformException(code: 'vault'),
    );
    await tester.tap(find.text('Enable fingerprint unlock'));
    await tester.pumpAndSettle();

    // The lifecycle race, surfaced: the vault re-locked while the prompt held
    // the screen. Swallowed, this was "I tapped it and nothing happened".
    expect(
      find.textContaining('locked while the prompt was open'),
      findsOneWidget,
    );
    expect(find.text('home'), findsNothing, reason: 'must not pop on failure');
  });
}
