import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/format.dart';
import 'package:kaspaverse/src/ui/widgets/kv_address.dart';

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
    // The two expectations below CHANGED at D-223. They previously asserted a
    // pure grouping in fours, which is the rule the founder replaced after
    // seeing its output on glass: a 61-character payload ended `c6jz qunt h`,
    // stranding one bold character where the eye is supposed to land.
    test('keeps the kaspa: prefix, fours in the head, FIVE in the tail', () {
      expect(chunkAddress('kaspa:qz7ulu4c25dh'), 'kaspa:qz7u lu4 c25dh');
    });

    test('a colon-less string takes the same rule', () {
      expect(chunkAddress('abcdefgh'), 'abc defgh');
    });

    test('the real 61-character payload ends qunth, not qunt h', () {
      // The exact address and the exact complaint that produced the amendment.
      const addr =
          'kaspa:qz5a8jtqt3l3nf8zxve9eu0qtrkewc5e0yn465djghw4438jqdecc6jzqunth';
      final out = chunkAddress(addr);
      expect(out, endsWith(' c6jz qunth'));
      expect(out, isNot(contains(' qunt h')));
      // Fourteen fours then the five: the short group, when a length produces
      // one, falls NEXT TO the tail rather than splitting it.
      expect(addressPayloadGroups(addr).last, 'qunth');
      expect(addressPayloadGroups(addr).length, 15);
    });

    test('EVERY surface that chunks an address uses this one rule', () {
      // The amendment was ratified for all screens and reached only one of the
      // three implementations, so Receive still rendered the stranded `h` on a
      // build whose Send screen did not. This asserts the seam, not the output:
      // a fourth copy appearing anywhere is what this is written to catch.
      const addr =
          'kaspa:qz5a8jtqt3l3nf8zxve9eu0qtrkewc5e0yn465djghw4438jqdecc6jzqunth';
      expect(KvAddress.groupsOf(addr), addressPayloadGroups(addr));
      expect(
        chunkAddress(addr),
        'kaspa:${addressPayloadGroups(addr).join(' ')}',
      );
      expect(KvAddress.tailGroup, addressTailGroup);
    });
  });
}
