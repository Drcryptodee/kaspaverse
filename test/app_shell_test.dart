import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/vault.dart';
import 'package:kaspaverse/src/ui/app_shell.dart';

VaultStatus _status({required bool exists, required bool unlocked}) =>
    VaultStatus(exists: exists, unlocked: unlocked, failedAttempts: 0);

void main() {
  group('AppShell.routeKey — status routes to exactly one surface', () {
    test('null status is the initialising splash', () {
      expect(AppShell.routeKey(null), 'init');
    });
    test('no vault yet routes to onboarding', () {
      expect(
        AppShell.routeKey(_status(exists: false, unlocked: false)),
        'onboarding',
      );
    });
    test('a sealed vault routes to locked', () {
      expect(
        AppShell.routeKey(_status(exists: true, unlocked: false)),
        'locked',
      );
    });
    test('an unlocked vault routes home', () {
      expect(AppShell.routeKey(_status(exists: true, unlocked: true)), 'home');
    });
  });

  testWidgets('shell shows the child for the live status, never home early', (
    tester,
  ) async {
    final status = ValueNotifier<VaultStatus?>(null);
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          status: status,
          initializing: const Text('INIT'),
          onboarding: const Text('ONBOARD'),
          locked: const Text('LOCKED'),
          home: const Text('HOME'),
        ),
      ),
    );

    // null → init, and crucially NOT home (no optimistic unlock flash).
    expect(find.text('INIT'), findsOneWidget);
    expect(find.text('HOME'), findsNothing);

    status.value = _status(exists: false, unlocked: false);
    await tester.pumpAndSettle();
    expect(find.text('ONBOARD'), findsOneWidget);

    status.value = _status(exists: true, unlocked: false);
    await tester.pumpAndSettle();
    expect(find.text('LOCKED'), findsOneWidget);

    status.value = _status(exists: true, unlocked: true);
    await tester.pumpAndSettle();
    expect(find.text('HOME'), findsOneWidget);
    expect(find.text('LOCKED'), findsNothing);

    status.dispose();
  });
}
