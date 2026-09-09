import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/passphrase_unlock_screen.dart';
import 'package:kaspaverse/src/rust/api/vault.dart' as vault_api;
import 'package:kaspaverse/src/ui/secret/masked_dots.dart';
import 'package:kaspaverse/src/ui/secret/secret_keyboard.dart';
import 'package:kaspaverse/src/ui/widgets/kv_keypad.dart';
import 'dart:typed_data';

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

  // ── D-312 · the pad the vault remembers, and the one it always offers ────

  Future<void> pump(
    WidgetTester tester, {
    required vault_api.VaultInputKind kind,
    Future<void> Function(Uint8List)? unlock,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, page) => KvWindow(child: page!),
        home: PassphraseUnlockScreen(
          setSecure: ({required bool enable}) async {},
          checkAccessibility: () async => false,
          inputKind: () async => kind,
          unlock: unlock,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a PIN vault opens on the number pad, six wells and no commit', (
    tester,
  ) async {
    await pump(tester, kind: vault_api.VaultInputKind.digits);

    expect(find.text('Enter your PIN'), findsOneWidget);
    expect(find.byType(KvKeypad), findsOneWidget);
    expect(find.byType(SecretKeyboard), findsNothing);
    // `O2`'s contract: the sixth digit is the commit.
    expect(find.widgetWithText(FilledButton, 'Unlock'), findsNothing);
    expect(tester.widget<MaskedDots>(find.byType(MaskedDots)).slots, 6);
  });

  testWidgets('the OTHER pad is on the glass in both states', (tester) async {
    // **The rule that outranks the header byte.** The kind is read without a
    // passphrase, so it is unauthenticated at the moment it is read — and a
    // number pad drawn at somebody whose secret contains letters would lock
    // them out of their own wallet while they were holding the correct answer.
    // The byte decides what is shown FIRST; it never decides what may be typed.
    // **One act, one pair of names** — the same strings the create and restore
    // ceremonies use, because two names for one act is one object wearing two
    // faces (BG-21; `ux-auditor`, D-312).
    await pump(tester, kind: vault_api.VaultInputKind.digits);
    expect(find.text('Use a keyboard passphrase'), findsOneWidget);

    await tester.tap(find.text('Use a keyboard passphrase'));
    await tester.pumpAndSettle();
    expect(find.byType(SecretKeyboard), findsOneWidget);
    expect(find.text('Enter your passphrase'), findsOneWidget);
    expect(find.text('Use a 6-digit PIN'), findsOneWidget);
  });

  testWidgets('a kind that cannot be read falls back to the KEYBOARD', (
    tester,
  ) async {
    // The safe direction, and the only safe direction: the alphanumeric pad
    // can enter a PIN, and the number pad cannot enter a passphrase. A wrong
    // answer this way costs a tap.
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, page) => KvWindow(child: page!),
        home: PassphraseUnlockScreen(
          setSecure: ({required bool enable}) async {},
          checkAccessibility: () async => false,
          inputKind: () async => throw StateError('no blob'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SecretKeyboard), findsOneWidget);
  });

  testWidgets('the sixth digit unlocks, and five do not', (tester) async {
    final tried = <String>[];
    await pump(
      tester,
      kind: vault_api.VaultInputKind.digits,
      unlock: (p) async => tried.add(String.fromCharCodes(p)),
    );

    for (final d in ['1', '2', '3', '4', '5']) {
      await tester.tap(find.text(d));
      await tester.pumpAndSettle();
    }
    expect(tried, isEmpty, reason: 'five digits is not a PIN');

    await tester.tap(find.text('6'));
    await tester.pumpAndSettle();
    expect(tried, ['123456']);
  });

  testWidgets('a refused PIN clears the wells instead of stranding the pad', (
    tester,
  ) async {
    // Without the wipe the six wells stayed full, every further press was a
    // no-op (`_onPinChar` early-returns at six) and there is no commit control
    // on this path — so the screen invited a retry it could not accept, with
    // the wrong secret still resident (`wallet-security-auditor`, D-312).
    await pump(
      tester,
      kind: vault_api.VaultInputKind.digits,
      unlock: (p) async => throw StateError('nope'),
    );
    for (final d in ['4', '8', '1', '9', '0', '2']) {
      await tester.tap(find.text(d));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('did not unlock'), findsOneWidget);
    expect(
      tester.widget<MaskedDots>(find.byType(MaskedDots)).length.value,
      0,
      reason: 'the spent secret is gone and the pad is live again',
    );
  });

  testWidgets('switching pads wipes what was typed on the other', (
    tester,
  ) async {
    await pump(tester, kind: vault_api.VaultInputKind.digits);
    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    expect(tester.widget<MaskedDots>(find.byType(MaskedDots)).length.value, 1);

    await tester.tap(find.text('Use a keyboard passphrase'));
    await tester.pumpAndSettle();
    expect(tester.widget<MaskedDots>(find.byType(MaskedDots)).length.value, 0);
  });
}
