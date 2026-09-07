import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_check.dart';
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
  const KvRowContainer({
    super.key,
    required this.children,
    this.header,
    this.divided = true,
    this.inset = KvRowContainer.padding,
    this.ground = KvColor.plate,
  });

  /// The ground it paints. `plate` is a card on a screen; **`chip` is a card
  /// inside a sheet** (§1.1), which had no way to be said until the receive
  /// picker put a card on a `plate` sheet and drew nothing at all — two
  /// identical `#121717` surfaces, one nominally on top of the other
  /// (`ux-auditor`, D-293). A caller on a lighter ground must re-tone what
  /// sits on it: `inkMeta` is 4.30 on `chip` and BG-14 forbids it carrying
  /// information there.
  final Color ground;

  /// A hairline between children. Off for a card that holds one composed
  /// block — `T5`'s node row, the own-node card — where a rule would divide
  /// nothing (founder, on glass 2026-09-05: every card on a screen shares the
  /// home's topography — `plate`, radius 28, **no border**).
  final bool divided;

  /// The card's inner padding; the house 6 / 20 by default, 20 all round for
  /// a card built around a single row or a gauge.
  final EdgeInsets inset;

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
        color: ground,
        borderRadius: BorderRadius.circular(KvRadius.plate),
      ),
      child: Padding(
        padding: inset,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ?header,
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0 && divided) const KvHairline(),
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
///
/// Public since `T4`: a card whose rows live inside their **own** scroll view
/// cannot get its rules from [KvRowContainer], which only draws between the
/// children it is handed. The list draws them itself, from the same part, so
/// there is still one hairline in the system rather than a second opinion.
class KvHairline extends StatelessWidget {
  const KvHairline({super.key});

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
  ///
  /// **The glyph is `ink`** — §2a rule 3 ("in a `chip` disc or icon button it
  /// is `ink`") and `T1 · Settings` measured, where the Wallet, Messages,
  /// Appearance, Notifications, Privacy and About discs all draw their mark at
  /// `#F2F5F4`. It was `inkDim`, which is the drawer's *inactive* seat doing
  /// the default's job; the drawer now states that tone where it means it.
  const KvRowDisc.neutral({
    Key? key,
    required KvGlyph mark,
    double size = KvSpace.rowDisc,
  }) : this(
         key: key,
         mark: mark,
         tint: KvColor.chip,
         tone: KvColor.ink,
         size: size,
       );

  final KvGlyph mark;

  final Color tint;
  final Color tone;
  final double size;

  /// **The person disc is 44, not 40** (`M1` measured: the tint runs
  /// y 217.0..261.0 at 4×). A name's monogram needs the room a 24 dp glyph on
  /// a 40 dp disc does not; every other row keeps [KvSpace.rowDisc].
  ///
  /// The disc itself is [KvContactAvatar] — §4 rules a contact-we-hold `chip`
  /// + `ink` and retired the teal treatment at v4.8 off `S6a`/`S6`/`S8`. A
  /// `KvRowDisc.initial` briefly lived here drawing `tealTint` +
  /// `primaryMuted`, which is the face §4 reserves for the wallet's OWN mark:
  /// one contact then wore two faces across Send and Messages (`ux-auditor`
  /// BLOCK, UX-R5, BG-21).
  static const double person = 44;

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

/// **The word under a trailing figure** — `Locked`, `Pending`: what the number
/// above it is not saying.
///
/// BG-7's amber, because both readings mean *this is not settled money you can
/// move right now*, and never `ok`, because nothing here has settled. Promoted
/// out of `wallet_screen.dart` at UX-R4b for the receive picker, which draws
/// the same word beside the same figure (BG-21).
class KvRowMeta extends StatelessWidget {
  const KvRowMeta(this.word, {super.key});

  final String word;

  @override
  Widget build(BuildContext context) => Text(
    word,
    style: const TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 11,
      height: 16 / 11,
      fontWeight: FontWeight.w600,
      fontVariations: KvWeight.w600,
      color: KvColor.warn,
    ),
  );
}

/// **`12 more fresh addresses · Show`** — the row that opens a fold.
///
/// One figure, the words that give it meaning, and the word that opens it. The
/// figure is mono and the words are not (BG-30); the **whole row** is the
/// target at BG-12's 52, which is why it is a `SizedBox` and not a text button.
///
/// Promoted out of `wallet_screen.dart` at UX-R4b. The receive picker's copy
/// had already drifted in three ways nobody would have caught by eye — `Show`
/// in `primary` 13 instead of `ink` 14, no gap at all between the count and
/// the word, and no `maxLines`, so at 320 dp / 1.3× the count wrapped into two
/// lines pressed against `Show` (`ux-auditor`, D-293). Two copies of a row is
/// how two screens start disagreeing about what opening a fold looks like
/// (BG-21).
class KvFoldRow extends StatelessWidget {
  const KvFoldRow({
    super.key,
    required this.figure,
    required this.words,
    required this.onTap,
    required this.semanticLabel,
    this.action = 'Show',
    this.tone = KvColor.inkMeta,
  });

  /// The count. Mono, and never grouped — a fold holds tens, not thousands.
  final int figure;

  /// What the count is of, with its own leading space.
  final String words;

  /// The word that opens it.
  final String action;

  /// The count line's ink. `inkMeta` on `plate`; **`inkDim` on `chip`**, where
  /// `inkMeta` measures 4.30 and BG-14 forbids it carrying information.
  final Color tone;

  final String semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            height: KvSpace.touchTarget,
            child: Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '$figure',
                          style: const TextStyle(
                            fontFamily: KvFont.mono,
                            fontWeight: FontWeight.w500,
                            fontVariations: KvWeight.w500,
                          ),
                        ),
                        TextSpan(text: words),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 13,
                      height: 18 / 13,
                      color: tone,
                    ),
                  ),
                ),
                const SizedBox(width: KvSpace.sm),
                Text(
                  action,
                  style: const TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 14,
                    height: 20 / 14,
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

/// **`Default`** — the badge on the one address the wallet hands out on its own.
///
/// Promoted out of `wallet_screen.dart` at UX-R4b, where it was `T4`'s private
/// shape: the receive picker draws the same badge on the same row for the same
/// reason, and a second copy is how two surfaces start disagreeing about what
/// the wallet's default address looks like (BG-21).
///
/// `okTint` ground with `ok` ink — BG-7's green used as a *state*, not a
/// decoration: this address is the one already in play.
class KvDefaultChip extends StatelessWidget {
  const KvDefaultChip({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: KvSpace.s, vertical: 2),
    decoration: BoxDecoration(
      color: KvColor.okTint,
      borderRadius: BorderRadius.circular(KvRadius.control),
    ),
    child: const Text(
      'Default',
      maxLines: 1,
      style: TextStyle(
        fontFamily: KvFont.ui,
        fontSize: 11,
        height: 16 / 11,
        fontWeight: FontWeight.w600,
        fontVariations: KvWeight.w600,
        color: KvColor.ok,
      ),
    ),
  );
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
    this.titleWidget,
    this.sub,
    this.subWidget,
    this.badge,
    this.trailing,
    this.trailingMeta,
    this.onTap,
    this.onLongPress,
    this.semanticLabel,
    this.dense = false,
    this.ground = KvColor.plate,
    this.trailingCap = KvRow.trailingMax,
    this.subLines = 1,
    this.titleLines = 1,
  }) : assert(
         sub == null || subWidget == null,
         'a row has one sub-line: a string or a widget, never both',
       );

  /// The 40 dp disc, or any leading object of that size. Null ⇒ the title
  /// starts at the container's own inset.
  final Widget? leading;

  final String title;

  /// **A composed title** — the counterpart of [subWidget], and it exists for
  /// exactly one case: a row whose name IS an address.
  ///
  /// [title] is a `String` rendered in the UI face with `overflow: ellipsis`,
  /// which is the wrong object for a key. The conversation list handed it a
  /// pre-truncated `kaspa:qz7u…ellj43pf` and at 320 dp / 1.3× the row
  /// ellipsised it a second time, to **`kaspa:qz…`** — two different keys
  /// sharing a 4-character payload head then render as byte-identical rows,
  /// which is the shape [KvAddress] exists to make impossible and its own
  /// `assert(!address.contains('…'))` exists to catch. Passing the whole
  /// address through `KvAddress(form: compact)` here restores the weighting,
  /// the mono face, the scale-to-floor and that assert
  /// (`wallet-security-auditor`, UX-R5).
  ///
  /// [title] is still required and is still what a screen reader announces,
  /// so a composed title can never quietly say something else.
  final Widget? titleWidget;

  /// `sub` [KvColor.inkMeta] — and [KvColor.inkDim] on a [KvColor.chip]
  /// ground, which BG-14 requires (§1.4).
  final String? sub;

  /// A composed sub-line — the ledger's lifecycle mark, for instance.
  final Widget? subWidget;

  /// A small mark that belongs **to the title**, on its own line beside it —
  /// `T4`'s green `Default` pill on the wallet's main address. Distinct from
  /// [trailing], which belongs to the row: a badge qualifies the name, a
  /// trailing object reports the row's value. It takes only its intrinsic
  /// width, so a long title still ellipsises rather than crushing it.
  final Widget? badge;

  /// The value, the toggle, or an [KvColor.etch] chevron.
  final Widget? trailing;

  /// A `metaMono` line under [trailing] — the ledger's time.
  final Widget? trailingMeta;

  /// Null ⇒ the row is a record, not a control.
  final VoidCallback? onTap;

  /// **A second gesture on the same row** — the conversation list's
  /// name / start over / clear / hide menu (D-068), which the old Material
  /// card carried on `InkWell.onLongPress`. It is a parameter rather than a
  /// wrapping `GestureDetector` at the call site so both gestures are declared
  /// on one widget and resolve in one arena: two nested detectors competing
  /// for the same pointer is how a tap starts losing to a long-press that was
  /// not quite long enough.
  final VoidCallback? onLongPress;

  /// What a screen reader announces for the whole row. Defaults to [title].
  final String? semanticLabel;

  /// **The compact register** (D-278/D-279, playbook §19.4 step 5) — the type
  /// one step down, and nothing else: 16 → 15 for the title, 13 → 12 for the
  /// sub. Both are clear of BG-14's 11 dp floor, and [height] does not move,
  /// because a row's box is a thumb target and a target never scales with a
  /// density (BG-12, §19.5).
  ///
  /// `T1`, `T2` and `T4` are drawn at this register — measured off the renders
  /// at 4×: a row title's cap is 11.0 dp (÷ Jakarta's 0.773 = 14.2) and a
  /// sub-line's 9.5 (= 12.3), against the 16 / 13 the default draws.
  final bool dense;

  /// How many lines the **title** may take before it ellipsises.
  ///
  /// One by default: a ledger row's title is a name or a counterparty, and a
  /// long one belongs in an ellipsis rather than in two lines that push the
  /// figure beside it out of alignment.
  ///
  /// **A settings row is the other case.** At 320 dp / 1.3× — BG-14's floor —
  /// `Lock when I leave` beside its `After 30 s` reading came out as
  /// `Lock whe…`, which names nothing. `KvTopBar`'s own rule is the house
  /// answer and it applies here: *a label WRAPS; only a number is forbidden
  /// from doing so.* Read off the floor frame, not argued (playbook §19.6).
  final int titleLines;

  /// How many lines the sub-line may take before it ellipsises.
  ///
  /// One by default — a ledger row's sub-line is one line (§2 `sub`). `T2`'s
  /// settings rows explain what a control *costs* ("Locking discards
  /// everything on screen; it is rebuilt from the chain on return"), and an
  /// explanation that ellipsises is worse than no explanation on a custody
  /// screen. The row's height grows with it; [height] stays the minimum.
  final int subLines;

  /// **The ground this row is drawn on**, so the sub-line can meet BG-14 on
  /// it. `plate` is a card on a screen; `chip` is a card inside a sheet
  /// (§1.1) — and `inkMeta` `#7a8583` on `chip` `#1a2120` measures **4.30:1**,
  /// under the 4.5 a sub-line carrying information owes. The class doc has
  /// claimed "`inkDim` on a `chip` ground, which BG-14 requires" since the row
  /// shipped and nothing implemented it: the field was a hard-coded `inkMeta`
  /// and the row had no way to be told (`ux-auditor` BLOCK, UX-R5). `inkDim`
  /// on `chip` is 7.36.
  final Color ground;

  /// §4: fixed in every window class (BG-33).
  static const double height = KvSpace.row;

  /// **The widest the trailing column may grow**, so a long figure scales
  /// inside a bound rather than taking the row.
  ///
  /// **Measured, not chosen** (item 0). At 320 dp / 1.3× — the floor, where the
  /// row is tightest — this value keeps every property the two previous shapes
  /// each broke one of: a short amount holds its right edge at the row's own
  /// (A11) with 87.9 dp left for the title; a fourteen-digit amount caps here,
  /// sits flush right, scales to 12.1 dp (clear of BG-14's 11 dp floor) and
  /// leaves the title 36 dp rather than nothing. Fixed in dp, like every other
  /// height and gap in the system (BG-33).
  static const double trailingMax = 132;

  /// This row's own cap on the trailing column, defaulting to [trailingMax].
  ///
  /// An **address** row wants a tighter one: its sub-line is a compact address
  /// of a fixed 19 characters, and a wide amount beside it pushed that line
  /// into two — founder, on glass 2026-09-07: *"a kas with more decimals kinda
  /// breaks the address and its not well sized there."* The figure has a
  /// `FittedBox` and can give way; the address has neither.
  final double trailingCap;

  @override
  State<KvRow> createState() => _KvRowState();
}

class _KvRowState extends State<KvRow> {
  bool _down = false;

  Text _title(String title) => Text(
    title,
    maxLines: widget.titleLines,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      fontFamily: KvFont.ui,
      fontSize: widget.dense ? 15 : 16,
      height: 20 / (widget.dense ? 15 : 16),
      fontWeight: FontWeight.w600,
      fontVariations: KvWeight.w600,
      color: KvColor.ink,
    ),
  );

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
                  if (widget.badge case final badge?)
                    // **A `Wrap`, not a `Row`** — `KvSectionHeader`'s lesson
                    // one file over, and the same floor found it: under a
                    // `Row` the title took `Flexible` and the badge its
                    // intrinsic width, so a narrow title column could not
                    // give the badge room and the row overflowed by 5.2 dp at
                    // 320 dp / 1.3× (the receive picker, whose rows carry a
                    // disc, a balance AND a check beside the same badge `T4`
                    // fits comfortably). Shrinking the badge instead would
                    // have set `Default` below BG-14's 11 dp floor or
                    // ellipsised a two-syllable word. A `Wrap` needs no
                    // threshold: the badge sits beside the title while there
                    // is room and drops beneath it the moment there is not.
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: KvSpace.s,
                      runSpacing: 2,
                      children: [widget.titleWidget ?? _title(title), badge],
                    )
                  else
                    widget.titleWidget ?? _title(title),
                  ?subLine,
                  if (sub != null)
                    Text(
                      sub,
                      maxLines: widget.subLines,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: widget.dense ? 12 : 13,
                        height:
                            (widget.dense ? 17 : 18) / (widget.dense ? 12 : 13),
                        // BG-14 on the ground it is actually drawn on: 4.30
                        // for `inkMeta` on `chip`, against 7.36 for `inkDim`.
                        color: widget.ground == KvColor.chip
                            ? KvColor.inkDim
                            : KvColor.inkMeta,
                      ),
                    ),
                ],
              ),
            ),
            if (trail != null || meta != null) ...[
              const SizedBox(width: KvSpace.sm),
              // **Intrinsic first, capped, flush right — and it took three
              // attempts to get all three at once.**
              //
              // *Unbounded* (a bare non-flex child): `KvAmount`'s own
              // `FittedBox(scaleDown)` has nothing to fit inside, so the figure
              // cannot shrink. Measured at 320 dp / 1.3×, a 1,234.56789012 KAS
              // row drove the title to **0 dp** and overflowed by 19, and a
              // 123,456 KAS row painted past the screen edge — BG-5's one
              // prohibition and BG-14's floor together, with **no `find.text`
              // able to see it** because a finder matches a 0 dp `Text` (L131).
              //
              // *`Flexible`*: bounded, but the leftover lands **after** the
              // last child, so a short amount floated ~60 dp clear of the
              // gutter — **A11, the founder's own ragged-edge finding, undone
              // by the fix for something else.**
              //
              // *Two `Expanded`*: flush right and bounded, but they partition
              // 50/50 **regardless of need** — so a four-character amount
              // truncated the title beside a half-empty column, and a long one
              // scaled the figure to **7.72 dp** against BG-14's floor of 11.
              //
              // A non-flex child under a stated cap is the shape that holds all
              // three: it takes its intrinsic width when it is small (title
              // keeps the rest, right edge unmoved), and stops at
              // [trailingMax] when it is not (the figure scales inside a bound
              // instead of eating the row).
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: widget.trailingCap),
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
    final longPress = widget.onLongPress;
    // **A row with no gesture at all** is a record and gets no detector — but
    // the guard used to read `onTap == null`, which dropped [onLongPress] on
    // exactly the rows that are not doors: a request card's own action is its
    // Accept button, so its `onTap` is null, and its long-press menu (name,
    // hide, start over) silently stopped existing.
    if (tap == null && longPress == null) return body;
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
          onLongPress: longPress,
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

/// **The choices inside a settings ceremony** (§4, D-275; `T3` measured).
///
/// A [KvColor.chip] card at [KvRadius.bubble] holding the options as rows with
/// exactly one [KvCheck] — the inner card of a sheet, never a screen's own
/// container (that is [KvRowContainer]). Promoted out of `node_screen.dart` at
/// UX-R4, where it was the explorer and API-source sheets' private shape: the
/// lock timer is the third sheet of the family, and a third copy is how three
/// ceremonies start disagreeing about what a chosen option looks like (BG-21).
class KvChoiceCard extends StatelessWidget {
  const KvChoiceCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: KvColor.chip,
      borderRadius: BorderRadius.circular(KvRadius.bubble),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0)
            const SizedBox(
              height: 1,
              child: ColoredBox(color: KvColor.hairline),
            ),
          children[i],
        ],
      ],
    ),
  );
}

/// One choice: a title, an optional line beneath, and the mark that says which
/// one is current. A [KvSpace.control]-high row (BG-12).
///
/// **The unchosen options carry an empty ring, not an empty box** (`T3`,
/// measured: a 22 dp [KvColor.edgeHi] circle on every row that is not the
/// current one). A column of one check and five blanks reads as a list with
/// one annotation; a column of six rings reads as a choice, which is what the
/// sheet is for. The shipped sheets held the space and drew nothing in it.
class KvChoiceRow extends StatelessWidget {
  const KvChoiceRow({
    super.key,
    required this.title,
    this.sub,
    this.subTone,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String? sub;

  /// The sub-line's hue. Null is the house [KvColor.inkDim] on this ground
  /// (§1.4). `T3` spends [KvColor.warn] on exactly one line — *Anyone holding
  /// the phone can spend*, under **Never** — because that option's cost is the
  /// thing the sheet exists to make visible (BG-7: not-yet-safe, said in
  /// words as well as in hue).
  final Color? subTone;

  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: sub == null ? title : '$title. $sub',
    child: ExcludeSemantics(
      child: InkWell(
        onTap: onTap,
        highlightColor: KvColor.chipPressed,
        splashFactory: NoSplash.splashFactory,
        child: ConstrainedBox(
          // **64, not 56** (`sheet-SELECTION SHEET`, measured: five rows at a
          // 65 dp pitch inside a card padded 6, so the row is the house 64 and
          // the extra dp is the hairline). It is a minimum, so a wrapped
          // at-risk line grows the row rather than clipping.
          constraints: const BoxConstraints(minHeight: KvSpace.row),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: KvSpace.s20,
              vertical: KvSpace.s,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontFamily: KvFont.ui,
                          fontSize: 15,
                          height: 20 / 15,
                          fontWeight: FontWeight.w600,
                          fontVariations: KvWeight.w600,
                          color: KvColor.ink,
                        ),
                      ),
                      if (sub case final sub?)
                        Text(
                          sub,
                          style: TextStyle(
                            fontFamily: KvFont.ui,
                            fontSize: 12,
                            height: 17 / 12,
                            color: subTone ?? KvColor.inkDim,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: KvSpace.sm),
                // The app's one yes (BG-29), and the ring where it is not.
                if (selected)
                  const KvCheck(ground: KvColor.chip)
                else
                  const KvRadio(),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// **The unchosen mark**: a 24 dp ring, 2 dp stroke, in [KvColor.etch]
/// (`sheet-SELECTION SHEET`, measured at 2×).
///
/// It exists because a column of one mark and five blanks reads as a list with
/// one annotation, while a column of rings reads as a **choice** — which is
/// what a selection sheet is for. The shipped sheets held the space and drew
/// nothing in it.
///
/// **The chosen mark is [KvCheck], and stays [KvCheck]** — the founder's
/// ruling on glass (2026-09-06: *"let it use our green checkmark, the way it
/// was before … lets always use that instead of this teal select color"*).
/// The sheet render drew a lit teal ring and D-284 argued for it from BG-29's
/// own wording — the check means *confirmed*, and nothing on a selection sheet
/// is confirmed yet. **His eye outranks that reading** (D-262), and he is
/// right about the thing the argument missed: BG-29's value is that the app
/// has exactly ONE yes, recognisable without being re-learned, and a second
/// chosen-mark vocabulary costs more than the tense distinction buys. Teal
/// also stays what it is — light, never a status (BG-2).
///
/// It draws inside [KvCheck]'s own footprint, so the column does not shift by
/// a ring width when the choice moves.
class KvRadio extends StatelessWidget {
  const KvRadio({super.key, this.ring = 24});

  /// The visible circle. The widget's box is [KvCheck]'s outer, which is
  /// larger — the ring sits centred in it.
  final double ring;

  /// The ring's stroke, at any size (measured 2 at 24).
  static const double stroke = 2;

  /// The miniature that rides a disabled action's label, saying *nothing new
  /// has been picked* in the sheet's own vocabulary.
  static const double markInPill = 10;

  @override
  Widget build(BuildContext context) {
    const box = KvCheck(disc: KvCheck.small);
    final extent = ring <= markInPill ? ring : box.outer;
    return SizedBox(
      width: extent,
      height: extent,
      child: Center(
        child: Container(
          width: ring,
          height: ring,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: KvColor.etch, width: stroke),
          ),
        ),
      ),
    );
  }
}
