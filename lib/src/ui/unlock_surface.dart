import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/vault_service.dart';
import 'theme/tokens.dart';

/// The locked-state surface (P1.3 shell, decision D-036: biometric-first). A
/// vault exists but is sealed; this offers the Path-A biometric unlock — the
/// real, device-proven lane (P1.2). It deliberately keys in **no** secret, so
/// it is not one of the §0.6 FLAG_SECURE secret screens; the passphrase
/// ceremony (with its FLAG_SECURE + a11y refusal) is P1.4.
///
/// Vault-calm throughout (DS-5): decelerate motion, no celebration, no
/// exclamation. The unlock callbacks are injected so the surface tests without
/// a platform channel.
class UnlockSurface extends StatefulWidget {
  const UnlockSurface({super.key, this.probe, this.unlock, this.debugFooter});

  /// Is a biometric (Path-A) unlock both enrolled and currently available?
  /// Defaults to the platform channel; injected in tests.
  final Future<bool> Function()? probe;

  /// Run the system biometric ceremony; true once Rust holds the seed.
  /// Defaults to the platform channel; injected in tests.
  final Future<bool> Function()? unlock;

  /// Debug-only escape hatch (the caged DevVaultPanel); null in release.
  final Widget? debugFooter;

  static Future<bool> _probeBiometric() async {
    final enrolled = await VaultService.ceremony.invokeMethod<bool>(
      'pathAEnrolled',
    );
    final available = await VaultService.ceremony.invokeMethod<bool>(
      'biometricAvailable',
    );
    return (enrolled ?? false) && (available ?? false);
  }

  static Future<bool> _runBiometricUnlock() async {
    final ok = await VaultService.ceremony.invokeMethod<bool>(
      'unlockBiometric',
    );
    return ok ?? false;
  }

  @override
  State<UnlockSurface> createState() => _UnlockSurfaceState();
}

class _UnlockSurfaceState extends State<UnlockSurface> {
  bool? _biometricReady; // null while probing
  bool _unlocking = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    final probe = widget.probe ?? UnlockSurface._probeBiometric;
    try {
      final ready = await probe();
      if (mounted) setState(() => _biometricReady = ready);
    } on PlatformException {
      if (mounted) setState(() => _biometricReady = false);
    }
  }

  Future<void> _unlock() async {
    final unlock = widget.unlock ?? UnlockSurface._runBiometricUnlock;
    setState(() {
      _unlocking = true;
      _message = null;
    });
    try {
      final ok = await unlock();
      // On success the status stream flips to unlocked and AppShell swaps this
      // surface for home — so we stay in the "unlocking" state until then and
      // never flash back to idle (P1.3 watch-out). Only a non-success needs a
      // local reset.
      if (!ok && mounted) {
        setState(() {
          _unlocking = false;
          _message = "Unlock didn't complete. Your funds are safe — try again.";
        });
      }
    } on PlatformException {
      if (mounted) {
        setState(() {
          _unlocking = false;
          _message = 'Unlock is unavailable right now. Your funds are safe.';
        });
      }
    }
  }

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
                  Icons.lock_outline,
                  size: KvSpace.xxl,
                  color: KvColor.primaryMuted,
                ),
                const SizedBox(height: KvSpace.l),
                Text('Vault locked', style: theme.textTheme.headlineSmall),
                const SizedBox(height: KvSpace.s),
                Text(
                  'Unlock to see your wallet.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: KvColor.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: KvSpace.xl),
                _action(theme),
                if (_message != null) ...[
                  const SizedBox(height: KvSpace.m),
                  Text(
                    _message!,
                    // Inter (prose), not the mono data role; neutral, not
                    // error-red — a retry prompt is not fund risk, and red is
                    // rationed to fund risk only (§3/§4). The copy already says
                    // funds are safe; the colour must agree.
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: KvColor.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                if (widget.debugFooter != null) ...[
                  const SizedBox(height: KvSpace.xl),
                  widget.debugFooter!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _action(ThemeData theme) {
    if (_biometricReady == null) {
      return const SizedBox(
        width: KvSpace.l,
        height: KvSpace.l,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: KvColor.primaryMuted,
        ),
      );
    }
    if (_biometricReady == false) {
      // No Path-A on this device yet — the passphrase unlock screen is P1.4.
      // Inter (prose), not the mono data role (§4).
      return Text(
        'Passphrase unlock arrives in the next update.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: KvColor.textTertiary,
        ),
        textAlign: TextAlign.center,
      );
    }
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        // 48 dp minimum touch target (§9).
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(KvSpace.touchTarget),
        ),
        onPressed: _unlocking ? null : _unlock,
        child: Text(_unlocking ? 'Unlocking…' : 'Unlock vault'),
      ),
    );
  }
}

/// The `!exists` state — no vault on this device yet. The real create ceremony
/// (generate → reveal → verify) is P1.4; this is a calm placeholder so the
/// shell is navigable. Debug builds get the caged DevVaultPanel to create one.
class NoVaultSurface extends StatelessWidget {
  const NoVaultSurface({super.key, this.debugFooter});

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
                Text('No vault yet', style: theme.textTheme.headlineSmall),
                const SizedBox(height: KvSpace.s),
                Text(
                  'Wallet setup arrives in the next update.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: KvColor.textSecondary,
                  ),
                  textAlign: TextAlign.center,
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
