import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'haptics.dart';

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
      onTap = null,
      active = false;

  /// A key that does something to the keyboard or the buffer — shift, page,
  /// backspace, space. It emits nothing.
  const KvKey.command(
    String label, {
    required this.onTap,
    this.flex = 2,
    this.active = false,
    this.semantics,
  }) : _label = label,
       emits = null;

  final String? _label;

  /// What is printed on the cap.
  String get label => _label ?? emits!;

  /// The character this key writes, or null on a command key.
  final String? emits;

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
           KvKey.command('⌫', onTap: onBackspace, semantics: 'Backspace'),
         ],
       ];

  final List<List<KvKey>> rows;
  final KvKeypadSkin skin;

  /// Receives exactly one character per press. Never the accumulated value.
  final ValueChanged<String> onChar;

  @override
  Widget build(BuildContext context) {
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
                    child: _KeyCap(cap: rows[r][i], skin: skin, onChar: onChar),
                  ),
                ],
              ],
            ),
          ),
      ],
    );

    // The secret skin sits on a bed: it replaces the system keyboard at the
    // bottom of a screen, and a keyboard floating on the void reads as a
    // dialog. The plain pad is part of its screen and takes no container —
    // BG-1, a container is earned.
    if (skin == KvKeypadSkin.plain) return keys;
    return Container(
      color: KvColor.surface,
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
  const _KeyCap({required this.cap, required this.skin, required this.onChar});

  final KvKey cap;
  final KvKeypadSkin skin;
  final ValueChanged<String> onChar;

  @override
  Widget build(BuildContext context) {
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

    final style = switch (skin) {
      // Mono, because every cap on the amount pad is a figure and the figure
      // it types is rendered in mono two inches above it.
      KvKeypadSkin.plain => const TextStyle(
        fontFamily: KvFont.mono,
        fontSize: 20,
        fontWeight: FontWeight.w500,
      ),
      KvKeypadSkin.secret => theme.textTheme.titleMedium,
    };

    return Semantics(
      button: true,
      label: cap.semantics ?? cap.label,
      child: Material(
        // A lit key is one step lighter, with its edge and ink in `ok` — the
        // depth ramp and the value hue doing the work a brand accent used to.
        color: cap.active ? KvColor.keyPressed : KvColor.key,
        borderRadius: BorderRadius.circular(KvRadius.key),
        child: InkWell(
          borderRadius: BorderRadius.circular(KvRadius.key),
          onTap: press,
          child: Container(
            height: skin.keyHeight,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(KvRadius.key),
              border: Border.all(
                color: cap.active ? KvColor.ok : KvColor.keyEdge,
              ),
            ),
            // The cap's glyph is excluded: the `Semantics` above already
            // speaks the key, and without this a screen reader reads
            // *"Backspace ⌫"* — the word and then the symbol it stands in
            // for. A cap whose glyph IS its name simply names itself.
            child: ExcludeSemantics(
              child: Text(
                cap.label,
                style: style?.copyWith(
                  color: cap.active
                      ? KvColor.ok
                      : (cap.emits == null && skin == KvKeypadSkin.plain
                            ? KvColor.inkMeta
                            : KvColor.ink),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
