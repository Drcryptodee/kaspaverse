import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// **Where you are in a ceremony that has a fixed number of beats** — the
/// onboarding archetype's fourth clause, *progress that never lies*.
///
/// `O2`–`O6` measured at 4×: a **6 dp** dot per step, **6 dp** apart, and the
/// current step drawn as a **22 × 6** stadium. Done and current are `primary`;
/// what has not happened yet is `edgeHi`. Five steps therefore measure exactly
/// 70 dp, centred in the bar on the back control's own centre line.
///
/// **It is a reading, not a control.** No step is tappable: a create ceremony
/// is not a wizard you can skip around inside, and a dot that took a tap would
/// be offering to jump over the beat that writes the vault.
///
/// ## Why the count is passed in rather than inferred
///
/// The number a step indicator prints is a claim about a flow, and the flow it
/// describes here spans **two processes** — the passphrase and extra-word
/// beats are Flutter, the word reveal and its quiz are a separate FLAG_SECURE
/// Activity (D-039). Nothing in the widget tree can see the whole sequence, so
/// the screen that knows the shape states it. A widget that counted its own
/// siblings would have counted three and called it the ceremony.
class KvSteps extends StatelessWidget {
  const KvSteps({super.key, required this.count, required this.index})
    : assert(count >= 2, 'one step is not progress'),
      assert(index >= 0 && index < count, 'the current step is inside the set');

  /// How many beats the whole ceremony has.
  final int count;

  /// The zero-based beat the user is on. Everything before it is done.
  final int index;

  /// `O2` measured.
  static const double dot = 6;
  static const double current = 22;
  static const double gap = 6;

  /// The width [count] steps take — used by the tests that assert the bar's
  /// centre content fits beside its controls at the floor.
  static double widthFor(int count) =>
      (count - 1) * dot + current + (count - 1) * gap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // The dots are one reading, spoken once. Eleven separate nodes saying
      // "dot" is what an unlabelled indicator sounds like under TalkBack.
      label: 'Step ${index + 1} of $count',
      excludeSemantics: true,
      child: SizedBox(
        height: dot,
        width: widthFor(count),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < count; i++) ...[
              if (i > 0) const SizedBox(width: gap),
              AnimatedContainer(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : KvMotion.calm,
                curve: KvMotion.curve,
                width: i == index ? current : dot,
                height: dot,
                decoration: BoxDecoration(
                  color: i <= index ? KvColor.primary : KvColor.edgeHi,
                  borderRadius: BorderRadius.circular(dot / 2),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
