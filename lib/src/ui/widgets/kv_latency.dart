import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_breath.dart';
import 'kv_rolling_text.dart';
import 'kv_status_chip.dart';

/// §4's five tiers, and the face an absent reading wears — **one value that
/// the number, the word, the dot and the bars all read from**, so the four
/// channels cannot be computed differently from one another (BG-7, BG-25).
enum KvLatencyTier {
  fast(bars: 5, tone: KvLampTone.ok, word: 'Fast'),
  good(bars: 4, tone: KvLampTone.ok, word: 'Good'),
  slow(bars: 3, tone: KvLampTone.warn, word: 'Slow'),
  verySlow(bars: 2, tone: KvLampTone.warn, word: 'Very slow'),
  poor(bars: 1, tone: KvLampTone.risk, word: 'Poor'),

  /// No reading at all (BG-8): nothing lit, `inkMeta`, and the word says so.
  /// Never a zero, and never a tier hue borrowed for a measurement nobody has.
  none(bars: 0, tone: null, word: 'No reading');

  const KvLatencyTier({
    required this.bars,
    required this.tone,
    required this.word,
  });

  final int bars;

  /// The lamp tone the tier lights, or null for the face with no reading —
  /// which draws a ringless `inkMeta` disc, because an unlit lamp would still
  /// be a lamp.
  final KvLampTone? tone;
  final String word;

  /// The hue every channel of the reading wears.
  Color get hue => tone?.color ?? KvColor.inkMeta;

  /// §4's ladder: a reading under `bounds[i]` is tier `i`, and one at or past
  /// the last is [poor]. `< 60` · `< 150` · `< 300` · `< 500`.
  static const List<int> bounds = <int>[60, 150, 300, 500];

  /// **How far past a boundary a reading has to be before the tier moves.**
  ///
  /// A probe is one round trip every couple of seconds, and a round trip
  /// jitters. A node whose true distance is about 150 ms therefore read
  /// `Good` and `Slow` on alternate probes — green bars, amber bars, green —
  /// which is the instrument flapping, not the link changing. A threshold
  /// display that flips at its own boundary is a known defect with a known
  /// cure: Android's signal bars take a `hysteresisDb` (*"to prevent
  /// flapping"*, default 2 dB) and a hold time before a bar changes, and TCP
  /// never reports a raw RTT sample at all (RFC 6298 smooths it at 1/8). This
  /// is that cure at the seat's own scale: a tier is left only when the reading
  /// has cleared the boundary by a tenth of it — `Good` becomes `Slow` at
  /// 165 ms, and `Slow` becomes `Good` again under 135.
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

/// **A stable reading from a jittery probe** — pure, immutable, and the one
/// place the seat's smoothing lives.
///
/// Two things, both stated so a reader can check them against BG-8 and BG-18:
///
///  * The **figure** is the **median of the last three samples**. It is
///    therefore always a number the node actually answered — nothing is
///    modelled, averaged or predicted — and a single spike (a GC pause on the
///    node, a Wi-Fi retransmit) does not take the readout with it. With two
///    samples the median is the slower one, which errs on the side the user
///    would rather be warned about.
///  * The **tier** carries [KvLatencyTier.hysteresis], so it moves when the
///    link moves and not when the noise does.
///
/// A probe that fails clears everything ([offer] with `null`): a stale figure
/// beside a dead socket is the confidently-wrong-number BG-8 exists to prevent,
/// and smoothing must never become holding.
@immutable
class KvLatencyReading {
  const KvLatencyReading._(this._samples, this.tier);

  /// No reading — the cold start and the face after a failed probe.
  const KvLatencyReading.none()
    : _samples = const <int>[],
      tier = KvLatencyTier.none;

  /// Oldest first, at most [window] of them.
  final List<int> _samples;

  /// The tier the seat is showing, hysteresis applied.
  final KvLatencyTier tier;

  /// How many samples the median is taken over.
  static const int window = 3;

  /// The figure to print: the median of the window, or null with no sample.
  int? get milliseconds => _samples.isEmpty ? null : _median(_samples);

  /// The samples behind the figure, for a guard to check the median against.
  List<int> get samples => List<int>.unmodifiable(_samples);

  /// The reading after one more probe. `null` — the node did not answer — is
  /// not a sample, it is the absence of one, and it empties the window.
  KvLatencyReading offer(int? sample) {
    if (sample == null) return const KvLatencyReading.none();
    final next = <int>[..._samples, sample];
    if (next.length > window) next.removeAt(0);
    return KvLatencyReading._(
      next,
      KvLatency.tierFor(_median(next), held: tier),
    );
  }

  static int _median(List<int> xs) {
    final sorted = <int>[...xs]..sort();
    return sorted[sorted.length ~/ 2];
  }
}

/// **How far away the node is, measured** (`T5`, §4's latency re-spec).
///
/// A round-trip time in milliseconds, the tier it falls in, a dot, and a
/// five-bar signal staircase — **all four in the tier's own hue**, so the
/// reading survives greyscale, a screen reader and colour-blindness with three
/// redundant channels behind the number (BG-7, BG-25).
///
/// ## Why this is not `KvCadence`, and the Bible is amended rather than the
/// widget bent to fit it
///
/// §4's v4.10 Cadence row reads *"now reads latency, not liveness"*, which
/// would fold this into [KvCadence]. Built against `T5` that turns out to be
/// two objects wearing one name, and BG-21 forbids exactly that:
///
///  * [KvCadence] is a **hill that breathes** — bars 6·10·14·10·6, all five
///    alive, animating only while something is genuinely in flight. It reports
///    *waiting*, and it is the app's one loading indicator (three seats: the
///    money screen's hunt, the node screen's hunt, the ceremony's broadcast).
///  * This is a **rising staircase that does not move** — bars 24→48 in steps
///    of 6, measured off `T5`, with as many lit as the reading earns. It
///    reports *a measurement*, and a measurement that animated would be
///    claiming movement it did not observe (BG-18).
///
/// One name for both would have made the loading meter and the instrument
/// indistinguishable in the tree, which is the seam BG-21 exists to close. So
/// §4 gains a second row instead, and `KvCadence` keeps the job it is good at.
///
/// ## The tiers are §4's, and the render agrees with them
///
/// `< 60` five `ok` · `< 150` four `ok` · `< 300` three `warn` · `< 500` two
/// `warn` · else one `risk`. `T5` draws **151 ms with three amber bars and the
/// word `Slow`**, which is the `< 300` band exactly — the law and the picture
/// were checked against each other rather than one being assumed. What the
/// second beat added is [KvLatencyTier.hysteresis] at the boundaries, so a
/// reading hovering at one does not flap between two faces.
///
/// **An absent reading is its own face** (BG-8). `null` is `— ms`, the word
/// `No reading`, an unlit staircase and the `inkMeta` tone: never a zero, and
/// never the last number still standing at full brightness.
class KvLatency extends StatelessWidget {
  const KvLatency({super.key, required this.milliseconds, this.tier});

  /// The measured round trip, or null when the node did not answer.
  final int? milliseconds;

  /// The tier to draw. A seat holding a [KvLatencyReading] passes its tier so
  /// the hysteresis it carries reaches the glass; null classifies the number
  /// cold, which is what a preview or a one-shot reading wants.
  final KvLatencyTier? tier;

  /// `T5`, measured: five bars 24 · 30 · 36 · 42 · 48 dp, each **6 dp** wide
  /// with a **4 dp** gap (bar edges at 300.5 · 310 · 320 · 330 · 340).
  ///
  /// §4 transcribed these as `12→36`; the render is the original and wins
  /// (D-259), so the law is corrected to the picture rather than the picture
  /// halved to the law.
  /// *(v4.17, D-278 — founder on glass 2026-09-05: "the lines are too long so
  /// its not giving a perfect network bar shape yet. make the lines shorter to
  /// the one line that signifies 'poor' connection is the shortest.") The
  /// render's own 24 → 48 read as five tall strokes rather than a staircase,
  /// because the first bar was already half the last. **The shape is in the
  /// ratio, not the height**: 10 → 34 keeps the same 6 dp step count in a
  /// tenth less ink and drops the poorest bar to under a third of the tallest,
  /// which is what makes a staircase read as one.*
  static const List<double> barHeights = <double>[10, 16, 22, 28, 34];
  static const double barWidth = 6;
  static const double barGap = 4;

  /// **The unlit tone, and the one place this component does not follow `T5`.**
  ///
  /// The render draws its two dark bars at (33, 42, 41) — **1.23:1 on `plate`**,
  /// measured off the PNG. The unlit bars are what make the reading a
  /// *fraction*: without them "three lit" cannot be read as three **of five**,
  /// so they are meaningful non-text content and owe WCAG 1.4.11's 3:1 floor.
  /// `etch` does not clear it either (2.35 on `plate`, 2.53 on `abyss` — the
  /// "3.04" this project's own comments carried was simply wrong, recomputed at
  /// UX-R3), so the staircase's ground is `inkMeta` at **4.75**.
  ///
  /// This is the QR quiet-zone precedent (§4): **a picture cannot encode an
  /// accessibility requirement**, and D-259 governs design, not function. The
  /// reading stays easy to take at a glance — the lit bars are 9.14 (`warn`)
  /// and 10.10 (`ok`), roughly double, and carry a hue the ground does not.
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

  @override
  Widget build(BuildContext context) {
    final ms = milliseconds;
    final tier = this.tier ?? tierFor(ms);
    return Semantics(
      label: ms == null
          ? 'Connection latency: no reading.'
          : 'Connection latency $ms milliseconds. ${tier.word}.',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  // **The digits turn over rather than blinking** (D-271,
                  // L163). A latency re-answers every couple of seconds with a
                  // different three-digit number, which is the seat
                  // [KvRollingText] was built for and the one the founder asked
                  // for next: *"it would be honed and improved in future"*.
                  child: KvRollingText(
                    ms == null ? '—' : '$ms',
                    style: TextStyle(
                      fontFamily: KvFont.mono,
                      // `amountScreen`-scale (§4). `T5`'s digits measure 29.0 dp
                      // of cap — 37.5 at Jakarta's ratio, 39.2 at the mono one —
                      // and the named role's 40 is inside that measurement's own
                      // error. A named role beats a bespoke number the next
                      // reader has to look up (BG-21).
                      fontSize: 40,
                      height: 44 / 40,
                      fontWeight: FontWeight.w700,
                      fontVariations: KvWeight.w700,
                      color: tier.hue,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: KvSpace.xs),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    // **Jakarta, because `ms` is a word beside a figure and not
                    // a figure** (BG-30 / §2). Mono is for digits and
                    // identifiers; a unit label set in it borrows the figure's
                    // face without being one (`ux-auditor`, UX-R3).
                    'ms',
                    style: TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 15,
                      height: 20 / 15,
                      color: tier.hue,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: KvSpace.s),
          _Bars(lit: tier.bars, hue: tier.hue),
        ],
      ),
    );
  }
}

/// The tier word and its dot — `T5` sets them at the head of the card, opposite
/// the caps label, in the same hue as the figure below.
///
/// It is separate from [KvLatency] because the render puts the two on different
/// rows, and one widget that had to be split across a `Row` boundary would only
/// be a layout constraint pretending to be a component.
class KvLatencyWord extends StatelessWidget {
  const KvLatencyWord({super.key, required this.milliseconds, this.tier});

  final int? milliseconds;

  /// See [KvLatency.tier]: the seat's held tier, or null to classify cold.
  final KvLatencyTier? tier;

  @override
  Widget build(BuildContext context) {
    final tier = this.tier ?? KvLatency.tierFor(milliseconds);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // **The dot breathes only while there is a reading to breathe about.**
        // [KvBreath] freezes to a static full-opacity dot under reduced motion,
        // which is what keeps a frozen meter from being mistaken for a running
        // one (BG-8) — the same contract [KvCadence] keeps.
        // **A lamp, as `T5` draws it** — the tier dot sampled off the render
        // is an `ok`/`warn` disc inside its tint ring, §4's `KvLamp`, not a
        // bare disc (`ux-auditor` item 33). No reading is no lamp.
        KvBreath(
          active: milliseconds != null,
          child: switch (tier.tone) {
            final tone? => KvLamp(tone),
            null => Container(
              width: KvLamp.size,
              height: KvLamp.size,
              decoration: const BoxDecoration(
                color: KvColor.inkMeta,
                shape: BoxShape.circle,
              ),
            ),
          },
        ),
        const SizedBox(width: KvSpace.s),
        Text(
          tier.word,
          maxLines: 1,
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 15,
            height: 20 / 15,
            fontWeight: FontWeight.w600,
            fontVariations: KvWeight.w600,
            color: tier.hue,
          ),
        ),
      ],
    );
  }
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
