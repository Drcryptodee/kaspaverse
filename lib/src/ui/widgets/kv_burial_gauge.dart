import 'package:flutter/material.dart';

import '../../rust/api/wallet.dart';
import '../theme/tokens.dart';
import 'kv_burial_mark.dart';
import 'kv_status_chip.dart';
import 'kv_streaming_count.dart';
import 'tx_status_chip.dart';

/// **The burial gauge — the instrument register the balance gave up** (D-191),
/// and the transaction detail's whole reason to exist.
///
/// Kaspa runs at about ten blocks a second, so a hundred confirmations is a
/// ten-second event and a thousand about a hundred seconds. Both are watchable,
/// which is what makes a live gauge a feature here rather than a spinner.
///
/// ## The scale, and why it declares itself (BG-22)
///
/// Depth is plotted **logarithmically**, so one confirmation is not invisible
/// beside a thousand. A non-linear scale is permitted only where it declares
/// itself: **the axis is named, every decade is a labelled graduation, and
/// nothing interpolates unlabelled between marks.** Undeclared, this ladder's
/// lie factor against a linear reading is 100× at n = 1,000.
///
/// So the axis is named (`blocks deep`), and it carries five labelled marks:
///
/// ```
///   0    10   100                     1,000
///   ├┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼┼]
///        ^    confirmed                final
///        the exact centre of 0 … 100
/// ```
///
/// **The graduations are D-192's ratified ladder plus its origin.** 1 · 10 ·
/// 100 · 1,000 are the ratified marks and the two thresholds — *100 is safe,
/// 1,000 is final* — are named on the axis itself, which is where naming a
/// threshold belongs. The **`0` is an addition**, and it is made deliberately
/// rather than quietly: zero confirmations is a state the wallet genuinely
/// reaches and is exactly the moment a user watches this screen, `log10(0)` has
/// no position, and an origin the reader cannot see is an **undeclared** origin
/// — which is the one thing BG-22 forbids outright. It touches neither
/// threshold nor vocabulary.
///
/// **The decades are not evenly spaced, and that is the point.** The scale is
/// piecewise: `0 … 100` shares the first third, and `100 … 1,000` takes the
/// remaining two. Evenly spaced at quarters — the scale UX-5 shipped — the one
/// decade that carries the decision occupied a quarter of the track, and it
/// was measured on glass at the 2026-08-31 device sitting: a real send
/// climbing from **981 to 1,000 moved the fill two pixels**. Nine hundred
/// blocks of the journey from *confirmed* to *final* were visually
/// indistinguishable on the surface built to show exactly that.
///
/// The rescale spends ink where the reading changes a decision, which is
/// Tufte's argument rather than a departure from it, and it stays **declared**:
/// every graduation is labelled, so a reader can see that `100 … 1,000` is
/// wider than `10 … 100` and is not invited to interpolate. **Nothing ever
/// renders strictly between `0` and `1`**: a depth is a count of whole blocks,
/// and [KvStreamingCount] passes through the integers between two readings and
/// never between two integers.
///
/// ## The ink is the reading
///
/// The fill is a **rectangle**, not a stroked line, so it has no cap to paint
/// past the value it reports — the defect that added 4.21% of the circle to
/// every reading of the sign ring. Its extent is computed from the **depth**
/// and from nothing else: [positionFor] is a pure function of an integer, the
/// crossfade controller drives colour and never geometry, and there is no
/// curve anywhere on the path from a reading to a width. A gauge is never
/// eased, in either direction (BG-22, BG-9's one exception).
///
/// ## One fact, two registers, one implementation
///
/// [KvBurialMark] renders this same chain fact in a ledger row. Both read
/// their thresholds, rung arithmetic and words from [KvBurial], so the two
/// cannot drift into disagreeing about one number (BG-21 / L143) — and this
/// widget renders **its own** words rather than embedding the mark, because a
/// second [KvStreamingCount] would start a second tween and the number beside
/// the gauge could differ from the number the gauge was drawn at.
class KvBurialGauge extends StatefulWidget {
  const KvBurialGauge({
    super.key,
    required this.state,
    required this.confirmations,
    required this.maturity,
    this.stalled = false,
  });

  final TxChipState state;

  /// The observed depth, or null when there is none to be had (BG-8).
  final int? confirmations;

  final MaturityState maturity;

  /// The link is not live, so no reading is arriving and the counter stops
  /// where it last actually read (BG-8 applied to movement).
  final bool stalled;

  /// The labelled graduations, in order. The ratified ladder plus its origin.
  static const List<int> graduations = [0, 10, 100, KvBurial.settled];

  /// **The sub-marks: the scale's own subdivisions, drawn and unlabelled.**
  ///
  /// This is what makes the compression *visible* rather than merely declared.
  /// A reader seeing nine ticks bunch toward `10` and nine more bunch toward
  /// `100` can see the axis is logarithmic without being told; the labels then
  /// only have to name the decades. It is the canonical log ruler, and it is a
  /// stronger answer to BG-22's *no unlabelled interpolation* than blank track
  /// was — blank track invites the eye to interpolate linearly, and a ruler
  /// shows it exactly why it must not.
  static const List<int> subGraduations = [
    1, 2, 3, 4, 5, 6, 7, 8, 9, //
    20, 30, 40, 50, 60, 70, 80, 90,
    200, 300, 400, 500, 600, 700, 800, 900,
  ];

  /// The name of the axis, which is what turns four numerals into a scale.
  static const String axisName = 'blocks deep';

  /// **The declared scale**: `x(n) = (log10(n) + 1) / 4`, clamped to the track.
  ///
  /// Pure, and public, so the guard that measures the painted ink can compare
  /// it against the arithmetic instead of against another copy of the drawing
  /// code. `0` maps to the origin; anything past a thousand is a full track,
  /// because the scale ends where finality does.
  /// Where `10` sits: **the exact centre of `0 … 100`** (founder, device
  /// sitting). It is what makes the low end read as a ruler rather than as
  /// three numbers crowded against the hundred mark.
  static const double tenAt = 1 / 6;

  /// Where the safe threshold sits. **One third**, so the decade that carries
  /// the decision gets the other two.
  static const double safeAt = 1 / 3;

  /// The track is divided into this many equal steps, and every step that is
  /// not already a labelled mark gets a sub-mark. **Thirty is not arbitrary:**
  /// it is the smallest division on which all four labelled marks land exactly
  /// — `0`, `10` at 5/30, `100` at 10/30, `1,000` at 30/30 — so the whole ruler
  /// is one even rhythm with no tick out of step with its neighbours.
  static const int subDivisions = 30;

  /// **The declared scale: piecewise LINEAR, with labelled breakpoints.**
  ///
  /// `0 → 0`, `10 → 1/6`, `100 → 1/3`, `1,000 → 1`, straight lines between.
  /// Pure, and public, so the guard that measures the painted ink compares it
  /// against the arithmetic rather than against another copy of the drawing
  /// code.
  ///
  /// Linear inside each segment is what lets the sub-marks be an even rhythm
  /// and still mean something: an evenly spaced tick on a linear segment is an
  /// even step of DEPTH. On the log scale this replaced, evenly spaced ticks
  /// would have been decoration and clustered ticks were, in the founder's
  /// words, "just not it".
  static double positionFor(int depth) {
    if (depth <= 0) return 0;
    if (depth >= KvBurial.settled) return 1;
    if (depth <= 10) return depth / 10 * tenAt;
    if (depth <= KvBurial.safe) {
      return tenAt + (depth - 10) / 90 * (safeAt - tenAt);
    }
    return safeAt +
        (depth - KvBurial.safe) /
            (KvBurial.settled - KvBurial.safe) *
            (1 - safeAt);
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
  /// therefore printed `Confirmed` immediately and left the bar sitting below
  /// the hundred mark for the rest of the second: the word and the extent
  /// disagreeing about which side of the safe threshold the money was on, on
  /// the surface built to answer exactly that. Deriving the rung from the
  /// **drawn** depth makes the word flip in the same frame the fill crosses the
  /// mark, by construction.
  KvBurialRung? _shown;

  /// Bumped on a BACKWARD crossing, and it is the reading line's switcher key
  /// — so the switcher is remounted rather than asked to animate in zero time,
  /// which is the mechanism [KvBurialMark] uses and the reason
  /// `duration: Duration.zero` is not it (the outgoing child is never
  /// released). A rung that goes down is a reorg or a late reading, and BG-18
  /// says a decrease snaps.
  int _epoch = 0;

  /// Amber runs only to safety. Past a hundred blocks a transaction is certain
  /// enough to act on, and holding it amber for another fifteen minutes tells
  /// the user to keep worrying about something already settled (§5). Finality
  /// is carried by the thousand mark closing, never by a fourth hue the palette
  /// does not have.
  /// Every rung answers with a colour, including [KvBurialRung.stalled] —
  /// **whether anything is drawn is the DEPTH's decision, never the tone's.** A
  /// null here would also break the implicit crossfade outright: a
  /// `TweenAnimationBuilder` asserts on a null `end`, and a stalled submit
  /// would have rendered no gauge at all rather than an empty one.
  static Color _fillFor(KvBurialRung rung) => switch (rung) {
    // A stalled submit was never accepted, so there is no depth to plot — and
    // `_body` passes a null depth for it, which is what stops the fill.
    KvBurialRung.stalled => KvColor.warn,
    KvBurialRung.seen => KvColor.warn,
    KvBurialRung.confirmed || KvBurialRung.settled => KvColor.ok,
  };

  @override
  Widget build(BuildContext context) {
    final n = widget.confirmations;
    // **ONE reading feeds both registers.** The words and the fill are built
    // inside the same builder from the same `shown`, so the number printed and
    // the number drawn are the same integer in the same frame.
    return KvStreamingCount(
      value: n == null ? null : BigInt.from(n),
      stalled: widget.stalled,
      builder: (context, shown) => _body(shown?.toInt() ?? n),
    );
  }

  Widget _body(int? depth) {
    final rung = KvBurial.rungFor(widget.state, depth, widget.maturity);
    final previous = _shown;
    final backwards = previous != null && rung.index < previous.index;
    if (backwards) _epoch++;
    _shown = rung;

    final words = KvBurial.words(rung, depth: depth);
    final tone = KvBurial.toneFor(rung);
    // A decrease snaps; everything else crosses (BG-18 over BG-24).
    final crossing = backwards ? Duration.zero : KvMotion.fast;
    return Semantics(
      // Spoken as one reading. Without this a screen reader walks a bare row
      // of numerals — 0, 1, 10, 100, 1,000 — which is the axis, not the value.
      //
      // **Built from the DEPTH, not from the words**, for two reasons. The
      // words dangled the axis into a sentence that does not take it —
      // *"Confirmed blocks deep"* — and, past the safe mark, the words carry no
      // number at all while the fill carries the reading: a screen-reader user
      // got **no depth** exactly where a sighted user reads one off the track
      // (`ux-auditor`, UX-5).
      label: depth == null
          ? '$words. Depth unknown.'
          : '$words. $depth ${KvBurialGauge.axisName}. '
                '${KvBurial.safe} is safe, ${KvBurial.settled} is final.',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // **The words cross, they do not cut** (BG-24). At the thousand mark
          // the line went from 40 dp to 24 dp in one frame and the lamp dot
          // vanished with nothing between, while the bar beneath it crossfaded
          // for the full 160 ms — one state carried by two things that
          // disagreed about when it changed (`ux-auditor`, UX-5). Keyed on the
          // RUNG, so the depth streaming inside a rung updates in place instead
          // of crossfading sixty times a second, and the outgoing child is
          // `Positioned` so it sizes nothing — a crossfade whose layout still
          // jumps has only relocated the cut.
          AnimatedSwitcher(
            key: ValueKey(_epoch),
            duration: KvMotion.fast,
            switchInCurve: KvMotion.out,
            switchOutCurve: KvMotion.out,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.centerLeft,
              clipBehavior: Clip.none,
              children: [
                for (final old in previous)
                  Positioned(left: 0, right: 0, top: 0, bottom: 0, child: old),
                ?current,
              ],
            ),
            child: KeyedSubtree(
              key: ValueKey(rung),
              child: _ReadingLine(
                words: words,
                // Mono only where digits are actually printed — the same rule
                // the ledger row's mark keeps, so one fact does not wear two
                // faces.
                mono: rung == KvBurialRung.seen && depth != null,
                tone: tone,
              ),
            ),
          ),
          const SizedBox(height: KvSpace.s),
          // **Implicit, and colour only.** The extent is a pure function of the
          // depth below; these two builders carry the amber -> green crossing
          // and the thousand mark's closing arm, which are the two things that
          // genuinely appear. Nothing on the path from a reading to a width
          // touches either of them (BG-22).
          TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: _fillFor(rung)),
            duration: crossing,
            curve: KvMotion.out,
            builder: (context, fill, _) => TweenAnimationBuilder<double>(
              tween: Tween<double>(end: rung == KvBurialRung.settled ? 1 : 0),
              duration: crossing,
              curve: KvMotion.out,
              builder: (context, seated, _) => CustomPaint(
                size: const Size(double.infinity, KvBurialGaugePainter.extent),
                painter: KvBurialGaugePainter(
                  depth: rung == KvBurialRung.stalled ? null : depth,
                  fill: fill,
                  seated: seated,
                ),
              ),
            ),
          ),
          const SizedBox(height: KvSpace.xs),
          const _Graduations(),
        ],
      ),
    );
  }
}

/// The reading, in the detail's register: the lamp the rung wears, the words,
/// and the axis the number is counted on.
class _ReadingLine extends StatelessWidget {
  const _ReadingLine({
    required this.words,
    required this.tone,
    required this.mono,
  });

  final String words;
  final KvLampTone? tone;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final dot = tone;
    return Row(
      children: [
        if (dot != null) ...[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot.color, shape: BoxShape.circle),
          ),
          const SizedBox(width: KvSpace.s),
        ],
        Expanded(
          child: Text(
            words,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: mono ? KvFont.mono : KvFont.ui,
              fontSize: 15,
              height: 20 / 15,
              fontWeight: FontWeight.w500,
              // The dot carries the hue; the words do not (§1.5).
              color: KvColor.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        // **The axis is still named — by the section heading above it.**
        // BG-22 requires a named axis, not an inline one, and `DEPTH` set in
        // capitals at the head of the section names it louder than a dimmed
        // 11 dp label sitting at the far end of the reading line ever did.
        // [KvBurialGauge.axisName] survives as the spoken form, because a
        // screen reader has no heading in earshot when it reaches the gauge.
      ],
    );
  }
}

/// The labelled decades, each centred on the tick it names, with the two
/// thresholds named where they fall.
///
/// Laid out against the track's own width rather than by dividing a `Row` into
/// cells: the outer labels have to sit flush with the ends of the scale, and
/// `1,000` at 1.3x text scale is wider than an eighth of a 320 dp screen.
///
/// The row's height is **computed** from the two constants the labels
/// themselves are styled with, rather than reserved by an invisible copy of
/// the tallest label — a ghost `Text` would put a second `100` in the tree,
/// which is a duplicate for every finder and every reader that walks it.
class _Graduations extends StatelessWidget {
  const _Graduations();

  /// The label ramp, named once and used by both the styles below and the
  /// height arithmetic, so the two cannot drift (item 0 / L121).
  static const double labelSize = 11;
  static const double labelLine = 15;

  static String _numeral(int mark) => mark >= 1000 ? '1,000' : '$mark';

  /// The two thresholds D-192 settled, named on the axis itself (§5).
  static String? _threshold(int mark) => switch (mark) {
    // `confirmed` rather than `safe`: it is the word the rung itself uses at
    // this depth, so the threshold and the reading now say the same thing.
    KvBurial.safe => 'confirmed',
    KvBurial.settled => 'final',
    _ => null,
  };

  static Widget _label(int mark) => Column(
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
      if (_threshold(mark) case final word?)
        Text(
          word,
          maxLines: 1,
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: labelSize,
            height: labelLine / labelSize,
            color: KvColor.inkMetaLow,
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    const marks = KvBurialGauge.graduations;
    // The tallest label is a numeral over a threshold word: two line boxes,
    // each `labelLine / labelSize` of whatever the user's scaler makes of
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
                  // its index falls. Even-index spacing was correct only while
                  // the scale was even quarters; the moment the scale became
                  // piecewise it made the numerals disagree with the ink they
                  // name, which is the exact failure BG-22 exists to prevent.
                  left: width * KvBurialGauge.positionFor(marks[i]),
                  top: 0,
                  child: FractionalTranslation(
                    // Flush at the ends, centred in between — so no label
                    // overhangs the gutter and every inner one sits on its
                    // tick.
                    translation: Offset(switch (i) {
                      0 => 0,
                      _ when i == marks.length - 1 => -1,
                      _ => -0.5,
                    }, 0),
                    child: _label(marks[i]),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The track, the fill, the graduations and the thousand mark.
///
/// **Public, and it takes the depth rather than a fraction**, so there is no
/// intermediate argument for a guard to confirm instead of the drawing: hand
/// it a reading, measure the ink, compare against [KvBurialGauge.positionFor].
/// That is L145's lesson made structural — a guard that records the value the
/// code handed it can only confirm that the code handed it that value.
class KvBurialGaugePainter extends CustomPainter {
  const KvBurialGaugePainter({
    required this.depth,
    required this.fill,
    required this.seated,
  });

  /// The observed depth, or null when there is none. **A null draws no fill at
  /// all** — an extent for a quantity nobody has is a fabricated reading, and
  /// BG-8 renders the unknown as a dash, which the words above already do.
  final int? depth;

  /// The rung's colour, mid-crossfade. It says what the fill would look like;
  /// **[depth] says whether there is one at all.**
  final Color? fill;

  /// How far the thousand mark has closed, 0 → 1. **An opacity, never a
  /// geometry**: the bracket's arms are drawn at fixed length and fade in.
  final double seated;

  /// The fill band's thickness, and the rule runs down its centre.
  static const double band = 3;

  /// Tick lengths below the band. The thousand mark is the tallest thing the
  /// painter draws, which is what makes it read as the end of the scale.
  /// A sub-mark is deliberately shorter than the shortest labelled tick, so
  /// the hierarchy reads at a glance: named decades stand off the line, their
  /// subdivisions only graze it.
  static const double subTick = 2;

  static const double shortTick = 3;
  static const double safeTick = 5;
  static const double finalTick = 8;

  /// How far the bracket's arms reach back over the track.
  static const double bracketArm = 4;

  /// Total painted height, derived from the marks rather than asserted (L121).
  static const double extent = band + finalTick;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    // `isAntiAlias: false` keeps a 1px engraved rule one pixel wide instead of
    // two half-lit ones — the difference between machined and smudged.
    // **The track has to READ as a track, and clear the 3:1 floor doing it.**
    // `datum` — the engraved rule a balance floats on — is 1.1:1 on the abyss
    // and vanished the moment the fill stopped, turning a reading on a scale
    // into an unbounded bar. `tick` fixed the look and still measured 1.85:1,
    // under WCAG 1.4.11's 3:1 for a non-text element that carries meaning
    // (`ux-auditor`, UX-5 — recomputed from the render, not from this comment).
    // So: `etch` at 3.04:1 for the axis, `inkMetaLow` at 5.32:1 for the marks,
    // which keeps the machined hierarchy — the graduations stand off the line
    // they sit on — with both tones above the floor.
    final rule = Paint()
      ..color = KvColor.etch
      ..strokeWidth = 1
      ..isAntiAlias = false;
    canvas.drawLine(Offset(0, band / 2), Offset(w, band / 2), rule);

    // **The fill: a rectangle, so the ink ends where the reading does.** A
    // stroked line with any cap but `butt` paints half a stroke width past
    // both ends, which is a constant added to every value and an unbounded lie
    // as the value goes to zero (BG-22).
    final n = depth;
    final paintFill = fill;
    if (n != null && paintFill != null) {
      final x = KvBurialGauge.positionFor(n) * w;
      if (x > 0) {
        canvas.drawRect(
          Rect.fromLTWH(0, 0, x, band),
          Paint()
            ..color = paintFill
            ..style = PaintingStyle.fill,
        );
      }
    }

    // **The graduations, and an unread scale flattens.** With the `0` origin
    // labelled, an empty track at a live zero and an empty track at an unknown
    // depth were the same ink — so the graphic asserted *"measured at zero"*
    // for a reading nobody has (`consensus-auditor`, UX-5). The marks and the
    // rule share one tone when there is nothing to read, which collapses the
    // hierarchy an instrument has when it is live; with a reading they stand
    // off the line they sit on. Both tones clear the 3:1 floor, and the words
    // carry the dash either way.
    final tick = Paint()
      ..color = n == null ? KvColor.etch : KvColor.inkMetaLow
      ..strokeWidth = 1
      ..isAntiAlias = false;
    // **The sub-marks: one even rhythm across the whole track.** Every step of
    // `1 / subDivisions` that is not already a labelled mark gets a short tick,
    // so the spacing is identical everywhere and the labelled marks sit ON the
    // grid rather than beside it. Drawn first, so a major tick is never
    // overdrawn by a minor one landing on the same pixel.
    final majors = KvBurialGauge.graduations
        .map(KvBurialGauge.positionFor)
        .toList();
    for (var i = 1; i < KvBurialGauge.subDivisions; i++) {
      final at = i / KvBurialGauge.subDivisions;
      if (majors.any((m) => (m - at).abs() < 1e-9)) continue;
      final x = (w * at).clamp(0.5, w - 0.5);
      canvas.drawLine(Offset(x, band), Offset(x, band + subTick), tick);
    }
    // **Every tick stands where the SCALE puts it, not where its index falls.**
    // Index spacing was right only while the scale was even quarters; under a
    // piecewise scale it drew a ruler that disagreed with its own fill.
    const marks = KvBurialGauge.graduations;
    for (var i = 0; i < marks.length - 1; i++) {
      final x = (w * KvBurialGauge.positionFor(marks[i])).clamp(0.5, w - 0.5);
      final len = marks[i] == KvBurial.safe ? safeTick : shortTick;
      canvas.drawLine(Offset(x, band), Offset(x, band + len), tick);
    }

    // **The thousand mark, an open bracket that seats** (§5). Finality is not
    // a fourth hue — it is this mark closing. Open, it is a hook: the upright
    // and one arm. Seated, the second arm arrives and the bracket is shut, so
    // the state is carried by the SHAPE and survives hue being removed
    // (BG-25). The words say `final` at the same instant, which is BG-7's
    // redundancy rather than BG-19's duplication: one is the mark, one is the
    // reading.
    final x = w - 0.5;
    canvas.drawLine(Offset(x, band), Offset(x, band + finalTick), tick);
    canvas.drawLine(
      Offset(x - bracketArm, band + 0.5),
      Offset(x, band + 0.5),
      tick,
    );
    if (seated > 0) {
      canvas.drawLine(
        Offset(x - bracketArm, band + finalTick - 0.5),
        Offset(x, band + finalTick - 0.5),
        Paint()
          ..color = (n == null ? KvColor.etch : KvColor.inkMetaLow).withValues(
            alpha: seated.clamp(0, 1),
          )
          ..strokeWidth = 1
          ..isAntiAlias = false,
      );
    }
  }

  @override
  bool shouldRepaint(KvBurialGaugePainter old) =>
      old.depth != depth || old.fill != fill || old.seated != seated;
}
