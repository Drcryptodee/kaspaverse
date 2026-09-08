import 'package:flutter/material.dart';

import 'create_screen.dart';
import 'restore_screen.dart';
import 'theme/kv_page_route.dart';
import 'theme/tokens.dart';
import 'widgets/entrance.dart';
import 'widgets/kv_chrome.dart';
import 'widgets/kv_mark.dart';
import 'widgets/kv_two_pane.dart';

/// **`O1 · Welcome`** — the `!exists` shell state (P1.4): no vault on this
/// device yet, and two doors.
///
/// The lightest screen in the group and the one that says what the app is. The
/// render is a **left-aligned** composition — orb, a two-line `display`
/// statement, one sentence, then the pair of verbs in the thumb arc — and it
/// was a centred Material stack of `FilledButton` / `OutlinedButton` under a
/// tinted `Icons.shield_outlined` disc until UX-R6.
///
/// **The orb replaces the shield, and it is not a swap of one picture for
/// another.** A shield is a claim about safety made by the app about itself;
/// the mark is the app's identity, which is the honest thing to open with when
/// the sentence underneath is *answers to no one else — including us*. `KvMark`
/// at the canon 120 rung (`O1` measured a 115 dp disc inside a 148 dp halo).
///
/// Both paths are fully wired: create runs the ceremony (native FLAG_SECURE
/// word reveal + verify, D-037/D-039) then seals; restore uses the in-app word
/// picker. Vault-calm (BG-9): a steady invitation, no celebration.
class OnboardingSurface extends StatelessWidget {
  const OnboardingSurface({super.key, this.debugFooter});

  /// Debug-only escape hatch (the caged DevVaultPanel); null in release.
  final Widget? debugFooter;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        child: KvColumn(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.only(
                top: KvSpace.xl,
                bottom: KvSpace.l,
              ),
              child: ConstrainedBox(
                // The screen has no scroll at the reference geometry and needs
                // one at the floor: `display` at 40 / 1.3× is 52 dp a line.
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - KvSpace.xl - KvSpace.l,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  // Two equal gaps — above the mark and under the sentence —
                  // which is what `O1` draws (197.5 dp and 209).
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const SizedBox.shrink(),
                    _statement(),
                    _doors(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _statement() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      const Entrance(child: KvMark(size: 120)),
      const SizedBox(height: KvSpace.xl),
      Entrance(
        index: 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // §2 `display`, welcome rung: Jakarta 40 / 44, 800, −0.025em.
            const Text(
              'Your money.\nYour keys.',
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 40,
                height: 44 / 40,
                fontWeight: FontWeight.w800,
                fontVariations: KvWeight.w800,
                letterSpacing: -1,
                color: KvColor.ink,
              ),
            ),
            const SizedBox(height: KvSpace.s20),
            Text(
              'This wallet lives on this phone and answers to no one else '
              '— including us.',
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 15,
                height: 22 / 15,
                color: KvColor.inkDim,
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _doors(BuildContext context) => Entrance(
    index: 2,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KvAction(
          label: 'Create a new wallet',
          primary: true,
          onTap: () => Navigator.of(
            context,
          ).push(KvPageRoute<void>(builder: (_) => const CreateScreen())),
        ),
        const SizedBox(height: KvSpace.s10),
        KvAction.raised(
          label: 'I have recovery words',
          onTap: () => Navigator.of(
            context,
          ).push(KvPageRoute<void>(builder: (_) => const RestoreScreen())),
        ),
        if (debugFooter != null) ...[
          const SizedBox(height: KvSpace.xl),
          debugFooter!,
        ],
      ],
    ),
  );
}
