import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/vault.dart';
import 'package:kaspaverse/src/services/vault_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The L9 property under its WORST case: on the host there is no native
  // library, so the bridge call throws — and the finally-wipe must fire
  // anyway. A wipe that only runs on the success path is the exact leak
  // class L9 records (a throw between use and wipe).
  test(
    'passphrase buffer is zeroed even when the bridge call throws',
    () async {
      final passphrase = Uint8List.fromList(List.filled(32, 0x42));

      await expectLater(
        VaultService.instance.unlockWithPassphrase(passphrase),
        throwsA(anything),
      );

      expect(
        passphrase.every((b) => b == 0),
        isTrue,
        reason: 'finally-wipe must zero the caller buffer on the throw path',
      );
    },
  );

  test('sealAndPersist wipes its buffers on the throw path too', () async {
    final passphrase = Uint8List.fromList(List.filled(16, 0x7A));
    final extraWord = Uint8List.fromList(List.filled(4, 0x33));

    await expectLater(
      VaultService.instance.sealAndPersist(
        passphrase,
        extraWord,
        // Explicit params: the tuned() fetch is itself a bridge call that would
        // throw on host BEFORE sealAndPersist runs — passing params makes the
        // sealAndPersist call the one under test.
        params: const VaultKdfParams(mCostKib: 65536, tCost: 3, pCost: 1),
      ),
      throwsA(anything),
    );

    expect(passphrase.every((b) => b == 0), isTrue);
    expect(extraWord.every((b) => b == 0), isTrue);
  });

  // ── D-133: the auto-lock grace, and the ceremony handoff ─────────────────

  group('auto-lock policy', () {
    late List<String> locks;
    late DateTime now;

    setUp(() {
      locks = [];
      now = DateTime(2026, 8, 12, 12, 0, 0);
      VaultService.lockVaultFn = () async => locks.add('lock');
      VaultService.readLockGraceFn = () async => 0;
      VaultService.writeLockGraceFn = (_) async {};
      VaultService.instance.clock = () => now;
    });

    tearDown(() {
      // Order matters: neuter the lock first, THEN resume — which cancels any
      // timer this case armed. A watchdog surviving into the next test would
      // append to *its* `locks` list, which is a flake that reads like a bug in
      // whatever ran next.
      VaultService.lockVaultFn = () async {};
      VaultService.instance.didChangeAppLifecycleState(
        AppLifecycleState.resumed,
      );
      VaultService.presenceWindow = const Duration(seconds: 10);
      VaultService.instance.clock = DateTime.now;
    });

    void background() => VaultService.instance.didChangeAppLifecycleState(
      AppLifecycleState.paused,
    );
    void foreground() => VaultService.instance.didChangeAppLifecycleState(
      AppLifecycleState.resumed,
    );

    test(
      'the default is the pre-D-133 behaviour exactly — lock on background',
      () async {
        await VaultService.instance.setLockGraceSecs(0);
        background();
        expect(locks, [
          'lock',
        ], reason: 'grace 0 must lock the instant we leave');
      },
    );

    test('inside the grace, coming straight back does NOT lock', () async {
      await VaultService.instance.setLockGraceSecs(60);
      background();
      expect(locks, isEmpty);
      now = now.add(const Duration(seconds: 20));
      foreground();
      expect(locks, isEmpty, reason: 'a quick app-switch is the whole feature');
    });

    test('a phone that slept through the grace comes back LOCKED', () async {
      // The enforcement that matters. A backgrounded Dart isolate can be frozen
      // by the OS, so the timer is best-effort — trusting it alone would mean a
      // phone that dozed past the grace resumed with the vault still open.
      await VaultService.instance.setLockGraceSecs(60);
      background();
      now = now.add(const Duration(minutes: 30)); // no timer ever fired
      foreground();
      expect(locks, ['lock']);
    });

    test(
      'a second lifecycle event cannot extend the grace past its ceiling',
      () async {
        // wallet-security-auditor. `paused` at t0 arms the full grace; Android
        // then destroys the activity near the end and `detached` arrives, which
        // cancelled and re-armed a FRESH full grace — roughly 2× the ceiling,
        // failing open at exactly the moment the ceiling is supposed to hold.
        // The timer must run for what is LEFT, measured from the departure.
        await VaultService.instance.setLockGraceSecs(60);
        background(); // t0
        now = now.add(const Duration(seconds: 55));
        VaultService.instance.didChangeAppLifecycleState(
          AppLifecycleState.detached,
        );
        // 5 s left of the original grace, not another 60.
        now = now.add(const Duration(seconds: 6));
        foreground();
        expect(locks, ['lock']);
      },
    );

    test(
      'a resume delivered mid-ceremony does not break the deferral',
      () async {
        // wallet-security-auditor. At the default grace of 0, `elapsed >= 0` is
        // unconditionally true, so any resume arriving before the ceremony's
        // future completed locked the vault while the prompt was still up — the
        // exact path the deferral exists to hold. Latent only because AndroidX
        // usually resolves the ceremony first, which is message ordering rather
        // than a guarantee.
        await VaultService.instance.setLockGraceSecs(0);
        final ceremony = VaultService.instance.runCeremony(() async {
          background();
          foreground(); // arrives while the prompt is still up
          expect(locks, isEmpty, reason: 'the ceremony still owns the window');
          return true;
        });
        expect(await ceremony, isTrue);
        expect(locks, isEmpty);
      },
    );

    test(
      'a cancelled ceremony the user is PRESENT for does not arm a lock',
      () async {
        // wallet-security re-audit finding 2. The prompt pauses Flutter, the user
        // taps "Use passphrase", the resume lands, and the cancel then armed a
        // full grace that ran on INTO the foreground — locking the wallet mid-use
        // a minute later, from the ordinary "changed my mind" path.
        VaultService.presenceWindow = const Duration(milliseconds: 40);
        await VaultService.instance.setLockGraceSecs(60);
        await VaultService.instance.runCeremony(() async {
          background(); // the prompt's own window transition
          foreground(); // …and it dismissed; the user never left
          return false; // cancelled
        });
        now = now.add(const Duration(minutes: 5));
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(
          locks,
          isEmpty,
          reason: 'the app never actually left — there is nothing to act on',
        );
      },
    );

    test(
      'a later lifecycle event cannot erase the tighter presence bound',
      () async {
        // wallet-security re-audit finding 3. `detached` after a completed
        // ceremony re-stamped the departure and armed the FULL grace, cancelling
        // the 10 s watchdog — presence, the tighter bound, erased by the looser
        // one it exists to replace. Total exposure landed past the ceiling.
        VaultService.presenceWindow = const Duration(milliseconds: 40);
        await VaultService.instance.setLockGraceSecs(900);
        await VaultService.instance.runCeremony(() async {
          background();
          return true; // presence proven, app still away
        });
        VaultService.instance.didChangeAppLifecycleState(
          AppLifecycleState.detached,
        );
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(locks, [
          'lock',
        ], reason: 'the 40 ms presence deadline must survive a 900 s re-arm');
      },
    );

    test('the grace is clamped — it can never become an off switch', () async {
      var written = -1;
      VaultService.writeLockGraceFn = (secs) async => written = secs;
      await VaultService.instance.setLockGraceSecs(99999);
      expect(written, VaultService.maxLockGraceSecs);
      expect(
        VaultService.instance.lockGraceSecs.value,
        VaultService.maxLockGraceSecs,
      );
    });

    test(
      'a COMPLETED ceremony proves presence, so the deferred lock is dropped',
      () async {
        await VaultService.instance.setLockGraceSecs(0);
        // The suspected race: the system prompt takes the foreground, Flutter
        // reports paused, and the §0.11 lock would fire mid-enrolment — export
        // the seed, get "vault is locked", swallow it, pop. "Nothing happened."
        final ceremony = VaultService.instance.runCeremony(() async {
          background();
          expect(locks, isEmpty, reason: 'suppressed for the handoff');
          return true; // the user put a finger on the sensor
        });
        expect(await ceremony, isTrue);
        expect(
          locks,
          isEmpty,
          reason: 'a completed biometric ceremony IS proof of presence',
        );
      },
    );

    test(
      'a CANCELLED ceremony proves nothing, so the deferred lock is honoured',
      () async {
        await VaultService.instance.setLockGraceSecs(0);
        final ceremony = VaultService.instance.runCeremony(() async {
          background(); // the user actually left the app
          return false; // ...so the prompt was cancelled
        });
        expect(await ceremony, isFalse);
        // Deferring must never become discarding: an unlocked vault left behind a
        // suppression is a custody downgrade wearing a bug fix's clothes.
        expect(locks, ['lock']);
      },
    );

    test(
      'presence is BOUNDED — it holds the vault open, it does not own it',
      () async {
        // ffi-leak-auditor, this session. The one path through `runCeremony` that
        // skips `_armLock` was unbounded: a ceremony that completed while the app
        // stayed backgrounded left `_pausedAt` set with no timer, so the vault
        // could sit open past MAX_LOCK_GRACE_SECS — the ceiling failing exactly
        // where it exists to hold. Proof the user WAS there is not a promise that
        // they come back.
        VaultService.presenceWindow = const Duration(milliseconds: 40);
        await VaultService.instance.setLockGraceSecs(0);
        await VaultService.instance.runCeremony(() async {
          background();
          return true; // authenticated, but the app is still away
        });
        expect(locks, isEmpty, reason: 'presence holds it open, for now');

        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(locks, [
          'lock',
        ], reason: 'a resume that never came must not buy an open vault');
      },
    );

    test('presence that DOES come back keeps the vault open', () async {
      VaultService.presenceWindow = const Duration(milliseconds: 40);
      await VaultService.instance.setLockGraceSecs(0);
      await VaultService.instance.runCeremony(() async {
        background();
        return true;
      });
      foreground(); // the prompt dismissed and the app came straight back
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        locks,
        isEmpty,
        reason:
            'the whole point: a fingerprint must not send you to the lock '
            'screen it just unlocked',
      );
    });

    test('a ceremony that throws still settles the deferred lock', () async {
      await VaultService.instance.setLockGraceSecs(0);
      await expectLater(
        VaultService.instance.runCeremony(() async {
          background();
          throw PlatformException(code: 'vault');
        }),
        throwsA(anything),
      );
      expect(locks, [
        'lock',
      ], reason: 'the finally must settle it on the throw path');
    });

    test('an unreadable grace setting falls back to locking immediately', () async {
      VaultService.readLockGraceFn = () async => throw Exception('no bridge');
      await VaultService.instance.setLockGraceSecs(300);
      // Re-read the way `start()` does. Every other persisted count in this app
      // falls back to what costs the user a re-probe; this one must fall back to
      // what costs an ATTACKER everything.
      VaultService.readLockGraceFn = () async => throw Exception('no bridge');
      await VaultService.instance.reloadLockGraceForTest();
      background();
      expect(locks, ['lock']);
    });
  });
}
