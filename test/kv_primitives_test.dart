import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/kv_page_route.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_breath.dart';
import 'package:kaspaverse/src/ui/widgets/kv_loader.dart';

void main() {
  group('KvPageRoute — the §6 v2.2 duration law', () {
    test('slow in, normal back (leaving is lighter than arriving)', () {
      final route = KvPageRoute<void>(builder: (_) => const SizedBox());
      expect(route.transitionDuration, KvMotion.slow);
      expect(route.reverseTransitionDuration, KvMotion.normal);
    });
  });

  group('KvBreath — the live dot\'s pulse (BG-9, §3)', () {
    testWidgets('active: one sine period on BOTH channels, 1600 ms', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: KvBreath(child: Text('dot')),
        ),
      );
      final fade = tester.widget<FadeTransition>(
        find.byType(FadeTransition).first,
      );
      final scale = tester.widget<ScaleTransition>(
        find.byType(ScaleTransition).first,
      );
      expect(fade.opacity.value, 1.0); // wakes bright
      expect(scale.scale.value, 1.0);

      // §3: the trough is scale .7 and opacity .55 — NOT `opacityStale`, which
      // is the *stale* step and would have a live dot reaching a dead
      // reading's tone twice a second.
      await tester.pump(KvMotion.pulse * 0.5);
      expect(fade.opacity.value, closeTo(0.55, 0.01));
      expect(scale.scale.value, closeTo(0.7, 0.01));

      // …and a full period later it is bright again (seamless loop).
      await tester.pump(KvMotion.pulse * 0.5);
      expect(fade.opacity.value, closeTo(1.0, 0.01));
      expect(scale.scale.value, closeTo(1.0, 0.01));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('inactive: a static child, no animation to settle', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: KvBreath(active: false, child: Text('dot')),
        ),
      );
      expect(find.byType(FadeTransition), findsNothing);
      await tester.pumpAndSettle(); // proves nothing is ticking
      expect(find.text('dot'), findsOneWidget);
    });

    testWidgets('reduced motion: static full-opacity child (§6 rule)', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: KvBreath(child: Text('dot')),
          ),
        ),
      );
      expect(find.byType(FadeTransition), findsNothing);
      await tester.pumpAndSettle(); // the controller must be stopped
      expect(find.text('dot'), findsOneWidget);
    });
  });

  group('KvLoader — the one indeterminate spinner (§8 v2.2)', () {
    testWidgets('mark is 24 dp, inline is 16 dp, both stroke 2', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(children: [KvLoader(), KvLoader.inline()]),
        ),
      );
      final boxes = tester.widgetList<SizedBox>(find.byType(SizedBox)).toList();
      expect(boxes[0].width, KvSpace.l);
      expect(boxes[1].width, KvSpace.m);
      for (final spinner in tester.widgetList<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      )) {
        expect(spinner.strokeWidth, 2);
      }
    });
  });
}
