import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_burial_gauge.dart';
import 'package:kaspaverse/src/ui/widgets/kv_burial_mark.dart';
import 'package:kaspaverse/src/ui/widgets/kv_status_chip.dart';

import 'support/maturity.dart';
import 'support/preview_harness.dart';

/// **The burial ladder under BG-21 and BG-22**, rebuilt at UX-R3 on D-248's
/// ratified vocabulary (`Pending · Accepted · Settled`) with D-249's thresholds
/// crossing the FFI instead of being typed here.
///
/// Every assertion measures the **ink** rather than an argument the code handed
/// the canvas. That distinction is L145, and it is the scar the canon session
/// produced about its own first guard: the sign ring's guard recorded
/// `drawArc`'s `sweepAngle` parameter and was structurally blind to a
/// `StrokeCap.round` painting 4.21% of the circle past every reading. So [_Ink]
/// below replays the real painter onto a spy canvas and reconstructs what the
/// eye would cover — rectangles by their bounds, strokes by their length plus
/// whatever their cap adds — and the painter is deliberately given **the depth
/// and the ceiling** rather than a pre-computed fraction, so there is no
/// intermediate number for a test to confirm instead of the drawing.
void main() {
  setUpAll(loadBundledFonts);

  group('D-249 · the thresholds are READ, never remembered', () {
    test('no threshold literal survives anywhere in lib/', () {
      // **The acceptance criterion, as a guard.** D-249: *"UX-R3 must not
      // hardcode 100 or 1,000. Both live on the pinned side and cross the FFI
      // from `NetworkParams::from(network_id)`."* The shipped ladder carried
      // `safe = 100` / `settled = 1000` as constants and was right by accident
      // — they are wallet-core's **mainnet** pair, while `10 / 100` is its
      // **devnet** pair, so a re-pin or a different network would have left the
      // glass quoting numbers the balance no longer used.
      //
      // Searched as a declaration, not as the digits: `100` appears legitimately
      // as a percentage, a duration and a mass all over the tree. What must not
      // exist is a *named threshold* holding one.
      final offenders = <String>[];
      final pattern = RegExp(
        r'(safe|settled|maturity|threshold|confirmations?|depth)\w*\s*=\s*'
        r'(100|1000|1_000)\b',
        caseSensitive: false,
      );
      for (final file in Directory('lib').listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        if (_exempt(file.path)) continue;
        for (final (i, line) in file.readAsLinesSync().indexed) {
          if (line.trimLeft().startsWith('//')) continue;
          if (pattern.hasMatch(line)) {
            offenders.add('${file.path}:${i + 1}  ${line.trim()}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'a maturity threshold is typed into lib/ instead of crossing the '
            'FFI from NetworkParams (D-249):\n${offenders.join('\n')}',
      );
    });

    test('the ceiling branches on is_coinbase', () {
      // D-249's last finding, which the shipped `rungFor` never read: a
      // coinbase matures at `coinbase_transaction_maturity_period_daa`, not at
      // the user period. At 150 it rendered green and settled while wallet-core
      // still called it Pending and the balance excluded it — one row, two
      // answers, and the wrong one was the reassuring one.
      expect(kTestMaturity.ceilingFor(coinbase: false), kTestMaturity.userDaa);
      expect(
        kTestMaturity.ceilingFor(coinbase: true),
        kTestMaturity.coinbaseDaa,
      );
      expect(kTestMaturity.coinbaseDaa, greaterThan(kTestMaturity.userDaa));
    });

    test('the whole scale moves when the pin hands it different numbers', () {
      // The falsification of "read, not remembered". `10 / 100` is verbatim
      // wallet-core's **devnet** pair, so a ladder that still lands `Settled`
      // at 100 under these thresholds is one that ignored what it was given.
      final ceiling = kTestDevnetMaturity.ceilingFor(coinbase: false);
      expect(ceiling, 10);
      expect(KvBurialGauge.positionFor(5, ceiling), closeTo(0.5, 1e-12));
      expect(KvBurialGauge.positionFor(10, ceiling), 1);
      expect(
        KvBurial.rungFor(
          10,
          MaturityState.confirmed,
          stalled: false,
          direction: ActivityDirection.outgoing,
          isCoinbase: false,
          thresholds: kTestDevnetMaturity,
        ),
        KvBurialRung.settled,
      );
      // …and the same depth is only halfway up the mainnet track.
      expect(
        KvBurial.rungFor(
          10,
          MaturityState.confirmed,
          stalled: false,
          direction: ActivityDirection.outgoing,
          isCoinbase: false,
          thresholds: kTestMaturity,
        ),
        KvBurialRung.accepted,
      );
    });

    testWidgets('a coinbase at 150 is NOT settled — the shipped defect', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          KvBurialGauge(
            stalled: false,
            confirmations: 150,
            maturity: MaturityState.confirmed,
            direction: ActivityDirection.incoming,
            isCoinbase: true,
            thresholds: kTestMaturity,
          ),
        ),
      );
      await tester.pump();
      expect(
        _Ink.of(tester).filledFraction,
        closeTo(150 / kTestMaturity.coinbaseDaa, 0.002),
        reason:
            'a coinbase 150 deep is still Pending at the pin and excluded from '
            'the balance — a gauge that does not branch would show it full '
            '(D-249)',
      );
      expect(
        _dotHue(tester),
        isNot(KvColor.ok),
        reason: 'the rung must not claim spendable either',
      );
      // The same depth on an ordinary payment is over the line.
      await tester.pumpWidget(
        _host(
          KvBurialGauge(
            key: const ValueKey('user'),
            stalled: false,
            confirmations: 150,
            maturity: MaturityState.confirmed,
            direction: ActivityDirection.incoming,
            isCoinbase: false,
            thresholds: kTestMaturity,
          ),
        ),
      );
      await tester.pump();
      expect(_Ink.of(tester).filledFraction, closeTo(1, 0.002));
      expect(_dotHue(tester), KvColor.ok);
    });
  });

  group('BG-22 · the declared scale is linear', () {
    test('it is a straight line from the origin to the ceiling', () {
      // D-248 replaced the log/piecewise ruler with one decade drawn linearly,
      // and D-249 gave it an honest referent: progress **inside** the Accepted
      // rung toward spendable, which is a real quantity the wallet reads every
      // second.
      const ceiling = 100;
      for (final d in const [0, 1, 25, 50, 75, 99, 100]) {
        expect(
          KvBurialGauge.positionFor(d, ceiling),
          closeTo(d / ceiling, 1e-12),
          reason: 'depth $d is not where a linear scale puts it',
        );
      }
    });

    test('it is monotone and never runs past its ceiling', () {
      var previous = -1.0;
      for (final n in const [0, 1, 2, 49, 50, 51, 99, 100, 101, 5000]) {
        final x = KvBurialGauge.positionFor(n, 100);
        expect(x, greaterThanOrEqualTo(previous), reason: 'depth $n went back');
        previous = x;
      }
      expect(KvBurialGauge.positionFor(99, 100), lessThan(1));
      expect(KvBurialGauge.positionFor(100, 100), 1);
      expect(KvBurialGauge.positionFor(100000, 100), 1);
      expect(KvBurialGauge.positionFor(0, 100), 0);
      expect(KvBurialGauge.positionFor(-5, 100), 0);
    });

    test('the tick hierarchy is §4\'s: 21 marks in three lengths', () {
      // §4: **21 ticks** — 12 dp at 0 · 50 · 100, 8 dp every 10, 5 dp every 5.
      // `S9` measured its own majors at 0 %, 50 % and 100 % of the track, so
      // the render and the law agree here and neither had to be assumed.
      expect(KvBurialGauge.subDivisions, 20, reason: '21 marks = 20 steps');
      final lengths = [
        for (var s = 0; s <= KvBurialGauge.subDivisions; s++)
          KvBurialGaugePainter.tickLength(s),
      ];
      expect(lengths, hasLength(21));
      expect(lengths.first, KvBurialGaugePainter.majorTick);
      expect(lengths.last, KvBurialGaugePainter.majorTick);
      expect(
        lengths[10],
        KvBurialGaugePainter.majorTick,
        reason: 'the 50 mark',
      );
      // A step is 5 % of the ceiling, so an even step is a tenth and an odd
      // one is a fifth.
      expect(lengths[2], KvBurialGaugePainter.tenTick, reason: 'every tenth');
      expect(lengths[1], KvBurialGaugePainter.fiveTick, reason: 'every fifth');
      expect(
        lengths.where((l) => l == KvBurialGaugePainter.majorTick).length,
        3,
        reason:
            '§4 seats exactly three tall marks: 0, the midpoint, the ceiling',
      );
      expect(
        KvBurialGaugePainter.fiveTick,
        lessThan(KvBurialGaugePainter.tenTick),
      );
      expect(
        KvBurialGaugePainter.tenTick,
        lessThan(KvBurialGaugePainter.majorTick),
      );
    });
  });

  group('BG-22 · the ink is the reading', () {
    testWidgets('the painted fill IS the declared position, at every step', (
      tester,
    ) async {
      for (final depth in const [0, 1, 5, 25, 50, 99, 100, 340]) {
        await tester.pumpWidget(_host(_gauge(depth, key: ValueKey(depth))));
        // A fresh gauge snaps to its first reading, so one pump settles it.
        await tester.pump();
        final ink = _Ink.of(tester);
        final declared = KvBurialGauge.positionFor(
          depth,
          kTestMaturity.userDaa,
        );
        expect(
          ink.filledFraction,
          closeTo(declared, 0.002),
          reason:
              'at $depth DAA the gauge covers '
              '${(ink.filledFraction * 100).toStringAsFixed(1)}% of the track '
              'where the declared scale says '
              '${(declared * 100).toStringAsFixed(1)}%',
        );
      }
    });

    testWidgets('the ticks the reading has passed take its hue (`S9`)', (
      tester,
    ) async {
      // `S9` draws every graduation of its full track in the fill's own green
      // ((125,213,132) at five sampled ticks). Under the reading the ticks are
      // lit; past it they keep the machined tone — the same extent the fill
      // draws, so the ruler cannot state a second reading (BG-19).
      await tester.pumpWidget(_host(_gauge(42)));
      await tester.pump();
      final ink = _Ink.of(tester);
      final fillX = ink.filledFraction * ink._size.width;
      int rgb(Color c) => c.toARGB32() & 0x00FFFFFF;
      final ticks = ink.verticalTicks;
      final lit = ticks.where((t) => t.from.dx <= fillX).toList();
      final beyond = ticks.where((t) => t.from.dx > fillX).toList();
      // 42 % of twenty steps: the origin and the eight fives up to 40 %.
      expect(lit.length, 9);
      expect(beyond.length, 12);
      expect(lit.map((t) => rgb(t.colour)).toSet(), {rgb(KvColor.settled)});
      expect(beyond.map((t) => rgb(t.colour)).toSet(), {rgb(KvColor.inkDim)});
    });

    testWidgets('at zero deep no tick is lit, and past the ceiling all are', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_gauge(0)));
      await tester.pump();
      expect(_Ink.of(tester).tickTones, {KvColor.inkDim.toARGB32() & 0xFFFFFF});
      await tester.pumpWidget(_host(_gauge(340, key: const ValueKey(340))));
      await tester.pump();
      // Past the ceiling the reading wears the terminal rung's hue (D-248).
      expect(_Ink.of(tester).tickTones, {KvColor.ok.toARGB32() & 0xFFFFFF});
    });

    testWidgets('no stroke cap paints past any reading', (tester) async {
      await tester.pumpWidget(_host(_gauge(42)));
      await tester.pump();
      final ink = _Ink.of(tester);
      expect(ink.lines, isNotEmpty, reason: 'the ruler was never drawn');
      for (final line in ink.lines) {
        expect(
          line.cap,
          ui.StrokeCap.butt,
          reason:
              'a ${line.cap} cap paints half a stroke width past BOTH ends of '
              'every stroke on this gauge — a mark may overhang, a measurement '
              'may not (BG-22)',
        );
      }
    });

    testWidgets('nothing is filled for a depth nobody has', (tester) async {
      await tester.pumpWidget(
        _host(
          KvBurialGauge(
            stalled: false,
            confirmations: null,
            maturity: MaturityState.confirmed,
            direction: ActivityDirection.outgoing,
            isCoinbase: false,
            thresholds: kTestMaturity,
          ),
        ),
      );
      await tester.pump();
      expect(
        _Ink.of(tester).filledFraction,
        0,
        reason:
            'an extent drawn for an unknown quantity is a fabricated reading '
            '(BG-8); the reading line carries the dash instead',
      );
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('a stalled submit plots no depth', (tester) async {
      await tester.pumpWidget(
        _host(
          KvBurialGauge(
            stalled: true,
            // A stalled submit has no acceptance score, so no depth — the
            // fixture that gave it 40 built a world production cannot
            // produce (`consensus-auditor` item 26).
            confirmations: null,
            maturity: MaturityState.pending,
            direction: ActivityDirection.outgoing,
            isCoinbase: false,
            thresholds: kTestMaturity,
          ),
        ),
      );
      await tester.pump();
      expect(_Ink.of(tester).filledFraction, 0);
      expect(_reading('Not accepted yet'), findsNothing);
      expect(
        KvBurial.rungWord(KvBurialRung.stalled),
        'Not accepted yet',
        reason: 'the stall keeps its own sentence, carried by the chip',
      );
    });
  });

  group('BG-22 · a gauge is never eased, in either direction', () {
    testWidgets('the ink tracks the streamed reading frame by frame', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_gauge(20)));
      await tester.pump();
      // The readings arrive a poll apart: the tween crosses the observed
      // gap, so a second reading in the same frame would cross in 100 ms.
      await tester.pump(KvMotion.stream);
      // A second reading arrives: the count replays the interval between two
      // observations, linearly, and the gauge is drawn at whatever integer the
      // replay is on. Both readings sit inside the `Accepted` rung, where the
      // reading line prints the count — so the ink has something independent of
      // the painter to be checked against.
      await tester.pumpWidget(_host(_gauge(95)));
      await tester.pump();

      var moved = 0;
      var previous = _Ink.of(tester).filledFraction;
      for (var step = 0; step < 8; step++) {
        await tester.pump(const Duration(milliseconds: 100));
        final ink = _Ink.of(tester);
        // **The reading is read off the printed number, not off the painter.**
        // The two registers are built from one value inside one builder; if the
        // ink and the printed number ever disagree, one of them is lying.
        final shown = _shownDepth(tester);
        expect(
          ink.filledFraction,
          closeTo(
            KvBurialGauge.positionFor(shown, kTestMaturity.userDaa),
            0.003,
          ),
          reason:
              'the gauge reads ${(ink.filledFraction * 100).toStringAsFixed(1)}%'
              ' while the line beside it says $shown',
        );
        if ((ink.filledFraction - previous).abs() > 1e-9) moved++;
        previous = ink.filledFraction;
      }
      expect(
        moved,
        greaterThan(2),
        reason:
            'an extent may not be pinned while its quantity moves (BG-22) — '
            'the fill never changed while the count climbed 20 → 95',
      );
      await tester.pumpAndSettle();
    });

    testWidgets('a fall snaps rather than sliding backwards', (tester) async {
      await tester.pumpWidget(_host(_gauge(80)));
      await tester.pump();
      expect(
        _Ink.of(tester).filledFraction,
        closeTo(KvBurialGauge.positionFor(80, kTestMaturity.userDaa), 0.002),
      );
      // A reorg, or a depth reading arriving over a maturity flag. BG-18 says
      // a decrease snaps; a gauge that slid back would animate burial being
      // undone.
      await tester.pumpWidget(_host(_gauge(20)));
      await tester.pump();
      expect(
        _Ink.of(tester).filledFraction,
        closeTo(KvBurialGauge.positionFor(20, kTestMaturity.userDaa), 0.002),
        reason: 'the fall must be on the new reading in one frame',
      );
    });

    testWidgets('reduced animations do not leave the gauge full', (
      tester,
    ) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      expect(SemanticsBinding.instance.disableAnimations, isTrue);

      await tester.pumpWidget(_host(_gauge(4)));
      await tester.pump();
      expect(
        _Ink.of(tester).filledFraction,
        closeTo(KvBurialGauge.positionFor(4, kTestMaturity.userDaa), 0.002),
        reason:
            'the sign ring drew a COMPLETE circle under this flag with only '
            'its opacity carrying the reading (D-229) — the extent half of the '
            'same exception is the one that reads as closed',
      );
      await tester.pumpAndSettle();
    });
  });

  group('BG-20 · an unread scale does not look like a measured zero', () {
    testWidgets('the ink differs between "0 deep" and "no reading"', (
      tester,
    ) async {
      // With the `0` origin labelled, an empty track reads as a measurement AT
      // zero. Both states fill nothing, so the graphic asserted the stronger of
      // the two for a reading nobody has (`consensus-auditor`, UX-5). The
      // printed value already differs — `0` against `—` — and the ink does too.
      await tester.pumpWidget(_host(_gauge(0, key: const ValueKey('zero'))));
      await tester.pump();
      expect(find.text('0'), findsWidgets);
      final measured = _Ink.of(tester).tickTones;

      await tester.pumpWidget(
        _host(
          KvBurialGauge(
            key: const ValueKey('unknown'),
            stalled: false,
            confirmations: null,
            maturity: MaturityState.confirmed,
            direction: ActivityDirection.outgoing,
            isCoinbase: false,
            thresholds: kTestMaturity,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('—'), findsOneWidget);
      final unread = _Ink.of(tester).tickTones;

      expect(measured, isNotEmpty);
      expect(
        unread,
        isNot(measured),
        reason:
            'an empty track at a live zero and an empty track at an unknown '
            'depth painted the same pixels',
      );
      // Neither is filled — the difference is in the scale, not in a fabricated
      // extent (BG-22 is untouched).
      expect(_Ink.of(tester).filledFraction, 0);
    });
  });

  group('BG-21 · one vocabulary, and it is the bridge\'s own', () {
    test('the words are Pending · Accepted · Settled', () {
      // D-248, transcribed rather than improved: *"we will remove seen,
      // confirmed and final. and make it only Pending, Accepted, and Settled"*.
      expect(KvBurial.rungWord(KvBurialRung.pending), 'Pending');
      expect(KvBurial.rungWord(KvBurialRung.accepted), 'Accepted');
      expect(KvBurial.rungWord(KvBurialRung.settled), 'Settled');
      // The measurement form composes from the bare word, so a chip and a
      // gauge can never disagree about what a rung is called.
      expect(KvBurial.words(KvBurialRung.accepted, depth: null), 'Accepted —');
      expect(KvBurial.words(KvBurialRung.accepted, depth: 7), 'Accepted 7');
      expect(KvBurial.words(KvBurialRung.settled), 'Settled');
      // §9.17's case question, closed: the terminal word is capitalised like
      // its siblings. `final` was lowercase because it read as an adjective;
      // `Settled` is a rung name and rung names are capitalised.
      expect(KvBurial.rungWord(KvBurialRung.settled), startsWith('S'));
    });

    test('the retired words are gone from every call site', () {
      // BG-21's waiver named this sitting as its trigger, and half a migration
      // is what the law forbids: two vocabularies on one fact, with the seam
      // sitting exactly where a user checks whether their money is safe.
      final offenders = <String>[];
      final retired = RegExp(
        r"""['"](Seen|Settling|Confirmed|final)( —| \$?\w+)?['"]""",
      );
      for (final file in Directory('lib').listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        if (_exempt(file.path)) continue;
        for (final (i, line) in file.readAsLinesSync().indexed) {
          final code = line.trimLeft();
          // Prose about the migration is not a call site.
          if (code.startsWith('//') || code.startsWith('///')) continue;
          if (retired.hasMatch(line)) {
            offenders.add('${file.path}:${i + 1}  ${line.trim()}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'a retired lifecycle word still reaches the glass (BG-21, '
            'D-248):\n${offenders.join('\n')}',
      );
    });

    test('the rung reads the DIRECTION, because one flag means two things', () {
      // D-249 correction (a). For a **spend**, `wallet_sync.rs` derives
      // `Confirmed` from `accepted_daa_score.is_some()` — accepted at depth 0,
      // not settled. For a **receive** it derives from `record.maturity(daa)`,
      // so `Pending` means *on chain and under the maturity period*, never in a
      // mempool. Read without the direction, an incoming deposit wore an amber
      // `Pending` chip for its first ten seconds while it was already accepted.
      KvBurialRung rung(ActivityDirection d, MaturityState m, {int? depth}) =>
          KvBurial.rungFor(
            depth,
            m,
            stalled: false,
            direction: d,
            isCoinbase: false,
            thresholds: kTestMaturity,
          );

      // A receive under the maturity period is ON CHAIN — never `Pending`.
      expect(
        rung(ActivityDirection.incoming, MaturityState.pending),
        KvBurialRung.accepted,
      );
      // A spend the DAG has not accepted is the one true `Pending`.
      expect(
        rung(ActivityDirection.outgoing, MaturityState.pending),
        KvBurialRung.pending,
      );
      // A spend the DAG HAS accepted, with no depth to be read, is `Accepted —`
      // rather than the terminal word: the depth is what earns that.
      expect(
        rung(ActivityDirection.outgoing, MaturityState.confirmed),
        KvBurialRung.accepted,
      );
      // A receive the library itself calls mature is settled on its word.
      expect(
        rung(ActivityDirection.incoming, MaturityState.confirmed),
        KvBurialRung.settled,
      );
    });

    test('the chain\'s acceptance outranks the tracker\'s stall', () {
      // The stall is a verdict on an absence the tracker's own deaf lane can
      // manufacture; `Confirmed` is wallet-core's persisted acceptance. A row
      // the screen is counting the burial of must never read "Not accepted
      // yet" (`consensus-auditor`, UX-R3 second beat).
      KvBurialRung rung(MaturityState m, {int? depth}) => KvBurial.rungFor(
        depth,
        m,
        stalled: true,
        direction: ActivityDirection.outgoing,
        isCoinbase: false,
        thresholds: kTestMaturity,
      );
      expect(rung(MaturityState.confirmed, depth: 42), KvBurialRung.accepted);
      expect(rung(MaturityState.confirmed, depth: 420), KvBurialRung.settled);
      expect(rung(MaturityState.pending), KvBurialRung.stalled);
      expect(rung(MaturityState.unknown), KvBurialRung.stalled);
    });

    test('a computable depth outranks a stale Pending flag on a spend', () {
      // The two inputs cannot honestly disagree — `depthOf` anchors a spend on
      // `acceptedDaaScore` and `wallet_sync.rs` derives its maturity from the
      // same field — so when they do, the raw score wins over the projection.
      expect(
        KvBurial.rungFor(
          42,
          MaturityState.pending,
          stalled: false,
          direction: ActivityDirection.outgoing,
          isCoinbase: false,
          thresholds: kTestMaturity,
        ),
        KvBurialRung.accepted,
        reason:
            'a screen actively counting a spend\'s burial must not print '
            'Pending over it',
      );
    });

    test('the mark and the gauge read one implementation of the ladder', () {
      // BG-21: two registers, one law. If these ever diverge, the ledger row
      // and the detail screen are two widgets disagreeing about one number.
      for (final rung in KvBurialRung.values) {
        expect(KvBurial.hueFor(rung), isNotNull);
        expect(KvBurial.tintFor(rung), isNotNull);
        expect(KvBurial.rungWord(rung), isNotEmpty);
      }
      // D-248 seats `settled` as a fourth value hue and spends it in exactly
      // one place: the terminal rung. It is never a general status, which is
      // why it is a colour here and not a fourth `KvLampTone`.
      expect(KvBurial.hueFor(KvBurialRung.settled), KvColor.ok);
      expect(KvBurial.hueFor(KvBurialRung.accepted), KvColor.settled);
      expect(KvBurial.hueFor(KvBurialRung.pending), KvColor.warn);
    });
  });

  group('BG-24 · the crossings are accounted for', () {
    testWidgets('the word flips in the same frame the fill crosses the mark', (
      tester,
    ) async {
      // **The coherence property, and it is why the rung is derived from the
      // DRAWN depth.** It used to come from the newest reading, so a poll
      // arriving at 150 over a wallet showing 99 printed the terminal word
      // immediately and left the bar below the ceiling for the rest of the
      // second — the word and the extent disagreeing about which side of the
      // threshold the money was on, on the surface built to answer exactly
      // that question.
      await tester.pumpWidget(_host(_gauge(60)));
      await tester.pump();
      await tester.pumpWidget(_host(_gauge(400)));
      await tester.pump();

      // **Measured as ink against the PRINTED number**, not against a tween's
      // current colour: the dot crossfades through intermediate hues by design
      // (BG-24), and a guard that keyed on the exact end colour would be
      // testing the animation rather than the coherence.
      var sawUnder = false;
      var sawOver = false;
      for (var step = 0; step < 14; step++) {
        final fill = _Ink.of(tester).filledFraction;
        final shown = _shownDepth(tester);
        if (shown >= kTestMaturity.userDaa) {
          sawOver = true;
          expect(
            fill,
            greaterThanOrEqualTo(1 - 1e-6),
            reason:
                'the line says $shown — past the ceiling — while the bar is '
                'still short of it',
          );
        } else {
          sawUnder = true;
          expect(
            fill,
            lessThan(1),
            reason: 'the bar is full while the line still says $shown',
          );
        }
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(sawUnder && sawOver, isTrue, reason: 'the crossing never ran');
      // And when it has settled, the dot is the fourth hue D-248 seated.
      await tester.pumpAndSettle();
      expect(_dotHue(tester), KvColor.ok);
    });
  });

  group('the depth arithmetic — one implementation, three lanes', () {
    ActivityRecord row(
      ActivityDirection direction, {
      BigInt? accepted,
      int block = 1000,
    }) => ActivityRecord(
      txid: 'a' * 64,
      valueSompi: BigInt.from(1),
      blockDaaScore: BigInt.from(block),
      acceptedDaaScore: accepted,
      direction: direction,
      isCoinbase: false,
      maturity: MaturityState.pending,
      stalled: false,
    );

    final tip = BigInt.from(3500);

    test('a deposit counts from its own inclusion score', () {
      expect(
        KvBurial.depthOf(row(ActivityDirection.incoming), tip, stale: false),
        2500,
      );
    });

    test('a send counts from DAG acceptance, never from submit time', () {
      expect(
        KvBurial.depthOf(
          row(ActivityDirection.outgoing, accepted: BigInt.from(3000)),
          tip,
          stale: false,
        ),
        500,
      );
      expect(
        KvBurial.depthOf(row(ActivityDirection.outgoing), tip, stale: false),
        isNull,
        reason: 'a send the DAG has not accepted has no depth at all',
      );
    });

    test('a chained-send leg is a spend and counts like one', () {
      // `ActivityDirection.change` is `TransactionData::Batch` — the
      // compounding leg of a >100k-mass chained send — and Rust surfaces its
      // `accepted_daa_score` exactly as it does for a payment. Anchored on
      // `blockDaaScore` instead, a leg the DAG never accepted accrued 2,500
      // blocks of burial off the wall clock and the gauge rendered the terminal
      // word over a Pending record (`consensus-auditor`, UX-5).
      expect(
        KvBurial.depthOf(row(ActivityDirection.change), tip, stale: false),
        isNull,
      );
      expect(
        KvBurial.depthOf(
          row(ActivityDirection.change, accepted: BigInt.from(3400)),
          tip,
          stale: false,
        ),
        100,
      );
    });

    test('a stale link never counts, whatever the lane', () {
      for (final d in ActivityDirection.values) {
        expect(
          KvBurial.depthOf(
            row(d, accepted: BigInt.from(3000)),
            tip,
            stale: true,
          ),
          isNull,
        );
      }
    });

    testWidgets('the gauge claims nothing on a never-accepted leg', (
      tester,
    ) async {
      // The end-to-end shape of the same defect: the words and the fill both
      // asserted the terminal rung over a record wallet-core calls Pending.
      final record = row(ActivityDirection.change);
      final depth = KvBurial.depthOf(record, tip, stale: false);
      await tester.pumpWidget(
        _host(
          KvBurialGauge(
            stalled: false,
            confirmations: depth,
            maturity: record.maturity,
            direction: record.direction,
            isCoinbase: record.isCoinbase,
            thresholds: kTestMaturity,
          ),
        ),
      );
      await tester.pump();
      expect(_Ink.of(tester).filledFraction, 0);
      expect(find.text('—'), findsOneWidget);
    });
  });

  group('BG-21 · the ledger row reads the same law the gauge does', () {
    testWidgets('the row\'s count does not stop short of the mark it crosses', (
      tester,
    ) async {
      // The mark used to take its rung from `widget.confirmations` while the
      // count streamed from the last reading, so a poll of 106 arriving over a
      // row showing 96 abandoned the streaming branch outright: the number
      // stopped dead at 96 and was replaced by the terminal word — the row
      // claiming to have crossed the ceiling while the last figure it ever
      // showed was ninety-six. Fixed on the gauge first; this is the second
      // register, and a rule swept once is a rule swept nowhere (L144).
      await tester.pumpWidget(_host(_mark(96)));
      await tester.pump();
      expect(find.text('Accepted 96'), findsOneWidget);
      // The readings arrive a poll apart: the tween crosses the observed
      // gap, so a second reading in the same frame would cross in 100 ms.
      await tester.pump(KvMotion.stream);

      await tester.pumpWidget(_host(_mark(106)));
      await tester.pump();
      var highest = 96;
      for (var i = 0; i < 20; i++) {
        for (final t in tester.widgetList<Text>(find.byType(Text))) {
          // **The RENDERED run, not `data`.** The mark is a `Text.rich` since
          // UX-R3 — word in Jakarta, digits in mono (BG-30) — so `data` is null
          // on exactly the rows this measures.
          final shown = t.data ?? t.textSpan?.toPlainText() ?? '';
          final m = RegExp(r'^Accepted (\d+)$').firstMatch(shown);
          if (m != null) {
            highest = math.max(highest, int.parse(m.group(1)!));
          }
        }
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(
        highest,
        greaterThanOrEqualTo(kTestMaturity.userDaa - 1),
        reason:
            'the count stopped at $highest and the row then said it was past '
            '${kTestMaturity.userDaa}',
      );
      await tester.pumpAndSettle();
      expect(find.text('Settled'), findsOneWidget);
    });
  });

  group('BG-22 · the axis names itself', () {
    testWidgets('a screen reader hears the depth and the ceiling', (
      tester,
    ) async {
      // Built from the DEPTH, not from the words: past the ceiling the words
      // carry no number while the fill carries the reading, so a label built
      // from the words gave a screen-reader user no depth at all exactly where
      // a sighted user reads one off the track (`ux-auditor`, UX-5).
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_gauge(42, key: const ValueKey(42))));
      await tester.pump();
      expect(
        find.bySemanticsLabel(RegExp(r'42 of 100 DAA deep')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'Spendable at 100')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('the graduations are on the glass, ceiling named by its rung', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_gauge(42)));
      await tester.pump();
      // Origin, midpoint, ceiling. The midpoint is derived from the ceiling,
      // so a coinbase row labels 0 · 500 · 1,000 without a second table.
      for (final label in const ['0', '50', '100']) {
        expect(
          find.text(label),
          findsWidgets,
          reason: 'a scale is honest only where its graduations are labelled',
        );
      }
      // The ceiling is named with the rung it delivers — the same word the chip
      // says at the same instant, which is BG-7's redundancy rather than
      // BG-19's duplication: one is the axis, one is the reading.
      expect(find.text('settled'), findsOneWidget);
    });

    testWidgets('a coinbase row labels its own ceiling', (tester) async {
      await tester.pumpWidget(
        _host(
          KvBurialGauge(
            stalled: false,
            confirmations: 42,
            maturity: MaturityState.pending,
            direction: ActivityDirection.incoming,
            isCoinbase: true,
            thresholds: kTestMaturity,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('1,000'), findsOneWidget);
      expect(find.text('500'), findsOneWidget);
      // **One integer, one format.** The reading and the graduation twenty dp
      // beneath it both go through `formatScore` now; they used to print
      // `of 1000 DAA` and `1,000` (`ux-auditor` item 33).
      expect(find.text('of 1,000 DAA'), findsOneWidget);
    });

    testWidgets('every label clears the 11dp floor at 1.3x on a 320dp screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_host(_gauge(42), textScale: 1.3));
      await tester.pump();
      final texts = tester.widgetList<Text>(find.byType(Text));
      expect(texts, isNotEmpty);
      for (final text in texts) {
        final size = text.style?.fontSize ?? 0;
        expect(
          size,
          greaterThanOrEqualTo(11),
          reason: '"${text.data}" renders under the readable floor (BG-14)',
        );
      }
      expect(tester.takeException(), isNull);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────

/// **What the source guards above do not police, and why each one is out.**
///
///  * `lib/src/rust/` — generated bindings. That is Rust's own text, mirrored;
///    the ladder's law is enforced on the Rust side by `NetworkParams` itself.
///  * `lib/src/ui/preview/black_glass_home_preview.dart` — the **Black Glass
///    prototype**, a debug-only feel test of a design language the app has
///    since replaced twice. It is imported only by the dev launcher, imports
///    nothing from the shipped screens, and is a frozen record of what the
///    founder judged on glass in July. Migrating its vocabulary would make it a
///    *worse* record of that, and its `kSafeDepth`/`kFinalDepth` are its own
///    prototype constants rather than a threshold any user's money is measured
///    against. **The exemption is scoped to that one file** — a second preview
///    reaching for the retired words fails here.
bool _exempt(String path) =>
    path.contains('/rust/') ||
    path.endsWith('preview/black_glass_home_preview.dart');

/// The reading line's own words, told apart from the axis label that happens to
/// carry the same name. `settled` is both a rung and a graduation, so a bare
/// `find.text` matches two things that mean different things.
Finder _reading(String words) => find.byWidgetPredicate(
  (w) => w is Text && w.data == words && (w.style?.fontSize ?? 0) > 11,
);

/// The rung's hue, read off the reading line's dot — the channel that carries
/// the rung when the line prints only a number.
Color? _dotHue(WidgetTester tester) {
  // The dot is §4's lamp since the second beat — a disc inside its tint ring —
  // so the hue is the lamp's own colour, never the first circle in the tree
  // (which is the ring).
  final lamps = tester.widgetList<KvLamp>(find.byType(KvLamp));
  return lamps.isEmpty ? null : lamps.first.color;
}

Widget _mark(int depth) => KvBurialMark(
  stalled: false,
  confirmations: depth,
  maturity: MaturityState.confirmed,
  direction: ActivityDirection.outgoing,
  isCoinbase: false,
  thresholds: kTestMaturity,
);

/// [key] is how a case asks for a **fresh** gauge. `pumpWidget` reuses the
/// element tree, so a second call with a new depth is an UPDATE — the streamed
/// count then replays the interval between the two readings and the first frame
/// still shows the old one. That is exactly what the streaming cases want and
/// exactly what a step-by-step sweep must not have (L140).
Widget _gauge(int depth, {Key? key}) => KvBurialGauge(
  key: key,
  stalled: false,
  confirmations: depth,
  maturity: MaturityState.confirmed,
  direction: ActivityDirection.outgoing,
  isCoinbase: false,
  thresholds: kTestMaturity,
);

Widget _host(Widget child, {double textScale = 1}) => MediaQuery(
  data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
  child: MaterialApp(
    theme: kvDarkTheme(),
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
          child: child,
        ),
      ),
    ),
  ),
);

/// The depth the READING LINE is currently printing — read off the rendered
/// figure, so the ink can be checked against something the painter did not
/// produce.
int _shownDepth(WidgetTester tester) {
  for (final t in tester.widgetList<Text>(find.byType(Text))) {
    final d = t.data ?? '';
    // The reading is mono at 15; the graduations are mono at 11.
    if (t.style?.fontFamily == KvFont.mono &&
        (t.style?.fontSize ?? 0) > 11 &&
        RegExp(r'^\d+$').hasMatch(d)) {
      return int.parse(d);
    }
  }
  return 0;
}

/// What the gauge actually painted, replayed onto a spy canvas at the size the
/// widget was really laid out at.
class _Ink {
  _Ink._(this._spy, this._size);

  final _CanvasSpy _spy;
  final Size _size;

  static _Ink of(WidgetTester tester) {
    final finder = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is KvBurialGaugePainter,
    );
    expect(
      finder,
      findsOneWidget,
      reason:
          'the gauge painter was not in the tree — this test proves nothing '
          'unless it found the thing it is measuring',
    );
    final size = tester.getSize(finder);
    final painter =
        tester.widget<CustomPaint>(finder).painter! as KvBurialGaugePainter;
    final spy = _CanvasSpy();
    painter.paint(spy, size);
    return _Ink._(spy, size);
  }

  List<_Line> get lines => _spy.lines;

  /// The tones the painter uses for **structure** — the track's ground and its
  /// graduations. Everything else it paints is a reading.
  ///
  /// The polarity is deliberate: ink the guard does not recognise counts
  /// against the reading and fails loudly, rather than being quietly ignored —
  /// and it did exactly that when UX-R3 moved the structure off `etch`, which
  /// is the guard doing its job rather than a test to be loosened. Both tones
  /// clear WCAG 1.4.11's 3:1 floor now (`inkMeta` 4.75, `inkDim` 8.14 on
  /// `plate`); `etch`'s 2.35 never did, on a comment that said 3.04 (L164).
  /// Alpha is masked off so a mid-crossfade tone is still matched.
  static const List<Color> _structure = [KvColor.inkMeta, KvColor.inkDim];

  static bool _isStructure(Color c) {
    final rgb = c.toARGB32() & 0x00FFFFFF;
    return _structure.any((s) => (s.toARGB32() & 0x00FFFFFF) == rgb);
  }

  /// How much of the track is covered in reading ink, as a fraction —
  /// rectangles by their right edge, strokes by their end **plus whatever their
  /// cap paints past it**.
  ///
  /// **The track's own ground is a rectangle now**, so a guard that took the
  /// rightmost rect would read 100% at every depth. It is excluded by TONE,
  /// with the same polarity as the strokes: unrecognised ink counts as a
  /// reading and fails loudly.
  double get filledFraction {
    var right = 0.0;
    for (final (rect, colour) in _spy.rects) {
      if (_isStructure(colour)) continue;
      right = math.max(right, rect.right);
    }
    for (final line in _spy.lines) {
      if (_isStructure(line.colour)) continue;
      final overhang = line.cap == ui.StrokeCap.butt ? 0.0 : line.width / 2;
      right = math.max(right, math.max(line.from.dx, line.to.dx) + overhang);
    }
    return right / _size.width;
  }

  /// The tones the graduation strokes are painted in — the channel that tells
  /// a live scale from an unread one.
  Set<int> get tickTones =>
      verticalTicks.map((l) => l.colour.toARGB32() & 0x00FFFFFF).toSet();

  /// The graduation strokes, ordered left to right.
  List<_Line> get verticalTicks =>
      _spy.lines.where((l) => l.from.dx == l.to.dx).toList()
        ..sort((a, b) => a.from.dx.compareTo(b.from.dx));
}

class _Line {
  const _Line(this.from, this.to, this.width, this.cap, this.colour);

  final Offset from;
  final Offset to;
  final double width;
  final ui.StrokeCap cap;
  final Color colour;

  double get length => (to - from).distance;
}

/// Records every mark the painter makes and swallows the rest of `Canvas`.
class _CanvasSpy implements Canvas {
  final List<_Line> lines = [];
  final List<(Rect, Color)> rects = [];

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) =>
      lines.add(_Line(p1, p2, paint.strokeWidth, paint.strokeCap, paint.color));

  @override
  void drawRect(Rect rect, Paint paint) => rects.add((rect, paint.color));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
