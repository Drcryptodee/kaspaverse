import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/home_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_amount.dart';
import 'package:kaspaverse/src/ui/widgets/kv_coming_soon.dart';
import 'package:kaspaverse/src/ui/widgets/kv_drawer.dart';
import 'package:kaspaverse/src/ui/widgets/kv_glyph.dart';
import 'package:kaspaverse/src/ui/widgets/kv_money_plate.dart';
import 'package:kaspaverse/src/ui/widgets/kv_rows.dart';
import 'package:kaspaverse/src/ui/widgets/kv_status_chip.dart';
import 'package:kaspaverse/src/ui/widgets/kv_tabs.dart';
import 'package:kaspaverse/src/ui/widgets/kv_two_pane.dart';

import 'support/preview_harness.dart';

/// **UX-R1 — the shell, the drawer, the money plate and the ledger, in Deep
/// V6.** The guards for the parts this sitting built, and for the one law that
/// makes them a system rather than eight widgets: BG-33.
void main() {
  setUpAll(loadBundledFonts);

  // ───────────────────────────────────────────────────────────────────────
  // BG-33 · the window is derived ONCE, and nothing below it decides a layout
  // ───────────────────────────────────────────────────────────────────────

  group('BG-33 — one decision point, and no breakpoint under it', () {
    /// **The sweep, as a test rather than as a paragraph.**
    ///
    /// `ux-auditor` item 24a forbids a *breakpoint* — choosing a layout from a
    /// raw width — anywhere below the root. It does **not** forbid measuring
    /// the space a widget was actually given, and it says nothing at all about
    /// pixels. Ten of the twelve hits in the UX-R0 sweep were correct code
    /// (`UX_R_REGISTER.md` §2), so a guard that simply counted matches would
    /// have sent four auditor fixes, a Lie-Factor guard and a decode budget
    /// back to be "fixed".
    ///
    /// So every site is pinned with its reason. A NEW one reddens this test,
    /// which is the only way a rule like this survives contact with the next
    /// six groups.
    test('every width-reading site in lib/ is one of the classified ones', () {
      const allowed = <String, String>{
        'lib/src/ui/theme/kv_window.dart':
            'THE decision point — the one place a width becomes a class',
        'lib/src/ui/widgets/kv_two_pane.dart':
            'measures the space it was GIVEN to split it; the arrangement was '
            'already chosen by the class',
        'lib/src/ui/home_screen.dart':
            'bounds the pinned plate by the viewport HEIGHT — never a width',
        'lib/src/ui/restore_screen.dart':
            'min-height centring with an overflow escape (an auditor fix)',
        'lib/src/ui/create_screen.dart': 'same pattern, same origin',
        'lib/src/ui/widgets/kv_burial_gauge.dart':
            'a gauge must measure its own track to place ticks — BG-22 ink '
            '(L145). Removing it would CREATE a Lie Factor defect',
        'lib/src/ui/widgets/kv_rows.dart':
            'intrinsic sizing inside a row; no width is read',
        'lib/src/ui/widgets/kv_drawer.dart':
            'rounds the rail\'s scroll viewport DOWN to a whole number of '
            'sockets so a clip never falls through a glyph — a HEIGHT it was '
            'given, never a width',
        'lib/src/ui/messages/contacts_screen.dart':
            'keyboard inset (`viewInsets`), not width',
        'lib/src/ui/messages/history_fill_sheet.dart': 'keyboard inset',
        'lib/src/ui/messages/thread_screen.dart':
            'keyboard inset, plus a decode budget in PHYSICAL pixels and two '
            'bubble caps R5 owns (U2-1 / U2-2, register §2)',
      };
      final offenders = <String>[];
      for (final file
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        // Generated bindings are never edited by hand and carry no layout.
        if (file.path.startsWith('lib/src/rust/')) continue;
        final source = file.readAsStringSync();
        final reads =
            source.contains('MediaQuery.sizeOf') ||
            source.contains('MediaQuery.of(context).size') ||
            source.contains('LayoutBuilder') ||
            source.contains('constraints.maxWidth');
        if (reads && !allowed.containsKey(file.path)) {
          offenders.add(file.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'a new width-reading site appeared below the root. If it measures '
            'the space it was given, add it to the allow-list with its reason; '
            'if it chooses a layout from a width, it is a BG-33 violation and '
            'the answer is KvWindow.of(context)',
      );
    });

    testWidgets('the provider sits ABOVE the Navigator, so a pushed route '
        'reads the same window the page did', (tester) async {
      tester.view.physicalSize = const Size(1180, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late KvWindowMetrics onPage;
      late KvWindowMetrics onRoute;
      await tester.pumpWidget(
        MaterialApp(
          theme: kvDarkTheme(),
          builder: (context, page) => KvWindow(child: page!),
          home: Builder(
            builder: (context) {
              onPage = KvWindow.of(context);
              return TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (c) {
                      onRoute = KvWindow.of(c);
                      return const SizedBox.shrink();
                    },
                  ),
                ),
                child: const Text('push'),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();
      // The failure this guards: mounting below `home:` puts the provider
      // under the Navigator, so every pushed route — Send, Receive, the
      // ceremony, Settings — falls back to `compact` and lays a tablet out as
      // a phone, silently.
      expect(onPage.widthClass, KvWindowClass.expanded);
      expect(onRoute.widthClass, KvWindowClass.expanded);
      expect(tester.takeException(), isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // §4 / §3a.2 · the drawer, in three postures
  // ───────────────────────────────────────────────────────────────────────

  group('KvDrawer — one widget, three postures (§4, §3a.2)', () {
    for (final (label, size, posture) in const [
      ('393 compact', Size(393, 851), 'pushed'),
      ('700 medium', Size(700, 900), 'rail'),
      ('1180 expanded', Size(1180, 800), 'standing'),
      ('915x412 expanded short', Size(915, 412), 'rail'),
    ]) {
      testWidgets('$label ⇒ $posture', (tester) async {
        await pumpShell(tester, size);
        // `compact` hides the panel behind the page until it is summoned, so
        // the posture is read from what navigation IS rather than from what
        // is currently visible.
        expect(
          find.byType(KvRail),
          posture == 'rail' ? findsOneWidget : findsNothing,
          reason: label,
        );
        expect(
          find.byType(KvDrawer),
          posture == 'rail' ? findsNothing : findsOneWidget,
          reason: label,
        );
        // §3a.2: the avatar summons the drawer in `compact` and is DROPPED
        // wherever navigation already stands — never kept and made inert.
        expect(
          find.bySemanticsLabel('Open navigation'),
          posture == 'pushed' ? findsOneWidget : findsNothing,
          reason: label,
        );
        if (posture != 'pushed') {
          expect(
            tester
                .getSize(find.byType(posture == 'rail' ? KvRail : KvDrawer))
                .width,
            posture == 'rail' ? KvLayout.rail : KvLayout.drawer,
            reason: label,
          );
        }
      });
    }

    testWidgets('the panel is 296 and the page is pushed exactly that far', (
      tester,
    ) async {
      await pumpShell(tester, const Size(393, 851));
      final before = tester.getTopLeft(find.byType(HomeScreen)).dx;
      await tester.tap(find.bySemanticsLabel('Open navigation'));
      await tester.pump();
      await tester.pump(KvMotion.enter);
      await tester.pump(KvMotion.enter);
      expect(tester.getSize(find.byType(KvDrawer)).width, KvLayout.drawer);
      expect(
        tester.getTopLeft(find.byType(HomeScreen)).dx - before,
        closeTo(KvMotion.drawerPush, 0.5),
        reason: 'the page translates 296 dp right (§3)',
      );
    });

    testWidgets('an unbuilt destination wears a tag and takes NO tap (§8)', (
      tester,
    ) async {
      await pumpShell(tester, const Size(1180, 800));
      for (final unbuilt in const ['Games', 'Finance', 'Identity']) {
        final row = find.ancestor(
          of: find.text(unbuilt),
          matching: find.byType(KvRow),
        );
        expect(row, findsOneWidget, reason: unbuilt);
        expect(
          tester.widget<KvRow>(row).onTap,
          isNull,
          reason: '$unbuilt is a dead button if it answers a tap',
        );
      }
      // The tag itself, in the seat the feature will occupy.
      expect(find.text('Coming soon'), findsNWidgets(3));
    });

    testWidgets('every destination §4 names is seated, in §4\'s order', (
      tester,
    ) async {
      await pumpShell(tester, const Size(1180, 800));
      const order = ['Wallet', 'Messages', 'Games', 'Finance', 'Identity'];
      var previous = double.negativeInfinity;
      for (final name in order) {
        final top = tester.getRect(find.text(name)).top;
        expect(top, greaterThan(previous), reason: name);
        previous = top;
      }
      // Settings and Lock at the FOOT, under the hairline.
      for (final foot in const ['Settings', 'Lock']) {
        expect(
          tester.getRect(find.text(foot)).top,
          greaterThan(previous),
          reason: foot,
        );
      }
    });

    testWidgets('the drawer NEVER survives a discard of its subtree (BG-13)', (
      tester,
    ) async {
      // The shell replaces this whole subtree at 0 ms when the vault locks, so
      // the open state has nowhere to persist. Asserted by doing exactly what
      // the shell does — swapping the child — rather than by trusting it.
      await pumpShell(tester, const Size(393, 851));
      await tester.tap(find.bySemanticsLabel('Open navigation'));
      await tester.pump();
      await tester.pump(KvMotion.enter);
      await tester.pump(KvMotion.enter);
      expect(tester.getTopLeft(find.byType(HomeScreen)).dx, greaterThan(100));

      await tester.pumpWidget(const SizedBox());
      await pumpShell(tester, const Size(393, 851));
      expect(
        tester.getTopLeft(find.byType(HomeScreen)).dx,
        0,
        reason: 'a re-mounted shell opens closed',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // §4 · the money plate, and the one collapse there is
  // ───────────────────────────────────────────────────────────────────────

  group('KvMoneyPlate / KvMoneyBar (BG-28, BG-33)', () {
    testWidgets('the plate holds only what is always true', (tester) async {
      await pumpShell(tester, const Size(393, 851));
      // Label, figure, fiat slot, live dot, the raised pair — and nothing
      // transient inside the plate itself.
      final plate = find.byType(KvMoneyPlate);
      expect(plate, findsOneWidget);
      for (final always in const ['Receive', 'Send']) {
        expect(
          find.descendant(of: plate, matching: find.text(always)),
          findsOneWidget,
          reason: always,
        );
      }
      expect(
        find.descendant(of: plate, matching: find.byType(KvLamp)),
        findsOneWidget,
        reason: 'the live dot is IN the plate (§4)',
      );
      // The pair is 52 high and raised — not the screen's one primary fill.
      expect(
        tester
            .getSize(
              find
                  .ancestor(
                    of: find.text('Send'),
                    matching: find.byType(AnimatedContainer),
                  )
                  .first,
            )
            .height,
        KvSpace.controlThumb,
      );
    });

    testWidgets('the bar returns the fraction on a tap', (tester) async {
      await pumpShell(tester, const Size(915, 412));
      expect(find.byType(KvMoneyBar), findsOneWidget);
      Finder inBar(Pattern p) => find.descendant(
        of: find.byType(KvMoneyBar),
        matching: find.textContaining(p),
      );
      // Whole units by default — and **the abbreviation carries its own
      // mark**, because a figure that hides digits without saying so is a
      // truncation presenting itself as a value (BG-5).
      expect(inBar('1,284'), findsOneWidget);
      expect(inBar('…'), findsOneWidget);
      expect(inBar('.5027'), findsNothing);
      await tester.tap(inBar('1,284'));
      await tester.pump();
      // …and every significant digit one tap later. Nothing is deleted by the
      // collapse; it is put one tap away, and the mark goes with it.
      expect(inBar('.5027'), findsOneWidget);
      expect(inBar('…'), findsNothing);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // §4 / BG-33 · the ledger
  // ───────────────────────────────────────────────────────────────────────

  group('the ledger (§4, §5, A6, A9)', () {
    testWidgets('a row is 64 dp in EVERY window class (BG-33, A9)', (
      tester,
    ) async {
      for (final size in const [
        Size(393, 851),
        Size(700, 900),
        Size(1180, 800),
      ]) {
        await pumpShell(tester, size, activity: _activity());
        expect(
          tester.getSize(find.byType(KvRow).first).height,
          KvRow.height,
          reason: '$size: a tablet shows MORE rows, never smaller ones',
        );
      }
    });

    testWidgets('the ledger is headed by Activity · Tokens, and Tokens is a '
        'designed seat rather than a feature (B1)', (tester) async {
      await pumpShell(tester, const Size(393, 851), activity: _activity());
      expect(find.byType(KvTabs), findsOneWidget);
      expect(find.text('Activity'), findsOneWidget);
      expect(find.text('Tokens'), findsOneWidget);
      expect(find.byType(KvComingSoon), findsNothing);

      await tester.tap(find.text('Tokens'));
      await tester.pump();
      await tester.pump(KvMotion.calm);
      // No token layer exists in Rust, the bridge or the DTOs, so the tab
      // shows the shape of what is missing in the seat it will occupy — never
      // an empty list pretending to be one.
      expect(find.byType(KvComingSoon), findsOneWidget);
      expect(find.text('Assets'), findsOneWidget);
    });

    testWidgets('tapping a row fills the DETAIL column in expanded, and '
        'pushes below it (§3a.2)', (tester) async {
      await pumpShell(tester, const Size(1180, 800), activity: _activity());
      expect(find.byType(KvTwoPane), findsOneWidget);
      expect(find.text('Select a transaction.'), findsOneWidget);
      await tester.tap(find.text('Received'));
      await tester.pump();
      await tester.pump(KvMotion.enter);
      expect(find.text('Select a transaction.'), findsNothing);
      expect(find.text('the detail pane'), findsOneWidget);
    });

    test('the list pane is derived, and yields to the detail column', () {
      // §3a.1 puts the pane at 400–480 and pins the V60 in landscape at 340;
      // both fall out of the same formula rather than being special-cased.
      expect(KvTwoPane.listWidth(1440 - 296, 48), inInclusiveRange(400, 480));
      expect(KvTwoPane.listWidth(915 - 80, 40), KvTwoPane.minList);
      // A detail column never falls under 320.
      for (final width in const [700.0, 840.0, 915.0, 1180.0, 1440.0]) {
        final pane = KvTwoPane.listWidth(width, 40);
        expect(
          width - 80 - KvLayout.columnGap - pane,
          greaterThanOrEqualTo(KvTwoPane.minDetail - 0.5),
          reason: '$width',
        );
      }
    });
  });

  testWidgets('a long amount shrinks the FIGURE, never the title — and never '
      'overflows (BG-5, BG-14)', (tester) async {
    // **The defect this is written against**, measured at 320 dp / 1.3× before
    // the fix: an unbounded trailing column took its intrinsic width, so
    // `KvAmount`'s own `FittedBox(scaleDown)` had nothing to fit inside. A
    // 1,234.56789012 KAS row drove the title to **0 dp** and overflowed the
    // row by 19; a 123,456 KAS row painted the figure past the screen edge.
    //
    // **No `find.text` assertion could see it** — a finder matches a 0 dp
    // `Text` (L131) — so the gate was green through it and `ux-auditor` was
    // not. That is the whole argument for item 24d.
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(320 * 3, 720 * 3);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    for (final sompi in const [
      '2500000000',
      '10012345678',
      '123456789012',
      '12345678901234',
    ]) {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          theme: kvDarkTheme(),
          builder: (context, page) => KvWindow(child: page!),
          home: Scaffold(
            backgroundColor: KvColor.abyss,
            body: Padding(
              padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
              child: KvRowContainer(
                children: [
                  KvRow(
                    leading: const KvRowDisc.neutral(mark: KvGlyph.arrowIn),
                    title: 'Received',
                    trailing: KvAmount(
                      BigInt.parse(sompi),
                      role: KvAmountRole.row,
                      direction: KvMoneyDirection.incoming,
                    ),
                    trailingMeta: const Text('12 m ago'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: '$sompi: the row overflowed instead of the figure scaling',
      );
      expect(
        tester.getSize(find.text('Received')).width,
        greaterThan(40),
        reason: '$sompi: the title was starved to nothing',
      );
      expect(
        tester.getRect(find.byType(KvRow)).right,
        lessThanOrEqualTo(320 - KvSpace.gutter + 0.5),
        reason: '$sompi: the row is painted past the gutter',
      );
    }
  });

  // ───────────────────────────────────────────────────────────────────────
  // A3 · the shed order, MEASURED — not left to taste
  // ───────────────────────────────────────────────────────────────────────

  group('A3 — what a squeeze takes, at 320x568 / 1.3x', () {
    /// **The risk note A3 recorded is real, and this is it measured.**
    ///
    /// BG-28 admits into the plate only what is always true — label, figure,
    /// `≈` fiat, live dot, the raised pair — and puts everything transient in
    /// a strip *beneath* it. That inverts the shed order a previous audit
    /// required: the honesty *sentence* now sits below the fiat line, so a
    /// squeeze takes it first.
    ///
    /// **What it does not take is the signal.** The lamp goes amber and the
    /// figure dims to 45% *inside the plate*, which is the part that pins. A
    /// user at the tightest supported geometry can never read a bright,
    /// confident number with nothing to say it is old — they read a dimmed
    /// number under an amber lamp, and the sentence is one scroll away.
    ///
    /// Said out loud, and pinned, because A3 asked for exactly that rather
    /// than for a judgement call.
    testWidgets('the sentence may shed; the lamp and the dimming never do', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(320 * 3, 568 * 3);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_squeezed());
      await tester.pump();
      await tester.pump(KvMotion.enter);

      final viewport = tester.getRect(find.byType(CustomScrollView));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pump();

      final header = tester
          .renderObjectList<RenderSliverPersistentHeader>(
            find.byType(SliverPersistentHeader),
          )
          .first;
      final pinned = header.geometry!.paintExtent;
      final plate = tester.getRect(find.byType(KvMoneyPlate));
      final strip = tester.getRect(
        find.textContaining('node has no UTXO index'),
      );
      // The numbers, printed so the record carries a measurement rather than
      // an adjective (L121).
      debugPrint(
        'A3 @ 320x568/1.3x — viewport ${viewport.height.toStringAsFixed(1)} · '
        'cap ${(viewport.height / 2).toStringAsFixed(1)} · '
        'pinned ${pinned.toStringAsFixed(1)} · '
        'plate ${plate.height.toStringAsFixed(1)} · '
        'sentence bottom ${(strip.bottom - viewport.top).toStringAsFixed(1)}',
      );

      // **The cost, asserted rather than described.** At this geometry the
      // band wants 309 dp against a 234.5 dp cap, so it pins at the plate
      // (221.2) and the strip below it is clipped: the trust SENTENCE is what
      // a squeeze takes. That is A3's risk note realised, and it is stated
      // here so a later reader finds a measurement instead of an opinion.
      expect(
        strip.bottom - viewport.top,
        greaterThan(pinned),
        reason: 'A3: the sentence sheds — say so out loud, do not discover it',
      );

      // **The plate survives the squeeze whole.** Every part of it is
      // load-bearing under BG-28, so none of it is sheddable.
      expect(
        plate.bottom,
        lessThanOrEqualTo(viewport.top + pinned + 0.5),
        reason: 'the plate itself must never be clipped by the pinned band',
      );
      // The signal is inside it, and stays.
      expect(
        find.descendant(
          of: find.byType(KvMoneyPlate),
          matching: find.byType(KvLamp),
        ),
        findsOneWidget,
      );
      expect(
        tester.widgetList<KvLamp>(find.byType(KvLamp)).first.tone,
        KvLampTone.warn,
        reason: 'a dark link is amber on the plate, whatever the geometry',
      );
      // …and so is the dimming: the figure is at 45%, never full brightness.
      expect(
        tester
            .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
            .map((o) => o.opacity),
        contains(KvFreshness.opacityStale),
        reason: 'BG-8: a number nobody can vouch for is never bright',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // BG-2 · what the shell spends the light on
  // ───────────────────────────────────────────────────────────────────────

  testWidgets('the light is rationed, and the two columns are counted '
      'separately (BG-2)', (tester) async {
    await pumpShell(tester, const Size(1180, 800), activity: _activity());

    // **Emitting OBJECTS, not hex occurrences**, and counted per column.
    //
    // BG-2 caps a *screen* at three. §3a's own model is that a wider window
    // gains **columns with jobs** — and the navigation column is one, standing
    // across every screen in the app. Counting its orb against each screen's
    // cap would leave two emissions for the whole of `expanded`, which §5's
    // own compositions cannot be built inside (Send alone spends a primary
    // pill, a caret and a Paste ghost). So the money column is counted against
    // the three, and navigation is counted as the one surface it is.
    // Counted at the `DecoratedBox` leaf, which is what actually paints: a
    // `Container` builds one, an `AnimatedContainer` builds a `Container` that
    // builds one, and counting the wrappers too would report a single live dot
    // as three emissions — a guard that fails for the wrong reason is worse
    // than none.
    int emissionsIn(Finder scope) => find
        .descendant(
          of: scope,
          matching: find.byWidgetPredicate(
            (w) => w is DecoratedBox && _isPrimaryFill(w.decoration),
          ),
        )
        .evaluate()
        .length;

    // The money column: the live dot, and the ledger's active tab underline.
    expect(
      emissionsIn(find.byType(HomeScreen)),
      lessThanOrEqualTo(3),
      reason: 'ration the light and its arrival still means something',
    );
    expect(emissionsIn(find.byType(HomeScreen)), 2);
    // The navigation column: the orb disc, and nothing else. Every socket
    // glyph and the K avatar are `primaryMuted`, which is ambient and
    // UNCOUNTED (§1.5) — counting them here is the finding pointed the wrong
    // way round.
    expect(emissionsIn(find.byType(KvDrawer)), 1);
  });

  testWidgets('an avatar and a socket CARRY the brand, they never emit '
      '(§1.5)', (tester) async {
    await pumpShell(tester, const Size(393, 851));
    final avatar = tester.widget<Container>(
      find
          .descendant(
            of: find.bySemanticsLabel('Open navigation'),
            matching: find.byType(Container),
          )
          .first,
    );
    expect((avatar.decoration! as BoxDecoration).color, KvColor.tealTint);
    expect(
      tester
          .renderObject<RenderParagraph>(
            find.descendant(
              of: find.bySemanticsLabel('Open navigation'),
              matching: find.text('K'),
            ),
          )
          .text
          .style!
          .color,
      KvColor.primaryMuted,
    );
  });
}

/// The degraded money screen: a dark link, a node with no UTXO index, money
/// pending and money in flight — the tallest the pinned band ever gets.
Widget _squeezed() {
  final now = DateTime(2026, 9, 4, 12);
  return MaterialApp(
    theme: kvDarkTheme(),
    builder: (context, page) => KvWindow(child: page!),
    home: HomeScreen(
      chain: ChainScope(
        connected: ValueNotifier(false),
        virtualDaaScore: ValueNotifier<BigInt?>(BigInt.from(526633447)),
        error: ValueNotifier<String?>(null),
        lastUpdate: ValueNotifier<DateTime?>(
          now.subtract(const Duration(minutes: 3)),
        ),
      ),
      wallet: WalletScope(
        mature: ValueNotifier<BigInt?>(BigInt.parse('128450270000')),
        pending: ValueNotifier<BigInt?>(BigInt.parse('128450270000')),
        outgoing: ValueNotifier<BigInt?>(BigInt.parse('128450270000')),
        // Enough rows that the ledger genuinely scrolls: a band that never
        // shrinks because there is nothing under it to scroll is not a
        // measurement of the squeeze, it is a measurement of an empty wallet.
        activity: ValueNotifier(_activity(count: 12)),
        syncing: ValueNotifier(false),
        utxoIndexMissing: ValueNotifier(true),
      ),
      clock: () => now,
      receiveRoute: (_) => const SizedBox.shrink(),
      sendRoute: (_, _) => const SizedBox.shrink(),
    ),
  );
}

bool _isPrimaryFill(Decoration? d) =>
    d is BoxDecoration && d.color == KvColor.primary;

List<ActivityRecord> _activity({int count = 1}) => [
  for (var i = 0; i < count; i++)
    ActivityRecord(
      txid: '${i.toRadixString(16)}${'a' * 63}',
      valueSompi: BigInt.from(2400000000),
      unixtimeMsec: BigInt.from(1788085010103),
      blockDaaScore: BigInt.from(526633400),
      direction: ActivityDirection.incoming,
      isCoinbase: false,
      maturity: MaturityState.confirmed,
      stalled: false,
    ),
];

/// The money screen inside the app's navigation, at one geometry — the only
/// way either of them is ever seen.
Future<void> pumpShell(
  WidgetTester tester,
  Size size, {
  List<ActivityRecord> activity = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final now = DateTime(2026, 9, 4, 12);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    MaterialApp(
      theme: kvDarkTheme(),
      builder: (context, page) => KvWindow(child: page!),
      home: KvNav(
        selected: 0,
        destinations: [
          KvDestination(mark: KvGlyph.money, label: 'Wallet', onTap: () {}),
          KvDestination(mark: KvGlyph.chat, label: 'Messages', onTap: () {}),
          const KvDestination(
            mark: KvGlyph.games,
            label: 'Games',
            tag: 'Coming soon',
          ),
          const KvDestination(
            mark: KvGlyph.finance,
            label: 'Finance',
            tag: 'Coming soon',
          ),
          const KvDestination(
            mark: KvGlyph.identity,
            label: 'Identity',
            tag: 'Coming soon',
          ),
        ],
        footer: [
          KvDestination(
            mark: KvGlyph.settings,
            label: 'Settings',
            onTap: () {},
          ),
          KvDestination(mark: KvGlyph.lock, label: 'Lock', onTap: () {}),
        ],
        child: HomeScreen(
          chain: ChainScope(
            connected: ValueNotifier(true),
            virtualDaaScore: ValueNotifier<BigInt?>(BigInt.from(526633447)),
            error: ValueNotifier<String?>(null),
            lastUpdate: ValueNotifier<DateTime?>(now),
          ),
          wallet: WalletScope(
            mature: ValueNotifier<BigInt?>(BigInt.from(128450270000)),
            pending: ValueNotifier<BigInt?>(BigInt.zero),
            activity: ValueNotifier(activity),
            syncing: ValueNotifier(false),
            utxoIndexMissing: ValueNotifier(false),
          ),
          clock: () => now,
          receiveRoute: (_) => const SizedBox.shrink(),
          sendRoute: (_, _) => const SizedBox.shrink(),
          detailRoute: (_, _, _) =>
              const Center(child: Text('the detail pane')),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(KvMotion.enter);
}
