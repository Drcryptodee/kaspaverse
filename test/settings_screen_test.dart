import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/rust/api/send.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/biometric_copy.dart';
import 'package:kaspaverse/src/ui/home_screen.dart';
import 'package:kaspaverse/src/ui/settings/about_screen.dart';
import 'package:kaspaverse/src/ui/settings/security_screen.dart';
import 'package:kaspaverse/src/ui/settings/settings_scopes.dart';
import 'package:kaspaverse/src/ui/settings/settings_screen.dart';
import 'package:kaspaverse/src/ui/settings/wallet_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_drawer.dart';
import 'package:kaspaverse/src/ui/address_text.dart';
import 'package:kaspaverse/src/ui/roadmap_screen.dart';
import 'package:kaspaverse/src/ui/widgets/kv_check.dart';
import 'package:kaspaverse/src/ui/widgets/kv_glyph.dart';
import 'package:kaspaverse/src/ui/widgets/kv_rows.dart';
import 'package:kaspaverse/src/ui/widgets/kv_toggle.dart';

import 'support/preview_harness.dart';
import 'support/finders.dart';
import 'support/maturity.dart';

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
    Future<void> Function()? lockNow,
    Future<void> Function()? removeWallet,
  }) => SettingsScreen(
    security: securityScope(
      biometricStatus: biometricStatus,
      pathAState: pathAState,
      enroll: enroll,
      clear: clear,
      grace: grace,
      setGrace: setGrace,
      lockNow: lockNow,
    ),
    removeWallet: removeWallet,
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
    await tester.pumpWidget(MaterialApp(builder: _kvWindow, home: s));
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
      // The root's two groups, and the four doors the drawer's users hunt.
      for (final group in ['Wallet', 'App']) {
        expect(findRuledLabel(group), findsOneWidget, reason: group);
      }
      for (final door in ['Security', 'Network', 'About']) {
        expect(find.text(door), findsOneWidget, reason: door);
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

  // ── `T1` · the root, as the render draws it ─────────────────────────────

  testWidgets('the root names its two groups and every door in them', (
    tester,
  ) async {
    await pump(tester, screen());
    for (final group in ['Wallet', 'App']) {
      expect(findRuledLabel(group), findsOneWidget, reason: group);
    }
    for (final door in const [
      'Security',
      'Wallet',
      'Network',
      'Messages',
      'Appearance',
      'Notifications',
      'Privacy',
      'About',
    ]) {
      expect(find.text(door), findsOneWidget, reason: door);
    }
  });

  testWidgets('every door states a condition — never a bare name', (
    tester,
  ) async {
    // `T1`'s law: the sub-line IS the row's current state. A door that shows
    // only its name is a door the user has to open to learn anything, which
    // is the screen this group replaced.
    await pump(tester, screen(grace: ValueNotifier(30)));
    expect(find.textContaining('locks after 30 s'), findsOneWidget);
    expect(find.textContaining('Public community nodes'), findsOneWidget);
    expect(find.textContaining('KaspaVerse 1.0.0'), findsOneWidget);
    for (final row in const [
      'Messages',
      'Appearance',
      'Notifications',
      'Privacy',
    ]) {
      final sub = find.descendant(
        of: find.ancestor(of: find.text(row), matching: find.byType(KvRow)),
        matching: find.byType(Text),
      );
      expect(
        sub.evaluate().length,
        greaterThanOrEqualTo(2),
        reason: '$row states its name and nothing else',
      );
    }
  });

  testWidgets('the fingerprint fragment reports the STATE, not a bool', (
    tester,
  ) async {
    // The scar, in one row: collapsed to on/off, "no fingerprint registered"
    // and "no sensor on this phone" read identically, and only one of them is
    // something the user can fix.
    await pump(
      tester,
      screen(
        biometricStatus: () async => 'ready',
        pathAState: () async => pathAInvalidated,
      ),
    );
    expect(find.textContaining('needs setting up again'), findsOneWidget);
  });

  testWidgets('a probe that throws reads as UNKNOWN, never as a verdict', (
    tester,
  ) async {
    await pump(tester, screen(biometricStatus: () async => throw 'no channel'));
    expect(find.textContaining('Fingerprint unknown'), findsOneWidget);
  });

  testWidgets('the Network row summarises the CHOICE, not the health', (
    tester,
  ) async {
    await pump(
      tester,
      screen(
        pinnedNode: ValueNotifier<String?>('ws://mine.local:17110'),
        rateEnabled: ValueNotifier(false),
      ),
    );
    expect(find.text('Your own node · fiat value off'), findsOneWidget);
    // The health belongs to the screen behind the row and is never restated
    // here — a second rendering of the link is the C7 defect.
    expect(find.textContaining('Connected'), findsNothing);
  });

  testWidgets('with no network seam the row is absent, not dead', (
    tester,
  ) async {
    await pump(tester, screen(withNetwork: false));
    expect(find.text('Network'), findsNothing);
  });

  testWidgets('with no removal seam the red text is absent, not inert', (
    tester,
  ) async {
    // `T1` draws it and `vault.rs` has no wipe. A control that says "Remove
    // this wallet from this phone" and removes nothing is the worst thing
    // this screen could ship (§8) — so it is not drawn until the seam is.
    await pump(tester, screen());
    expect(find.textContaining('Remove this wallet'), findsNothing);

    var removed = false;
    await pump(
      tester,
      screen(lockNow: () async {}, removeWallet: () async => removed = true),
    );
    final red = find.textContaining('Remove this wallet');
    expect(red, findsOneWidget);
    // It is the ONE red thing, and it sits below the raised pill — §4 puts
    // destructive text last on a page with no primary.
    expect(
      tester.widget<Text>(red).style!.color,
      KvColor.risk,
      reason: 'the removal text is `risk`',
    );
    expect(
      tester.getTopLeft(red).dy,
      greaterThan(tester.getTopLeft(find.text('Lock now')).dy),
      reason: 'the red text sits below the raised pill, out of the thumb arc',
    );
    await tester.tap(red);
    await tester.pump();
    expect(removed, isTrue);
  });

  testWidgets('Lock now fires the vault, and is absent without the seam', (
    tester,
  ) async {
    await pump(tester, screen());
    expect(find.text('Lock now'), findsNothing);

    var locked = false;
    await pump(tester, screen(lockNow: () async => locked = true));
    await tester.tap(find.text('Lock now'));
    await tester.pump();
    expect(locked, isTrue);
  });

  testWidgets('the whole root fits the phone, with nothing to scroll', (
    tester,
  ) async {
    // **Playbook §19.** A settings group owes a one-view fit: a setting you
    // must scroll to hunt is a setting you will not change. The V60 is
    // 393 × 894 logical and the system bars take ~50 of it, so the real
    // budget is ~845; the guard is 800, and it reds before he sees it.
    //
    // Every seam is present, because a screen that fits only because a
    // section is absent does not fit.
    tester.view.physicalSize = const Size(393 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: _kvWindow,
        // **Every seam this build actually wires** (§19.3: a screen that
        // fits only because a section is absent does not fit). `removeWallet`
        // is deliberately not among them — `main.dart` passes null because
        // `vault.rs` has no wipe. The red text costs 60 dp when its seam
        // lands (52 target + 8 gap), which is the budget the sitting that
        // builds it has to find; the assertion below is what will tell it.
        home: screen(
          grace: ValueNotifier(30),
          lockNow: () async {},
          consolidate: () async => throw UnimplementedError(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    expect(
      position.maxScrollExtent,
      0,
      reason:
          'the Settings root overflows its own phone by '
          '${position.maxScrollExtent.toStringAsFixed(1)} dp — `About` and '
          'the red text are below the fold, which is the finding this guards',
    );
  });

  // ── `T2` · Security ──────────────────────────────────────────────────────

  group('T2 · Security', () {
    Future<void> pumpSecurity(
      WidgetTester tester, {
      Future<String> Function()? biometricStatus,
      Future<String> Function()? pathAState,
      Future<bool> Function()? enroll,
      Future<void> Function()? clear,
      ValueNotifier<int>? grace,
      Future<void> Function(int)? setGrace,
      double height = 2400,
    }) async {
      tester.view.physicalSize = Size(393 * 3, height * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: _kvWindow,
          home: SecurityScreen(
            scope: securityScope(
              biometricStatus: biometricStatus,
              pathAState: pathAState,
              enroll: enroll,
              clear: clear,
              grace: grace,
              setGrace: setGrace,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'the render\'s three sections, with the live grace on the row',
      (tester) async {
        await pumpSecurity(tester, grace: ValueNotifier(300));
        // `SIGNING` was removed on his word (2026-09-06, on glass); its two
        // rows are logged in IDEAS_BACKLOG with their copy.
        for (final section in ['Unlock', 'Recovery']) {
          expect(findRuledLabel(section), findsOneWidget, reason: section);
        }
        expect(find.text('After 5 min'), findsOneWidget);
      },
    );

    testWidgets('a toggle that cannot fire says why (BG-12)', (tester) async {
      await pumpSecurity(
        tester,
        biometricStatus: () async => biometricNoneEnrolled,
      );
      expect(find.text('Biometric unlock'), findsOneWidget);
      // The refusal is on the glass, in our words, where the refusal is.
      expect(
        find.textContaining('no fingerprint set up yet'),
        findsOneWidget,
        reason: 'a disabled control always says why',
      );
    });

    testWidgets('enrolment is reachable, and a CANCEL is not a failure', (
      tester,
    ) async {
      var enrolled = false;
      await pumpSecurity(
        tester,
        pathAState: () async => enrolled ? pathAReady : pathANone,
        enroll: () async {
          enrolled = true;
          return true;
        },
      );
      await tester.tap(find.text('Biometric unlock'));
      await tester.pumpAndSettle();
      expect(enrolled, isTrue);

      // A cancel leaves no banner and nothing to apologise for.
      await pumpSecurity(
        tester,
        enroll: () async => throw PlatformException(code: 'cancelled'),
      );
      await tester.tap(find.text('Biometric unlock'));
      await tester.pumpAndSettle();
      expect(find.textContaining('could not'), findsNothing);
    });

    testWidgets('Block screenshots is a GUARANTEE, not a switch', (
      tester,
    ) async {
      // BG-10 is not a preference: secret screens set FLAG_SECURE and refuse
      // accessibility unconditionally, so a switch that turns that off is a
      // switch that breaks a safety law. Drawn as a switch it renders dim and
      // reads as broken — the frame said so — so it takes the shape the two
      // rows above it already use for a guarantee.
      await pumpSecurity(tester);
      final row = find.ancestor(
        of: find.text('Block screenshots'),
        matching: find.byType(KvRow),
      );
      expect(row, findsOneWidget);
      expect(
        tester.widget<KvRow>(row).onTap,
        isNull,
        reason: 'a guarantee is a record, never a control',
      );
      expect(find.byType(KvToggle), findsOneWidget, reason: 'only biometrics');
      // And the section that held the other two guarantees is gone on his
      // word — the assertion is here so a future sitting re-adds it
      // deliberately rather than by drift.
      expect(findRuledLabel('Signing'), findsNothing);
      expect(find.text('Hold to sign'), findsNothing);
      expect(find.textContaining('cannot be turned off'), findsOneWidget);
    });

    testWidgets('the whole screen fits the phone, with nothing to scroll', (
      tester,
    ) async {
      await pumpSecurity(tester, height: 800, grace: ValueNotifier(30));
      final position = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      expect(
        position.maxScrollExtent,
        0,
        reason:
            'Security overflows its own phone by '
            '${position.maxScrollExtent.toStringAsFixed(1)} dp',
      );
    });
  });

  // ── `T3` · the lock timer, and the sheet law's four clauses ─────────────

  group('T3 · the lock timer ceremony', () {
    Future<void> openSheet(
      WidgetTester tester,
      ValueNotifier<int> grace, {
      List<int>? saved,
    }) async {
      tester.view.physicalSize = const Size(393 * 3, 852 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: _kvWindow,
          home: SecurityScreen(
            scope: securityScope(
              grace: grace,
              setGrace: (secs) async {
                saved?.add(secs);
                grace.value = secs;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lock when I leave'));
      await tester.pumpAndSettle();
    }

    testWidgets('Cancel is `risk`, and the scrim leaves the sheet', (
      tester,
    ) async {
      // D-277 clauses 1 and 2. `T3` draws Cancel in `inkDim`; the founder's
      // house-wide ruling was made on glass AFTER these renders and his eye
      // outranks the render (D-262). Said in the sitting.
      await openSheet(tester, ValueNotifier(30));
      final cancel = find.text('Cancel');
      expect(cancel, findsOneWidget);
      expect(tester.widget<Text>(cancel).style!.color, KvColor.risk);

      await tester.tapAt(const Offset(196, 40));
      await tester.pumpAndSettle();
      expect(find.text('Cancel'), findsNothing, reason: 'the scrim leaves it');
    });

    testWidgets('one sentence at the top, and one act in the foot', (
      tester,
    ) async {
      // D-277 clause 3: the disclosure belongs where the choice is made, not
      // stacked over the button — one sentence, and it is above the CHOICES.
      await openSheet(tester, ValueNotifier(30));
      final sentence = find.textContaining('How long the wallet stays open');
      expect(sentence, findsOneWidget);
      expect(
        tester.getTopLeft(sentence).dy,
        lessThan(tester.getTopLeft(find.text('Immediately')).dy),
      );
      // The act is in the foot. **Disabled, its label IS the reason**
      // (D-284), so `Done` appears the moment a different option is picked.
      expect(find.text('30 seconds is already set'), findsOneWidget);
      await tester.tap(find.text('1 minute'));
      await tester.pumpAndSettle();
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('the act is disabled with its reason until a choice differs', (
      tester,
    ) async {
      // D-277 clause 4, and D-275's settings ceremony.
      await openSheet(tester, ValueNotifier(30));
      // The reason names the SETTING, not the situation — one line saying
      // what is in force and why the act is waiting (D-284, the render).
      expect(find.text('30 seconds is already set'), findsOneWidget);
      expect(find.text('Done'), findsNothing);
      await tester.tap(find.text('5 minutes'));
      await tester.pumpAndSettle();
      expect(find.text('30 seconds is already set'), findsNothing);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('exactly one check, and a ring on every other option', (
      tester,
    ) async {
      // **The house check marks the choice, and a ring marks the rest** —
      // his ruling on glass (2026-09-06). BG-29's value is that the app has
      // exactly one yes; a second chosen-mark vocabulary costs more than the
      // choosing/confirmed distinction buys, and teal stays light rather than
      // status (BG-2).
      await openSheet(tester, ValueNotifier(30));
      expect(find.byType(KvCheck), findsOneWidget);
      // Five rings: four unchosen options, and the miniature on the disabled
      // act that says *nothing new has been picked* in the same vocabulary.
      expect(find.byType(KvRadio), findsNWidgets(5));
      final rows = tester
          .widgetList<KvChoiceRow>(find.byType(KvChoiceRow))
          .where((r) => r.selected)
          .toList();
      expect(rows.length, 1);
      expect(rows.single.title, '30 seconds');
    });

    testWidgets('NEVER is not offered — the vault clamps at 15 minutes', (
      tester,
    ) async {
      // `T3` draws it. `vault.rs` clamps the grace at MAX_LOCK_GRACE_SECS =
      // 900 and stores a `u32`, so "never lock" does not exist on the Rust
      // side and offering it would be a control that silently did something
      // else. The cost the render says out loud under **Never** moves to the
      // longest wait that really exists.
      await openSheet(tester, ValueNotifier(30));
      expect(find.text('Never'), findsNothing);
      expect(find.text('15 minutes'), findsOneWidget);
      expect(
        find.text('Anyone holding the phone in that window can spend'),
        findsOneWidget,
      );
    });

    testWidgets('Done writes the chosen grace, and leaving writes nothing', (
      tester,
    ) async {
      final saved = <int>[];
      final grace = ValueNotifier(30);
      await openSheet(tester, grace, saved: saved);
      await tester.tap(find.text('5 minutes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(saved, [300]);
      expect(find.text('After 5 min'), findsOneWidget);

      await openSheet(tester, grace, saved: saved);
      await tester.tap(find.text('1 minute'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(saved, [300], reason: 'a cancelled ceremony changes nothing');
    });
  });

  // ── `T4` · Wallet — the half this build can honestly draw ───────────────

  group('T4 · Wallet', () {
    Future<void> pumpWallet(
      WidgetTester tester, {
      Future<DeepScanReport> Function()? deepScan,
      Future<String> Function()? receiveAddress,
      Future<SignableSummaryDto> Function()? consolidate,
    }) async {
      tester.view.physicalSize = const Size(393 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: _kvWindow,
          home: WalletScreen(
            scope: WalletSettingsScope(
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
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('"nothing new" is reported as SUCCESS, never as a failure', (
      tester,
    ) async {
      await pumpWallet(tester);
      await tester.tap(find.text('Scan for more addresses'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing new found'), findsOneWidget);
      expect(find.textContaining('watching 92'), findsOneWidget);
    });

    testWidgets('a widening scan says what it found', (tester) async {
      await pumpWallet(
        tester,
        deepScan: () async => const DeepScanReport(
          depth: 2048,
          receiveSeen: 20,
          changeSeen: 4,
          widened: true,
        ),
      );
      await tester.tap(find.text('Scan for more addresses'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Found more addresses'), findsOneWidget);
    });

    testWidgets('a failed scan NEVER reports success', (tester) async {
      await pumpWallet(tester, deepScan: () async => throw 'boom');
      await tester.tap(find.text('Scan for more addresses'));
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't finish the scan"), findsOneWidget);
    });

    testWidgets('the merge row exists only when wired, and EXPLAINS before '
        'anything is priced (BG-11)', (tester) async {
      await pumpWallet(tester);
      expect(find.text('Merge coins'), findsNothing);
      expect(find.textContaining('Merging is an ordinary send'), findsNothing);

      await pumpWallet(tester, consolidate: () async => _summary());
      expect(find.text('Merge coins'), findsOneWidget);
      final notice = find.textContaining('Merging is an ordinary send');
      expect(notice, findsOneWidget);
      // The disclosure sits above the act it describes: explain, then price.
      expect(
        tester.getTopLeft(notice).dy,
        greaterThan(tester.getTopLeft(find.text('Merge coins')).dy),
      );
      // And it names no figure of its own — the fee is the ceremony's, from
      // the prepared plan, never a number this screen guessed.
      expect(find.textContaining('KAS fee'), findsNothing);
    });

    testWidgets('a Rust refusal lands on the row, in Rust\'s own words', (
      tester,
    ) async {
      await pumpWallet(
        tester,
        consolidate: () async => throw const AppError(
          message:
              'nothing to merge — your spendable coins are already '
              'consolidated',
        ),
      );
      await tester.tap(find.text('Merge coins'));
      await tester.pumpAndSettle();
      expect(find.textContaining('nothing to merge'), findsOneWidget);
    });

    testWidgets('the receive address is rendered by the house part', (
      tester,
    ) async {
      await pumpWallet(tester);
      expect(find.byType(AddressText), findsOneWidget);
    });
  });

  // ── `T6` · About ────────────────────────────────────────────────────────

  group('T6 · About', () {
    Future<void> pumpAbout(
      WidgetTester tester, {
      Future<Map<String, String>> Function()? packageInfo,
    }) async {
      tester.view.physicalSize = const Size(393 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: _kvWindow,
          home: AboutScreen(
            scope: AboutScope(
              packageInfo:
                  packageInfo ??
                  () async => const {
                    'version': '1.0.0',
                    'build': '7',
                    'signature':
                        'ef7ac03d1b2c4d5e6f708192a3b4c5d6'
                        'e7f8091a2b3c4d5e6f708192a3b4c5d6',
                  },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the WHOLE fingerprint is on the glass, in printable groups', (
      tester,
    ) async {
      // The scar: shortening on arrival destroyed the only copy, so the
      // surface that exists to show the whole thing had 16 characters and an
      // ellipsis, and a user following RELEASE.md could never match it.
      await pumpAbout(tester);
      expect(
        find.text(
          'EF7A C03D 1B2C 4D5E 6F70 8192 A3B4 C5D6 '
          'E7F8 091A 2B3C 4D5E 6F70 8192 A3B4 C5D6',
        ),
        findsOneWidget,
      );
    });

    testWidgets('nothing claims to be verified or up to date', (tester) async {
      // A build cannot verify its own signature (a tampered build carries a
      // tampered expectation and prints the same tick), and INV-8 means it
      // cannot know whether it is current without asking a server. Both would
      // be the first lie on the screen whose whole job is provenance.
      await pumpAbout(tester);
      expect(find.textContaining('Up to date'), findsNothing);
      expect(find.text('Verified'), findsNothing);
      expect(find.byType(KvCheck), findsNothing);
      expect(find.textContaining('published beside it'), findsOneWidget);
    });

    testWidgets('unreadable build metadata degrades honestly (BG-8)', (
      tester,
    ) async {
      await pumpAbout(tester, packageInfo: () async => throw 'no channel');
      expect(find.text('build metadata unavailable'), findsOneWidget);
      expect(find.textContaining('unreadable on this build'), findsOneWidget);
    });

    testWidgets('every roadmap line carries a status, and none is blank', (
      tester,
    ) async {
      await pumpAbout(tester);
      for (final d in RoadmapScreen.destinations) {
        expect(find.text(d.name), findsOneWidget, reason: d.name);
      }
      expect(find.text('Next'), findsOneWidget);
      expect(
        find.text('Planned'),
        findsNWidgets(RoadmapScreen.destinations.length - 1),
      );
    });

    testWidgets('the whole screen fits the phone, with nothing to scroll', (
      tester,
    ) async {
      // **Playbook §19.1 names About**: a status surface, where the whole
      // state is the point. It owes the fit, so it owes the §19.3 guard —
      // and the register claimed the fit from a frame that its own `Licences`
      // row was clipped in (`ux-auditor`, BLOCK).
      tester.view.physicalSize = const Size(393 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: _kvWindow,
          home: AboutScreen(
            scope: AboutScope(
              // Every seam, and the longest real datum: 64 hex characters.
              packageInfo: () async => const {
                'version': '1.0.0',
                'build': '3041',
                'signature':
                    'a1f39c204b7e88d10e52c6aa71b93f04'
                    'd2e85c179a0b6e33f41022cd8b7ae059',
              },
              openUrl: (_) async => true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      expect(
        position.maxScrollExtent,
        0,
        reason:
            'About overflows its own phone by '
            '${position.maxScrollExtent.toStringAsFixed(1)} dp — `Licences` '
            'is below the fold, which is the finding this guards',
      );
    });

    testWidgets('the source row leaves the app, and says so', (tester) async {
      final opened = <String>[];
      tester.view.physicalSize = const Size(393 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          builder: _kvWindow,
          home: AboutScreen(
            scope: AboutScope(
              packageInfo: () async => const {'version': '1.0.0'},
              openUrl: (url) async {
                opened.add(url);
                return true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp('Leaves the app')), findsOneWidget);
      await tester.tap(find.text('Source code'));
      await tester.pump();
      expect(opened, [AboutScreen.repository]);
      semantics.dispose();
    });
  });
}

/// Security's seams, in one place, so the root and `T2` are pumped against the
/// same contract.
SecurityScope securityScope({
  Future<String> Function()? biometricStatus,
  Future<String> Function()? pathAState,
  Future<bool> Function()? enroll,
  Future<void> Function()? clear,
  ValueNotifier<int>? grace,
  Future<void> Function(int)? setGrace,
  Future<void> Function()? lockNow,
}) => SecurityScope(
  biometricStatus: biometricStatus ?? () async => 'ready',
  pathAState: pathAState ?? () async => pathANone,
  enroll: enroll ?? () async => true,
  clearEnrollment: clear ?? () async {},
  lockGraceSecs: grace ?? ValueNotifier(0),
  setLockGraceSecs: setGrace ?? (_) async {},
  lockNow: lockNow,
);

SignableSummaryDto _summary() => SignableSummaryDto(
  kind: SignableKind.consolidate,
  destination: 'kaspa:qrxk2f9pabcdefghijklmnopqrstuvwmx3f4a2',
  amountSompi: BigInt.from(1240000000),
  feeSompi: BigInt.from(40000),
  totalSompi: BigInt.from(1240040000),
  mass: BigInt.from(2036),
  txCount: 1,
  utxoCount: 38,
  payloadLen: null,
  payloadKind: null,
  nonce: BigInt.one,
  resultingCoins: 1,
  feeStrategy: FeeStrategyKind.senderPays,
  priorityFeeSompi: BigInt.zero,
);

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
            maturity: kTestMaturity,
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

/// `KvWindow` above the `Navigator`, exactly as `main.dart` mounts it — a
/// pushed sheet reads the window class to decide whether it is full-width or
/// floating (BG-33), so a host without it cannot build the route under test.
Widget _kvWindow(BuildContext context, Widget? page) => KvWindow(child: page!);
