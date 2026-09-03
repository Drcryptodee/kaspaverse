import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_glyph.dart';

/// The furniture every full-screen surface shares: the top bar it hangs
/// under, the label that names a section, and the pill it ends on.
///
/// They live here because several screens wear them, and a second private copy
/// of a bar is how two screens start disagreeing about where a back button is
/// and how big a title is (C7).
///
/// **`KvTopBar` was called `KvRail` until UX-R1.** §3a.3 gives that name to the
/// 80 dp standing navigation rail, and one name for two unrelated objects is
/// BG-21 at the widget layer. The thing here is a back-button title bar and is
/// now named for what it is; the rail lives in `kv_drawer.dart`.

/// A back target, a centred title, and the balance that keeps the title
/// centred. Nothing is painted in the status bar's 52dp (BG-14) — the caller
/// reserves that above this.
class KvTopBar extends StatelessWidget {
  const KvTopBar({super.key, required this.title, required this.onBack});

  final String title;

  /// Null ⇒ **the way out is closed right now**, and the chevron says so
  /// rather than looking live and doing nothing (BG-12). The ceremony uses it
  /// while a broadcast is in flight: there is nothing left to cancel, and a
  /// control that silently ignores a tap teaches distrust of every other
  /// control on the screen.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(KvSpace.m, KvSpace.s, KvSpace.m, 0),
      child: Row(
        children: [
          Semantics(
            button: true,
            enabled: onBack != null,
            label: 'Back',
            child: InkWell(
              onTap: onBack,
              borderRadius: BorderRadius.circular(KvRadius.control),
              child: SizedBox(
                width: KvSpace.touchTarget,
                height: KvSpace.touchTarget,
                child: Center(
                  child: RotatedBox(
                    quarterTurns: 2,
                    child: KvGlyphIcon(
                      KvGlyph.chevron,
                      // `etch` is the disabled tone: decorative by design, and
                      // it never carries information alone — what the exit is
                      // waiting for is on the screen in words beneath it.
                      tone: onBack == null ? KvColor.etch : KvColor.inkNav,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Expanded rather than two Spacers: at 1.3x on a 320dp screen a
          // title can be wider than what is left between two 48dp targets, and
          // a Spacer cannot give any of it back. A label WRAPS (BG-14); only a
          // number is forbidden from doing so.
          //
          // **The cap stays at 2, and it was nearly changed on a false
          // reading.** UX-4's `TextPainter` guard first reported *"Confirm
          // contact request"* — the ceremony's longest heading — clipped in
          // the 192dp this rail leaves at 320dp/1.3×. It was not: that run had
          // not loaded the bundled faces, and the test fallback's square
          // em-boxes overstate every label by roughly a factor of two. With
          // Inter loaded the title fits two lines with room. The cap is still
          // a magic number, but the guard now re-measures every ceremony
          // heading at the floor, so a longer title fails a test instead of
          // clipping in silence (L121: a measurement is only as true as what
          // it measured).
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                fontVariations: KvWeight.w600,
                color: KvColor.inkDim,
              ),
            ),
          ),
          // Balances the back target so the title sits centred.
          const SizedBox(width: KvSpace.touchTarget),
        ],
      ),
    );
  }
}

/// A tick, then a sentence-case label — where an instrument silk-screens the
/// name of a section.
class KvRuledLabel extends StatelessWidget {
  const KvRuledLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(width: KvSpace.s, height: 1, color: KvColor.inkMeta),
      const SizedBox(width: KvSpace.s),
      // Flexible for the same reason as the rail's title: at 1.3x this label
      // can be wider than a 320dp gutter leaves it.
      Flexible(
        child: Text(
          // **Section labels are set in capitals** (UX-5 device sitting).
          // A ruled label is chrome, not content: caps on a wider track read
          // as a machined heading and stop competing with the datum beneath
          // them, which on the transaction detail is the entire point of the
          // screen. The size drops a point because caps carry more visual
          // weight than lowercase at the same ramp — still clear of BG-14's
          // 11 dp floor.
          text.toUpperCase(),
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 12,
            height: 16 / 12,
            letterSpacing: 0.8,
            color: KvColor.inkDim,
          ),
        ),
      ),
    ],
  );
}

/// **The pill a screen acts on** (§4).
///
/// Three forms, one widget, because a second rendering of a pill is how two
/// screens start disagreeing about what a button looks like:
///
///  * **primary** — [KvColor.primary] fill, [KvColor.onPrimary] label at 600.
///    **One per screen** (BG-2), and it is one of the three emissions.
///  * **raised** — [KvColor.chip] fill, [KvColor.ink] label; pressed
///    [KvColor.chipPressed]. The secondary action, and the money plate's
///    Send / Receive pair.
///  * **disabled** — [KvColor.shelf] fill, [KvColor.etch] label, and the
///    reason in [KvColor.inkMeta] underneath (BG-12).
///
/// Promoted out of `home_screen.dart` at UX-4 rather than copied a third time.
/// `node_screen.dart` keeps its own, deliberately — it is never primary, it
/// left-aligns its reason and it sits in a different register; folding it in
/// here would be a re-skin of a settled surface, not a de-duplication.
///
/// **BG-12: a disabled control always says why.** [disabledReason] is both the
/// disable switch and the sentence under the control — they cannot drift apart
/// because they are one field.
class KvAction extends StatefulWidget {
  const KvAction({
    super.key,
    required this.label,
    required this.primary,
    required this.onTap,
    this.disabledReason,
    this.mark,
    this.height = KvSpace.control,
  });

  /// The raised form: `chip` fill, `ink` label. Sugar for `primary: false`,
  /// which is the same rendering — the named constructor exists so a call site
  /// says which pill it means rather than what it is not.
  const KvAction.raised({
    Key? key,
    required String label,
    required VoidCallback onTap,
    String? disabledReason,
    KvGlyph? mark,
    double height = KvSpace.control,
  }) : this(
         key: key,
         label: label,
         primary: false,
         onTap: onTap,
         disabledReason: disabledReason,
         mark: mark,
         height: height,
       );

  /// Verb plus object, never "Confirm" (BG-11).
  final String label;

  final bool primary;
  final VoidCallback onTap;

  /// Null ⇒ enabled. Non-null ⇒ disabled, and this is what it says.
  final String? disabledReason;

  /// An optional 18 dp glyph before the label (§4).
  final KvGlyph? mark;

  /// 56 by default; the money plate's thumb pair is 52
  /// ([KvSpace.controlThumb], §4).
  final double height;

  /// The glyph's box (§4).
  static const double glyph = 18;

  @override
  State<KvAction> createState() => _KvActionState();
}

class _KvActionState extends State<KvAction> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.disabledReason != null;
    final lit = widget.primary && !disabled;
    // Every control is a stadium (§3): the `KvAction` 8 dp trial is closed.
    const radius = KvRadius.control;
    final Color fill;
    if (disabled) {
      fill = KvColor.shelf;
    } else if (lit) {
      fill = _down ? KvColor.primaryPressed : KvColor.primary;
    } else {
      fill = _down ? KvColor.chipPressed : KvColor.chip;
    }
    final ink = disabled
        ? KvColor.etch
        : (lit ? KvColor.onPrimary : KvColor.ink);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          enabled: !disabled,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: disabled ? null : widget.onTap,
            onTapDown: disabled ? null : (_) => setState(() => _down = true),
            onTapUp: disabled ? null : (_) => setState(() => _down = false),
            onTapCancel: disabled ? null : () => setState(() => _down = false),
            child: AnimatedContainer(
              duration: KvMotion.fast,
              curve: KvMotion.curve,
              height: widget.height,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(radius),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.mark != null) ...[
                    KvGlyphIcon(widget.mark!, size: KvAction.glyph, tone: ink),
                    const SizedBox(width: KvSpace.s),
                  ],
                  Flexible(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: KvFont.ui,
                        // §2 `button`: 16, and 15 on a 52-high control.
                        fontSize: widget.height >= KvSpace.control ? 16 : 15,
                        height: 20 / 16,
                        fontWeight: FontWeight.w600,
                        fontVariations: KvWeight.w600,
                        color: ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (disabled) ...[
          const SizedBox(height: KvSpace.xs),
          Text(
            widget.disabledReason!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 11,
              height: 15 / 11,
              color: KvColor.inkMeta,
            ),
          ),
        ],
      ],
    );
  }
}
