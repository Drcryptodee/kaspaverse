import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_reading.dart';

/// The reading room, on its own — the part `T4` and the home screen both sit
/// on, tested where its behaviour is visible rather than through two screens.
void main() {
  double edgeOpacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.descendant(
          of: find.byType(KvScrollEdge),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  Widget host({required int rows, double cap = 300}) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 300,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: cap),
            child: KvScrollEdge(
              ground: KvColor.plate,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: rows,
                itemBuilder: (_, i) => SizedBox(height: 60, child: Text('$i')),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  group('KvScrollEdge — honest, or absent', () {
    testWidgets('no fade over a list with nothing below it', (tester) async {
      // Three 60 dp rows in a 300 dp box: nothing to scroll.
      await tester.pumpWidget(host(rows: 3));
      await tester.pumpAndSettle();
      expect(
        edgeOpacity(tester),
        0,
        reason:
            'a permanent fade would be the decoration BG-4 forbids and '
            'the claim BG-8 forbids — it would say *there is more* over the '
            'last row',
      );
    });

    testWidgets('a fade while there IS more, and gone at the end', (
      tester,
    ) async {
      await tester.pumpWidget(host(rows: 20));
      await tester.pumpAndSettle();
      expect(edgeOpacity(tester), 1);

      // Scroll to the very end.
      final pos = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      pos.jumpTo(pos.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(
        edgeOpacity(tester),
        0,
        reason: 'at the end there is nothing more to signify',
      );
    });

    testWidgets('a list that GROWS gains its fade without being touched', (
      tester,
    ) async {
      await tester.pumpWidget(host(rows: 3));
      await tester.pumpAndSettle();
      expect(edgeOpacity(tester), 0);

      await tester.pumpWidget(host(rows: 20));
      await tester.pumpAndSettle();
      expect(
        edgeOpacity(tester),
        1,
        reason:
            'the metrics change on their own — a live feed must not need '
            'a drag before it tells the truth',
      );
    });
  });
}
