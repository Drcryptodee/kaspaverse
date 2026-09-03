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
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_drawer.dart';
import 'package:kaspaverse/src/ui/widgets/kv_glyph.dart';

import 'support/preview_harness.dart';
import 'support/finders.dart';

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
    ValueNotifier<String?>? pinnedNode,
    ValueNotifier<bool>? rateEnabled,
    bool withNetwork = true,
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
    network: withNetwork
        ? NetworkSettingsScope(
            // The row's destination is the SAME screen the money plate's chip
            // opens; `main.dart` owns the one builder. Here it only has to be
            // a route, so the row's reachability is what is under test.
            route: (_) => const Scaffold(body: Text('Node & connection')),
            pinnedNode: pinnedNode ?? ValueNotifier<String?>(null),
            rateEnabled: rateEnabled ?? ValueNotifier<bool>(true),
          )
        : null,
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
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_home(settings: screen()));
      await tester.pump();

      // The door is in the drawer since UX-R1, and the K avatar is what opens
      // it (§3a.2) — so reachability is now two taps, and both are asserted.
      await openDrawer(tester);
      await tester.tap(find.bySemanticsLabel('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsWidgets);
      // Every section the registry declares is on the glass.
      for (final section in ['Security', 'Wallet', 'Network', 'About']) {
        expect(findRuledLabel(section), findsOneWidget, reason: section);
      }
      semantics.dispose();
    },
  );

  // ── F5 (product-audit run 3), re-aimed at the UX-2 rail ──
  //
  // The test above proves Settings is REACHABLE. It proves it at
  // `physicalSize = Size(1000, 2400)`, `devicePixelRatio = 1.0` — a 1000 dp-wide
  // viewport, ~2.8x any phone, with the test font's uniform glyph advances. At
  // that width nothing can be squeezed out, so the property it guards is
  // "the route is wired", not "the door is on the glass".
  //
  // These run at real phone geometry with the real bundled fonts. The squeeze
  // has a different shape since UX-2 — the beacon pill is gone and the link's
  // words moved into the money plate — but the property is identical and it is
  // the one that actually cost a founder his settings screen: **a custody door
  // never yields.** The rail now has two of them, so the test walks both.
  Widget coldLaunchHome() => _home(settings: screen(), messages: screen());

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
  // 2.0 is beyond BG-14's 1.3 floor on purpose: it is Android 14's "Largest"
  // font size, and it is the geometry where a door is actually at risk.
  //
  // **The squeeze has a different shape since UX-R1 and the property is the
  // same.** The doors were two 52 dp targets in a top rail beside a wordmark
  // that had to yield; they are now rows in a 296 dp drawer, and what can go
  // wrong is a row growing past the panel or a label eating its own target.
  // A custody door never yields, whatever is holding it.
  for (final geometry in const [
    (320.0, 1.30),
    (320.0, 1.15),
    (360.0, 1.30),
    (393.0, 1.30),
    (320.0, 2.00),
  ]) {
    testWidgets('both drawer doors are still tappable at '
        '${geometry.$1.toInt()} dp / textScale ${geometry.$2}', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPhone(tester, widthDp: geometry.$1, textScale: geometry.$2);
      await openDrawer(tester);

      expect(
        tester.takeException(),
        isNull,
        reason: 'the drawer overflowed instead of laying its rows out',
      );
      for (final door in const ['Messages', 'Settings']) {
        final finder = find.bySemanticsLabel(door);
        expect(finder, findsOneWidget, reason: door);
        // Nothing may be pushed past the panel's own edge.
        expect(
          tester.getRect(finder).right,
          lessThanOrEqualTo(KvLayout.drawer + 0.5),
          reason: '$door is outside the drawer panel',
        );
        // A 52 dp target is a promise, and a target compressed by a Row is a
        // promise the geometry broke (BG-12). The row is fixed at 64 in every
        // class and grows with text scale rather than clipping (BG-33/BG-14).
        expect(
          tester.getSize(finder).height,
          greaterThanOrEqualTo(KvSpace.touchTarget),
          reason: '$door yielded its target',
        );
      }

      // The behavioural half — a hit test that actually reaches the control,
      // and a door that actually opens. `tap` alone can dispatch into empty
      // space; opening Settings is the property the user has.
      await tester.tap(find.bySemanticsLabel('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsWidgets);
      semantics.dispose();
    });
  }

  /// Home with a live-but-stale link: connected, last snapshot 12 s old, so the
  /// plate's trust line speaks and wears its age.
  Widget staleHome() => _home(
    settings: screen(),
    connected: true,
    lastUpdate: DateTime(2026, 8, 24, 12),
    now: DateTime(2026, 8, 24, 12, 0, 12),
    mature: BigInt.from(1000),
  );

  // BG-8: a stale link is dimming PLUS a visible age.
  //
  // The old header made the beacon the child that yields, which made the AGE
  // the thing that could be cut — and at 320 dp / 1.30 it was, by 14.7 dp. The
  // label was shortened from 'as of 12 s ago' to '12 s ago' to buy that back.
  //
  // UX-2 gave the age a plate instead of a pill, so the fuller phrasing fits
  // again and the line wraps to a second line before it ellipsizes anything.
  // The invariant does not change with the room: **whatever is cut, the age is
  // not.** Asserted against the width '12 s' alone needs in the same style and
  // scale, so it tracks the token rather than a hardcoded number.
  for (final geometry in const [
    (320.0, 1.0),
    (320.0, 1.15),
    (320.0, 1.30),
    (360.0, 1.30),
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

      final label = find.text('as of 12 s ago');
      expect(label, findsOneWidget, reason: 'the stale state renders its age');
      final paragraph = tester.renderObject<RenderParagraph>(label);
      final age = TextPainter(
        text: TextSpan(text: '12 s', style: paragraph.text.style),
        textDirection: TextDirection.ltr,
        textScaler: paragraph.textScaler,
      )..layout();
      expect(
        paragraph.size.width,
        greaterThanOrEqualTo(age.width),
        reason:
            'the age itself was ellipsized away — BG-8 requires a stale link '
            'to show dimming AND a visible age',
      );
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: 'the plate has room for the whole phrase and lost it',
      );
      await tester.pumpWidget(const SizedBox()); // cancel the 1 s ticker
    });
  }

  testWidgets(
    'the wallet identity does NOT ellipsize when there is room (393 dp / 1.0)',
    (tester) async {
      // **The wordmark is gone** (D-260): §4 put an orb and `KaspaVerse` at the
      // head of the drawer; the intake render puts the **wallet's own name and
      // address** there, and the founder's reason is a product one — that seat
      // becomes the wallet switcher when the app holds more than one account
      // on a phone. A wordmark answers a question nobody standing inside their
      // own wallet is asking.
      //
      // The property under test is unchanged and is still the other half of
      // the acceptance bar: the header yields **when squeezed and not
      // otherwise**. A `Flexible` beside a `Spacer()` would take half the free
      // space and ellipsize on a wide screen with room to spare — a new defect
      // wearing the fix's clothes, and this is the test that tells them apart.
      await pumpPhone(tester, widthDp: 393.0, textScale: 1.0);
      await openDrawer(tester);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text('Main wallet'),
      );
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason:
            'the wallet name is truncated on a 393 dp phone at default size',
      );
      await tester.pumpWidget(const SizedBox());
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
        'node-connection',
        'version',
        'signature',
        'roadmap',
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
      "What's coming",
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
  });

  testWidgets('the Network row summarises the CHOICE, not the health', (
    tester,
  ) async {
    // A summary of the link's health here would be a second rendering of a
    // truth the screen behind the row already tells — the C7 disagreement the
    // retired network sheet actually caused. Whose node and whether a price is
    // fetched are both things the USER chose, so they cannot contradict it.
    final pinned = ValueNotifier<String?>(null);
    final rateOn = ValueNotifier<bool>(true);
    await pump(tester, screen(pinnedNode: pinned, rateEnabled: rateOn));
    expect(find.text('Public community nodes · fiat value on'), findsOneWidget);

    // Both halves are live, and both propositions are asserted — a summary
    // that only ever renders one branch is a summary nobody has checked
    // (`L126`).
    pinned.value = 'wss://mine.example/borsh';
    rateOn.value = false;
    await tester.pump();
    expect(find.text('Your own node · fiat value off'), findsOneWidget);

    // Nothing about liveness, ever: that word belongs to the surface behind
    // the row.
    expect(find.textContaining('Connected'), findsNothing);
    expect(find.textContaining('Answering'), findsNothing);
  });

  testWidgets('with no network seam the section is absent, not dead', (
    tester,
  ) async {
    await pump(tester, screen(withNetwork: false));
    expect(findRuledLabel('Network'), findsNothing);
    expect(find.text('Node & connection'), findsNothing);
    // The custody domains are untouched by the absence.
    expect(findRuledLabel('Security'), findsOneWidget);
    expect(findRuledLabel('About'), findsOneWidget);
  });

  testWidgets("what a PLANNED destination says, when tapped", (tester) async {
    // The compact nav dropped the one-line blurbs (D-193, with a recorded
    // dissent), the panel was then withdrawn entirely (D-190), and the
    // explanation had nowhere to live. It lives here now — on a surface no
    // navigation shape can delete.
    await pump(tester, screen());
    await tester.tap(find.text("What's coming"));
    await tester.pumpAndSettle();

    for (final name in const ['Games', 'Contracts', 'Finance', 'Assets']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    // The dissent's own example, verbatim: the entire pitch of Contracts to
    // someone who has never heard of a covenant.
    expect(find.textContaining('Agreements with no admin key'), findsOneWidget);
    // Engraved tags, one per destination — "not yet" as information rather
    // than as damage (D-190).
    expect(find.text('PLANNED'), findsNWidgets(4));
    // And it promises nothing before it names anything.
    expect(find.textContaining('None of these exist yet'), findsOneWidget);
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
      expect(findRuledLabel('Costs you'), findsOneWidget);
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

/// The money screen **inside the app's navigation**, wired to nothing but the
/// doors under test.
///
/// Settings and Messages are drawer destinations since UX-R1, not rail icons
/// on the money screen, so a reachability test has to mount the drawer that
/// holds them — which is exactly the property being asserted.
Widget _home({
  required Widget settings,
  Widget? messages,
  bool connected = true,
  DateTime? lastUpdate,
  DateTime? now,
  BigInt? mature,
}) {
  final clock = now ?? DateTime(2026, 8, 24);
  return MaterialApp(
    theme: kvDarkTheme(),
    builder: (context, page) => KvWindow(child: page!),
    home: Builder(
      builder: (context) => KvNav(
        selected: 0,
        header: const KvWalletIdentity(name: 'Main wallet'),
        destinations: [
          const KvDestination(mark: KvGlyph.money, label: 'Wallet'),
          if (messages != null)
            KvDestination(
              mark: KvGlyph.chat,
              label: 'Messages',
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => messages)),
            ),
        ],
        footer: [
          KvDestination(
            mark: KvGlyph.settings,
            label: 'Settings',
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => settings)),
          ),
        ],
        child: HomeScreen(
          chain: ChainScope(
            connected: ValueNotifier(connected),
            virtualDaaScore: ValueNotifier(BigInt.from(2000)),
            error: ValueNotifier(null),
            lastUpdate: ValueNotifier(lastUpdate),
          ),
          wallet: WalletScope(
            mature: ValueNotifier(mature ?? BigInt.zero),
            pending: ValueNotifier(BigInt.zero),
            activity: ValueNotifier(const []),
            syncing: ValueNotifier(false),
            utxoIndexMissing: ValueNotifier(false),
          ),
          clock: () => clock,
        ),
      ),
    ),
  );
}

/// Open the drawer the way a thumb does, and settle it.
///
/// In `expanded`+ there is nothing to open — the drawer is already standing
/// and §3a.2 drops the avatar — so the helper is a no-op there rather than a
/// failure. That branch is itself the property: navigation is on screen.
Future<void> openDrawer(WidgetTester tester) async {
  final avatar = find.bySemanticsLabel('Open navigation');
  if (avatar.evaluate().isEmpty) return;
  await tester.tap(avatar);
  // **Bounded pumps, never `pumpAndSettle`.** The drawer does not push a
  // route, so the money screen stays visible and its tickers keep running —
  // the live dot and the cadence never quiesce, by design (BG-9). Waiting for
  // stillness here waits forever; a pushed route mutes them via `TickerMode`,
  // which is why every OTHER settle in this file works.
  await tester.pump();
  await tester.pump(KvMotion.enter);
  await tester.pump(KvMotion.enter);
}
