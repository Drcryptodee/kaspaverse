import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_breath.dart';
import 'kv_rolling_text.dart';

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
/// ## The tiers are §4's, unchanged, and the render agrees with them
///
/// `< 60` five `ok` · `< 150` four `ok` · `< 300` three `warn` · `< 500` two
/// `warn` · else one `risk`. `T5` draws **151 ms with three amber bars and the
/// word `Slow`**, which is the `< 300` band exactly — the law and the picture
/// were checked against each other rather than one being assumed.
///
/// **An absent reading is its own face** (BG-8). `null` is `— ms`, the word
/// `No reading`, an unlit staircase and the `inkMeta` tone: never a zero, and
/// never the last number still standing at full brightness.
class KvLatency extends StatelessWidget {
  const KvLatency({super.key, required this.milliseconds});

  /// The measured round trip, or null when the node did not answer.
  final int? milliseconds;

  /// `T5`, measured: five bars 24 · 30 · 36 · 42 · 48 dp, each **6 dp** wide
  /// with a **4 dp** gap (bar edges at 300.5 · 310 · 320 · 330 · 340).
  ///
  /// §4 transcribed these as `12→36`; the render is the original and wins
  /// (D-259), so the law is corrected to the picture rather than the picture
  /// halved to the law.
  static const List<double> barHeights = <double>[24, 30, 36, 42, 48];
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

  /// **How many bars a reading lights, and the hue it lights them in** — §4's
  /// ladder, in one pure function so the number, the word, the dot and the
  /// bars cannot be computed differently from one another.
  static ({int bars, Color hue, String word}) tierFor(int? ms) {
    if (ms == null) {
      return (bars: 0, hue: KvColor.inkMeta, word: 'No reading');
    }
    if (ms < 60) return (bars: 5, hue: KvColor.ok, word: 'Fast');
    if (ms < 150) return (bars: 4, hue: KvColor.ok, word: 'Good');
    if (ms < 300) return (bars: 3, hue: KvColor.warn, word: 'Slow');
    if (ms < 500) return (bars: 2, hue: KvColor.warn, word: 'Very slow');
    return (bars: 1, hue: KvColor.risk, word: 'Poor');
  }

  @override
  Widget build(BuildContext context) {
    final ms = milliseconds;
    final tier = tierFor(ms);
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
  const KvLatencyWord({super.key, required this.milliseconds});

  final int? milliseconds;

  @override
  Widget build(BuildContext context) {
    final tier = KvLatency.tierFor(milliseconds);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // **The dot breathes only while there is a reading to breathe about.**
        // [KvBreath] freezes to a static full-opacity dot under reduced motion,
        // which is what keeps a frozen meter from being mistaken for a running
        // one (BG-8) — the same contract [KvCadence] keeps.
        KvBreath(
          active: milliseconds != null,
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: tier.hue, shape: BoxShape.circle),
          ),
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
