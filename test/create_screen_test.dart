import 'dart:typed_data';

import 'package:flutter/material.dart';
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
        biometricAvailable: () async => false,
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
        biometricAvailable: () async => false,
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
        biometricAvailable: () async => true,
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
}
