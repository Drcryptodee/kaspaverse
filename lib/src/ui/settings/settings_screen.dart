import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../rust/api/wallet.dart' show DeepScanReport;
import '../biometric_copy.dart';
import '../theme/kv_page_route.dart';
import '../theme/kv_window.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_coming_soon.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_rows.dart';
import '../widgets/kv_two_pane.dart';
import 'about_screen.dart';
import 'security_screen.dart';
import 'settings_scopes.dart';
import 'wallet_screen.dart';

/// **`T1 · Settings` — the root of the settings group** (playbook §3.5,
/// D-266).
///
/// Two row containers under two bare caps labels; every row is a door with a
/// **40 dp disc, its own name, and its current state as a fragment beneath**;
/// `Lock now` raised in the thumb arc; the one red text last, outside it.
///
/// **What changed at UX-R4, and why it is not a re-skin.** Until this sitting
/// Settings was one screen holding four sections of every setting the app has,
/// with no glyphs and no sub-screens — a registry that grew by adding rows.
/// `T1` is a different information architecture: the root names *domains* and
/// each domain owns a screen. That is the render's own composition, and it is
/// what lets each row's sub-line be a state rather than a description.
///
/// **The screen owes a one-view fit** (playbook §19.1: a setting you must
/// scroll to hunt is a setting you will not change), and `settings_group_test`
/// proves it at 393 × 800 rather than claiming it from a frame.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.security,
    required this.wallet,
    required this.about,
    this.network,
    this.removeWallet,
  });

  final SecurityScope security;
  final WalletSettingsScope wallet;
  final AboutScope about;

  /// Absent ⇒ the Network row does not render. A door with nothing behind it
  /// is worse than no door: it teaches that a control here might do nothing.
  final NetworkSettingsScope? network;

  /// The one red text. Null ⇒ it is not drawn — **not** drawn and inert.
  final Future<void> Function()? removeWallet;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  /// Every sub-line on this screen, each read from the seam that owns it.
  final ValueNotifier<String?> _security = ValueNotifier(null);
  final ValueNotifier<String?> _wallet = ValueNotifier(null);
  final ValueNotifier<String?> _about = ValueNotifier(null);

  /// The Network row's own state, kept apart because it is the one sub-line
  /// that is **composed** rather than written: a lamp, then the endpoint in
  /// mono (`T1`, measured).
  final ValueNotifier<String?> _node = ValueNotifier(null);

  /// The last address count the deep scan reported. Null until one has run
  /// in this session — the wallet's address window is Rust's, and this screen
  /// does not have a seam that enumerates it (see [WalletScreen]).
  DeepScanReport? _scan;

  bool _locking = false;

  @override
  void initState() {
    super.initState();
    widget.security.lockGraceSecs.addListener(_readSecurity);
    final network = widget.network;
    if (network != null) {
      network.pinnedNode.addListener(_readNetwork);
      network.rateEnabled?.addListener(_readNetwork);
    }
    WidgetsBinding.instance.addObserver(this);
    _readSecurity();
    _readNetwork();
    _readWallet();
    _readAbout();
  }

  /// Re-probe when the user comes back.
  ///
  /// The `none_enrolled` copy sends them to Android Settings and says "then
  /// turn this on". With any lock grace above zero the vault does not lock,
  /// this route is never popped and the `State` survives the background — so
  /// the one path the copy prescribes landed on a stale verdict. The
  /// reachability defect this screen exists to end, one level down.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _readSecurity();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.security.lockGraceSecs.removeListener(_readSecurity);
    final network = widget.network;
    if (network != null) {
      network.pinnedNode.removeListener(_readNetwork);
      network.rateEnabled?.removeListener(_readNetwork);
    }
    _security.dispose();
    _wallet.dispose();
    _about.dispose();
    _node.dispose();
    super.dispose();
  }

  // ── the sub-lines, each from its own seam ────────────────────────────────

  /// `Fingerprint on · locks after 30 s` (`T1`) — both halves are Security's,
  /// and both are things the user set.
  Future<void> _readSecurity() async {
    // **Each probe fails on its own.** One `try` around both meant a first
    // success and a second throw left `state` on its `pathANone` seed, and
    // the row printed a confident `Fingerprint off` over a wallet where it
    // was on (BG-8, L170). `unknown` is what an unread state is called.
    String status;
    try {
      status = await widget.security.biometricStatus();
    } catch (_) {
      status = biometricUnknown;
    }
    var state = pathANone;
    var stateRead = true;
    try {
      state = await widget.security.pathAState();
    } catch (_) {
      stateRead = false;
    }
    if (!mounted) return;
    final unlock = switch (status) {
      _ when biometricStateIsUnknown(status) => 'Fingerprint unknown',
      _ when biometricStateIsDegraded(status) => 'Fingerprint needs attention',
      // The vault answered about the phone and not about us: say so rather
      // than resolving the half-read into `off`.
      _ when !stateRead => 'Fingerprint unknown',
      _ when state == pathAInvalidated => 'Fingerprint needs setting up again',
      _ when state == pathAReady => 'Fingerprint on',
      _ => 'Fingerprint off',
    };
    _security.value =
        '$unlock · ${graceFragment(widget.security.lockGraceSecs.value)}';
  }

  /// `Main · 3 addresses` in the render. This build has no seam that
  /// enumerates the wallet's addresses (see [WalletScreen]'s own note), so the
  /// fragment says what the wallet screen actually holds — never a count it
  /// cannot count.
  void _readWallet() {
    final scan = _scan;
    _wallet.value = scan == null
        ? (widget.wallet.canMerge
              ? 'Scan for more addresses · merge coins'
              : 'Scan for more addresses')
        : 'Watching ${scan.receiveSeen + scan.changeSeen} addresses';
  }

  void _readNetwork() {
    final network = widget.network;
    if (network == null) return;
    final node = network.pinnedNode.value == null
        ? 'Public community nodes'
        : 'Your own node';
    // Null twice over — no seam wired, or a posture not yet read — and both
    // say nothing about a price rather than guessing at one.
    final rate = network.rateEnabled?.value;
    _node.value = rate == null
        ? node
        : '$node · fiat value ${rate ? 'on' : 'off'}';
  }

  Future<void> _readAbout() async {
    try {
      final info = await widget.about.packageInfo();
      if (!mounted) return;
      final version = info['version'];
      // Short enough to stand whole in the row at 393 dp — the frame, not the
      // string, decides how long a fragment may be (L169).
      _about.value = version == null
          ? 'This build'
          : 'KaspaVerse $version · signature, roadmap';
    } catch (_) {
      // BG-8: an unknown datum is named, never invented.
      if (mounted) _about.value = 'Version unavailable on this build';
    }
  }

  // ── acts ─────────────────────────────────────────────────────────────────

  Future<void> _lockNow() async {
    final lock = widget.security.lockNow;
    if (lock == null || _locking) return;
    KvHaptic.destructiveArmed();
    setState(() => _locking = true);
    try {
      await lock();
    } finally {
      if (mounted) setState(() => _locking = false);
    }
  }

  void _open(WidgetBuilder builder) {
    KvHaptic.selection();
    Navigator.of(context).push(KvPageRoute<void>(builder: builder));
  }

  /// A domain the product has named and the build has not reached. The house's
  /// designed placeholder, never a `TODO` and never an inert row (§4, D-247).
  void _openComingSoon(KvGlyph mark, String name, String sentence) => _open(
    (_) => KvComingSoonPage(mark: mark, name: name, sentence: sentence),
  );

  @override
  Widget build(BuildContext context) {
    final network = widget.network;
    final remove = widget.removeWallet;
    return Scaffold(
      backgroundColor: KvColor.abyss,
      // The system inset and nothing more (D-275): `top_inset_test` fails any
      // screen under `lib/src/ui` that reserves the retired token.
      body: SafeArea(
        child: Column(
          children: [
            KvTopBar(
              title: 'Settings',
              page: true,
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: KvColumn(
                gutter: false,
                child: ListView(
                  // The compact register's list edges (playbook §19.4 step 2):
                  // 4 above, 24 below. Every gap between the sections is
                  // `KvSectionHeader`'s own air and nothing else — three
                  // stacked gap constants per label is what pushed the Network
                  // surface past one view.
                  padding: EdgeInsets.fromLTRB(
                    KvWindow.of(context).gutter,
                    KvSpace.xs,
                    KvWindow.of(context).gutter,
                    KvSpace.m,
                  ),
                  children: [
                    const KvSectionHeader('Wallet'),
                    KvRowContainer(
                      children: [
                        _door(
                          // The one tinted disc on the screen: security is
                          // *ours* in the way the wallet's own address is
                          // (§4). Every other row takes the neutral `chip`.
                          disc: const KvRowDisc.ours(mark: KvGlyph.shield),
                          title: 'Security',
                          state: _security,
                          onTap: () => _open(
                            (_) => SecurityScreen(scope: widget.security),
                          ),
                        ),
                        _door(
                          disc: const KvRowDisc.neutral(mark: KvGlyph.money),
                          title: 'Wallet',
                          state: _wallet,
                          onTap: () => _open(
                            (_) => WalletScreen(
                              scope: widget.wallet,
                              onScanned: (report) {
                                _scan = report;
                                _readWallet();
                              },
                            ),
                          ),
                        ),
                        if (network != null)
                          _door(
                            disc: const KvRowDisc.neutral(
                              mark: KvGlyph.network,
                            ),
                            title: 'Network',
                            state: _node,
                            onTap: () => _open(network.route),
                          ),
                      ],
                    ),
                    const KvSectionHeader('App'),
                    KvRowContainer(
                      children: [
                        // **Four of these five doors open the house's Coming
                        // soon page, and their sub-lines say so.** The render
                        // draws a live state under each; three of these
                        // domains have no seam in this build and one — the
                        // Kasia message settings — has a sheet on the thread
                        // screen rather than a settings surface. A sub-line
                        // that reads `Kasia · backups on · last 2 h ago` over
                        // nothing is the one thing a trust screen may not do
                        // (BG-11). Said in the sitting, not only here.
                        _door(
                          disc: const KvRowDisc.neutral(mark: KvGlyph.chat),
                          title: 'Messages',
                          sub: 'Kasia threads · settings not built yet',
                          onTap: () => _openComingSoon(
                            KvGlyph.chat,
                            'Messages',
                            'Kasia handshakes and threads work today, from '
                                'the drawer. Their settings — backups, who may '
                                'reach you — will live here.',
                          ),
                        ),
                        _door(
                          disc: const KvRowDisc.neutral(mark: KvGlyph.palette),
                          title: 'Appearance',
                          sub: 'Deep · one theme so far',
                          onTap: () => _openComingSoon(
                            KvGlyph.palette,
                            'Appearance',
                            'The wallet draws one theme. Hiding balances and '
                                'choosing a lighter ground will live here.',
                          ),
                        ),
                        _door(
                          disc: const KvRowDisc.neutral(mark: KvGlyph.bell),
                          title: 'Notifications',
                          sub: 'Off — nothing is sent from this phone yet',
                          onTap: () => _openComingSoon(
                            KvGlyph.bell,
                            'Notifications',
                            'Nothing notifies you yet. Incoming money and '
                                'handshakes will be the first two, and both '
                                'will be off until you turn them on.',
                          ),
                        ),
                        _door(
                          disc: const KvRowDisc.neutral(mark: KvGlyph.eye),
                          // Both halves are true of this build: secret
                          // screens set FLAG_SECURE and refuse accessibility
                          // (BG-10), and nothing is ever sent anywhere about
                          // you (INV-8). They are facts, not settings, which
                          // is why the row explains rather than switches.
                          title: 'Privacy',
                          sub: 'Screenshots blocked · no analytics',
                          onTap: () => _openComingSoon(
                            KvGlyph.eye,
                            'Privacy',
                            'This wallet phones nobody: no analytics, no '
                                'crash uploads, no account. Secret screens '
                                'already block screenshots and screen '
                                'readers. What lands here are the choices you '
                                'can make on top of that.',
                          ),
                        ),
                        _door(
                          disc: const KvRowDisc.neutral(mark: KvGlyph.info),
                          title: 'About',
                          state: _about,
                          onTap: () =>
                              _open((_) => AboutScreen(scope: widget.about)),
                        ),
                      ],
                    ),
                    // `T1` measured: 19 dp between the last card and the
                    // pill, and 16 is the grid step under it.
                    const SizedBox(height: KvSpace.m),
                    if (widget.security.lockNow != null)
                      KvAction.raised(
                        label: 'Lock now',
                        mark: KvGlyph.lock,
                        height: KvSpace.touchTarget,
                        onTap: _lockNow,
                        disabledReason: _locking ? 'Locking…' : null,
                      ),
                    if (remove != null) ...[
                      const SizedBox(height: KvSpace.s),
                      _RemoveWallet(onTap: remove),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One door. The render's row exactly: a 40 dp disc, the domain's name, its
  /// state beneath as a fragment, an `etch` chevron.
  ///
  /// [state] is the live seam; [sub] is for a domain whose state does not
  /// change. Exactly one of them, because a row with both would print two
  /// sub-lines and the render draws one.
  Widget _door({
    required KvRowDisc disc,
    required String title,
    ValueListenable<String?>? state,
    String? sub,
    required VoidCallback onTap,
  }) {
    assert(
      (state == null) != (sub == null),
      'a door states its own condition once: a live seam or a fixed fragment',
    );
    final row = state == null
        ? KvRow(
            leading: disc,
            title: title,
            sub: sub,
            dense: true,
            // **Two lines, read off the 320 dp / 1.3× frame.** At 393 every
            // sub-line stands on one, so the root's fit guard is untouched;
            // at the floor all eight ellipsised, and BG-14's own rule is the
            // one this sitting already applied to `titleLines` — a label
            // wraps, only a number may not (playbook §19.6).
            subLines: 2,
            trailing: const KvGlyphIcon(
              KvGlyph.chevron,
              size: 16,
              tone: KvColor.etch,
            ),
            onTap: onTap,
          )
        : ValueListenableBuilder<String?>(
            valueListenable: state,
            builder: (context, value, _) => KvRow(
              leading: disc,
              title: title,
              // Null is *not yet read*, and a row that has not read its seam
              // shows the name alone rather than a `—` (BG-8: a dash means an
              // unknown datum, not an unfinished read).
              sub: value,
              dense: true,
              subLines: 2,
              semanticLabel: value == null ? title : '$title. $value',
              trailing: const KvGlyphIcon(
                KvGlyph.chevron,
                size: 16,
                tone: KvColor.etch,
              ),
              onTap: onTap,
            ),
          );
    return row;
  }
}

/// **The one red thing on the screen** (`T1`, measured `risk` #F26D5F,
/// centred, last, below the raised pill).
///
/// Plain text rather than a pill, and below the thumb arc rather than in it:
/// §4 puts destructive red text last on a scrolling page with no primary, and
/// the distance from the thumb is the point. The ellipsis is load-bearing —
/// it says a ceremony follows, and one does.
class _RemoveWallet extends StatefulWidget {
  const _RemoveWallet({required this.onTap});

  final Future<void> Function() onTap;

  @override
  State<_RemoveWallet> createState() => _RemoveWalletState();
}

class _RemoveWalletState extends State<_RemoveWallet> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    const label = 'Remove this wallet from this phone…';
    return Semantics(
      button: true,
      label: label,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: () {
            KvHaptic.destructiveArmed();
            widget.onTap();
          },
          child: SizedBox(
            // The words are 15 dp; the target is BG-12's 52 and does not
            // scale with the density (§19.5).
            height: KvSpace.touchTarget,
            child: Center(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 15,
                  height: 20 / 15,
                  fontWeight: FontWeight.w600,
                  fontVariations: KvWeight.w600,
                  color: _down
                      ? KvColor.risk.withValues(alpha: 0.7)
                      : KvColor.risk,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `locks after 30 s` — the lock grace as a **fragment**, for a sub-line that
/// already has a subject. The sheet says the same duration as a sentence.
///
/// Shared with [SecurityScreen] so the root and the screen behind it can never
/// disagree about what the current setting is called.
String graceFragment(int secs) => switch (secs) {
  0 => 'locks immediately',
  30 => 'locks after 30 s',
  60 => 'locks after 1 min',
  300 => 'locks after 5 min',
  900 => 'locks after 15 min',
  _ => 'locks after $secs s',
};
