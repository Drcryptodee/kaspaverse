import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/vault.dart' as vault_api;
import 'package:kaspaverse/src/ui/biometric_copy.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/unlock_surface.dart';
import 'package:kaspaverse/src/ui/widgets/kv_loader.dart';
import 'package:kaspaverse/src/ui/widgets/kv_lock_mark.dart';

/// The app mounts `KvWindow` at its root (UX-R1) and `KvColumn` asserts on its
/// absence rather than falling back to compact — so a screen test has to mount
/// it too, exactly as `create_screen_test` does.
Future<void> _pump(
  WidgetTester tester, {
  required Future<bool> Function() probe,
  Future<bool> Function()? unlock,
  Future<vault_api.VaultInputKind> Function()? inputKind,
  ValueListenable<DateTime?>? lockedAt,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, page) => KvWindow(child: page!),
      home: UnlockSurface(
        probe: probe,
        unlock: unlock ?? () async => true,
        // Never the real lane in a host test: it would reach the bridge.
        inputKind: inputKind ?? () async => vault_api.VaultInputKind.passphrase,
        lockedAt: lockedAt ?? ValueNotifier<DateTime?>(null),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // `find.bySemanticsLabel` needs the tree built.
  setUp(() => SemanticsBinding.instance.ensureSemantics());

  testWidgets('biometric ready → the Unlock pill, and success HOLDS busy', (
    tester,
  ) async {
    await _pump(tester, probe: () async => true, unlock: () async => true);

    expect(find.text('Unlock'), findsOneWidget);
    // The render's emblem, not a ceremony mark.
    expect(find.byType(KvLockMark), findsOneWidget);

    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();

    // On success the surface stays busy — it must NOT flash back to idle (the
    // status stream swaps it for home; P1.3 watch-out).
    expect(find.text('Unlocking…'), findsOneWidget);
    expect(find.text('Unlock'), findsNothing);
  });

  testWidgets('a cancelled unlock returns to idle with a calm, safe message', (
    tester,
  ) async {
    await _pump(tester, probe: () async => true, unlock: () async => false);

    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Your funds are safe'), findsOneWidget);
    expect(find.text('Unlock'), findsOneWidget); // idle again, so retry works
  });

  testWidgets('no Path-A enrolled → the passphrase takes the primary pill', (
    tester,
  ) async {
    await _pump(tester, probe: () async => false);

    // `Unlock-selection (1).png`: when the biometric is not on offer, Path B
    // IS the unlock and takes the pill rather than sitting under a dead one.
    expect(find.text('Enter passphrase'), findsOneWidget);
    expect(find.text('Unlock'), findsNothing);
    // And the "instead" escape is gone with it — there is nothing to instead.
    expect(find.text('Use passphrase instead'), findsNothing);
  });

  testWidgets('a probe that THROWS still renders a way in (INV-6 liveness)', (
    tester,
  ) async {
    await _pump(tester, probe: () async => throw Exception('no channel'));

    expect(find.text('Enter passphrase'), findsOneWidget);
  });

  group('the pad the vault remembers names the secret on the door', () {
    testWidgets('a Digits vault says PIN, everywhere it says it', (
      tester,
    ) async {
      await _pump(
        tester,
        probe: () async => false,
        inputKind: () async => vault_api.VaultInputKind.digits,
      );

      expect(find.text('Enter PIN'), findsOneWidget);
      expect(find.text('Use PIN instead'), findsNothing);
      expect(find.text('Enter passphrase'), findsNothing);
    });

    testWidgets('a read that fails keeps the word that fits either secret', (
      tester,
    ) async {
      await _pump(
        tester,
        probe: () async => false,
        inputKind: () async => throw Exception('no blob'),
      );

      // The same safe direction the pad rule keeps (D-312): never guess PIN.
      expect(find.text('Enter passphrase'), findsOneWidget);
      expect(find.text('Enter PIN'), findsNothing);
    });
  });

  group('Locked at', () {
    testWidgets('is not drawn when this process never watched the lock', (
      tester,
    ) async {
      await _pump(tester, probe: () async => true);

      // A cold start onto a sealed vault has no transition to have seen, and
      // a formatted `DateTime.now()` there is BG-8 (invisible, and wrong).
      expect(find.textContaining('Locked at'), findsNothing);
    });

    testWidgets('is drawn from the observed stamp when there is one', (
      tester,
    ) async {
      await _pump(
        tester,
        probe: () async => true,
        lockedAt: ValueNotifier<DateTime?>(DateTime(2026, 9, 9, 9, 41)),
      );

      expect(find.textContaining('Locked at'), findsOneWidget);
      expect(find.textContaining('9:41'), findsOneWidget);
    });
  });

  testWidgets('an invalidated key becomes a standing notice, not a retry', (
    tester,
  ) async {
    await _pump(
      tester,
      probe: () async => true,
      unlock: () async =>
          throw PlatformException(code: biometricKeyInvalidated),
    );

    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();

    // The render's amber plate carries the app's own audited sentence — and
    // that sentence sends the user to Settings, because a Path-B unlock does
    // NOT re-trust the key on its own (the render's copy claims it does).
    expect(find.text(biometricInvalidatedCopy()), findsOneWidget);
    expect(
      find.textContaining('turn fingerprint unlock on again'),
      findsOneWidget,
    );
    // The dead lane stops being offered, and Path B takes the pill.
    expect(find.text('Enter passphrase'), findsOneWidget);
    expect(find.text('Unlock'), findsNothing);
  });

  testWidgets('a probe that NEVER answers still states the way out', (
    tester,
  ) async {
    // `wallet-security-auditor`, UX-R7. `_probe()`'s `catch (_)` cannot reach
    // this one: a MethodChannel reply that never arrives is swallowed by
    // `DartMessenger`, so the future stays pending and `_biometricReady` stays
    // null for ever. The foot's early return used to render nothing but a
    // spinner — no pill, no hand-off, no recovery — on the one screen standing
    // between a user and their funds (INV-6's liveness shadow).
    final wedged = Completer<bool>();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, page) => KvWindow(child: page!),
        home: UnlockSurface(
          probe: () => wedged.future,
          unlock: () async => true,
          inputKind: () async => vault_api.VaultInputKind.passphrase,
          lockedAt: ValueNotifier<DateTime?>(null),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 5));

    // The pill's seat is held rather than left empty, so the foot does not
    // jump 56 dp the instant the probe answers — and nothing claims a lane
    // that has not reported yet.
    expect(find.byType(KvLoader), findsOneWidget);
    expect(find.text('Unlock'), findsNothing);
    expect(find.text('Enter passphrase'), findsNothing);
  });

  group("the render's ONE text action, and no recovery sheet", () {
    // **Founder's ruling, on glass 2026-09-10**: *"remove the whole info icon
    // and remove the lost passphrase/pin thingy. just remove it."*
    //
    // Pinned because an auditor seated this twice — wallet-security's run-1
    // F6, then `ffi-leak-auditor` this sitting when a relocation put it behind
    // `SecretScreenGuard`. It is gone by decision, not by accident, and a
    // future pass that re-adds it on the same reasoning should have to change
    // this test and read D-316 §6 while doing it.
    testWidgets('with a biometric on offer, the hand-off and nothing else', (
      tester,
    ) async {
      await _pump(tester, probe: () async => true);

      expect(find.text('Use passphrase instead'), findsOneWidget);
      expect(find.textContaining('Lost your'), findsNothing);
      expect(find.bySemanticsLabel('Lost your passphrase?'), findsNothing);
    });

    testWidgets('with none, the pill stands alone under the emblem', (
      tester,
    ) async {
      await _pump(tester, probe: () async => false);

      expect(find.text('Enter passphrase'), findsOneWidget);
      expect(find.text('Use passphrase instead'), findsNothing);
      expect(find.textContaining('Lost your'), findsNothing);
    });
  });
}
