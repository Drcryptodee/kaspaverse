import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/format.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/amount_text.dart';

void main() {
  group('kasParts (floor toward zero, render-layer only)', () {
    test('floors — never rounds a balance up', () {
      // 1.99999999 KAS must read as 1.99999999, never 2.
      final parts = kasParts(BigInt.from(199999999));
      expect(parts.integer, '1');
      expect(parts.fraction, '99999999');
    });

    test('a real zero is 0.00000000 (8-digit pad), not blank', () {
      final parts = kasParts(BigInt.zero);
      expect(parts.integer, '0');
      expect(parts.fraction, '00000000');
    });

    test('one whole KAS', () {
      expect(kasParts(BigInt.from(100000000)).integer, '1');
      expect(kasParts(BigInt.from(100000000)).fraction, '00000000');
    });

    test('one sompi is the smallest fraction', () {
      expect(kasParts(BigInt.one).fraction, '00000001');
    });

    test('groups the integer in threes', () {
      // 1,234,567 KAS exactly.
      final parts = kasParts(BigInt.from(1234567) * BigInt.from(100000000));
      expect(parts.integer, '1,234,567');
      expect(parts.fraction, '00000000');
    });

    test('BigInt survives past 2^53 without precision loss', () {
      // 9007199254740993 KAS — 2^53 + 1; a double would round to ...992.
      final sompi = BigInt.parse('9007199254740993') * BigInt.from(100000000);
      expect(kasParts(sompi).integer, '9,007,199,254,740,993');
    });
  });

  group('groupThousands', () {
    test('groups and leaves short strings alone', () {
      expect(groupThousands('1234567'), '1,234,567');
      expect(groupThousands('12'), '12');
      expect(groupThousands('0'), '0');
    });
  });

  group('trimFraction (§5 feeds/lists rule)', () {
    test('trims trailing zeros keeping at least two decimals', () {
      expect(trimFraction('50000000'), '50');
      expect(trimFraction('00000000'), '00');
      expect(trimFraction('40000000'), '40');
    });

    test('never trims significant digits', () {
      expect(trimFraction('56789012'), '56789012');
      expect(trimFraction('00000001'), '00000001');
    });
  });

  group('AmountText (DS-1/DS-2)', () {
    Future<void> pump(
      WidgetTester tester,
      BigInt? sompi, {
      bool stale = false,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          theme: kvDarkTheme(),
          home: Scaffold(body: AmountText(sompi, stale: stale)),
        ),
      );
    }

    String renderedAmount(WidgetTester tester) {
      final text = tester.widget<Text>(
        find.descendant(
          of: find.byType(AmountText),
          matching: find.byType(Text),
        ),
      );
      return text.textSpan?.toPlainText() ?? text.data ?? '';
    }

    testWidgets('null renders the DS-1 unknown dash, never a fake zero', (
      tester,
    ) async {
      await pump(tester, null);
      expect(find.text('—'), findsOneWidget);
      expect(find.textContaining('KAS'), findsNothing);
    });

    testWidgets('a real zero renders a live 0.00000000 KAS', (tester) async {
      await pump(tester, BigInt.zero);
      expect(renderedAmount(tester), '0.00000000 KAS');
      expect(find.text('—'), findsNothing);
    });

    testWidgets('a value renders integer.fraction KAS', (tester) async {
      await pump(tester, BigInt.from(123456789012)); // 1234.56789012 KAS
      expect(renderedAmount(tester), '1,234.56789012 KAS');
    });

    testWidgets('stale dims to opacity-stale', (tester) async {
      await pump(tester, BigInt.from(100000000), stale: true);
      final opacity = tester
          .widget<AnimatedOpacity>(find.byType(AnimatedOpacity))
          .opacity;
      expect(opacity, KvFreshness.opacityStale);
    });

    testWidgets('live (not stale) is full opacity', (tester) async {
      await pump(tester, BigInt.from(100000000));
      final opacity = tester
          .widget<AnimatedOpacity>(find.byType(AnimatedOpacity))
          .opacity;
      expect(opacity, 1.0);
    });

    testWidgets('carries a clean semantics label (§11, not digit soup)', (
      tester,
    ) async {
      await pump(tester, BigInt.from(123456789012));
      final text = tester.widget<Text>(
        find.descendant(
          of: find.byType(AmountText),
          matching: find.byType(Text),
        ),
      );
      expect(text.semanticsLabel, '1,234.56789012 KAS');
    });
  });

  group('AmountText precision & sign (§5/DS-2)', () {
    Future<void> pumpRole(
      WidgetTester tester,
      BigInt sompi, {
      AmountRole role = AmountRole.row,
      bool? exact,
      String? prefix,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          theme: kvDarkTheme(),
          home: Scaffold(
            body: AmountText(sompi, role: role, exact: exact, prefix: prefix),
          ),
        ),
      );
    }

    String rendered(WidgetTester tester) {
      final text = tester.widget<Text>(
        find.descendant(
          of: find.byType(AmountText),
          matching: find.byType(Text),
        ),
      );
      return text.textSpan?.toPlainText() ?? text.data ?? '';
    }

    testWidgets('a row trims trailing zeros to ≥2 decimals (feeds rule)', (
      tester,
    ) async {
      await pumpRole(tester, BigInt.from(50000000)); // 0.5 KAS
      expect(rendered(tester), '0.50 KAS');
    });

    testWidgets('exact forces all 8 decimals — the signing surface truth', (
      tester,
    ) async {
      await pumpRole(tester, BigInt.from(50000000), exact: true);
      expect(rendered(tester), '0.50000000 KAS');
    });

    testWidgets('hero and screen roles stay exact by default', (tester) async {
      await pumpRole(tester, BigInt.from(50000000), role: AmountRole.screen);
      expect(rendered(tester), '0.50000000 KAS');
    });

    testWidgets('a direction prefix renders and is spoken (§11)', (
      tester,
    ) async {
      await pumpRole(tester, BigInt.from(50000000), prefix: '+ ');
      expect(rendered(tester), '+ 0.50 KAS');
      final text = tester.widget<Text>(
        find.descendant(
          of: find.byType(AmountText),
          matching: find.byType(Text),
        ),
      );
      expect(text.semanticsLabel, '+ 0.50 KAS');
    });
  });
}
