import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_glyph.dart';
import 'masked_dots.dart';

/// **The parts the recovery-word surfaces are made of** (`O3` · `O4` · `O5` ·
/// `O7`), in one file because the two ceremonies that show or take a recovery
/// phrase must not draw it two ways.
///
/// Create shows twelve words on a native FLAG_SECURE screen and quizzes four
/// of them back; restore takes twelve or twenty-four by picking from the
/// wordlist. They are different flows with the same subject, and every time
/// one of them grew a private copy of a word chip, a mask or a reveal control,
/// the two drifted — the register carried `restore_screen.dart:536`'s six
/// `•` characters against §4's fixed four-dot mask as an explicit debt for
/// exactly that reason (L143).

/// **One recovery word, in a chip** — `O7`'s tray and `O4`'s answer row.
///
/// A mono index in `inkMeta`, then either the word in `ink` or the fixed
/// four-dot mask. The index is mono because it is a position and BG-30 sets
/// every count in mono; the word is Jakarta because it is a word.
///
/// `O7` measured at 4×: a 32 dp `chip` stadium, content-sized, 6 dp apart.
class KvWordChip extends StatelessWidget {
  const KvWordChip({super.key, required this.index, this.word})
    : prefix = null,
      typing = false;

  /// **The word being typed right now** — `O7`'s teal-outlined chip holding
  /// the prefix the user has keyed so far.
  ///
  /// **Painting it costs nothing that is not already on the screen; holding it
  /// in a Dart `String` does, and that is `restore_screen`'s debt, not this
  /// widget's.**
  ///
  /// The first draft of this comment called the prefix *a public search query
  /// over a public wordlist*. Measured against the bundled asset that is false
  /// past three characters: of 2048 English BIP39 words **no two share a
  /// four-character prefix**, so a four-key `_filter` IS the word, uniquely
  /// (`ffi-leak-auditor`, UX-R6). Drawing it changes nothing — the suggestion
  /// strip beside it already narrows to one word, and the alternative is a
  /// keyboard that echoes nothing at all, where a user cannot tell a mistyped
  /// letter from a word that is not in the list. What is a real residual is
  /// the immutable `String` the picker accumulates it in, which is logged with
  /// its own trigger beside `_indices` and `_assemblePhrase`.
  const KvWordChip.typing({
    super.key,
    required this.index,
    required this.prefix,
  }) : word = null,
       typing = true;

  final int index;

  /// The word, when it is being revealed. Null draws the mask.
  final String? word;

  final String? prefix;
  final bool typing;

  /// `O7` measured 32; the founder took it down on glass — the tray and its
  /// words "feel kinda big" against a three-column grid, and the chip is a
  /// record of a word, not a control you aim at, so it owes no touch target.
  static const double height = 30;

  @override
  Widget build(BuildContext context) {
    final revealed = word;
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.s),
      decoration: BoxDecoration(
        color: typing ? Colors.transparent : KvColor.chip,
        borderRadius: BorderRadius.circular(KvRadius.control),
        border: typing ? Border.all(color: KvColor.primary, width: 1.5) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!typing) ...[
            Text('$index', style: _index),
            const SizedBox(width: KvSpace.s),
          ],
          if (typing)
            Text(
              // An empty prefix still draws the chip: the slot exists and is
              // waiting, which is what `O4`'s dashed ring says on its screen.
              prefix!.isEmpty ? '$index' : prefix!,
              style: _index.copyWith(
                fontFamily: prefix!.isEmpty ? KvFont.mono : KvFont.ui,
                color: KvColor.primary,
                fontWeight: FontWeight.w600,
                fontVariations: KvWeight.w600,
              ),
            )
          else if (revealed != null)
            // **Flexible, because the cell is now a fixed grid column.** The
            // tray used to be a `Wrap`, so revealing re-flowed every chip and
            // the words landed in different places than the mask had — the
            // founder asked for the same rows and columns either way.
            Flexible(
              child: Text(
                revealed,
                style: _word,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
              ),
            )
          else
            const KvMaskDots.fixed(),
        ],
      ),
    );
  }

  static const TextStyle _index = TextStyle(
    fontFamily: KvFont.mono,
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w500,
    fontVariations: KvWeight.w500,
    color: KvColor.inkMeta,
  );

  static const TextStyle _word = TextStyle(
    fontFamily: KvFont.ui,
    fontSize: 14,
    height: 18 / 14,
    fontWeight: FontWeight.w600,
    fontVariations: KvWeight.w600,
    color: KvColor.ink,
  );
}

/// **A word offered from the list** — `O7`'s suggestion pills and `O4`'s bank.
///
/// A 48 dp `chip` stadium with the word centred in `ink`. It carries no index:
/// nothing about it says where the word would land, because at the moment it
/// is offered the answer is always *next*.
class KvSuggestion extends StatelessWidget {
  const KvSuggestion({super.key, required this.word, required this.onTap});

  final String word;
  final VoidCallback onTap;

  /// **52, not `O7`'s drawn 48.** A suggestion is a free-standing control with
  /// nothing constraining it, and BG-12's floor was raised from 48 with the
  /// clause *nothing that passed at 48 is grandfathered*. D-259 gives the
  /// render design; a target size is function, and the one thing a user does
  /// on this screen twelve or twenty-four times running is hit one of these
  /// (`ux-auditor`, UX-R6).
  static const double height = KvSpace.touchTarget;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: word,
    excludeSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: height,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: KvSpace.s20),
        decoration: BoxDecoration(
          color: KvColor.chip,
          borderRadius: BorderRadius.circular(KvRadius.control),
        ),
        child: Text(
          word,
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 16,
            height: 20 / 16,
            fontWeight: FontWeight.w600,
            fontVariations: KvWeight.w600,
            color: KvColor.ink,
          ),
        ),
      ),
    ),
  );
}

/// **Hold to reveal** — `O3`'s pill, and the one control that puts recovery
/// words on a screen.
///
/// A `chip` stadium with the `eye` mark and its label in `primaryMuted`
/// (§4's `KvWordGrid` row, and `O3` sampled at 4×: `#1A2120` under `#70C7BA`).
/// It retires the last two `Icons.*` in the onboarding group —
/// `visibility_outlined` and `visibility_off_outlined` — for [KvGlyph.eye] and
/// [KvGlyph.eyeOff], which is the pair Lucide draws rather than a rotation of
/// one mark.
///
/// **A hold, never a toggle** (BG-10). A toggle can be left on and walked away
/// from; a hold lasts exactly as long as the user is present for it, which is
/// the property that matters on a phrase worth the wallet. The height is
/// [KvSpace.control] — the render draws 48, and the founder's ruling of
/// 2026-09-08 that every pill in the app shares a height is later than the
/// render and outranks it.
class KvRevealHold extends StatelessWidget {
  const KvRevealHold({
    super.key,
    required this.revealed,
    required this.onChanged,
  });

  final bool revealed;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: revealed ? 'Showing your words' : 'Hold to check your words',
    excludeSemantics: true,
    child: GestureDetector(
      // Opaque, so the whole pill — including the air between the mark and its
      // label — takes the press rather than only the ink.
      behavior: HitTestBehavior.opaque,
      // **Down, not long-press.** `onLongPressStart` does not fire until
      // Flutter's 500 ms threshold, and the founder read that on glass as the
      // control being slow rather than as a deliberate hold. The native reveal
      // screen has always used raw ACTION_DOWN/UP, so the two halves of the
      // same ceremony did not even feel alike across the process seam.
      //
      // `onTapCancel` is what keeps this honest: a press that turns into a
      // scroll hides the words again instead of latching them open.
      onTapDown: (_) {
        KvHaptic.selection();
        onChanged(true);
      },
      onTapUp: (_) => onChanged(false),
      onTapCancel: () => onChanged(false),
      child: Container(
        height: KvSpace.control,
        padding: const EdgeInsets.symmetric(horizontal: KvSpace.l),
        decoration: BoxDecoration(
          color: KvColor.chip,
          borderRadius: BorderRadius.circular(KvRadius.control),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            KvGlyphIcon(
              revealed ? KvGlyph.eyeOff : KvGlyph.eye,
              size: KvSpace.s20,
              tone: KvColor.primaryMuted,
            ),
            const SizedBox(width: KvSpace.sm),
            Text(
              revealed ? 'Release to hide' : 'Hold to reveal',
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 16,
                height: 20 / 16,
                fontWeight: FontWeight.w600,
                fontVariations: KvWeight.w600,
                color: KvColor.primaryMuted,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// **`O5`'s field** — a 56 dp `plate` stadium holding a secret's LENGTH.
///
/// It renders [KvMaskDots] from a `ValueNotifier<int>` and has no other
/// channel to the bytes, which is what makes a field-shaped object legal on a
/// secret screen at all (INV-3).
///
/// **The render's reveal eye is not built, and INV-3 is the reason.**
/// `SecretByteBuffer` exposes a length and nothing else — that is the whole
/// point of the class — so painting the typed characters would mean the secret
/// becoming a Dart `String`. On the create ceremony the check that eye would
/// have given is already there and stronger: the word is typed a second time
/// and compared in place, which catches the typo an eye invites you to read
/// past.
class KvSecretField extends StatelessWidget {
  const KvSecretField({
    super.key,
    required this.length,
    required this.active,
    required this.placeholder,
    this.enabled = true,
    this.onTap,
    this.revealed,
    this.onReveal,
  });

  final ValueListenable<int> length;

  /// Whether this is the field the keyboard is typing into. The inactive one
  /// is not disabled — both are live in the flow's own order — it simply is
  /// not the one taking keys, and goes quiet to say so (BG-27).
  final bool active;

  final String placeholder;

  /// **Whether this field can be typed into at all**, which is a different
  /// question from [active] and the render draws both. `O5` shows the two boxes
  /// before the switch is on: they are what tells you *this word gets typed
  /// twice* before you have committed to typing it once. A disabled field is
  /// quiet and unpressable; an inactive one is live but not the one taking keys.
  final bool enabled;

  /// Take the keyboard. Null means this field cannot be focused — a disabled
  /// field, or a screen with no focus model.
  final VoidCallback? onTap;

  /// **The characters, while a hold is down** (D-312, §3 of the R6b prompt).
  ///
  /// Non-null only for the duration of a press on [onReveal]'s control, and the
  /// `String` behind it is [SecretByteBuffer.revealWhileHeld]'s ledgered
  /// residual — read that doc before touching this. Null means masked, which is
  /// every other moment.
  final String? revealed;

  /// Drives the trailing eye. Null draws no eye at all, which is what every
  /// field but `O5`'s first one wants.
  final ValueChanged<bool>? onReveal;

  @override
  Widget build(BuildContext context) {
    final onReveal = this.onReveal;
    final field = Container(
      // **A minimum, not a fixed height** — because the revealed word must be
      // ALL of it. Clipped to one line the field faded the tail of any secret
      // wider than the box: measured at BG-14's own floor (320 dp / 1.3×) a
      // twelve-character word lost about a third of itself, silently, on the
      // one control whose entire purpose is reading a word back against a
      // piece of paper. That is `KvAddress`'s ruling in §4 — *an ellipsis eats
      // the tail, the one part a person actually checks* — arriving on a
      // second surface (`ux-auditor` BLOCK, D-312).
      //
      // Growing is safe here in a way it was not on the restore tray (L200):
      // there is one field, and what moves is everything BELOW it, by one line.
      // Nothing changes identity or position relative to its own label, and
      // the acts are pinned in the foot, so no control moves under the thumb.
      constraints: const BoxConstraints(minHeight: KvSpace.control),
      width: double.infinity,
      alignment: Alignment.centerLeft,
      // `O5` measured: the dots start 22 dp inside the field.
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.s22,
        vertical: KvSpace.s,
      ),
      // **Focus is the fill, not a teal ring.** The active field carried a
      // 1.5 dp `primary` outline and the founder read it on glass as
      // "not-quite-it" — full-strength teal is the app's commit colour (BG-7,
      // BG-27: lit means committable), and spending it on *which box has the
      // caret* devalues it on the pill directly below that actually commits.
      // The active field lifts to `chip` and takes a hairline `edgeHi`; the
      // inactive one stays `plate` and unstroked. Same signal, quieter register,
      // and the teal is left to mean one thing.
      decoration: BoxDecoration(
        color: active && enabled ? KvColor.chip : KvColor.plate,
        borderRadius: BorderRadius.circular(KvRadius.control),
        border: Border.all(
          color: active && enabled ? KvColor.edgeHi : Colors.transparent,
          width: 1,
        ),
      ),
      child: ValueListenableBuilder<int>(
        valueListenable: length,
        builder: (context, n, _) {
          final shown = revealed;
          if (shown != null && n > 0) {
            // The ledgered residual, on the glass. Mono because it is being
            // read back character by character against a piece of paper, which
            // is the whole reason the eye exists.
            //
            // **`ExcludeSemantics`, and it is not cosmetic.** A `Text` puts its
            // string in a `SemanticsNode` label — a second GC-heap copy held by
            // the framework, and the one surface an accessibility or automation
            // client reads. `SecretScreenGuard` already fails closed against an
            // active a11y service, so this is the second fence rather than the
            // first (`ffi-leak-auditor`, D-312). The masked path is wrapped for
            // the opposite reason: a dot run has to ANNOUNCE its length,
            // because it has nothing else to say.
            return ExcludeSemantics(
              // **Wraps, and is never truncated.** See the box above.
              //
              // **Mono, and the ruling is named here rather than inferred.**
              // `KvWordChip` sets a recovery WORD in Jakarta because it is a
              // word from a fixed list; this is an arbitrary case-sensitive
              // string the user invented and is now checking character by
              // character against paper, where `l`/`I`/`1` and `O`/`0` have to
              // be distinguishable. That is what mono is for (BG-30's
              // reasoning, applied to a string rather than a figure).
              child: Text(
                shown,
                style: const TextStyle(
                  fontFamily: KvFont.mono,
                  fontSize: 15,
                  height: 22 / 15,
                  fontWeight: FontWeight.w500,
                  fontVariations: KvWeight.w500,
                  color: KvColor.ink,
                ),
              ),
            );
          }
          if (n == 0) {
            return Text(
              placeholder,
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 15,
                height: 22 / 15,
                fontWeight: FontWeight.w400,
                fontVariations: KvWeight.w400,
                // A placeholder that is not information is `etch` (§1.3); a
                // DISABLED field's placeholder is quieter still, because it is
                // describing something you cannot do yet.
                color: enabled
                    ? KvColor.etch
                    : KvColor.etch.withValues(alpha: 0.6),
              ),
            );
          }
          return Semantics(
            label: '$n characters entered',
            child: KvMaskDots.length(
              n,
              // `O5` measured: 4.2 dp `ink` dots on a 12.75 pitch.
              size: 4.2,
              gap: 8.5,
              tone: KvColor.ink,
              alignment: WrapAlignment.start,
            ),
          );
        },
      ),
    );

    final body = onReveal == null
        ? field
        : Row(
            children: [
              Expanded(child: field),
              const SizedBox(width: KvSpace.s),
              _KvFieldEye(revealed: revealed != null, onChanged: onReveal),
            ],
          );

    final tap = onTap;
    if (tap == null || !enabled) return body;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: tap,
      child: body,
    );
  }
}

/// **`O5`'s eye** — a round chip at the end of the first field, held rather
/// than toggled.
///
/// A sticky toggle would leave the extra word legible on a screen the user has
/// walked away from, and would make the residual behind
/// [SecretByteBuffer.revealWhileHeld] outlive the gesture it is fenced by. Held,
/// the word is on the glass exactly as long as a finger is on the control — the
/// same contract [KvRevealHold] keeps for the recovery words, and the same one
/// the native reveal keeps across the process seam.
class _KvFieldEye extends StatelessWidget {
  const _KvFieldEye({required this.revealed, required this.onChanged});

  final bool revealed;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: revealed ? 'Showing your word' : 'Hold to see your word',
    excludeSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Down/up, not long-press: 500 ms of nothing reads as a broken control,
      // which is what the founder found on the reveal pill (UX-R6, L200).
      onTapDown: (_) {
        KvHaptic.selection();
        onChanged(true);
      },
      onTapUp: (_) => onChanged(false),
      onTapCancel: () => onChanged(false),
      child: Container(
        // `O5` measured: a round chip the height of the field's control box,
        // which also clears BG-12's target floor without a hit-box hack.
        width: KvSpace.control,
        height: KvSpace.control,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: KvColor.chip,
          shape: BoxShape.circle,
        ),
        child: KvGlyphIcon(
          revealed ? KvGlyph.eyeOff : KvGlyph.eye,
          size: KvSpace.s20,
          tone: KvColor.ink,
        ),
      ),
    ),
  );
}
