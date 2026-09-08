import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_glyph.dart';
import 'kv_icon_button.dart';
import 'kv_rows.dart';

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
  const KvTopBar({
    super.key,
    required this.title,
    required this.onBack,
    this.trailing,
    this.avatar,
    this.subtitle,
    this.centre,
    this.page = false,
  });

  final String title;

  /// **A reading in the title's seat**, for a screen whose name is not a word.
  ///
  /// `O2`–`O6` draw no title at all: the centre of the onboarding bar carries
  /// [KvSteps], because *step 3 of 5* is what a create ceremony's chrome has
  /// to say and "Create wallet" repeated five times is not. The widget takes
  /// the same `Expanded` seat the title would, so it centres on exactly the
  /// line every other screen's title centres on.
  ///
  /// [title] is still required and still what a screen reader is told, so a
  /// bar can never be nameless — it only stops PAINTING the name.
  final Widget? centre;

  /// **The root register** (§2 `pageTitle`, `T1 · Settings` measured).
  ///
  /// A screen at the top of its own group names itself the way the money
  /// screen does — 22 / 700, **left, beside the leading disc**, not centred at
  /// 18 — and the render draws exactly that: a 44 dp disc seated on the gutter
  /// with `Settings` at the wordmark's size beside it, 15 dp clear of it.
  ///
  /// `T1` draws the identity monogram in that disc, because in the render
  /// Settings is a standing destination with the drawer behind it. **In this
  /// build it is a pushed route with no drawer above it**, so the disc holds
  /// the control it actually has — the way back — and everything else about
  /// the composition is the render's. Said in the sitting; when the shell
  /// makes Settings a standing destination the monogram takes the seat back.
  final bool page;

  /// An optional reading at the right of the bar — `S6`'s step counter, and
  /// nothing that acts. It is laid out in a box at least [KvSpace.touchTarget]
  /// wide, which is the same box that balances the back target, so the title
  /// stays centred whether or not anything is in it.
  final Widget? trailing;

  /// **The identity register** (§2, `M4 · Thread` measured at 4×).
  ///
  /// A 44 dp object between the back control and the title — the counterparty's
  /// own disc, 12 dp clear of the chevron's. A thread's bar names a *person*,
  /// not a screen, so the title drops from the `page` register's 22 to 16 and
  /// [subtitle] takes the line beneath it: `Jonas` over `kaspa:qpz3…41k8t`.
  ///
  /// That pairing is the point rather than decoration. A contact's name is a
  /// label the user typed over an address (D-049) and this is the surface an
  /// address-poisoning attack aims at — it wants the name to sit over somebody
  /// else's key. The key travels with the name wherever the name is shown.
  final Widget? avatar;

  /// A second line under [title] — the counterparty's address, through
  /// [KvAddress] in the one law shape (D-296). Only meaningful with [avatar];
  /// a screen that names itself has nothing to put here.
  final Widget? subtitle;

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
          // **§4's icon button, not a disc drawn here.** The back chevron in
          // its `plate` disc (`S6a`·`S6`·`S8`, founder on glass) is exactly
          // that component — 44 dp of disc inside a 52 dp target with a 20 dp
          // mark — and hand-rolling it was a second implementation of a §4
          // seat that already existed, unused, in the tree (L143). Using it
          // also brings the pressed state the hand-rolled one had no reason
          // to grow.
          KvIconButton(
            mark: KvGlyph.chevron,
            quarterTurns: 2,
            // `etch` is the disabled tone: decorative by design, and it never
            // carries information alone — what the exit is waiting for is on
            // the screen in words beneath it.
            tone: onBack == null ? KvColor.etch : KvColor.inkNav,
            label: 'Back',
            onTap: onBack,
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
          if (avatar != null) ...[
            const SizedBox(width: KvSpace.sm),
            avatar!,
            const SizedBox(width: KvSpace.sm),
          ] else if (page)
            const SizedBox(width: KvSpace.xs),
          Expanded(
            child: centre != null
                ? Semantics(
                    // The bar still announces the screen; the centre object
                    // announces the reading. Two labels, one row, in order.
                    label: title,
                    child: Center(child: centre),
                  )
                : subtitle == null
                ? _fitted(context)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [_title(context), subtitle!],
                  ),
          ),
          // Balances the back target so the title sits centred, and seats the
          // optional reading. A `page` title is not centred, so it balances
          // nothing and only appears when something is actually in it.
          if ((!page && avatar == null) || trailing != null)
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: KvSpace.touchTarget),
              child: Center(child: trailing ?? const SizedBox.shrink()),
            ),
        ],
      ),
    );
  }

  /// **A single word scales rather than breaking.**
  ///
  /// BG-14's rule here is `KvTopBar`'s own — *a label WRAPS; only a number is
  /// forbidden from doing so* — and wrapping is still what a multi-word title
  /// does. But a title that is ONE word wider than its column does not wrap:
  /// Flutter breaks it mid-syllable, and at 320 dp / 1.3× this bar rendered
  /// `Messag / es`. That is D-285's `ADD / RESS / ES` finding, in the bar
  /// instead of the section header, and it was found the same way — in the
  /// floor frame, not in a test.
  ///
  /// [BoxFit.scaleDown] never enlarges, so every title that fits renders at
  /// exactly the size §2 gives it and no shipped screen moves; only a title
  /// that would otherwise be broken gives up a little size instead. It is the
  /// rule [KvAmount] already follows for a figure that will not fit — scale
  /// before you clip — applied to the one other object that must stay whole.
  ///
  /// **There is no floor constant here, deliberately.** A `FittedBox` cannot
  /// be given one, and a `static const minScale` sitting beside it would claim
  /// a guarantee the widget does not enforce — the class of false claim that
  /// cost this project a whole auditor pass (L164). What holds the size is the
  /// floor frame: `kv_chrome_test` re-measures this title at 320 dp / 1.3×
  /// with the bundled faces loaded and fails if it is broken or smaller than
  /// the rows beneath it.
  Widget _fitted(BuildContext context) {
    final title = _title(context);
    // A wrapping title has nothing to scale — `scaleDown` on a two-line box
    // would shrink the whole block rather than let the second line exist.
    if (this.title.trim().contains(RegExp(r'\s'))) return title;
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: page || avatar != null
          ? Alignment.centerLeft
          : Alignment.center,
      child: title,
    );
  }

  Widget _title(BuildContext context) {
    // The identity register's own size: `M4` measures `Jonas` at cap 12.25
    // (÷ Jakarta's 0.773 = 15.85). It is smaller than a `page` title because
    // it shares the bar with a second line, and larger than nothing because a
    // person's name is the most important word on the screen.
    final identity = avatar != null;
    return Text(
      title,
      textAlign: (page || identity) ? TextAlign.start : TextAlign.center,
      maxLines: subtitle == null ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      // §2 `barTitle` — **18 / 700 in `ink`**, measured off `S6a`
      // (cap 14.0 dp against the `caps` label's calibration). It was
      // 15 / 600 `inkDim`, which is the `rowTitle` role wearing a
      // bar's job: a screen's own name should not be quieter than the
      // rows underneath it (UX-R2).
      style: TextStyle(
        fontFamily: KvFont.ui,
        fontSize: page
            ? 22
            : identity
            ? 16
            : 18,
        height: page
            ? 26 / 22
            : identity
            ? 20 / 16
            : 22 / 18,
        letterSpacing: page ? -0.2 : -0.18,
        fontWeight: FontWeight.w700,
        fontVariations: KvWeight.w700,
        color: KvColor.ink,
      ),
    );
  }
}

/// A tick, then a sentence-case label — where an instrument silk-screens the
/// name of a section.
class KvRuledLabel extends StatelessWidget {
  const KvRuledLabel(
    this.text, {
    super.key,
    this.tight = false,
    this.rule = true,
  });

  /// The tick before the words. `T5` and `S9` draw their caps labels bare —
  /// `CONNECTION`, `DEPTH`, `MY OWN NODE`, `SOURCES` — and the founder asked
  /// for the picture (2026-09-05), so those seats pass `false`.
  final bool rule;

  final String text;

  /// **Take only the width the words need.**
  ///
  /// The default is a full-width section heading, which is what every caller
  /// wanted until `T5` put this label and a live reading on one line. A `Row`
  /// is `MainAxisSize.max` by default, so inside a `Wrap` the label claimed the
  /// whole run and pushed the reading onto a second line — at 700 dp, where the
  /// two together used 206 dp of 454 available (measured off the frame, not
  /// argued). It is the same family as the `SizedBox`-in-a-`Wrap` trap that
  /// stacked three chips at UX-R2.
  ///
  /// A parameter rather than an `IntrinsicWidth` at the call site: the next
  /// caller that needs a label beside something inherits the answer instead of
  /// re-finding it (BG-21's shape at the widget layer).
  final bool tight;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: tight ? MainAxisSize.min : MainAxisSize.max,
    children: [
      if (rule) ...[
        Container(width: KvSpace.s, height: 1, color: KvColor.inkMeta),
        const SizedBox(width: KvSpace.s),
      ],
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
          // **A little weight** (founder on glass, 2026-09-05: *"they need
          // to be just a little bit bold like the screenshots"*) — 600 on the
          // axis, declared and painted (L150), for every caps label in the
          // house at once.
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 12,
            height: 16 / 12,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w600,
            fontVariations: KvWeight.w600,
            color: KvColor.inkDim,
          ),
        ),
      ),
    ],
  );
}

/// **A section's caps label, and the mark that opens its explainer** (§4;
/// D-275 / D-276 / D-277).
///
/// A screen's sections are broken by this row and by nothing else: the air
/// above and below the words IS the break, so a caller adds no gap of its own
/// and every screen breaks its sections identically. That is what let the
/// Network surface fit in one view — the founder's own bar, on glass
/// 2026-09-05 — after three separate gap constants had been stacked around
/// each label.
///
/// **The mark follows the words** (his ruling, same sitting), and a header
/// that carries one is a control: the whole row is a [height] dp target
/// (BG-12), its own semantics node, and the words sit low in it so the air a
/// target needs falls where the section break is. A header with no explainer
/// is not a control and takes [plainHeight].
class KvSectionHeader extends StatefulWidget {
  const KvSectionHeader(
    this.label, {
    super.key,
    this.info,
    this.trailing,
    this.gloss,
  });

  /// A few dim words on the label's own line, **defining the label**.
  ///
  /// The receive picker's `FRESH · not handed out from this phone`, where the
  /// gloss is load-bearing rather than decorative: `FRESH` alone reads as a
  /// claim about the chain, which is the one thing that wallet cannot make. It
  /// is a slot here rather than a private widget there because a caps label
  /// with its own gaps stacked around it is exactly what D-277 named after the
  /// Network overflow — the part owns the air, the caller adds none.
  ///
  /// A header carries a gloss **or** a control, never both: they want opposite
  /// ends of the same line.
  final String? gloss;

  final String label;

  /// The explainer's open state; null draws no mark and no target.
  final ValueNotifier<bool>? info;

  /// A control seated at the **right end of the same break**, sharing the
  /// header's air instead of adding its own — `T4`'s `With funds · All`
  /// segmented, measured on the label's own centre line (label 112.9,
  /// control 114.1).
  ///
  /// It raises the row to whatever the control needs, so a 52 dp target does
  /// not get squeezed into a 32 dp chrome row; the words stay seated low in
  /// it, which is what keeps every section break in the house the same shape.
  final Widget? trailing;

  /// A header that opens an explainer is a control, so it keeps BG-12's 52
  /// whatever the density is. A plain one is chrome and takes the compact
  /// register (D-278).
  static const double height = 52;
  static const double plainHeight = 32;

  /// Where the words sit inside the row — **measured, not guessed**: a 16 dp
  /// label in a 52 dp box leaves 36, and `(1 + 1/3) / 2 × 36` is exactly 24
  /// above and 12 below, which is the render's rhythm around `MY OWN NODE`.
  /// (`0.25` gave 22.5 / 13.5 while three comments claimed 24 / 12 —
  /// `ux-auditor`, D-277.)
  static const Alignment _seat = Alignment(-1, 1 / 3);

  @override
  State<KvSectionHeader> createState() => _KvSectionHeaderState();
}

class _KvSectionHeaderState extends State<KvSectionHeader> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final label = widget.label;
    final title = KvRuledLabel(label, tight: true, rule: false);
    final trailing = widget.trailing;
    if (info == null && trailing != null) {
      // The words sit on the control's own centre line — `T4` measured them
      // 1.2 dp apart — so the break is one line rather than a label with a
      // control floating beside it. The row takes the control's height, which
      // is the air BG-12 owes a 52 dp target anyway.
      //
      // **`Wrap`, not `Row`, and the reason is BG-14's floor.** Under a `Row`
      // the label took `Expanded` and the control its intrinsic width — which
      // at 320 dp / 1.3× left the label about 26 dp and rendered `ADDRESSES`
      // as `ADD / RESS / ES`, three lines of a word broken mid-syllable. A
      // `Wrap` needs no threshold and no measurement: both sit on one line
      // and spread to the edges while they fit, and the control drops to its
      // own line the moment they do not. Found in a preview frame at the
      // floor, which is where geometry defects are found (playbook §19.6).
      return Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: KvSpace.sm,
        runSpacing: KvSpace.xs,
        children: [title, trailing],
      );
    }
    final gloss = widget.gloss;
    if (info == null && gloss != null) {
      // A `Wrap` at the START, not `spaceBetween`: a definition sits beside
      // the word it defines. `ConstrainedBox`, not `SizedBox`, so the gloss
      // drops to a second line at 320 dp / 1.3× instead of being clipped.
      return ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: KvSectionHeader.plainHeight,
        ),
        child: Align(
          alignment: KvSectionHeader._seat,
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: KvSpace.s,
            runSpacing: 2,
            children: [
              title,
              Text(
                gloss,
                style: const TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 13,
                  height: 18 / 13,
                  color: KvColor.inkDim,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (info == null) {
      return SizedBox(
        height: KvSectionHeader.plainHeight,
        child: Align(alignment: KvSectionHeader._seat, child: title),
      );
    }
    assert(
      trailing == null,
      'a section break carries an explainer mark or a control, never both — '
      'two targets in one 52 dp row is BG-12 at the seat that defines the '
      'break',
    );
    return ValueListenableBuilder<bool>(
      valueListenable: info,
      builder: (context, open, _) => SizedBox(
        height: KvSectionHeader.height,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Semantics(
            // Its own node, so a reader lands on one control rather than on a
            // label merged with the caps title beside it.
            container: true,
            button: true,
            toggled: open,
            label: 'About ${label.toLowerCase()}',
            child: ExcludeSemantics(
              // **`GestureDetector`, not `InkWell`** — the house rule
              // (`KvRow`'s own note): a ripple needs a `Material` ancestor,
              // this language has no ripple, and a shared part must survive
              // the one place that dependency throws (the drawer panel sits
              // above every `Scaffold` in the app). `ux-auditor`, D-277.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) => setState(() => _down = true),
                onTapCancel: () => setState(() => _down = false),
                onTapUp: (_) => setState(() => _down = false),
                onTap: () => info.value = !open,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _down ? KvColor.keyPressed : Colors.transparent,
                    borderRadius: BorderRadius.circular(KvRadius.pill),
                  ),
                  child: SizedBox(
                    height: KvSectionHeader.height,
                    child: Align(
                      alignment: KvSectionHeader._seat,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          title,
                          const SizedBox(width: KvSpace.s),
                          KvGlyphIcon(
                            KvGlyph.info,
                            tone: open ? KvColor.primaryMuted : KvColor.inkMeta,
                            size: 16,
                          ),
                          const SizedBox(width: KvSpace.xs),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
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
///  * **disabled** — **no fill, a 2 dp [KvColor.edgeHi] outline, and the
///    reason AS the label** in [KvColor.inkDim] beside a small unchosen
///    [KvRadio] (BG-12).
///
/// **The disabled form is the sheet renders' answer, and it replaced ours on
/// the founder's word** (2026-09-06: *"the way its depicted as being disabled
/// is just not it"*). The old one was a `shelf`-filled pill with an `etch`
/// label and a separate `inkMeta` sentence beneath — a filled dark pill reads
/// as *broken*, and the sentence under it made a disabled control two objects
/// where an enabled one is one. The outline reads as **waiting** rather than
/// damaged; putting the reason in the label makes the control state its own
/// condition, so it cannot be pressed and wondered about; and the miniature
/// ring says, in the sheet's own vocabulary, *nothing new has been picked*.
/// One rendering: the `inlineReason` switch is gone, because there is no
/// longer a second way to say why.
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
    this.destructive = false,
    this.disabledReason,
    this.disabledLabel,
    this.disabledMark = true,
    this.labelWidget,
    this.mark,
    this.height = KvSpace.control,
  });

  /// **The destructive form**: a `risk` fill with a `plate` label.
  ///
  /// The app has exactly one control in this register — the total message
  /// erase — and §3 rations `error` to fund risk and DESTRUCTION. It is
  /// deliberately NOT the primary pill: DS §8's glow is the signing
  /// ceremony's, and dressing an erase in it would say *this is the thing you
  /// want*. It is deliberately not `raised` either, which reads identical to
  /// the benign "Clear messages" confirm one gesture away, and the two do very
  /// different things. Promoted out of `contacts_screen.dart`'s
  /// `FilledButton(backgroundColor: risk)` at UX-R5 so the one destructive
  /// control in the app is a stated form rather than a styled Material button
  /// (`ux-auditor`, BG-21/BG-25).
  const KvAction.destructive({
    Key? key,
    required String label,
    required VoidCallback onTap,
    String? disabledReason,
    double height = KvSpace.control,
  }) : this(
         key: key,
         label: label,
         primary: false,
         destructive: true,
         onTap: onTap,
         disabledReason: disabledReason,
         height: height,
       );

  /// The raised form: `chip` fill, `ink` label. Sugar for `primary: false`,
  /// which is the same rendering — the named constructor exists so a call site
  /// says which pill it means rather than what it is not.
  const KvAction.raised({
    Key? key,
    required String label,
    required VoidCallback onTap,
    String? disabledReason,
    bool disabledMark = true,
    KvGlyph? mark,
    double height = KvSpace.control,
  }) : this(
         key: key,
         label: label,
         primary: false,
         onTap: onTap,
         disabledReason: disabledReason,
         disabledMark: disabledMark,
         mark: mark,
         height: height,
       );

  /// Verb plus object, never "Confirm" (BG-11).
  final String label;

  final bool primary;

  /// See [KvAction.destructive].
  final bool destructive;

  final VoidCallback onTap;

  /// Null ⇒ enabled. Non-null ⇒ disabled, and this is what it says.
  final String? disabledReason;

  /// **What a disabled pill PAINTS, when the reason will not fit in it.**
  ///
  /// The disabled form normally sets [disabledReason] as its label, which is
  /// right for a full-width action: the user may not otherwise see why it is
  /// dark. It is wrong for a narrow pill beside a field. The thread composer's
  /// Send is 108 dp and its reason is 21 characters — at 320 dp / 1.3× the
  /// pill took the whole row and the message field measured 0.0 dp
  /// (`ux-auditor` BLOCK, UX-R5).
  ///
  /// The reason is not lost: it stays the pill's **semantic** label, so a
  /// screen reader is told why while the glass stays legible. Null keeps the
  /// reason on the glass, which remains the default everywhere else.
  final String? disabledLabel;

  /// **Whether the disabled form carries its ring.**
  ///
  /// The mark is [KvRadio] and its documented meaning is *nothing new has been
  /// picked* — it came from the selection sheet, where that is exactly the
  /// refusal. It is wrong on a refusal about anything else: `M3`'s *Enter an
  /// address to continue* is not an unmade choice, and neither is a network
  /// check in flight (`ux-auditor`, UX-R5). Defaults on, so no shipped surface
  /// moves; a caller whose refusal is not about a choice turns it off.
  final bool disabledMark;

  /// The **enabled** label, composed — for the one case a plain string cannot
  /// carry: a label that mixes words with a figure, which BG-30 sets in two
  /// faces. `T4`'s `Merge coins · ≈ 0.0004 KAS fee` is that case.
  ///
  /// [label] is still required and still the truth for a screen reader, so a
  /// composed label can never quietly say something different from what is
  /// announced. The disabled form ignores this entirely: its label is the
  /// reason, which is always words.
  final Widget? labelWidget;

  /// An optional 18 dp glyph before the label (§4).
  final KvGlyph? mark;

  /// 56 by default; the money plate's thumb pair is 52
  /// ([KvSpace.controlThumb], §4).
  final double height;

  /// A vertical breathing space so a wrapped label does not touch the pill's
  /// edge. Zero-cost on the common one-line case, because the pill's height is
  /// a minimum and one line never reaches it.
  static const double labelPad = KvSpace.s;

  /// The disabled outline's stroke (`sheet-SELECTION SHEET`, measured 2).
  static const double disabledEdge = 2;

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
      // **Nothing.** The outline is the whole shape (see the class doc).
      fill = Colors.transparent;
    } else if (widget.destructive) {
      // **The press INVERTS; it does not just darken.** `riskTint` is §1.6's
      // surface of `risk`, not a pressed step of it — `plate` ink on it
      // measured **1.12:1**, so the label of the app's one irreversible
      // confirmation vanished at the moment of the press (`ux-auditor` BLOCK,
      // UX-R5). Inverted, the ink moves with the fill: `risk` on `riskTint` is
      // 5.51, and the pill reads as pressed rather than as extinguished.
      fill = _down ? KvColor.riskTint : KvColor.risk;
    } else if (lit) {
      fill = _down ? KvColor.primaryPressed : KvColor.primary;
    } else {
      fill = _down ? KvColor.chipPressed : KvColor.chip;
    }
    final ink = disabled
        ? KvColor.inkDim
        : widget.destructive
        ? (_down ? KvColor.risk : KvColor.plate)
        : (lit ? KvColor.onPrimary : KvColor.ink);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          enabled: !disabled,
          // The composed label paints; [label] is what is SPOKEN, always —
          // and a disabled pill painting a short word still ANNOUNCES its
          // reason (see [disabledLabel]).
          label: disabled
              ? (widget.disabledLabel == null ? null : widget.disabledReason)
              : (widget.labelWidget == null ? null : widget.label),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: disabled ? null : widget.onTap,
            onTapDown: disabled ? null : (_) => setState(() => _down = true),
            onTapUp: disabled ? null : (_) => setState(() => _down = false),
            onTapCancel: disabled ? null : () => setState(() => _down = false),
            child: AnimatedContainer(
              duration: KvMotion.fast,
              curve: KvMotion.curve,
              // **A MINIMUM, not a fixed height** (`ux-auditor`, UX-R2). The
              // label names the action *and its object* (BG-11), and on Send
              // that object is a figure: `Review 123456.78901234 KAS` needs
              // 300 dp against the 288 a 320 dp / 1.3× pill has. A single
              // ellipsized line cut a money figure mid-number, which BG-5
              // forbids outright — *scales down before it clips, never
              // ellipsizes*. The pill grows instead, exactly as `KvHold`
              // does with the same string.
              constraints: BoxConstraints(minHeight: widget.height),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(radius),
                border: disabled
                    ? Border.all(
                        color: KvColor.edgeHi,
                        width: KvAction.disabledEdge,
                      )
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (disabled && widget.disabledMark) ...[
                    // *Nothing new has been picked* — the sheet's own mark, in
                    // miniature, rather than a second vocabulary. See
                    // [disabledMark] for when it does not belong.
                    const KvRadio(ring: KvRadio.markInPill),
                    const SizedBox(width: KvSpace.s),
                  ] else if (!disabled && widget.mark != null) ...[
                    KvGlyphIcon(widget.mark!, size: KvAction.glyph, tone: ink),
                    const SizedBox(width: KvSpace.s),
                  ],
                  Flexible(
                    child: Padding(
                      // **Horizontal air, measured off `M2`** — its Accept
                      // pill starts at x 97.0 and the label's ink at 115.2,
                      // so 18.2 ≈ [KvSpace.s20]. The part had none: every
                      // caller so far was full width, where the label floats
                      // in the middle and the omission cannot be seen. The
                      // first content-sized pill in the system — `M2`'s
                      // `Accept…` under [IntrinsicWidth] — rendered with 1 dp
                      // between the word and the pill's edge.
                      //
                      // A full-width caller is unaffected until its label
                      // nearly fills the pill, which is exactly where side air
                      // is wanted; and `KvAction`'s height is a MINIMUM, so
                      // the pill grows rather than clipping (BG-5).
                      padding: const EdgeInsets.symmetric(
                        vertical: KvAction.labelPad,
                        horizontal: KvSpace.s20,
                      ),
                      child: disabled
                          ? Text(
                              // **The reason IS the label** — measured off the
                              // render at 15 / 500 `inkDim`, the same size the
                              // verb takes on a 52-high control, so the pill
                              // does not shrink its own voice when it refuses.
                              // Unless it cannot fit: see [disabledLabel].
                              widget.disabledLabel ?? widget.disabledReason!,
                              maxLines: 2,
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: KvFont.ui,
                                fontSize: 15,
                                height: 20 / 15,
                                fontWeight: FontWeight.w500,
                                fontVariations: KvWeight.w500,
                                // `inkDim`, not `etch`: the reason is
                                // information and `etch` carries none (§1.4).
                                color: KvColor.inkDim,
                              ),
                            )
                          : widget.labelWidget ??
                                Text(
                                  widget.label,
                                  textAlign: TextAlign.center,
                                  // Unbounded: it wraps at a space, so a figure and
                                  // its unit stay together on one line whatever
                                  // happens (BG-5, BG-14).
                                  style: TextStyle(
                                    fontFamily: KvFont.ui,
                                    // §2 `button`: 16, and 15 on a 52-high control.
                                    fontSize: widget.height >= KvSpace.control
                                        ? 16
                                        : 15,
                                    height: 20 / 16,
                                    fontWeight: FontWeight.w600,
                                    fontVariations: KvWeight.w600,
                                    color: ink,
                                  ),
                                ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// **The Paste ghost** (§4; `S6a`, and `M3 · New handshake` draws the same
/// chip in the same seat).
///
/// Promoted out of `send_screen.dart` at UX-R5, when the handshake screen
/// needed the identical object — one address field, one clipboard read, one
/// chip (BG-21).
///
/// **`primary`, not `primaryMuted`.** §1.5 lists "the Paste chip's glyph and
/// label" under the ambient teal and BG-2 lists *Paste* among the ghost text
/// actions that emit — two laws on one object, and `S6a` settles it: the render
/// paints both glyph and word at `#49eacb`. It is a ghost action that happens
/// to sit in a chip, and it spends one of this screen's three emissions.

/// **A quiet text action** — words in a 52 dp target, and no pill.
///
/// Jakarta 14 / 600 in `inkDim`, `primaryMuted` where it is the only offer in
/// its seat. It was `KvContactAction`, private to `S6b`'s *Save as contact*,
/// until UX-R6 found the onboarding group needs exactly this object three
/// times and none of them is about a contact: `O4`'s *Show me the words
/// again*, `O5`'s **Skip — 12 words only**, `O6`'s *Passphrase only*.
///
/// **The founder's standing ruling lives here**: the way past an optional step
/// is plain text, never a second pill competing with the primary. A pill says
/// *this is a thing you want*; the skip is a thing the user may not need at
/// all, and two pills of equal weight on a custody screen make the wrong one
/// as easy to hit as the right one (BG-12's thumb-arc clause, one layer up).
///
/// [onTap] may be null — the control then still occupies its seat and says
/// nothing, which is what a busy ceremony needs from it.
class KvTextAction extends StatelessWidget {
  const KvTextAction({
    super.key,
    required this.label,
    required this.onTap,
    this.tone = KvColor.inkDim,
  });

  final String label;
  final VoidCallback? onTap;
  final Color tone;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Semantics(
      button: true,
      enabled: onTap != null,
      // **Measured, not assumed** (item 0 / L121). A 19.0 dp line box inside
      // 16 dp of padding is **51.0**, one dp under BG-12's floor — carried
      // verbatim from `KvContactAction`, where the comment claimed 52 and
      // nobody had multiplied it out. An extraction is new code for its new
      // callers, and this one has five (`ux-auditor`, UX-R6).
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: KvSpace.touchTarget),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: KvSpace.s,
            vertical: KvSpace.m,
          ),
          child: Align(
            alignment: Alignment.center,
            widthFactor: 1,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 14,
                height: 19 / 14,
                fontWeight: FontWeight.w600,
                fontVariations: KvWeight.w600,
                color: onTap == null ? KvColor.etch : tone,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class KvPasteChip extends StatelessWidget {
  const KvPasteChip({
    super.key,
    required this.onTap,
    this.label = 'Paste the address from your clipboard',
  });

  final VoidCallback onTap;

  /// What a screen reader says — verb plus object (BG-11).
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // A 40 dp chip in a 52 dp target (BG-12): the visual may be smaller
        // than the target, and the target never shrinks.
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: (KvSpace.touchTarget - KvSpace.rowDisc) / 2,
          ),
          child: Container(
            height: KvSpace.rowDisc,
            padding: const EdgeInsets.symmetric(horizontal: KvSpace.m),
            decoration: BoxDecoration(
              color: KvColor.chip,
              borderRadius: BorderRadius.circular(KvRadius.control),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                KvGlyphIcon(KvGlyph.paste, size: 16, tone: KvColor.primary),
                SizedBox(width: KvSpace.s),
                Text(
                  'Paste',
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 15,
                    height: 20 / 15,
                    fontWeight: FontWeight.w600,
                    fontVariations: KvWeight.w600,
                    color: KvColor.primary,
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
