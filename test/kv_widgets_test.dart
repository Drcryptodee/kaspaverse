import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_cadence.dart';
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

List<double> _barAlphas(WidgetTester tester) => tester
    .widgetList<ColoredBox>(
      find.descendant(
        of: find.byType(KvCadence),
        matching: find.byType(ColoredBox),
      ),
    )
    .map((b) => b.color.a)
    .toList();

void main() {
  group('KvCadence — the ONE loading indicator (§4, BG-8, D-192)', () {
    test('its extent is derived from the bars, never asserted (L121)', () {
      expect(KvCadence.height, 14);
      expect(
        KvCadence.width,
        KvCadence.barHeights.length * KvCadence.barWidth +
            (KvCadence.barHeights.length - 1) * KvCadence.barGap,
      );
      expect(KvCadence.barHeights, const [6, 10, 14, 10, 6]);
    });

    testWidgets('running: the bars travel', (tester) async {
      await tester.pumpWidget(_host(const KvCadence(running: true)));
      final first = _barAlphas(tester);
      expect(first, hasLength(5));
      await tester.pump(KvMotion.breath * 0.3);
      expect(_barAlphas(tester), isNot(equals(first)));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the link dies and it FREEZES, dimmed', (tester) async {
      await tester.pumpWidget(_host(const KvCadence(running: false)));
      expect(
        _barAlphas(tester),
        everyElement(closeTo(KvFreshness.opacityStale, 0.001)),
      );
      // Nothing is ticking: a settled screen is a still screen (D-192), so a
      // settle must return rather than time out.
      await tester.pumpAndSettle();
      expect(
        _barAlphas(tester),
        everyElement(closeTo(KvFreshness.opacityStale, 0.001)),
      );
    });

    testWidgets(
      'reduced motion keeps running and frozen TELLABLE APART (BG-9)',
      (tester) async {
        // Stopping the controller under reduced motion would render a running
        // cadence identically to a dead one — the precise lie BG-8 forbids.
        // The movement goes; the distinction does not.
        await tester.pumpWidget(
          _host(const KvCadence(running: true), reducedMotion: true),
        );
        final running = _barAlphas(tester);
        expect(running, everyElement(closeTo(1.0, 0.001)));
        await tester.pumpAndSettle(); // proves nothing is animating
        expect(_barAlphas(tester), running);

        await tester.pumpWidget(
          _host(const KvCadence(running: false), reducedMotion: true),
        );
        final frozen = _barAlphas(tester);
        expect(frozen, everyElement(closeTo(KvFreshness.opacityStale, 0.001)));
        expect(frozen, isNot(equals(running)));
      },
    );

    testWidgets('it stops the instant running goes false', (tester) async {
      await tester.pumpWidget(_host(const KvCadence(running: true)));
      await tester.pump(KvMotion.breath * 0.4);
      await tester.pumpWidget(_host(const KvCadence(running: false)));
      await tester.pumpAndSettle();
      expect(
        _barAlphas(tester),
        everyElement(closeTo(KvFreshness.opacityStale, 0.001)),
      );
    });

    testWidgets('it is one emission, and it is silent to a screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const KvCadence(running: false)));
      expect(find.byType(ExcludeSemantics), findsOneWidget);
      handle.dispose();
    });
  });

  group('KvSurface — tone plus one honest edge (BG-4, §1.1)', () {
    test(
      'every tone carries the fill, edge and radius §1.1/§3 pair it with',
      () {
        const expected = <KvSurfaceTone, (Color, Color?, double)>{
          KvSurfaceTone.abyss: (KvColor.abyss, null, 0),
          KvSurfaceTone.well: (KvColor.well, KvColor.hairline, KvRadius.plate),
          KvSurfaceTone.notice: (
            KvColor.notice,
            KvColor.noticeEdge,
            KvRadius.plate,
          ),
          KvSurfaceTone.chip: (
            KvColor.chip,
            KvColor.plateDivider,
            KvRadius.chip,
          ),
          KvSurfaceTone.plate: (
            KvColor.plate,
            KvColor.plateEdge,
            KvRadius.panel,
          ),
          KvSurfaceTone.key: (KvColor.key, KvColor.keyEdge, KvRadius.key),
          KvSurfaceTone.keyPressed: (
            KvColor.keyPressed,
            KvColor.keyEdge,
            KvRadius.key,
          ),
          KvSurfaceTone.summoned: (
            KvColor.summoned,
            KvColor.summonedEdge,
            KvRadius.panel,
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

    testWidgets(
      'controls are pills at `control`; surfaces are milled (D-194)',
      (tester) async {
        await tester.pumpWidget(
          _host(const KvSurface.control(width: 80, height: 48)),
        );
        final surface = tester.widget<KvSurface>(find.byType(KvSurface));
        expect(surface.resolvedRadius, KvRadius.control);
        expect(surface.resolvedRadius, KvRadius.pill);
        expect(surface.tone.fill, KvColor.control);
        expect(surface.resolvedEdge, KvColor.edgeHi);
        // `control` and `notice` are ONE tone, not two — v3.1 defined
        // `control = notice` and `KvSurfaceTone.notice` is the tone every
        // control wears. v4.2's ramp is five deep, not eight (§1.1), and the
        // legacy aliases must map onto it without splitting a pair the widgets
        // treat as interchangeable.
        expect(KvColor.control, KvColor.notice);
      },
    );

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
      expect(plateFor(tester).color, KvColor.noticeWarnFill);

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
