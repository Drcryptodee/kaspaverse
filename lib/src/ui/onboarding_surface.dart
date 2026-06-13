import 'package:flutter/material.dart';

import 'restore_screen.dart';
import 'secret/secret_screen_guard.dart';
import 'theme/tokens.dart';

/// The `!exists` shell state (P1.4) — no vault on this device yet. Offers the
/// two onboarding paths: create a new wallet, or restore an existing one. The
/// create path's secure word reveal/verify is a native FLAG_SECURE surface
/// landing in the on-device build (D-037, session 2); restore is fully wired.
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
                Icon(
                  Icons.shield_outlined,
                  size: KvSpace.xxl,
                  color: KvColor.primaryMuted,
                ),
                const SizedBox(height: KvSpace.l),
                Text(
                  'Your sovereign vault',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: KvSpace.s),
                Text(
                  'Hold your own keys on Kaspa. Set up a new wallet, or restore '
                  'one you already own.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: KvColor.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: KvSpace.xl),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(KvSpace.touchTarget),
                    ),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const _CreateComingSoonScreen(),
                      ),
                    ),
                    child: const Text('Create new wallet'),
                  ),
                ),
                const SizedBox(height: KvSpace.sm),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(KvSpace.touchTarget),
                    ),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const RestoreScreen(),
                      ),
                    ),
                    child: const Text('Restore existing wallet'),
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

/// Honest placeholder for the create ceremony's secure reveal/verify — a native
/// FLAG_SECURE surface (D-037) that lands in the on-device build (session 2).
/// Guarded so even the placeholder proves the §0.6 mechanism. Deliberately does
/// NOT call `beginCreate` (no dangling ceremony before a reveal exists).
class _CreateComingSoonScreen extends StatelessWidget {
  const _CreateComingSoonScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SecretScreenGuard(
      title: 'your recovery words',
      child: Scaffold(
        appBar: AppBar(title: const Text('Create wallet')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(KvSpace.gutter),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.vpn_key_outlined,
                    size: KvSpace.xxl,
                    color: KvColor.primaryMuted,
                  ),
                  const SizedBox(height: KvSpace.l),
                  Text(
                    'Secure backup is almost here',
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: KvSpace.sm),
                  Text(
                    'Your 12 recovery words are shown on a screen that blocks '
                    'screenshots and never lets the rest of the app read them. '
                    'That secure reveal arrives in the next on-device build. '
                    'For now, you can restore an existing wallet.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: KvColor.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
