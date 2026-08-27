import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/format.dart';

void main() {
  group('sompiFromKas (parse → sompi; string math, never a double)', () {
    test('whole and fractional KAS', () {
      expect(sompiFromKas('12.4'), BigInt.from(1240000000));
      expect(sompiFromKas('0'), BigInt.zero);
      expect(sompiFromKas('1'), BigInt.from(100000000));
      expect(sompiFromKas('.5'), BigInt.from(50000000));
      expect(sompiFromKas('0.00000001'), BigInt.one); // one sompi
      expect(sompiFromKas('12.'), BigInt.from(1200000000)); // trailing dot ok
    });

    test('trims surrounding whitespace', () {
      expect(sompiFromKas('  2.5  '), BigInt.from(250000000));
    });

    test('rejects malformed / non-amounts (returns null)', () {
      expect(sompiFromKas(''), isNull);
      expect(sompiFromKas('   '), isNull);
      expect(sompiFromKas('.'), isNull);
      expect(sompiFromKas('abc'), isNull);
      expect(sompiFromKas('1.2.3'), isNull);
      expect(sompiFromKas('-5'), isNull);
      expect(sompiFromKas('1,000'), isNull); // grouping is display-only
      expect(sompiFromKas('1 0'), isNull);
    });

    test(
      'rejects finer-than-sompi precision — never silently floors it away',
      () {
        expect(sompiFromKas('1.123456789'), isNull); // 9 fractional digits
        expect(sompiFromKas('0.000000001'), isNull);
        expect(
          sompiFromKas('1.12345678'),
          BigInt.from(112345678),
        ); // exactly 8 ok
      },
    );

    test('survives past 2^53 without precision loss (BigInt, L3)', () {
      // 100,000,000 KAS = 1e16 sompi > 2^53 (~9.007e15) — a double would round.
      expect(sompiFromKas('100000000'), BigInt.parse('10000000000000000'));
    });

    test('round-trips with kasParts', () {
      final sompi = sompiFromKas('1234.56789012')!;
      final parts = kasParts(sompi);
      expect(parts.integer, '1,234');
      expect(parts.fraction, '56789012');
    });
  });

  group('trimTrailingZeros (the precision law on a unit that is not KAS)', () {
    test('every significant digit, and no padding', () {
      // D-210 is written against **the unit's own precision**, deliberately, so
      // a figure denominated in something other than KAS inherits the rule
      // instead of needing a second one.
      expect(trimTrailingZeros(0.02864504), '0.02864504');
      expect(trimTrailingZeros(0.0712), '0.0712');
      expect(trimTrailingZeros(1.5), '1.5');
      expect(trimTrailingZeros(1), '1', reason: 'no lone trailing dot');
      expect(trimTrailingZeros(12.34, max: 2), '12.34');
    });

    test('a value finer than the unit floors, never rounds up', () {
      // The one edge where the answer is lossy, and it is bounded elsewhere:
      // Rust refuses a price ≤ 0 or above a believable ceiling before it ever
      // reaches a screen (`prefs::check_price`).
      expect(trimTrailingZeros(0.000000001), '0');
    });
  });

  group('chunkAddress (DS-8 full-form review)', () {
    test('keeps the kaspa: prefix and groups the payload in fours', () {
      expect(chunkAddress('kaspa:qz7ulu4c25dh'), 'kaspa:qz7u lu4c 25dh');
    });

    test('groups a colon-less string (e.g. a txid) wholesale', () {
      expect(chunkAddress('abcdefgh'), 'abcd efgh');
    });
  });
}
