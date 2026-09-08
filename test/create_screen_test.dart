import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/create_screen.dart';
import 'package:kaspaverse/src/ui/widgets/kv_chrome.dart';
import 'package:kaspaverse/src/ui/widgets/kv_toggle.dart';

/// Seam-driven walk of the create ceremony (the native reveal + biometric are
/// device-proven on glass; here we prove the Flutter flow + that the passphrase
/// and extra word reach `seal` as the bytes typed — never as a Dart `String`).
///
/// `pumpAndSettle` is avoided on purpose: the preparing + guard splashes spin a
/// `CircularProgressIndicator` (an infinite animation) that would hang it. We
/// pump a fixed number of frames to drain the chained async seams instead.
void main() {
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 15; i++) {
      await t.pump(const Duration(milliseconds: 20));
    }
  }

  /// Tap something that may be under the fold.
  ///
  /// `O5` with the switch on is a scrolling screen — heading, explainer, the
  /// switch card, two fields, the notice plate and two controls do not stand
  /// in one view under a pinned keyboard, and the render is drawn without one.
  /// A test that taps blind at a fixed geometry is asserting the fold, not the
  /// flow.
  Future<void> reach(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await settle(tester);
    await tester.tap(f);
    await settle(tester);
  }

  Future<void> pumpHost(WidgetTester tester, Widget screen) async {
    // **A phone, not the 800x600 desktop default.** These are full-height
    // ceremonies with a keyboard pinned to the foot, and the harness default is
    // a geometry no phone has: at 600 dp tall the primary sat below the fold,
    // so a tap that a user could never miss missed in the test. 393x851 is the
    // design's own reference frame (the floor gets its own test, below).
    tester.view.physicalSize = const Size(393, 851);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        // The app mounts `KvWindow` at its root (UX-R1) and `KvColumn`
        // asserts rather than falling back to a compact guess, so a host that
        // renders a Deep V6 screen mounts it too.
        builder: (context, page) => KvWindow(child: page!),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => Navigator.of(
                  ctx,
                ).push(MaterialPageRoute<void>(builder: (_) => screen)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
  }

  testWidgets('failed verify abandons the ceremony and returns to onboarding', (
    tester,
  ) async {
    var abandonCalls = 0;
    await pumpHost(
      tester,
      CreateScreen(
        begin: () async {},
        reveal: () async => false, // user backed out of the native reveal
        abandon: () async => abandonCalls++,
        seal: (p, x) async {},
        biometricStatus: () async => 'no_hardware',
        enroll: () async => true,
        checkAccessibility: () async => false,
        setSecure: ({required bool enable}) async {},
      ),
    );
    await settle(tester);

    expect(abandonCalls, greaterThanOrEqualTo(1));
    expect(find.text('open'), findsOneWidget); // popped back to the host
    expect(find.text('Choose an unlock passphrase'), findsNothing);
  });

  testWidgets('reveal → passphrase → skip extra → seal (no biometric) → home', (
    tester,
  ) async {
    Uint8List? sealedPass;
    Uint8List? sealedExtra;
    var enrollCalls = 0;
    await pumpHost(
      tester,
      CreateScreen(
        begin: () async {},
        reveal: () async => true,
        abandon: () async {},
        seal: (p, x) async {
          sealedPass = Uint8List.fromList(p);
          sealedExtra = Uint8List.fromList(x);
        },
        biometricStatus: () async => 'no_hardware',
        enroll: () async => enrollCalls++ == 0,
        checkAccessibility: () async => false,
        setSecure: ({required bool enable}) async {},
      ),
    );
    await settle(tester);

    expect(find.text('Choose an unlock passphrase'), findsOneWidget);
    await tester.tap(
      find.text('a'),
    ); // type passphrase "a" on the no-IME keyboard
    await settle(tester);
    await tester.tap(find.text('Next'));
    await settle(tester);

    expect(find.text('Add a 13th word?'), findsOneWidget);
    // The switch is off, so the primary IS the way past — and it names what
    // it will do rather than saying "Next" twice on two different screens.
    await reach(tester, find.text('Continue — 12 words only'));

    expect(sealedPass, equals(Uint8List.fromList([0x61]))); // 'a'
    expect(sealedExtra, isEmpty); // skipped
    expect(enrollCalls, 0); // not offered when no biometric
    expect(find.text('open'), findsOneWidget); // finished → popped to home host
  });

  testWidgets('reveal → passphrase → extra word → create → biometric enroll', (
    tester,
  ) async {
    Uint8List? sealedPass;
    Uint8List? sealedExtra;
    var enrollCalls = 0;
    await pumpHost(
      tester,
      CreateScreen(
        begin: () async {},
        reveal: () async => true,
        abandon: () async {},
        seal: (p, x) async {
          sealedPass = Uint8List.fromList(p);
          sealedExtra = Uint8List.fromList(x);
        },
        biometricStatus: () async => 'ready',
        enroll: () async => ++enrollCalls > 0,
        checkAccessibility: () async => false,
        setSecure: ({required bool enable}) async {},
      ),
    );
    await settle(tester);

    await tester.tap(find.text('a')); // passphrase "a"
    await settle(tester);
    await tester.tap(find.text('Next'));
    await settle(tester);
    await reach(tester, find.byType(KvToggle)); // opt in to the 13th word
    await tester.tap(find.text('b')); // extra word "b"
    await settle(tester);
    await reach(
      tester,
      find.widgetWithText(KvAction, 'Continue with 13th word'),
    );
    await tester.tap(find.text('b')); // confirm-repeat, matching
    await settle(tester);
    await reach(tester, find.widgetWithText(KvAction, 'Create wallet'));

    expect(sealedPass, equals(Uint8List.fromList([0x61]))); // 'a'
    expect(sealedExtra, equals(Uint8List.fromList([0x62]))); // 'b'
    expect(find.text('Open with biometrics?'), findsOneWidget);

    await tester.tap(find.text('Use biometrics'));
    await settle(tester);

    expect(enrollCalls, 1);
    expect(
      find.text('open'),
      findsOneWidget,
    ); // popped to home host after enroll
  });

  // ── F1: the extra word is seed-determining, so it is typed twice ────────
  //
  // It was typed ONCE, blind: masked dots render `buffer.length` and never the
  // characters, the native quiz covers the twelve words only and runs before
  // this word exists, and both buffers were wiped the instant the seal
  // returned. One wrong character sealed a wallet the user's own written
  // backup could never reproduce — with no delete path and no seal-over-an-
  // existing-blob, they could not even test the backup by restoring — and
  // nothing on the device would ever have said so.

  Future<void> toExtraWord(
    WidgetTester tester, {
    required void Function(Uint8List extra) onSeal,
    Future<void> Function(Finder)? tap,
  }) async {
    final press =
        tap ??
        (Finder f) async {
          await tester.tap(f);
          await settle(tester);
        };
    await pumpHost(
      tester,
      CreateScreen(
        begin: () async {},
        reveal: () async => true,
        abandon: () async {},
        seal: (p, x) async => onSeal(Uint8List.fromList(x)),
        biometricStatus: () async => 'no_hardware',
        enroll: () async => true,
        checkAccessibility: () async => false,
        setSecure: ({required bool enable}) async {},
      ),
    );
    await settle(tester);
    await press(find.text('a')); // passphrase
    await press(find.widgetWithText(KvAction, 'Next'));
    expect(find.text('Add a 13th word?'), findsOneWidget);
    // `O5`'s switch. The extra word is opted INTO — it is seed-determining and
    // unrecoverable — so the fields and the keyboard only exist once it is on.
    await press(find.byType(KvToggle));
  }

  testWidgets('a mistyped extra word is caught instead of sealed', (
    tester,
  ) async {
    var sealCalls = 0;
    await toExtraWord(tester, onSeal: (_) => sealCalls++);

    await tester.tap(find.text('b')); // entry: "b"
    await settle(tester);
    await reach(
      tester,
      find.widgetWithText(KvAction, 'Continue with 13th word'),
    );

    expect(find.text('Create wallet'), findsOneWidget);
    await tester.tap(find.text('c')); // confirm: "c" — the typo
    await settle(tester);
    await reach(tester, find.widgetWithText(KvAction, 'Create wallet'));

    // Nothing sealed, and the user is back at the entry with BOTH buffers
    // wiped: a mismatch means one of the two is wrong and neither the user nor
    // the app can see which, so re-typing only the copy would let them
    // "correct" it until it matched a first entry that was itself the typo.
    expect(sealCalls, 0);
    expect(find.text('Add a 13th word?'), findsOneWidget);
    expect(find.textContaining("didn't match"), findsOneWidget);
    // BOTH fields back to their placeholders: zero dots in either.
    expect(find.text('Type it here'), findsOneWidget);
    expect(find.text('Type it again'), findsOneWidget);
  });

  testWidgets('the mismatch reason is ON SCREEN on a small phone at 1.3x', (
    tester,
  ) async {
    // Proving the message exists is not proving the user can read it. Laid out
    // after both buttons it began ~416 dp down a 360 dp viewport — present in
    // the tree, findable by `find.textContaining`, and entirely below the
    // fold. Every other test here runs at the 800x600 default and would have
    // stayed green. This is the reachability gap 3227d32's commit message
    // named and the enroll-overflow fix hit before it.
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    Future<void> tapScrolled(Finder f) async {
      await tester.ensureVisible(f); // the buttons themselves scroll here
      await settle(tester);
      await tester.tap(f);
      await settle(tester);
    }

    await toExtraWord(tester, onSeal: (_) {}, tap: tapScrolled);
    await tapScrolled(find.text('b'));
    await tapScrolled(find.widgetWithText(KvAction, 'Continue with 13th word'));
    await tapScrolled(find.text('c'));
    await tapScrolled(find.widgetWithText(KvAction, 'Create wallet'));

    final message = find.textContaining("didn't match");
    expect(message, findsOneWidget);
    final box = tester.getRect(message);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(
      box.top >= 0 && box.bottom <= screen.height,
      isTrue,
      reason:
          'the reason beat must be visible without scrolling — it was at '
          '${box.top.toStringAsFixed(0)}..${box.bottom.toStringAsFixed(0)} dp '
          'on a ${screen.height.toStringAsFixed(0)} dp screen',
    );
  });

  testWidgets('a matching extra word seals exactly the bytes typed', (
    tester,
  ) async {
    Uint8List? sealedExtra;
    await toExtraWord(tester, onSeal: (x) => sealedExtra = x);

    for (final c in ['b', 'c']) {
      await tester.tap(find.text(c));
      await settle(tester);
    }
    await reach(
      tester,
      find.widgetWithText(KvAction, 'Continue with 13th word'),
    );
    for (final c in ['b', 'c']) {
      await tester.tap(find.text(c));
      await settle(tester);
    }
    await reach(tester, find.widgetWithText(KvAction, 'Create wallet'));

    expect(sealedExtra, equals(Uint8List.fromList([0x62, 0x63]))); // 'bc'
  });

  testWidgets('a longer confirm than entry does not match', (tester) async {
    // The length-mismatch arm: a dropped or doubled character is exactly what
    // a dot count cannot show, since the user cannot see the word to count against.
    var sealCalls = 0;
    await toExtraWord(tester, onSeal: (_) => sealCalls++);

    await tester.tap(find.text('b'));
    await settle(tester);
    await reach(
      tester,
      find.widgetWithText(KvAction, 'Continue with 13th word'),
    );
    for (final c in ['b', 'b']) {
      await tester.tap(find.text(c));
      await settle(tester);
    }
    await reach(tester, find.widgetWithText(KvAction, 'Create wallet'));

    expect(sealCalls, 0);
    expect(find.textContaining("didn't match"), findsOneWidget);
  });

  testWidgets('backing out of the confirm returns to the entry', (
    tester,
  ) async {
    await toExtraWord(tester, onSeal: (_) {});
    await tester.tap(find.text('b'));
    await settle(tester);
    await reach(
      tester,
      find.widgetWithText(KvAction, 'Continue with 13th word'),
    );
    await reach(tester, find.bySemanticsLabel('Back'));

    // Back at the entry, which still holds the word — only the half-typed
    // confirm is wiped.
    expect(find.text('Add a 13th word?'), findsOneWidget);
    // One dot in the entry field: "b" survived; the confirm shows its
    // placeholder because the half-typed copy did not.
    expect(find.text('Type it again'), findsOneWidget);
    expect(find.text('Type it here'), findsNothing);
  });

  testWidgets('Skip still seals an empty extra word with no confirm step', (
    tester,
  ) async {
    // The audit's constraint: the Skip path wipes to empty first and must be
    // untouched by the confirm gate.
    Uint8List? sealedExtra;
    await toExtraWord(tester, onSeal: (x) => sealedExtra = x);
    // The switch is ON here — `toExtraWord` flips it — so this is the plain
    // text way past a step the user has already opened, which is the path the
    // audit's constraint is about.
    await reach(tester, find.text('Skip — 12 words only'));

    expect(sealedExtra, isEmpty);
    expect(find.widgetWithText(KvAction, 'Create wallet'), findsNothing);
  });

  testWidgets('an empty entry is not sealed by the primary button', (
    tester,
  ) async {
    var sealCalls = 0;
    await toExtraWord(tester, onSeal: (_) => sealCalls++);
    await reach(
      tester,
      find.widgetWithText(KvAction, 'Continue with 13th word'),
    );

    expect(sealCalls, 0); // Skip owns the empty path, and says so
    expect(find.textContaining('or tap Skip'), findsOneWidget);
  });

  // ── Track 2: honest degrade on the enrolment step ───────────────────────
  //
  // `_safeBiometricProbe` returned false on ANY exception and `_enrollNow`
  // swallowed EVERY error before popping, so a user could not tell
  // "unavailable" from "failed" from "done" — the three outcomes rendered
  // identically as the screen simply going away.

  Future<void> sealTo(
    WidgetTester tester, {
    required Future<String> Function() biometricStatus,
    Future<bool> Function()? enroll,
  }) async {
    await pumpHost(
      tester,
      CreateScreen(
        begin: () async {},
        reveal: () async => true,
        abandon: () async {},
        seal: (p, x) async {},
        biometricStatus: biometricStatus,
        enroll: enroll,
        checkAccessibility: () async => false,
        setSecure: ({required bool enable}) async {},
      ),
    );
    await settle(tester);
    await tester.tap(find.text('a')); // passphrase
    await settle(tester);
    await tester.tap(find.text('Next'));
    await settle(tester);
    await reach(tester, find.text('Continue — 12 words only'));
  }

  testWidgets('no fingerprint enrolled on the phone is explained, not skipped', (
    tester,
  ) async {
    await sealTo(tester, biometricStatus: () async => 'none_enrolled');
    // The commonest state on a fresh phone, and the only one the user can fix.
    // As a bool it was indistinguishable from "no sensor" and vanished.
    expect(find.textContaining('Android Settings'), findsOneWidget);
    expect(find.text('Use biometrics'), findsNothing);
  });

  testWidgets('a probe that cannot run is unknown, never a confident no', (
    tester,
  ) async {
    // The wallet must still be created — enrolment is optional and Path B is
    // already live — but the verdict is not manufactured from a thrown probe.
    await sealTo(
      tester,
      biometricStatus: () async => throw Exception('no channel'),
    );
    expect(find.text('open'), findsOneWidget); // finished → popped to host
  });

  testWidgets(
    'a cancelled enrolment leaves the offer standing, with no error',
    (tester) async {
      await sealTo(
        tester,
        biometricStatus: () async => 'ready',
        enroll: () async => throw PlatformException(code: 'cancelled'),
      );
      await tester.tap(find.text('Use biometrics'));
      await settle(tester);
      expect(find.textContaining("didn't complete"), findsNothing);
      expect(find.text('Use biometrics'), findsOneWidget);
      expect(find.text('open'), findsNothing, reason: 'a cancel must not pop');
    },
  );

  testWidgets('a failed enrolment names the cause instead of popping', (
    tester,
  ) async {
    await sealTo(
      tester,
      biometricStatus: () async => 'ready',
      enroll: () async => throw PlatformException(code: 'vault'),
    );
    await tester.tap(find.text('Use biometrics'));
    await settle(tester);
    // The suspected lifecycle race, made visible rather than swallowed.
    expect(
      find.textContaining('locked while the prompt was open'),
      findsOneWidget,
    );
    expect(find.text('open'), findsNothing);
  });
}
