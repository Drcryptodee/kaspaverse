import 'package:flutter/material.dart';

import '../theme/kv_window.dart';
import '../theme/tokens.dart';
import 'haptics.dart';
import 'kv_glyph.dart';

/// Which skin the ONE keypad wears (D-189).
///
/// **The amount pad IS the passphrase keypad in a plain skin.** One muscle
/// memory for the whole app, one codepath to audit, and an amount inherits the
/// no-system-keyboard guarantee for free rather than by a second promise.
///
/// The skins differ in geometry and cap type and in nothing else: same tone,
/// same edge, same press feel, same haptic, same write-only emit path. A skin
/// that changed *behaviour* would be two keypads wearing one name.
///
/// **One thing the secret skin GAINED at the extraction, said plainly because
/// the sentence above would otherwise imply it was always there:** a
/// `selectionClick` per press. The old private key widget imported no haptics
/// at all. §6 asks for one on a keypad press and `restore_screen`'s word
/// picker already fires the same one, so this is the law being applied rather
/// than a new liberty — but it is a device-actuated per-keystroke marker on a
/// passphrase path that did not exist before, so it is recorded rather than
/// absorbed. It is uniform across every cap, so it discriminates no character
/// (`ffi-leak-auditor`, UX-4).
enum KvKeypadSkin {
  /// Amounts. A tall three-column grid on the ground — no bed, mono caps,
  /// because every key on it is a digit.
  plain,

  /// Passphrases and recovery words. A bedded alphanumeric keyboard with
  /// narrow caps, sized so a 10-key row fits a 320 dp screen.
  secret,
}

extension _KvKeypadSkinMetrics on KvKeypadSkin {
  /// Key height. Both clear the 48 dp target law; the plain pad takes the
  /// taller control height because it has four rows, not five, and the extra
  /// height is what makes a money keypad feel deliberate under the thumb.
  double get keyHeight => switch (this) {
    KvKeypadSkin.plain => KvSpace.control,
    KvKeypadSkin.secret => KvSpace.touchTarget,
  };

  /// Gap between keys and between rows.
  double get gap => switch (this) {
    KvKeypadSkin.plain => KvSpace.s,
    KvKeypadSkin.secret => KvSpace.xs,
  };
}

/// One key cap.
///
/// A key is either a **character key** — it emits [emits] into the caller's
/// buffer and nothing else — or a **command key**, which runs [onTap]. The
/// separation is the audit surface: a character key has no callback of its own
/// to do something with what it typed.
@immutable
class KvKey {
  /// A key that writes one character. The cap shows the character it writes
  /// unless [label] says otherwise, so the two cannot disagree by default.
  const KvKey.char(this.emits, {String? label, this.flex = 2, this.semantics})
    : _label = label,
      mark = null,
      onTap = null,
      active = false,
      bare = false,
      isGap = false;

  /// A key that does something to the keyboard or the buffer — shift, page,
  /// backspace, space. It emits nothing.
  ///
  /// A command cap is a **word** where a word works (`space`, `ABC`, `123`) and
  /// a **drawn [mark]** where a mark is right. It is never a symbol codepoint:
  /// BG-25 (D-229) puts glyph ownership in the app, and the cap that carried
  /// `'⌫'` was rendered in a face with no U+232B in its cmap. When [mark] is
  /// set, [label] stops being the cap and becomes what a screen reader says.
  const KvKey.command(
    String label, {
    required this.onTap,
    this.mark,
    this.flex = 2,
    this.active = false,
    this.semantics,
    this.bare = false,
  }) : _label = label,
       emits = null,
       isGap = false;

  /// **A hole in the grid.** Not a key at all: it emits nothing, does nothing
  /// and draws nothing, and exists so a row can be short without the row above
  /// it changing width. `O2`'s pad leaves the bottom-left cell empty, which a
  /// `Row` cannot say any other way.
  const KvKey.gap({this.flex = 2})
    : _label = '',
      emits = null,
      mark = null,
      onTap = null,
      active = false,
      semantics = null,
      bare = true,
      isGap = true;

  final String? _label;

  /// What is printed on the cap.
  String get label => _label ?? emits!;

  /// The character this key writes, or null on a command key.
  final String? emits;

  /// A drawn mark to print on the cap instead of [label]. Command keys only —
  /// a character key's cap is the character it writes.
  final KvGlyph? mark;

  /// A command key's action, or null on a character key.
  final VoidCallback? onTap;

  /// Relative width within its row.
  final int flex;

  /// Lit (a held shift) — a state the user set and that is true, which D-200
  /// puts in `ok` green. **Never teal**: teal is light, not a status (BG-2),
  /// and a primitive is where that would otherwise be inherited by every skin
  /// after this one.
  final bool active;

  /// What a screen reader says, when the cap is a symbol rather than a word.
  final String? semantics;

  /// **No plate under this cap** — the mark sits straight on the ground.
  ///
  /// `O2` draws its erase key this way and its ten digits with plates, and the
  /// composition is why: on a pad of ten figures the one glyph is plainly the
  /// odd one out, so the plate is doing nothing the shape does not already do
  /// (BG-1 — a container is earned). It costs no reach: the cell keeps its full
  /// box, so the touch target is the key's, not the glyph's (BG-12).
  ///
  /// The amount pad keeps its plate, because there the erase key sits in a
  /// four-row grid beside a decimal point and has no such singularity.
  final bool bare;

  /// Whether this cell is a [KvKey.gap] — nothing drawn, nothing pressable.
  final bool isGap;
}

/// The one on-screen keypad, in [skin].
///
/// **The system IME never sees a keystroke from here** (§0.7). Keys emit a
/// single character to [onChar]; this widget accumulates nothing, stores
/// nothing and reads nothing back, which is what lets the secret skin drive a
/// `SecretByteBuffer` without a Dart `String` of the secret ever existing
/// (INV-3) — and what lets the plain skin be the same code rather than a
/// look-alike. A key that could read its own history would be a keypad the
/// leak audit has to reason about twice.
///
/// Every press is a `selectionClick` (§6, *keypad press*).
class KvKeypad extends StatelessWidget {
  const KvKeypad({
    super.key,
    required this.rows,
    required this.skin,
    required this.onChar,
  });

  /// The numeric amount pad: three columns, a decimal point and a backspace.
  /// Digits and `.` only — an amount has no other characters, so there is no
  /// shift, no symbol page and nothing to switch.
  KvKeypad.amount({
    super.key,
    required this.onChar,
    required VoidCallback onBackspace,
  }) : skin = KvKeypadSkin.plain,
       rows = [
         [const KvKey.char('1'), const KvKey.char('2'), const KvKey.char('3')],
         [const KvKey.char('4'), const KvKey.char('5'), const KvKey.char('6')],
         [const KvKey.char('7'), const KvKey.char('8'), const KvKey.char('9')],
         [
           const KvKey.char('.', semantics: 'Decimal point'),
           const KvKey.char('0'),
           KvKey.command(
             'Backspace',
             mark: KvGlyph.backspace,
             onTap: onBackspace,
           ),
         ],
       ];

  /// **`O2`'s unlock pad — the same plain skin, one row shorter of a key.**
  ///
  /// Not a third skin: a skin is a geometry and a cap type, and this pad's are
  /// the amount pad's exactly (three columns, mono figures, the taller control
  /// height). What differs is the KEYS — no decimal point, because a PIN has no
  /// fractional part — and a keyboard that differed only in its keys and called
  /// itself a new skin would be the homonym `settings_screen_test` and
  /// `node_screen_test` had to count around (L201).
  ///
  /// The bottom-left cell is a [KvKey.gap] and the erase key is [KvKey.bare],
  /// both measured off `O2` at 4x.
  KvKeypad.pin({
    super.key,
    required this.onChar,
    required VoidCallback onBackspace,
  }) : skin = KvKeypadSkin.plain,
       rows = [
         [const KvKey.char('1'), const KvKey.char('2'), const KvKey.char('3')],
         [const KvKey.char('4'), const KvKey.char('5'), const KvKey.char('6')],
         [const KvKey.char('7'), const KvKey.char('8'), const KvKey.char('9')],
         [
           const KvKey.gap(),
           const KvKey.char('0'),
           KvKey.command(
             'Backspace',
             mark: KvGlyph.backspace,
             onTap: onBackspace,
             bare: true,
           ),
         ],
       ];

  final List<List<KvKey>> rows;
  final KvKeypadSkin skin;

  /// Receives exactly one character per press. Never the accumulated value.
  final ValueChanged<String> onChar;

  /// **§3a's `short` row, built** — *phone landscape: keypad keys 48*.
  ///
  /// The rule has been in the law since Deep V6 and nothing implemented it, so
  /// every keypad drew its portrait height in landscape. `O7` in the 915 × 412
  /// frame overflowed by 3 dp with the suggestion strip and the counter row
  /// under it — found in a preview frame at a geometry, which is where
  /// geometry defects are found.
  ///
  /// **The secret skin only, and the amount pad's short rule is still owed.**
  /// Not laziness: the amount pad shares its screen with a figure and one
  /// pill and has slack at 412, while a secret keyboard sits under a ceremony
  /// that also needs a body. Moving both would re-tone a `expanded short`
  /// frame UX-R2 already earned its tick on, without the founder looking at
  /// it. Written down rather than half-done (register §20).
  ///
  /// 48 is under BG-12's 52 dp floor, and §3a is the law's own exception for
  /// this class — the same document that sets the floor sets this number.
  double _keyHeight(BuildContext context) {
    if (skin != KvKeypadSkin.secret) return skin.keyHeight;
    return KvWindow.of(context).heightClass == KvHeightClass.short
        ? 48
        : skin.keyHeight;
  }

  @override
  Widget build(BuildContext context) {
    final keyHeight = _keyHeight(context);
    final keys = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var r = 0; r < rows.length; r++)
          Padding(
            padding: EdgeInsets.only(
              bottom: r == rows.length - 1 ? 0 : skin.gap,
            ),
            child: Row(
              children: [
                for (var i = 0; i < rows[r].length; i++) ...[
                  if (i > 0) SizedBox(width: skin.gap),
                  Expanded(
                    flex: rows[r][i].flex,
                    child: _KeyCap(
                      cap: rows[r][i],
                      skin: skin,
                      height: keyHeight,
                      onChar: onChar,
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );

    // **Neither skin takes a bed** (BG-1: a container is earned).
    //
    // The secret skin used to sit on a `plate` slab, on the argument that a
    // keyboard floating on the void reads as a dialog. `O2` and `O7` both draw
    // it bare on the ground — caps in `plate` directly on `abyss`, sampled at
    // 4× — and there is no void to float on: the ground IS the screen, and the
    // slab was a second surface under caps already a step lighter than it,
    // which is a container drawn around something already contained. The
    // founder's render outranks the reasoning that put it there (D-259).
    //
    // The 4 dp of side air stays: `O7` seats its keys at x 29 inside a content
    // column that starts at 25, which is exactly this padding.
    if (skin == KvKeypadSkin.plain) return keys;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.xs,
        vertical: KvSpace.s,
      ),
      child: keys,
    );
  }
}

/// One cap. Both skins render through this: the fill, the edge, the radius and
/// the press feel are the primitive's, and only the type and the height are
/// the skin's.
class _KeyCap extends StatelessWidget {
  const _KeyCap({
    required this.cap,
    required this.skin,
    required this.height,
    required this.onChar,
  });

  final KvKey cap;
  final KvKeypadSkin skin;

  /// The cap's box, resolved by the pad from the window's height class.
  final double height;

  final ValueChanged<String> onChar;

  /// The cap itself: a drawn mark, or the type. **The mark is sized from the
  /// cap type it replaces** rather than from a constant of its own — one number
  /// for both, so a type-ramp change carries the glyph with it and cannot leave
  /// a mark behind at the old size (L121: a size nobody can re-derive is a size
  /// nobody can re-check).
  ///
  /// **And it takes the text scaler, because a drawn cap is still type's job**
  /// (BG-14; `ux-auditor`, D-229). The `'⌫'` it replaced was a `Text` and grew
  /// with everyone's setting for free; a `KvGlyphIcon` takes a fixed dp, so
  /// swapping the two silently made the erase key — the key that corrects a
  /// wrong amount before it is signed — the only cap on the pad that ignored
  /// the user's text size. A drawn mark that is a control's sole identification
  /// is information, not decoration.
  Widget _cap(BuildContext context, TextStyle? style, Color ink) {
    final mark = cap.mark;
    if (mark != null) {
      final base = style?.fontSize ?? 20;
      return KvGlyphIcon(
        mark,
        size: MediaQuery.textScalerOf(context).scale(base),
        tone: ink,
      );
    }
    return Text(cap.label, style: style?.copyWith(color: ink));
  }

  @override
  Widget build(BuildContext context) {
    // A hole in the grid still occupies its cell — that is its whole job.
    if (cap.isGap) return SizedBox(height: height);
    final theme = Theme.of(context);
    final emits = cap.emits;
    void press() {
      KvHaptic.selection();
      if (emits != null) {
        onChar(emits);
      } else {
        cap.onTap!();
      }
    }

    // One tone rule for both cap kinds, so a drawn mark and a typed cap can
    // never disagree about what a lit or a command key looks like.
    final ink = cap.active
        ? KvColor.ok
        : (cap.emits == null && skin == KvKeypadSkin.plain
              ? KvColor.inkMeta
              : KvColor.ink);

    final style = switch (skin) {
      // Mono, because every cap on the amount pad is a figure and the figure
      // it types is rendered in mono two inches above it.
      // **600**, the Bible's own number for a key cap (§4 *Secure keypad*:
      // mono 22 / 600). It shipped declared 500 and painted 400 (the L150
      // bug), UX-R8 paired it so 500 rendered, and the founder chose the
      // Bible's weight on glass (2026-09-11: *"should we make em 600?"* —
      // yes). Size stays 20; the row's 22 is a separate question nobody has
      // asked.
      KvKeypadSkin.plain => const TextStyle(
        fontFamily: KvFont.mono,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        fontVariations: KvWeight.w600,
      ),
      KvKeypadSkin.secret => theme.textTheme.titleMedium,
    };

    return Semantics(
      button: true,
      label: cap.semantics ?? cap.label,
      child: Material(
        // A lit key is one step lighter, with its edge and ink in `ok` — the
        // depth ramp and the value hue doing the work a brand accent used to.
        // A BARE cap takes no fill at all: `O2` draws its erase key on the
        // ground, and the cell keeps its full box either way so the reach is
        // the same (BG-12).
        color: cap.bare
            ? Colors.transparent
            : (cap.active ? KvColor.chip : KvColor.plate),
        borderRadius: BorderRadius.circular(KvRadius.key),
        child: InkWell(
          borderRadius: BorderRadius.circular(KvRadius.key),
          onTap: press,
          child: Container(
            height: height,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(KvRadius.key),
              border: cap.bare
                  ? null
                  : Border.all(
                      color: cap.active ? KvColor.ok : KvColor.plateEdge,
                    ),
            ),
            // The cap is excluded from semantics: the `Semantics` above
            // already speaks the key, and without this a screen reader would
            // read the cap and then the word it stands for. A cap whose glyph
            // IS its name simply names itself.
            child: ExcludeSemantics(child: _cap(context, style, ink)),
          ),
        ),
      ),
    );
  }
}
