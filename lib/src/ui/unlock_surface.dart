import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/vault_service.dart';
import 'biometric_copy.dart';
import 'passphrase_unlock_screen.dart';
import 'theme/kv_page_route.dart';
import 'theme/tokens.dart';
import 'widgets/ceremony_mark.dart';
import 'widgets/kv_loader.dart';

/// The locked-state surface (P1.3 shell, decision D-036: biometric-first). A
/// vault exists but is sealed; this offers the Path-A biometric unlock — the
/// real, device-proven lane (P1.2). It deliberately keys in **no** secret, so
/// it is not one of the §0.6 FLAG_SECURE secret screens; the passphrase
/// ceremony (with its FLAG_SECURE + a11y refusal) is P1.4.
///
/// Vault-calm throughout (BG-9): decelerate motion, no celebration, no
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

  // Through VaultService, never the static ceremony channel. The §0.11 auto-lock
  // suppression is an INSTANCE guard on the service, so a caller that reaches
  // past it cannot be covered by it *by construction* — and this lane is the one
  // where that bites hardest: the prompt takes the foreground, the lifecycle
  // reports paused, and at the default grace of 0 the lock fires against the
  // vault the user's finger has just opened. (wallet-security-auditor, Track 2 —
  // three of the four ceremonies were routed and this one was left behind.)
  static Future<bool> _probeBiometric() async {
    final enrolled = await VaultService.instance.pathAEnrolled();
    final status = await VaultService.instance.biometricStatus();
    return enrolled && status == biometricReady;
  }

  static Future<bool> _runBiometricUnlock() =>
      VaultService.instance.unlockBiometric();

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
    } catch (_) {
      // `catch (_)`, not `on PlatformException`: a `MissingPluginException` is
      // not one, and an uncaught throw here leaves `_biometricReady` null — a
      // permanent spinner on the one screen standing between the user and their
      // funds, with the "Unlock with passphrase" escape never rendered. INV-6's
      // liveness shadow (wallet-security-auditor).
      if (mounted) setState(() => _biometricReady = false);
    }
  }

  Future<void> _unlock() async {
    final unlock = widget.unlock ?? UnlockSurface._runBiometricUnlock;
    setState(() {
      _unlocking = true;
      _message = null;
    });
    var succeeded = false;
    try {
      final ok = await unlock();
      succeeded = ok;
      if (!ok && mounted) {
        setState(
          () => _message =
              "Unlock didn't complete. Your funds are safe — try again.",
        );
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        // Tapping "Use passphrase" on the system prompt is a CHOICE, and on this
        // screen it is the common one — reporting it as "unavailable right now"
        // told the user something false about their own deliberate action every
        // single time. Same contract as create/restore/settings.
        _message = e.code == 'cancelled' ? null : unlockFailureCopy(e.code);
        // A key invalidated by a new fingerprint is not a transient failure —
        // this lane is gone until re-enrolment, so stop offering it and put the
        // passphrase where the finger already is.
        if (e.code == biometricKeyInvalidated) _biometricReady = false;
      });
    } catch (_) {
      // NOT `on PlatformException` alone. A MissingPluginException is not one,
      // and neither is a channel reply that never arrives at all — which is
      // exactly what an unguarded platform throw produced, because Flutter's
      // DartMessenger swallows it and simply never replies. Uncaught, that left
      // `_unlocking` true forever: a disabled button reading "Unlocking…" on the
      // one screen standing between the user and their funds (run 1, F4). Same
      // reasoning as `_probe()` above — solved one method up, never carried down.
      if (!mounted) return;
      setState(
        () =>
            _message = 'Unlock is unavailable right now. Your funds are safe.',
      );
    } finally {
      // The ONE place `_unlocking` is released, so no future branch can forget.
      // On success we deliberately stay busy: the status stream flips and
      // AppShell swaps this surface for home, and releasing here would flash the
      // button back to idle first (P1.3 watch-out). Every other path releases —
      // including the ones that used to throw straight past this method.
      if (!succeeded && mounted) {
        setState(() => _unlocking = false);
      }
    }
  }

  /// Hand off to the §0.6 passphrase unlock screen (Path B) — pushed over the
  /// shell; on success the status stream flips unlocked and the shell shows home
  /// beneath, and that screen pops itself.
  void _openPassphrase() {
    Navigator.of(
      context,
    ).push(KvPageRoute<void>(builder: (_) => const PassphraseUnlockScreen()));
  }

  /// The recovery a user holding their 12 words already has, and which this
  /// screen used to hide from them.
  ///
  /// `restore_and_persist` refuses while a sealed blob exists, and this surface
  /// offers only "unlock" — so a user who has lost the passphrase but kept the
  /// words was staring at a screen that implied there was nothing left to do.
  /// There was: the words are the wallet, the passphrase only seals the copy on
  /// this phone. The app does not clear its own storage here — a wipe reachable
  /// from the locked screen is a wipe an attacker holding the phone can reach —
  /// so this names the Android-side path and the one precondition that matters
  /// (run 1, F6).
  void _openLostPassphrase() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      elevation: 0,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        // Scrolls as well as being scroll-controlled — the flag lifts the 9/16
        // cap, it does not make a fixed Column fit. ~400 characters plus a
        // button clears 1.3× on a 360×640 viewport by a margin thinner than the
        // estimate, and this is the app's ONLY lost-passphrase instruction.
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(KvSpace.gutter),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Lost your passphrase?',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
                const SizedBox(height: KvSpace.s),
                Text(
                  'Your 12 recovery words are the wallet. The passphrase only '
                  'seals the copy stored on this phone, so if you still have the '
                  'words your funds are reachable.\n\n'
                  'Remove this phone’s copy in Android Settings → Apps → '
                  'KaspaVerse → Storage → Clear storage, then open the app and '
                  'choose “Restore existing wallet”.\n\n'
                  'Only do this with the words in front of you. Without them, '
                  'clearing storage removes the wallet for good.',
                  style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                    color: KvColor.textSecondary,
                  ),
                ),
                const SizedBox(height: KvSpace.l),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: const Text('Got it'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
                const CeremonyMark(Icons.lock_outline),
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
                if (_biometricReady == true) ...[
                  const SizedBox(height: KvSpace.s),
                  TextButton(
                    onPressed: _openPassphrase,
                    child: const Text('Use passphrase instead'),
                  ),
                ],
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
                const SizedBox(height: KvSpace.s),
                TextButton(
                  onPressed: _openLostPassphrase,
                  child: const Text('Lost your passphrase?'),
                ),
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
      return const Center(child: KvLoader());
    }
    if (_biometricReady == false) {
      // No Path-A enrolled (or unavailable) — Path B is the unlock lane (P1.4).
      return SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: _openPassphrase,
          child: const Text('Unlock with passphrase'),
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: _unlocking ? null : _unlock,
        child: Text(_unlocking ? 'Unlocking…' : 'Unlock vault'),
      ),
    );
  }
}
