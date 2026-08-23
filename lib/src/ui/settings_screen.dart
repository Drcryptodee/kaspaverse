import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../rust/api/send.dart' show SendOutcomeDto, SignableSummaryDto;
import '../rust/api/wallet.dart' show DeepScanReport;
import 'address_text.dart';
import 'biometric_copy.dart';
import 'error_text.dart';
import 'network_sheet.dart';
import 'send/confirm_send_sheet.dart';
import 'theme/kv_page_route.dart';
import 'theme/tokens.dart';
import 'widgets/glass_panel.dart';
import 'widgets/haptics.dart';
import 'widgets/kv_loader.dart';

/// One row of the settings registry.
///
/// The row is the unit of growth. Adding a setting later must be an additive
/// entry in [SettingsScreen.registry] and nothing else — never a new layout,
/// never a bespoke widget in the list. A settings screen becomes a dumping
/// ground when rows are allowed to invent their own shapes, so anything that
/// needs more than a title, a support line and a trailing value pushes its own
/// surface (as Network does) instead of growing this one.
@immutable
class SettingsRow {
  const SettingsRow({
    required this.id,
    required this.icon,
    required this.title,
    this.subtitle,
    this.status,
    this.onTap,
    this.destructive = false,
  });

  /// Stable identity, independent of copy. Tests and the reachability proof bind
  /// to this so a wording change can never silently delete their subject.
  final String id;

  final IconData icon;
  final String title;

  /// Static support copy. Say what the row DOES, not that it exists.
  final String? subtitle;

  /// Live trailing value — "On", "Immediately", an address. Null means the row
  /// shows a chevron and nothing else.
  final ValueListenable<SettingsStatus?>? status;

  final VoidCallback? onTap;

  /// Renders in `KvColor.error`. Rationed to fund risk and destruction only
  /// (§3/§4) — a row that merely changes a setting is never destructive.
  final bool destructive;
}

/// How a row's value should read. §3 rations colour, so a failure must not wear
/// the same ambient teal as a healthy "On" — and colour is never the only
/// carrier: the words say it too (§11).
enum SettingsTone {
  /// A live, healthy value — the brand teal.
  active,

  /// Quiet supporting data (a version string, a build number).
  neutral,

  /// Something is wrong, unavailable, or could not be done. `warning`, never
  /// `error`: nothing here is fund risk or destruction.
  degraded,
}

/// A row's live value, with the tone it should be read in.
///
/// A bare `String?` made every value — "On", "Needs a security update",
/// "Couldn't finish the scan" — render identically in the brand teal, so colour
/// carried no information at all on a surface where two of those three are
/// failures (ux-auditor, Track 2).
@immutable
class SettingsStatus {
  const SettingsStatus(this.text, {this.tone = SettingsTone.active})
    : address = null;

  /// A Kaspa address, rendered through [AddressText] — the DS-8 compact form
  /// (scheme tertiary, payload mono) with the §11 spoken label. Identity is
  /// mono-for-trust (§4) and must not be hand-formatted in a row.
  const SettingsStatus.address(String this.address)
    : text = '',
      tone = SettingsTone.active;

  final String text;
  final String? address;
  final SettingsTone tone;
}

/// A named group of rows. Every row belongs to exactly one section, and a row
/// that fits no section is a row without a reason to exist.
@immutable
class SettingsSection {
  const SettingsSection({
    required this.id,
    required this.title,
    required this.rows,
  });

  final String id;
  final String title;
  final List<SettingsRow> rows;
}

/// Everything the Security section drives. Seams, not singletons — the V5 scope
/// pattern (`ChainScope`/`WalletScope`, D-086), so widget tests run without a
/// platform channel.
@immutable
class SecurityScope {
  const SecurityScope({
    required this.biometricStatus,
    required this.pathAState,
    required this.enroll,
    required this.clearEnrollment,
    required this.lockGraceSecs,
    required this.setLockGraceSecs,
  });

  /// `ready` · `none_enrolled` · `no_hardware` · `unavailable` ·
  /// `security_update_required` · `unknown`. A reason, never a bool — see
  /// [biometricStateLabel] for why that distinction is the whole point.
  final Future<String> Function() biometricStatus;

  /// `none` · `ready` · `invalidated`. A state, not a bool, for the same reason
  /// [biometricStatus] is: "never set up" and "set up, then invalidated by a new
  /// fingerprint" need different sentences and different remedies. As a bool the
  /// second one read as "On" over a lane that could no longer open (run 1, F4).
  final Future<String> Function() pathAState;

  /// Throws [PlatformException] with a stable code so a cancel can be told from
  /// a failure.
  final Future<bool> Function() enroll;
  final Future<void> Function() clearEnrollment;

  final ValueListenable<int> lockGraceSecs;
  final Future<void> Function(int secs) setLockGraceSecs;
}

/// Everything the Wallet section drives.
@immutable
class WalletSettingsScope {
  const WalletSettingsScope({
    required this.receiveAddress,
    required this.deepScan,
    this.receiveRoute,
    this.consolidate,
    this.commitSend,
    this.abandonSend,
  });

  final Future<String> Function() receiveAddress;

  /// The manual deep scan (Track 1's lever). Long-running by design and bounded
  /// Rust-side; the row owns the busy state.
  final Future<DeepScanReport> Function() deepScan;

  final WidgetBuilder? receiveRoute;

  /// Merge coins (consolidation): Rust builds + stashes the plan, this screen
  /// opens the ONE signing surface ([ConfirmSendSheet]) over its summary. All
  /// three seams present ⇒ the row renders; absent ⇒ hidden (tests, and any
  /// build without the send stack wired).
  final Future<SignableSummaryDto> Function()? consolidate;
  final Future<SendOutcomeDto> Function(BigInt nonce)? commitSend;
  final Future<void> Function()? abandonSend;
}

/// The About section's public build identity.
@immutable
class AboutScope {
  const AboutScope({required this.packageInfo});

  /// `version` · `build` · `signature` (SHA-256, lowercase hex).
  final Future<Map<String, String>> Function() packageInfo;
}

/// The settings surface — the app's only one, and built to accumulate.
///
/// **Why this screen exists at all.** There was no settings screen, and that
/// absence was the root cause of a shipped-but-unreachable feature rather than a
/// side effect of one: biometric enrolment was offered exactly once, inside the
/// create flow, so a restored wallet could never enable it and a "Not now" was
/// irreversible in a release build. The native lane was complete the whole time;
/// only the way in was missing. Reachability is a feature.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.security,
    required this.wallet,
    required this.about,
    this.networkSheet,
  });

  final SecurityScope security;
  final WalletSettingsScope wallet;
  final AboutScope about;

  /// Builds the SAME sheet the home beacon opens (never a copy of it). The row
  /// deliberately shows no live status of its own: two renderings of one link
  /// state are two places to disagree, which is exactly what C7 forbids.
  final NetworkSheet Function()? networkSheet;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  final ValueNotifier<SettingsStatus?> _biometric = ValueNotifier(null);
  final ValueNotifier<SettingsStatus?> _address = ValueNotifier(null);
  final ValueNotifier<SettingsStatus?> _scan = ValueNotifier(null);
  final ValueNotifier<SettingsStatus?> _merge = ValueNotifier(null);
  final ValueNotifier<SettingsStatus?> _version = ValueNotifier(null);
  final ValueNotifier<SettingsStatus?> _signature = ValueNotifier(null);
  late final ValueNotifier<SettingsStatus?> _grace;

  /// Raw biometric status, kept so the action sheet can offer the right verbs.
  String _biometricStatus = 'unknown';

  /// Raw Path-A state, for the same reason — `invalidated` needs its own
  /// explanation and its own verb, not the "Off" branch's.
  String _pathAState = pathANone;

  /// The signing fingerprint as the platform gave it — all 64 hex characters.
  ///
  /// Kept beside the elided row value rather than instead of it. Shortening on
  /// arrival destroyed the only copy, so the sheet that exists to show the whole
  /// thing had 16 characters and an ellipsis to show, and a user following
  /// `RELEASE.md` compared a quarter of the digest against the published one and
  /// could never match it — the provenance check the feature exists for, unable
  /// to be performed (dependency-steward, Track 2). Elide at RENDER only.
  String? _fullSignature;
  bool _enrolled = false;
  String? _busyRow;

  @override
  void initState() {
    super.initState();
    _grace = ValueNotifier(
      SettingsStatus(_graceLabel(widget.security.lockGraceSecs.value)),
    );
    widget.security.lockGraceSecs.addListener(_onGraceChanged);
    WidgetsBinding.instance.addObserver(this);
    _refreshBiometric();
    _refreshAddress();
    _refreshAbout();
  }

  /// Re-probe when the user comes back.
  ///
  /// The copy for `none_enrolled` sends them to Android Settings and says "then
  /// turn this on in Settings → Security". With any auto-lock grace above zero
  /// the vault does not lock, this route is never popped, and the `State`
  /// survives the background — so the one path the copy prescribes landed on a
  /// stale verdict, with the row still reading "No fingerprint on this phone"
  /// and the sheet still offering no Enable action. The reachability defect this
  /// screen exists to end, re-created one level down (ux-auditor, Track 2).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshBiometric();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.security.lockGraceSecs.removeListener(_onGraceChanged);
    _biometric.dispose();
    _address.dispose();
    _scan.dispose();
    _merge.dispose();
    _version.dispose();
    _signature.dispose();
    _grace.dispose();
    super.dispose();
  }

  void _onGraceChanged() => _grace.value = SettingsStatus(
    _graceLabel(widget.security.lockGraceSecs.value),
  );

  // ── live values ──────────────────────────────────────────────────────────

  Future<void> _refreshBiometric() async {
    var status = 'unknown';
    var state = pathANone;
    try {
      status = await widget.security.biometricStatus();
      state = await widget.security.pathAState();
    } catch (_) {
      // A platform gap (host tests, a missing channel) is "unknown", which the
      // label renders honestly rather than as a confident "Off".
    }
    if (!mounted) return;
    _biometricStatus = status;
    _pathAState = state;
    final enrolled = state == pathAReady;
    _enrolled = enrolled;
    _biometric.value = SettingsStatus(
      biometricStateLabel(status, state),
      // "On" is health and wears `success`; "Off" is a quiet, correct state and
      // must not wear the same voice — colour has to distinguish the two states
      // of a custody control or it carries no information at all (§3).
      tone: switch (status) {
        _ when biometricStateIsDegraded(status) => SettingsTone.degraded,
        _ when biometricStateIsUnknown(status) => SettingsTone.neutral,
        // Enrolled-but-invalidated is a control the user believes is protecting
        // them and which no longer opens anything. That is degraded, not the
        // quiet neutral of "Off" — a row cannot wear the calm voice of a
        // deliberate choice for a state the user did not choose (§3).
        _ when state == pathAInvalidated => SettingsTone.degraded,
        _ => enrolled ? SettingsTone.active : SettingsTone.neutral,
      },
    );
  }

  Future<void> _refreshAddress() async {
    try {
      final address = await widget.wallet.receiveAddress();
      if (mounted) _address.value = SettingsStatus.address(address);
    } catch (_) {
      if (mounted) {
        _address.value = const SettingsStatus('—', tone: SettingsTone.degraded);
      }
    }
  }

  Future<void> _refreshAbout() async {
    try {
      final info = await widget.about.packageInfo();
      if (!mounted) return;
      final version = info['version'] ?? '—';
      final build = info['build'] ?? '—';
      _version.value = SettingsStatus(
        build == '—' ? version : '$version ($build)',
        tone: SettingsTone.neutral,
      );
      _fullSignature = info['signature'];
      _signature.value = SettingsStatus(
        _shortFingerprint(_fullSignature),
        tone: SettingsTone.neutral,
      );
    } catch (_) {
      if (!mounted) return;
      const unknown = SettingsStatus('—', tone: SettingsTone.degraded);
      _version.value = unknown;
      _fullSignature = null;
      _signature.value = unknown;
    }
  }

  static String _graceLabel(int secs) => switch (secs) {
    0 => 'Immediately',
    30 => 'After 30 seconds',
    60 => 'After 1 minute',
    300 => 'After 5 minutes',
    900 => 'After 15 minutes',
    _ => 'After $secs seconds',
  };

  /// The fingerprint is 64 hex characters — unreadable in a row and pointless to
  /// truncate silently, so the row shows the first and last groups and the sheet
  /// shows all of it.
  static String _shortFingerprint(String? hex) {
    if (hex == null || hex.length < 16) return hex ?? '—';
    return '${hex.substring(0, 8)}…${hex.substring(hex.length - 8)}';
  }

  // ── the registry ─────────────────────────────────────────────────────────

  /// The screen, declared. Every row states why it is here in its subtitle, and
  /// every section is a reason for a group of rows to sit together.
  List<SettingsSection> registry() => [
    SettingsSection(
      id: 'security',
      title: 'Security',
      rows: [
        SettingsRow(
          id: 'biometric',
          icon: Icons.fingerprint,
          title: 'Fingerprint unlock',
          subtitle: 'Unlock quickly. Your passphrase always still works.',
          status: _biometric,
          onTap: _openBiometricSheet,
        ),
        SettingsRow(
          id: 'lock-grace',
          icon: Icons.lock_clock,
          title: 'Lock when I leave',
          subtitle: 'How long the wallet stays open after you switch away.',
          status: _grace,
          onTap: _openGraceSheet,
        ),
      ],
    ),
    SettingsSection(
      id: 'wallet',
      title: 'Wallet',
      rows: [
        SettingsRow(
          id: 'receive-address',
          icon: Icons.south_west,
          title: 'Receive address',
          subtitle: 'Where payments to you arrive.',
          status: _address,
          onTap: widget.wallet.receiveRoute == null
              ? null
              : () => Navigator.of(
                  context,
                ).push(KvPageRoute<void>(builder: widget.wallet.receiveRoute!)),
        ),
        SettingsRow(
          id: 'deep-scan',
          icon: Icons.travel_explore,
          title: 'Scan for more addresses',
          subtitle:
              'Look deeper for funds held at addresses another wallet app '
              'created. Safe to run any time.',
          status: _scan,
          onTap: _runDeepScan,
        ),
        if (widget.wallet.consolidate != null &&
            widget.wallet.commitSend != null &&
            widget.wallet.abandonSend != null)
          SettingsRow(
            id: 'merge-coins',
            icon: Icons.join_full_outlined,
            title: 'Merge coins',
            subtitle:
                'Combine your spendable coins into one, so future sends '
                'cost less. You pay one network fee.',
            status: _merge,
            onTap: _runMergeCoins,
          ),
      ],
    ),
    SettingsSection(
      id: 'network',
      title: 'Network',
      rows: [
        SettingsRow(
          id: 'network-sheet',
          icon: Icons.hub_outlined,
          title: 'Node & connection',
          subtitle:
              'Which public node you are talking to, and how fresh it is.',
          onTap: widget.networkSheet == null
              ? null
              : () => NetworkSheet.show(context, widget.networkSheet!()),
        ),
      ],
    ),
    SettingsSection(
      id: 'about',
      title: 'About',
      rows: [
        SettingsRow(
          id: 'version',
          icon: Icons.info_outline,
          title: 'Version',
          status: _version,
        ),
        SettingsRow(
          id: 'signature',
          icon: Icons.verified_outlined,
          title: 'App signature',
          subtitle:
              'Check this against the published fingerprint for a release.',
          status: _signature,
          onTap: _openSignatureSheet,
        ),
      ],
    ),
  ];

  // ── row actions ──────────────────────────────────────────────────────────

  /// Merge coins: prepare in Rust, then hand the summary to the ONE signing
  /// surface — the same anti-blind-signing sheet every send uses (B7, DS-3).
  /// A refusal ("nothing to merge", dust beneath the fee) lands as the row's
  /// own status line, in Rust's honest words.
  Future<void> _runMergeCoins() async {
    final consolidate = widget.wallet.consolidate;
    final commit = widget.wallet.commitSend;
    final abandon = widget.wallet.abandonSend;
    if (consolidate == null || commit == null || abandon == null) return;
    if (_busyRow != null) return;
    setState(() => _busyRow = 'merge-coins');
    _merge.value = const SettingsStatus(
      'Preparing…',
      tone: SettingsTone.neutral,
    );
    try {
      final summary = await consolidate();
      if (!mounted) return;
      _merge.value = null;
      final outcome = await showModalBottomSheet<SendOutcomeDto?>(
        context: context,
        backgroundColor: KvColor.surface,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => ConfirmSendSheet(
          summary: summary,
          commit: commit,
          abandon: abandon,
        ),
      );
      if (!mounted) return;
      if (outcome != null && !outcome.partial && outcome.error == null) {
        // The new single coin arrives via the live sync; this line only
        // reports that the merge was broadcast.
        _merge.value = const SettingsStatus('Merged — balance updating');
      }
    } catch (e) {
      if (!mounted) return;
      // Rust's refusals are already plain English; render them, not a shrug.
      // "Nothing to merge" is the wallet in its BEST state — it must not wear
      // the degraded amber (§3: the same rule deep-scan's "Nothing new found"
      // follows). Real failures keep the honest degraded tone.
      final message = displayError(e);
      _merge.value = SettingsStatus(
        message,
        tone: message.startsWith('nothing to merge')
            ? SettingsTone.neutral
            : SettingsTone.degraded,
      );
    } finally {
      if (mounted) setState(() => _busyRow = null);
    }
  }

  Future<void> _runDeepScan() async {
    if (_busyRow != null) return;
    setState(() => _busyRow = 'deep-scan');
    _scan.value = const SettingsStatus('Scanning…');
    try {
      final report = await widget.wallet.deepScan();
      // The scan is bounded at 180 s Rust-side, which is ample time to navigate
      // away — and writing a disposed ValueNotifier throws, then throws again
      // inside the catch below as an unhandled async error.
      if (!mounted) return;
      // "Nothing new" is a SUCCESSFUL outcome and must not read like a failure —
      // most taps will land here, on a wallet that was already complete.
      _scan.value = SettingsStatus(
        report.widened
            ? 'Found more — your balance is updating'
            : 'Nothing new found',
      );
    } catch (_) {
      if (!mounted) return;
      // The honest failure. Never a silent "done": a scan that says it worked
      // and quietly found nothing is the original defect wearing a new button.
      //
      // Our own words, never the platform's. An earlier version rendered a
      // caught `PlatformException.message` here — a dead branch (`deepScan` is
      // an FRB call and raises `AppError`), and the one place in this screen
      // that would have put an OEM- and locale-dependent diagnostic string on
      // the glass.
      _scan.value = const SettingsStatus(
        "Couldn't finish the scan — try again",
        tone: SettingsTone.degraded,
      );
    } finally {
      if (mounted) setState(() => _busyRow = null);
    }
  }

  Future<void> _enrollNow() async {
    setState(() => _busyRow = 'biometric');
    try {
      await widget.security.enroll();
      await _refreshBiometric();
    } on PlatformException catch (e) {
      if (!mounted) return;
      // A cancel is a CHOICE, not a failure — no banner, nothing to apologise
      // for. Every other code gets words the user can act on.
      if (e.code != 'cancelled') {
        _biometric.value = SettingsStatus(
          enrollFailureCopy(e.code),
          tone: SettingsTone.degraded,
        );
      }
    } catch (_) {
      if (mounted) {
        _biometric.value = SettingsStatus(
          enrollFailureCopy('failed'),
          tone: SettingsTone.degraded,
        );
      }
    } finally {
      if (mounted) setState(() => _busyRow = null);
    }
  }

  Future<void> _clearEnrollment() async {
    setState(() => _busyRow = 'biometric');
    try {
      await widget.security.clearEnrollment();
      await _refreshBiometric();
    } catch (_) {
      if (mounted) _showMessage("Couldn't turn fingerprint unlock off.");
    } finally {
      if (mounted) setState(() => _busyRow = null);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  // ── sheets ───────────────────────────────────────────────────────────────

  Future<void> _openBiometricSheet() async {
    // Re-ask before offering verbs, so the actions match the phone's state now
    // and not at mount.
    await _refreshBiometric();
    if (!mounted) return;
    final ready = _biometricStatus == biometricReady;
    final invalidated = ready && _pathAState == pathAInvalidated;
    _showSheet(
      title: 'Fingerprint unlock',
      body: ready
          ? (invalidated
                ? biometricInvalidatedCopy
                : _enrolled
                ? 'Fingerprint unlock is on. Your passphrase still works as a '
                      'backup, and always will.'
                : 'Add your fingerprint to unlock quickly. Your passphrase '
                      'keeps working as a backup.')
          : biometricUnavailableCopy(_biometricStatus),
      actions: [
        // "Set up again" is the verb for the invalidated state and it now
        // actually repairs it: enrolment deletes the dead key and builds a new
        // one, where it used to reuse the dead one and fail the same way (F4).
        if (ready && !_enrolled && !invalidated)
          _SheetAction('Enable fingerprint unlock', _enrollNow),
        if (ready && (_enrolled || invalidated)) ...[
          _SheetAction('Set up again', _enrollNow),
          // Destructive: it deletes the Keystore key and the sealed blob. Not
          // fund loss — Path B is untouched and re-enrolling restores it — but
          // it is a deliberate removal of a custody control, so it says so.
          _SheetAction('Turn off', () {
            KvHaptic.destructiveArmed(); // §7: arming a destructive control
            _clearEnrollment();
          }, destructive: true),
        ],
      ],
    );
  }

  void _openGraceSheet() {
    _showSheet(
      title: 'Lock when I leave',
      // Says what the choice COSTS. The first draft ended "whatever you pick,
      // your funds are only ever spendable with your passphrase or fingerprint"
      // — false for precisely the window this control creates, since inside the
      // grace the wallet is already open and coming back spends with neither.
      // It was the one sentence a user reads while choosing their exposure, and
      // it denied that any existed (wallet-security-auditor).
      body:
          'The wallet locks itself when you switch to another app. Choose how '
          'long it waits first.\n\n'
          'While it waits, the wallet is still open — anyone who can use your '
          'phone in that window can spend from it. Your phone’s own lock screen '
          'is what protects you there. Pick Immediately if you would rather not '
          'rely on it.',
      actions: [
        for (final secs in const [0, 30, 60, 300, 900])
          _SheetAction(
            _graceLabel(secs),
            () => _applyGrace(secs),
            selected: widget.security.lockGraceSecs.value == secs,
          ),
      ],
    );
  }

  /// Awaited, so a failed write is reported rather than becoming an unhandled
  /// rejection behind a row whose label correctly did not move.
  Future<void> _applyGrace(int secs) async {
    KvHaptic.selection(); // §7: a picker choice is a selection click
    try {
      await widget.security.setLockGraceSecs(secs);
    } catch (_) {
      if (mounted) _showMessage("Couldn't save that. The wallet still locks.");
    }
  }

  void _openSignatureSheet() {
    // The whole fingerprint, in the form `apksigner verify --print-certs`
    // prints, so a user comparing an install against a published value is
    // comparing like with like. Public data — selecting and copying is fine
    // here (the no-clipboard law is DS-7, and it is about seeds).
    final full = _fullSignature;
    _showSheet(
      title: 'App signature',
      body:
          'SHA-256 of the certificate this build was signed with. A release '
          'that matches the published fingerprint was built by us.',
      monospace: full,
    );
  }

  void _showSheet({
    required String title,
    required String body,
    List<_SheetAction> actions = const [],
    String? monospace,
  }) {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      elevation: 0,
      // Without this the height is capped at 9/16 of the screen, and the
      // lock-grace sheet — five options under a paragraph about exposure —
      // clips its own last option at large text scales, on the surface where a
      // user chooses that exposure (ux-auditor, Track 2). `NetworkSheet.show`
      // needed the same fix, and an earlier version of this comment claimed
      // every other sheet already passed it — which was false for exactly the
      // sheet this screen routes to.
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: GlassPanel(
          frosted: true,
          radius: const BorderRadius.vertical(
            top: Radius.circular(KvRadius.card),
          ),
          padding: const EdgeInsets.all(KvSpace.gutter),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: KvSpace.s),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: KvColor.textSecondary,
                    fontFamily: KvFont.ui,
                  ),
                ),
                if (monospace != null) ...[
                  const SizedBox(height: KvSpace.m),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(KvSpace.sm),
                    decoration: BoxDecoration(
                      color: KvColor.surfaceAlt,
                      borderRadius: BorderRadius.circular(KvRadius.data),
                    ),
                    child: SelectableText(
                      monospace,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
                for (final action in actions) ...[
                  const SizedBox(height: KvSpace.s),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        action.onTap();
                      },
                      style: action.destructive
                          ? TextButton.styleFrom(foregroundColor: KvColor.error)
                          : null,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (action.selected) ...[
                            const Icon(Icons.check, size: 16),
                            const SizedBox(width: KvSpace.s),
                          ],
                          // Wraps rather than clipping. "Enable fingerprint
                          // unlock" is the longest label the app has and it
                          // reaches the button's content box around 1.8× —
                          // past §4's 1.3× bar, but a truncated verb+object
                          // (§12) on the only door to enabling biometric
                          // unlock is not a thing to leave to the margin.
                          Flexible(
                            child: Text(
                              action.label,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── render ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sections = registry();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            KvSpace.gutter,
            KvSpace.m,
            KvSpace.gutter,
            KvSpace.xl,
          ),
          children: [
            for (final section in sections) ...[
              Padding(
                padding: const EdgeInsets.only(
                  left: KvSpace.xs,
                  bottom: KvSpace.s,
                ),
                child: Text(section.title, style: theme.textTheme.titleMedium),
              ),
              GlassPanel(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var i = 0; i < section.rows.length; i++) ...[
                      if (i > 0) const Divider(height: 1, indent: KvSpace.xxl),
                      _Row(
                        row: section.rows[i],
                        busy: _busyRow == section.rows[i].id,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: KvSpace.l),
            ],
          ],
        ),
      ),
    );
  }
}

/// One action in a settings sheet.
@immutable
class _SheetAction {
  const _SheetAction(
    this.label,
    this.onTap, {
    this.destructive = false,
    this.selected = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool destructive;
  final bool selected;
}

/// The ONE row renderer. Every setting in the app is drawn by this widget, which
/// is what keeps the registry a registry: a row cannot quietly grow a bespoke
/// layout, so a new setting has to fit the contract or justify its own screen.
class _Row extends StatelessWidget {
  const _Row({required this.row, required this.busy});

  final SettingsRow row;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = row.destructive ? KvColor.error : KvColor.textSecondary;
    // The ink needs a Material of its own: `GlassPanel`'s fill is an opaque
    // Container, so without this the splash paints on the Scaffold's Material
    // UNDERNEATH the panel and the rows have no visible press feedback at all
    // (§6). Every other tappable row in the app already does this
    // (contacts_screen, history_fill_sheet, secret_keyboard) — ux-auditor.
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: row.onTap == null || busy
            ? null
            : () {
                KvHaptic.selection();
                row.onTap!();
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: KvSpace.m,
            vertical: KvSpace.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(row.icon, size: 20, color: tint),
              const SizedBox(width: KvSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      row.title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: row.destructive
                            ? KvColor.error
                            : KvColor.textPrimary,
                      ),
                    ),
                    if (row.subtitle != null) ...[
                      const SizedBox(height: KvSpace.xs),
                      Text(
                        row.subtitle!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: KvColor.textTertiary,
                          fontFamily: KvFont.ui,
                        ),
                      ),
                    ],
                    if (row.status != null)
                      ValueListenableBuilder<SettingsStatus?>(
                        valueListenable: row.status!,
                        builder: (context, value, _) {
                          // Nothing rendered until there IS something. A `—`
                          // means *unknown datum* (DS-1); an action row that has
                          // simply not been run yet has no datum to be unknown
                          // about (ux-auditor, Track 2).
                          if (value == null) return const SizedBox.shrink();
                          final address = value.address;
                          return Padding(
                            padding: const EdgeInsets.only(top: KvSpace.xs),
                            child: address != null
                                // Identity goes through the DS widget: compact
                                // DS-8 form, mono payload, §11 spoken label.
                                ? AddressText(
                                    address,
                                    style: theme.textTheme.labelSmall,
                                  )
                                : Text(
                                    value.text,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: switch (value.tone) {
                                        SettingsTone.active => KvColor.success,
                                        SettingsTone.neutral =>
                                          KvColor.textSecondary,
                                        SettingsTone.degraded =>
                                          KvColor.warning,
                                      },
                                      fontFamily: KvFont.ui,
                                    ),
                                  ),
                          );
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(width: KvSpace.s),
              if (busy)
                const KvLoader.inline()
              else if (row.onTap != null)
                const Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: KvColor.textTertiary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
