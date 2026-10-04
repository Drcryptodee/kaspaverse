import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/kv_page_route.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_loader.dart';
import 'package:kaspaverse/src/ui/widgets/kv_live_dot.dart';

void main() {
  group('KvPageRoute — the §6 v2.2 duration law', () {
    test('slow in, normal back (leaving is lighter than arriving)', () {
      final route = KvPageRoute<void>(builder: (_) => const SizedBox());
      expect(route.transitionDuration, KvMotion.enter);
      expect(route.reverseTransitionDuration, KvMotion.calm);
    });
  });

  group('KvLiveDot — the live dot\'s ping (BG-9, §3)', () {
    // Tailwind's `animate-ping`, number for number: 1 s, the ring travels the
    // first 75% on `cubic-bezier(0, 0, 0.2, 1)` from 1× / .75 to 2× / 0, and
    // rests out of sight for the last quarter.
    test('the ring: 1× at .75 → 2× at 0 by 75%, then out of sight', () {
      expect(kvPingAt(0).scale, 1.0);
      expect(kvPingAt(0).opacity, KvLiveDot.pingOpacity);
      // Halfway through its travel the ring is well past half its distance:
      // it leaves the dot fast (the curve's first handle is at the origin).
      final mid = kvPingAt(KvLiveDot.travel / 2);
      expect(mid.scale, greaterThan(1.7));
      expect(mid.opacity, lessThan(0.25));
      for (final t in [KvLiveDot.travel, 0.9, 1.0]) {
        expect(kvPingAt(t).scale, closeTo(KvLiveDot.pingScale, 1e-9));
        expect(kvPingAt(t).opacity, closeTo(0, 1e-9));
      }
      expect(KvLiveDot.period, const Duration(seconds: 1));
    });

    testWidgets('live: it loops, and the dot keeps its own box', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: KvLiveDot(live: true)),
        ),
      );
      await tester.pump(KvLiveDot.period * 3.5);
      expect(tester.hasRunningAnimations, isTrue); // never settles
      expect(
        find.descendant(
          of: find.byType(KvLiveDot),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
      // The ring paints outside the dot and takes no layout.
      expect(
        tester.getSize(find.byType(KvLiveDot)),
        const Size.square(KvLiveDot.size),
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('not live: a still amber dot, no animation to settle', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: KvLiveDot(live: false),
        ),
      );
      expect(find.byType(CustomPaint), findsNothing);
      await tester.pumpAndSettle(); // proves nothing is ticking
      expect(find.byType(KvLiveDot), findsOneWidget);
    });

    testWidgets('a link that drops: green and pinging → amber and still', (
      tester,
    ) async {
      Color fill() =>
          ((tester
                      .widget<DecoratedBox>(
                        find.descendant(
                          of: find.byType(KvLiveDot),
                          matching: find.byType(DecoratedBox),
                        ),
                      )
                      .decoration
                  as BoxDecoration)
              .color)!;
      Widget host(bool live) => Directionality(
        textDirection: TextDirection.ltr,
        child: KvLiveDot(live: live),
      );
      await tester.pumpWidget(host(true));
      await tester.pump(KvLiveDot.period * 0.3);
      expect(fill(), KvColor.ok);
      expect(tester.hasRunningAnimations, isTrue);

      // BG-8: the motion says *live*, so it stops the frame the link does.
      await tester.pumpWidget(host(false));
      expect(fill(), KvColor.warn);
      expect(find.byType(CustomPaint), findsNothing);
      expect(tester.hasRunningAnimations, isFalse);

      // …and resumes when it comes back.
      await tester.pumpWidget(host(true));
      expect(fill(), KvColor.ok);
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('reduced motion: the dot alone, no ghost (§6 rule)', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: KvLiveDot(live: true),
          ),
        ),
      );
      expect(find.byType(CustomPaint), findsNothing);
      await tester.pumpAndSettle(); // the controller must be stopped
      expect(find.byType(KvLiveDot), findsOneWidget);
    });
  });

  group('KvLoader draws one filled shape at both sizes', () {
    // Each loader is found and read on its own, so a drawing rule that stops
    // holding cannot pass by matching nothing.
    testWidgets('the mark is 24 dp and the inline loader 16 dp, each a filled '
        'shape over its centre', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(children: [KvLoader(), KvLoader.inline()]),
        ),
      );
      final loaders = find.byType(KvLoader);
      expect(loaders, findsNWidgets(2));
      void drawsAt(int index, double side) {
        final paint = find.descendant(
          of: loaders.at(index),
          matching: find.byType(CustomPaint),
        );
        expect(paint, findsOneWidget);
        expect(tester.widget<CustomPaint>(paint).painter, isA<KvLoaderShape>());
        expect(tester.getSize(paint), Size.square(side));
        expect(
          tester.renderObject(paint),
          paints..path(
            style: PaintingStyle.fill,
            includes: [Offset(side / 2, side / 2)],
            excludes: [const Offset(0.5, 0.5)],
          ),
        );
      }

      drawsAt(0, KvSpace.l);
      drawsAt(1, KvSpace.m);
    });
  });
}
