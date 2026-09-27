import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../theme/tokens.dart';
import 'kv_status_chip.dart';

/// §4's five tiers, and the face an absent reading wears — **one value that
/// the figure's hue and the bars both read from**, so the channels cannot be
/// computed differently from one another (BG-7, BG-25). They are the MEASURED
/// reading's: while the figure replays toward a new reading (D-226's glide,
/// v4.45) the hue and the bars already show it, leading the figure by at most
/// one interval (≤ [KvMotion.replayCap]) and agreeing with it on every
/// measured value — never drawn from a frame between two. LINK-UX1 moves the
/// bars onto a steadier median and the glide onto a critically damped spring
/// (D-337), which shortens the lead.
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
  /// A probe is one round trip, and a round trip jitters. A node whose true
  /// distance is about 150 ms therefore read `Good` and `Slow` on alternate
  /// probes — green bars, amber bars, green — which is the instrument
  /// flapping, not the link changing. A threshold display that flips at its
  /// own boundary is a known defect with a known cure: Android's signal bars
  /// take a `hysteresisDb` (*"to prevent flapping"*, default 2 dB) and a hold
  /// time before a bar changes, and TCP never reports a raw RTT sample at all
  /// (RFC 6298 smooths it at 1/8). This is that cure at the seat's own scale:
  /// a tier is left only when the reading has cleared the boundary by a tenth
  /// of it — `Good` becomes `Slow` at 165 ms, and `Slow` becomes `Good` again
  /// under 135. Twice a second (D-332) it matters twice as much.
  ///
  /// **The number stays honest.** The figure printed beside the tier is a
  /// sample the node actually answered (see [KvLatencyReading]); the tier is
  /// the classification, and a classification that changes only on a real
  /// move is what the ladder was for.
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

/// **A stable reading from a jittery probe** — pure, immutable, and the one
/// place the seat's smoothing lives.
///
///  * The **figure** is the **median of the last three samples** — a 1.5 s
///    window at the seat's two probes a second (D-332). It is therefore always
///    a number the node actually answered, or a deadline it actually outlasted
///    — nothing is modelled, averaged or predicted — and a single spike does
///    not take the readout with it. With two samples the median is the slower
///    one, the side the user would rather be warned about.
///  * **A timeout is its own lower bound in the median** (D-333). It sorts at
///    its deadline — after an answer of the same size, since it is at least
///    that — so one slow probe among two answers is outvoted like any spike,
///    and two of three means the link really is that slow: the figure reads
///    `> N s`, the tier [KvLatencyTier.poor].
///  * The **tier** carries [KvLatencyTier.hysteresis], so it moves when the
///    link moves and not when the noise does.
///
/// **Smoothing is not holding.** The seat empties the window only when the
/// socket is down or three probes in a row were refused (D-333's dwell) — the
/// house rule behind the old wipe, *no confident number beside a dead socket*,
/// stands; a slow answer on a live one was never that case.
@immutable
class KvLatencyReading {
  const KvLatencyReading._(this._samples, this.tier);

  /// No reading — the cold start, and the face after the dwell runs out.
  const KvLatencyReading.none()
    : _samples = const <KvLatencySample>[],
      tier = KvLatencyTier.none;

  /// Oldest first, at most [window] of them.
  final List<KvLatencySample> _samples;

  /// The tier the seat is showing, hysteresis applied.
  final KvLatencyTier tier;

  /// How many samples the median is taken over.
  static const int window = 3;

  KvLatencySample? get _median => _samples.isEmpty ? null : _medianOf(_samples);

  /// The figure to print, in ms: the median of the window, or null with no
  /// sample. When [atLeast] is true it is a deadline, printed as `> N s`.
  int? get milliseconds => _median?.ms;

  /// Whether the figure is a lower bound — the median sample timed out.
  bool get atLeast => _median?.atLeast ?? false;

  /// The samples behind the figure, for a guard to check the median against.
  List<KvLatencySample> get samples =>
      List<KvLatencySample>.unmodifiable(_samples);

  /// The reading after one more probe outcome.
  KvLatencyReading offer(KvLatencySample sample) {
    final next = <KvLatencySample>[..._samples, sample];
    if (next.length > window) next.removeAt(0);
    final median = _medianOf(next);
    return KvLatencyReading._(
      next,
      median.atLeast
          // "At least" the deadline is the poorest reading there is: one bar,
          // the poorest hue (D-333). Its own tier, not a hysteresis step — a
          // link that is not answering is not a boundary case.
          ? KvLatencyTier.poor
          : KvLatency.tierFor(median.ms, held: tier),
    );
  }

  /// Two readings with the same window and tier ARE the same reading, so a
  /// steady link offering the same answer twice a second notifies nobody —
  /// the seat rebuilds when the reading changes, not when the poll does.
  @override
  bool operator ==(Object other) =>
      other is KvLatencyReading &&
      other.tier == tier &&
      _listEquals(other._samples, _samples);

  @override
  int get hashCode => Object.hash(tier, Object.hashAll(_samples));

  static bool _listEquals(List<KvLatencySample> a, List<KvLatencySample> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static KvLatencySample _medianOf(List<KvLatencySample> xs) {
    final sorted = <KvLatencySample>[...xs]
      ..sort((a, b) {
        final byMs = a.ms.compareTo(b.ms);
        if (byMs != 0) return byMs;
        // Equal figures: the censored one is at least that, so it sorts after.
        return (a.atLeast ? 1 : 0).compareTo(b.atLeast ? 1 : 0);
      });
    return sorted[sorted.length ~/ 2];
  }
}

/// **How far away the node is, measured** (`T5`, §4's latency re-spec, as the
/// founder re-ruled it for glass at D-332 and D-333).
///
/// A round-trip time in milliseconds and a five-bar signal staircase, **both
/// in the tier's own hue**, so the reading survives greyscale, a screen reader
/// and colour-blindness: the number of lit bars and the figure are two
/// non-colour channels behind the hue, and the spoken label keeps the tier's
/// word (BG-7, BG-25).
///
/// ## What D-332 changed, and why it is not decoration
///
/// * **The figure counts.** A new reading is reached by counting through the
///   integers between the two — up or down, always coming to rest on the
///   measured value. The frames in between are motion, not readings: nothing
///   moves on its own, and a reading that does not change does not move. It
///   replaced a rolling odometer that turned digits over, which read as the
///   number being swapped rather than the link moving. Tabular figures, so the
///   width never shimmies while it counts.
/// * **It streams, the way the DAA count does** (D-226's law, on the
///   founder's glass 2026-09-27): the first count after the figure appears
///   (on open, or back from `—` or `> N s`) takes [countFor]; every change
///   after it REPLAYS the interval since the change before, at an even pace,
///   capped at [replayCap]. Readings arrive once per
///   round trip — twice a second on a good link, every 1–5 s on a bad one — so
///   a quarter-second count left the figure frozen between them and then
///   jumping ("pauses, then boom"). Replayed, it is still gliding toward the
///   latest measurement when the next one lands. The price is D-226's own,
///   stated: the figure trails the newest reading by up to one interval, never
///   more than [replayCap], and every frame lies within the readings measured
///   so far (between the two it moves between, or — a count cut short by a
///   newer reading — between the frame it had reached and the newest).
/// * **No tier words.** The bars and their colour carry the reading; the word
///   is spoken, not drawn (`T5` drew it; the founder's glass ruling supersedes
///   the render for this seat — the D-278 precedent).
/// * **The staircase stands on the figure's baseline**, not on the row's
///   bottom below the digits' descent.
///
/// ## Why this is not `KvCadence`, and the Bible was amended rather than the
/// widget bent to fit it
///
/// §4's v4.10 Cadence row read *"now reads latency, not liveness"*, which
/// would have folded this into [KvCadence]. Built against `T5` that turned out
/// to be two objects wearing one name, and BG-21 forbids exactly that:
/// [KvCadence] is a **hill that breathes** — bars 6·10·14·10·6, animating only
/// while something is genuinely in flight — and this is a **rising staircase
/// that does not move**. It reports a measurement, and a staircase that
/// animated would be claiming movement it did not observe (BG-18).
///
/// ## The four faces
///
/// * a reading: `151 ms`, three lit amber bars;
/// * **at least** (D-333): `> 1.8 s`, one lit bar in the poorest hue — the
///   probe's deadline passed on a live link;
/// * **stale** (D-333, stale-while-revalidate): the last reading from before
///   the screen opened, shown at once with the seat's age beside it and
///   dimmed to [KvFreshness.opacityStaleRegion] until the first fresh answer
///   lands, when it counts to it;
/// * **no reading** (BG-8): `—`, every bar unlit, `inkMeta` — the one face
///   that carries no hue, so it reads without colour.
class KvLatency extends StatelessWidget {
  const KvLatency({
    super.key,
    required this.milliseconds,
    this.atLeast = false,
    this.tier,
    this.stale = false,
  });

  /// The measured round trip, or null when there is no reading. With
  /// [atLeast] it is the deadline the probe outlasted.
  final int? milliseconds;

  /// The figure is a lower bound (the probe timed out): drawn `> N s`.
  final bool atLeast;

  /// The tier to draw. A seat holding a [KvLatencyReading] passes its tier so
  /// the hysteresis it carries reaches the glass; null classifies the number
  /// cold, which is what a preview or a one-shot reading wants.
  final KvLatencyTier? tier;

  /// The reading predates this screen (stale-while-revalidate, D-333): the
  /// figure and the staircase dim, and the seat's caption says how old it is.
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

  /// How long the figure's FIRST count takes after it appears — BG-9's middle
  /// step, the founder's "~250 ms" (D-332). Every later change replays the
  /// interval since the one before (see the class doc), never faster.
  static const Duration countFor = KvMotion.calm;

  /// The longest interval a change is replayed over — [KvMotion.replayCap].
  static const Duration replayCap = KvMotion.replayCap;

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

  /// A deadline in seconds, **floored** to a tenth: `> N s` is a lower bound,
  /// and rounding it up would claim a wait the probe never measured.
  static String seconds(int ms) {
    final tenths = ms ~/ 100;
    return tenths % 10 == 0
        ? '${tenths ~/ 10}'
        : '${tenths ~/ 10}.${tenths % 10}';
  }

  /// The sentence a screen reader hears — the whole reading at once, with the
  /// tier's word the glass no longer draws (§11: never digit soup).
  static String spoken(int? ms, {required bool atLeast, KvLatencyTier? tier}) {
    if (ms == null) return 'Connection latency: no reading.';
    if (atLeast) {
      return 'Connection latency: at least ${seconds(ms)} seconds. '
          '${KvLatencyTier.poor.word}.';
    }
    return 'Connection latency $ms milliseconds. '
        '${(tier ?? tierFor(ms)).word}.';
  }

  @override
  Widget build(BuildContext context) {
    final ms = milliseconds;
    final tier = ms == null
        ? KvLatencyTier.none
        : atLeast
        ? KvLatencyTier.poor
        : (this.tier ?? tierFor(ms));
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
    final Widget figure = switch ((ms, atLeast)) {
      (null, _) => Text('—', style: figureStyle),
      (final int deadline, true) => Text(
        '> ${seconds(deadline)}',
        style: figureStyle,
      ),
      (final int value, false) => _CountingFigure(
        value: value,
        builder: (context, shown) => Text('$shown', style: figureStyle),
      ),
    };
    final dim = stale ? KvFreshness.opacityStaleRegion : 1.0;
    // Eased, never cut: the first fresh answer lifts a carried reading's dim
    // over the house's calm step, in step with its caption leaving (BG-24).
    final ease = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : KvMotion.calm;
    return Semantics(
      label: spoken(ms, atLeast: atLeast, tier: tier),
      excludeSemantics: true,
      child: Row(
        // **The staircase stands on the figure's baseline** (D-332). The row
        // used to align its children to its own bottom — the bottom of the
        // figure's line box, the digits' descent below them — so the bars
        // stood lower than the number they reported. The bars now report
        // their own bottom as their baseline, and the row aligns baselines.
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: AnimatedOpacity(
                    opacity: dim,
                    duration: ease,
                    curve: KvMotion.curve,
                    child: figure,
                  ),
                ),
                const SizedBox(width: KvSpace.xs),
                // **Jakarta, because a unit is a word beside a figure and not
                // a figure** (BG-30 / §2). Body size, so it never dims (BG-8).
                Text(
                  ms != null && atLeast ? 's' : 'ms',
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 15,
                    height: 20 / 15,
                    color: tier.hue,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: KvSpace.s),
          _BottomBaseline(
            child: AnimatedOpacity(
              opacity: dim,
              duration: ease,
              curve: KvMotion.curve,
              child: _Bars(lit: tier.bars, hue: tier.hue),
            ),
          ),
        ],
      ),
    );
  }
}

/// **A figure that counts to its reading** (D-332) — from the value it was
/// showing to the new one, through the integers between, resting exactly on
/// the new value. The first count takes [KvLatency.countFor] on the house
/// curve (BG-9); every later one replays the interval since the change before,
/// at an even pace, up to [KvLatency.replayCap] (D-226's law — see
/// [KvLatency]). A value that does not change starts nothing; under reduced
/// motion the figure simply becomes the new value.
class _CountingFigure extends StatefulWidget {
  const _CountingFigure({required this.value, required this.builder});

  final int value;
  final Widget Function(BuildContext context, int shown) builder;

  @override
  State<_CountingFigure> createState() => _CountingFigureState();
}

class _CountingFigureState extends State<_CountingFigure>
    with SingleTickerProviderStateMixin {
  late final AnimationController _count = AnimationController(
    vsync: this,
    duration: KvLatency.countFor,
    value: 1,
  );
  late int _from = widget.value;
  late int _to = widget.value;

  /// The frame time of the last change — where the interval the next change
  /// replays begins. Null until the first change: that one has no interval.
  Duration? _changedAt;

  /// This motion is a replay (an even pace across the interval), not the
  /// first count (the house curve).
  bool _replay = false;

  int get _shown {
    if (_count.value >= 1) return _to;
    final t = _replay ? _count.value : KvMotion.curve.transform(_count.value);
    return (_from + (_to - _from) * t).round();
  }

  @override
  void didUpdateWidget(_CountingFigure old) {
    super.didUpdateWidget(old);
    if (widget.value == _to) return;
    // Frame time, not the wall clock: it is the clock the glide is drawn on,
    // and the one a test's pumps advance.
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    final interval = _changedAt == null ? null : now - _changedAt!;
    _changedAt = now;
    // Count from wherever the eye is now — a reading that lands mid-count
    // continues from the frame on screen, never jumping back to the old value.
    _from = _shown;
    _to = widget.value;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _count.value = 1;
      return;
    }
    _replay = interval != null;
    _count.duration = interval == null
        ? KvLatency.countFor
        : interval < KvLatency.countFor
        ? KvLatency.countFor
        : interval > KvLatency.replayCap
        ? KvLatency.replayCap
        : interval;
    _count.forward(from: 0);
  }

  @override
  void dispose() {
    _count.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _count,
    builder: (context, _) => widget.builder(context, _shown),
  );
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
