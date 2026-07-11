import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/vault_service.dart';
import '../theme/tokens.dart';
import '../widgets/kv_loader.dart';

/// Wraps a §0.6 secret screen with the two platform guarantees locked at
/// P1 §0.6 (D-028):
///
/// 1. **FLAG_SECURE** on while the screen is shown — no screenshots, no recents
///    thumbnail (set on the native window via the ceremony `MethodChannel`).
/// 2. **Accessibility refusal** — the screen will NOT render its secret child
///    while any accessibility service is enabled; it shows a plain-language
///    explanation instead (the maximum-paranoia posture, founder call D-028 —
///    a third-party service can read the screen, so custody ceremonies refuse).
///
/// The platform PROOF of both (screenshot visibly blocked; refusal under
/// TalkBack) is the on-glass P1.4 device pass; this wires the mechanism and the
/// refusal UX, with seams so the gating logic is unit-tested without a channel.
///
/// Fail-closed: if the a11y query cannot be answered (only the host-test
/// no-channel case on a real build), the screen REFUSES rather than risk showing
/// a secret to an unverified screen — DS-7, "assume a hostile screen".
class SecretScreenGuard extends StatefulWidget {
  const SecretScreenGuard({
    super.key,
    required this.child,
    this.title,
    this.setSecure,
    this.checkAccessibility,
  });

  /// The secret screen to protect (rendered only when a11y is confirmed off).
  final Widget child;

  /// Optional context line for the refusal screen (e.g. "your recovery words").
  final String? title;

  /// Test seam: toggle FLAG_SECURE. Defaults to the ceremony channel.
  final Future<void> Function({required bool enable})? setSecure;

  /// Test seam: is any accessibility service active? Defaults to the channel.
  final Future<bool> Function()? checkAccessibility;

  static Future<void> _setSecure({required bool enable}) async {
    await VaultService.ceremony.invokeMethod<void>('setSecure', enable);
  }

  static Future<bool> _checkAccessibility() async {
    final active = await VaultService.ceremony.invokeMethod<bool>(
      'isAccessibilityActive',
    );
    return active ?? false;
  }

  @override
  State<SecretScreenGuard> createState() => _SecretScreenGuardState();
}

class _SecretScreenGuardState extends State<SecretScreenGuard>
    with WidgetsBindingObserver {
  late final Future<void> Function({required bool enable}) _setSecure =
      widget.setSecure ?? SecretScreenGuard._setSecure;
  late final Future<bool> Function() _checkA11y =
      widget.checkAccessibility ?? SecretScreenGuard._checkAccessibility;

  /// null = still checking; true = refuse (a11y on or unverifiable); false = ok.
  bool? _refuse;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _enter();
  }

  Future<void> _enter() async {
    // FLAG_SECURE the instant the route mounts (best-effort; a host test has no
    // channel — the a11y gate below still protects the secret).
    try {
      await _setSecure(enable: true);
    } on PlatformException {
      /* platform gap — gating still applies */
    } on MissingPluginException {
      /* host test — no channel */
    }
    await _recheck();
  }

  Future<void> _recheck() async {
    bool refuse;
    try {
      refuse = await _checkA11y();
    } catch (_) {
      refuse = true; // fail-closed: cannot verify → do not show the secret
    }
    if (mounted) setState(() => _refuse = refuse);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A user could enable TalkBack while we are backgrounded; re-gate on resume
    // so the refusal fires before any secret is shown again.
    if (state == AppLifecycleState.resumed) _recheck();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Clear FLAG_SECURE on the way out (flat secret-screen usage; best-effort).
    _setSecure(enable: false).catchError((Object _) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final refuse = _refuse;
    if (refuse == null) return const _GuardSplash();
    if (refuse) return _AccessibilityRefusal(onRecheck: _recheck);
    return widget.child;
  }
}

class _GuardSplash extends StatelessWidget {
  const _GuardSplash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: KvLoader()));
  }
}

class _AccessibilityRefusal extends StatelessWidget {
  const _AccessibilityRefusal({required this.onRecheck});

  final VoidCallback onRecheck;

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
                  Icons.visibility_off_outlined,
                  size: KvSpace.xxl,
                  color: KvColor.primaryMuted,
                ),
                const SizedBox(height: KvSpace.l),
                Text(
                  'Secure screen paused',
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: KvSpace.sm),
                Text(
                  'An accessibility service is active. To keep your recovery '
                  'words and passphrase private, KaspaVerse will not show them '
                  'while another app can read the screen.\n\nTurn off '
                  'accessibility services, then tap below to continue.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: KvColor.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: KvSpace.xl),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(KvSpace.touchTarget),
                    ),
                    onPressed: onRecheck,
                    child: const Text('I have turned them off'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
