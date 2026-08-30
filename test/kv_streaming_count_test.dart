import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_streaming_count.dart';

/// The rendered number, read back out of the tree.
int _shown(WidgetTester tester) {
  final text = tester.widget<Text>(find.byType(Text));
  return int.parse(text.data!);
}

Widget _host(
  BigInt? value, {
  bool stalled = false,
  bool reduced = false,
  Duration interval = KvMotion.stream,
}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reduced),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: KvStreamingCount(
      value: value,
      stalled: stalled,
      interval: interval,
      // DS-1: the caller renders the unknown dash. The primitive hands
      // null through rather than deciding to render nothing.
      builder: (context, shown) => Text(shown == null ? '—' : '$shown'),
    ),
  ),
);

void main() {
  group('KvStreamingCount — motion that cannot overstate the chain (D-226)', () {
    testWidgets('the first reading SNAPS: there is no interval to replay', (
      tester,
    ) async {
      await tester.pumpWidget(_host(BigInt.from(500)));
      expect(_shown(tester), 500);
    });

    testWidgets('it replays the interval BETWEEN two readings, never past the '
        'newest one', (tester) async {
      // The whole honesty argument in one test. The counter is monotonic and
      // passes through every integer between two observations, so each frame
      // shows a number the chain genuinely had. Extrapolating instead — the
      // obvious "predict at ~10/s" fix — would render numbers the chain has
      // NOT reached, which is the wallet-clock defect in a new costume.
      await tester.pumpWidget(_host(BigInt.from(100)));
      expect(_shown(tester), 100);

      await tester.pumpWidget(_host(BigInt.from(110)));
      await tester.pump(); // frame 0 of the tween
      expect(_shown(tester), 100, reason: 'starts at the PREVIOUS observation');

      await tester.pump(const Duration(milliseconds: 500));
      final mid = _shown(tester);
      expect(
        mid,
        greaterThan(100),
        reason: 'it actually moved rather than waiting to jump',
      );
      expect(mid, lessThan(110), reason: 'and it has not arrived early');

      await tester.pump(const Duration(milliseconds: 600));
      expect(_shown(tester), 110, reason: 'lands exactly on the observation');

      // And having landed, it STAYS. No coasting past the newest reading.
      await tester.pump(const Duration(seconds: 3));
      expect(_shown(tester), 110);
    });

    testWidgets('every frame of a crossing stays within the two observations', (
      tester,
    ) async {
      // Sampled across the whole tween rather than at one convenient instant:
      // the law is about EVERY frame, and a bound asserted once is a bound
      // asserted nowhere.
      await tester.pumpWidget(_host(BigInt.from(1000)));
      await tester.pumpWidget(_host(BigInt.from(1010)));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        final n = _shown(tester);
        expect(
          n,
          inInclusiveRange(1000, 1010),
          reason: 'frame $i rendered $n outside the observed interval',
        );
      }
    });

    testWidgets('a DECREASE snaps — a reorg is not progress', (tester) async {
      await tester.pumpWidget(_host(BigInt.from(500)));
      await tester.pumpWidget(_host(BigInt.from(400)));
      await tester.pump();
      expect(
        _shown(tester),
        400,
        reason: 'depth going backwards must not animate as if it were burial',
      );
    });

    testWidgets('a STALLED link stops the motion instead of coasting', (
      tester,
    ) async {
      // BG-8 applied to movement. A counter still climbing while the link is
      // dead is pure prediction, and it is the P0.3 scar's shape: a frozen
      // reading presented as a live one.
      await tester.pumpWidget(_host(BigInt.from(200)));
      await tester.pumpWidget(_host(BigInt.from(220)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_shown(tester), lessThan(220));

      await tester.pumpWidget(_host(BigInt.from(220), stalled: true));
      await tester.pump();
      final parked = _shown(tester);
      expect(parked, 220, reason: 'lands on the last value actually READ');
      await tester.pump(const Duration(seconds: 2));
      expect(_shown(tester), parked, reason: 'and does not move again');
    });

    testWidgets('reduced motion snaps rather than streams', (tester) async {
      await tester.pumpWidget(_host(BigInt.from(10), reduced: true));
      await tester.pumpWidget(_host(BigInt.from(90), reduced: true));
      await tester.pump();
      expect(_shown(tester), 90);
    });

    testWidgets('a null reading hands NULL to the caller, so the surface can '
        'render DS-1\'s dash', (tester) async {
      // The first cut returned `SizedBox.shrink()` for null, which deleted the
      // whole `DAA —` line from the money plate: an unknown value rendered as
      // NOTHING, where DS-1/BG-8 require the dash. Deciding what "no reading"
      // looks like belongs to the surface, never to the primitive.
      await tester.pumpWidget(_host(BigInt.from(7)));
      expect(_shown(tester), 7);
      await tester.pumpWidget(_host(null));
      await tester.pump();
      expect(find.text('—'), findsOneWidget, reason: 'the dash, not a blank');
      await tester.pumpWidget(_host(BigInt.from(9)));
      await tester.pump();
      expect(_shown(tester), 9);
    });

    testWidgets('a DAA-sized score streams without losing an integer', (
      tester,
    ) async {
      // The real magnitudes: ~5.2e8 and climbing ~10/s. The interpolation is
      // integer-only, so this is exact rather than nearly-exact.
      final a = BigInt.from(526633447);
      final b = BigInt.from(526633457);
      await tester.pumpWidget(_host(a));
      await tester.pumpWidget(_host(b));
      await tester.pump(const Duration(milliseconds: 500));
      expect(_shown(tester), inInclusiveRange(a.toInt(), b.toInt()));
      await tester.pump(const Duration(milliseconds: 600));
      expect(_shown(tester), b.toInt());
    });
  });
}
