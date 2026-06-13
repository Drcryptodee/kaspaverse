import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/unlock_surface.dart';

void main() {
  testWidgets('biometric ready → Unlock vault button, success holds unlocking', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: UnlockSurface(probe: () async => true, unlock: () async => true),
      ),
    );
    await tester.pumpAndSettle(); // probe resolves

    expect(find.text('Unlock vault'), findsOneWidget);

    await tester.tap(find.text('Unlock vault'));
    await tester.pumpAndSettle();

    // On success the surface stays in "Unlocking…" — it must NOT flash back to
    // idle (the status stream swaps it for home; P1.3 watch-out).
    expect(find.text('Unlocking…'), findsOneWidget);
    expect(find.text('Unlock vault'), findsNothing);
  });

  testWidgets('a cancelled unlock returns to idle with a calm, safe message', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: UnlockSurface(probe: () async => true, unlock: () async => false),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Unlock vault'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Your funds are safe'), findsOneWidget);
    // Idle again so the user can retry.
    expect(find.text('Unlock vault'), findsOneWidget);
  });

  testWidgets(
    'no Path-A enrolled → passphrase-in-P1.4 note, no unlock button',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: UnlockSurface(
            probe: () async => false,
            unlock: () async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Passphrase unlock'), findsOneWidget);
      expect(find.text('Unlock vault'), findsNothing);
    },
  );
}
