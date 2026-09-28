import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../theme/tokens.dart';
import 'kv_status_chip.dart';

/// §4's five tiers, and the face an absent reading wears — **one value that
/// the figure's hue and the bars both read from**, so the channels cannot be
/// computed differently from one another (BG-7, BG-25).
///
/// **They classify the last ten seconds, not the last probe** (LINK-UX1,
/// D-337): the tier is read off [KvLatencyReading]'s time-weighted ten-second
/// median, with [hysteresis], so the bars and the hue hold still through the
/// jitter a live figure shows and move only when the link has been somewhere
/// else for seconds. On the founder's air (LINK-Q2's 2 h capture, replayed)
/// the ten-second tier flipped 0.05 times a minute against the three-probe
/// tier's 0.17. It also closes D-334's documented gap: the hue no longer
/// leads the gliding figure — it trails it, as a steadier reading of the same
/// measurements. Only the "at least" face overrides it (one bar, the poorest
/// hue, D-333), because a probe that is not answering is not a boundary case.
enum KvLatencyTier {
  fast(bars: 5, tone: KvLampTone.ok, word: 'Fast'),
  good(bars: 4, tone: KvLampTone.ok, word: 'Good'),
  slow(bars: 3, tone: KvLampTone.warn, word: 'Slow'),
  verySlow(bars: 2, tone: KvLampTone.warn, word: 'Very slow'),
  poor(bars: 1, tone: KvLampTone.risk, word: 'Poor'),

  /// No reading at all (BG-8): nothing lit, `inkMeta`. Never a zero, and never
  /// a tier hue borrowed for a measurement nobody has.
  none(bars: 0, tone: null, word: 'No reading');

  const KvLatencyTier({
    required this.bars,
    required this.tone,
    required this.word,
  });

  final int bars;

  /// The lamp tone the tier lights, or null for the face with no reading.
  final KvLampTone? tone;

  /// **Spoken, never drawn** (D-332). The seat's words left the glass — the
  /// bars and their colour carry the reading, with the lit-bar count and the
  /// figure as its two non-colour channels — but a screen reader still hears
  /// the classification the colour shows, so the word lives on in the
  /// reading's semantics label.
  final String word;

  /// The hue every channel of the reading wears.
  Color get hue => tone?.color ?? KvColor.inkMeta;

  /// §4's ladder: a reading under `bounds[i]` is tier `i`, and one at or past
  /// the last is [poor]. `< 60` · `< 150` · `< 300` · `< 500`.
  static const List<int> bounds = <int>[60, 150, 300, 500];

  /// **How far past a boundary a reading has to be before the tier moves.**
  ///
  /// A threshold display that flips at its own boundary is a known defect
  /// with a known cure: Android's signal bars take a `hysteresisDb` (*"to
  /// prevent flapping"*, default 2 dB) and a hold time before a bar changes,
  /// and TCP never reports a raw RTT sample at all (RFC 6298 smooths it at
  /// 1/8). This is that cure at the seat's own scale: a tier is left only when
  /// the reading has cleared the boundary by a tenth of it — `Good` becomes
  /// `Slow` at 165 ms, and `Slow` becomes `Good` again under 135. Since
  /// LINK-UX1 it is applied to the ten-second median, which is the hold time
  /// half of Android's cure.
  static const double hysteresis = 0.10;

  /// The tier a reading lands in with no history — the ladder's letter.
  static KvLatencyTier cold(int ms) {
    for (var i = 0; i < bounds.length; i++) {
      if (ms < bounds[i]) return values[i];
    }
    return poor;
  }
}

/// **One probe's outcome, as the seat keeps it** (D-333): a round trip the
/// node answered, or one that outlasted the probe's deadline — which is not an
/// absence but a lower bound. "At least 1.8 s" is a reading of a slow, live
/// link; the old seat drew it as no link at all, and blinked dark on a socket
/// that never dropped. A refused probe (no socket, an error) is neither, and
/// never becomes a sample.
@immutable
class KvLatencySample {
  /// The node answered in [ms].
  const KvLatencySample.answered(this.ms) : atLeast = false;

  /// No answer inside a deadline of [ms]: the round trip was at least that.
  const KvLatencySample.atLeast(this.ms) : atLeast = true;

  final int ms;

  /// True for a censored sample — a lower bound, not a measurement.
  final bool atLeast;

  @override
  bool operator ==(Object other) =>
      other is KvLatencySample && other.ms == ms && other.atLeast == atLeast;

  @override
  int get hashCode => Object.hash(ms, atLeast);

  @override
  String toString() => atLeast ? '>=${ms}ms' : '${ms}ms';
}

/// **A sample, where it landed in time, and how much time it stands for.**
///
/// The seat's history and every time-weighted statistic read these, never a
/// bare list of samples — because the probe is single-flight, a stall is ONE
/// slow sample where a healthy stretch of the same length is ten fast ones,
/// and a statistic that counts samples under-weighs exactly the stretch the
/// user most needs to see (coordinated omission). Weighted by [span], a 5 s
/// stall is 5 s of the window.
@immutable
class KvLatencyOutcome {
  const KvLatencyOutcome({
    required this.at,
    required this.sample,
    required this.span,
    this.carried = false,
  });

  /// When the outcome landed, on the screen's clock.
  final DateTime at;

  final KvLatencySample sample;

  /// **The stretch of time this outcome stands for** — from the outcome
  /// before it to this one, which is the idle wait for the next poll tick
  /// plus this probe's own round trip. Bounded below by the round trip (the
  /// probe cannot answer sooner than it took) and above by the round trip
  /// plus one [KvLatencyReading.cadence] — a gap the screen was not watching
  /// (backgrounded, covered) is not a stall and must not weigh as one. The
  /// first outcome after a start stands for its own round trip.
  final Duration span;

  /// Measured before this screen opened (stale-while-revalidate, D-333):
  /// drawn in the history, where time places it honestly, and never an input
  /// to the figure, the path or the tier — a carried reading is where the
  /// count starts, never a sample (`ux-auditor`, LINK-Q1).
  final bool carried;

  /// Where the stretch this outcome stands for begins.
  DateTime get from => at.subtract(span);

  KvLatencyOutcome _asCarried() =>
      KvLatencyOutcome(at: at, sample: sample, span: span, carried: true);

  @override
  bool operator ==(Object other) =>
      other is KvLatencyOutcome &&
      other.at == at &&
      other.sample == sample &&
      other.span == span &&
      other.carried == carried;

  @override
  int get hashCode => Object.hash(at, sample, span, carried);

  @override
  String toString() => '$sample@${at.toIso8601String()}/${span.inMilliseconds}';
}

/// **The One Euro filter** (Casiez, Roussel & Vogel, CHI 2012) — a low-pass
/// whose cutoff rises with the signal's own speed, so it is calm at rest and
/// quick on a real move. Immutable, so the reading that holds it stays a value.
///
/// **It never extrapolates.** Each step is `x̂ + α·(x − x̂)` with `α` in
/// `(0, 1]`, so the output is always a blend of what was measured and never
/// lies outside the range of the inputs — the speed only chooses how much of
/// the newest sample to take.
///
/// **Tuned on the founder's air, not chosen** (LINK-Q2's capture, 14,502
/// probes over two hours on his split 2.4 GHz Starlink link, replayed through
/// the seat): the minimum cutoff was lowered, with no speed term, until the
/// figure held still at rest; then [beta] was raised to the knee where the lag
/// on real moves stopped paying for itself in stillness. At these constants,
/// with the display steps and their hold ([KvLatencyReading.stepHold]), the
/// figure changes **~15 times a minute at rest against the three-probe
/// median's 66**, a move of ≥ 80 ms is 90 % covered in 0.93 s (median) and a
/// spike of ≥ 200 ms in 0.25 s (median; 0.86 s p90) — real spikes pass,
/// by design.
@immutable
class KvOneEuro {
  const KvOneEuro._(this.value, this.speed, this.at);

  /// A filter that starts on its first sample, at rest.
  const KvOneEuro.start(double x, this.at) : value = x, speed = 0;

  /// The filtered figure, in ms.
  final double value;

  /// The filtered speed of the figure, in ms per second.
  final double speed;

  /// When [value] was last updated.
  final DateTime at;

  /// The cutoff at rest, in Hz — a time constant of ~8 s.
  static const double minCutoff = 0.02;

  /// How fast the cutoff rises with speed, in Hz per (ms/s).
  static const double beta = 0.01;

  /// The cutoff of the speed's own smoothing, in Hz (the paper's default).
  static const double speedCutoff = 1.0;

  static double _alpha(double cutoff, double dt) {
    final tau = 1 / (2 * math.pi * cutoff);
    return 1 / (1 + tau / dt);
  }

  /// The filter after a sample [x] measured [now]. A clock that did not
  /// advance (a test's fixed clock) is taken as one cadence apart, so the
  /// filter still moves — the step is otherwise undefined.
  KvOneEuro next(double x, DateTime now) {
    var dt = now.difference(at).inMicroseconds / 1e6;
    if (dt <= 0) dt = KvLatencyReading.cadence.inMicroseconds / 1e6;
    final dx = (x - value) / dt;
    final s = speed + _alpha(speedCutoff, dt) * (dx - speed);
    final cutoff = minCutoff + beta * s.abs();
    return KvOneEuro._(value + _alpha(cutoff, dt) * (x - value), s, now);
  }

  @override
  bool operator ==(Object other) =>
      other is KvOneEuro &&
      other.value == value &&
      other.speed == speed &&
      other.at == at;

  @override
  int get hashCode => Object.hash(value, speed, at);
}

/// One column of the history's minute: the time-weighted spread of the
/// answers around it and the path floor under it. All null where nothing
/// answered. (The unanswered stretches are drawn apart, by their own times —
/// [KvLatencyReading.stalls].)
@immutable
class KvLatencyColumn {
  const KvLatencyColumn({
    required this.at,
    this.p10,
    this.p50,
    this.p90,
    this.floor,
  });

  final DateTime at;
  final int? p10;
  final int? p50;
  final int? p90;
  final int? floor;
}

/// **The seat's whole reading, as one immutable value** — pure, and the one
/// place its smoothing lives. Every probe outcome goes in through [offer];
/// what comes out is four things, each for its own job:
///
///  * **The figure** ([milliseconds]): the **median of the last three
///    samples** (a 1.5 s window at the seat's two probes a second, D-332) — so
///    a single spike never takes the readout with it — **then a One Euro
///    filter** ([KvOneEuro], D-337), then **display steps** ([quantize]): 1 ms
///    under 100 ms, 10 ms above, and a step moves only once the filtered value
///    is [stepHold] past the rounding line. The jitter on a public node is
///    ±15 ms, so a single millisecond above 100 is precision the measurement
///    does not have (the research's guardrail).
///  * **"At least"** ([atLeast]): a timeout is its own lower bound in the
///    median (D-333) — it sorts at its deadline, after an answer of the same
///    size — so one slow probe among two answers is outvoted like any spike,
///    and two of three means the link really is that slow. That face is never
///    filtered: it is the bound itself.
///  * **The path** ([pathAt]): the best answer in the last ten seconds —
///    BBR's min-RTT window — the floor this node allows from here right now.
///  * **The tier** ([tier]): the **time-weighted** median of the last ten
///    seconds with [KvLatencyTier.hysteresis], which the bars and the hue read.
///
/// **Smoothing is not holding.** The seat empties the reading only when the
/// socket is down or three probes in a row were refused (D-333's dwell) — the
/// house rule behind the old wipe, *no confident number beside a dead socket*,
/// stands; a slow answer on a live one was never that case.
@immutable
class KvLatencyReading {
  const KvLatencyReading._({
    required List<KvLatencySample> window,
    required List<KvLatencyOutcome> history,
    required KvOneEuro? filter,
    required int? shown,
    required this.tier,
  }) : _window = window,
       _history = history,
       _filter = filter,
       _shown = shown;

  /// No reading — the cold start, and the face after the dwell runs out.
  const KvLatencyReading.none()
    : _window = const <KvLatencySample>[],
      _history = const <KvLatencyOutcome>[],
      _filter = null,
      _shown = null,
      tier = KvLatencyTier.none;

  /// The three-probe median's samples, oldest first.
  final List<KvLatencySample> _window;

  /// Every outcome of the last [historySpan], oldest first.
  final List<KvLatencyOutcome> _history;

  final KvOneEuro? _filter;

  /// The display step the figure rests on, with the step's own hysteresis.
  final int? _shown;

  /// The ten-second tier the bars and the hue read, hysteresis applied.
  final KvLatencyTier tier;

  /// **The seat's cadence: twice a second** (D-332) — the Network screen polls
  /// on it, and it bounds an outcome's [KvLatencyOutcome.span].
  static const Duration cadence = Duration(milliseconds: 500);

  /// How many samples the figure's median is taken over.
  static const int window = 3;

  /// The span the tier's median is weighted over.
  static const Duration tierSpan = Duration(seconds: 10);

  /// The span the path is the best answer of — BBR's min-RTT window.
  static const Duration pathSpan = Duration(seconds: 10);

  /// How much history the seat keeps and draws.
  static const Duration historySpan = Duration(seconds: 60);

  /// Outcomes kept at most — a minute at the cadence, twice over, so a clock
  /// that does not advance (a test's) cannot grow the history without bound.
  static const int historyCap = 240;

  /// **The display step for a figure** — 1 ms under 100, 10 ms above.
  static int step(double ms) => ms < 100 ? 1 : 10;

  /// **How far past the rounding line the figure must be before it steps**,
  /// in steps — a quarter, so a value wandering across the line between two
  /// steps does not flick the figure, and the printed figure is never more
  /// than 7.5 ms from the filtered one. Measured on the founder's capture: a
  /// whole step of hold was calmer (10 changes a minute against 15) and held
  /// a steady 172 ms link at `180` for as long as it stayed there — a
  /// standing 8 ms error the path beside it would have exposed as queueing.
  static const double stepHold = 0.25;

  /// [ms] on the display grid, rounded half away from zero.
  static int quantize(double ms) {
    final s = step(ms);
    return (ms / s).round() * s;
  }

  /// **The path as printed** — floored to its display step, because a floor
  /// is never rounded up, and never above the [figure] printed beside it
  /// (`ux-auditor`, LINK-UX1: rounded half-up against a figure held a
  /// quarter step below its filter, the path printed above node reply 11
  /// times in 6,833 of the founder's readings — `170 ms · PATH 180`, a
  /// negative queue nobody measured). The clamp applies only beside a
  /// reading; beside "at least" the figure is a bound, not a value.
  static int? printedPath(int? path, {int? figure, bool atLeast = false}) {
    if (path == null) return null;
    final s = step(path.toDouble());
    var p = path ~/ s * s;
    if (figure != null && !atLeast && p > figure) p = figure;
    return p;
  }

  KvLatencySample? get _median => _window.isEmpty ? null : _medianOf(_window);

  /// No fresh outcome yet: the cold start, a forgotten node, or a reading that
  /// resumed from a carried one and has not been answered since.
  bool get isEmpty => _window.isEmpty;

  /// The figure to print, in ms — the filtered reading on its display step, or
  /// with [atLeast] the deadline the median outlasted — or null with none.
  int? get milliseconds {
    final median = _median;
    if (median == null) return null;
    return median.atLeast ? median.ms : _shown;
  }

  /// Whether the figure is a lower bound — the median sample timed out.
  bool get atLeast => _median?.atLeast ?? false;

  /// The One Euro filter's output behind the figure, unstepped — for a guard.
  double? get filtered => atLeast ? null : _filter?.value;

  /// The samples behind the median, for a guard to check it against.
  List<KvLatencySample> get samples =>
      List<KvLatencySample>.unmodifiable(_window);

  /// The last minute of outcomes, oldest first — what the history draws.
  List<KvLatencyOutcome> get history =>
      List<KvLatencyOutcome>.unmodifiable(_history);

  /// **The path**: the best answer in the [pathSpan] before [now], or null when
  /// nothing answered in it. Only this screen's own answers count.
  int? pathAt(DateTime now) {
    int? best;
    for (final o in _history) {
      if (o.carried || o.sample.atLeast) continue;
      if (!o.at.isAfter(now.subtract(pathSpan)) || o.at.isAfter(now)) continue;
      if (best == null || o.sample.ms < best) best = o.sample.ms;
    }
    return best;
  }

  /// **The same history, with the rest started again** — for the first fresh
  /// outcome after a carried reading (D-333). The minute stays drawn, marked
  /// carried; the figure, the path and the tier begin empty, so a remembered
  /// median can never stand at full brightness as fresh.
  KvLatencyReading resumed() => KvLatencyReading._(
    window: const <KvLatencySample>[],
    history: [for (final o in _history) o._asCarried()],
    filter: null,
    shown: null,
    tier: KvLatencyTier.none,
  );

  /// The reading after one more probe outcome, landed [at].
  KvLatencyReading offer(KvLatencySample sample, {required DateTime at}) {
    final window = <KvLatencySample>[..._window, sample];
    if (window.length > KvLatencyReading.window) window.removeAt(0);
    final median = _medianOf(window);

    // The span this outcome stands for (see [KvLatencyOutcome.span]).
    final own = Duration(milliseconds: sample.ms);
    final previous = _history.isEmpty ? null : _history.last.at;
    var span = previous == null ? own : at.difference(previous);
    if (span < own) span = own;
    if (span > own + cadence) span = own + cadence;
    final history = <KvLatencyOutcome>[
      for (final o in _history)
        if (o.at.isAfter(at.subtract(historySpan))) o,
      KvLatencyOutcome(at: at, sample: sample, span: span),
    ];
    while (history.length > historyCap) {
      history.removeAt(0);
    }

    // The figure: filtered from the median, and started again whenever the
    // median returns from "at least" — the filter never saw the bound, so
    // easing out of it would be easing out of a number nobody measured.
    KvOneEuro? filter;
    int? shown;
    if (!median.atLeast) {
      final x = median.ms.toDouble();
      final held = _median?.atLeast ?? true ? null : _filter;
      filter = held == null ? KvOneEuro.start(x, at) : held.next(x, at);
      final y = filter.value;
      final prior = held == null ? null : _shown;
      shown = prior == null || (y - prior).abs() >= step(y) * (0.5 + stepHold)
          ? quantize(y)
          : prior;
    }

    // The tier: the time-weighted median of this screen's last ten seconds.
    final recent = [
      for (final o in history)
        if (!o.carried) o,
    ];
    final ten = weightedPercentile(
      recent,
      from: at.subtract(tierSpan),
      to: at,
      q: 0.5,
    )!;
    final tier = ten.atLeast
        ? KvLatencyTier.poor
        : KvLatency.tierFor(ten.ms, held: this.tier);

    return KvLatencyReading._(
      window: window,
      history: history,
      filter: filter,
      shown: shown,
      tier: tier,
    );
  }

  /// **A time-weighted percentile** of the outcomes overlapping `[from, to]`:
  /// each weighs the part of its [KvLatencyOutcome.span] inside the window, a
  /// timeout sorts at its bound after an answer of the same size, and the
  /// answer is the sample at which the cumulative weight first reaches [q].
  /// Null when nothing overlaps. With [answeredOnly] the timeouts are left out
  /// (the history's band, which draws them apart).
  static KvLatencySample? weightedPercentile(
    Iterable<KvLatencyOutcome> outcomes, {
    required DateTime from,
    required DateTime to,
    required double q,
    bool answeredOnly = false,
  }) {
    final weighted = <(KvLatencySample, int)>[];
    var total = 0;
    for (final o in outcomes) {
      if (answeredOnly && o.sample.atLeast) continue;
      final start = o.from.isAfter(from) ? o.from : from;
      final end = o.at.isBefore(to) ? o.at : to;
      var w = end.difference(start).inMicroseconds;
      // An outcome inside the window with no measurable span still counts
      // once: it happened in the window.
      if (w <= 0) {
        if (o.at.isBefore(from) || o.at.isAfter(to)) continue;
        w = 1;
      }
      weighted.add((o.sample, w));
      total += w;
    }
    if (weighted.isEmpty) return null;
    weighted.sort((a, b) => _byBound(a.$1, b.$1));
    final need = q * total;
    var acc = 0;
    for (final (sample, w) in weighted) {
      acc += w;
      if (acc >= need) return sample;
    }
    return weighted.last.$1;
  }

  /// **The history's minute, as [count] columns ending at [now]** — each the
  /// time-weighted p10 / median / p90 of the answers over the [smooth] before
  /// it (SmokePing's median and smoke) and the path floor at that moment.
  ///
  /// **A column is drawn only where something answered inside it**
  /// (`ux-auditor`, LINK-UX1): the windows smooth the values, never the
  /// extent — without the rule the median ran five seconds and the floor nine
  /// into a stretch where nothing answered, under the red mark saying so, and
  /// a carried minute's floor ran on into time the screen was closed.
  ///
  /// **The grid is anchored to whole slices** ([anchor]): hung on `now`
  /// itself, which moves half a second a poll, the sampling phase alternated
  /// and the drawn past reshaped every tick with no new measurement. Anchored,
  /// the minute changes only by a whole column scrolling or by a new outcome.
  /// Memoised per reading and anchor, so the rebuilds between (a probe going
  /// out, the poll clock) reuse it.
  List<KvLatencyColumn> columns(
    DateTime now, {
    int count = 60,
    Duration smooth = const Duration(seconds: 5),
  }) {
    final slice = Duration(microseconds: historySpan.inMicroseconds ~/ count);
    final end = anchor(now, count: count);
    final memo = _columnsMemo[this];
    if (memo != null &&
        memo.$1 == end &&
        memo.$2 == count &&
        memo.$3 == smooth) {
      return memo.$4;
    }
    final start = end.subtract(historySpan);
    final columns = [
      for (var k = 0; k < count; k++)
        () {
          final at = start.add(slice * (k + 1));
          final sliceFrom = at.subtract(slice);
          // Something answered inside this column's own slice?
          final answered = _history.any(
            (o) =>
                !o.sample.atLeast &&
                o.from.isBefore(at) &&
                o.at.isAfter(sliceFrom),
          );
          if (!answered) return KvLatencyColumn(at: at);
          final p = [
            for (final q in const [0.1, 0.5, 0.9])
              weightedPercentile(
                _history,
                from: at.subtract(smooth),
                to: at,
                q: q,
                answeredOnly: true,
              )?.ms,
          ];
          int? floor;
          for (final o in _history) {
            if (o.sample.atLeast) continue;
            if (o.at.isAfter(at) || !o.at.isAfter(at.subtract(pathSpan))) {
              continue;
            }
            if (floor == null || o.sample.ms < floor) floor = o.sample.ms;
          }
          return KvLatencyColumn(
            at: at,
            p10: p[0],
            p50: p[1],
            p90: p[2],
            floor: floor,
          );
        }(),
    ];
    _columnsMemo[this] = (end, count, smooth, columns);
    return columns;
  }

  static final Expando<(DateTime, int, Duration, List<KvLatencyColumn>)>
  _columnsMemo = Expando('KvLatencyReading.columns');

  /// **Where the minute ends: [now] floored to a whole slice** of the
  /// history (a second, at the default sixty columns) — the grid the columns
  /// and the unanswered marks are both drawn on.
  static DateTime anchor(DateTime now, {int count = 60}) {
    final slice = historySpan.inMicroseconds ~/ count;
    final us = now.microsecondsSinceEpoch;
    return DateTime.fromMicrosecondsSinceEpoch(us - us % slice);
  }

  /// **Every unanswered stretch of the minute before [now], by its own
  /// times** — each timeout from when its probe went out (`at − ms`) to when
  /// it gave up, and the probe still out ([waitingSince]) from when it went
  /// out to now, once its wait has passed [KvLatency.liveFrom], because the
  /// elapsed time is a measurement too. Drawn at exactly that width
  /// (`ux-auditor`, LINK-UX1: by whole columns, and from the idle wait before
  /// the probe went out, a 1.8 s timeout marked three seconds).
  List<(DateTime, DateTime)> stalls(DateTime now, {DateTime? waitingSince}) {
    // On the columns' grid ([anchor]), so a mark and the line it interrupts
    // are drawn against one clock.
    final end = anchor(now);
    final start = end.subtract(historySpan);
    DateTime clip(DateTime t) =>
        t.isBefore(start) ? start : (t.isAfter(end) ? end : t);
    return [
      for (final o in _history)
        if (o.sample.atLeast && o.at.isAfter(start))
          (
            clip(o.at.subtract(Duration(milliseconds: o.sample.ms))),
            clip(o.at),
          ),
      if (waitingSince != null &&
          now.difference(waitingSince) >= KvLatency.liveFrom)
        (clip(waitingSince), end),
    ];
  }

  /// Two readings with the same window, history, filter, step and tier ARE
  /// the same reading.
  @override
  bool operator ==(Object other) =>
      other is KvLatencyReading &&
      other.tier == tier &&
      other._shown == _shown &&
      other._filter == _filter &&
      _listEquals(other._window, _window) &&
      _listEquals(other._history, _history);

  @override
  int get hashCode => Object.hash(
    tier,
    _shown,
    _filter,
    Object.hashAll(_window),
    Object.hashAll(_history),
  );

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Equal figures: the censored one is at least that, so it sorts after.
  static int _byBound(KvLatencySample a, KvLatencySample b) {
    final byMs = a.ms.compareTo(b.ms);
    if (byMs != 0) return byMs;
    return (a.atLeast ? 1 : 0).compareTo(b.atLeast ? 1 : 0);
  }

  static KvLatencySample _medianOf(List<KvLatencySample> xs) {
    final sorted = <KvLatencySample>[...xs]..sort(_byBound);
    return sorted[sorted.length ~/ 2];
  }
}

/// **How far away the node is, measured** (`T5`, §4's latency re-spec, as the
/// founder re-ruled it for glass at D-332, D-333 and D-337).
///
/// A round-trip time in milliseconds and a five-bar signal staircase, **both
/// in the tier's own hue**, so the reading survives greyscale, a screen reader
/// and colour-blindness: the number of lit bars and the figure are two
/// non-colour channels behind the hue, and the spoken label keeps the tier's
/// word (BG-7, BG-25). Between them, when the screen gives one, the last
/// minute ([history], [KvLatencyHistory]).
///
/// ## The figure glides on a critically damped spring (LINK-UX1, D-337)
///
/// It replaced D-334's even-paced replay: a new reading pulls the figure on a
/// spring of damping ratio 1 at [glideOmega] — **no overshoot**, so no frame
/// lies outside the range between the figure on the glass and the newest
/// reading (the frames between ARE unmeasured values — motion, D-332, drawn on
/// the display grid, never past either end); **the speed is carried** into the next reading
/// when it lies the same way, so a climb reads as one motion rather than a
/// stutter; and **never past the newest reading** — a carried speed that
/// would cross it stops on it, and one that points away from it is dropped.
/// Settle time was measured against the founder's own probe cadence (p10
/// interval 0.476 s): a typical 100 ms move lands in 0.24 s, the house's
/// `calm` step, and even a 5 s jump inside 0.47 s — so the figure never
/// trails a reading by more than one interval. Reduced motion: a jump.
///
/// ## Its faces
///
/// * **a reading**: `150 ms`, three lit amber bars;
/// * **at least** (D-333): `> 1.8 s`, one lit bar in the poorest hue — and
///   **it counts up live** while the next probe is still out, because the
///   elapsed time is itself a measurement (floored to a tenth, never above
///   what has elapsed);
/// * **measuring…**: the socket is up and nothing has answered yet on this
///   screen — past [liveFrom] with no answer it becomes the counting `> N s`;
/// * **stale** (D-333): the last reading from before the screen opened,
///   dimmed to [KvFreshness.opacityStaleRegion] until the first fresh answer;
/// * **no reading** (BG-8): `—`, every bar unlit, `inkMeta` — the one face
///   that carries no hue, so it reads without colour.
///
/// ## Why this is not `KvCadence` (BG-21)
///
/// [KvCadence] is a **hill that breathes**, animating only while something is
/// genuinely in flight; this is a **rising staircase that does not move**. It
/// reports a measurement, and a staircase that animated would be claiming
/// movement it did not observe (BG-18).
class KvLatency extends StatefulWidget {
  const KvLatency({
    super.key,
    required this.milliseconds,
    this.atLeast = false,
    this.tier,
    this.stale = false,
    this.measuring = false,
    this.waitingSince,
    this.clock = DateTime.now,
    this.path,
    this.history,
  });

  /// The figure, in ms (see [KvLatencyReading.milliseconds]), or null when
  /// there is no reading. With [atLeast] it is the deadline the probe outlasted.
  final int? milliseconds;

  /// The figure is a lower bound (the probe timed out): drawn `> N s`.
  final bool atLeast;

  /// The tier to draw. A seat holding a [KvLatencyReading] passes its
  /// ten-second tier; null classifies the number cold, which is what a preview
  /// or a one-shot reading wants.
  final KvLatencyTier? tier;

  /// The reading predates this screen (stale-while-revalidate, D-333): the
  /// figure, the history and the staircase dim, and the seat's caption says
  /// how old it is.
  ///
  /// **Dimmed to [KvFreshness.opacityStaleRegion], not `opacityStale`, and
  /// that is measured rather than chosen** (L164, recomputed from the hexes on
  /// `plate`): at 0.45 an amber figure is **2.81:1** and a red one **2.18:1**,
  /// under the 3.0 bar even this 40 dp run must clear (BG-14 does not bend),
  /// and the unlit bars fall to 1.93 against 1.4.11's 3.0. At 0.74 the worst
  /// figure is red at **3.88:1** and the unlit ground **3.16:1**. The `ms`
  /// unit is 15 dp — body size — so it does not dim at all (BG-8's own
  /// clause); the caption carries the age.
  final bool stale;

  /// The socket is up and no probe has answered on this screen yet.
  final bool measuring;

  /// When the probe now in flight was sent, on [clock] — the live count's
  /// origin in the "at least" and measuring faces. Null with none out.
  final DateTime? waitingSince;

  /// The clock [waitingSince] is on — the screen's own, so a test can drive it.
  final DateTime Function() clock;

  /// The path, in ms — spoken with the figure. The screen draws it in the
  /// seat's caption.
  final int? path;

  /// The last minute, seated between the figure and the bars.
  final Widget? history;

  /// **How the figure glides** — the spring's natural frequency, rad/s, at
  /// damping ratio 1 ([KvMotion.glide]; the class doc says where it came from).
  static const double glideOmega = KvMotion.glide;

  /// **How long a probe may be out before its wait is the reading** — the
  /// probe deadline's own floor (RFC 6298 §2.4, D-333): no probe can time out
  /// sooner, so before it nothing is unusual yet.
  static const Duration liveFrom = Duration(seconds: 1);

  /// The largest live wait the figure prints. A lower bound may be stated
  /// low, never high, so a longer wait still reads `> 9.9 s` — and the
  /// figure keeps its five characters at the 320 dp / 1.3× floor.
  static const Duration liveCap = Duration(milliseconds: 9900);

  /// `T5`, measured: five bars, each **6 dp** wide with a **4 dp** gap.
  ///
  /// *(v4.17, D-278 — founder on glass 2026-09-05: "the lines are too long so
  /// its not giving a perfect network bar shape yet. make the lines shorter to
  /// the one line that signifies 'poor' connection is the shortest.") The
  /// render's own 24 → 48 read as five tall strokes rather than a staircase,
  /// because the first bar was already half the last. **The shape is in the
  /// ratio, not the height**: 10 → 34 keeps the same 6 dp step in a tenth
  /// less ink and drops the poorest bar under a third of the tallest.*
  static const List<double> barHeights = <double>[10, 16, 22, 28, 34];
  static const double barWidth = 6;
  static const double barGap = 4;

  /// **The unlit tone, and the one place this component does not follow `T5`.**
  ///
  /// The render draws its dark bars at (33, 42, 41) — **1.23:1 on `plate`**.
  /// The unlit bars are what make the reading a *fraction*: without them
  /// "three lit" cannot be read as three **of five**, so they are meaningful
  /// non-text content and owe WCAG 1.4.11's 3:1 floor. `etch` does not clear
  /// it (2.35 on `plate`), so the staircase's ground is `inkMeta` at **4.75**.
  /// A picture cannot encode an accessibility requirement (the QR quiet-zone
  /// precedent); D-259 governs design, not function.
  static const Color unlit = KvColor.inkMeta;

  /// The meter's own extent, derived from the bars rather than asserted
  /// (item 0 / L121).
  static double get height => barHeights.last;
  static double get width =>
      barHeights.length * barWidth + (barHeights.length - 1) * barGap;

  /// **Which tier a reading lights** — §4's ladder, with [KvLatencyTier
  /// .hysteresis] applied against the tier currently [held].
  ///
  /// Cold (no [held], or nothing held), the ladder's letter answers. Otherwise
  /// the tier moves only when the reading has cleared the boundary between
  /// the held tier and its neighbour by the margin — and when it has, it lands
  /// wherever the reading actually is, so a genuine jump from 60 to 400 ms
  /// crosses two tiers at once rather than one per probe.
  static KvLatencyTier tierFor(int? ms, {KvLatencyTier? held}) {
    if (ms == null) return KvLatencyTier.none;
    final raw = KvLatencyTier.cold(ms);
    if (held == null || held == KvLatencyTier.none || raw == held) return raw;
    if (raw.index > held.index) {
      // Slower: clear the boundary just above the held tier by the margin.
      final boundary = KvLatencyTier.bounds[held.index];
      return ms >= boundary * (1 + KvLatencyTier.hysteresis) ? raw : held;
    }
    // Faster: undercut the boundary just below the held tier by the margin.
    final boundary = KvLatencyTier.bounds[held.index - 1];
    return ms < boundary * (1 - KvLatencyTier.hysteresis) ? raw : held;
  }

  /// A deadline in seconds, **floored** to a tenth and always printed with it:
  /// `> N s` is a lower bound, and rounding it up would claim a wait the probe
  /// never measured; the tenth always shows, so a counting figure keeps its
  /// width (`> 2.0`, not `> 2`).
  static String seconds(int ms) {
    final tenths = ms ~/ 100;
    return '${tenths ~/ 10}.${tenths % 10}';
  }

  /// **One step of the glide** — the exact solution of a critically damped
  /// spring from position [p] and speed [v] toward [target] over [dt] seconds,
  /// with the guardrail applied: a step that would cross the target stops on
  /// it. Pure, so the no-overshoot claim is provable without a frame.
  static (double, double) glide(double p, double v, double target, double dt) {
    final a = p - target;
    if (a == 0) return (target, 0);
    const w = glideOmega;
    final b = v + w * a;
    final e = math.exp(-w * dt);
    final np = target + (a + b * dt) * e;
    final nv = (b - w * (a + b * dt)) * e;
    if ((np - target) * a <= 0) return (target, 0);
    return (np, nv);
  }

  /// The sentence a screen reader hears — the whole reading at once, with the
  /// tier's word the glass no longer draws (§11: never digit soup).
  static String spoken(
    int? ms, {
    required bool atLeast,
    KvLatencyTier? tier,
    bool measuring = false,
    int? path,
  }) {
    final floor = path == null
        ? ''
        : path >= 1000
        ? ' Path ${seconds(path)} seconds.'
        : ' Path $path milliseconds.';
    if (ms == null) {
      return measuring ? 'Node reply: measuring.' : 'Node reply: no reading.';
    }
    if (atLeast) {
      return 'Node reply: at least ${seconds(ms)} seconds. '
          '${KvLatencyTier.poor.word}.$floor';
    }
    return 'Node reply $ms milliseconds. '
        '${(tier ?? tierFor(ms)).word}.$floor';
  }

  @override
  State<KvLatency> createState() => _KvLatencyState();
}

class _KvLatencyState extends State<KvLatency>
    with SingleTickerProviderStateMixin {
  /// Runs only while a probe's wait is on the glass, and rebuilds only when
  /// the printed tenth changes.
  late final Ticker _wait = createTicker(_onWait);
  int? _tenths;

  /// **The staircase, reused until it changes.** A probe rebuilds this seat
  /// twice a second and the bars change about once in twenty minutes (0.05
  /// tier flips a minute on the founder's capture): handing the framework
  /// the SAME widget lets it skip the six elements of an unchanged staircase
  /// (the V4 seam law, `rebuild_scope_test`).
  _Bars? _bars;

  _Bars _staircase(int lit, Color hue) {
    final bars = _bars;
    if (bars != null && bars.lit == lit && bars.hue == hue) return bars;
    return _bars = _Bars(lit: lit, hue: hue);
  }

  bool get _counting =>
      widget.waitingSince != null && (widget.atLeast || widget.measuring);

  Duration? get _elapsed {
    final since = widget.waitingSince;
    if (since == null) return null;
    final d = widget.clock().difference(since);
    return d.isNegative ? Duration.zero : d;
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(KvLatency old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (_counting && !_wait.isActive) {
      _wait.start();
    } else if (!_counting && _wait.isActive) {
      _wait.stop();
    }
  }

  void _onWait(Duration _) {
    final t = (_elapsed?.inMilliseconds ?? 0) ~/ 100;
    if (t != _tenths) setState(() => _tenths = t);
  }

  @override
  void dispose() {
    _wait.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final elapsed = _counting ? _elapsed : null;
    // The live wait as a bound: floored to a tenth, capped (see [liveCap]).
    int? live;
    if (elapsed != null) {
      final ms = math.min(
        elapsed.inMilliseconds,
        KvLatency.liveCap.inMilliseconds,
      );
      live = ms ~/ 100 * 100;
    }
    final measuringLive =
        w.measuring && live != null && elapsed! >= KvLatency.liveFrom;
    final atLeast = w.atLeast || measuringLive;
    final int? ms = measuringLive
        ? live
        : w.atLeast && live != null && w.milliseconds != null
        ? math.max(w.milliseconds!, live)
        : w.milliseconds;
    final measuring = w.measuring && !measuringLive;
    final tier = measuring || ms == null
        ? KvLatencyTier.none
        : atLeast
        ? KvLatencyTier.poor
        : (w.tier ?? KvLatency.tierFor(ms));
    final figureStyle = TextStyle(
      fontFamily: KvFont.mono,
      // `amountScreen`-scale (§4). `T5`'s digits measure 29.0 dp of cap —
      // 37.5 at Jakarta's ratio, 39.2 at the mono one — and the named role's
      // 40 is inside that measurement's own error (BG-21).
      fontSize: 40,
      height: 44 / 40,
      fontWeight: FontWeight.w700,
      fontVariations: KvWeight.w700,
      color: tier.hue,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final unitStyle = TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 15,
      height: 20 / 15,
      color: tier.hue,
    );
    final Widget figure = switch ((ms, atLeast, measuring)) {
      // **A word, in Jakarta, at the unit's size** (BG-30): nothing has been
      // measured yet, so there is no figure to set in the counting face.
      (_, _, true) => Text(
        'measuring…',
        style: unitStyle.copyWith(color: KvColor.inkMeta),
        // **The figure's line box, not the word's**: forced to the figure's
        // strut, the row keeps its 44 dp and its baseline, so the card does
        // not step when the first answer replaces the word (seen in the
        // frame — without it the card rose ten dp and dropped back).
        strutStyle: StrutStyle.fromTextStyle(
          figureStyle,
          forceStrutHeight: true,
        ),
      ),
      (null, _, _) => Text('—', style: figureStyle),
      (final int bound, true, _) => Text(
        '> ${KvLatency.seconds(bound)}',
        style: figureStyle,
      ),
      (final int value, false, _) => _GlidingFigure(
        target: value,
        builder: (context, shown) => Text('$shown', style: figureStyle),
      ),
    };
    final dim = w.stale ? KvFreshness.opacityStaleRegion : 1.0;
    // Eased, never cut: the first fresh answer lifts a carried reading's dim
    // over the house's calm step, in step with its caption leaving (BG-24).
    final ease = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : KvMotion.calm;
    Widget dimmed(Widget child) => AnimatedOpacity(
      opacity: dim,
      duration: ease,
      curve: KvMotion.curve,
      child: child,
    );
    final Widget face = AnimatedSwitcher(
      duration: ease,
      switchInCurve: KvMotion.curve,
      switchOutCurve: KvMotion.curve,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topLeft,
        children: [...previous, ?current],
      ),
      child: Row(
        key: ValueKey(
          measuring
              ? 'measuring'
              : ms == null
              ? 'dash'
              : atLeast
              ? 'bound'
              : 'value',
        ),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          dimmed(figure),
          if (ms != null && !measuring) ...[
            const SizedBox(width: KvSpace.xs),
            // **Jakarta, because a unit is a word beside a figure and
            // not a figure** (BG-30 / §2). Body size, so it never dims
            // (BG-8).
            Text(atLeast ? 's' : 'ms', style: unitStyle),
          ],
        ],
      ),
    );
    return Semantics(
      label: KvLatency.spoken(
        measuring ? null : ms,
        atLeast: atLeast,
        tier: tier,
        measuring: measuring,
        path: w.path,
      ),
      excludeSemantics: true,
      child: Row(
        // **The staircase and the history stand on the figure's baseline**
        // (D-332): both report their own bottom as their baseline, and the
        // row aligns baselines — never the row's bottom, below the digits'
        // descent.
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          // The figure takes its own width, always: it is the reading. The
          // widest face is `> 9.9 s`, five mono characters, which clears the
          // 320 dp / 1.3× floor beside the staircase (see [liveCap]).
          //
          // **A change of face is eased, never cut** (BG-24, `ux-auditor`):
          // *measuring…* giving way to the first figure, a figure to `> N s`,
          // either to `—` — the figure and its unit cross-fade as one over the
          // house's `calm` step. Within a face nothing is switched: a value
          // glides (its spring keeps its state under one key) and a bound
          // counts. Both faces share the figure's line box, so the fade never
          // moves the row.
          // **And the room the face takes is eased with it** (BG-24,
          // `ux-auditor`): the switcher holds the wider face through its
          // fade, so without this the history beside it lost or regained its
          // room in one frame — at the floor, 0 ↔ ~60 dp.
          // Under reduced motion there is nothing to ease — and an
          // `AnimatedSize` given no time completes inside its own layout and
          // re-dirties itself, so it is not there at all then.
          ease == Duration.zero
              ? face
              : AnimatedSize(
                  duration: ease,
                  curve: KvMotion.curve,
                  alignment: Alignment.centerLeft,
                  child: face,
                ),
          // **The history takes what the figure leaves, up to its own width,
          // and sits against the staircase** — one instrument cluster on the
          // right, the reading on the left. Its gaps are inside it, so where
          // the figure leaves nothing it takes nothing (the floor, `> 5.0 s`).
          Flexible(
            child: Align(
              alignment: Alignment.bottomRight,
              // Its own height, always: without the factor an `Align` given a
              // bounded height fills it, and the instrument would stand as
              // tall as whatever parent bounded it (a test host did: 600 dp).
              heightFactor: 1,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  if (w.history case final history?)
                    // One box: a `SizedBox` wider than the room a `Flexible`
                    // gives it is clamped to that room, so this is the
                    // history's own width up to [preferredWidth] with no
                    // wrapper doing it twice (the V4 seam law counts every
                    // element a probe rebuilds, `rebuild_scope_test`).
                    Flexible(
                      child: _BottomBaseline(
                        // **Never dimmed** — a history is a record with its
                        // own time axis, BG-8's ledger-row reason: a carried
                        // stretch already says how old it is by where it
                        // stands, and the region dim would take the band under
                        // 3:1 (0.72 × 0.74 of `inkMeta` is ~2.2:1 on `plate`).
                        child: SizedBox(
                          width: KvLatencyHistory.preferredWidth,
                          height: KvLatency.height,
                          child: history,
                        ),
                      ),
                    )
                  else
                    const SizedBox(width: KvSpace.s),
                  _BottomBaseline(
                    child: dimmed(_staircase(tier.bars, tier.hue)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// **A figure that glides to its reading on a critically damped spring**
/// (LINK-UX1, D-337) — see [KvLatency]'s class doc. It appears AT its first
/// value (it never counts out of nothing, or out of "at least"); every change
/// after pulls it with [KvLatency.glide], the speed carried toward the new
/// value and dropped when it points away; the frames between are drawn on the
/// display grid ([KvLatencyReading.quantize]), so a glide counts in the same
/// steps the figure rests on. Under reduced motion the figure simply becomes
/// the new value.
class _GlidingFigure extends StatefulWidget {
  const _GlidingFigure({required this.target, required this.builder});

  final int target;
  final Widget Function(BuildContext context, int shown) builder;

  @override
  State<_GlidingFigure> createState() => _GlidingFigureState();
}

class _GlidingFigureState extends State<_GlidingFigure>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);

  /// Where the figure is. Set in [initState], never lazily: a `late` field
  /// first read in [didUpdateWidget] would initialise from the NEW target and
  /// the figure would jump instead of gliding (the suite caught it).
  double _p = 0;
  double _v = 0;
  Duration? _last;

  @override
  void initState() {
    super.initState();
    _p = widget.target.toDouble();
  }

  @override
  void didUpdateWidget(_GlidingFigure old) {
    super.didUpdateWidget(old);
    if (widget.target == old.target) return;
    final target = widget.target.toDouble();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _ticker.stop();
      _p = target;
      _v = 0;
      return;
    }
    // **Carry the speed only toward the newest reading** — a speed that
    // points away from it would take the figure past it, to a value nobody
    // measured (the guardrail).
    if ((target - _p) * _v < 0) _v = 0;
    if (!_ticker.isActive) {
      _last = null;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final last = _last;
    _last = elapsed;
    if (last == null) return;
    final dt = (elapsed - last).inMicroseconds / 1e6;
    if (dt <= 0) return;
    final target = widget.target.toDouble();
    final (p, v) = KvLatency.glide(_p, _v, target, dt);
    setState(() {
      _p = p;
      _v = v;
    });
    // At rest within a hundredth of a millisecond: stop on the reading itself.
    if ((target - p).abs() < 0.01) {
      _p = target;
      _v = 0;
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.target;
    final shown = _ticker.isActive ? KvLatencyReading.quantize(_p) : target;
    return widget.builder(context, shown);
  }
}

/// **The last minute of the reading, word-sized** (Tufte's sparkline; LINK-UX1,
/// D-337) — the median as a line, the p10–p90 spread as a faint band around
/// it, the path floor as a faint line under it, and every unanswered stretch
/// in the poorest hue along the top edge. **x is time, not sample count**: a
/// 5 s stall is 5 s wide, and a screen opened 20 s ago has 40 s of nothing on
/// the left. The spread is time-weighted, so a stall is not under-sampled.
///
/// **Neutral ink** — information is colourless (BG-7): the line `ink`, the
/// band and the floor `inkMeta`, and one hue, `risk`, for a wait with no
/// answer, because that is the poorest reading there is. No end dot: a dot in
/// the tier's hue sat at the last ANSWER, which in a stall is seconds old and
/// fast, and it was the live dot's shape with a second meaning (`ux-auditor`).
///
/// **Every mark clears WCAG 1.4.11's 3:1, measured from the hexes on
/// `plate`**: the band (`inkMeta` at [bandAlpha]) **3.06:1**, the median line
/// on the band **5.40:1**, the floor line **4.75:1**, the unanswered mark
/// **6.14:1**. A first cut drew the band at 0.28 (1.46:1) with an `inkDim`
/// line and called it texture on the claim that no fill could reach 3:1
/// without dragging the line under it; with the line in `ink` that claim is
/// false (`ux-auditor`), and the floor does not bend (BG-14).
///
/// Where the figure leaves it narrower than [minWidth] it draws nothing: the
/// reading is the figure, and a sliver of chart is not a history.
class KvLatencyHistory extends StatelessWidget {
  const KvLatencyHistory({
    super.key,
    required this.reading,
    required this.now,
    this.waitingSince,
  });

  final KvLatencyReading reading;

  /// The right edge — the screen's poll clock, so the minute scrolls on the
  /// cadence the readings arrive on and never on its own.
  final DateTime now;

  final DateTime? waitingSince;

  /// The widest the history grows; the figure and the staircase keep theirs.
  static const double preferredWidth = 140;

  /// Narrower than this, nothing is drawn.
  static const double minWidth = 28;

  /// The band's `inkMeta` alpha — the least that clears 3:1 on `plate`.
  static const double bandAlpha = 0.72;

  /// The narrowest spread the vertical scale shows, in ms — so a flat link
  /// reads flat rather than as its own jitter magnified to the full height.
  static const int minRange = 40;

  /// Its air on each side, painted inside its own box rather than laid out
  /// around it — the gap to the figure and to the staircase.
  static const double inset = KvSpace.s;

  // No semantics of its own: a `CustomPaint` without a builder adds none,
  // and on the card the instrument speaks for the whole reading.
  @override
  Widget build(BuildContext context) {
    final start = KvLatencyReading.anchor(
      now,
    ).subtract(KvLatencyReading.historySpan);
    final span = KvLatencyReading.historySpan.inMicroseconds;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _HistoryPainter(
          columns: reading.columns(now),
          stalls: [
            for (final (from, to) in reading.stalls(
              now,
              waitingSince: waitingSince,
            ))
              (
                from.difference(start).inMicroseconds / span,
                to.difference(start).inMicroseconds / span,
              ),
          ],
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _HistoryPainter extends CustomPainter {
  _HistoryPainter({required this.columns, required this.stalls});

  final List<KvLatencyColumn> columns;

  /// Each unanswered stretch as fractions of the minute, left to right.
  final List<(double, double)> stalls;

  @override
  void paint(Canvas canvas, Size box) {
    const inset = KvLatencyHistory.inset;
    final size = Size(box.width - 2 * inset, box.height);
    if (size.width < KvLatencyHistory.minWidth) return;
    canvas.translate(inset, 0);
    const stallStroke = 2.0;
    // The unanswered stretches, along the top edge, at their own widths —
    // butt caps, so a mark is never wider than the time it stands for.
    final stall = Paint()
      ..color = KvColor.risk
      ..strokeWidth = stallStroke
      ..strokeCap = StrokeCap.butt;
    for (final (from, to) in stalls) {
      canvas.drawLine(
        Offset(from * size.width, stallStroke / 2),
        Offset(to * size.width, stallStroke / 2),
        stall,
      );
    }
    int? lo;
    int? hi;
    for (final c in columns) {
      for (final v in [c.p10, c.floor]) {
        if (v != null && (lo == null || v < lo)) lo = v;
      }
      if (c.p90 != null && (hi == null || c.p90! > hi)) hi = c.p90;
    }
    if (lo == null || hi == null) return;
    // The scale: the minute's own spread, at least [minRange] tall, centred.
    if (hi - lo < KvLatencyHistory.minRange) {
      final mid = (hi + lo) / 2;
      lo = (mid - KvLatencyHistory.minRange / 2).floor();
      hi = (mid + KvLatencyHistory.minRange / 2).ceil();
    }
    final n = columns.length;
    double x(int k) => (k + 0.5) / n * size.width;
    final top = stallStroke + 2;
    final bottom = size.height - 1;
    double y(int v) => bottom - (v - lo!) / (hi! - lo) * (bottom - top);

    final band = Paint()
      ..color = KvColor.inkMeta.withValues(alpha: KvLatencyHistory.bandAlpha);
    final median = Paint()
      ..color = KvColor.ink
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final floor = Paint()
      ..color = KvColor.inkMeta
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    // The band, p90 across and p10 back, and the line over it — one run per
    // stretch of answers, broken where nothing answered.
    var k = 0;
    while (k < n) {
      if (columns[k].p50 == null) {
        k++;
        continue;
      }
      final start = k;
      while (k < n && columns[k].p50 != null) {
        k++;
      }
      final run = [for (var i = start; i < k; i++) i];
      final area = Path()..moveTo(x(run.first), y(columns[run.first].p90!));
      for (final i in run.skip(1)) {
        area.lineTo(x(i), y(columns[i].p90!));
      }
      for (final i in run.reversed) {
        area.lineTo(x(i), y(columns[i].p10!));
      }
      canvas.drawPath(area..close(), band);
      final line = Path()..moveTo(x(run.first), y(columns[run.first].p50!));
      for (final i in run.skip(1)) {
        line.lineTo(x(i), y(columns[i].p50!));
      }
      canvas.drawPath(line, median);
    }
    // The path floor: a step line, faint — it is the ground, not the reading.
    // One path per run of columns that have a floor, drawn once.
    final ground = Path();
    var open = false;
    for (var i = 0; i < n; i++) {
      final f = columns[i].floor;
      if (f == null) {
        open = false;
        continue;
      }
      final left = i / n * size.width;
      final right = (i + 1) / n * size.width;
      if (open) {
        ground.lineTo(left, y(f));
      } else {
        ground.moveTo(left, y(f));
        open = true;
      }
      ground.lineTo(right, y(f));
    }
    canvas.drawPath(ground, floor);
  }

  @override
  bool shouldRepaint(_HistoryPainter old) {
    if (old.columns.length != columns.length ||
        old.stalls.length != stalls.length) {
      return true;
    }
    for (var i = 0; i < stalls.length; i++) {
      if (old.stalls[i] != stalls[i]) return true;
    }
    for (var i = 0; i < columns.length; i++) {
      final a = old.columns[i];
      final b = columns[i];
      if (a.p10 != b.p10 ||
          a.p50 != b.p50 ||
          a.p90 != b.p90 ||
          a.floor != b.floor) {
        return true;
      }
    }
    return false;
  }
}

/// Reports its own bottom edge as its baseline, so a baseline-aligned row
/// seats a non-text child ON the text's baseline rather than at the row's top.
class _BottomBaseline extends SingleChildRenderObjectWidget {
  const _BottomBaseline({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBottomBaseline();
}

class _RenderBottomBaseline extends RenderProxyBox {
  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => size.height;

  @override
  double? computeDryBaseline(
    covariant BoxConstraints constraints,
    TextBaseline baseline,
  ) => getDryLayout(constraints).height;
}

/// The staircase. **Never eased and never animated**: it is an instrument, and
/// the reading is the ink (BG-22, BG-18).
class _Bars extends StatelessWidget {
  const _Bars({required this.lit, required this.hue});

  final int lit;
  final Color hue;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: KvLatency.height,
    width: KvLatency.width,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < KvLatency.barHeights.length; i++) ...[
          if (i > 0) const SizedBox(width: KvLatency.barGap),
          Container(
            width: KvLatency.barWidth,
            height: KvLatency.barHeights[i],
            decoration: BoxDecoration(
              color: i < lit ? hue : KvLatency.unlit,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ],
    ),
  );
}
