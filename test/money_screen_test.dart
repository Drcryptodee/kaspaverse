import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/services/rate_service.dart';
import 'package:kaspaverse/src/ui/home_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_cadence.dart';
import 'package:kaspaverse/src/ui/widgets/kv_money_plate.dart';
import 'package:kaspaverse/src/ui/widgets/kv_tabs.dart';
import 'package:kaspaverse/src/ui/widgets/kv_status_chip.dart';
import 'support/finders.dart';

/// **UX-2 — the money surface**, in the five states it has to hold
/// (SCREEN_INVENTORY 7a–7e): first-run empty · live · syncing · in flight ·
/// degraded.
///
/// The primitives are pinned by `kv_*_test.dart`; this file pins the
/// **composition** — what appears, what stays silent, and what a squeeze does
/// to it.
/// The bundled faces, so a width measured here is a width about Inter and
/// JetBrains Mono rather than about the test fallback — whose glyphs are square
/// em-boxes and overstate every label by roughly a factor of two. A 320dp /
/// 1.3x claim measured in Ahem is a claim about Ahem.
///
/// Called from `setUpAll`, NEVER from inside `testWidgets`: the test body runs
/// in a fake-async zone where real file I/O never completes (settings_screen_
/// test.dart records the 2m57s hang that taught this).
Future<void> loadBundledFonts() async {
  for (final font in const {
    'PlusJakartaSans': 'assets/fonts/PlusJakartaSans-Variable.ttf',
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

  final t0 = DateTime(2026, 8, 27, 14, 2, 41);

  ActivityRecord received({
    required BigInt sompi,
    required DateTime at,
    MaturityState maturity = MaturityState.confirmed,
  }) => ActivityRecord(
    txid: 'a' * 64,
    valueSompi: sompi,
    unixtimeMsec: BigInt.from(at.millisecondsSinceEpoch),
    blockDaaScore: BigInt.from(1000),
    direction: ActivityDirection.incoming,
    isCoinbase: false,
    maturity: maturity,
    stalled: false,
  );

  ActivityRecord sent({
    required BigInt sompi,
    required DateTime at,
    bool stalled = false,
  }) => ActivityRecord(
    txid: 'b' * 64,
    valueSompi: sompi,
    unixtimeMsec: BigInt.from(at.millisecondsSinceEpoch),
    blockDaaScore: BigInt.from(1000),
    acceptedDaaScore: stalled ? null : BigInt.from(1000),
    direction: ActivityDirection.outgoing,
    isCoinbase: false,
    maturity: stalled ? MaturityState.pending : MaturityState.confirmed,
    stalled: stalled,
  );

  ActivityRecord merged({required BigInt sompi, required DateTime at}) =>
      ActivityRecord(
        txid: 'c' * 64,
        valueSompi: sompi,
        unixtimeMsec: BigInt.from(at.millisecondsSinceEpoch),
        blockDaaScore: BigInt.from(1000),
        direction: ActivityDirection.change,
        isCoinbase: false,
        maturity: MaturityState.confirmed,
        stalled: false,
      );

  Widget money({
    BigInt? mature,
    BigInt? pending,
    BigInt? outgoing,
    bool connected = true,
    bool syncing = false,
    bool utxoIndexMissing = false,
    bool discoveryIncomplete = false,
    DateTime? lastUpdate,
    DateTime? now,
    List<ActivityRecord> activity = const [],
    Future<void> Function()? onRefresh,
    bool actions = true,
    // The fiat restatement, wired ON with no quote by default — which is the
    // state a wallet is in for the first seconds of every launch, and the one
    // BG-5 answers with `≈ —`.
    // `null` is a real third value here: the posture has not been read yet.
    bool? rateOn = true,
    KvRateQuote? quote,
    // A clock that can be MOVED, for the one assertion about a value that
    // changes because time passed rather than because data arrived.
    DateTime Function()? clock,
  }) => MaterialApp(
    theme: kvDarkTheme(),
    // The window is derived once at the root and read from context (BG-33) —
    // the same mount point `main.dart` uses.
    builder: (context, page) => KvWindow(child: page!),
    home: HomeScreen(
      chain: ChainScope(
        connected: ValueNotifier(connected),
        virtualDaaScore: ValueNotifier<BigInt?>(BigInt.from(2000)),
        error: ValueNotifier<String?>(null),
        lastUpdate: ValueNotifier<DateTime?>(lastUpdate ?? t0),
      ),
      wallet: WalletScope(
        mature: ValueNotifier<BigInt?>(mature),
        pending: ValueNotifier<BigInt?>(pending),
        outgoing: ValueNotifier<BigInt?>(outgoing),
        activity: ValueNotifier<List<ActivityRecord>>(activity),
        syncing: ValueNotifier(syncing),
        utxoIndexMissing: ValueNotifier(utxoIndexMissing),
        discoveryIncomplete: ValueNotifier(discoveryIncomplete),
        onRefreshActivity: onRefresh,
      ),
      clock: clock ?? () => now ?? t0,
      fiat: FiatScope(
        enabled: ValueNotifier<bool?>(rateOn),
        quote: ValueNotifier<KvRateQuote?>(quote),
      ),
      sendRoute: actions ? (_, _) => const Placeholder() : null,
      receiveRoute: actions ? (_) => const Placeholder() : null,
    ),
  );

  /// Two frames: one to build, one for the pinned plate to adopt its MEASURED
  /// extent. Never `pumpAndSettle` — the freshness ticker never ends.
  Future<void> pump(
    WidgetTester tester,
    Widget app, {
    double width = 393,
    double height = 850,
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = Size(width * 3.0, height * 3.0);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    // A fresh mount every time. `HomeScreen` asserts its injected notifiers
    // stay identical for the life of the state (the V4 seam law), so pumping a
    // second fixture over a live one trips that assert rather than the thing
    // under test.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app);
    await tester.pump();
  }

  TextStyle styleOf(WidgetTester tester, String text) =>
      tester.renderObject<RenderParagraph>(find.text(text)).text.style!;

  group('the five states', () {
    testWidgets('first run: the one empty state, and the door that says why', (
      tester,
    ) async {
      await pump(tester, money(mature: BigInt.zero));

      // Etched glyph · one truth · one nudge — and the SHIPPED copy, because
      // the redesign is a change of form, not of voice (D-196).
      expect(find.text('No recent activity'), findsOneWidget);
      expect(
        find.text('Payments you send and receive appear here.'),
        findsOneWidget,
      );
      // The tabs head the container whether or not it has rows; what must not
      // appear is a promise of a ledger there is none of.
      expect(find.text('Recent activity'), findsNothing);
      expect(find.text('Activity'), findsOneWidget);

      // **Neither pill is primary, and UX-2's light-flip is superseded.**
      // §4 gives the money plate a *raised* Send / Receive pair, so this
      // screen's emissions are the live dot and the ledger's active tab
      // underline — and on a proven zero the statement is not a brighter
      // Receive but a Send that is disabled and says why (BG-12), which is
      // the stronger of the two.
      // **Send is disabled and says why INSIDE its pill** (BG-12, D-262): the
      // foot bar's footprint is constant, so the reason replaces the verb on
      // a `shelf` pill. Receive is raised, never the one primary fill.
      expect(find.text('Nothing to send yet'), findsOneWidget);
      expect(find.text('Send'), findsNothing);
      final receive = tester.widget<AnimatedContainer>(
        find
            .ancestor(
              of: find.text('Receive'),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      expect(
        (receive.decoration! as BoxDecoration).color,
        isNot(KvColor.primary),
        reason: 'Receive is raised, never the one primary fill',
      );
      final send = tester.widget<AnimatedContainer>(
        find
            .ancestor(
              of: find.text('Nothing to send yet'),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      expect(
        (send.decoration! as BoxDecoration).color,
        KvColor.shelf,
        reason: 'a disabled pill is `shelf`, its reason in words on it (§4)',
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an UNKNOWN balance is not an empty one', (tester) async {
      // The trap the empty state sits next to: `mature == null` means we do
      // not know, and telling that user they have nothing to send is a claim
      // we cannot make (BG-5/BG-8).
      await pump(tester, money(mature: null, connected: false));
      expect(find.text('—'), findsOneWidget);
      expect(find.text('Nothing to send yet'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an UNPROVEN zero is not an empty one either', (tester) async {
      // A zero the wallet cannot vouch for is not a zero. `discoveryIncomplete`
      // means the balance was computed over a window that may be SHORT, and
      // `utxoIndexMissing` means the node cannot see this wallet's coins at
      // all — so the plate was saying "this may not be your whole balance" and
      // "Nothing to send yet" in the same frame, and closing the money door on
      // a wallet that may hold funds (`consensus-auditor`, UX-2).
      for (final label in const ['discovery', 'utxo index']) {
        await pump(
          tester,
          money(
            mature: BigInt.zero,
            discoveryIncomplete: label == 'discovery',
            utxoIndexMissing: label == 'utxo index',
          ),
        );
        expect(find.text('Nothing to send yet'), findsNothing, reason: label);
      }
      // The control: a zero nothing disputes really does close the door.
      await pump(tester, money(mature: BigInt.zero));
      expect(find.text('Nothing to send yet'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('live: a settled screen is a STILL and SILENT one', (
      tester,
    ) async {
      await pump(
        tester,
        money(
          mature: BigInt.parse('128450270000'),
          activity: [
            received(
              sompi: BigInt.from(2400000000),
              at: t0.subtract(const Duration(seconds: 12)),
            ),
          ],
        ),
      );

      // **Silence is the healthy state** (D-192). A standing "Node responding"
      // beside a permanently animating meter reports that nothing changed,
      // twice, and becomes wallpaper.
      expect(find.byType(KvCadence), findsNothing);
      expect(find.textContaining('as of'), findsNothing);
      expect(find.text('syncing…'), findsNothing);
      // The chip's lamp is the screen's standing link indicator (founder call,
      // 2026-08-27, amending BG-7 — see `_NetworkChip`'s doc). It is the ONLY
      // lamp on a healthy screen: the trust line stays silent, so a second one
      // never appears beside it.
      expect(find.text('Mainnet'), findsOneWidget);
      expect(find.byType(KvLamp), findsOneWidget);
      expect(
        tester.widget<KvLamp>(find.byType(KvLamp)).tone,
        // **`ok` green, pulsing** (founder correction D-259, from the intake
        // render). A6 said `ok` from the start — *"link healthy"* is one of
        // BG-7's `ok` meanings — and the teal reading was the transcription,
        // not the design. Teal is never a status.
        KvLampTone.ok,
        reason: 'a live link reads live on the chip',
      );

      // The figure: a `caps` label nested into the plate's corner (A8), the
      // unit WITH the number, every significant decimal and no more.
      expect(findCapsLabel('Available balance'), findsOneWidget);
      expect(find.text('1,284'), findsOneWidget);
      expect(find.text('.5027'), findsOneWidget);
      expect(find.text('KAS'), findsWidgets);
      // Teal, by the founder's ruling on glass (D-262) over the render's
      // grey (S1).
      expect(styleOf(tester, 'KAS').color, KvColor.primaryMuted);

      // **The chain clock reads under the balance** (A4, founder ruling
      // D-256). It came off at UX-R1 on a reading of BG-8 and went back on
      // with the distinction that reading was missing: the counter's animation
      // is not the point, the numbers are — and a chain counter that stops IS
      // the stale signal. BG-8 is amended to seat it rather than worked
      // around. `DAA` is a word and takes Jakarta; the score is a figure and
      // takes mono (BG-30).
      // The label and the figure are two runs now (render `S1`: `DAA` as a
      // caps label, the score in 16 dp mono beside it, D-261).
      expect(find.text('DAA'), findsOneWidget);
      expect(find.text('2,000'), findsOneWidget);
      // The fiat slot rendering the honest unknown.
      expect(find.text('≈ —'), findsOneWidget);
      expect(find.text('no rate yet'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a price renders beside the figure, and says nothing else', (
      tester,
    ) async {
      // UX-3 built the source control, which is what let this stop rendering
      // a placeholder. The disclosure conditions were narrowed twice (D-193,
      // D-189): the source is named where the source is CHOSEN, and the age
      // appears only when age matters — so a fresh price is a bare figure.
      await pump(
        tester,
        money(
          mature: BigInt.from(128450270000),
          quote: KvRateQuote(
            usdPerKas: 0.02864504,
            fetchedAt: t0,
            source: 'https://api.kaspa.org/info/price',
          ),
          now: t0,
        ),
      );
      expect(find.text('≈ \$36.79'), findsOneWidget);
      expect(find.text('≈ —'), findsNothing);
      expect(find.text('no rate yet'), findsNothing);
      expect(
        find.textContaining('api.kaspa.org'),
        findsNothing,
        reason: 'a hostname beside a balance is disclosure nobody reads',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a price old enough to mislead wears its age', (tester) async {
      // The other half of `L126`: the test above drives the fresh branch, this
      // one drives the degraded branch, and neither alone would catch an age
      // that renders always or never.
      await pump(
        tester,
        money(
          mature: BigInt.from(128450270000),
          quote: KvRateQuote(
            usdPerKas: 0.02864504,
            fetchedAt: t0.subtract(RateService.staleAfter),
            source: 'https://api.kaspa.org/info/price',
          ),
          now: t0,
        ),
      );
      expect(find.text('≈ \$36.79'), findsOneWidget);
      expect(find.textContaining('old'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the age APPEARS as the price ages, with no new quote', (
      tester,
    ) async {
      // The transition, not the rendering. Every other assertion here builds a
      // widget that is already stale under a frozen clock, which proves the
      // branch paints and says nothing about whether it can ever be reached —
      // and it could not: the only thing that rebuilt this line was a fresh
      // quote, and a fresh quote resets the age to zero, so a vendor that went
      // down rendered a confident figure, ageless, forever
      // (`consensus-auditor`; `L126` in its purest form).
      var wall = t0;
      await pump(
        tester,
        money(
          mature: BigInt.from(128450270000),
          quote: KvRateQuote(
            usdPerKas: 0.02864504,
            fetchedAt: t0,
            source: 'https://api.kaspa.org/info/price',
          ),
          now: t0,
          clock: () => wall,
        ),
      );
      expect(find.text('≈ \$36.79'), findsOneWidget);
      expect(
        find.textContaining('old'),
        findsNothing,
        reason: 'a fresh rate says nothing about its age',
      );

      // Nothing new arrives. Only time passes, on the screen's own 1 s clock.
      wall = t0.add(RateService.staleAfter);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('≈ \$36.79'), findsOneWidget);
      expect(
        find.textContaining('old'),
        findsOneWidget,
        reason: 'a price old enough to mislead says how old, unprompted',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('switched off, the line is GONE — not a dash', (tester) async {
      // A user who turned fiat off did not ask for a row explaining that they
      // turned fiat off. `—` means *unknown datum* (BG-8), and a setting the
      // user chose is not an unknown.
      await pump(
        tester,
        money(mature: BigInt.from(128450270000), rateOn: false),
      );
      expect(find.text('≈ —'), findsNothing);
      expect(find.textContaining('≈'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('before the posture is read, the line is absent entirely', (
      tester,
    ) async {
      // Not `≈ —`: a dash means *unknown datum* (BG-8), and at this moment the
      // unknown is our own setting, not the price. A user who had switched
      // fiat off would otherwise watch a fiat line appear and leave on every
      // launch (`wallet-security-auditor`).
      await pump(
        tester,
        money(mature: BigInt.from(128450270000), rateOn: null),
      );
      expect(find.textContaining('≈'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an unknown balance restates as an unknown value', (
      tester,
    ) async {
      // Never `≈ \$0.00` under a hero reading `—`: a confident zero beside a
      // dash is a true-looking lie, which is the class BG-8 exists to stop.
      await pump(
        tester,
        money(
          mature: null,
          quote: KvRateQuote(
            usdPerKas: 0.02864504,
            fetchedAt: t0,
            source: 'https://api.kaspa.org/info/price',
          ),
          now: t0,
        ),
      );
      expect(find.text('≈ —'), findsOneWidget);
      expect(find.textContaining('0.00'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('syncing: the trust line speaks and the meter runs', (
      tester,
    ) async {
      await pump(tester, money(mature: BigInt.zero, syncing: true));
      expect(find.text('syncing…'), findsOneWidget);
      expect(
        tester.widget<KvCadence>(find.byType(KvCadence)).running,
        isTrue,
        reason: 'a first scan IS something happening',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('in flight: a memo beside the number, never a second sign', (
      tester,
    ) async {
      // 100 KAS held, 30 of it already spent and travelling. At the pin the
      // hero is ALREADY net of the send, so a `−` here would invite 70 − 30.
      await pump(
        tester,
        money(
          mature: BigInt.from(7000000000),
          outgoing: BigInt.from(3000000000),
        ),
      );
      expect(findCapsLabel('in flight'), findsOneWidget);
      expect(find.text('70'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
      expect(
        find.textContaining('−'),
        findsNothing,
        reason: 'the hero has already had it subtracted',
      );
      // Unsigned AND colourless: `risk` would say this money is at risk, and
      // on a self-send frame it is travelling straight back to this wallet.
      expect(styleOf(tester, '30').color, KvColor.ink);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the plate keeps ONE height, whatever it has to say', (
      tester,
    ) async {
      // **The card must not resize under the thumb** (founder, device sitting
      // 2026-08-31). It used to grow a line the moment a deposit started
      // arriving and lose it again when the money matured, and lose another
      // when `syncing…` cleared a second after every cold open — so the
      // balance moved three times for events the user did not cause. This is
      // BG-24's rule applied to a card rather than to a tile, and it is the
      // same argument as Receive's reserved footprint.
      //
      // Written as a measurement of the RENDERED plate rather than of the
      // widgets inside it: a slot that reserves the right height by accident
      // passes for the right reason, and one that reserves it by a ghost
      // child would fail the finder assertions below.
      double plateHeight() => tester.getSize(find.byType(KvMoneyPlate)).height;

      await pump(tester, money(mature: BigInt.from(7000000000)));
      final quiet = plateHeight();
      expect(findCapsLabel('pending'), findsNothing);

      await pump(
        tester,
        money(mature: BigInt.from(7000000000), pending: BigInt.from(50000000)),
      );
      expect(findCapsLabel('pending'), findsOneWidget);
      expect(
        plateHeight(),
        quiet,
        reason: 'the plate grew when money started arriving',
      );

      await pump(
        tester,
        money(mature: BigInt.from(7000000000), outgoing: BigInt.from(50000000)),
      );
      expect(findCapsLabel('in flight'), findsOneWidget);
      expect(
        plateHeight(),
        quiet,
        reason: 'the in-flight memo shares the reserved slot',
      );

      // And the other half of the jump: the trust sentence clearing.
      await pump(tester, money(mature: BigInt.from(7000000000), syncing: true));
      final syncing = plateHeight();
      await pump(tester, money(mature: BigInt.from(7000000000)));
      expect(
        plateHeight(),
        syncing,
        reason: 'the plate shrank when the first scan finished',
      );

      // The reserved slot holds NOTHING when empty — no ghost child answering
      // finders or screen readers with money that is not being shown (the
      // `Visibility(maintainSize:)` trap, L121 / UX-5's duplicated `100`).
      expect(findCapsLabel('pending'), findsNothing);
      expect(findCapsLabel('in flight'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('pending is money ARRIVING — signed, green, and additive', (
      tester,
    ) async {
      await pump(
        tester,
        money(mature: BigInt.from(7000000000), pending: BigInt.from(50000000)),
      );
      expect(findCapsLabel('pending'), findsOneWidget);
      // `pending` is a set DISJOINT from `mature`, so unlike the in-flight
      // memo it really is a term the hero does not yet contain.
      // **BG-23 on the qualifier**, which is the likeliest sub-1 amount on the
      // screen: the leading `+0.` drops to the fraction's size and the weight
      // starts at the first digit that carries value. Since BG-7's reversal
      // the figure takes the direction's hue in **both** runs — it is one
      // object in one colour, and emphasis is the channel that separates them.
      expect(find.text('+0.'), findsOneWidget);
      // `50`, not `5`: `trimFraction` keeps a minimum of two digits.
      expect(find.text('50'), findsOneWidget);
      expect(styleOf(tester, '+0.').color, KvColor.ok);
      expect(styleOf(tester, '50').color, KvColor.ok);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('degraded: dimmed, aged, frozen — and no counter streams', (
      tester,
    ) async {
      await pump(
        tester,
        money(
          mature: BigInt.parse('128450270000'),
          connected: false,
          lastUpdate: t0.subtract(const Duration(minutes: 3)),
          activity: [
            received(
              sompi: BigInt.from(2400000000),
              at: t0.subtract(const Duration(seconds: 12)),
              maturity: MaturityState.pending,
            ),
          ],
        ),
      );

      // BG-8's whole demand: dimmed cached truth WITH a visible age.
      expect(find.text('as of 3 m ago'), findsOneWidget);
      expect(
        tester.widget<KvCadence>(find.byType(KvCadence)).running,
        isFalse,
        reason: 'nothing is happening, so nothing may look like it is',
      );
      expect(find.text('1,284'), findsOneWidget); // retained, never blanked

      // **The BALANCE dims; the ledger row does not** (BG-8 as amended,
      // D-257). The 45% multiply is a large-text device: measured on `plate`
      // it takes a 16 dp ledger amount to **3.03:1** and an 11 dp time to
      // **1.93** against BG-14's 4.5 — and BG-14 is one of §0's clauses that
      // do not bend. Only the balance figure is large enough to sit on the
      // 3.0 large-text bar, where the dim lands at 4.22.
      //
      // A row is also a *record*, not a live reading: it did not become less
      // true when the socket dropped. Its live parts — the depth counter and
      // the relative age — stop instead, which is what the amended BG-8 names
      // as the stale signal.
      expect(
        tester
            .widgetList<AnimatedOpacity>(
              find.ancestor(
                of: find.text('1,284'),
                matching: find.byType(AnimatedOpacity),
              ),
            )
            .map((o) => o.opacity),
        contains(KvFreshness.opacityStale),
        reason: 'the balance is large text and must still dim',
      );
      expect(
        tester
            .widgetList<Opacity>(
              find.ancestor(
                of: find.text('Received'),
                matching: find.byType(Opacity),
              ),
            )
            .where((o) => o.opacity == KvFreshness.opacityStale),
        isEmpty,
        reason:
            'a 16 dp amount dimmed to 45% is 3.03:1 — under AA, and a record '
            'does not go stale',
      );
      // A frozen last-known DAA must not tick at full presence.
      expect(find.textContaining('confirmations'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('one indicator, however many facts — most consequential first', (
      tester,
    ) async {
      // Two truths, two subjects: the completeness of the NUMBER, and the age
      // of the LINK. Neither may hide the other — but they were two stacked
      // amber lamps on one plate, which spends BG-2's cap saying "something is
      // amber" twice. One lamp now; the sentences queue under it, the one that
      // changes what the user believes they own first.
      await pump(
        tester,
        money(
          mature: BigInt.from(1000),
          utxoIndexMissing: true,
          connected: false,
          lastUpdate: t0.subtract(const Duration(minutes: 3)),
        ),
      );
      expect(
        find.text(
          'node has no UTXO index — retrying another node\nas of 3 m ago',
        ),
        findsOneWidget,
      );
      // Two lamps and no more: the chip's standing indicator, and the trust
      // line's one lamp carrying however many sentences it has. The caption
      // and the link never light separately.
      expect(find.byType(KvLamp), findsNWidgets(2));

      // The other ordering: a live link has nothing to add, so the number's
      // caption stands alone.
      await pump(
        tester,
        money(mature: BigInt.from(1000), discoveryIncomplete: true),
      );
      expect(
        find.text(
          'still checking your addresses — this may not be your whole balance',
        ),
        findsOneWidget,
      );
      expect(find.byType(KvLamp), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the ledger', () {
    testWidgets('direction rides four ways at once (BG-7)', (tester) async {
      await pump(
        tester,
        money(
          mature: BigInt.from(1000),
          activity: [
            received(
              sompi: BigInt.from(2400000000),
              at: t0.subtract(const Duration(seconds: 12)),
            ),
            sent(
              sompi: BigInt.from(1240000000),
              at: t0.subtract(const Duration(minutes: 1)),
            ),
          ],
        ),
      );

      // 1 · the word, 2 · the sign, 3 · the colour, 4 · the weight. Every one
      // of them survives greyscale, colour-blindness and a screen reader.
      //
      // **BG-7 reversed the colour channel in Deep V6.** UX-5 made the figure
      // neutral so a row read as a quantity first; on the tinted ground the
      // coloured figure is what makes the ledger scannable at arm's length —
      // the eye finds *what left* before it reads a digit. The cost BG-26
      // named (hue grading the size of money) is answered by weight instead:
      // incoming 700, outgoing 500. **A neutral ledger figure is now the
      // finding.** All four channels still stand; which object carries which
      // has swapped.
      expect(find.text('Received'), findsOneWidget);
      expect(find.text('+24'), findsOneWidget);
      expect(styleOf(tester, '+24').color, KvColor.ok);
      expect(styleOf(tester, '+24').fontWeight, FontWeight.w700);

      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('−12'), findsOneWidget);
      expect(styleOf(tester, '−12').color, KvColor.risk);
      expect(styleOf(tester, '−12').fontWeight, FontWeight.w500);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the pinned plate', () {
    /// The property the measured extent exists for: **the plate never sits on
    /// top of the ledger.** Asserted rather than the number itself, because a
    /// number is exactly the claim `L121` says goes stale.
    void expectNoOverlap(WidgetTester tester) {
      // Measured off the plate itself. Send · Receive left it for the foot
      // bar (D-261), so the plate's own bottom edge is the last thing in the
      // pinned band before the strip.
      final plateBottom = tester.getRect(find.byType(KvMoneyPlate)).bottom;
      final rowTop = tester.getRect(find.text('Received')).top;
      expect(
        plateBottom,
        lessThanOrEqualTo(rowTop),
        reason: 'the pinned header is shorter than the plate inside it',
      );
    }

    testWidgets('its extent TRACKS the plate, at every state and scale', (
      tester,
    ) async {
      // The bug this is written against: a stated extent is right on the day
      // it is written and wrong the first time the plate grows a line. So the
      // same screen is grown twice — by content, then by text scale — and the
      // header has to keep up both times.
      final rows = [
        received(
          sompi: BigInt.from(2400000000),
          at: t0.subtract(const Duration(seconds: 12)),
        ),
      ];
      await pump(tester, money(mature: BigInt.from(1000), activity: rows));
      expectNoOverlap(tester);
      final lean = tester.getRect(find.text('Received')).top;

      // Grow it by content: a pending line, an in-flight line and a caption
      // the settled plate never draws.
      await pump(
        tester,
        money(
          mature: BigInt.from(1000),
          pending: BigInt.from(50000000),
          outgoing: BigInt.from(3000000000),
          discoveryIncomplete: true,
          connected: false,
          lastUpdate: t0.subtract(const Duration(minutes: 3)),
          activity: rows,
        ),
      );
      expectNoOverlap(tester);
      expect(
        tester.getRect(find.text('Received')).top,
        greaterThan(lean),
        reason: 'a taller plate must actually push the ledger down',
      );

      // Grow it by text scale, at the narrowest phone the app supports.
      await pump(
        tester,
        money(mature: BigInt.from(1000), activity: rows),
        width: 320,
        textScale: 1.3,
      );
      expectNoOverlap(tester);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('it never swallows the viewport, however tall it grows', (
      tester,
    ) async {
      // **The plate is fixed above the ledger card now** (D-262), and the
      // band it sits in is capped so the card always keeps its head and one
      // row: the band clips inside its cap rather than pushing the ledger
      // off the glass. 320x568 and 360x640 are real phones; 320x400 is a
      // phone in split-screen, and it is also `short` (BG-33), where the
      // plate is the 56 dp bar. Height is an input.
      for (final (w, h, short) in const [
        (320.0, 568.0, false),
        (360.0, 640.0, false),
        (320.0, 400.0, true),
      ]) {
        await pump(
          tester,
          money(
            mature: BigInt.parse('128450270000'),
            pending: BigInt.parse('128450270000'),
            outgoing: BigInt.parse('128450270000'),
            connected: false,
            utxoIndexMissing: true,
            lastUpdate: t0.subtract(const Duration(minutes: 3)),
            activity: [
              received(
                sompi: BigInt.from(2400000000),
                at: t0.subtract(const Duration(seconds: 12)),
              ),
            ],
          ),
          width: w,
          height: h,
          textScale: 1.3,
        );
        final where = '${w.toInt()}x${h.toInt()}';
        expect(tester.takeException(), isNull, reason: '$where overflowed');
        // **The one collapse there is** (BG-33): a `short` window trades the
        // plate for the 56 dp bar, and nothing else on the screen changes.
        expect(
          find.byType(KvMoneyBar),
          short ? findsOneWidget : findsNothing,
          reason:
              '$where: the money plate collapses in `short`, and only there',
        );
        expect(
          find.byType(KvMoneyPlate),
          short ? findsNothing : findsOneWidget,
          reason: where,
        );
        // The card keeps its head and its first row on the glass, whatever
        // the band above it wanted.
        expect(
          tester.getRect(find.byType(KvTabs)).bottom,
          lessThanOrEqualTo(h),
          reason: '$where: the tabs are on the glass',
        );
        expect(find.text('Received'), findsOneWidget, reason: where);
        expect(
          tester.getRect(find.text('Received')).bottom,
          lessThanOrEqualTo(h),
          reason: '$where: the first row is on the glass',
        );
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('pull-to-refresh works FROM the balance (D-194)', (
      tester,
    ) async {
      // The gesture is hosted by the whole scroll view rather than by the
      // list, so it works where a hand reaches for it first. A plate laid out
      // above the viewport would emit no scroll notification and the drag
      // would die on it.
      var pulls = 0;
      await pump(
        tester,
        money(
          mature: BigInt.from(1000),
          onRefresh: () async => pulls++,
          activity: [
            received(
              sompi: BigInt.from(2400000000),
              at: t0.subtract(const Duration(seconds: 12)),
            ),
          ],
        ),
      );

      await tester.drag(
        findCapsLabel('Available balance'),
        const Offset(0, 320),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(pulls, 1, reason: 'the drag started ON the balance');

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the laws that outrank the composition', () {
    /// BG-2 counts **emitting objects**, not hexes: the five-bar cadence is
    /// one, not five, and `primaryMuted` is ambient and free (§1.5).
    ///
    /// **The cap counts TEAL emitters**, which is what the law it comes from
    /// actually says: BG-2 is titled *"Teal is light, not paint"* and §1.5
    /// spells it out — *"`primary` is light: it emits, it is capped at three
    /// per screen"*. A lamp is `ok`/`warn`/`risk` and never `primary`, so it
    /// is not what the teal budget is rationing.
    ///
    /// This is a **narrowing recorded on 2026-08-27**, not an accident. An
    /// earlier pass in this sitting counted lamps too and, on that reading, the
    /// money plate's compound states ran to four — which is what removed the
    /// network chip's lamp. The founder restored the lamp on glass, and the
    /// honest way to hold both is to say which budget governs which object:
    /// teal is rationed by count, and lamps are rationed by **not being
    /// redundant** — asserted separately below.
    ///
    /// `TxStatusChip`'s dots are outside both: §1.5 defines a lamp as a 6dp dot
    /// **under an 8dp blur**, and that dot has no `boxShadow`.
    int tealEmissions(WidgetTester tester) {
      var n = find.byType(KvCadence).evaluate().length;
      for (final c in tester.widgetList<Container>(find.byType(Container))) {
        final d = c.decoration;
        if (d is BoxDecoration && d.color == KvColor.primary) n++;
      }
      return n;
    }

    testWidgets('teal never exceeds three emissions, in any state', (
      tester,
    ) async {
      for (final (label, app) in <(String, Widget)>[
        ('empty', money(mature: BigInt.zero)),
        (
          'live',
          money(
            mature: BigInt.parse('128450270000'),
            activity: [received(sompi: BigInt.from(1), at: t0)],
          ),
        ),
        ('syncing', money(mature: BigInt.zero, syncing: true)),
        (
          'in flight',
          money(
            mature: BigInt.from(7000000000),
            outgoing: BigInt.from(3000000000),
          ),
        ),
        (
          'degraded',
          money(
            mature: BigInt.from(1000),
            connected: false,
            lastUpdate: t0.subtract(const Duration(minutes: 3)),
          ),
        ),
        // The two flags that used to add a third lamp — the worst case, and
        // the one the old counter could not see.
        (
          'degraded + no UTXO index',
          money(
            mature: BigInt.from(1000),
            connected: false,
            utxoIndexMissing: true,
            lastUpdate: t0.subtract(const Duration(minutes: 3)),
          ),
        ),
        (
          'syncing + discovery incomplete',
          money(mature: BigInt.zero, syncing: true, discoveryIncomplete: true),
        ),
      ]) {
        await pump(tester, app);
        expect(tealEmissions(tester), lessThanOrEqualTo(3), reason: label);
        // Lamps are rationed by non-redundancy rather than by count: at most
        // the chip's standing indicator plus ONE trust lamp carrying however
        // many sentences it has. Three would mean two lamps saying the same
        // thing, which is the P0.3 shape.
        expect(
          find.byType(KvLamp).evaluate().length,
          lessThanOrEqualTo(2),
          reason: '$label: a third lamp is a second opinion',
        );
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('every state survives 1.3x text scale at 320dp (BG-14)', (
      tester,
    ) async {
      // The widest row the ledger can produce: the longest title
      // (`Consolidated`), the longest lifecycle label (`Not accepted yet`) and
      // an eight-decimal four-figure amount, all at once.
      final rows = [
        received(
          sompi: BigInt.parse('128450270000'),
          at: t0.subtract(const Duration(seconds: 12)),
          maturity: MaturityState.pending,
        ),
        sent(
          sompi: BigInt.parse('128450270000'),
          at: t0.subtract(const Duration(minutes: 1)),
          stalled: true,
        ),
        merged(
          sompi: BigInt.parse('128450270000'),
          at: t0.subtract(const Duration(hours: 2)),
        ),
      ];
      for (final (label, app) in <(String, Widget)>[
        ('empty', money(mature: BigInt.zero)),
        ('live', money(mature: BigInt.parse('128450270000'), activity: rows)),
        ('syncing', money(mature: BigInt.zero, syncing: true, activity: rows)),
        (
          'in flight',
          money(
            mature: BigInt.parse('128450270000'),
            pending: BigInt.parse('128450270000'),
            outgoing: BigInt.parse('128450270000'),
            activity: rows,
          ),
        ),
        (
          'degraded',
          money(
            mature: BigInt.parse('128450270000'),
            connected: false,
            utxoIndexMissing: true,
            lastUpdate: t0.subtract(const Duration(minutes: 3)),
            activity: rows,
          ),
        ),
      ]) {
        await pump(tester, app, width: 320, textScale: 1.3);
        expect(
          tester.takeException(),
          isNull,
          reason: '$label overflowed at 320dp / 1.3x',
        );
        await tester.pumpWidget(const SizedBox());
      }
    });
  });
}
