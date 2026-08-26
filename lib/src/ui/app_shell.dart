import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../rust/api/vault.dart' as vault_api;
import 'theme/tokens.dart';
import 'widgets/kv_loader.dart';

/// The top-level navigation shell. Routes purely on the vault status stream
/// (`VaultService.status`):
///
/// `null` (initialising) → `!exists` (onboarding) → `!unlocked` (locked /
/// unlock surface) → home.
///
/// It never shows home optimistically, so the first `unlocked=false` emit on
/// attach cannot flash over an in-flight unlock (P1.3 watch-out). The four
/// destination widgets are injected so the routing is unit-testable without
/// any of them.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.status,
    required this.initializing,
    required this.onboarding,
    required this.locked,
    required this.home,
  });

  final ValueListenable<vault_api.VaultStatus?> status;
  final Widget initializing;
  final Widget onboarding;
  final Widget locked;
  final Widget home;

  /// Stable key per shell state — drives the cross-fade and is the testable
  /// name of the routing decision.
  static String routeKey(vault_api.VaultStatus? s) {
    if (s == null) return 'init';
    if (!s.exists) return 'onboarding';
    if (!s.unlocked) return 'locked';
    return 'home';
  }

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  String _lastKey = AppShell.routeKey(null);

  @override
  void initState() {
    super.initState();
    _lastKey = AppShell.routeKey(widget.status.value);
    widget.status.addListener(_onStatusChanged);
  }

  @override
  void dispose() {
    widget.status.removeListener(_onStatusChanged);
    super.dispose();
  }

  /// When the vault leaves `home` (e.g. a background-lock — §0.11), dismiss any
  /// route pushed over the shell (the Send screen, the Receive/confirm sheets)
  /// so the locked surface is actually shown, never hidden behind a stale
  /// money screen. The vault already refuses operations while locked; this makes
  /// the UI tell the truth (the founder's device find, 2026-06-15).
  void _onStatusChanged() {
    final key = AppShell.routeKey(widget.status.value);
    if (key != 'home' && _lastKey == 'home') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.maybeOf(context)?.popUntil((route) => route.isFirst);
        }
      });
    }
    _lastKey = key;
  }

  Widget _childFor(String key) => switch (key) {
    'init' => widget.initializing,
    'onboarding' => widget.onboarding,
    'locked' => widget.locked,
    _ => widget.home,
  };

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<vault_api.VaultStatus?>(
      valueListenable: widget.status,
      builder: (context, s, _) {
        final key = AppShell.routeKey(s);
        // Vault-calm cross-fade between states — decelerate, no slide (BG-9/§6).
        return AnimatedSwitcher(
          duration: KvMotion.normal,
          switchInCurve: KvMotion.out,
          switchOutCurve: KvMotion.out,
          child: KeyedSubtree(key: ValueKey(key), child: _childFor(key)),
        );
      },
    );
  }
}

/// The initialising splash — shown only while the vault lane attaches its
/// stream (status `null`). Vault-calm: a quiet wordmark, no celebration. There
/// is no cached data here, so a thin progress mark is honest (not a spinner
/// over known structure — §6/§13).
class KvSplash extends StatelessWidget {
  const KvSplash({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('KaspaVerse', style: theme.textTheme.headlineSmall),
            const SizedBox(height: KvSpace.l),
            const KvLoader(),
          ],
        ),
      ),
    );
  }
}
