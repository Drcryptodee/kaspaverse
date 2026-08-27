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
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(KvSpace.m, KvSpace.s, KvSpace.m, 0),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: 'Back',
            child: InkWell(
              onTap: onBack,
              borderRadius: BorderRadius.circular(KvRadius.control),
              child: const SizedBox(
                width: KvSpace.touchTarget,
                height: KvSpace.touchTarget,
                child: Center(
                  child: RotatedBox(
                    quarterTurns: 2,
                    child: KvGlyphIcon(KvMark.chevron, tone: KvColor.inkNav),
                  ),
                ),
              ),
            ),
          ),
          // Expanded rather than two Spacers: at 1.3x on a 320dp screen a
          // title can be wider than what is left between two 48dp targets, and
          // a Spacer cannot give any of it back. A label WRAPS (BG-14); only a
          // number is forbidden from doing so.
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
