import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kaspaverse/src/rust/api/send.dart' show sendFeePreview;
import 'package:kaspaverse/src/rust/api/transport.dart' show txAcceptanceStatus;
import 'package:kaspaverse/src/rust/api/vault.dart' show vaultReceiveAddress;
import 'package:kaspaverse/src/rust/api/wallet.dart' show deepScan;
import 'package:kaspaverse/src/rust/frb_generated.dart';
import 'package:kaspaverse/src/services/chain_service.dart';
import 'package:kaspaverse/src/services/contacts_service.dart';
import 'package:kaspaverse/src/services/messaging_service.dart';
import 'package:kaspaverse/src/services/rate_service.dart';
import 'package:kaspaverse/src/services/transport_service.dart';
import 'package:kaspaverse/src/services/vault_service.dart';
import 'package:kaspaverse/src/services/wallet_service.dart';
import 'package:kaspaverse/src/ui/app_shell.dart';
import 'package:kaspaverse/src/ui/dev_transport_panel.dart';
import 'package:kaspaverse/src/ui/dev_vault_panel.dart';
import 'package:kaspaverse/src/ui/home_screen.dart';
import 'package:kaspaverse/src/ui/messages/contacts_screen.dart';
import 'package:kaspaverse/src/ui/node/node_screen.dart';
import 'package:kaspaverse/src/ui/onboarding_surface.dart';
import 'package:kaspaverse/src/ui/preview/black_glass_home_preview.dart';
import 'package:kaspaverse/src/rust/api/dag.dart' show dagStatus;
import 'package:kaspaverse/src/rust/api/prefs.dart'
    show prefsExplorerConfig, prefsExplorerTxUrl, prefsSetExplorerConfig;
import 'package:kaspaverse/src/ui/receive/receive_screen.dart';
import 'package:kaspaverse/src/ui/send/send_screen.dart';
import 'package:kaspaverse/src/ui/settings_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_page_route.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/widgets/kv_coming_soon.dart';
import 'package:kaspaverse/src/ui/widgets/kv_contact.dart' show ContactsScope;
import 'package:kaspaverse/src/ui/widgets/kv_drawer.dart';
import 'package:kaspaverse/src/ui/widgets/kv_glyph.dart';
import 'package:kaspaverse/src/ui/tx/tx_detail_screen.dart';
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
  onReconnect: chain.reconnect,
  refreshConfig: () => chain.refreshNodeConfig(),
  // The scan line the retired network sheet uniquely rendered, carried across
  // (UX-3). `dagStatus` is a poll that takes no I/O in its steady state.
  blockAgeSecs: () async => (await dagStatus()).lastBlockAgeSecs?.toInt(),
);

/// The explorer choice, mapped off the bridge DTO. Dart moves strings; Rust
/// validates them and builds every URL (INV-9's reasoning: a second, weaker
/// guard on this side is the thing to avoid).
ExplorerScope _explorerScope() => ExplorerScope(
  read: () async {
    final config = await prefsExplorerConfig();
    return ExplorerChoice(
      txTemplate: config.txTemplate,
      addressTemplate: config.addressTemplate,
      defaults: [
        for (final d in config.defaults)
          ExplorerOption(
            name: d.name,
            txTemplate: d.txTemplate,
            addressTemplate: d.addressTemplate,
          ),
      ],
    );
  },
  write: (tx, address) =>
      prefsSetExplorerConfig(txTemplate: tx, addressTemplate: address),
);

/// The price source, over the ONE service that owns the fetch.
RateScope _rateScope(RateService rate) => RateScope(
  enabled: rate.enabled,
  endpoint: rate.endpoint,
  defaultEndpoint: rate.defaultEndpoint,
  quote: rate.quote,
  error: rate.error,
  setConfig: rate.setConfig,
  load: rate.loadConfig,
);

/// **The** node surface, built once and reached from two doors: the money
/// plate's network chip and the Settings row. One builder is what keeps them
/// from becoming two screens answering the same question — the C7 defect the
/// retired network sheet actually had.
WidgetBuilder _nodeRoute(ChainService chain) =>
    (_) => NodeScreen(
      scope: _nodeScope(chain),
      explorer: _explorerScope(),
      rate: _rateScope(RateService.instance),
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
      // **The window is derived once, here, and provided to the whole tree**
      // (BG-33, §3a). `builder` rather than wrapping `home:` on purpose: it
      // sits ABOVE the Navigator, so a pushed route — Send, Receive, the
      // ceremony, Settings, the node surface — reads the same class the money
      // screen did. Below `home:` every one of them would find no provider and
      // lay a tablet out as a phone.
      builder: (context, child) => KvWindow(child: child!),
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
        home: _MoneyShell(chain: chain, wallet: wallet),
      ),
    );
  }
}

/// **The** settings surface, built once so the drawer and any later door
/// open the same screen rather than two renderings of one truth (C7).
WidgetBuilder _settingsRoute(ChainService chain, WalletService wallet) =>
    (_) => SettingsScreen(
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
        receiveRoute: (_) => ReceiveScreen(
          fetch: vaultReceiveAddress,
          share: VaultService.instance.shareText,
        ),
        consolidate: wallet.prepareConsolidate,
        commitSend: wallet.commitSend,
        abandonSend: wallet.abandonSend,
      ),
      about: AboutScope(packageInfo: VaultService.instance.packageInfo),
      // The SAME screen the money plate's chip opens, from the same
      // builder — never a second rendering of one truth (C7). The
      // summary beside the row reports the CHOICE (whose node, fiat on
      // or off), never the link's health, which changes without the
      // user and belongs to the screen behind it.
      network: NetworkSettingsScope(
        route: _nodeRoute(chain),
        pinnedNode: chain.pinnedNode,
        rateEnabled: RateService.instance.enabled,
      ),
    );

/// **The money screen inside the app's navigation** (§4, §3a.2).
///
/// `KvNav` is what makes the drawer one widget in three postures: it pushes
/// the page in `compact`, stands as an 80 dp rail in `medium` (and in any
/// window too short to seat its rows), and stands as the 296 dp panel in
/// `expanded`+. It wraps **home only**, which is what makes BG-13 true by
/// construction: the shell discards this whole subtree the instant the vault
/// locks, so the drawer has nowhere to survive.
///
/// Messages and Settings were `HomeScreen` parameters until UX-R1, back when
/// a top rail was the only place a destination could live (D-190 withdrew the
/// nav panel). They are destinations now, and the money screen offers neither
/// — two doors to one room is how they start disagreeing.
class _MoneyShell extends StatefulWidget {
  const _MoneyShell({required this.chain, required this.wallet});

  final ChainService chain;
  final WalletService wallet;

  @override
  State<_MoneyShell> createState() => _MoneyShellState();
}

class _MoneyShellState extends State<_MoneyShell> {
  /// The wallet's own receive address, for the drawer's identity header
  /// (D-260). Resolved once per mount; null until the vault answers, and the
  /// header renders the name alone rather than a placeholder.
  late final Future<String> _address = vaultReceiveAddress();

  /// Built once and held, so a drawer swipe does not rebuild the money
  /// screen's whole subtree — and, more importantly, does not tear down the
  /// derived notifiers it mounted (the V4 seam law).
  late final Widget _home = HomeScreen(
    // V5 service scopes: the SAME service notifiers as ever, grouped —
    // inner identities stay stable for the life of the state (the V4
    // seam law; scope objects themselves may rebuild freely).
    chain: ChainScope(
      connected: widget.chain.connected,
      virtualDaaScore: widget.chain.virtualDaaScore,
      error: widget.chain.error,
      lastUpdate: widget.chain.lastUpdate,
      reconnecting: widget.chain.reconnecting,
      searching: widget.chain.searching,
      osOffline: widget.chain.osOffline,
      disconnectedAt: widget.chain.disconnectedAt,
    ),
    wallet: WalletScope(
      mature: widget.wallet.mature,
      pending: widget.wallet.pending,
      activity: widget.wallet.activity,
      syncing: widget.wallet.syncing,
      utxoIndexMissing: widget.wallet.utxoIndexMissing,
      outgoing: widget.wallet.outgoing,
      discoveryIncomplete: widget.wallet.discoveryIncomplete,
      onRefreshActivity: widget.wallet.refreshNow,
    ),
    onReady: () {
      widget.wallet.start();
      // P2.3 transport hub: needs the unlocked vault (this screen only
      // mounts unlocked) and rebuilds after a re-unlock. Fire-and-forget;
      // the service surfaces its own errors.
      MessagingService.instance.start();
    },
    receiveRoute: (_) => ReceiveScreen(
      fetch: vaultReceiveAddress,
      share: VaultService.instance.shareText,
    ),
    sendRoute: (_, balanceStale) => SendScreen(
      mature: widget.wallet.mature,
      balanceStale: balanceStale,
      // The tracker's live depth for the txid the ceremony just made —
      // node-read, polled once a second while the receipt is up.
      acceptanceStatus: (txid) => txAcceptanceStatus(txid: txid),
      // The Generator's own fee for what is typed — signerless,
      // stash-free, priced over the live coins on every pause.
      feePreview: (destination, amount) =>
          sendFeePreview(destination: destination, amountSompi: amount),
      prepare: widget.wallet.prepareSend,
      commit: widget.wallet.commitSend,
      abandon: widget.wallet.abandonSend,
      minimumSendable: widget.wallet.minimumSendable,
      prepareSweep: widget.wallet.prepareSweep,
      // The receipt's explorer exit — the same widget the transaction
      // detail uses, with the same disclosure (D-223's placeholder is
      // now the real thing).
      explorerUrl: (id) => prefsExplorerTxUrl(txid: id),
      openUrl: VaultService.instance.openUrl,
      // The `≈` price under the figure being typed and under the
      // ceremony's restatement of it (founder, 2026-09-04). Read-only
      // here by construction: the place a price is switched off is the
      // place it is chosen (D-193).
      fiat: FiatScope(
        enabled: RateService.instance.enabled,
        quote: RateService.instance.quote,
        attach: RateService.instance.attach,
        detach: RateService.instance.detach,
      ),
      // The address book — names for addresses, device-local, read on
      // mount and re-read after every save.
      contacts: ContactsScope(
        contacts: ContactsService.instance.contacts,
        refresh: ContactsService.instance.refresh,
        save: ContactsService.instance.save,
      ),
    ),
    // A tapped ledger row opens the record at full size, with the burial
    // gauge the feed has no room for. The explorer link is RESOLVED in
    // Rust (validated template, identifier in the path, https only) and
    // opened by the platform channel the app already owns — no plugin,
    // and no URL built on this side (UX-5).
    detailRoute: (_, txid, stale) => TxDetailScreen(
      txid: txid,
      activity: widget.wallet.activity,
      virtualDaaScore: widget.chain.virtualDaaScore,
      stale: stale,
      explorerUrl: (id) => prefsExplorerTxUrl(txid: id),
      openUrl: VaultService.instance.openUrl,
    ),
    nodeRoute: _nodeRoute(widget.chain),
    // Read-only on this surface by construction: the plate shows a
    // price, and the place a price is chosen is the place it can be
    // switched off (D-193).
    fiat: FiatScope(
      enabled: RateService.instance.enabled,
      quote: RateService.instance.quote,
      attach: RateService.instance.attach,
      detach: RateService.instance.detach,
    ),
    floatingActionButton: kDebugMode ? const _DevFabs() : null,
  );

  void _push(WidgetBuilder builder) =>
      Navigator.of(context).push(KvPageRoute<void>(builder: builder));

  @override
  Widget build(BuildContext context) {
    return KvNav(
      selected: 0,
      // **Who you are in, not what the app is called** (D-260). The seat
      // becomes the wallet switcher when the app holds more than one account
      // on a phone; it takes no tap until it does (§8).
      header: FutureBuilder<String>(
        future: _address,
        builder: (context, snap) =>
            KvWalletIdentity(name: 'Main wallet', address: snap.data),
      ),
      // The render's nine, in the render's two groups (`S2 · Drawer`, D-261).
      // Every row is live: an unbuilt destination opens its own seat, honestly
      // empty, rather than dying under the thumb (§8).
      destinations: [
        KvDestination(mark: KvGlyph.money, label: 'Wallet', onTap: () {}),
        // No count: there is no unread source yet, and a count is never faked.
        KvDestination(
          mark: KvGlyph.chat,
          label: 'Messages',
          onTap: () => _push((_) => const ContactsScreen()),
        ),
        // The arcade waits on P4's covenant engine, swaps on an engine that
        // does not exist, and identity on a scope nobody has named yet
        // (register §4, D-1, D-256). Each says so where it will live.
        KvDestination(
          mark: KvGlyph.games,
          label: 'Games',
          onTap: () => _push(
            (_) => const KvComingSoonPage(
              mark: KvGlyph.games,
              name: 'Games',
              sentence: 'Not built yet. The arcade will live here.',
            ),
          ),
        ),
        KvDestination(
          mark: KvGlyph.finance,
          label: 'Finance',
          onTap: () => _push(
            (_) => const KvComingSoonPage(
              mark: KvGlyph.finance,
              name: 'Finance',
              sentence: 'Not built yet. Swaps and offers will live here.',
            ),
          ),
        ),
        KvDestination(
          mark: KvGlyph.identity,
          label: 'Identity',
          onTap: () => _push(
            (_) => const KvComingSoonPage(
              mark: KvGlyph.identity,
              name: 'Identity',
              sentence: 'Not built yet. Who you are to others will live here.',
            ),
          ),
        ),
      ],
      secondary: [
        KvDestination(
          mark: KvGlyph.settings,
          label: 'Settings',
          onTap: () => _push(_settingsRoute(widget.chain, widget.wallet)),
        ),
        // The lamp is the chain's own `connected` — the reading the plate's
        // lamp is derived from, so the two cannot disagree.
        KvDestination(
          mark: KvGlyph.network,
          label: 'Network',
          live: widget.chain.connected,
          onTap: () => _push(_nodeRoute(widget.chain)),
        ),
        // Security's rows live inside Settings until `T2 · Security` is built
        // as its own surface; the row opens where those rows are today.
        KvDestination(
          mark: KvGlyph.shield,
          label: 'Security',
          onTap: () => _push(_settingsRoute(widget.chain, widget.wallet)),
        ),
        KvDestination(
          mark: KvGlyph.help,
          label: 'Help',
          onTap: () => _push(
            (_) => const KvComingSoonPage(
              mark: KvGlyph.help,
              name: 'Help',
              sentence: 'Not built yet. Answers will live here.',
            ),
          ),
        ),
      ],
      footer: [
        // **Lock is a discard, not a pause** (BG-13): 0 ms, and the shell
        // routes to the locked surface on the vault's own status stream, so
        // nothing here has to navigate.
        KvDestination(
          mark: KvGlyph.lock,
          label: 'Lock',
          onTap: VaultService.instance.lockNow,
        ),
      ],
      child: _home,
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
