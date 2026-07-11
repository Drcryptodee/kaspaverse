import 'package:flutter/material.dart';

import 'create_screen.dart';
import 'restore_screen.dart';
import 'theme/kv_page_route.dart';
import 'theme/tokens.dart';
import 'widgets/ceremony_mark.dart';
import 'widgets/entrance.dart';

/// The `!exists` shell state (P1.4) — no vault on this device yet. Offers the
/// two onboarding paths: create a new wallet, or restore an existing one. Both
/// are fully wired: create runs the two-step ceremony (native FLAG_SECURE word
/// reveal + verify, D-037/D-039) then seals; restore uses the in-app word picker.
/// Vault-calm (DS-5): a steady invitation, no celebration.
class OnboardingSurface extends StatelessWidget {
  const OnboardingSurface({super.key, this.debugFooter});

  /// Debug-only escape hatch (the caged DevVaultPanel); null in release.
  final Widget? debugFooter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(KvSpace.gutter),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Entrance(child: CeremonyMark(Icons.shield_outlined)),
                const SizedBox(height: KvSpace.l),
                Entrance(
                  index: 1,
                  child: Column(
                    children: [
                      Text(
                        'Your sovereign vault',
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: KvSpace.s),
                      Text(
                        'Hold your own keys on Kaspa. Set up a new wallet, or '
                        'restore one you already own.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: KvColor.textSecondary,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: KvSpace.xl),
                Entrance(
                  index: 2,
                  child: Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () => Navigator.of(context).push(
                            KvPageRoute<void>(
                              builder: (_) => const CreateScreen(),
                            ),
                          ),
                          child: const Text('Create new wallet'),
                        ),
                      ),
                      const SizedBox(height: KvSpace.sm),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).push(
                            KvPageRoute<void>(
                              builder: (_) => const RestoreScreen(),
                            ),
                          ),
                          child: const Text('Restore existing wallet'),
                        ),
                      ),
                    ],
                  ),
                ),
                if (debugFooter != null) ...[
                  const SizedBox(height: KvSpace.xl),
                  debugFooter!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// The create path is now the real two-step ceremony — see create_screen.dart.
