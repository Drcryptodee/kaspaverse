import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_amount.dart';
import 'kv_chrome.dart';

/// **The money plate** (§4, BG-28).
///
/// `plateHero` 32 on [KvColor.plate]: a `caps` label with the live indicator
/// nested into the opposite corner, the balance at `balanceHero`, its `≈` fiat
/// restatement, and the Send / Receive **raised** pair at 52 in the thumb arc.
///
/// **It holds only what is always true.** Pending money, money in flight and
/// the trust line are transient news and arrive in a strip *beneath* it
/// (BG-28) — reserving space for them inside the plate left a permanent gap
/// where the news usually is not, and letting them grow it moved the balance
/// three times for events the user did not cause.
///
/// **Neither pill is primary.** §4 gives the pair the raised form, so this
/// screen's emissions are the live dot and the ledger's active tab underline
/// — two of BG-2's three. UX-2's flip (the light moving to Receive on an empty
/// wallet) is superseded by that: on a proven zero, Send is *disabled and says
/// why*, which is the stronger statement and the one BG-12 asks for.
class KvMoneyPlate extends StatelessWidget {
  const KvMoneyPlate({
    super.key,
    required this.label,
    required this.figure,
    required this.indicator,
    this.fiat,
    this.onSend,
    this.onReceive,
    this.sendDisabledReason,
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

  final VoidCallback? onSend;
  final VoidCallback? onReceive;

  /// Non-null ⇒ Send is disabled and this is what it says (BG-12).
  final String? sendDisabledReason;

  /// The plate's own padding (§3: 18–22 inside a plate).
  static const EdgeInsets padding = EdgeInsets.fromLTRB(
    KvSpace.s20,
    KvSpace.s,
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
            if (fiat != null) ...[const SizedBox(height: KvSpace.xs), fiat!],
            const SizedBox(height: KvSpace.s20),
            _Pair(
              onSend: onSend,
              onReceive: onReceive,
              sendDisabledReason: sendDisabledReason,
            ),
          ],
        ),
      ),
    );
  }
}

/// Send and Receive, raised, 52 high, in the thumb arc (§4, BG-12).
class _Pair extends StatelessWidget {
  const _Pair({
    required this.onSend,
    required this.onReceive,
    required this.sendDisabledReason,
  });

  final VoidCallback? onSend;
  final VoidCallback? onReceive;
  final String? sendDisabledReason;

  @override
  Widget build(BuildContext context) {
    if (onSend == null && onReceive == null) return const SizedBox.shrink();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (onReceive != null)
          Expanded(
            child: KvAction.raised(
              label: 'Receive',
              height: KvSpace.controlThumb,
              onTap: onReceive!,
            ),
          ),
        if (onReceive != null && onSend != null)
          const SizedBox(width: KvSpace.sm),
        if (onSend != null)
          Expanded(
            child: KvAction.raised(
              label: 'Send',
              height: KvSpace.controlThumb,
              disabledReason: sendDisabledReason,
              onTap: onSend!,
            ),
          ),
      ],
    );
  }
}

/// **The `short` collapse, and the only one there is** (BG-33).
///
/// A 56 dp bar: the integer figure, the live indicator, and Send · Receive as
/// 44 dp pills. **The fraction returns on tap** — it is not deleted, it is put
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
                            if (!_full) ...[
                              const _Truncated(),
                              const SizedBox(width: KvSpace.s),
                              const _Unit(),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: KvSpace.sm),
              if (widget.onReceive != null)
                _BarPill(label: 'Receive', onTap: widget.onReceive!),
              // **A pill that cannot act and has nowhere to say why is not
              // shown at all** (BG-12). The plate renders the reason in
              // `inkMeta` under the control; a 56 dp bar has no line to put it
              // on, and a silent `shelf` pill is the disabled-with-no-reason
              // form the law forbids outright. On a proven zero there is
              // nothing to send, Receive is the sensible next act, and the
              // plate one rotation away still says why in words.
              if (widget.onReceive != null &&
                  widget.onSend != null &&
                  widget.sendDisabledReason == null)
                const SizedBox(width: KvSpace.s),
              if (widget.onSend != null && widget.sendDisabledReason == null)
                _BarPill(label: 'Send', onTap: widget.onSend!),
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
  const _BarPill({required this.label, required this.onTap});

  final String label;
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
            child: Text(
              label,
              maxLines: 1,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 15,
                height: 20 / 15,
                fontWeight: FontWeight.w600,
                color: KvColor.ink,
              ),
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
      color: KvColor.inkMeta,
    ),
  );
}

/// The unit, kept outside the figure's fit so it never scales under the 11 dp
/// readable floor — the same reason [KvAmount] keeps its own outside.
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
      color: KvColor.primaryMuted,
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
      letterSpacing: 1.1,
      color: KvColor.inkMeta,
    ),
  );
}
