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
/// ## The scale, and what it measures (BG-22 as amended by D-248/D-249/D-276)
///
/// **Two linear segments.** `0 → ceiling` runs over the left two thirds of the
/// track — the settling, where the money becomes spendable — and
/// `ceiling → 10 × ceiling` over the right third, the burial past it, ending
/// at `N+` (the founder's ruling on glass, 2026-09-05: *"0 to 1000, the
/// 100–1000 part a third of the length to the right, and 1000 is just
/// `1000+`"*). The ceiling is the pin's own threshold for this row —
/// [KvMaturity.userDaa] normally, [KvMaturity.coinbaseDaa] when the row is a
/// mined coinbase — so a coinbase reads `0 · 1,000 settled · 10,000+`.
///
/// ```
///   0                                100 settled              1,000+
///   |..:..:..:..|..:..:..:..|..:..:..:..|.....|.....|.....|.....|
///   ├───────────── two thirds ─────────┼──── one third ────────┤
/// ```
///
/// **Why the thousand is back, and why it is not the ruler D-248 struck.**
/// D-248 removed the thousand on the argument that past 100 nothing changes,
/// and D-249 kept it as *conditional* (a coinbase matures there). D-276 draws
/// it on every row — but as a **burial**, not a rung: the fill past the
/// ceiling claims nothing new about spendability, it says how deep the money
/// now lies, which is what `S9`'s `1,240 blocks deep` says in words.
///
/// ## The ink is the reading
///
/// The fill is a **rectangle**, not a stroked line, so it has no cap to paint
/// past the value it reports. Its extent is computed from the **depth** and
/// from nothing else: [positionFor] is a pure function of an integer and a
/// ceiling, the crossfade controller drives colour and never geometry, and
/// there is no curve anywhere on the path from a reading to a width. A gauge
/// is never eased, in either direction (BG-22, BG-9's one exception). The
/// guard measures the **painted ink** through a spy canvas rather than the
/// value the code handed the painter (L145).
///
/// ## The graduations are honest, and they adapt
///
/// Every tick stands on a round depth — never an even pixel step laid over a
/// bent scale, which the founder called *"just not it"* the first time. The
/// minor step is the finest round division the width will hold at
/// [minTickGap] ([graduationsFor]), so a 320 dp screen at 1.3× gets a coarser
/// ruler rather than a smudge; the tenths and the ends stand taller, and a
/// tick the reading has passed takes the fill's hue.
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
/// stream's builder. The graduation labels depend on the ceiling alone and are
/// built once beside it; the screen-reader sentence is built from the
/// **newest** reading rather than the streamed one, because the assistive
/// reader wants where the money is, not where the animation is.
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

  /// Where the ceiling sits on the track: two thirds along (D-276).
  static const double knee = 2 / 3;

  /// The scale's far end — ten ceilings, printed as `N+` (D-276).
  static int endFor(int ceiling) => ceiling * 10;

  /// The closest two ticks may stand. Under it a ruler is a smudge, and the
  /// next coarser round step is taken instead ([graduationsFor]).
  static const double minTickGap = 4;

  /// **The declared scale**, pure and public, so the guard that measures the
  /// painted ink compares it against the arithmetic rather than against a
  /// second copy of the drawing code.
  ///
  /// Linear to the ceiling over [knee] of the width, linear again to
  /// [endFor] over the rest; anything at or past the end is a full track.
  static double positionFor(int depth, int ceiling) {
    if (depth <= 0 || ceiling <= 0) return 0;
    if (depth < ceiling) return knee * depth / ceiling;
    final end = endFor(ceiling);
    if (depth >= end) return 1;
    // The ceiling itself lands on the knee exactly, not a rounding under it.
    return knee + (1 - knee) * (depth - ceiling) / (end - ceiling);
  }

  /// **Every graduation of the track for [ceiling] at [width]**, each on a
  /// round depth, with its rank.
  ///
  /// The settling segment subdivides the ceiling by 50, 20 or 10 — the finest
  /// the width holds at [minTickGap] — with every tenth medium and the origin,
  /// the midpoint and the ceiling major. The burial segment subdivides its
  /// nine ceilings by halves or wholes on the same rule, with every ceiling
  /// medium and five ceilings and the end major. A division that does not
  /// divide the ceiling evenly is never offered: a tick on a fraction of a
  /// block would be a mark on nothing.
  static List<KvGraduation> graduationsFor(int ceiling, double width) {
    if (ceiling <= 0 || width <= 0) return const [];
    final end = endFor(ceiling);
    int? finest(List<int> divisions, double span, int extent) {
      for (final d in divisions) {
        if (extent % d != 0) continue;
        if (span / d >= minTickGap) return extent ~/ d;
      }
      return null;
    }

    final marks = <KvGraduation>[];
    // The settling: 0 → ceiling over the knee.
    final leftStep =
        finest(const [50, 20, 10], knee * width, ceiling) ?? ceiling;
    for (var v = 0; v <= ceiling; v += leftStep) {
      final rank = v == 0 || v == ceiling || v * 2 == ceiling
          ? KvGraduationRank.major
          : (v * 10) % ceiling == 0
          ? KvGraduationRank.medium
          : KvGraduationRank.minor;
      marks.add(KvGraduation(v, rank));
    }
    // The burial: ceiling → end over the rest.
    final rightStep =
        finest(const [18, 9], (1 - knee) * width, end - ceiling) ??
        (end - ceiling);
    for (var v = ceiling + rightStep; v <= end; v += rightStep) {
      final rank = v == end || v == ceiling * 5
          ? KvGraduationRank.major
          : v % ceiling == 0
          ? KvGraduationRank.medium
          : KvGraduationRank.minor;
      marks.add(KvGraduation(v, rank));
    }
    return marks;
  }

  @override
  State<KvBurialGauge> createState() => _KvBurialGaugeState();
}

/// A tick's standing on the ruler.
enum KvGraduationRank { minor, medium, major }

/// One tick: the depth it stands on, and how tall it stands.
class KvGraduation {
  const KvGraduation(this.depth, this.rank);

  final int depth;
  final KvGraduationRank rank;

  @override
  bool operator ==(Object other) =>
      other is KvGraduation && other.depth == depth && other.rank == rank;

  @override
  int get hashCode => Object.hash(depth, rank);

  @override
  String toString() => '$depth·${rank.name}';
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
    // screen reader walks a bare row of numerals — 0, 100, 1,000 — which is
    // the axis, not the value.
    //
    // **Built from the DEPTH, not from the words**, for two reasons. The words
    // dangled the axis into a sentence that does not take it, and a screen-
    // reader user is owed the number a sighted user reads off the track
    // (`ux-auditor`, UX-5).
    final words = KvBurial.words(_rungAt(n), depth: n);
    return Semantics(
      label: n == null
          ? '$words. Depth unknown.'
          : '$words. $n blocks deep. Spendable at $ceiling.',
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
  /// under **one** colour tween, so the dot and the fill cross from blue to
  /// green in the same frame by construction rather than by two tweens that
  /// happen to share a duration.
  Widget _live(int? depth, int ceiling) {
    final rung = _rungAt(depth);
    final previous = _shown;
    final backwards = previous != null && rung.index < previous.index;
    _shown = rung;
    // A decrease snaps; everything else crosses (BG-18 over BG-24).
    final crossing = backwards ? Duration.zero : KvMotion.fast;
    // **The rung crosses, it does not cut** (BG-24). What changes at a crossing
    // is a *hue* — the reading line prints the depth either side of the mark —
    // so the dot and the fill tween together, from the same rung, over the
    // same duration. Nothing on the path from a reading to a width touches
    // this builder (BG-22).
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
            const SizedBox(height: KvSpace.s10),
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
/// measurement hard right — `S9`'s `1,240 blocks deep`.
///
/// **It prints the number, never the rung's word.** `S9` puts the word in the
/// lifecycle chip above and the count here, and BG-19 is why: the first cut
/// printed `Accepted 42` in both and the suite caught it as one measurement
/// stated twice on one surface. The rung is still in this line's ink: the dot
/// carries its hue. **Past the scale's end the count stops** — `1,000+` — so
/// a transaction days old streams no number (founder on glass, 2026-09-05).
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
    fontWeight: FontWeight.w600,
    fontVariations: KvWeight.w600,
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

  /// **One number, one format.** Every chain integer on the screen goes
  /// through `formatScore` (`ux-auditor`, item 33).
  static String _grouped(int n) => formatScore(BigInt.from(n));

  /// What the line prints for a depth: the grouped count to the scale's end,
  /// `N+` at and past it, `—` for a reading nobody has (BG-8).
  static String figureFor(int? depth, int ceiling) {
    if (depth == null) return '—';
    final end = KvBurialGauge.endFor(ceiling);
    return depth >= end ? '${_grouped(end)}+' : _grouped(depth);
  }

  @override
  Widget build(BuildContext context) {
    final figure = figureFor(depth, ceiling);
    // The axis, inline and subordinate — `S9`'s `blocks deep`. A DAA-score
    // delta is a count of blocks at 10 BPS, so the render's word is true.
    const unit = 'blocks deep';
    final reading = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // §4's lamp anatomy, in the rung's own hue and tint — `settled` is
        // fenced out of `KvLampTone` (D-248), so the lamp takes the hue
        // directly rather than the ladder drawing a second lamp (item 33).
        KvLamp.hued(color: hue, ring: ring),
        const SizedBox(width: KvSpace.s),
        Text(figure, maxLines: 1, style: _figure),
        const SizedBox(width: KvSpace.xs),
        const Text(unit, maxLines: 1, style: _unit),
      ],
    );
    final label = heading;
    if (label == null) {
      return Align(alignment: Alignment.centerRight, child: reading);
    }
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // **Measured, then either one row or two** — never a broken word. When
        // the heading and the reading cannot share the width, the heading
        // takes its own line and the reading keeps the right edge underneath,
        // which is `KvFactLine`'s rule for the same squeeze one plate down.
        final headingNeeds = _width(label.toUpperCase(), _caps, scaler);
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

/// The labelled graduations — the origin, the ceiling with its word, and the
/// end with its plus — each sitting on the tick it names.
///
/// Laid out against the track's own width rather than by dividing a `Row` into
/// cells: the outer labels have to sit flush with the ends of the scale, and
/// the ceiling's label sits on the knee, two thirds along.
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

  /// The app's one grouping, so the axis and the reading above it cannot
  /// print the same integer two ways (`ux-auditor` item 33).
  static String _numeral(int mark) => formatScore(BigInt.from(mark));

  /// The number and, at the ceiling, its word — on one line, as `S9` sets
  /// `100 confirmed` and `1,000 final`.
  static Widget _label(String numeral, {String? word}) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [
      Text(
        numeral,
        maxLines: 1,
        style: const TextStyle(
          fontFamily: KvFont.mono,
          fontSize: labelSize,
          height: labelLine / labelSize,
          color: KvColor.inkMeta,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
      if (word != null) ...[
        const SizedBox(width: KvSpace.xs),
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
    ],
  );

  @override
  Widget build(BuildContext context) {
    // **The ceiling is named with the rung it delivers** — `settled`, the same
    // word the chip above says at the same instant, which is BG-7's
    // redundancy rather than BG-19's duplication: one is the axis, one is the
    // reading. The end is a plus, not a word: nothing new is delivered there
    // (D-249 struck the finality claim; D-276 draws the burial).
    final end = KvBurialGauge.endFor(ceiling);
    final marks = <(double, Widget, double)>[
      (0, _label(_numeral(0)), 0),
      (KvBurialGauge.knee, _label(_numeral(ceiling), word: 'settled'), -0.5),
      (1, _label('${_numeral(end)}+'), -1),
    ];
    // One line box, whatever the user's scaler makes of `labelSize`.
    final rows =
        MediaQuery.textScalerOf(context).scale(labelSize) *
        (labelLine / labelSize);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return SizedBox(
          height: rows,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (final (at, label, anchor) in marks)
                Positioned(
                  // **The label sits where its own mark is drawn** (BG-22):
                  // flush at the ends, centred on the knee.
                  left: width * at,
                  top: 0,
                  child: FractionalTranslation(
                    translation: Offset(anchor, 0),
                    child: label,
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

  /// The pin's threshold for this row: the knee of the scale.
  final int ceiling;

  /// The rung's colour, mid-crossfade. It says what the fill would look like;
  /// **[depth] says whether there is one at all.**
  final Color? fill;

  /// The bar's thickness — **6 dp** (§4, and the render measures 6.0 exactly).
  static const double band = 6;

  /// Tick lengths above the band: the origin, the midpoint, the ceiling, five
  /// ceilings and the end stand tallest; every tenth and every ceiling next;
  /// the fine divisions only graze the bar.
  static const double majorTick = 10;
  static const double mediumTick = 7;
  static const double minorTick = 4;

  /// The gap between the tick row and the bar, so the ruler reads as a scale
  /// standing over its reading rather than as fringe growing out of it.
  static const double tickGap = 3;

  /// Total painted height, derived from the marks rather than asserted (L121).
  static const double extent = majorTick + tickGap + band;

  static double tickLength(KvGraduationRank rank) => switch (rank) {
    KvGraduationRank.major => majorTick,
    KvGraduationRank.medium => mediumTick,
    KvGraduationRank.minor => minorTick,
  };

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

    // **The ticks stand on round depths, at the finest step the width holds.**
    // A tick the reading has passed takes the reading's hue — `S9` draws every
    // graduation of its full track in the fill's own tone — so the ruler reads
    // as part of the instrument rather than as a rule laid over it. Beyond the
    // reading the ticks keep the machined tone, which is what makes the lit
    // ones read as *reached*; it is the same extent the fill draws, from the
    // same arithmetic, so it cannot state a second reading (BG-19).
    //
    // `isAntiAlias: false` keeps a 1px engraved rule one pixel wide instead of
    // two half-lit ones — the difference between machined and smudged.
    //
    // **An unread scale flattens.** An empty track at a live zero and an empty
    // track at an unknown depth would otherwise be the same ink, so the graphic
    // would assert *"measured at zero"* for a reading nobody has
    // (`consensus-auditor`, UX-5). Without a reading the ticks drop to the
    // track's own tone and the hierarchy an instrument has when it is live
    // collapses. Both tones clear WCAG 1.4.11's 3:1 floor: `inkMeta` is 4.75
    // and `inkDim` 8.14 on `plate` (recomputed at UX-R3, L121).
    final unread = Paint()
      ..color = depth == null ? KvColor.inkMeta : KvColor.inkDim
      ..strokeWidth = 1
      ..isAntiAlias = false;
    final reached = Paint()
      ..color = paintFill ?? KvColor.inkDim
      ..strokeWidth = 1
      ..isAntiAlias = false;
    for (final mark in KvBurialGauge.graduationsFor(ceiling, w)) {
      final at = KvBurialGauge.positionFor(mark.depth, ceiling);
      final x = (w * at).clamp(0.5, w - 0.5);
      final len = tickLength(mark.rank);
      final lit = fillX != null && fillX > 0 && w * at <= fillX;
      canvas.drawLine(
        Offset(x, top - len),
        Offset(x, top),
        lit ? reached : unread,
      );
    }

    // **The track has to READ as a track, and clear the 3:1 floor doing it.**
    // The track is what makes the fill a *fraction* rather than a bar, so it
    // is meaningful non-text content and owes the floor: `inkMeta` at 4.75 on
    // `plate`, with the graduations above it at `inkDim`'s 8.14 keeping the
    // machined hierarchy.
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
