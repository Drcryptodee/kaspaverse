import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// A switch, and the row that carries it.
///
/// **"On" is `ok` green** (founder directive, restored at D-200): a toggle
/// reports a state the user set and that is true, which is the same family as
/// confirmed. Teal stays out — teal is light, never a status (BG-2), and one
/// emission per switch would spend the whole per-screen budget on chrome.
///
/// **Why this is drawn rather than a Material `Switch`.** `Switch` animates its
/// thumb through `AnimationController`s that consult no `disableAnimations`
/// anywhere in the pinned SDK, so a framework switch **slides under reduced
/// motion** while BG-9 says everything collapses to opacity.
///
/// `kv_theme.dart` used to pin a `SwitchThemeData` in exactly these colours —
/// the same decision rendered twice. **UX-3 retired it** (D-206) once this was
/// the app's only switch, and the removal is safe in the direction that
/// matters: an unthemed `Switch` would resolve its selected track to
/// `colorScheme.primary` and paint teal as a status (BG-2), so a future one
/// arrives visibly wrong rather than quietly plausible.
///
/// The **whole row is the target** and clears 48dp on its own; the 44×26
/// switch is the visual inside it, which BG-12 permits and requires the code
/// to state.
class KvToggle extends StatelessWidget {
  const KvToggle({
    super.key,
    required this.on,
    required this.title,
    required this.sub,
    required this.onChanged,
    this.disabledReason,
    this.bare = false,
  });

  /// No card of its own: the row sits inside a card that also holds the
  /// controls the switch governs (`T5`'s own-node card, founder on glass
  /// 2026-09-05). The tap target is still the whole row.
  final bool bare;

  final bool on;

  final String title;

  /// What the state means, in plain English. Always present: a switch whose
  /// two positions are not explained is a setting the user guesses at.
  final String sub;

  /// Null disables the row — and BG-12 then requires [disabledReason].
  final ValueChanged<bool>? onChanged;

  /// Why it cannot be pressed, in words. **A disabled control always says
  /// why** (BG-12); rendered under the row so the explanation is where the
  /// refusal is.
  final String? disabledReason;

  /// Drawn geometry, not layout — it does not sit on the §3 space grid because
  /// it is the shape of an object rather than the space around one.
  static const double trackWidth = 44;
  static const double trackHeight = 26;
  static const double thumb = 20;
  static const double trackInset = 3;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    assert(
      enabled || disabledReason != null,
      'A disabled control always says why, in words (BG-12).',
    );
    // BG-9: reduced motion collapses movement, and nothing in the pinned SDK
    // does this for an implicit animation — every moving thing in this app
    // honours it by hand.
    final reduced = MediaQuery.disableAnimationsOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          toggled: on,
          enabled: enabled,
          label: title,
          hint: enabled ? sub : '$sub. ${disabledReason!}',
          // The InkWell's own tap action is dropped by `excludeSemantics`, so
          // the wrapper has to declare one or the switch announces as a
          // control that cannot be activated — and this is the only control on
          // the INV-8 escape hatch.
          onTap: enabled ? () => onChanged!(!on) : null,
          excludeSemantics: true,
          child: InkWell(
            onTap: enabled ? () => onChanged!(!on) : null,
            borderRadius: BorderRadius.circular(KvRadius.panel),
            // The card is the home's: `plate`, the panel radius, **no
            // border** (founder on glass 2026-09-05 — every card shares the
            // home's topography).
            child: Container(
              padding: bare ? EdgeInsets.zero : const EdgeInsets.all(KvSpace.m),
              decoration: bare
                  ? null
                  : BoxDecoration(
                      color: KvColor.plate,
                      borderRadius: BorderRadius.circular(KvRadius.panel),
                    ),
              child: Opacity(
                // The whole row dims, so "you cannot press this right now" is
                // visible and not only spoken.
                opacity: enabled ? 1 : KvFreshness.opacityStale,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontFamily: KvFont.ui,
                              fontSize: 15,
                              height: 20 / 15,
                              fontWeight: FontWeight.w600,
                              color: KvColor.ink,
                            ),
                          ),
                          const SizedBox(height: KvSpace.xs),
                          Text(
                            sub,
                            style: const TextStyle(
                              fontFamily: KvFont.ui,
                              fontSize: 12,
                              height: 17 / 12,
                              color: KvColor.inkMeta,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: KvSpace.sm),
                    AnimatedContainer(
                      duration: reduced ? Duration.zero : KvMotion.fast,
                      curve: KvMotion.out,
                      width: trackWidth,
                      height: trackHeight,
                      padding: const EdgeInsets.all(trackInset),
                      alignment: on
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      // `T5`, measured: the resting track is a filled grey
                      // (42,52,51) — `edgeHi` as a fill — under an `inkMeta`
                      // knob, and it carries no border (founder on glass
                      // 2026-09-05).
                      decoration: BoxDecoration(
                        color: on ? KvColor.ok : KvColor.edgeHi,
                        borderRadius: BorderRadius.circular(KvRadius.control),
                      ),
                      child: Container(
                        width: thumb,
                        height: thumb,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: on ? KvColor.abyss : KvColor.inkMeta,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (!enabled) ...[
          const SizedBox(height: KvSpace.xs),
          Text(
            disabledReason!,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 12,
              height: 17 / 12,
              color: KvColor.inkMeta,
            ),
          ),
        ],
      ],
    );
  }
}
