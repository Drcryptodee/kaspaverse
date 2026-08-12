import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/create_screen.dart';

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

  Future<void> pumpHost(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(
      MaterialApp(
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
    expect(find.text('Set a passphrase'), findsNothing);
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

    expect(find.text('Set a passphrase'), findsOneWidget);
    await tester.tap(
      find.text('a'),
    ); // type passphrase "a" on the no-IME keyboard
    await settle(tester);
    await tester.tap(find.text('Next'));
    await settle(tester);

    expect(find.text('Add an extra word? (optional)'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await settle(tester);

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
    await tester.tap(find.text('b')); // extra word "b"
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Create wallet'));
    await settle(tester);

    expect(sealedPass, equals(Uint8List.fromList([0x61]))); // 'a'
    expect(sealedExtra, equals(Uint8List.fromList([0x62]))); // 'b'
    expect(find.text('Unlock with your fingerprint?'), findsOneWidget);

    await tester.tap(find.text('Enable fingerprint unlock'));
    await settle(tester);

    expect(enrollCalls, 1);
    expect(
      find.text('open'),
      findsOneWidget,
    ); // popped to home host after enroll
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
    await tester.tap(find.text('Skip'));
    await settle(tester);
  }

  testWidgets('no fingerprint enrolled on the phone is explained, not skipped', (
    tester,
  ) async {
    await sealTo(tester, biometricStatus: () async => 'none_enrolled');
    // The commonest state on a fresh phone, and the only one the user can fix.
    // As a bool it was indistinguishable from "no sensor" and vanished.
    expect(find.textContaining('Android Settings'), findsOneWidget);
    expect(find.text('Enable fingerprint unlock'), findsNothing);
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
      await tester.tap(find.text('Enable fingerprint unlock'));
      await settle(tester);
      expect(find.textContaining("didn't complete"), findsNothing);
      expect(find.text('Enable fingerprint unlock'), findsOneWidget);
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
    await tester.tap(find.text('Enable fingerprint unlock'));
    await settle(tester);
    // The suspected lifecycle race, made visible rather than swallowed.
    expect(
      find.textContaining('locked while the prompt was open'),
      findsOneWidget,
    );
    expect(find.text('open'), findsNothing);
  });
}
