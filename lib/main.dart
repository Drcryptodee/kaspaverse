import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kaspaverse/src/rust/api/vault.dart' show vaultReceiveAddress;
import 'package:kaspaverse/src/rust/api/wallet.dart' show deepScan;
import 'package:kaspaverse/src/rust/frb_generated.dart';
import 'package:kaspaverse/src/services/chain_service.dart';
import 'package:kaspaverse/src/services/messaging_service.dart';
import 'package:kaspaverse/src/services/transport_service.dart';
import 'package:kaspaverse/src/services/vault_service.dart';
import 'package:kaspaverse/src/services/wallet_service.dart';
import 'package:kaspaverse/src/ui/app_shell.dart';
import 'package:kaspaverse/src/ui/dev_transport_panel.dart';
import 'package:kaspaverse/src/ui/dev_vault_panel.dart';
import 'package:kaspaverse/src/ui/home_screen.dart';
import 'package:kaspaverse/src/ui/messages/contacts_screen.dart';
import 'package:kaspaverse/src/ui/network_sheet.dart';
import 'package:kaspaverse/src/ui/node/node_screen.dart';
import 'package:kaspaverse/src/ui/onboarding_surface.dart';
import 'package:kaspaverse/src/ui/preview/black_glass_home_preview.dart';
import 'package:kaspaverse/src/ui/receive/receive_screen.dart';
import 'package:kaspaverse/src/ui/send/send_screen.dart';
import 'package:kaspaverse/src/ui/settings_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_page_route.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/unlock_surface.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  // Vault lane (P1.2) FIRST: hands Rust the app-private dir, attaches the
  // status stream, and registers the background→lock kill switch (§0.11).
  // Ordering matters since the P1.5 re-audit: the chain lane's last-good
  // endpoint cache lives under the vault dir, so the dir must exist before
  // the monitor initialises (or the first connect skips the fast path).
  await VaultService.instance.start();
  // Single app-lifetime subscription to the bridge stream (L4); the first
  // call also kicks off the mainnet connection in Rust — preferring the
  // cached endpoint, resolver fallback.
  ChainService.instance.start();
  // Live `ciph_msg:` wire (P2.1) — same shared socket, matches only; the
  // Rust-side scan pauses/resumes with the chain service's battery posture.
  TransportService.instance.start();
  // V3 freshness watchdog (register item 10): when the link is up but the
  // wallet lane has applied nothing past the quiet threshold, the chain
  // watchdog tick pulls the fold's latest — a cheap local re-serve that heals
  // a dropped stream delivery within one tick. Wired by callback so the two
  // services stay decoupled.
  ChainService.instance.walletLastApply = () =>
      WalletService.instance.lastApply;
  ChainService.instance.onWalletQuiet = () {
    unawaited(WalletService.instance.refreshLocal());
  };
  // WalletService is NOT started here — its stream derives addresses from the
  // unlocked vault, so the home screen starts it on mount (post-unlock).
  runApp(
    KaspaVerseApp(chain: ChainService.instance, wallet: WalletService.instance),
  );
}

/// One mapping from the chain service onto the node surface, used by both
/// paths into the network sheet. Written once so the two can never disagree
/// about which notifiers the picker is reading (C7).
NodeScope _nodeScope(ChainService chain) => NodeScope(
  connected: chain.connected,
  activeEndpoint: chain.endpoint,
  virtualDaaScore: chain.virtualDaaScore,
  pinnedNode: chain.pinnedNode,
  pinDropped: chain.pinDropped,
  setPinnedNode: chain.setPinnedNode,
  lastUpdate: chain.lastUpdate,
  searching: chain.searching,
  osOffline: chain.osOffline,
  reconnecting: chain.reconnecting,
  refreshConfig: () => chain.refreshNodeConfig(),
);

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
        home: HomeScreen(
          // V5 service scopes: the SAME service notifiers as ever, grouped —
          // inner identities stay stable for the life of the state (the V4
          // seam law; scope objects themselves may rebuild freely).
          chain: ChainScope(
            connected: chain.connected,
            endpoint: chain.endpoint,
            virtualDaaScore: chain.virtualDaaScore,
            error: chain.error,
            lastUpdate: chain.lastUpdate,
            reconnecting: chain.reconnecting,
            onReconnect: chain.reconnect,
            searching: chain.searching,
            osOffline: chain.osOffline,
            disconnectedAt: chain.disconnectedAt,
            node: _nodeScope(chain),
          ),
          wallet: WalletScope(
            mature: wallet.mature,
            pending: wallet.pending,
            activity: wallet.activity,
            syncing: wallet.syncing,
            utxoIndexMissing: wallet.utxoIndexMissing,
            outgoing: wallet.outgoing,
            discoveryIncomplete: wallet.discoveryIncomplete,
            onRefreshActivity: wallet.refreshNow,
          ),
          onReady: () {
            wallet.start();
            // P2.3 transport hub: needs the unlocked vault (this screen only
            // mounts unlocked) and rebuilds after a re-unlock. Fire-and-forget;
            // the service surfaces its own errors.
            MessagingService.instance.start();
          },
          receiveRoute: (_) => ReceiveScreen(fetch: vaultReceiveAddress),
          sendRoute: (_) => SendScreen(
            mature: wallet.mature,
            prepare: wallet.prepareSend,
            commit: wallet.commitSend,
            abandon: wallet.abandonSend,
            minimumSendable: wallet.minimumSendable,
            prepareSweep: wallet.prepareSweep,
          ),
          messagesRoute: (_) => const ContactsScreen(),
          // Track 2: the app's settings surface, and the only door to biometric
          // enrolment outside the create flow. Every seam is wired here so the
          // screen itself imports no service (the V5 scope law).
          settingsRoute: (_) => SettingsScreen(
            security: SecurityScope(
              biometricStatus: VaultService.instance.biometricStatus,
              pathAState: VaultService.instance.pathAState,
              enroll: VaultService.instance.enrollBiometric,
              clearEnrollment: VaultService.instance.clearBiometric,
              lockGraceSecs: VaultService.instance.lockGraceSecs,
              setLockGraceSecs: VaultService.instance.setLockGraceSecs,
            ),
            wallet: WalletSettingsScope(
              receiveAddress: vaultReceiveAddress,
              deepScan: deepScan,
              receiveRoute: (_) => ReceiveScreen(fetch: vaultReceiveAddress),
              consolidate: wallet.prepareConsolidate,
              commitSend: wallet.commitSend,
              abandonSend: wallet.abandonSend,
            ),
            about: AboutScope(packageInfo: VaultService.instance.packageInfo),
            // The SAME sheet the home beacon opens, over the same notifiers —
            // never a second rendering of one link state (C7).
            networkSheet: () => NetworkSheet(
              connected: chain.connected,
              endpoint: chain.endpoint,
              virtualDaaScore: chain.virtualDaaScore,
              error: chain.error,
              lastUpdate: chain.lastUpdate,
              clock: DateTime.now,
              reconnecting: chain.reconnecting,
              onReconnect: chain.reconnect,
              searching: chain.searching,
              osOffline: chain.osOffline,
              disconnectedAt: chain.disconnectedAt,
              node: _nodeScope(chain),
            ),
          ),
          floatingActionButton: kDebugMode ? const _DevFabs() : null,
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          onPressed: () => Navigator.of(
            context,
          ).push(KvPageRoute<void>(builder: (_) => const DevVaultPanel())),
          icon: const Icon(Icons.build_outlined),
          label: const Text('Dev vault panel'),
        ),
        // Reachable from the gate on purpose: the feel test renders no real
        // money and reads no vault state, so it can be looked at without
        // unlocking anything.
        TextButton.icon(
          onPressed: () => Navigator.of(context).push(
            KvPageRoute<void>(builder: (_) => const BlackGlassHomePreview()),
          ),
          icon: const Icon(Icons.contrast_outlined),
          label: const Text('Black Glass preview'),
        ),
      ],
    );
  }
}

/// The debug FAB stack on home: vault panel (P1.2) + transport panel (P2.1)
/// + the Black Glass feel test (Pre-P3.1 UX-0 — a prototype, not the build).
/// Distinct heroTags — two FABs on one route must never share the default tag.
class _DevFabs extends StatelessWidget {
  const _DevFabs();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton.small(
          heroTag: 'dev-blackglass',
          tooltip: 'DEV Black Glass home preview',
          onPressed: () => Navigator.of(context).push(
            KvPageRoute<void>(builder: (_) => const BlackGlassHomePreview()),
          ),
          child: const Icon(Icons.contrast_outlined),
        ),
        const SizedBox(height: 8),
        FloatingActionButton.small(
          heroTag: 'dev-transport',
          tooltip: 'DEV transport panel',
          onPressed: () => Navigator.of(
            context,
          ).push(KvPageRoute<void>(builder: (_) => const DevTransportPanel())),
          child: const Icon(Icons.satellite_alt_outlined),
        ),
        const SizedBox(height: 8),
        FloatingActionButton.small(
          heroTag: 'dev-vault',
          tooltip: 'DEV vault panel',
          onPressed: () => Navigator.of(
            context,
          ).push(KvPageRoute<void>(builder: (_) => const DevVaultPanel())),
          child: const Icon(Icons.build_outlined),
        ),
      ],
    );
  }
}
