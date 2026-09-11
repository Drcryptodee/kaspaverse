import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// One tab: its word, and the count that rides beside it.
@immutable
class KvTab {
  const KvTab(this.label, {this.count});

  final String label;

  /// A count is set in `metaMono` in [KvColor.primaryMuted] — **never a dot**
  /// (§4). `primaryMuted` is ambient and uncounted against BG-2's cap (§1.5).
  final int? count;
}

/// **Two or three exclusive views of one container** (§4).
///
/// Jakarta 14; the active tab is [KvColor.ink] at 600 over a 2 dp
/// [KvColor.primary] underline — one of BG-2's permitted emissions — and an
/// inactive one is [KvColor.inkMeta]. There is no track, no pill and no
/// background: the underline is the whole indicator.
///
/// It is not [KvSegmented]: segmented switches a *filter* inside one view,
/// tabs switch the view itself.
class KvTabs extends StatelessWidget {
  const KvTabs({
    super.key,
    required this.tabs,
    required this.index,
    required this.onSelect,
  });

  final List<KvTab> tabs;
  final int index;
  final ValueChanged<int> onSelect;

  /// The underline's thickness (§4).
  static const double underline = 2;

  /// The gap under the label the underline sits in.
  static const double _underlineGap = 6;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < tabs.length; i++) ...[
          if (i > 0) const SizedBox(width: KvSpace.l),
          // Flexible, because the tab row now shares its line with the `All`
          // action (render `S1`, D-261): at 320 dp / 2.0× the two words and
          // the action overran the row by 24 dp. A word ellipsizes before the
          // row overflows (BG-14 asks the row to survive the scale, not that
          // every word stay whole at twice its size).
          Flexible(
            child: _Tab(
              tab: tabs[i],
              active: i == index,
              onTap: () => onSelect(i),
            ),
          ),
        ],
      ],
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.tab, required this.active, required this.onTap});

  final KvTab tab;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final count = tab.count;
    return Semantics(
      button: true,
      selected: active,
      label: count == null ? tab.label : '${tab.label}, $count',
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            // The whole tab is the target and it never shrinks (BG-12); the
            // label sits in the middle of it.
            height: KvSpace.touchTarget,
            // **The underline is as wide as the word it underlines**, so it
            // is measured from the label rather than given a number somebody
            // liked (item 0: geometry is computed, never asserted).
            child: IntrinsicWidth(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Flexible(
                        child: Text(
                          tab.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: KvFont.ui,
                            fontSize: 14,
                            height: 20 / 14,
                            fontWeight: active
                                ? FontWeight.w600
                                : FontWeight.w400,
                            // Both channels: on a variable face the enum is a
                            // hint and the axis is the ink, and an inline style
                            // inherits the ambient axis (L150).
                            fontVariations: active
                                ? KvWeight.w600
                                : KvWeight.w400,
                            color: active ? KvColor.ink : KvColor.inkMeta,
                          ),
                        ),
                      ),
                      if (count != null) ...[
                        const SizedBox(width: KvSpace.s),
                        Text(
                          '$count',
                          style: const TextStyle(
                            fontFamily: KvFont.mono,
                            fontSize: 11,
                            height: 16 / 11,
                            color: KvColor.primaryMuted,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: KvTabs._underlineGap),
                  // The indicator arrives and leaves on one curve rather than
                  // snapping (BG-24); it is a tint change, so `fast`.
                  AnimatedContainer(
                    duration: KvMotion.fast,
                    curve: KvMotion.curve,
                    height: KvTabs.underline,
                    decoration: BoxDecoration(
                      color: active ? KvColor.primary : Colors.transparent,
                      borderRadius: BorderRadius.circular(KvTabs.underline),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// **A filter over one view** (§4; `T4 · Wallet`, measured).
///
/// Two or three exclusive readings of the *same* list — `With funds` against
/// `All`, never a different screen. [KvTabs] switches the view; this switches
/// what the view is showing, so it is a control with a track rather than an
/// indicator under a heading.
///
/// The render's geometry, measured off `T4` at 4×: a [KvColor.plate] track
/// [KvSpace.xs] deep, a [KvColor.chip] thumb at [KvRadius.control] under the
/// selected label in [KvColor.ink], the others [KvColor.inkMeta]. Track 36,
/// thumb 28 — a **visual** under BG-12's floor, so the whole control declares
/// [KvSpace.touchTarget] and each segment takes an equal share of it.
///
/// A count rides its label as ` · n` in the same run rather than as a second
/// text: the render draws one line per segment and a second `Text` here would
/// be a second thing to align at 1.3×.
class KvSegmentedOption {
  const KvSegmentedOption(this.label, {this.count});

  final String label;

  /// Null draws the word alone.
  final int? count;

  String get spoken => count == null ? label : '$label, $count';
}

class KvSegmented extends StatelessWidget {
  const KvSegmented({
    super.key,
    required this.options,
    required this.index,
    required this.onSelect,
  }) : assert(
         options.length >= 2 && options.length <= 3,
         'segmented holds 2–3 exclusive views (§4); more is a tab row or a '
         'sheet',
       );

  final List<KvSegmentedOption> options;
  final int index;
  final ValueChanged<int> onSelect;

  /// The track's drawn height (`T4`, measured 36.75). The target is
  /// [KvSpace.touchTarget] and does not scale with it (BG-12).
  static const double track = 36;

  /// The track's padding, and so the thumb's inset (`T4`, measured 4).
  static const double inset = KvSpace.xs;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: KvSpace.touchTarget,
      child: Center(
        // **Shrink-wrap.** Without it the control takes whatever width it is
        // offered, which under `KvSectionHeader`'s `Wrap` was the whole row —
        // pushing the section label onto a second run and costing `T4` 20 dp
        // it did not have. A segmented is as wide as its options and no wider
        // (the track's own rule: content-sized segments, `T4` measured).
        widthFactor: 1,
        child: Container(
          height: track,
          padding: const EdgeInsets.all(inset),
          decoration: BoxDecoration(
            color: KvColor.plate,
            borderRadius: BorderRadius.circular(KvRadius.control),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < options.length; i++)
                _Segment(
                  option: options[i],
                  active: i == index,
                  onTap: () => onSelect(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.option,
    required this.active,
    required this.onTap,
  });

  final KvSegmentedOption option;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final count = option.count;
    return Semantics(
      button: true,
      selected: active,
      label: option.spoken,
      child: ExcludeSemantics(
        // The house rule: no ripple in this language, and a shared part must
        // survive a `Material`-less ancestor (`KvRow`'s own note).
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          // **The thumb moves** (BG-24: nothing appears or vanishes without
          // motion). A bare `Container` snapped the fill from one segment to
          // the other; `_Tab` a hundred lines above already animates its own
          // indicator, and two controls in one file disagreeing about whether
          // a selection moves is the drift this file exists to prevent.
          // BG-9: reduced motion collapses it to zero, by hand, because
          // nothing in the pinned SDK does it for an implicit animation.
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : KvMotion.fast,
            curve: KvMotion.curve,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: KvSpace.s14),
            decoration: BoxDecoration(
              color: active ? KvColor.chip : Colors.transparent,
              borderRadius: BorderRadius.circular(KvRadius.control),
            ),
            // **The count is a figure and takes the mono face** (BG-30), the
            // word beside it does not — one `Text` carrying both set `31` in
            // Jakarta, which `T4` does not. Split when this control got its
            // first call site, which is when the defect became visible.
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  option.label,
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 14,
                    height: 18 / 14,
                    fontWeight: FontWeight.w600,
                    fontVariations: KvWeight.w600,
                    color: active ? KvColor.ink : KvColor.inkMeta,
                  ),
                ),
                if (count != null) ...[
                  Text(
                    ' · ',
                    style: TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 14,
                      height: 18 / 14,
                      color: active ? KvColor.inkDim : KvColor.inkMeta,
                    ),
                  ),
                  Text(
                    '$count',
                    maxLines: 1,
                    style: TextStyle(
                      fontFamily: KvFont.mono,
                      fontSize: 13,
                      height: 18 / 13,
                      fontWeight: FontWeight.w600,
                      fontVariations: KvWeight.w600,
                      color: active ? KvColor.ink : KvColor.inkMeta,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
