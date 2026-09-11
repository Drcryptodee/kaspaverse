import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/rust/api/vault.dart' as vault_api;
import 'package:kaspaverse/src/ui/biometric_copy.dart';
import 'package:kaspaverse/src/ui/secret/masked_dots.dart';
import 'package:kaspaverse/src/ui/secret/secret_keyboard.dart';
import 'package:kaspaverse/src/ui/settings/rekey_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/widgets/kv_chrome.dart' show KvAction;
import 'package:kaspaverse/src/ui/widgets/kv_keypad.dart';
import 'package:kaspaverse/src/ui/widgets/kv_steps.dart';

// REKEY-1 — change the unlock secret, PIN ↔ passphrase, on an existing vault.
// The Rust half (the seal, the atomic replace, the lockout) is proven in
// `rust/bridge/src/api/vault.rs`; these prove the ceremony: what it draws,
// what it hands the lane, and what it wipes.

/// What the fake lanes saw. Bytes are copied at the call, because the lane
/// contract is that the caller's buffer is wiped afterwards.
class Seen {
  final List<String> confirmed = [];
  final List<(String, String, vault_api.VaultInputKind)> resealed = [];
  int enrolled = 0;
}

Future<Seen> pump(
  WidgetTester tester, {
  vault_api.VaultInputKind kind = vault_api.VaultInputKind.digits,
  Future<void> Function(Uint8List)? confirm,
  Future<void> Function(Uint8List, Uint8List, vault_api.VaultInputKind)? reseal,
  bool canBind = true,
  String biometric = biometricReady,
  String pathA = pathAReady,
  bool accessibility = false,
  Size size = const Size(393, 852),
  List<Object?>? popped,
}) async {
  final seen = Seen();
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, page) => KvWindow(child: page!),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                final result = await Navigator.of(context)
                    .push<vault_api.VaultInputKind>(
                      MaterialPageRoute(
                        builder: (_) => RekeyScreen(
                          inputKind: () async => kind,
                          confirm:
                              confirm ??
                              (s) async =>
                                  seen.confirmed.add(String.fromCharCodes(s)),
                          reseal:
                              reseal ??
                              (c, n, k) async => seen.resealed.add((
                                String.fromCharCodes(c),
                                String.fromCharCodes(n),
                                k,
                              )),
                          deviceBinding: () async => canBind,
                          biometricStatus: () async => biometric,
                          pathAState: () async => pathA,
                          enroll: () async {
                            seen.enrolled++;
                            return true;
                          },
                          checkAccessibility: () async => accessibility,
                          setSecure: ({required bool enable}) async {},
                        ),
                      ),
                    );
                popped?.add(result);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return seen;
}

Future<void> type(WidgetTester tester, String s) async {
  for (final ch in s.split('')) {
    await tester.tap(find.text(ch).first);
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Object refusal(String message) => AppError(message: message);

void main() {
  testWidgets('the confirm beat opens on the pad the vault keeps, and offers '
      'the other (D-312)', (tester) async {
    await pump(tester);
    expect(find.text('Enter your current PIN'), findsOneWidget);
    expect(find.byType(KvKeypad), findsOneWidget);
    expect(find.byType(SecretKeyboard), findsNothing);
    expect(tester.widget<MaskedDots>(find.byType(MaskedDots)).slots, 6);
    // No commit on the PIN path — the sixth digit is the commit (`O2`).
    expect(find.widgetWithText(KvAction, 'Next'), findsNothing);
    expect(find.text('Use a keyboard passphrase'), findsOneWidget);
    // Three beats on a phone whose fingerprint is already on.
    expect(tester.widget<KvSteps>(find.byType(KvSteps)).count, 3);

    await tester.tap(find.text('Use a keyboard passphrase'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your current passphrase'), findsOneWidget);
    expect(find.byType(SecretKeyboard), findsOneWidget);
    expect(find.widgetWithText(KvAction, 'Next'), findsOneWidget);
    expect(find.text('Use a 6-digit PIN'), findsOneWidget);
  });

  testWidgets('a kind that cannot be read keeps the KEYBOARD on both beats', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, page) => KvWindow(child: page!),
        home: RekeyScreen(
          inputKind: () async => throw StateError('no blob'),
          confirm: (_) async {},
          biometricStatus: () async => biometricReady,
          pathAState: () async => pathAReady,
          checkAccessibility: () async => false,
          setSecure: ({required bool enable}) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SecretKeyboard), findsOneWidget);
    expect(find.text('Enter your current passphrase'), findsOneWidget);
  });

  testWidgets(
    'a wrong current secret is wiped and said, in the door\'s words',
    (tester) async {
      var calls = 0;
      await pump(
        tester,
        confirm: (_) async {
          calls++;
          throw refusal('wrong passphrase or corrupted vault data');
        },
      );
      await type(tester, '111111');
      expect(calls, 1);
      expect(find.text('Enter your current PIN'), findsOneWidget);
      expect(find.textContaining('not this wallet’s PIN'), findsOneWidget);
      // The wrong six digits do not survive the attempt that spent them.
      expect(
        tester.widget<MaskedDots>(find.byType(MaskedDots)).length.value,
        0,
      );
      // …and a second try reaches the lane again — the pad was not left dead.
      await type(tester, '222222');
      expect(calls, 2);
    },
  );

  testWidgets('a lockout is said as the door says it', (tester) async {
    await pump(
      tester,
      confirm: (_) async =>
          throw refusal('too many attempts — locked out for 30 more seconds'),
    );
    await type(tester, '111111');
    expect(find.textContaining('Too many attempts'), findsOneWidget);
  });

  testWidgets('a device binding is said as the door says it', (tester) async {
    await pump(
      tester,
      confirm: (_) async => throw refusal(
        "vault is bound to its phone's hardware key: this vault is bound to "
        'its phone',
      ),
    );
    await type(tester, '111111');
    // NOT the door's sentence: the wallet is open in front of the user, so
    // "this phone cannot open it" would be false where they stand.
    expect(
      find.textContaining('locked to the phone that made it'),
      findsNothing,
    );
    expect(find.textContaining('guards your PIN'), findsOneWidget);
    expect(find.textContaining('still open'), findsOneWidget);
  });

  testWidgets('PIN → passphrase: confirm, choose, repeat, seal — and the lane '
      'gets the bytes it needs, nothing more', (tester) async {
    final popped = <Object?>[];
    final seen = await pump(tester, popped: popped);

    // 1 · confirm on the number pad; the sixth digit commits.
    await type(tester, '481902');
    expect(seen.confirmed, ['481902']);
    // 2 · the chooser opens on the pad the vault keeps, as `O2` draws it.
    expect(find.text('Choose an unlock PIN'), findsOneWidget);
    expect(tester.widget<KvSteps>(find.byType(KvSteps)).index, 1);
    expect(find.textContaining('not your recovery phrase'), findsOneWidget);
    // …and the onboarding tail is gone: nothing has just been written down.
    expect(find.textContaining('just written down'), findsNothing);
    await tester.tap(find.text('Use a keyboard passphrase'));
    await tester.pumpAndSettle();
    expect(find.text('Choose an unlock passphrase'), findsOneWidget);
    expect(find.byType(SecretKeyboard), findsOneWidget);
    await type(tester, 'abc');
    await tester.tap(find.widgetWithText(KvAction, 'Next'));
    await tester.pumpAndSettle();
    // 3 · repeat, on the same pad, with its own commit.
    expect(find.text('Enter the passphrase again'), findsOneWidget);
    expect(tester.widget<KvSteps>(find.byType(KvSteps)).index, 2);
    await type(tester, 'abc');
    await tester.tap(find.widgetWithText(KvAction, 'Set passphrase'));
    await tester.pumpAndSettle();
    // 4 · sealed with the confirmed current and the repeated next; Path A is
    // already on, so no offer — straight back, reporting the change.
    expect(seen.resealed, [
      ('481902', 'abc', vault_api.VaultInputKind.passphrase),
    ]);
    // The FACT goes back, not a bool: the kind that was sealed.
    expect(popped, [vault_api.VaultInputKind.passphrase]);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('passphrase → PIN: the sixth digit of the repeat seals', (
    tester,
  ) async {
    final seen = await pump(tester, kind: vault_api.VaultInputKind.passphrase);
    await type(tester, 'old');
    await tester.tap(find.widgetWithText(KvAction, 'Next'));
    await tester.pumpAndSettle();
    expect(find.text('Choose an unlock passphrase'), findsOneWidget);
    await tester.tap(find.text('Use a 6-digit PIN'));
    await tester.pumpAndSettle();
    expect(find.text('Choose an unlock PIN'), findsOneWidget);
    expect(find.textContaining('this phone only'), findsOneWidget);
    await type(tester, '902481');
    expect(find.text('Enter the PIN again'), findsOneWidget);
    expect(find.widgetWithText(KvAction, 'Set PIN'), findsNothing);
    await type(tester, '902481');
    expect(seen.resealed, [('old', '902481', vault_api.VaultInputKind.digits)]);
  });

  testWidgets('a repeat that does not match wipes BOTH and returns to the '
      'chooser', (tester) async {
    final seen = await pump(tester, kind: vault_api.VaultInputKind.passphrase);
    await type(tester, 'old');
    await tester.tap(find.widgetWithText(KvAction, 'Next'));
    await tester.pumpAndSettle();
    await type(tester, 'abc');
    await tester.tap(find.widgetWithText(KvAction, 'Next'));
    await tester.pumpAndSettle();
    await type(tester, 'abd');
    await tester.tap(find.widgetWithText(KvAction, 'Set passphrase'));
    await tester.pumpAndSettle();
    expect(seen.resealed, isEmpty, reason: 'a mismatch must never seal');
    expect(find.text('Choose an unlock passphrase'), findsOneWidget);
    expect(find.textContaining('didn’t match'), findsOneWidget);
    expect(
      tester.widget<MaskedDots>(find.byType(MaskedDots)).length.value,
      0,
      reason: 'the first entry may be the typo — both are wiped',
    );
  });

  testWidgets('a PIN is refused at the switch on a phone that cannot bind', (
    tester,
  ) async {
    await pump(
      tester,
      kind: vault_api.VaultInputKind.passphrase,
      canBind: false,
    );
    await type(tester, 'old');
    await tester.tap(find.widgetWithText(KvAction, 'Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use a 6-digit PIN'));
    await tester.pumpAndSettle();
    expect(find.text('Choose an unlock passphrase'), findsOneWidget);
    expect(find.byType(SecretKeyboard), findsOneWidget);
    expect(find.textContaining('cannot lock a PIN'), findsOneWidget);
  });

  testWidgets('a seal Rust refuses for the PIN\'s own sake returns to the '
      'chooser, on the keyboard, in Rust\'s words', (tester) async {
    await pump(
      tester,
      reseal: (_, _, _) async => throw refusal(
        'that PIN is one of the first anyone would try — pick digits that are '
        'not all the same and not in a row',
      ),
    );
    await type(tester, '481902');
    await type(tester, '112233');
    await type(tester, '112233');
    expect(find.text('Choose an unlock passphrase'), findsOneWidget);
    expect(find.textContaining('anyone would try'), findsOneWidget);
    expect(find.byType(SecretKeyboard), findsOneWidget);
  });

  testWidgets('any other seal failure says the secret is UNCHANGED — naming '
      'the one the vault KEEPS, not the one being chosen', (tester) async {
    // A passphrase vault whose user was choosing a PIN: the sentence must say
    // the passphrase is unchanged, never "your PIN is unchanged" about a PIN
    // they never had (`wallet-security-auditor`).
    await pump(
      tester,
      kind: vault_api.VaultInputKind.passphrase,
      reseal: (_, _, _) async =>
          throw refusal('vault storage write re-keyed blob: disk full'),
    );
    await type(tester, 'old');
    await tester.tap(find.widgetWithText(KvAction, 'Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use a 6-digit PIN'));
    await tester.pumpAndSettle();
    await type(tester, '902481');
    await type(tester, '902481');
    expect(find.textContaining('passphrase is unchanged'), findsOneWidget);
    expect(find.textContaining('PIN is unchanged'), findsNothing);
    // Back on the chooser, on the pad the user was on.
    expect(find.text('Choose an unlock PIN'), findsOneWidget);
  });

  testWidgets('the fingerprint offer closes the ceremony only where Path A is '
      'not already on, and names the new secret', (tester) async {
    final popped = <Object?>[];
    final seen = await pump(tester, pathA: pathANone, popped: popped);
    expect(tester.widget<KvSteps>(find.byType(KvSteps)).count, 4);
    await type(tester, '481902');
    await type(tester, '902481');
    await type(tester, '902481');
    expect(seen.resealed, hasLength(1));
    expect(find.text('Open with biometrics?'), findsOneWidget);
    expect(tester.widget<KvSteps>(find.byType(KvSteps)).index, 3);
    // The text action names the secret the vault now keeps (`O6`).
    expect(find.text('PIN only'), findsOneWidget);
    await tester.tap(find.widgetWithText(KvAction, 'Use biometrics'));
    await tester.pumpAndSettle();
    expect(seen.enrolled, 1);
    expect(popped, [vault_api.VaultInputKind.digits]);
  });

  testWidgets('…and "PIN only" leaves without enrolling', (tester) async {
    final popped = <Object?>[];
    final seen = await pump(tester, pathA: pathANone, popped: popped);
    await type(tester, '481902');
    await type(tester, '902481');
    await type(tester, '902481');
    await tester.tap(find.text('PIN only'));
    await tester.pumpAndSettle();
    expect(seen.enrolled, 0);
    expect(popped, [vault_api.VaultInputKind.digits]);
  });

  testWidgets('a cancelled system prompt is a choice: the offer stays', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, page) => KvWindow(child: page!),
        home: RekeyScreen(
          inputKind: () async => vault_api.VaultInputKind.digits,
          confirm: (_) async {},
          reseal: (_, _, _) async {},
          biometricStatus: () async => biometricReady,
          pathAState: () async => pathANone,
          enroll: () async =>
              throw PlatformException(code: 'cancelled', message: 'user'),
          checkAccessibility: () async => false,
          setSecure: ({required bool enable}) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await type(tester, '481902');
    await type(tester, '902481');
    await type(tester, '902481');
    await tester.tap(find.widgetWithText(KvAction, 'Use biometrics'));
    await tester.pumpAndSettle();
    expect(find.text('Open with biometrics?'), findsOneWidget);
    expect(find.textContaining('didn\'t complete'), findsNothing);
  });

  testWidgets('back is one beat, and re-asks the current secret', (
    tester,
  ) async {
    final seen = await pump(tester);
    await type(tester, '481902');
    expect(find.text('Choose an unlock PIN'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    // The bar's back target: the confirm beat, empty.
    expect(find.text('Enter your current PIN'), findsOneWidget);
    expect(tester.widget<MaskedDots>(find.byType(MaskedDots)).length.value, 0);
    await type(tester, '481902');
    expect(seen.confirmed, ['481902', '481902']);
  });

  testWidgets('the phone\'s back from the first beat leaves with nothing '
      'changed', (tester) async {
    final popped = <Object?>[];
    final seen = await pump(tester, popped: popped);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(popped, [null]);
    expect(seen.resealed, isEmpty);
  });

  testWidgets('every typing beat sits behind the secret-screen guard', (
    tester,
  ) async {
    await pump(tester, accessibility: true);
    expect(find.byType(KvKeypad), findsNothing);
    expect(find.text('Secure screen paused'), findsOneWidget);
  });

  testWidgets('at `short` the wells ride the foot and nothing overflows', (
    tester,
  ) async {
    await pump(tester, size: const Size(915, 412));
    expect(tester.takeException(), isNull);
    expect(find.text('Enter your current PIN'), findsOneWidget);
    expect(find.byType(MaskedDots), findsOneWidget);
    await type(tester, '481902');
    expect(find.text('Choose an unlock PIN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a failure that is NOT about the secret is said in Rust\'s words, '
    'never as "that is not your PIN"',
    (tester) async {
      await pump(
        tester,
        confirm: (_) async => throw refusal('vault storage read blob: gone'),
      );
      await type(tester, '111111');
      expect(find.textContaining('not this wallet'), findsNothing);
      expect(find.textContaining('read blob'), findsOneWidget);
    },
  );

  testWidgets('a lit primary over an empty field says so, on every beat', (
    tester,
  ) async {
    await pump(tester, kind: vault_api.VaultInputKind.passphrase);
    await tester.tap(find.widgetWithText(KvAction, 'Next'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your passphrase first.'), findsOneWidget);
    await type(tester, 'old');
    await tester.tap(find.widgetWithText(KvAction, 'Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(KvAction, 'Next'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a passphrase first.'), findsOneWidget);
    await type(tester, 'abc');
    await tester.tap(find.widgetWithText(KvAction, 'Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(KvAction, 'Set passphrase'));
    await tester.pumpAndSettle();
    expect(find.text('Enter it again first.'), findsOneWidget);
  });
}
