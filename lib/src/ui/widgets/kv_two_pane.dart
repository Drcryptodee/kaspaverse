import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/kv_window.dart';
import '../theme/tokens.dart';

/// **Two columns with jobs** (§3a.2, BG-33) — list left, detail right.
///
/// A wider window never gets a wider column; it gets another column, and the
/// page stops growing at [KvLayout.pageMax] and centres. Tapping a row in the
/// list **fills the detail column** rather than pushing a route: there is no
/// "back" from a pane, because the list beside it never left.
///
/// **The list pane's width is derived, not chosen.** §3a.1 puts it at 400–480,
/// and the same section pins the V60 in landscape at 340 — which is not a
/// contradiction: with a rail or a standing drawer already taking 80 or 296 dp,
/// 400 would leave the detail column too narrow to be a column. So the pane
/// takes 40% of what is actually left, held between 340 and
/// [KvLayout.listPaneMax], and yields further only if the detail would fall
/// under [minDetail]. On a roomy window the formula lands inside the band on
/// its own.
class KvTwoPane extends StatelessWidget {
  const KvTwoPane({super.key, required this.list, required this.detail});

  final Widget list;
  final Widget detail;

  /// The narrowest a detail column may be and still be one.
  static const double minDetail = 320;

  /// The narrowest the list pane may be squeezed to (§3a.1, the V60).
  static const double minList = 340;

  /// The list pane's width for a given available [width] and outer [gutter].
  /// Exposed so a test can assert the geometry rather than eyeball a render.
  static double listWidth(double width, double gutter) {
    final content = width - gutter * 2 - KvLayout.columnGap;
    if (content <= 0) return 0;
    var pane = (content * 0.4).clamp(minList, KvLayout.listPaneMax);
    if (content - pane < minDetail) {
      pane = math.max(0, content - minDetail);
    }
    return math.min(pane, content);
  }

  @override
  Widget build(BuildContext context) {
    final metrics = KvWindow.of(context);
    final gutter = metrics.gutter;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: KvLayout.pageMax),
        child: LayoutBuilder(
          // Measuring the space this widget was actually given, which BG-33
          // permits and requires — what it forbids is *choosing a layout* from
          // a raw width, and the layout here was already chosen by the class.
          builder: (context, box) {
            final pane = listWidth(box.maxWidth, gutter);
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: gutter),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: pane, child: list),
                  const SizedBox(width: KvLayout.columnGap),
                  Expanded(child: detail),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
