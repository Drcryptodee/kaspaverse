import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/secret/secret_screen_guard.dart';

// Deliverable-5 mechanism (§0.6 a11y refusal). The platform PROOF is on-glass
// (FLAG_SECURE / TalkBack, device pass); these pin the gating logic via seams.
void main() {
  Widget host(Widget child) => MaterialApp(home: child);

  testWidgets('renders the child when no accessibility service is active', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        SecretScreenGuard(
          setSecure: ({required bool enable}) async {},
          checkAccessibility: () async => false,
          child: const Text('SECRET', key: Key('secret')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('secret')), findsOneWidget);
    expect(find.text('Secure screen paused'), findsNothing);
  });

  testWidgets('refuses (hides the child) when an a11y service is active', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        SecretScreenGuard(
          setSecure: ({required bool enable}) async {},
          checkAccessibility: () async => true,
          child: const Text('SECRET', key: Key('secret')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('secret')), findsNothing);
    expect(find.text('Secure screen paused'), findsOneWidget);
  });

  testWidgets('fails CLOSED (refuses) when the a11y query throws', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        SecretScreenGuard(
          setSecure: ({required bool enable}) async {},
          checkAccessibility: () async => throw Exception('no channel'),
          child: const Text('SECRET', key: Key('secret')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('secret')), findsNothing);
    expect(find.text('Secure screen paused'), findsOneWidget);
  });
}
