import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **A test may not depend on the machine's timezone** (L173, 2026-09-06).
///
/// The app stamps wall clocks in **local time** by design — `formatStamp`'s own
/// doc says so, and it is the right choice: a receipt shows the user the hour
/// they were in. That makes any test which pairs a **bare epoch constant** with
/// a **hard-coded wall clock** an assertion about the author's timezone rather
/// than about the code.
///
/// It is the worst shape of green a suite can have. The transaction detail's
/// stamp test paired `1788058080000` with `'03:48'`; that is true at UTC+1 and
/// false everywhere else, so it passed on the machine that wrote it and failed
/// **every CI run for a day** — eight consecutive reds that read as "the gate
/// is broken" rather than "one fixture is". The local gate cannot see it,
/// because the local gate runs in the local zone.
///
/// **The fix is a shape, not a value**: build the fixture from
/// `DateTime(y, m, d, h, min)` and take `.millisecondsSinceEpoch`. A local
/// `DateTime` round-trips through local formatting to the same wall clock in
/// every zone, which is what `send_flow_test.dart` already did and what the
/// three fixtures that did not now do.
///
/// This guard is the cheap half. The other half is that the wrap now checks CI
/// after it pushes, because a green local gate is not a green CI.
void main() {
  test('no test file carries a bare epoch-millisecond constant', () {
    // **A 13-digit literal in a TIMESTAMP seat**, not any long number: a
    // balance of 12,345 KAS is `1234500000000` sompi and has nothing to do
    // with a clock. The seat is what makes it a timestamp, so the guard reads
    // the field name beside the literal rather than the literal alone — which
    // is also why it fired on two sompi amounts the first time it ran, and why
    // the second test below pins both halves.
    final epochish = RegExp(
      r'(unixtime\w*|acceptedUnixMs|\w*UnixMs|millisecondsSinceEpoch)'
      r'[^\n]*\b1\d{12}\b',
      caseSensitive: false,
    );
    final offenders = <String>[];
    for (final file
        in Directory('test')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      // This file quotes one in its own doc, which is the point of it.
      if (file.path.endsWith('timezone_guard_test.dart')) continue;
      final source = file.readAsStringSync();
      for (final line in source.split('\n')) {
        // A doc line explaining the trap is not the trap.
        if (line.trimLeft().startsWith('//') ||
            line.trimLeft().startsWith('///')) {
          continue;
        }
        if (epochish.hasMatch(line)) {
          offenders.add('${file.path}: ${line.trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'a bare epoch-millisecond constant in a test is a timezone-bound '
          'fixture waiting to happen: the app formats wall clocks in LOCAL '
          'time, so the same constant prints a different hour on the CI runner '
          'than on the machine that wrote the expectation. Build it from '
          'DateTime(y, m, d, h, min).millisecondsSinceEpoch instead, which '
          'round-trips to the same wall clock in every zone (L173).\n'
          '${offenders.join('\n')}',
    );
  });

  test('and the guard would have caught the one that got through', () {
    // The falsification: the pattern must match the literal that shipped red,
    // or this guard is decoration. `1788058080000` is the constant the
    // transaction detail paired with '03:48'.
    final epochish = RegExp(
      r'(unixtime\w*|acceptedUnixMs|\w*UnixMs|millisecondsSinceEpoch)'
      r'[^\n]*\b1\d{12}\b',
      caseSensitive: false,
    );
    expect(
      epochish.hasMatch('unixtimeMsec: BigInt.from(1788058080000),'),
      true,
    );
    expect(
      epochish.hasMatch('acceptedUnixMs: BigInt.from(1788085010103),'),
      true,
    );
    // The shape that is CORRECT must not trip it.
    expect(
      epochish.hasMatch(
        'unixtimeMsec: BigInt.from(DateTime(2026, 8, 30, 3, 48).millisecondsSinceEpoch),',
      ),
      false,
      reason: 'a fixture built from a local DateTime is the fix, not the fault',
    );
    // And it must NOT match the things a wallet legitimately writes long.
    for (final safe in const [
      'BigInt.parse("458174059")', // a DAA score
      'mature: BigInt.from(1234500000000)', // 12,345 KAS in sompi
      'BigInt.parse("2900000000000000000")', // the whole supply, nineteen
      'Duration(milliseconds: 250)',
    ]) {
      expect(
        epochish.hasMatch(safe),
        false,
        reason: '$safe is not a timestamp and must not trip the guard',
      );
    }
  });
}
