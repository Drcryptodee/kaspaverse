import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kaspaverse/src/rust/api/vault.dart' show vaultReceiveAddress;
import 'package:kaspaverse/src/rust/frb_generated.dart';
import 'package:kaspaverse/src/services/chain_service.dart';
import 'package:kaspaverse/src/services/vault_service.dart';
import 'package:kaspaverse/src/services/wallet_service.dart';
import 'package:kaspaverse/src/ui/app_shell.dart';
import 'package:kaspaverse/src/ui/dev_vault_panel.dart';
import 'package:kaspaverse/src/ui/hello_dag_screen.dart';
import 'package:kaspaverse/src/ui/onboarding_surface.dart';
import 'package:kaspaverse/src/ui/send/send_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/unlock_surface.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  // Single app-lifetime subscription to the bridge stream (L4); the first
  // call also kicks off the mainnet connection in Rust.
  ChainService.instance.start();
  // Vault lane (P1.2): hands Rust the app-private dir, attaches the status
  // stream, and registers the background→lock kill switch (§0.11).
  await VaultService.instance.start();
  // WalletService is NOT started here — its stream derives addresses from the
  // unlocked vault, so the home screen starts it on mount (post-unlock).
  runApp(
    KaspaVerseApp(chain: ChainService.instance, wallet: WalletService.instance),
  );
}

/// The app: Bioluminescent Vault theme (tokens, P1.3) wrapping the navigation
/// shell. The D-027 freestyle seed-colour drift dies here — the theme is built
/// entirely from `kv_theme.dart` / `tokens.dart`.
class KaspaVerseApp extends StatelessWidget {
  const KaspaVerseApp({super.key, required this.chain, required this.wallet});

  final ChainService chain;
  final WalletService wallet;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KaspaVerse',
      debugShowCheckedModeBanner: false,
      theme: kvDarkTheme(),
      home: AppShell(
        status: VaultService.instance.status,
        initializing: const KvSplash(),
        // P1.4: onboarding (create/restore) + the passphrase unlock screen the
        // locked surface hands off to. The create ceremony's native word reveal
        // is the on-device build (D-037); debug builds still reach the caged
        // DevVaultPanel from these surfaces (D5).
        onboarding: const OnboardingSurface(
          debugFooter: kDebugMode ? _DevPanelLink() : null,
        ),
        locked: const UnlockSurface(
          debugFooter: kDebugMode ? _DevPanelLink() : null,
        ),
        home: HelloDagScreen(
          connected: chain.connected,
          endpoint: chain.endpoint,
          virtualDaaScore: chain.virtualDaaScore,
          error: chain.error,
          lastUpdate: chain.lastUpdate,
          mature: wallet.mature,
          pending: wallet.pending,
          outgoing: wallet.outgoing,
          activity: wallet.activity,
          syncing: wallet.syncing,
          utxoIndexMissing: wallet.utxoIndexMissing,
          onReady: wallet.start,
          receiveAddress: vaultReceiveAddress,
          sendRoute: (_) => SendScreen(
            mature: wallet.mature,
            prepare: wallet.prepareSend,
            commit: wallet.commitSend,
            abandon: wallet.abandonSend,
          ),
          floatingActionButton: kDebugMode ? const _DevPanelFab() : null,
        ),
      ),
    );
  }
}

/// Debug-only launcher for the caged DevVaultPanel (D5) — the P1.2 throwaway
/// driver, kept for P1.4 dev + the passphrase fallback. Never built in release
/// (`kDebugMode` guards both call sites), so the panel is unreachable there.
class _DevPanelLink extends StatelessWidget {
  const _DevPanelLink();

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const DevVaultPanel())),
      icon: const Icon(Icons.build_outlined),
      label: const Text('Dev vault panel'),
    );
  }
}

class _DevPanelFab extends StatelessWidget {
  const _DevPanelFab();

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      tooltip: 'DEV vault panel',
      onPressed: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const DevVaultPanel())),
      child: const Icon(Icons.build_outlined),
    );
  }
}
