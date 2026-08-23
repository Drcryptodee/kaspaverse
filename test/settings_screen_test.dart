import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/rust/api/send.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/biometric_copy.dart';
import 'package:kaspaverse/src/ui/home_screen.dart';
import 'package:kaspaverse/src/ui/settings_screen.dart';

/// Track 2. Two properties matter here and they are different properties:
///
/// 1. **Reachability.** A setting nobody can open is a setting that does not
///    exist — which is literally how biometric enrolment came to be unreachable
///    after a restore while its native lane was complete and device-proven. So
///    the walk starts at Home and taps its way in.
/// 2. **Honesty.** Every row states a true thing about the state it reports,
///    including the states where the answer is "we cannot".
void main() {
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
