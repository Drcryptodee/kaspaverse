import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/rust/api/send.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/biometric_copy.dart';
import 'package:kaspaverse/src/ui/home_screen.dart';
import 'package:kaspaverse/src/ui/settings_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';

/// Track 2. Two properties matter here and they are different properties:
///
/// 1. **Reachability.** A setting nobody can open is a setting that does not
///    exist — which is literally how biometric enrolment came to be unreachable
///    after a restore while its native lane was complete and device-proven. So
///    the walk starts at Home and taps its way in.
/// 2. **Honesty.** Every row states a true thing about the state it reports,
///    including the states where the answer is "we cannot".
/// Without the real fonts the test font inflates every glyph and the measured
/// widths mean nothing — the result would be a number about Ahem, not about what
/// a user sees.
///
/// Called from `setUpAll`, NEVER from inside `testWidgets`: the test body runs in
/// a fake-async zone where real file I/O never completes, so the load hangs until
/// the harness gives up (observed: the suite sat for 2m57s and then died with
/// "Cannot close sink while adding stream").
Future<void> loadBundledFonts() async {
  for (final font in const {
    'Inter': 'assets/fonts/Inter-Variable.ttf',
    'JetBrainsMono': 'assets/fonts/JetBrainsMono-Variable.ttf',
  }.entries) {
    final bytes = await File(font.value).readAsBytes();
    await (FontLoader(
      font.key,
    )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  }
}

void main() {
  setUpAll(loadBundledFonts);

  const scanned = DeepScanReport(
    depth: 2048,
    receiveSeen: 13,
    changeSeen: 79,
    widened: false,
  );

  SettingsScreen screen({
    Future<String> Function()? biometricStatus,
    Future<String> Function()? pathAState,
    Future<bool> Function()? enroll,
    Future<void> Function()? clear,
    ValueNotifier<int>? grace,
    Future<void> Function(int)? setGrace,
    Future<DeepScanReport> Function()? deepScan,
    Future<String> Function()? receiveAddress,
    Future<Map<String, String>> Function()? packageInfo,
    Future<SignableSummaryDto> Function()? consolidate,
  }) => SettingsScreen(
    security: SecurityScope(
      biometricStatus: biometricStatus ?? () async => 'ready',
      pathAState: pathAState ?? () async => pathANone,
      enroll: enroll ?? () async => true,
      clearEnrollment: clear ?? () async {},
      lockGraceSecs: grace ?? ValueNotifier(0),
      setLockGraceSecs: setGrace ?? (_) async {},
    ),
    wallet: WalletSettingsScope(
      receiveAddress:
          receiveAddress ??
          () async => 'kaspa:qrxk2f9pabcdefghijklmnopqrstuvwmx3f4a2',
      deepScan: deepScan ?? () async => scanned,
      consolidate: consolidate,
      commitSend: consolidate == null
          ? null
          : (_) async => SendOutcomeDto(
              finalTxid: 'a' * 64,
              submitted: 1,
              total: 1,
              partial: false,
            ),
      abandonSend: consolidate == null ? null : () async {},
    ),
    about: AboutScope(
      packageInfo:
          packageInfo ??
          () async => const {
            'version': '1.0.0',
            'build': '7',
            'signature':
                'ef7ac03d1b2c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6',
          },
    ),
  );

  /// A tall surface. The registry is a `ListView`, so on the default 800×600
  /// test viewport the About rows are never built and "not rendered" would be
  /// indistinguishable from "not declared".
  Future<void> pump(WidgetTester tester, SettingsScreen s) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: s));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Settings is reachable from Home — the property that was missing',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            chain: ChainScope(
              connected: ValueNotifier(true),
              endpoint: ValueNotifier('wss://node.example'),
              virtualDaaScore: ValueNotifier(BigInt.from(1)),
              error: ValueNotifier(null),
              lastUpdate: ValueNotifier(DateTime(2026, 8, 12)),
            ),
            wallet: WalletScope(
              mature: ValueNotifier(BigInt.zero),
              pending: ValueNotifier(BigInt.zero),
              activity: ValueNotifier(const []),
              syncing: ValueNotifier(false),
              utxoIndexMissing: ValueNotifier(false),
            ),
            clock: () => DateTime(2026, 8, 12),
            settingsRoute: (_) => screen(),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsWidgets);
      // Every section the registry declares is on the glass.
      for (final section in ['Security', 'Wallet', 'Network', 'About']) {
        expect(find.text(section), findsOneWidget, reason: section);
      }
    },
  );

  // ── F5 (product-audit run 3): the gear must survive the header squeeze ──
  //
  // The test above proves Settings is REACHABLE. It proves it at
  // `physicalSize = Size(1000, 2400)`, `devicePixelRatio = 1.0` — a 1000 dp-wide
  // viewport, ~2.8x any phone, with the test font's uniform glyph advances. At
  // that width nothing can be squeezed out, so the property it guards is
  // "the route is wired", not "the door is on the glass".
  //
  // These run at real phone geometry with the real bundled fonts, in the state
  // the header actually spends 14-28 s in at every cold launch and every
  // reconnect hunt: `finding a node…`, the longest label the beacon can wear.

  /// Home in the cold-launch hunt: never connected, no snapshot ever, so the
  /// beacon reads `finding a node…` (status_beacon.dart:119).
  Widget coldLaunchHome() => MaterialApp(
    theme: kvDarkTheme(),
    home: HomeScreen(
      chain: ChainScope(
        connected: ValueNotifier(false),
        endpoint: ValueNotifier(null),
        virtualDaaScore: ValueNotifier(BigInt.zero),
        error: ValueNotifier(null),
        lastUpdate: ValueNotifier(null),
      ),
      wallet: WalletScope(
        mature: ValueNotifier(BigInt.zero),
        pending: ValueNotifier(BigInt.zero),
        activity: ValueNotifier(const []),
        syncing: ValueNotifier(false),
        utxoIndexMissing: ValueNotifier(false),
      ),
      clock: () => DateTime(2026, 8, 24),
      settingsRoute: (_) => screen(),
    ),
  );

  /// dp -> physical pixels at dpr 3.0, the density of the reference device.
  Future<void> pumpPhone(
    WidgetTester tester, {
    required double widthDp,
    required double textScale,
  }) async {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = Size(widthDp * 3.0, 800 * 3.0);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await tester.pumpWidget(coldLaunchHome());
    await tester.pump();
  }

  // 1.30 is AOSP's stock maximum font size through Android 13, and the value
  // this repo's own create_screen_test.dart:236 already uses as its large-text
  // case. 360 dp is the LG V60's bucket — the founder's own device, which at
  // "Largest" lost the gear during every launch hunt. 320 dp is the narrowest
  // phone the app claims to support.
  for (final geometry in const [
    (320.0, 1.30),
    (320.0, 1.15),
    (360.0, 1.30),
    (393.0, 1.30),
  ]) {
    testWidgets('the Settings gear is still tappable at '
        '${geometry.$1.toInt()} dp / textScale ${geometry.$2}', (tester) async {
      await pumpPhone(tester, widthDp: geometry.$1, textScale: geometry.$2);

      // The precondition: this really is the long-label state. If the beacon
      // ever stops saying this, the squeeze it creates is gone and these
      // tests would pass while measuring nothing.
      expect(
        find.text('finding a node…'),
        findsOneWidget,
        reason: 'the cold-launch hunt state is what squeezes the header',
      );

      // The geometric half — the gear dies when its CENTRE crosses the Row's
      // own clip, which is the viewport minus the gutter, not the viewport.
      final gear = find.byTooltip('Settings');
      final centre = tester.getCenter(gear);
      expect(
        centre.dx,
        lessThan(geometry.$1 - KvSpace.gutter),
        reason:
            'the gear centre is outside the header Row clip — pushed out '
            'by the beacon taking its intrinsic width',
      );

      // The behavioural half — a hit test that actually reaches the button,
      // and a door that actually opens. `tap` alone can dispatch into empty
      // space; opening Settings is the property the user has.
      await tester.tap(gear);
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsWidgets);
    });
  }

  /// Home with a live-but-stale link: connected, last snapshot 12 s old, so the
  /// beacon wears its warning colour and its age.
  Widget staleHome() => MaterialApp(
    theme: kvDarkTheme(),
    home: HomeScreen(
      chain: ChainScope(
        connected: ValueNotifier(true),
        endpoint: ValueNotifier('wss://node.example/borsh'),
        virtualDaaScore: ValueNotifier(BigInt.from(2000)),
        error: ValueNotifier(null),
        lastUpdate: ValueNotifier(DateTime(2026, 8, 24, 12, 0, 0)),
      ),
      wallet: WalletScope(
        mature: ValueNotifier(BigInt.from(1000)),
        pending: ValueNotifier(BigInt.zero),
        activity: ValueNotifier(const []),
        syncing: ValueNotifier(false),
        utxoIndexMissing: ValueNotifier(false),
      ),
      clock: () => DateTime(2026, 8, 24, 12, 0, 12),
      settingsRoute: (_) => screen(),
    ),
  );

  // DS-1: a stale link is dimming PLUS a visible age. Making the beacon yield so
  // the gear survives (F5) made the beacon the child that gets ellipsized — so
  // the age became the thing that CAN be cut, and DS-1 is what says it must not
  // be (ux-auditor, this sitting). The chip's label was shortened from
  // 'as of 12 s ago' to '12 s ago' for exactly this.
  //
  // Measured, with the bundled fonts at dpr 3.0, in the stale state:
  //
  //   320 dp / 1.00  box 51.6  needs 51.6  — fits
  //   320 dp / 1.15  box 59.0  needs 59.0  — fits
  //   320 dp / 1.30  box 51.7  needs 66.4  — 14.7 dp short, ellipsized
  //   360 dp / 1.30  box 66.4  needs 66.4  — fits
  //   393 dp / 1.30  box 66.4  needs 66.4  — fits
  //
  // So one geometry — the narrowest phone at AOSP's stock maximum font size —
  // still cannot show the whole label, and the honest guard is the invariant
  // itself rather than "never ellipsizes": **the AGE survives; only 'ago' is
  // cut.** That is what DS-1 asks for, and it is what these assert. The
  // fully-fits check runs everywhere it can, so a regression that pushed a
  // second geometry over the edge is still caught.
  for (final geometry in const [
    (320.0, 1.0, true),
    (320.0, 1.15, true),
    (320.0, 1.30, false), // 14.7 dp short — the age must still survive
    (360.0, 1.30, true),
  ]) {
    testWidgets('a stale link keeps its AGE readable at '
        '${geometry.$1.toInt()} dp / textScale ${geometry.$2}', (tester) async {
      tester.view.devicePixelRatio = 3.0;
      tester.view.physicalSize = Size(geometry.$1 * 3.0, 800 * 3.0);
      tester.platformDispatcher.textScaleFactorTestValue = geometry.$2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      await tester.pumpWidget(staleHome());
      await tester.pump();

      final label = find.text('12 s ago');
      expect(label, findsOneWidget, reason: 'the stale state renders its age');
      final paragraph = tester.renderObject<RenderParagraph>(label);

      // The DS-1 invariant, at every geometry: whatever is cut, the age is
      // not. Measured against the width '12 s' alone needs in the same style
      // and scale, so it tracks the token rather than a hardcoded number.
      final age = TextPainter(
        text: TextSpan(text: '12 s', style: paragraph.text.style),
        textDirection: TextDirection.ltr,
        textScaler: paragraph.textScaler,
      )..layout();
      expect(
        paragraph.size.width,
        greaterThanOrEqualTo(age.width),
        reason:
            'the age itself was ellipsized away — DS-1 requires a stale link '
            'to show dimming AND a visible age',
      );

      if (geometry.$3) {
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: 'this geometry has room for the whole label and lost it',
        );
      }
      await tester.pumpWidget(const SizedBox()); // cancel the 1 s ticker
    });
  }

  testWidgets(
    'and the beacon label does NOT ellipsize when there is room (393 dp / 1.0)',
    (tester) async {
      // The other half of the acceptance bar. Making the beacon yield is only
      // correct if it yields when squeezed and NOT otherwise — wrapping it in a
      // `Flexible` beside the `Spacer()` would make it a second flex child at
      // flex 1, taking half the free space and ellipsizing on a wide screen
      // with room to spare. That is a new defect wearing the fix's clothes, and
      // this is the test that tells the two apart.
      await pumpPhone(tester, widthDp: 393.0, textScale: 1.0);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text('finding a node…'),
      );
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: 'the label is truncated on a 393 dp phone at default text size',
      );
    },
  );

  testWidgets('the registry renders one row per declared entry', (
    tester,
  ) async {
    final s = screen();
    await pump(tester, s);
    final state = tester.state<State<SettingsScreen>>(
      find.byType(SettingsScreen),
    );
    // The registry IS the screen. If a row is declared it renders, and adding
    // one later must stay an additive entry rather than a layout change.
    final ids = [
      for (final section
          in (state as dynamic).registry() as List<SettingsSection>)
        for (final row in section.rows) row.id,
    ];
    expect(
      ids,
      containsAll(<String>[
        'biometric',
        'lock-grace',
        'receive-address',
        'deep-scan',
        'network-sheet',
        'version',
        'signature',
      ]),
    );
    for (final title in [
      'Fingerprint unlock',
      'Lock when I leave',
      'Receive address',
      'Scan for more addresses',
      'Node & connection',
      'Version',
      'App signature',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
  });

  // The defect in three assertions: collapsed to a bool, "this phone has no
  // fingerprint registered" and "this phone has no sensor" both read "Off", and
  // only one of them is something the user can fix. One test each — pumping a
  // second SettingsScreen of the same type into the same slot reuses the State,
  // so `initState` would never re-run and the first probe would stand forever.
  testWidgets('a phone with no fingerprint registered says exactly that', (
    tester,
  ) async {
    await pump(tester, screen(biometricStatus: () async => 'none_enrolled'));
    expect(find.text('No fingerprint on this phone'), findsOneWidget);
    expect(find.text('Off'), findsNothing);
  });

  testWidgets('a phone with no sensor says exactly that instead', (
    tester,
  ) async {
    await pump(tester, screen(biometricStatus: () async => 'no_hardware'));
    expect(find.text('Not supported'), findsOneWidget);
    expect(find.text('Off'), findsNothing);
  });

  testWidgets('an enrolled wallet reads On', (tester) async {
    await pump(
      tester,
      screen(
        biometricStatus: () async => 'ready',
        pathAState: () async => pathAReady,
      ),
    );
    expect(find.text('On'), findsOneWidget);
  });

  testWidgets('a probe that throws reads as UNKNOWN, not as a verdict', (
    tester,
  ) async {
    await pump(
      tester,
      screen(biometricStatus: () async => throw PlatformException(code: 'x')),
    );
    // DS-1 gives three honest states and unknown is one of them. "Off" would
    // claim the feature is available and switched off; "Unavailable" — the
    // first version — would assert a platform fact the app has just admitted it
    // could not determine, and would contradict the sheet one tap away, which
    // says "the wallet can't tell" (ux-auditor, Track 2).
    expect(find.text('—'), findsWidgets);
    expect(find.text('Off'), findsNothing);
    expect(find.text('Unavailable'), findsNothing);
  });

  testWidgets('enrolment is offered from Settings — the reversible "Not now"', (
    tester,
  ) async {
    var enrolls = 0;
    await pump(
      tester,
      screen(
        enroll: () async => ++enrolls > 0,
        pathAState: () async => pathANone,
      ),
    );
    await tester.tap(find.text('Fingerprint unlock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enable fingerprint unlock'));
    await tester.pumpAndSettle();
    expect(enrolls, 1, reason: 'a create-flow "Not now" must be recoverable');
  });

  testWidgets('an enrolled wallet can turn it off again', (tester) async {
    var cleared = 0;
    await pump(
      tester,
      screen(pathAState: () async => pathAReady, clear: () async => cleared++),
    );
    await tester.tap(find.text('Fingerprint unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Set up again'), findsOneWidget);
    await tester.tap(find.text('Turn off'));
    await tester.pumpAndSettle();
    expect(cleared, 1);
  });

  testWidgets('the lock-grace row reads the live setting and can change it', (
    tester,
  ) async {
    final grace = ValueNotifier(0);
    var written = -1;
    await pump(
      tester,
      screen(
        grace: grace,
        setGrace: (secs) async {
          written = secs;
          grace.value = secs;
        },
      ),
    );
    expect(find.text('Immediately'), findsOneWidget);

    await tester.tap(find.text('Lock when I leave'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('After 1 minute'));
    await tester.pumpAndSettle();

    expect(written, 60);
    expect(find.text('After 1 minute'), findsOneWidget);
  });

  testWidgets('"nothing new" is reported as SUCCESS, not as a failure', (
    tester,
  ) async {
    // Most taps land here, on a wallet that was already complete. Copy that
    // implied a failure would train the user to distrust a working control.
    await pump(tester, screen());
    await tester.tap(find.text('Scan for more addresses'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing new found'), findsOneWidget);
  });

  testWidgets('a widening scan says the balance is moving', (tester) async {
    await pump(
      tester,
      screen(
        deepScan: () async => const DeepScanReport(
          depth: 2048,
          receiveSeen: 13,
          changeSeen: 1501,
          widened: true,
        ),
      ),
    );
    await tester.tap(find.text('Scan for more addresses'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Found more'), findsOneWidget);
  });

  testWidgets('a failed scan NEVER reports success', (tester) async {
    // The cost of getting this wrong is the whole reason the row is audited: a
    // user taps "scan deeper", the app says it worked, and the funds stay
    // invisible — Track 1's original defect wearing a fresh button.
    await pump(
      tester,
      screen(deepScan: () async => throw Exception('socket down')),
    );
    await tester.tap(find.text('Scan for more addresses'));
    await tester.pumpAndSettle();
    expect(find.textContaining("Couldn't finish the scan"), findsOneWidget);
    expect(find.text('Nothing new found'), findsNothing);
  });

  testWidgets(
    'About shows the build, and the sheet shows the WHOLE fingerprint',
    (tester) async {
      const full =
          'ef7ac03d1b2c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6';
      await pump(tester, screen());
      expect(find.text('1.0.0 (7)'), findsOneWidget);
      // Elided in the row — 64 hex characters do not belong in a list row.
      expect(find.text('ef7ac03d…a3b4c5d6'), findsOneWidget);

      // …but the sheet must hold every character, because comparing against the
      // value published in RELEASE.md is the entire point of the row. The first
      // version shortened on ARRIVAL, destroying the only copy: the sheet then
      // rendered 16 of 64 characters under a comment claiming it showed all of
      // them, and no user following the provenance check could ever match it.
      // The old test passed on `findsWidgets('…')` — it asserted the truncation
      // rather than the promise (dependency-steward, Track 2).
      await tester.tap(find.text('App signature'));
      await tester.pumpAndSettle();
      expect(find.text(full), findsOneWidget);
      expect(full.length, 64);
    },
  );

  testWidgets('unreadable build metadata degrades to em dashes, never a lie', (
    tester,
  ) async {
    await pump(
      tester,
      screen(packageInfo: () async => throw PlatformException(code: 'x')),
    );
    expect(find.text('—'), findsWidgets);
  });

  group('Merge coins (consolidation reachability + honesty)', () {
    SignableSummaryDto mergeSummary() => SignableSummaryDto(
      nonce: BigInt.one,
      kind: SignableKind.consolidate,
      destination: 'kaspa:qrxk2f9pabcdefghijklmnopqrstuvwmx3f4a2',
      amountSompi: BigInt.from(24700000000),
      feeSompi: BigInt.from(427200),
      totalSompi: BigInt.from(24700427200),
      mass: BigInt.from(4272),
      txCount: 1,
      utxoCount: 22,
      resultingCoins: 1,
      payloadLen: null,
      payloadKind: null,
      feeStrategy: FeeStrategyKind.senderPays,
      priorityFeeSompi: BigInt.zero,
    );

    testWidgets('the row exists only when wired, and opens the ONE signing '
        'surface over Rust\'s summary', (tester) async {
      // Unwired (every pre-existing test): no row — the harness default
      // proves the hidden state.
      await pump(tester, screen());
      expect(find.text('Merge coins'), findsNothing);

      var prepares = 0;
      await pump(
        tester,
        screen(
          consolidate: () async {
            prepares++;
            return mergeSummary();
          },
        ),
      );
      expect(find.text('Merge coins'), findsOneWidget);

      await tester.tap(find.text('Merge coins'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(prepares, 1);
      // The same anti-blind-signing sheet every send uses (B7): kind-derived
      // title, fee-led headline, the absorbed count from the DTO.
      expect(find.text('Confirm merge'), findsOneWidget);
      expect(find.text('Costs you'), findsOneWidget);
      expect(find.textContaining('Merges 22 coins into one'), findsOneWidget);
    });

    testWidgets('a Rust refusal lands as the row status, in Rust\'s words', (
      tester,
    ) async {
      await pump(
        tester,
        screen(
          consolidate: () async => throw const AppError(
            message:
                'nothing to merge — your spendable coins are already '
                'consolidated',
          ),
        ),
      );
      await tester.tap(find.text('Merge coins'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.textContaining('nothing to merge'),
        findsOneWidget,
        reason: 'the honest refusal renders, never a shrug',
      );
    });
  });
}
