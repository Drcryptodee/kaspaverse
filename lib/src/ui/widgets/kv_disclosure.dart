import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_glyph.dart';

/// **A heading that carries its explanation behind an info mark.**
///
/// Founder ruling, 2026-09-08, made as a standing rule rather than a one-off:
///
/// > *"add an info icon infront of the main text, that when this icon is
/// > clicked, is shows more info … this is to make sure that the sheet is not
/// > too tall and space is well managed. infact this should be a rule so we
/// > dont have long texts showing unnecessarily in some screens where it could
/// > have just been minimized so an info button shows it on tap and snaps back
/// > when tapped again."*
///
/// ## What belongs behind the mark, and what never does
///
/// **Explanation** goes behind it: how a mechanism works, why a cost exists,
/// what a word means. **State and consequence never do.** A figure the user is
/// about to spend, a count they are consenting to, a refusal, a warning about
/// what an action cannot undo — those are the surface's subject, and hiding
/// the subject behind a tap is how a disclosure becomes a dark pattern rather
/// than a tidy-up. The test is simple: if a user who never taps the mark could
/// be surprised by what happens next, it is not explanation.
///
/// ## Why a mark and not an expander on the whole row
///
/// The heading stays a heading — tappable target on the mark alone, so a row
/// that also carries a control does not fight with it, and a screen reader
/// hears a labelled button rather than a paragraph that grew.
///
/// Closed is the resting state, and the mark is `inkMeta` — it is the fourth
/// thing on the line, behind the words, and BG-2 does not spend an emission on
/// a footnote. Open, it eases (BG-24) and the mark takes `primary` so the
/// screen says which one is speaking.
class KvDisclosure extends StatefulWidget {
  const KvDisclosure({
    super.key,
    required this.title,
    required this.detail,
    this.titleStyle,
    this.detailStyle,
    this.initiallyOpen = false,
  });

  /// The one line that is always visible.
  final String title;

  /// The paragraph behind the mark.
  final String detail;

  final TextStyle? titleStyle;
  final TextStyle? detailStyle;

  /// For the rare surface whose explanation IS the point on first visit.
  final bool initiallyOpen;

  @override
  State<KvDisclosure> createState() => _KvDisclosureState();
}

class _KvDisclosureState extends State<KvDisclosure> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.titleStyle ?? theme.textTheme.bodyMedium;
    final detail =
        widget.detailStyle ??
        theme.textTheme.bodySmall?.copyWith(
          color: KvColor.inkDim,
          fontFamily: KvFont.ui,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(widget.title, style: title)),
            const SizedBox(width: KvSpace.s),
            Semantics(
              button: true,
              // The mark's job said as a verb, and it names WHAT it explains
              // so a listener hears which heading it belongs to (BG-11).
              label: _open
                  ? 'Hide the explanation of ${widget.title}'
                  : 'Explain ${widget.title}',
              child: ExcludeSemantics(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _open = !_open),
                  child: SizedBox(
                    // Under BG-12's control floor on purpose: this is a
                    // footnote's mark, not a control the screen is for, and a
                    // 52 dp target beside a heading would set the heading's
                    // own height. It is comfortably tappable and it is never
                    // the only route to anything.
                    width: 32,
                    height: 24,
                    child: Center(
                      child: KvGlyphIcon(
                        KvGlyph.info,
                        size: 16,
                        tone: _open ? KvColor.primary : KvColor.inkMeta,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        // **Eases, and collapses to nothing** (BG-24). `AnimatedSize` over an
        // empty box rather than a visibility flip, so the sheet above it moves
        // once and smoothly rather than snapping twice.
        AnimatedSize(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : KvMotion.calm,
          curve: KvMotion.curve,
          alignment: Alignment.topCenter,
          child: _open
              ? Padding(
                  padding: const EdgeInsets.only(top: KvSpace.s),
                  child: Text(widget.detail, style: detail),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
