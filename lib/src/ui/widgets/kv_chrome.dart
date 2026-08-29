import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_glyph.dart';

/// The two pieces of furniture every full-screen Black Glass surface shares:
/// the rail it hangs under, and the label that names a section.
///
/// They live here because there are now two screens wearing them — the node
/// surface and Settings — and a second private copy of a rail is how two
/// screens start disagreeing about where a back button is and how big a title
/// is. One rendering, one file (C7).

/// A back target, a centred title, and the balance that keeps the title
/// centred. Nothing is painted in the status bar's 52dp (BG-14) — the caller
/// reserves that above this.
class KvRail extends StatelessWidget {
  const KvRail({super.key, required this.title, required this.onBack});

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
                      KvMark.chevron,
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
          text,
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 13,
            height: 18 / 13,
            color: KvColor.inkDim,
          ),
        ),
      ),
    ],
  );
}

/// The primary (or secondary) action a screen ends on.
///
/// Promoted out of `home_screen.dart` at UX-4 rather than copied a third time:
/// Send, the signing ceremony and the money screen's thumb arc are the same
/// control, and a second private copy of a rail is exactly how two screens
/// started disagreeing about where a back button is (the reason this file
/// exists). `node_screen.dart` keeps its own, deliberately — it is never
/// primary, it left-aligns its reason and it sits in a different register;
/// folding it in here would be a re-skin of a settled surface, not a
/// de-duplication.
///
/// **BG-12: a disabled control always says why.** [disabledReason] is both the
/// disable switch and the sentence under the control — they cannot drift apart
/// because they are one field.
class KvAction extends StatelessWidget {
  const KvAction({
    super.key,
    required this.label,
    required this.primary,
    required this.onTap,
    this.disabledReason,
  });

  /// Verb plus object, never "Confirm" (BG-11).
  final String label;

  final bool primary;
  final VoidCallback onTap;

  /// Null ⇒ enabled. Non-null ⇒ disabled, and this is what it says.
  final String? disabledReason;

  @override
  Widget build(BuildContext context) {
    final disabled = disabledReason != null;
    final lit = primary && !disabled;
    // **Trialling the pre-UX-2 radius** (founder, on glass, still deciding).
    // D-194 made every control a pill so that "at a glance the things you press
    // are round and the things you read are milled" — these are the loudest
    // controls in the app, so if the pill language is wrong anywhere it shows
    // here first. Reverting them alone means the money actions and the chip
    // speak different shapes until the call is settled; recorded, not hidden.
    const radius = KvRadius.button;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          enabled: !disabled,
          child: InkWell(
            onTap: disabled ? null : onTap,
            borderRadius: BorderRadius.circular(radius),
            child: Container(
              height: KvSpace.control,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                // Teal fills exactly one thing on a screen: the single primary
                // action (BG-2). Everything else recedes to `control`.
                color: lit ? KvColor.primary : KvColor.control,
                borderRadius: BorderRadius.circular(radius),
                border: lit ? null : Border.all(color: KvColor.edgeHi),
              ),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 15,
                  height: 20 / 15,
                  fontWeight: FontWeight.w600,
                  color: lit
                      ? KvColor.onPrimary
                      : (disabled ? KvColor.inkMeta : KvColor.ink),
                ),
              ),
            ),
          ),
        ),
        if (disabled) ...[
          const SizedBox(height: KvSpace.xs),
          Text(
            disabledReason!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 11,
              height: 15 / 11,
              color: KvColor.inkMetaLow,
            ),
          ),
        ],
      ],
    );
  }
}
