import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/create_screen.dart';
import 'package:kaspaverse/src/rust/api/vault.dart' as vault_api;
import 'package:kaspaverse/src/ui/secret/masked_dots.dart';
import 'package:kaspaverse/src/ui/secret/secret_keyboard.dart';
import 'package:kaspaverse/src/ui/secret/word_parts.dart';
import 'package:kaspaverse/src/ui/widgets/kv_chrome.dart';
import 'package:kaspaverse/src/ui/widgets/kv_glyph.dart';
import 'package:kaspaverse/src/ui/widgets/kv_keypad.dart';
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

  /// Focus a field and type into it — **the keypad does not exist until a field
  /// is tapped** (D-312 F18), so a test that types blind is asserting a pad the
  /// render does not draw.
  Future<void> typeInto(
    WidgetTester tester,
    String placeholder,
    List<String> chars, {
    Future<void> Function(Finder)? tap,
  }) async {
    final press =
        tap ??
        (Finder f) async {
          await tester.tap(f);
          await settle(tester);
        };
    await press(find.text(placeholder));
    for (final c in chars) {
      await press(find.text(c));
    }
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
        seal: (p, x, k) async {},
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
        seal: (p, x, k) async {
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
        seal: (p, x, k) async {
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
    await typeInto(tester, 'Type it here', ['b'], tap: (f) => reach(tester, f));
    await typeInto(tester, 'Type it again', [
      'b',
    ], tap: (f) => reach(tester, f));
    // ONE act, not two: `O5` draws one primary and D-312 collapsed the confirm
    // step into the same screen.
    await reach(
      tester,
      find.widgetWithText(KvAction, 'Continue with 13th word'),
    );

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
        seal: (p, x, k) async => onSeal(Uint8List.fromList(x)),
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
    // unrecoverable — so the two fields are DISABLED until it is on (D-312
    // F17); they are drawn either way, which is what says the word gets typed
    // twice before you have committed to typing it once.
    await press(find.byType(KvToggle));
  }

  testWidgets('BOTH boxes are on the glass before the switch is on', (
    tester,
  ) async {
    // **F17.** They used to appear only once the switch was flipped, so the
    // screen did not say *this word gets typed twice* until after you had
    // committed to typing it once. Drawn and disabled is the render.
    await pumpHost(
      tester,
      CreateScreen(
        begin: () async {},
        reveal: () async => true,
        abandon: () async {},
        seal: (p, x, k) async {},
        biometricStatus: () async => 'no_hardware',
        checkAccessibility: () async => false,
        setSecure: ({required bool enable}) async {},
      ),
    );
    await settle(tester);
    await tester.tap(find.text('a'));
    await settle(tester);
    await reach(tester, find.widgetWithText(KvAction, 'Next'));

    expect(find.text('Add a 13th word?'), findsOneWidget);
    expect(find.byType(KvSecretField), findsNWidgets(2));
    for (final f in tester.widgetList<KvSecretField>(
      find.byType(KvSecretField),
    )) {
      expect(f.enabled, isFalse, reason: 'disabled until the switch is on');
    }
    // …and no keyboard, on a screen whose render draws none (F18).
    expect(find.byType(SecretKeyboard), findsNothing);
  });

  testWidgets('the keypad rises on a field tap and falls on a tap outside', (
    tester,
  ) async {
    // **F18.** Ours is not a system IME, so this is a layout contract rather
    // than a flag — including the half a system IME gives for free: a pad this
    // app raises is a pad this app has to be able to lower.
    await toExtraWord(tester, onSeal: (_) {});
    expect(find.byType(SecretKeyboard), findsNothing);

    await reach(tester, find.text('Type it here'));
    expect(find.byType(SecretKeyboard), findsOneWidget);

    // The heading is body, not a field.
    await reach(tester, find.text('Add a 13th word?'));
    expect(find.byType(SecretKeyboard), findsNothing);
  });

  testWidgets('a mistyped extra word cannot even be submitted', (tester) async {
    // **F19, and it is the F1 property enforced a beat earlier.** The word is
    // seed-determining: one wrong character seals a wallet the user's own
    // written backup can never reproduce, with no delete path and no
    // seal-over-an-existing-blob to test it with. It used to be *caught* after
    // a second screen; now the act is simply not offered until the two agree.
    var sealCalls = 0;
    await toExtraWord(tester, onSeal: (_) => sealCalls++);

    await typeInto(tester, 'Type it here', ['b'], tap: (f) => reach(tester, f));
    await typeInto(tester, 'Type it again', [
      'c',
    ], tap: (f) => reach(tester, f));

    // **The act is not offered at all.** A disabled `KvAction` paints its
    // reason AS its label, so the pill that would have sealed the wallet is
    // now the sentence explaining why it will not (BG-8/BG-12: a dead control
    // that does not say why is a control that looks broken).
    expect(
      find.widgetWithText(KvAction, 'Continue with 13th word'),
      findsNothing,
    );
    expect(find.textContaining('do not match yet'), findsOneWidget);
    expect(sealCalls, 0);
    expect(find.text('Add a 13th word?'), findsOneWidget);
  });

  testWidgets('the mismatch reason is ON SCREEN on a small phone at 1.3x', (
    tester,
  ) async {
    // Proving the message exists is not proving the user can read it. Laid out
    // after both buttons it began ~416 dp down a 360 dp viewport — present in
    // the tree, findable by `find.textContaining`, and entirely below the
    // fold. Every other test here runs at the reference frame and would have
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
    await typeInto(tester, 'Type it here', ['b'], tap: tapScrolled);
    await typeInto(tester, 'Type it again', ['c'], tap: tapScrolled);

    final message = find.textContaining('do not match yet');
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

    await typeInto(tester, 'Type it here', [
      'b',
      'c',
    ], tap: (f) => reach(tester, f));
    await typeInto(tester, 'Type it again', [
      'b',
      'c',
    ], tap: (f) => reach(tester, f));
    await reach(
      tester,
      find.widgetWithText(KvAction, 'Continue with 13th word'),
    );

    expect(sealedExtra, equals(Uint8List.fromList([0x62, 0x63]))); // 'bc'
  });

  testWidgets('a longer confirm than entry does not match', (tester) async {
    // The length-mismatch arm: a dropped or doubled character is exactly what
    // a dot count cannot show, since the user cannot see the word to count
    // against — unless they hold the eye, which is the next test.
    var sealCalls = 0;
    await toExtraWord(tester, onSeal: (_) => sealCalls++);

    await typeInto(tester, 'Type it here', ['b'], tap: (f) => reach(tester, f));
    await typeInto(tester, 'Type it again', [
      'b',
      'b',
    ], tap: (f) => reach(tester, f));

    expect(sealCalls, 0);
    expect(find.textContaining('do not match yet'), findsOneWidget);
  });

  testWidgets('the eye shows the word only while it is HELD', (tester) async {
    // **D-312 §3, and the fence is the test.** The founder asked for the eye
    // after hearing why it had not been built; what makes it acceptable is
    // that the `String` behind it exists for the length of a gesture, on a
    // FLAG_SECURE screen, and never for the length of a screen. A sticky
    // toggle would break exactly that, and nothing else here would notice.
    await toExtraWord(tester, onSeal: (_) {});
    await typeInto(tester, 'Type it here', [
      'b',
      'c',
    ], tap: (f) => reach(tester, f));

    expect(find.text('bc'), findsNothing, reason: 'masked by default');

    final eye = find.byWidgetPredicate(
      (w) => w is KvGlyphIcon && w.mark == KvGlyph.eye,
      description: "O5's eye",
    );
    expect(eye, findsOneWidget);
    await tester.ensureVisible(eye);
    await settle(tester);
    final press = await tester.startGesture(tester.getCenter(eye));
    await settle(tester);
    expect(find.text('bc'), findsOneWidget, reason: 'visible while held');

    await press.up();
    await settle(tester);
    expect(find.text('bc'), findsNothing, reason: 'gone on release');
  });

  testWidgets(
    'backing out of the extra word is ONE step, and takes both boxes',
    (tester) async {
      // The two-step model is gone (D-312), so back from here lands on the
      // passphrase — the step before it — rather than on a confirm screen that
      // no longer exists. Both buffers go with it: a half-typed secret does not
      // survive the step it belongs to (INV-1/3), and a buffer that survived and
      // was APPENDED to on re-entry produced a warning whose stated cause was
      // false (`wallet-security-auditor`, UX-R6).
      await toExtraWord(tester, onSeal: (_) {});
      await typeInto(tester, 'Type it here', [
        'b',
      ], tap: (f) => reach(tester, f));
      await reach(tester, find.bySemanticsLabel('Back'));

      expect(find.text('Choose an unlock passphrase'), findsOneWidget);
      // **The passphrase went with it**, which is not tidiness: on the PIN path
      // the wells would otherwise arrive full on a screen whose only commit is
      // the sixth digit (`wallet-security-auditor`, D-312). So it is retyped.
      expect(
        tester.widget<MaskedDots>(find.byType(MaskedDots)).length.value,
        0,
      );
      await reach(tester, find.text('a'));

      // Forward again: both boxes are back to their placeholders.
      await reach(tester, find.widgetWithText(KvAction, 'Next'));
      expect(find.text('Type it here'), findsOneWidget);
      expect(find.text('Type it again'), findsOneWidget);
    },
  );

  testWidgets('Skip still seals an empty extra word', (tester) async {
    // The audit's constraint: the Skip path wipes to empty first and must be
    // untouched by the match gate.
    Uint8List? sealedExtra;
    await toExtraWord(tester, onSeal: (x) => sealedExtra = x);
    // The switch is ON here — `toExtraWord` flips it — so this is the plain
    // text way past a step the user has already opened, which is the path the
    // audit's constraint is about.
    await reach(tester, find.text('Skip — 12 words only'));

    expect(sealedExtra, isEmpty);
  });

  testWidgets('an empty entry is not sealed by the primary button', (
    tester,
  ) async {
    var sealCalls = 0;
    await toExtraWord(tester, onSeal: (_) => sealCalls++);

    // Skip owns the empty path, and the primary says so rather than refusing
    // silently — it is not tappable at all, which is the F19 shape.
    expect(
      find.widgetWithText(KvAction, 'Continue with 13th word'),
      findsNothing,
    );
    expect(find.textContaining('in both boxes first'), findsOneWidget);
    expect(sealCalls, 0);
  });

  // ── D-312 · the pad is a CHOICE, and the PIN never ships alone ──────────

  /// Walk to `O2` with the binding lane and the seal seam injected.
  Future<void> toPassphrase(
    WidgetTester tester, {
    required Future<bool> Function() binding,
    void Function(Uint8List pass, vault_api.VaultInputKind kind)? onSeal,
    Future<int> Function()? wordCount,
  }) async {
    await pumpHost(
      tester,
      CreateScreen(
        begin: () async {},
        reveal: () async => true,
        abandon: () async {},
        seal: (p, x, k) async => onSeal?.call(Uint8List.fromList(p), k),
        biometricStatus: () async => 'no_hardware',
        deviceBinding: binding,
        wordCount: wordCount,
        checkAccessibility: () async => false,
        setSecure: ({required bool enable}) async {},
      ),
    );
    await settle(tester);
    expect(find.text('Choose an unlock passphrase'), findsOneWidget);
  }

  testWidgets('the keyboard is the default, and the PIN is one tap away', (
    tester,
  ) async {
    await toPassphrase(tester, binding: () async => true);

    // The keyboard pad, a commit control, and the offer of the other pad.
    expect(find.byType(SecretKeyboard), findsOneWidget);
    expect(find.widgetWithText(KvAction, 'Next'), findsOneWidget);
    await reach(tester, find.text('Use a 6-digit PIN'));

    // `O2`: six wells, a number pad, and **no commit** — the sixth digit is
    // the commit, which is what every lock screen on the phone already does.
    expect(find.byType(SecretKeyboard), findsNothing);
    expect(find.byType(KvKeypad), findsOneWidget);
    expect(find.widgetWithText(KvAction, 'Next'), findsNothing);
    expect(find.text('Use a keyboard passphrase'), findsOneWidget);
    expect(
      tester.widget<MaskedDots>(find.byType(MaskedDots)).slots,
      6,
      reason: '`O2` draws six wells, and empty slots need a known total',
    );
  });

  testWidgets('a phone that cannot hardware-bind is REFUSED the PIN', (
    tester,
  ) async {
    // **The founder's own condition when he took the option: the PIN and the
    // hardware key ship together or neither ships** (D-312). Six digits with
    // no binding is 10^6 candidates at ~679 ms each for anyone who lifts the
    // file — a real downgrade from the passphrase it would replace.
    //
    // Rust refuses it again at the seal (`binding_for`), because a rule that
    // lives only in a screen is a rule the next screen will not have. This is
    // the half that means a user finds out while choosing rather than with
    // their twelve words already written down.
    await toPassphrase(tester, binding: () async => false);
    await reach(tester, find.text('Use a 6-digit PIN'));

    expect(find.byType(SecretKeyboard), findsOneWidget, reason: 'unchanged');
    expect(find.textContaining('cannot lock a PIN'), findsOneWidget);
    expect(find.text('Use a 6-digit PIN'), findsOneWidget);
  });

  testWidgets('the sixth digit commits, and the pad choice reaches the seal', (
    tester,
  ) async {
    Uint8List? sealedPass;
    vault_api.VaultInputKind? sealedKind;
    await toPassphrase(
      tester,
      binding: () async => true,
      onSeal: (p, k) {
        sealedPass = p;
        sealedKind = k;
      },
    );
    await reach(tester, find.text('Use a 6-digit PIN'));

    for (final d in ['1', '2', '3', '4', '5']) {
      await reach(tester, find.text(d));
    }
    // Five is not six: still on `O2`, nothing committed.
    expect(find.text('Choose an unlock passphrase'), findsOneWidget);

    await reach(tester, find.text('6'));
    expect(find.text('Add a 13th word?'), findsOneWidget);

    // Skip the extra word and seal, so the kind can be observed crossing.
    await reach(
      tester,
      find.widgetWithText(KvAction, 'Continue — 12 words only'),
    );
    expect(sealedPass, equals(Uint8List.fromList('123456'.codeUnits)));
    expect(
      sealedKind,
      vault_api.VaultInputKind.digits,
      reason: 'the blob header records what the user typed on (D-312)',
    );
  });

  testWidgets('switching pads WIPES what was typed on the other one', (
    tester,
  ) async {
    // The two pads do not share an alphabet, and a half-typed secret does not
    // survive the pad that was typing it (INV-1/3).
    await toPassphrase(tester, binding: () async => true);
    await reach(tester, find.text('a'));
    await reach(tester, find.text('Use a 6-digit PIN'));

    expect(
      tester.widget<MaskedDots>(find.byType(MaskedDots)).length.value,
      0,
      reason: 'the keyboard entry did not survive the switch',
    );
  });

  testWidgets('backing out of the extra word does not strand a full PIN', (
    tester,
  ) async {
    // On the PIN path `O2` has no commit control — the sixth digit is the
    // commit — so returning to six already-full wells was a screen with no way
    // forward at all (`wallet-security-auditor`, D-312).
    await toPassphrase(tester, binding: () async => true);
    await reach(tester, find.text('Use a 6-digit PIN'));
    for (final d in ['4', '8', '1', '9', '0', '2']) {
      await reach(tester, find.text(d));
    }
    expect(find.text('Add a 13th word?'), findsOneWidget);

    await reach(tester, find.bySemanticsLabel('Back'));
    expect(find.text('Choose an unlock passphrase'), findsOneWidget);
    expect(
      tester.widget<MaskedDots>(find.byType(MaskedDots)).length.value,
      0,
      reason: 'the wells are empty, so the pad can commit again',
    );
    // …and it really can: six more digits move on.
    for (final d in ['4', '8', '1', '9', '0', '2']) {
      await reach(tester, find.text(d));
    }
    expect(find.text('Add a 13th word?'), findsOneWidget);
  });

  testWidgets('a PIN Rust refuses sends the user back with the reason', (
    tester,
  ) async {
    // Two refusals are actionable and "try again" is the wrong answer to both:
    // a phone that cannot bind, and a PIN anyone would guess first. Both are
    // resolved by a different CHOICE, so the screen goes back to the choice
    // and says which one (`wallet-security-auditor`, D-312).
    await pumpHost(
      tester,
      CreateScreen(
        begin: () async {},
        reveal: () async => true,
        abandon: () async {},
        seal: (p, x, k) async =>
            throw StateError('that PIN is one of the first anyone would try'),
        biometricStatus: () async => 'no_hardware',
        deviceBinding: () async => true,
        checkAccessibility: () async => false,
        setSecure: ({required bool enable}) async {},
      ),
    );
    await settle(tester);
    await reach(tester, find.text('Use a 6-digit PIN'));
    for (final d in ['1', '2', '3', '4', '5', '6']) {
      await reach(tester, find.text(d));
    }
    await reach(
      tester,
      find.widgetWithText(KvAction, 'Continue — 12 words only'),
    );

    expect(find.text('Choose an unlock passphrase'), findsOneWidget);
    expect(find.textContaining('anyone would try'), findsOneWidget);
    expect(
      tester.widget<MaskedDots>(find.byType(MaskedDots)).length.value,
      0,
      reason: 'the refused PIN does not survive the refusal',
    );
  });

  // ── D-312 · `12 | 24`, and the ordinal that follows it ──────────────────

  testWidgets('a 24-word ceremony names the extra word a 25th', (tester) async {
    // **The reversal of D-028, at the only place Dart can see it.** The count
    // is chosen on the NATIVE reveal surface (`O3`'s control), so what this
    // screen owes is to read it back and name the extra word by its ordinal —
    // a wrong ordinal is a wrong instruction on the one piece of paper that
    // restores the wallet.
    //
    // **And no copy on this path says or implies 24 is more secure**, because
    // it is not: 12 words is 128 bits, which already saturates secp256k1's
    // ~128-bit effective security (D-312).
    await toPassphrase(
      tester,
      binding: () async => true,
      wordCount: () async => 24,
    );
    await reach(tester, find.text('a'));
    await reach(tester, find.widgetWithText(KvAction, 'Next'));

    expect(find.text('Add a 25th word?'), findsOneWidget);
    expect(find.text('Continue — 24 words only'), findsOneWidget);
    expect(find.textContaining('YOUR 25TH WORD'), findsOneWidget);
    for (final claim in ['more secure', 'stronger', 'safer', 'recommended']) {
      expect(
        find.textContaining(claim, findRichText: true),
        findsNothing,
        reason: '24 words is not stronger, and nothing may imply it is',
      );
    }
  });

  testWidgets('a count read that fails does not abandon a verified ceremony', (
    tester,
  ) async {
    // The ceremony is verified by this point — the user has written twelve
    // words down and passed a quiz on them. A failed count read must not be
    // caught by the enclosing handler that abandons.
    await toPassphrase(
      tester,
      binding: () async => true,
      wordCount: () async => throw StateError('no ceremony'),
    );
    expect(find.text('Choose an unlock passphrase'), findsOneWidget);
    await reach(tester, find.text('a'));
    await reach(tester, find.widgetWithText(KvAction, 'Next'));
    expect(find.text('Add a 13th word?'), findsOneWidget);
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
        seal: (p, x, k) async {},
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
