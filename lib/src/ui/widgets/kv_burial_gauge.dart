import 'package:flutter/material.dart';

import '../../rust/api/wallet.dart';
import '../format.dart';
import '../theme/tokens.dart';
import 'kv_burial_mark.dart';
import 'kv_chrome.dart';
import 'kv_status_chip.dart';
import 'kv_streaming_count.dart';

/// **The burial gauge — the instrument register the balance gave up** (D-191),
/// and the transaction detail's whole reason to exist.
///
/// Kaspa runs at about ten blocks a second, so the hundred DAA a payment waits
/// to become spendable is a ten-second event and a coinbase's thousand about a
/// hundred seconds. Both are watchable, which is what makes a live gauge a
/// feature here rather than a spinner.
///
/// ## The scale, and what it measures (BG-22 as amended by D-248/D-249)
///
/// **Linear, `0 → ceiling`, and the ceiling is the pin's own threshold for this
/// row** — [KvMaturity.userDaa] normally, [KvMaturity.coinbaseDaa] when the row
/// is a mined coinbase. The track runs **inside the `Accepted` rung** and
/// measures progress toward *spendable*: a real quantity the wallet reads every
/// second, and the honest referent the old scale never had.
///
/// ```
///   0                    50                   100
///   ├────┼────┼────┼────┼─┼──┼────┼────┼────┼────┤
///        every 5 short · every 10 medium · ends and midpoint tall
/// ```
///
/// **What this replaces, and why the replacement is not a simplification.**
/// The shipped gauge was a piecewise-linear `0 · 10 · 100 · 1,000` ruler, and
/// D-248 removed the thousand rung on the argument that *"past 100 nothing
/// changes again"*. `consensus-auditor` caught that as false and D-249 recorded
/// it: between 100 and 1,000 a **coinbase output matures and becomes
/// spendable**. So the thousand is not deleted — it is *conditional*, and the
/// condition is `is_coinbase`. A gauge that does not branch is a defect, not a
/// simplification: a coinbase at 150 would fill its track and claim spendable
/// over money wallet-core still excludes from the balance.
///
/// ## The ink is the reading
///
/// The fill is a **rectangle**, not a stroked line, so it has no cap to paint
/// past the value it reports — the defect that added 4.21% of the circle to
/// every reading of the sign ring. Its extent is computed from the **depth**
/// and from nothing else: [positionFor] is a pure function of an integer and a
/// ceiling, the crossfade controller drives colour and never geometry, and
/// there is no curve anywhere on the path from a reading to a width. A gauge is
/// never eased, in either direction (BG-22, BG-9's one exception). The guard
/// measures the **painted ink** through a spy canvas rather than the value the
/// code handed the painter (L145).
///
/// ## One fact, two registers, one implementation
///
/// [KvBurialMark] renders this same chain fact in a ledger row. Both read their
/// rung arithmetic and words from [KvBurial] and their thresholds from the same
/// [KvMaturity], so the two cannot drift into disagreeing about one number
/// (BG-21 / L143) — and this widget renders **its own** words rather than
/// embedding the mark, because a second [KvStreamingCount] would start a second
/// tween and the number beside the gauge could differ from the number the gauge
/// was drawn at.
///
/// ## What rebuilds, and what does not (UX-R3, second beat)
///
/// The streamed depth changes every frame of a crossing, and only the reading
/// line and the painted track depend on it — so only they sit inside the
/// stream's builder. The graduations depend on the ceiling alone and are built
/// once beside it; the screen-reader sentence is built from the **newest**
/// reading rather than the streamed one, because the assistive reader wants
/// where the money is, not where the animation is.
class KvBurialGauge extends StatefulWidget {
  const KvBurialGauge({
    super.key,
    required this.stalled,
    required this.confirmations,
    required this.maturity,
    required this.direction,
    required this.isCoinbase,
    required this.thresholds,
    this.heading,
    this.stale = false,
  });

  /// The section label, laid out on the **same row** as the reading — `S9`
  /// draws `DEPTH` at the plate's left edge and `1,240 blocks deep` hard right,
  /// on one line. It is the gauge's own row rather than the plate's, so the
  /// axis name and the number it names cannot drift apart (BG-22 wants a named
  /// axis; one widget owning both is what keeps the naming true).
  ///
  /// A string rather than a widget, so the row can **measure** it: at 320 dp
  /// and 1.3× the label and the reading do not both fit, and a section label
  /// is chrome that never breaks a word — `DEPT / H` was found in the floor
  /// frame (UX-R3, second beat). The row stacks instead, keeping the reading's
  /// right edge, exactly as `KvFactLine` does.
  final String? heading;

  /// The tracker has seen no acceptance for this submit past the stall
  /// threshold — a fault, not a depth (see [KvBurial.rungFor]).
  final bool stalled;

  /// The observed depth, or null when there is none to be had (BG-8).
  final int? confirmations;

  final MaturityState maturity;

  /// One `MaturityState` means different things on a spend and on a receive —
  /// see [KvBurial.rungFor].
  final ActivityDirection direction;

  /// Branches the ceiling (D-249's last finding).
  final bool isCoinbase;

  /// The pin's own thresholds, crossed from `NetworkParams` (D-249).
  final KvMaturity thresholds;

  /// The link is not live, so no reading is arriving and the counter stops
  /// where it last actually read (BG-8 applied to movement).
  final bool stale;

  /// The track's own subdivisions, as fractions of the ceiling.
  ///
  /// §4: **21 ticks** — one every 5% — with three lengths, so the ruler has a
  /// hierarchy a reader can use without a label on every mark: the two ends and
  /// the midpoint stand tallest, every tenth stands next, and the fives only
  /// graze the bar. It is one even rhythm across the whole track, which is what
  /// a linear scale earns and the piecewise one could never have.
  static const int subDivisions = 20;

  /// **The declared scale: linear, `0 → ceiling`.**
  ///
  /// Pure, and public, so the guard that measures the painted ink compares it
  /// against the arithmetic rather than against another copy of the drawing
  /// code. Anything at or past the ceiling is a full track, because the scale
  /// ends where spendability begins and no rung claims anything beyond it.
  static double positionFor(int depth, int ceiling) {
    if (depth <= 0 || ceiling <= 0) return 0;
    if (depth >= ceiling) return 1;
    return depth / ceiling;
  }

  @override
  State<KvBurialGauge> createState() => _KvBurialGaugeState();
}

class _KvBurialGaugeState extends State<KvBurialGauge> {
  /// The rung the **last built frame actually rendered**, which is not the same
  /// thing as the rung of the newest reading.
  ///
  /// This is the correction that makes the two registers one. The rung used to
  /// be recomputed in `didUpdateWidget` from `widget.confirmations` — the
  /// newest observation — while the fill was drawn at whatever integer the
  /// streamed replay was on. A reading arriving at 150 over a wallet showing 99
  /// therefore printed the settled word immediately and left the bar sitting
  /// below the ceiling for the rest of the second: the word and the extent
  /// disagreeing about which side of the threshold the money was on, on the
  /// surface built to answer exactly that. Deriving the rung from the **drawn**
  /// depth makes the word flip in the same frame the fill crosses the mark, by
  /// construction.
  KvBurialRung? _shown;

  KvBurialRung _rungAt(int? depth) => KvBurial.rungFor(
    depth,
    widget.maturity,
    stalled: widget.stalled,
    direction: widget.direction,
    isCoinbase: widget.isCoinbase,
    thresholds: widget.thresholds,
  );

  @override
  Widget build(BuildContext context) {
    final n = widget.confirmations;
    final ceiling = widget.thresholds.ceilingFor(coinbase: widget.isCoinbase);
    // Spoken as one reading, from the NEWEST observation. Without this a
    // screen reader walks a bare row of numerals — 0, 50, 100 — which is the
    // axis, not the value.
    //
    // **Built from the DEPTH, not from the words**, for two reasons. The words
    // dangled the axis into a sentence that does not take it, and past the
    // ceiling the words carry no number at all while the fill carries the
    // reading: a screen-reader user got **no depth** exactly where a sighted
    // user reads one off the track (`ux-auditor`, UX-5).
    final words = KvBurial.words(_rungAt(n), depth: n);
    return Semantics(
      label: n == null
          ? '$words. Depth unknown.'
          : '$words. $n of $ceiling DAA deep. '
                'Spendable at $ceiling.',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // **ONE reading feeds both registers.** The words and the fill are
          // built inside the same builder from the same `shown`, so the number
          // printed and the number drawn are the same integer in the same frame.
          KvStreamingCount(
            value: n == null ? null : BigInt.from(n),
            stalled: widget.stale,
            builder: (context, shown) => _live(shown?.toInt() ?? n, ceiling),
          ),
          const SizedBox(height: KvSpace.xs),
          // The axis depends on the ceiling alone: built beside the stream,
          // never inside it, so a crossing frame rebuilds a line and a painter
          // and not three labels that cannot change.
          _Graduations(ceiling: ceiling),
        ],
      ),
    );
  }

  /// The two things a streamed depth drives — the reading line and the track —
  /// under **one** colour tween, so the dot and the fill cross from green to
  /// blue in the same frame by construction rather than by two tweens that
  /// happen to share a duration.
  Widget _live(int? depth, int ceiling) {
    final rung = _rungAt(depth);
    final previous = _shown;
    final backwards = previous != null && rung.index < previous.index;
    _shown = rung;
    // A decrease snaps; everything else crosses (BG-18 over BG-24).
    final crossing = backwards ? Duration.zero : KvMotion.fast;
    // **The rung crosses, it does not cut** (BG-24). What changes at a crossing
    // is a *hue* — the reading line prints the count and the ceiling, which
    // are the same words either side of the mark — so the dot and the fill
    // tween together, from the same rung, over the same duration. Nothing on
    // the path from a reading to a width touches this builder (BG-22).
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: KvBurial.hueFor(rung)),
      duration: crossing,
      curve: KvMotion.out,
      builder: (context, hue, _) {
        final fill = hue ?? KvBurial.hueFor(rung);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ReadingLine(
              heading: widget.heading,
              depth: depth,
              ceiling: ceiling,
              hue: fill,
              ring: KvBurial.tintFor(rung),
            ),
            const SizedBox(height: KvSpace.sm),
            CustomPaint(
              size: const Size(double.infinity, KvBurialGaugePainter.extent),
              painter: KvBurialGaugePainter(
                depth: rung == KvBurialRung.stalled ? null : depth,
                ceiling: ceiling,
                fill: fill,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The reading, in the detail's register: the axis named at the left, the
/// measurement hard right.
///
/// **It prints the number, never the rung's word.** `S9` puts the word in the
/// lifecycle chip above and the count here, and BG-19 is why: the first cut
/// printed `Accepted 42` in both and the suite caught it as one measurement
/// stated twice on one surface. Two registers of one fact are permitted — a
/// word, and a position on a declared scale — two printings of the count are
/// not. The rung is still in this line's ink: the dot carries its hue.
class _ReadingLine extends StatelessWidget {
  const _ReadingLine({
    required this.heading,
    required this.depth,
    required this.ceiling,
    required this.hue,
    required this.ring,
  });

  final String? heading;
  final int? depth;
  final int ceiling;
  final Color hue;
  final Color ring;

  static const TextStyle _figure = TextStyle(
    fontFamily: KvFont.mono,
    fontSize: 15,
    height: 20 / 15,
    // **Declared AND painted** (L150): on a variable face the enum is only a
    // hint, and a weight set without its axis paints at whatever the ambient
    // one is.
    fontWeight: FontWeight.w500,
    fontVariations: KvWeight.w500,
    color: KvColor.ink,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle _unit = TextStyle(
    fontFamily: KvFont.ui,
    fontSize: 13,
    height: 18 / 13,
    color: KvColor.inkMeta,
  );

  /// `KvRuledLabel`'s own text style, restated for measurement only.
  static const TextStyle _caps = TextStyle(
    fontFamily: KvFont.ui,
    fontSize: 12,
    height: 16 / 12,
    letterSpacing: 0.8,
  );

  static double _width(String text, TextStyle style, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// **One number, one format.** The reading printed `of 1000 DAA` while the
  /// graduation twenty dp beneath it printed `1,000`, and every other chain
  /// integer on the screen goes through `formatScore` (`ux-auditor`, item 33).
  static String _grouped(int n) => formatScore(BigInt.from(n));

  @override
  Widget build(BuildContext context) {
    final n = depth;
    final figure = n == null ? '—' : _grouped(n);
    // The axis, inline and subordinate — `S9`'s `blocks deep`, in the unit
    // D-249 corrected it to: `KvBurial.depthOf` computes a **DAA-score**
    // delta, and at 10 BPS the wall-clock arithmetic is unchanged but the
    // word must be true.
    //
    // **Two phrasings, because there are two questions.** Under the ceiling
    // the reading is *progress* and `42 of 100 DAA` answers it. At or past
    // it that question is closed, and `420 of 100 DAA` is arithmetic
    // nonsense — so the scale drops away and the depth stands on its own,
    // which is what `S9` itself does with `1,240 blocks deep`. The true
    // number is printed either way: clamping it to the ceiling would hide
    // how deep the money actually is, which is the one thing this surface
    // exists to say. (Caught in a rendered frame of the settled state.)
    final unit = n != null && n >= ceiling
        ? 'DAA deep'
        : 'of ${_grouped(ceiling)} DAA';
    final reading = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // §4's lamp anatomy, in the rung's own hue and tint — `settled` is
        // fenced out of `KvLampTone` (D-248), so the lamp takes the hue
        // directly rather than the ladder drawing a second lamp (item 33).
        KvLamp.hued(color: hue, ring: ring),
        const SizedBox(width: KvSpace.s),
        // **`—` for a depth nobody has** (BG-8): a stale link, a cold start, a
        // row the live DAA cannot anchor. Never a zero, which is a reading.
        Text(figure, maxLines: 1, style: _figure),
        const SizedBox(width: KvSpace.xs),
        Text(unit, maxLines: 1, style: _unit),
      ],
    );
    final label = heading;
    if (label == null) {
      return Align(alignment: Alignment.centerRight, child: reading);
    }
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // **Measured, then either one row or two** — never a broken word. The
        // heading needs its rule, its gap and its capitals; the reading needs
        // its dot, its figure and its unit. When the two cannot share the
        // width, the heading takes its own line and the reading keeps the
        // right edge underneath, which is `KvFactLine`'s rule for the same
        // squeeze one plate down.
        final headingNeeds =
            KvSpace.s + KvSpace.s + _width(label.toUpperCase(), _caps, scaler);
        final readingNeeds =
            KvLamp.extent +
            KvSpace.s +
            _width(figure, _figure, scaler) +
            KvSpace.xs +
            _width(unit, _unit, scaler);
        final fits =
            headingNeeds + KvSpace.s + readingNeeds <= constraints.maxWidth;
        if (fits) {
          return Row(
            children: [
              KvRuledLabel(label, tight: true, rule: false),
              const Spacer(),
              reading,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KvRuledLabel(label, tight: true, rule: false),
            const SizedBox(height: KvSpace.xs),
            Align(alignment: Alignment.centerRight, child: reading),
          ],
        );
      },
    );
  }
}

/// The labelled graduations — the origin, the midpoint and the ceiling, each
/// centred on the tick it names, with the terminal rung's word under the mark
/// it is reached at.
///
/// Laid out against the track's own width rather than by dividing a `Row` into
/// cells: the outer labels have to sit flush with the ends of the scale, and
/// `1,000` at 1.3x text scale is wider than a third of a 320 dp screen.
///
/// The row's height is **computed** from the two constants the labels
/// themselves are styled with, rather than reserved by an invisible copy of the
/// tallest label — a ghost `Text` would put a second numeral in the tree, which
/// is a duplicate for every finder and every reader that walks it.
class _Graduations extends StatelessWidget {
  const _Graduations({required this.ceiling});

  final int ceiling;

  /// The label ramp, named once and used by both the styles below and the
  /// height arithmetic, so the two cannot drift (item 0 / L121).
  static const double labelSize = 11;
  static const double labelLine = 15;

  /// Thousands get a separator; the midpoint and the origin never need one.
  /// The app's one grouping, so the axis and the reading above it cannot print
  /// the same integer two ways (`ux-auditor` item 33: the reading said
  /// `of 1000 DAA` while this label said `1,000`, twenty dp apart).
  static String _numeral(int mark) => formatScore(BigInt.from(mark));

  static Widget _label(int mark, {String? word}) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Text(
        _numeral(mark),
        maxLines: 1,
        style: const TextStyle(
          fontFamily: KvFont.mono,
          fontSize: labelSize,
          height: labelLine / labelSize,
          color: KvColor.inkMeta,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
      if (word != null)
        Text(
          word,
          maxLines: 1,
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: labelSize,
            height: labelLine / labelSize,
            color: KvColor.inkMeta,
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    // The origin, the midpoint and the ceiling. **The ceiling is named with the
    // rung it delivers** — `settled`, the same word the reading line says at
    // the same instant, which is BG-7's redundancy rather than BG-19's
    // duplication: one is the axis, one is the reading. It is also the word,
    // not a second one: naming the mark `spendable` would put two names on one
    // fact, which is the BG-21 defect this whole rebuild exists to close.
    final marks = <(int, String?)>[
      (0, null),
      (ceiling ~/ 2, null),
      (ceiling, 'settled'),
    ];
    // The tallest label is a numeral over a word: two line boxes, each
    // `labelLine / labelSize` of whatever the user's scaler makes of
    // `labelSize`.
    final rows =
        MediaQuery.textScalerOf(context).scale(labelSize) *
        (labelLine / labelSize) *
        2;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return SizedBox(
          height: rows,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 0; i < marks.length; i++)
                Positioned(
                  // **The label sits where its own mark is drawn**, not where
                  // its index falls — the rule that survived the rescale, and
                  // the one BG-22 exists to enforce.
                  left: width * KvBurialGauge.positionFor(marks[i].$1, ceiling),
                  top: 0,
                  child: FractionalTranslation(
                    // Flush at the ends, centred in between — so no label
                    // overhangs the gutter and the middle one sits on its tick.
                    translation: Offset(switch (i) {
                      0 => 0,
                      _ when i == marks.length - 1 => -1,
                      _ => -0.5,
                    }, 0),
                    child: _label(marks[i].$1, word: marks[i].$2),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The ticks above, the track, and the fill.
///
/// **Public, and it takes the depth and the ceiling rather than a fraction**, so
/// there is no intermediate argument for a guard to confirm instead of the
/// drawing: hand it a reading, measure the ink, compare against
/// [KvBurialGauge.positionFor]. That is L145's lesson made structural — a guard
/// that records the value the code handed it can only confirm that the code
/// handed it that value.
class KvBurialGaugePainter extends CustomPainter {
  const KvBurialGaugePainter({
    required this.depth,
    required this.ceiling,
    required this.fill,
  });

  /// The observed depth, or null when there is none. **A null draws no fill at
  /// all** — an extent for a quantity nobody has is a fabricated reading, and
  /// BG-8 renders the unknown as a dash, which the words above already do.
  final int? depth;

  /// The pin's threshold for this row: the scale's full extent.
  final int ceiling;

  /// The rung's colour, mid-crossfade. It says what the fill would look like;
  /// **[depth] says whether there is one at all.**
  final Color? fill;

  /// The bar's thickness — **6 dp** (§4, and the render measures 6.0 exactly).
  static const double band = 6;

  /// Tick lengths above the band (§4): the ends and the midpoint stand tallest,
  /// every tenth stands next, and every fifth only grazes the bar.
  static const double majorTick = 12;
  static const double tenTick = 8;
  static const double fiveTick = 5;

  /// The gap between the tick row and the bar, so the ruler reads as a scale
  /// standing over its reading rather than as fringe growing out of it.
  static const double tickGap = 3;

  /// Total painted height, derived from the marks rather than asserted (L121).
  static const double extent = majorTick + tickGap + band;

  /// **Which length a graduation takes, from the step it lands on** — §4's
  /// three lengths, expressed against the SUBDIVISION grid rather than against
  /// the ceiling, so a coinbase row's 0 · 500 · 1,000 wears the same hierarchy
  /// as a payment's 0 · 50 · 100 without a second table.
  ///
  /// Twenty steps span the track, so a step is 5 % of the ceiling: the ends and
  /// the midpoint (steps 0 · 10 · 20) stand tallest, every second step is a
  /// tenth and stands next, and the odd steps are the fifths that only graze
  /// the bar.
  static double tickLength(int step) {
    const half = KvBurialGauge.subDivisions ~/ 2;
    if (step == 0 || step == half || step == KvBurialGauge.subDivisions) {
      return majorTick;
    }
    return step.isEven ? tenTick : fiveTick;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final top = majorTick + tickGap;

    // **The fill's extent, computed once and read by both the ticks and the
    // bar** — a rectangle, so the ink ends where the reading does. A stroked
    // line with any cap but `butt` paints half a stroke width past both ends,
    // which is a constant added to every value and an unbounded lie as the
    // value goes to zero (BG-22).
    final n = depth;
    final paintFill = fill;
    final fillX = n == null || paintFill == null
        ? null
        : KvBurialGauge.positionFor(n, ceiling) * w;

    // **The ticks, one even rhythm across the whole track.** A linear scale is
    // what earns this: an evenly spaced tick is an even step of DEPTH, so the
    // ruler means something rather than decorating. On the piecewise scale this
    // replaced, evenly spaced ticks were decoration and clustered ticks were,
    // in the founder's words, "just not it".
    //
    // **A tick the reading has passed takes the reading's hue** — `S9` draws
    // every graduation of its full track in `ok` green (measured: (125,213,132)
    // at five sampled ticks, the fill's own tone), so the ruler reads as part
    // of the instrument rather than as a rule laid over it. Beyond the reading
    // the ticks keep the machined tone, which is what makes the lit ones read
    // as *reached*; it is the same extent the fill draws, from the same
    // arithmetic, so it cannot state a second reading (BG-19).
    //
    // `isAntiAlias: false` keeps a 1px engraved rule one pixel wide instead of
    // two half-lit ones — the difference between machined and smudged.
    //
    // **An unread scale flattens.** An empty track at a live zero and an empty
    // track at an unknown depth would otherwise be the same ink, so the graphic
    // would assert *"measured at zero"* for a reading nobody has
    // (`consensus-auditor`, UX-5). Without a reading the ticks drop to the
    // track's own tone and the hierarchy an instrument has when it is live
    // collapses.
    //
    // **Both tones clear WCAG 1.4.11's 3:1 floor, and until UX-R3 neither did.**
    // This comment claimed `etch` measures 3.04:1; recomputed from the hexes it
    // is **2.35 on `plate`, 2.53 on `abyss`** — a false measured claim that had
    // been standing since the gauge shipped and that this sitting propagated to
    // two more objects before `ux-auditor` caught it (item 0 / L121). The whole
    // "no reading" face was under the floor. `inkMeta` is **4.75** and `inkDim`
    // **8.14** on `plate`, so the machined hierarchy survives above the bar
    // rather than below it.
    final unread = Paint()
      ..color = depth == null ? KvColor.inkMeta : KvColor.inkDim
      ..strokeWidth = 1
      ..isAntiAlias = false;
    final reached = Paint()
      ..color = paintFill ?? KvColor.inkDim
      ..strokeWidth = 1
      ..isAntiAlias = false;
    for (var step = 0; step <= KvBurialGauge.subDivisions; step++) {
      final at = step / KvBurialGauge.subDivisions;
      final x = (w * at).clamp(0.5, w - 0.5);
      final len = tickLength(step);
      final lit = fillX != null && fillX > 0 && w * at <= fillX;
      canvas.drawLine(
        Offset(x, top - len),
        Offset(x, top),
        lit ? reached : unread,
      );
    }

    // **The track has to READ as a track, and clear the 3:1 floor doing it.**
    // `datum` — the engraved rule a balance floats on — is 1.1:1 on the abyss
    // and vanished the moment the fill stopped, turning a reading on a scale
    // into an unbounded bar. The track is what makes the fill a *fraction*
    // rather than a bar, so it is meaningful non-text content and owes the
    // floor: `inkMeta` at **4.75** on `plate`, with the graduations above it at
    // `inkDim`'s **8.14** keeping the machined hierarchy.
    canvas.drawRect(
      Rect.fromLTWH(0, top, w, band),
      Paint()..color = KvColor.inkMeta,
    );

    if (fillX != null && fillX > 0) {
      canvas.drawRect(
        Rect.fromLTWH(0, top, fillX, band),
        Paint()
          ..color = paintFill!
          ..style = PaintingStyle.fill,
      );
    }
  }

  @override
  bool shouldRepaint(KvBurialGaugePainter old) =>
      old.depth != depth || old.fill != fill || old.ceiling != ceiling;
}
