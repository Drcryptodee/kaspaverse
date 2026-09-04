import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_amount.dart';
import 'kv_glyph.dart';

/// **The money plate** (§4, BG-28, render `S1 · Home`).
///
/// `plateHero` 32 on [KvColor.plate]: a `caps` label with the live indicator
/// nested into the opposite corner, the balance at `balanceHero`, its `≈` fiat
/// restatement, then a **hairline** and the chain clock beneath it — the one
/// internal division the plate has, and the render draws it (D-261).
///
/// **Send and Receive are not in the plate.** The render pins them as a bar at
/// the foot of the screen, Send lit; UX-R1 built them as a raised pair inside
/// the plate on §4's transcription (D-255), and the render outranks the
/// transcription (D-259). The plate is now a reading, not a control surface —
/// which is also what BG-28 was asking for.
///
/// **It holds only what is always true.** Pending money, money in flight and
/// the trust line are transient news and arrive in a strip *beneath* it
/// (BG-28) — reserving space for them inside the plate left a permanent gap
/// where the news usually is not, and letting them grow it moved the balance
/// three times for events the user did not cause.
///
class KvMoneyPlate extends StatelessWidget {
  const KvMoneyPlate({
    super.key,
    required this.label,
    required this.figure,
    required this.indicator,
    this.fiat,
    this.chainClock,
  });

  /// The `caps` label, top left. Sentence given in normal case; the widget
  /// capitalises, because a caller should not have to know the ramp.
  final String label;

  /// The balance, at `balanceHero`. A widget rather than a `BigInt` so the
  /// screen keeps ownership of freshness, streaming and semantics.
  final Widget figure;

  /// The live indicator, nested into the top-right corner (A8) — the network
  /// chip, whose lamp carries "fine" alone (BG-8).
  final Widget indicator;

  /// The `≈` restatement. Null ⇒ the user switched it off, or no rate seam is
  /// wired: **the line is gone, never a dash** (D-193).
  final Widget? fiat;

  /// **The chain clock, under the balance** (A4, founder ruling 2026-09-04,
  /// D-256). It reads the DAA score the wallet is measuring everything else
  /// against, and it belongs in the plate under BG-28 because it is always
  /// true: a number when the link is live, `—` when it is not.
  ///
  /// It streams (D-226, BG-18) and that is now explicitly seated in BG-8
  /// rather than tolerated against it: **a chain counter that stops IS the
  /// stale signal**, so its motion is the reading rather than decoration. What
  /// BG-8 still forbids on a settled screen is a spinner, a shimmer, a loader
  /// or a meter — none of which carry a value.
  final Widget? chainClock;

  /// The plate's own padding (§3: 18–22 inside a plate). 12 at the top because
  /// the indicator chip's 44 dp target overhangs its 34 dp body.
  static const EdgeInsets padding = EdgeInsets.fromLTRB(
    KvSpace.s20,
    KvSpace.sm,
    KvSpace.s20,
    KvSpace.s20,
  );

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: KvColor.plate,
        borderRadius: BorderRadius.circular(KvRadius.plateHero),
        // A plate on the ground has no edge (BG-4).
      ),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                // The label yields, never the indicator: the indicator is a
                // control with a destination, and the thing that gives way
                // under a squeeze must never be the one the user needs to
                // press (F5's lesson).
                Expanded(child: _Caps(label)),
                const SizedBox(width: KvSpace.s),
                indicator,
              ],
            ),
            const SizedBox(height: KvSpace.s),
            figure,
            if (fiat != null) ...[const SizedBox(height: KvSpace.s), fiat!],
            if (chainClock != null) ...[
              // The render's one line inside the plate: 16 under the fiat,
              // 14 over the clock, `hairline` the whole inner width (S1,
              // measured at 264 dp on the 393 frame).
              const SizedBox(height: KvSpace.m),
              // `controlEdge` (12% white), not `hairline` (7%): at 7% the
              // line did not read on the V60 at all — the founder asked for
              // the line the render draws, which measures 19 units over the
              // plate, and 12% lands there (D-262).
              const SizedBox(
                height: 1,
                child: ColoredBox(color: KvColor.controlEdge),
              ),
              const SizedBox(height: KvSpace.s14),
              chainClock!,
            ],
          ],
        ),
      ),
    );
  }
}

/// **The `short` collapse, and the only one there is** (BG-33).
///
/// A 56 dp bar: the integer figure, the live indicator, and Send · Receive as
/// 44 dp pills wearing their arrows (render `R5 · expanded · short`: both
/// raised, `↗ Send` then `↙ Receive`). **The fraction returns on tap** — it is not deleted, it is put
/// one tap away, because a phone on its side has 412 dp of height and the
/// ledger is what the user turned it for.
class KvMoneyBar extends StatefulWidget {
  const KvMoneyBar({
    super.key,
    required this.sompi,
    required this.indicator,
    this.stale = false,
    this.onSend,
    this.onReceive,
    this.sendDisabledReason,
  });

  /// The balance itself, because this widget decides how much of it to show.
  final BigInt? sompi;
  final Widget indicator;
  final bool stale;
  final VoidCallback? onSend;
  final VoidCallback? onReceive;
  final String? sendDisabledReason;

  /// §3a.1.
  static const double height = 56;

  /// The pills in the bar.
  static const double pill = 44;

  @override
  State<KvMoneyBar> createState() => _KvMoneyBarState();
}

class _KvMoneyBarState extends State<KvMoneyBar> {
  bool _full = false;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: KvMoneyBar.height),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: KvColor.plate,
          borderRadius: BorderRadius.circular(KvRadius.control),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: KvSpace.m),
          child: Row(
            children: [
              widget.indicator,
              const SizedBox(width: KvSpace.sm),
              Flexible(
                child: Semantics(
                  button: true,
                  label: _full
                      ? 'Balance in full. Tap to shorten'
                      : 'Balance, whole units. Tap for the full figure',
                  child: ExcludeSemantics(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _full = !_full),
                      // **The whole figure scales as one group.** The
                      // abbreviated form is three runs — digits, the
                      // truncation mark, the unit — and they belong together:
                      // scaling only the digits left a gap between them, and
                      // leaving the group unbounded overflowed the bar by 12
                      // at the `expanded short` pane width. One `FittedBox`
                      // over the group is bounded *and* tight.
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            // `IntrinsicWidth` so the figure sizes to its
                            // digits: `KvAmount`'s own `Flexible` otherwise
                            // takes the share it is offered and left-aligns
                            // inside it, which put 6 dp between `25` and the
                            // truncation mark and made one figure read as two
                            // objects.
                            IntrinsicWidth(
                              child: KvAmount(
                                widget.sompi,
                                role: KvAmountRole.row,
                                // 24 rather than `balanceHero`'s 48: the bar is
                                // 56 dp tall and the figure has to sit inside it
                                // with a pill. The composition asking for an
                                // exception, out loud (§2's ramp is the rule).
                                size: 24,
                                // **The whole point of the collapse.** Whole
                                // units by default; every significant digit on
                                // tap. `0` is "trim to nothing", and `KvAmount`
                                // already refuses to erase a dust balance that
                                // way.
                                fractionDigits: _full ? null : 0,
                                stale: widget.stale,
                                showUnit: _full,
                              ),
                            ),
                            // **The abbreviation is marked, or it is a lie.**
                            // `25 KAS` for 25.977922 with nothing to say so
                            // reads as an exact figure — BG-5 forbids a
                            // truncation that presents itself as a value. The
                            // screen reader was told and the eye was not
                            // (`ux-auditor`, UX-R1). The ellipsis sits where
                            // the fraction will land, so the tap that reveals
                            // it is the obvious next move.
                            if (!_full) const _Truncated(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // **The unit sits OUTSIDE the fit, and that is the whole point
              // of its floor.** Inside, `max(readableFloor, …)` is computed and
              // then multiplied away by the very scale that saved the figure —
              // measured at a 340 dp pane / 1.3×, `KAS` painted at **7.98 dp**
              // against an 11 dp law. It is the identical defect `KvAmount`
              // rescued its own unit from at UX-4, reintroduced one widget
              // over by grouping the runs (`ux-auditor`, UX-R1).
              if (!_full) ...[const SizedBox(width: KvSpace.s), const _Unit()],
              const SizedBox(width: KvSpace.sm),
              // **`Receive · Send`, the foot bar's order (S1).** R5 draws the
              // bar the other way round; a phone turned on its side must not
              // swap the two verbs' seats (BG-21), so S1's order rules in
              // every class and R5's is recorded as superseded (§9.21).
              if (widget.onReceive != null)
                _BarPill(
                  label: 'Receive',
                  mark: KvGlyph.arrowIn,
                  onTap: widget.onReceive!,
                ),
              if (widget.onReceive != null && widget.onSend != null)
                const SizedBox(width: KvSpace.s),
              // **A pill that cannot act is replaced by the reason, not
              // deleted** (BG-12, BG-24). A 56 dp bar has no line beneath a
              // control to put a reason on, and a silent `shelf` pill is the
              // disabled-with-no-reason form the law forbids outright — but
              // simply dropping it says nothing either, and drops it without
              // the motion that accounts for it. The slot cross-fades between
              // the control and the sentence, so `short` still tells the user
              // why the money door is closed.
              if (widget.onSend != null)
                AnimatedSwitcher(
                  duration: KvMotion.calm,
                  switchInCurve: KvMotion.curve,
                  switchOutCurve: KvMotion.curve,
                  child: widget.sendDisabledReason == null
                      ? _BarPill(
                          key: const ValueKey('send'),
                          label: 'Send',
                          mark: KvGlyph.arrowOut,
                          onTap: widget.onSend!,
                        )
                      : Padding(
                          key: const ValueKey('reason'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: KvSpace.s,
                          ),
                          child: Text(
                            widget.sendDisabledReason!,
                            maxLines: 2,
                            style: const TextStyle(
                              fontFamily: KvFont.ui,
                              fontSize: 11,
                              height: 16 / 11,
                              fontWeight: FontWeight.w500,
                              fontVariations: KvWeight.w500,
                              color: KvColor.inkMeta,
                            ),
                          ),
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A 44 dp pill inside the bar. It is [KvAction]'s raised form at the bar's
/// own height — not a second rendering: same fill, same ink, same stadium.
/// **There is no disabled form**: a control that cannot act has nowhere in a
/// 56 dp bar to say why, so the bar omits it instead (BG-12).
class _BarPill extends StatelessWidget {
  const _BarPill({
    super.key,
    required this.label,
    required this.mark,
    required this.onTap,
  });

  final String label;
  final KvGlyph mark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            height: KvMoneyBar.pill,
            padding: const EdgeInsets.symmetric(horizontal: KvSpace.m),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: KvColor.chip,
              borderRadius: BorderRadius.circular(KvRadius.control),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                KvGlyphIcon(mark, size: 16, tone: KvColor.ink),
                const SizedBox(width: KvSpace.s),
                Text(
                  label,
                  maxLines: 1,
                  style: const TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 15,
                    height: 20 / 15,
                    fontWeight: FontWeight.w600,
                    fontVariations: KvWeight.w600,
                    color: KvColor.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The mark that says a figure has been abbreviated: an ellipsis in the
/// fraction's own tone and size, exactly where the fraction appears when the
/// bar is tapped.
///
/// **The ellipsis alone, without a leading `.`** — in a monospace face the
/// full stop is centred in its own cell, so `.…` opened a 6 dp hole between
/// the integer and the mark and one figure read as two objects. The mark says
/// *there is more*, which is the whole job.
class _Truncated extends StatelessWidget {
  const _Truncated();

  @override
  Widget build(BuildContext context) => const Text(
    '…',
    style: TextStyle(
      fontFamily: KvFont.mono,
      fontSize: 12,
      height: 1.14,
      fontWeight: FontWeight.w500,
      fontVariations: KvWeight.w500,
      color: KvColor.inkMeta,
    ),
  );
}

/// The unit, kept outside the figure's fit so it never scales under the 11 dp
/// readable floor — the same reason [KvAmount] keeps its own outside. `inkMeta`
/// like the plate's (D-261): the render never sets the unit in teal.
class _Unit extends StatelessWidget {
  const _Unit();

  @override
  Widget build(BuildContext context) => const Text(
    'KAS',
    style: TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 11,
      height: 16 / 11,
      fontWeight: FontWeight.w600,
      fontVariations: KvWeight.w600,
      color: KvColor.inkMeta,
    ),
  );
}

/// A `caps` label (§2): Jakarta 11 / 16, 600, +0.10em, uppercase.
class _Caps extends StatelessWidget {
  const _Caps(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 11,
      height: 16 / 11,
      fontWeight: FontWeight.w600,
      fontVariations: KvWeight.w600,
      letterSpacing: 1.1,
      color: KvColor.inkMeta,
    ),
  );
}
