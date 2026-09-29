import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_loader.dart';
import 'package:kaspaverse/src/ui/widgets/kv_empty_state.dart';
import 'package:kaspaverse/src/ui/widgets/kv_glyph.dart';
import 'package:kaspaverse/src/ui/widgets/kv_status_chip.dart';
import 'package:kaspaverse/src/ui/widgets/kv_surface.dart';
import 'package:kaspaverse/src/ui/widgets/kv_toggle.dart';

Widget _host(Widget child, {bool reducedMotion = false, double width = 360}) {
  return MediaQuery(
    data: MediaQueryData(
      size: Size(width, 640),
      disableAnimations: reducedMotion,
    ),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: KvColor.abyss,
        child: Center(child: child),
      ),
    ),
  );
}

KvLoaderShape _shape(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.descendant(
                of: find.byType(KvLoader),
                matching: find.byType(CustomPaint),
              ),
            )
            .painter!
        as KvLoaderShape;

void main() {
  group('KvLoader — the ONE loader (LINK-Q4: Material 3 Expressive, the '
      'founder\'s choice; §4, BG-8, D-192)', () {
    test('its numbers are AOSP\'s LoadingIndicator, not a guess', () {
      expect(KvLoader.morphMs, 650);
      expect(KvLoader.turnMs, 4666);
      expect(KvLoader.springDamping, 0.6);
      expect(KvLoader.springStiffness, 200);
      expect(KvLoader.activeRatio, closeTo(38 / 48, 1e-9));
      expect(KvLoader.shapes, hasLength(7));
    });

    test('the morph is a spring: it overshoots about 9 % and settles inside '
        'one morph', () {
      expect(KvLoader.spring(0), 0);
      var peak = 0.0;
      for (var t = 0.0; t <= KvLoader.morphMs / 1000; t += 0.001) {
        peak = peak > KvLoader.spring(t) ? peak : KvLoader.spring(t);
      }
      expect(peak, closeTo(1.095, 0.01), reason: 'underdamped, ζ = 0.6');
      expect(KvLoader.spring(KvLoader.morphMs / 1000), closeTo(1, 0.01));
    });

    test('seven distinct outlines, each reaching the edge exactly once', () {
      for (final s in KvLoader.shapes) {
        expect(s, hasLength(KvLoader.samples));
        expect(s.reduce((a, b) => a > b ? a : b), closeTo(1, 1e-9));
        expect(s.reduce((a, b) => a < b ? a : b), greaterThan(0.5));
      }
      for (var i = 0; i < KvLoader.shapes.length; i++) {
        for (var k = i + 1; k < KvLoader.shapes.length; k++) {
          expect(KvLoader.shapes[i], isNot(equals(KvLoader.shapes[k])));
        }
      }
    });

    testWidgets('running: it turns and morphs', (tester) async {
      await tester.pumpWidget(_host(const KvLoader()));
      await tester.pump(const Duration(milliseconds: 16));
      final first = _shape(tester);
      await tester.pump(const Duration(milliseconds: 300));
      final later = _shape(tester);
      expect(later.turn, isNot(first.turn));
      expect(later.progress, isNot(first.progress));
      expect(later.color.a, closeTo(1, 0.001));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the link dies and it FREEZES, dimmed', (tester) async {
      await tester.pumpWidget(_host(const KvLoader(running: false)));
      expect(_shape(tester).color.a, closeTo(KvFreshness.opacityStale, 0.001));
      // Nothing is ticking: a settled screen is a still screen (D-192).
      await tester.pumpAndSettle();
      expect(_shape(tester).color.a, closeTo(KvFreshness.opacityStale, 0.001));
    });

    testWidgets(
      'reduced motion keeps running and frozen TELLABLE APART (BG-9)',
      (tester) async {
        await tester.pumpWidget(_host(const KvLoader(), reducedMotion: true));
        final running = _shape(tester);
        expect(running.color.a, closeTo(1, 0.001));
        await tester.pumpAndSettle(); // proves nothing is animating
        expect(_shape(tester).turn, running.turn);
        await tester.pumpWidget(
          _host(const KvLoader(running: false), reducedMotion: true),
        );
        expect(
          _shape(tester).color.a,
          closeTo(KvFreshness.opacityStale, 0.001),
        );
      },
    );

    testWidgets('it stops the instant running goes false', (tester) async {
      await tester.pumpWidget(_host(const KvLoader()));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpWidget(_host(const KvLoader(running: false)));
      await tester.pumpAndSettle();
      expect(_shape(tester).color.a, closeTo(KvFreshness.opacityStale, 0.001));
    });

    testWidgets('three looks, one meaning each — working teal, waiting grey '
        'and moving, stopped grey and dim; never a lamp\'s hue (LINK-Q4)', (
      tester,
    ) async {
      // Working: teal, full, moving.
      await tester.pumpWidget(_host(const KvLoader(label: null)));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_shape(tester).color.withValues(alpha: 1), KvLoader.colour);
      expect(_shape(tester).color.a, closeTo(1, 0.001));
      expect(tester.hasRunningAnimations, isTrue);
      // Waiting: grey, full, still moving (a new loader — its colour is
      // chosen when it appears).
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        _host(const KvLoader(waiting: true, label: null)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(_shape(tester).color.withValues(alpha: 1), KvLoader.waitingColour);
      expect(_shape(tester).color.a, closeTo(1, 0.001));
      expect(tester.hasRunningAnimations, isTrue, reason: 'it listens');
      // Stopped: grey, dimmed, still.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        _host(const KvLoader(running: false, label: null)),
      );
      await tester.pumpAndSettle();
      expect(_shape(tester).color.withValues(alpha: 1), KvLoader.waitingColour);
      expect(_shape(tester).color.a, closeTo(KvFreshness.opacityStale, 0.001));
      // The two colours are the house's, and neither is a status hue.
      expect(KvLoader.colour, KvColor.primaryMuted);
      expect(KvLoader.waitingColour, KvColor.inkMeta);
      for (final status in [KvColor.ok, KvColor.warn, KvColor.risk]) {
        expect(KvLoader.colour, isNot(status));
        expect(KvLoader.waitingColour, isNot(status));
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('it keeps the colour it appeared in until it leaves — a state '
        'change moves or dims it, never re-colours it (the founder, LINK-Q4)', (
      tester,
    ) async {
      Future<Color> hue(KvLoader loader) async {
        await tester.pumpWidget(_host(loader));
        await tester.pump(const Duration(milliseconds: 16));
        return _shape(tester).color.withValues(alpha: 1);
      }

      // Appears working: teal. Then the phone drops: still teal.
      expect(await hue(const KvLoader(label: null)), KvLoader.colour);
      expect(
        await hue(const KvLoader(waiting: true, label: null)),
        KvLoader.colour,
      );
      // Gone, then a new one appears waiting: grey. Work starts: still grey.
      await tester.pumpWidget(const SizedBox());
      expect(
        await hue(const KvLoader(waiting: true, label: null)),
        KvLoader.waitingColour,
      );
      expect(await hue(const KvLoader(label: null)), KvLoader.waitingColour);
      expect(tester.hasRunningAnimations, isTrue, reason: 'it still moves');
      // Stopping dims it; the colour it appeared in stays.
      await tester.pumpWidget(
        _host(const KvLoader(running: false, label: null)),
      );
      await tester.pumpAndSettle();
      expect(_shape(tester).color.withValues(alpha: 1), KvLoader.waitingColour);
      expect(_shape(tester).color.a, closeTo(KvFreshness.opacityStale, 0.001));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('it speaks only when it stands alone', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(const KvLoader(running: false, label: null)),
      );
      expect(find.bySemanticsLabel('loading'), findsNothing);
      await tester.pumpWidget(_host(const KvLoader(running: false)));
      expect(find.bySemanticsLabel('loading'), findsOneWidget);
      handle.dispose();
    });
  });

  group('KvSurface — tone plus one honest edge (BG-4, §1.1)', () {
    test(
      'every tone carries the fill, edge and radius §1.1/§3 pair it with',
      () {
        const expected = <KvSurfaceTone, (Color, Color?, double)>{
          KvSurfaceTone.abyss: (KvColor.abyss, null, 0),
          KvSurfaceTone.well: (KvColor.plate, KvColor.hairline, KvRadius.plate),
          KvSurfaceTone.chip: (
            KvColor.chip,
            KvColor.hairline,
            KvRadius.control,
          ),
          KvSurfaceTone.plate: (
            KvColor.plate,
            KvColor.plateEdge,
            KvRadius.plate,
          ),
        };
        expect(expected.keys, containsAll(KvSurfaceTone.values));
        for (final tone in KvSurfaceTone.values) {
          final (fill, edge, radius) = expected[tone]!;
          expect(tone.fill, fill, reason: '$tone fill');
          expect(tone.edge, edge, reason: '$tone edge');
          expect(tone.radius, radius, reason: '$tone radius');
        }
      },
    );

    testWidgets('there is no shadow, and no way to ask for one (BG-4)', (
      tester,
    ) async {
      for (final tone in KvSurfaceTone.values) {
        await tester.pumpWidget(
          _host(KvSurface(tone: tone, width: 40, height: 40)),
        );
        final decoration =
            tester
                    .widget<Container>(
                      find.descendant(
                        of: find.byType(KvSurface),
                        matching: find.byType(Container),
                      ),
                    )
                    .decoration!
                as BoxDecoration;
        expect(decoration.boxShadow, isNull, reason: '$tone');
        expect(decoration.gradient, isNull, reason: '$tone');
        expect(decoration.color, tone.fill);
      }
    });

    testWidgets('a transparent edge is no edge at all', (tester) async {
      await tester.pumpWidget(
        _host(const KvSurface(edge: Color(0x00000000), width: 40, height: 40)),
      );
      expect(
        tester.widget<KvSurface>(find.byType(KvSurface)).resolvedEdge,
        isNull,
      );
    });
  });

  group('KvLamp / KvStatusChip — lamp and words, always both (§4)', () {
    test('teal is a status nowhere except the named live dot', () {
      // Four tones since Deep V6: BG-2 lists *the live dot* among `primary`'s
      // permitted appearances, and §4's money plate anatomy asks for one by
      // name. Every OTHER tone is still barred from both teals, which is what
      // keeps "teal is never a status" true where it matters.
      expect(KvLampTone.values, hasLength(4));
      for (final tone in KvLampTone.values) {
        if (tone == KvLampTone.live) continue;
        expect(tone.color, isNot(KvColor.primary));
        expect(tone.color, isNot(KvColor.primaryMuted));
      }
      expect(KvLampTone.live.color, KvColor.primary);
      expect(KvLampTone.ok.color, KvColor.ok);
      expect(KvLampTone.warn.color, KvColor.warn);
      expect(KvLampTone.risk.color, KvColor.risk);
      // The ring is the hue's own tint, and there is no bloom left to check:
      // BG-32 seats exactly two glowing things and a lamp is neither.
      expect(KvLampTone.live.ring, KvColor.tealTint);
      expect(KvLampTone.ok.ring, KvColor.okTint);
      expect(KvLampTone.warn.ring, KvColor.warnTint);
      expect(KvLampTone.risk.ring, KvColor.riskTint);
    });

    testWidgets('a disc in a ring, and NO bloom (BG-32)', (tester) async {
      await tester.pumpWidget(_host(const KvLamp(KvLampTone.ok)));
      for (final box in tester.widgetList<Container>(
        find.descendant(
          of: find.byType(KvLamp),
          matching: find.byType(Container),
        ),
      )) {
        final decoration = box.decoration! as BoxDecoration;
        expect(decoration.shape, BoxShape.circle);
        expect(
          decoration.boxShadow,
          isNull,
          reason: 'a lamp is a disc, not a bloom',
        );
      }
      expect(
        tester.getSize(find.byType(KvLamp)),
        const Size(KvLamp.extent, KvLamp.extent),
      );
    });

    testWidgets('the words are colourless whatever the lamp does', (
      tester,
    ) async {
      for (final tone in KvLampTone.values) {
        await tester.pumpWidget(
          _host(KvStatusChip(tone: tone, words: 'Node responding')),
        );
        final text = tester.widget<Text>(find.text('Node responding'));
        expect(
          text.style!.color,
          KvColor.inkDim,
          reason:
              'a fault reads as an indicator coming ON, not as coloured '
              'text — which is also what holds every string at AA (§1.5)',
        );
      }
    });

    testWidgets('only amber has a tinted plate — §1.6 names no other', (
      tester,
    ) async {
      BoxDecoration plateFor(WidgetTester t) =>
          t
                  .widget<Container>(
                    find
                        .descendant(
                          of: find.byType(KvStatusChip),
                          matching: find.byType(Container),
                        )
                        .first,
                  )
                  .decoration!
              as BoxDecoration;

      await tester.pumpWidget(
        _host(
          const KvStatusChip(
            tone: KvLampTone.warn,
            words: 'Link lost',
            plated: true,
          ),
        ),
      );
      expect(plateFor(tester).color, KvColor.warnTint);

      for (final tone in [KvLampTone.ok, KvLampTone.risk]) {
        await tester.pumpWidget(
          _host(KvStatusChip(tone: tone, words: 'Sent', plated: true)),
        );
        // Neutral: inventing a green or red plate would break BG-3, which
        // names exactly four tinted surfaces in the whole system.
        expect(plateFor(tester).color, KvColor.chip, reason: '$tone');
      }
    });
  });

  group('KvEmptyState — the ONE empty state (§4)', () {
    testWidgets('etched glyph, one truth, one nudge', (tester) async {
      await tester.pumpWidget(
        _host(
          const KvEmptyState(
            mark: KvGlyph.diamond,
            truth: 'Nothing has moved yet',
            nudge: 'Your address is ready to receive.',
          ),
        ),
      );
      expect(find.text('Nothing has moved yet'), findsOneWidget);
      expect(find.text('Your address is ready to receive.'), findsOneWidget);
      final glyph = tester.widget<KvGlyphIcon>(find.byType(KvGlyphIcon));
      expect(glyph.tone, KvColor.etch);
      // `etch` is 3.04:1 and below AA BY DESIGN — legitimate only because the
      // two lines of copy carry every bit of the meaning.
      expect(glyph.semanticLabel, isNull);
    });

    testWidgets('it survives 1.3x text scale at 320dp', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(1.3),
          ),
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: Material(
              color: KvColor.abyss,
              child: KvEmptyState(
                mark: KvGlyph.diamond,
                truth: 'Nothing has moved yet',
                nudge: 'Your address is ready to receive.',
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('KvToggle — a switch the user set (D-200, BG-9, BG-12)', () {
    testWidgets('"on" is `ok` green — never teal (BG-2)', (tester) async {
      await tester.pumpWidget(
        _host(
          KvToggle(
            on: true,
            title: 'Pin a node I run',
            sub: 'A pinned node never falls back.',
            onChanged: (_) {},
          ),
        ),
      );
      final track =
          tester
                  .widget<AnimatedContainer>(find.byType(AnimatedContainer))
                  .decoration!
              as BoxDecoration;
      // A toggle reports a state the user set and that is TRUE, which is the
      // same family as confirmed. Teal is light, never a status.
      expect(track.color, KvColor.ok);
      expect(track.color, isNot(KvColor.primary));
      expect(track.borderRadius, BorderRadius.circular(KvRadius.control));
    });

    testWidgets('the row is the target and clears 48dp (BG-12)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          KvToggle(
            on: false,
            title: 'Pin a node I run',
            sub: 'The wallet reaches Kaspa through public community nodes.',
            onChanged: (_) {},
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(InkWell)).height,
        greaterThanOrEqualTo(KvSpace.touchTarget),
      );
      // The 44x26 switch is the smaller visual inside it, which BG-12 permits
      // only because the code states it.
      expect(
        tester.getSize(find.byType(AnimatedContainer)),
        const Size(KvToggle.trackWidth, KvToggle.trackHeight),
      );
    });

    testWidgets('reduced motion collapses the slide (BG-9)', (tester) async {
      // Nothing in the pinned SDK does this for an implicit animation, and
      // `SwitchThemeData` cannot reach it at all — which is the whole reason
      // this is drawn rather than inherited.
      await tester.pumpWidget(
        _host(
          KvToggle(
            on: true,
            title: 'Pin a node I run',
            sub: 'A pinned node never falls back.',
            onChanged: (_) {},
          ),
          reducedMotion: true,
        ),
      );
      expect(
        tester
            .widget<AnimatedContainer>(find.byType(AnimatedContainer))
            .duration,
        Duration.zero,
      );

      await tester.pumpWidget(
        _host(
          KvToggle(
            on: true,
            title: 'Pin a node I run',
            sub: 'A pinned node never falls back.',
            onChanged: (_) {},
          ),
        ),
      );
      expect(
        tester
            .widget<AnimatedContainer>(find.byType(AnimatedContainer))
            .duration,
        KvMotion.fast,
      );
    });

    testWidgets('a disabled toggle SAYS why, and looks it (BG-12)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const KvToggle(
            on: false,
            title: 'Pin a node I run',
            sub: 'The wallet reaches Kaspa through public community nodes.',
            onChanged: null,
            disabledReason: 'Setting the node…',
          ),
        ),
      );
      expect(find.text('Setting the node…'), findsOneWidget);
      final dimmed = tester
          .widgetList<Opacity>(find.byType(Opacity))
          .any((o) => o.opacity == KvFreshness.opacityStale);
      expect(
        dimmed,
        isTrue,
        reason: 'spoken is not enough — it is visible too',
      );
    });

    testWidgets('a disabled toggle with no reason is caught in debug', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const KvToggle(
            on: false,
            title: 'Pin a node I run',
            sub: 'The wallet reaches Kaspa through public community nodes.',
            onChanged: null,
          ),
        ),
      );
      expect(tester.takeException(), isA<AssertionError>());
    });
  });
}
