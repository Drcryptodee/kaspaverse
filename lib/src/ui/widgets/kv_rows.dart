import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_glyph.dart';

/// **The default home of any list of eight or fewer rows** (§4, BG-1 as
/// amended).
///
/// Under Black Glass a plate had to justify itself and a bare list on the
/// ground was correct; in Deep V6 the row container is the default and the
/// bare list is the finding. It is [KvColor.plate] at [KvRadius.plate],
/// padded `6 / 20`, with **no drawn edge** — a plate on the ground has none
/// (BG-4) — and a [KvColor.hairline] between rows, never above the first.
///
/// The hairline is drawn by the container rather than by the row, because a
/// row that draws its own separator draws one at the top of the list the first
/// time somebody reorders the children.
class KvRowContainer extends StatelessWidget {
  const KvRowContainer({super.key, required this.children, this.header});

  /// The rows. Any widget: the container's only claim is the ground it paints
  /// and the line it puts between them.
  final List<Widget> children;

  /// An optional headline that sits **inside** the container above the first
  /// row — the Activity · Tokens tab row on the money screen. It takes no
  /// hairline: the tabs' own underline is the boundary.
  final Widget? header;

  /// The container's own padding (§3): 6 vertical, 20 horizontal.
  static const EdgeInsets padding = EdgeInsets.symmetric(
    vertical: 6,
    horizontal: 20,
  );

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: KvColor.plate,
        borderRadius: BorderRadius.circular(KvRadius.plate),
      ),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ?header,
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const _Hairline(),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// The one line inside a container (§1.2). One physical pixel would vanish on a
/// 3× panel; 1 dp is the demarcation the law names.
class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 1, child: ColoredBox(color: KvColor.hairline));
}

/// The 40 dp disc that opens a row (§4).
///
/// *Ours* is [KvColor.tealTint] + a [KvColor.primaryMuted] glyph; a value
/// context takes the hue's own tint with the hue's glyph; neutral is
/// [KvColor.chip] + [KvColor.ink]. Never [KvColor.primary] — an avatar or a
/// socket that emits is BG-2's most common finding, pointed the wrong way.
class KvRowDisc extends StatelessWidget {
  const KvRowDisc({
    super.key,
    required this.mark,
    required this.tint,
    required this.tone,
    this.size = KvSpace.rowDisc,
    this.stroke,
    this.ring,
  });

  /// *Ours*: the wallet's own, a contact we hold, an active destination.
  const KvRowDisc.ours({Key? key, required KvGlyph mark, Color? ring})
    : this(
        key: key,
        mark: mark,
        tint: KvColor.tealTint,
        tone: KvColor.primaryMuted,
        ring: ring,
      );

  /// Neutral: a row that is not about value and is not ours.
  const KvRowDisc.neutral({Key? key, required KvGlyph mark})
    : this(key: key, mark: mark, tint: KvColor.chip, tone: KvColor.inkDim);

  final KvGlyph mark;
  final Color tint;
  final Color tone;
  final double size;

  /// Overrides the glyph's stroke **on the 24 dp grid**. A direction arrow
  /// inside a value disc takes [KvGlyphSpec.strokeArrow] (BG-25); everything
  /// else leaves it null.
  final double? stroke;

  /// A 1 dp ring on the tint — the drawer's active socket, and nothing else
  /// so far (§4).
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tint,
        shape: BoxShape.circle,
        border: ring == null ? null : Border.all(color: ring!),
      ),
      child: KvGlyphIcon(mark, size: size * 0.5, tone: tone, stroke: stroke),
    );
  }
}

/// **One row, 64 dp** (§4, BG-33).
///
/// 40 disc · [title] in `rowTitle` · an optional sub-line · a trailing value,
/// with an optional `metaMono` line under it. The height is fixed **in every
/// window class** — a tablet shows more rows, never smaller ones — and it is a
/// *minimum* rather than a clamp, because BG-14 requires the row to survive
/// the user's 1.3× font setting and a clamped row would clip instead.
class KvRow extends StatefulWidget {
  const KvRow({
    super.key,
    this.leading,
    required this.title,
    this.sub,
    this.subWidget,
    this.trailing,
    this.trailingMeta,
    this.onTap,
    this.semanticLabel,
  }) : assert(
         sub == null || subWidget == null,
         'a row has one sub-line: a string or a widget, never both',
       );

  /// The 40 dp disc, or any leading object of that size. Null ⇒ the title
  /// starts at the container's own inset.
  final Widget? leading;

  final String title;

  /// `sub` [KvColor.inkMeta] — and [KvColor.inkDim] on a [KvColor.chip]
  /// ground, which BG-14 requires (§1.4).
  final String? sub;

  /// A composed sub-line — the ledger's lifecycle mark, for instance.
  final Widget? subWidget;

  /// The value, the toggle, or an [KvColor.etch] chevron.
  final Widget? trailing;

  /// A `metaMono` line under [trailing] — the ledger's time.
  final Widget? trailingMeta;

  /// Null ⇒ the row is a record, not a control.
  final VoidCallback? onTap;

  /// What a screen reader announces for the whole row. Defaults to [title].
  final String? semanticLabel;

  /// §4: fixed in every window class (BG-33).
  static const double height = KvSpace.row;

  @override
  State<KvRow> createState() => _KvRowState();
}

class _KvRowState extends State<KvRow> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final leading = widget.leading;
    final title = widget.title;
    final sub = widget.sub;
    final trailing = widget.trailing;
    final trailingMeta = widget.trailingMeta;
    final onTap = widget.onTap;
    final lead = leading;
    final trail = trailing;
    final meta = trailingMeta;
    final subLine = widget.subWidget;
    final body = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: KvRow.height),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: KvSpace.s),
        child: Row(
          children: [
            if (lead != null) ...[lead, const SizedBox(width: KvSpace.sm)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 15,
                      height: 20 / 15,
                      fontWeight: FontWeight.w600,
                      color: KvColor.ink,
                    ),
                  ),
                  ?subLine,
                  if (sub != null)
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 13,
                        height: 18 / 13,
                        color: KvColor.inkMeta,
                      ),
                    ),
                ],
              ),
            ),
            if (trail != null || meta != null) ...[
              const SizedBox(width: KvSpace.sm),
              // **Two `Expanded` children, and both halves of that matter.**
              //
              // Unbounded, the trailing column takes its intrinsic width, so
              // `KvAmount`'s own `FittedBox(scaleDown)` has nothing to fit
              // inside and the figure cannot shrink: measured at 320 dp /
              // 1.3×, a 1,234.56789012 KAS row drove the title to **0 dp** and
              // overflowed the row by 19, and a 123,456 KAS row painted the
              // figure past the screen edge — BG-5's one prohibition (a figure
              // clips instead of scaling) and BG-14's floor, together. **No
              // `find.text` could see it**: a finder matches a 0 dp `Text`
              // (L131), which is why the gate was green through it and
              // `ux-auditor` was not.
              //
              // `Flexible` bounds it but leaves the leftover *after* the last
              // child, so a short amount floated ~60 dp clear of the gutter and
              // the ledger's right edge read ragged again — **A11, the
              // founder's own finding, undone by the fix for something else.**
              // Two `Expanded` children split the free space with nothing left
              // over, so the trailing column's right edge IS the row's, and it
              // still has a bounded width to scale inside.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [?trail, ?meta],
                ),
              ),
            ],
          ],
        ),
      ),
    );
    final tap = onTap;
    if (tap == null) return body;
    // **A `GestureDetector`, not an `InkWell`.** There is no ripple in this
    // language, so the only thing an ink response would give us is a hard
    // dependency on a `Material` ancestor — and the drawer panel sits above
    // every `Scaffold` in the app, which is exactly where that dependency
    // throws. A pressed row lifts one step (§1.1) and that is the whole
    // interaction.
    return Semantics(
      button: true,
      label: widget.semanticLabel ?? title,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: tap,
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _down ? KvColor.chipPressed : Colors.transparent,
              borderRadius: BorderRadius.circular(KvRadius.row),
            ),
            child: body,
          ),
        ),
      ),
    );
  }
}
