import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kaspaverse/src/ui/widgets/kv_toggle.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/restore_screen.dart';
import 'package:kaspaverse/src/ui/secret/bip39_wordlist.dart';
import 'package:kaspaverse/src/ui/secret/secret_keyboard.dart';
import 'package:kaspaverse/src/ui/secret/word_parts.dart';
import 'package:kaspaverse/src/ui/widgets/kv_chrome.dart';
import 'package:kaspaverse/src/ui/widgets/kv_tabs.dart';

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
        // The app mounts `KvWindow` at its root (UX-R1) and `KvColumn`
        // asserts rather than falling back to a compact guess, so a host that
        // renders a Deep V6 screen mounts it too.
        builder: (context, page) => KvWindow(child: page!),
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
    // `O7` puts the count in the bar, as `1 of 12` — mono figures, Jakarta
    // between them (BG-30), so it is one rich run rather than three widgets.
    expect(find.text('1 of 12', findRichText: true), findsOneWidget);
    expect(find.byType(SecretKeyboard), findsOneWidget);
    // The 12/24 length choice is the house segmented (§4), not Material's.
    expect(find.widgetWithText(KvSegmented, '24'), findsOneWidget);
  });

  testWidgets('refuses to render under an active accessibility service', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, page) => KvWindow(child: page!),
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
    tester.view.physicalSize = const Size(393, 851);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        // The app mounts `KvWindow` at its root (UX-R1) and `KvColumn` asserts
        // rather than falling back to a compact guess.
        builder: (context, page) => KvWindow(child: page!),
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

    Future<void> reach(Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    // 12 words, PICKED from the filtered suggestions — the phrase is never
    // typed, and never exists as a Dart String (INV-3).
    for (var i = 0; i < 12; i++) {
      await tester.tap(find.text('a')); // filter prefix
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(KvSuggestion, 'abandon'),
      ); // the suggestion pill
      await tester.pumpAndSettle();
    }
    await reach(find.widgetWithText(KvAction, 'Continue'));
    // **The address is DERIVED on this path, and this assertion is why the
    // test exists.** Its first version walked here, commented that the words
    // go straight to the address, and asserted nothing about the address — so
    // it certified a screen that rendered an empty plate under *Is this your
    // wallet?* with a live confirm beneath it. The injected `preview` seam was
    // never invoked and `qtestaddress` was never looked for
    // (`wallet-security-auditor` BLOCK, UX-R6).
    expect(
      find.textContaining('qtestaddress', findRichText: true),
      findsOneWidget,
      reason: 'the preview must show a derived address, never an empty plate',
    );
    await reach(find.widgetWithText(KvAction, 'This is my wallet'));
    await tester.tap(find.text('a')); // passphrase "a"
    await tester.pumpAndSettle();
    await reach(find.widgetWithText(KvAction, 'Restore wallet'));
  }

  // ── the system back button ───────────────────────────────────────────────
  //
  // **Five correct back arrows, and none of them wired to the phone's button.**
  // `restore_screen` had no [PopScope], so the hardware key and the
  // predictive-back gesture fell through to the route and popped the whole
  // ceremony. The founder hit it while typing the 13th word — the button threw
  // away a phrase he had entered word by word and landed him on Welcome
  // (UX-R6 glass beat, D-311). Nothing in this suite could see it, because a
  // widget test taps arrows and never presses the phone's button.

  /// Press the system back button, the way Android delivers it.
  Future<void> systemBack(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec.encodeMethodCall(
        const MethodCall('popRoute'),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the system back button is a STEP, never an exit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 851);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, page) => KvWindow(child: page!),
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

    // Turn the extra word on, then fill the phrase so `Continue` lands on the
    // 13th-word step — the exact place he was standing.
    await tester.tap(find.byType(KvSwitch));
    await tester.pumpAndSettle();
    for (var i = 0; i < 12; i++) {
      await tester.tap(find.text('a'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(KvSuggestion, 'abandon'));
      await tester.pumpAndSettle();
    }
    final cont = find.widgetWithText(KvAction, 'Continue');
    await tester.ensureVisible(cont);
    await tester.pumpAndSettle();
    await tester.tap(cont);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('word', findRichText: true),
      findsWidgets,
      reason: 'we should be on the extra-word step',
    );

    // THE REGRESSION. This used to pop the whole restore.
    await systemBack(tester);
    expect(
      find.text('home'),
      findsNothing,
      reason: 'back from the 13th word must not abandon the ceremony',
    );
    expect(
      find.byType(SecretKeyboard),
      findsOneWidget,
      reason: 'back lands on the word picker, the step before it',
    );

    // And from the FIRST step it does leave — there is only Welcome behind it.
    await systemBack(tester);
    expect(find.text('home'), findsOneWidget);
  });

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
    expect(find.text('Open with biometrics?'), findsOneWidget);

    await tester.tap(find.text('Use biometrics'));
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
      expect(find.text('Use biometrics'), findsNothing);
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
    await tester.tap(find.text('Use biometrics'));
    await tester.pumpAndSettle();

    // Backing out of a system prompt is a CHOICE. No banner, and the offer is
    // still there — a wallet that shows an error for this is lying.
    expect(find.textContaining("didn't complete"), findsNothing);
    expect(find.text('Use biometrics'), findsOneWidget);
  });

  testWidgets('a FAILED enrolment says so instead of silently going home', (
    tester,
  ) async {
    await restoreTo(
      tester,
      biometricStatus: () async => 'ready',
      enroll: () async => throw PlatformException(code: 'vault'),
    );
    await tester.tap(find.text('Use biometrics'));
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
