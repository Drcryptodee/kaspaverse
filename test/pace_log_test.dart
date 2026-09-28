import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/services/pace_log.dart';

/// **The chain's average pace** (D-342) — the `BPS` row's right side, kept by
/// `ChainService` off the score it already receives.
void main() {
  final t0 = DateTime(2026, 9, 28, 12);

  /// Ten blocks a second, sampled every [every] for [over].
  KvPaceLog feed({
    Duration over = const Duration(minutes: 5),
    Duration every = const Duration(milliseconds: 250),
    double bps = 10,
    KvPaceLog? into,
    DateTime? from,
    int score = 1000000,
  }) {
    final log = into ?? KvPaceLog();
    final start = from ?? t0;
    for (var t = Duration.zero; t <= over; t += every) {
      log.record(start.add(t), score + (t.inMicroseconds / 1e6 * bps).floor());
    }
    return log;
  }

  test('it says nothing until two minutes of chain exist — under that the '
      'endpoints\' timing is the decimal it would print', () {
    final log = feed(over: const Duration(seconds: 110));
    expect(log.average(), isNull);
    feed(
      into: log,
      from: t0.add(const Duration(seconds: 110)),
      over: const Duration(seconds: 20),
      score: 1000000 + 1100,
    );
    expect(log.average(), isNotNull);
  });

  test('the average is the score\'s climb over the time between, over the '
      'span it covers', () {
    final avg = feed(over: const Duration(minutes: 12)).average()!;
    expect(avg.bps, closeTo(10, 0.01));
    expect(avg.span, const Duration(minutes: 12));
  });

  test('it rolls: past an hour it is the last hour, never the whole '
      'session', () {
    // Two hours: the first at 5 blocks a second, the second at 10.
    final log = feed(over: const Duration(hours: 1), bps: 5);
    feed(
      into: log,
      from: t0.add(const Duration(hours: 1, milliseconds: 250)),
      over: const Duration(hours: 1),
      score: 1000000 + 5 * 3600,
    );
    final avg = log.average()!;
    expect(avg.span, KvPaceLog.span, reason: 'capped at the hour');
    expect(
      avg.bps,
      closeTo(10, 0.05),
      reason: 'the first hour has left the window',
    );
  });

  test('it keeps a sample every ten seconds at most — an hour is ~361 '
      'entries, whatever the stream\'s rate', () {
    final log = feed(over: const Duration(hours: 2));
    // The kept list is private; its bound shows in the average's span, which
    // could not be one hour if old samples were not being dropped, and in
    // this: a second log fed the same hour at 60 Hz agrees to the decimal.
    final dense = feed(
      over: const Duration(hours: 1),
      every: const Duration(milliseconds: 16),
    );
    expect(log.average()!.span, KvPaceLog.span);
    expect(
      dense.average()!.bps.toStringAsFixed(1),
      log.average()!.bps.toStringAsFixed(1),
    );
  });

  test('a node a few blocks behind keeps the window; a count that falls '
      'far is another count, and starts again', () {
    final log = feed(over: const Duration(minutes: 10));
    final end = t0.add(const Duration(minutes: 10, seconds: 1));
    // A swap to a node 5 blocks behind: still the same chain.
    log.record(end, 1000000 + 6010 - 5);
    expect(log.average(), isNotNull);
    // A node 10,000 blocks behind: not a pace — the window starts again.
    log.record(end.add(const Duration(seconds: 1)), 1000000 + 6000 - 10000);
    expect(log.average(), isNull);
  });

  test('a stall or a background spell inside the window changes nothing — '
      'the score counts every block whether or not the app saw it arrive', () {
    final log = feed(over: const Duration(minutes: 5));
    // Nothing for ten minutes (backgrounded), then the chain where it is.
    final back = t0.add(const Duration(minutes: 15));
    log.record(back, 1000000 + 15 * 60 * 10);
    expect(log.average()!.bps, closeTo(10, 0.01));
  });

  test('a gap longer than the span starts the window again — "1 hour avg" is '
      'never printed over nine hours', () {
    final log = feed(over: const Duration(hours: 1));
    // Eight hours in the background, then five minutes back.
    final back = t0.add(const Duration(hours: 9));
    feed(
      into: log,
      from: back,
      over: const Duration(minutes: 5),
      score: 1000000 + 9 * 3600 * 10,
    );
    final avg = log.average()!;
    expect(avg.span, const Duration(minutes: 5), reason: 'the new window');
    expect(avg.bps, closeTo(10, 0.01));
  });

  test('a gap shorter than the hour never stretches "1 h" past the hour — '
      'the label shrinks to the span actually covered', () {
    // An hour connected, thirty minutes away, then thirty-five back: the
    // sample from before the gap is over an hour old by then.
    final log = feed(over: const Duration(hours: 1));
    final back = t0.add(const Duration(minutes: 90));
    feed(
      into: log,
      from: back,
      over: const Duration(minutes: 35),
      score: 1000000 + 90 * 60 * 10,
    );
    final avg = log.average()!;
    expect(
      avg.span,
      lessThanOrEqualTo(KvPaceLog.span),
      reason: 'never an hour and a half under a one-hour label',
    );
    expect(avg.span, const Duration(minutes: 35), reason: 'the span covered');
    expect(avg.bps, closeTo(10, 0.01));
  });

  test('past the hour it reads the hour on every poll — a jittered '
      'cadence never flickers the label to 59 m', () {
    // Snapshots 250 ms apart plus 0–100 ms of jitter, deterministic.
    final log = KvPaceLog();
    var t = t0;
    var score = 1000000;
    var seed = 7;
    int next() => seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    var polls = 0;
    var shortOnes = 0;
    var lastPoll = t0;
    while (t.isBefore(t0.add(const Duration(hours: 2)))) {
      final step = Duration(milliseconds: 250 + next() % 101);
      t = t.add(step);
      score += (step.inMicroseconds / 1e5).round();
      log.record(t, score);
      // The screen polls twice a second.
      if (t.difference(lastPoll) >= const Duration(milliseconds: 500)) {
        lastPoll = t;
        if (t.isAfter(t0.add(const Duration(hours: 1, minutes: 1)))) {
          polls++;
          if (log.average()!.span != KvPaceLog.span) shortOnes++;
        }
      }
    }
    expect(polls, greaterThan(5000));
    expect(shortOnes, 0, reason: '$shortOnes of $polls polls read short');
  });

  test('a clock that did not advance adds nothing', () {
    final log = feed(over: const Duration(minutes: 3));
    final before = log.average()!;
    log.record(t0.add(const Duration(minutes: 3)), 999999999);
    expect(log.average()!.bps, before.bps);
  });
}
