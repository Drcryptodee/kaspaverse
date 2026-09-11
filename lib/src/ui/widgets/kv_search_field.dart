import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_glyph.dart';

/// **The one field that looks something up** (§4; `M1 · Chats`, measured at 4×).
///
/// A [KvColor.plate] pill 48 dp deep on the screen's own gutter, the
/// [KvGlyph.search] mark at 18 dp in [KvColor.inkMeta] seated on the
/// container's inset (20), then 10 dp of air, then the words. The placeholder
/// is `inkMeta` — §1.4 names it the tone for "placeholders that are not
/// information" — and what the user types is `ink`, because that IS
/// information.
///
/// It is deliberately **not** a control (`KvAction`, `KvGlowPill`): a control
/// is something you commit, and BG-27 lights those. A search field commits nothing; it filters
/// what is already on the screen, and it never takes the teal.
class KvSearchField extends StatefulWidget {
  const KvSearchField({
    super.key,
    required this.hint,
    required this.onChanged,
    this.controller,
  });

  /// What the field is for, in the user's words — never the word "Search"
  /// alone, which names the mechanism rather than the objects (BG-11).
  final String hint;

  final ValueChanged<String> onChanged;

  /// Supplied by a screen that also wants to clear the field itself.
  final TextEditingController? controller;

  /// §4, `M1` measured: the tint runs y 91.0..139.0 at 4×.
  static const double height = 48;

  /// The mark's box (§4) and the air after it, both measured off `M1`: ink at
  /// x 44.25..59.50 is an 18 dp Lucide box seated at the inset, and the words
  /// start at 71.75.
  static const double glyph = 18;
  static const double gap = KvSpace.s10;

  @override
  State<KvSearchField> createState() => _KvSearchFieldState();
}

class _KvSearchFieldState extends State<KvSearchField> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController();
  bool _owned = false;

  @override
  void initState() {
    super.initState();
    _owned = widget.controller == null;
  }

  @override
  void dispose() {
    if (_owned) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: KvSearchField.height,
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.s20),
      decoration: BoxDecoration(
        color: KvColor.plate,
        borderRadius: BorderRadius.circular(KvRadius.control),
      ),
      child: Row(
        children: [
          const KvGlyphIcon(
            KvGlyph.search,
            size: KvSearchField.glyph,
            tone: KvColor.inkMeta,
          ),
          const SizedBox(width: KvSearchField.gap),
          Expanded(
            child: TextField(
              controller: _controller,
              onChanged: widget.onChanged,
              textInputAction: TextInputAction.search,
              // The caret is one of BG-2's named ambient teals, so it is the
              // house `primary` and is not counted against the screen's three.
              cursorColor: KvColor.primary,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 15,
                height: 20 / 15,
                fontWeight: FontWeight.w400,
                fontVariations: KvWeight.w400,
                color: KvColor.ink,
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: widget.hint,
                hintStyle: const TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 15,
                  height: 20 / 15,
                  fontWeight: FontWeight.w400,
                  fontVariations: KvWeight.w400,
                  color: KvColor.inkMeta,
                ),
              ),
            ),
          ),
          // **A fixed slot, not an `AnimatedSwitcher`** (BG-24).
          //
          // The mark appears only when there is something to clear — BG-27's
          // rule for a control with nothing to commit — but a switcher's
          // default layout holds the larger child for the whole duration and
          // releases it in one frame: measured, the field held 228.0 dp for
          // 160 ms and then snapped to 272.0, which relocates the cut rather
          // than removing it (`ux-auditor`, UX-R5). A slot that is always
          // there and only changes opacity has no cut at all — the field's
          // width never moves, and the mark fades.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder: (context, value, _) {
              final showing = value.text.isNotEmpty;
              return Semantics(
                button: showing,
                label: 'Clear the search',
                child: ExcludeSemantics(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: showing
                        ? () {
                            _controller.clear();
                            widget.onChanged('');
                          }
                        : null,
                    // **The target is the field's whole depth**, which is 48
                    // rather than BG-12's 52 because the field itself is 48
                    // and a target cannot be taller than the control it sits
                    // inside. Stated here, as §4 requires of any visual under
                    // the floor: the mark is 18, the box around it is 44 × 48,
                    // and its right edge is the field's own inset.
                    child: SizedBox(
                      width: KvSpace.iconButton,
                      height: KvSearchField.height,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: AnimatedOpacity(
                          opacity: showing ? 1 : 0,
                          duration: KvMotion.fast,
                          curve: KvMotion.curve,
                          child: const KvGlyphIcon(
                            KvGlyph.close,
                            size: KvSearchField.glyph,
                            tone: KvColor.inkMeta,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
