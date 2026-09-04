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
