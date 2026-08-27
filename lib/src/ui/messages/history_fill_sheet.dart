import 'package:flutter/material.dart';

import '../../rust/api/transport.dart';
import '../../services/messaging_service.dart';
import '../error_text.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_loader.dart';
import '../widgets/kv_toggle.dart';
import '../widgets/status_beacon.dart' show formatAge;

/// V2b history fill surfaces (D-074): the honest gap notice, and the settings
/// sheet with the toggle + plain privacy disclosure. Everything here is
/// public-wire-class metadata — flags, counts, an endpoint URL; never message
/// content.

/// Minutes of chain the node-only catch-up replays per open (D-074: 48 pages
/// ≈ 20 min). A gap inside this window heals without any indexer — no notice.
const int nodeRewindCoverMinutes = 20;

/// The honest residual notice (D-074: **never silence**). Returns the banner
/// text, or null when history is whole as far as the mechanism can know.
/// Pure — unit-tested against every (gap × fill-posture) cell:
///
/// - No gap signal (first run / unresolved yet / gap within the node rewind):
///   no notice.
/// - A gap beyond the rewind with fill OFF: the notice invites the fix.
/// - Fill ON but the run failed, was incomplete, or hasn't happened yet: the
///   notice stays — an enabled fill is a mechanism, not a guarantee.
/// - Fill ON and the last run completed: healed; quiet.
String? historyNotice({
  required GapAgeDto? gap,
  required FillConfigDto? config,
  required FillReportDto? report,
}) {
  if (gap == null) return null;
  final minutes = gap.gapMinutes?.toInt();
  if (!gap.beyondHorizon &&
      (minutes == null || minutes <= nodeRewindCoverMinutes)) {
    return null;
  }
  final away = gap.beyondHorizon
      ? 'a long time'
      : formatAge(Duration(minutes: minutes!));
  if (config == null || !config.enabled) {
    return 'Away $away — messages sent while the app was closed may be '
        'missing. Tap to recover them.';
  }
  if (report != null && report.ran && report.complete) {
    return null; // filled — as whole as an untrusted hint can make it
  }
  if (report != null && report.ran && report.error != null) {
    return "Couldn't reach the message archive — history before this open "
        'may be incomplete.';
  }
  return 'History check still running or incomplete — older messages may '
      'be missing.';
}

/// The D-138 backup notice: what a restore-from-seed would NOT bring back.
///
/// Pure, and deliberately silent in three cases: before Rust has answered
/// (`null` state — never claim a zero we have not measured), with nothing to
/// back up, and when the last backup still covers everything.
///
/// It speaks up unasked, which almost nothing in this app does. It earns that
/// because the thing it is warning about is invisible until the moment it
/// cannot be fixed: the user finds out their contacts were never backed up on
/// the day they no longer have the device.
String? backupNotice(StashStateDto? state, {required bool archiveEnabled}) {
  if (state == null || state.total == 0) return null;
  if (state.lastUnixMs == BigInt.zero) {
    return "Your conversations aren't backed up — a restore would bring back "
        'your money, but not your contacts. Tap to fix.';
  }
  // Sent is not the same as findable. A backup is parked on chain by us but
  // located again through an archive, and that lookup can fail quietly — so
  // until a history check has actually read it back, the honest word is "sent".
  //
  // With the archive OFF there is nothing that could ever confirm it, so the
  // line must not nag about a check the user cannot run: it says what is true
  // and what would change it, once.
  // Everything else is a DETAIL, and details belong in the sheet.
  //
  // Founder ruling: the banner speaks only for the state where you lose
  // everything. Partial coverage, an unconfirmed read-back, an archive that is
  // switched off — all real, all visible one tap away, none of them worth
  // interrupting for. A warning you cannot act on becomes wallpaper, and then
  // the one that matters gets ignored with it.
  return null;
}

/// Slim tappable banner above the conversation list — renders only when
/// [historyNotice] or [backupNotice] has something honest to say; tapping
/// opens the sheet.
class HistoryNoticeBanner extends StatelessWidget {
  const HistoryNoticeBanner({
    super.key,
    required this.messaging,
    this.onBackUp,
  });

  final MessagingService messaging;

  /// Runs the backup confirm ceremony. Owned by the caller because the sheet
  /// pops before the confirm sheet opens.
  final VoidCallback? onBackUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return AnimatedBuilder(
      animation: Listenable.merge([
        messaging.gapAge,
        messaging.fillConfig,
        messaging.lastFill,
        messaging.stashState,
      ]),
      builder: (context, _) {
        // ONE banner, never two stacked. A history gap is the more urgent of
        // the pair — it is about messages already missing rather than a risk —
        // so it wins, and the backup line surfaces once history is whole.
        final text =
            historyNotice(
              gap: messaging.gapAge.value,
              config: messaging.fillConfig.value,
              report: messaging.lastFill.value,
            ) ??
            backupNotice(
              messaging.stashState.value,
              archiveEnabled: messaging.fillConfig.value?.enabled ?? false,
            );
        // AnimatedSwitcher so the notice resolves (fill completes → banner
        // dissolves) instead of popping; opacity-only under reduced motion
        // (§6 — the TxStatusChip contract, exactly).
        return AnimatedSwitcher(
          duration: KvMotion.normal,
          switchInCurve: KvMotion.out,
          switchOutCurve: KvMotion.out,
          transitionBuilder: (child, animation) {
            final fade = FadeTransition(opacity: animation, child: child);
            if (reduced) return fade;
            return SizeTransition(
              sizeFactor: animation,
              axisAlignment: -1.0,
              child: fade,
            );
          },
          child: text == null
              ? const SizedBox.shrink()
              : Padding(
                  key: ValueKey(text),
                  padding: const EdgeInsets.fromLTRB(
                    KvSpace.gutter,
                    KvSpace.s,
                    KvSpace.gutter,
                    0,
                  ),
                  child: Material(
                    // A recessed notice plate, with the edge §1.1 gives it —
                    // a container without its boundary is not earned (BG-1/4).
                    color: KvColor.notice,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(KvRadius.plate),
                      side: const BorderSide(color: KvColor.noticeEdge),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(KvRadius.plate),
                      onTap: () {
                        KvHaptic.selection();
                        showHistoryFillSheet(
                          context,
                          messaging,
                          onBackUp: onBackUp,
                        );
                      },
                      child: Container(
                        constraints: const BoxConstraints(
                          minHeight: KvSpace.touchTarget,
                        ),
                        padding: const EdgeInsets.all(KvSpace.sm),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.history,
                              size: 18,
                              color: KvColor.inkMeta,
                            ),
                            const SizedBox(width: KvSpace.s),
                            Expanded(
                              child: Text(
                                text,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: KvColor.textSecondary,
                                  fontFamily: KvFont.ui,
                                ),
                              ),
                            ),
                            const Icon(
                              Icons.chevron_right,
                              size: 18,
                              color: KvColor.textTertiary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

/// The D-138 backup block: what a restore would and would not bring back, the
/// coverage line, and the one button that fixes it.
///
/// **Deliberately not behind the archive toggle.** Writing a backup is an
/// ordinary transaction through our own node and tells no third party anything
/// at the time it happens; only READING one back rides the archive opt-in. Two
/// different privacy questions, so two different consents.
class _BackupBlock extends StatelessWidget {
  const _BackupBlock({required this.messaging, required this.onBackUp});

  final MessagingService messaging;
  final VoidCallback? onBackUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: messaging.stashState,
      builder: (context, _) {
        final state = messaging.stashState.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Back up your conversations',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: KvSpace.s),
            Text(
              'Your recovery phrase rebuilds your money on any device. It does '
              'not rebuild your contacts — those live only here. Backing up '
              'parks them on Kaspa, sealed to your own key, so a restore finds '
              'them too. It costs a network fee; the amount comes straight '
              'back to you.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: KvColor.textSecondary,
                fontFamily: KvFont.ui,
              ),
            ),
            const SizedBox(height: KvSpace.s),
            Text(
              _coverageLine(state),
              style: theme.textTheme.bodySmall?.copyWith(
                color: KvColor.textSecondary,
                fontFamily: KvFont.ui,
              ),
            ),
            const SizedBox(height: KvSpace.m),
            FilledButton.tonalIcon(
              // Nothing to back up is a disabled button with an honest line
              // above it, never a button that spends a fee on an empty payload.
              onPressed: (state == null || state.total == 0) ? null : onBackUp,
              icon: const Icon(Icons.backup_outlined, size: 18),
              label: const Text('Back up now'),
            ),
          ],
        );
      },
    );
  }

  /// Counts only — never a contact, never an address.
  static String _coverageLine(StashStateDto? state) {
    if (state == null) return 'Checking what is backed up…';
    if (state.total == 0) return 'No conversations to back up yet.';
    if (state.lastUnixMs == BigInt.zero) {
      return 'Nothing backed up yet (${state.total} '
          'conversation${state.total == 1 ? '' : 's'} here).';
    }
    if (!state.confirmedReadable) {
      return 'Backup sent — waiting to confirm it can be read back.';
    }
    if (state.covered < state.total) {
      return '${state.covered} of ${state.total} conversations backed up — '
          'one backup holds your most recent ones.';
    }
    if (state.covered >= state.total) {
      return 'All ${state.total} conversation${state.total == 1 ? '' : 's'} '
          'backed up.';
    }
    return 'All ${state.total} conversations backed up.';
  }
}

/// Open the history-fill settings sheet.
Future<void> showHistoryFillSheet(
  BuildContext context,
  MessagingService messaging, {
  VoidCallback? onBackUp,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => HistoryFillSheet(messaging: messaging, onBackUp: onBackUp),
  );
}

/// The toggle + disclosure sheet. The disclosure is the D-074 privacy law in
/// plain English: the operator learns the conversation graph and query
/// timing; content stays sealed (verify-by-decrypt). Node-only remains fully
/// functional with the toggle off (INV-8 as amended D-070).
class HistoryFillSheet extends StatefulWidget {
  const HistoryFillSheet({super.key, required this.messaging, this.onBackUp});

  final MessagingService messaging;

  /// Runs the D-138 backup confirm ceremony. The sheet pops first, so the
  /// caller's context (not this one) owns the confirm.
  final VoidCallback? onBackUp;

  @override
  State<HistoryFillSheet> createState() => _HistoryFillSheetState();
}

class _HistoryFillSheetState extends State<HistoryFillSheet> {
  late final TextEditingController _endpoint;
  bool _enabled = false;
  bool _busy = false;
  String? _line; // last action's outcome — honest, small

  @override
  void initState() {
    super.initState();
    final config = widget.messaging.fillConfig.value;
    _enabled = config?.enabled ?? false;
    _endpoint = TextEditingController(text: config?.endpoint ?? '');
    // Pull fresh config in case the sheet opened before start() resolved it.
    if (config == null) {
      widget.messaging.refreshFillState().then((_) {
        if (!mounted) return;
        final fresh = widget.messaging.fillConfig.value;
        if (fresh != null) {
          setState(() {
            _enabled = fresh.enabled;
            _endpoint.text = fresh.endpoint;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _endpoint.dispose();
    super.dispose();
  }

  Future<void> _apply({required bool enabled}) async {
    setState(() {
      _busy = true;
      _line = null;
    });
    try {
      // THIS tap's report, from the return value — never the notifier's
      // possibly-stale prior run (ux-audit residual).
      final report = await widget.messaging.setFillConfig(
        enabled: enabled,
        endpoint: _endpoint.text,
      );
      final config = widget.messaging.fillConfig.value;
      if (!mounted) return;
      setState(() {
        _enabled = config?.enabled ?? enabled;
        if (config != null) _endpoint.text = config.endpoint;
        // The enable path runs a fill at once; a null report means it
        // FAILED at the bridge — say so, never "no check yet."
        _line = !_enabled
            ? 'Off — the app talks to your Kaspa node only.'
            : report == null
            ? "Couldn't check: "
                  '${widget.messaging.error.value ?? 'messaging is restarting — try again'}'
            : _reportLine(report);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _line = displayError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkNow() async {
    setState(() {
      _busy = true;
      _line = null;
    });
    final report = await widget.messaging.fillNow();
    if (!mounted) return;
    setState(() {
      _busy = false;
      // A null report means the check RAN and failed at the bridge (locked
      // vault / hub restarting) — say that, never "no check has run yet."
      _line = report == null
          ? "Couldn't check: "
                '${widget.messaging.error.value ?? 'messaging is restarting — try again'}'
          : _reportLine(report);
    });
  }

  /// One honest sentence per outcome — counts only, never content.
  static String _reportLine(FillReportDto? report) {
    if (report == null || !report.ran) return 'No check has run yet.';
    if (report.error != null) {
      return "Couldn't reach the archive: ${report.error}";
    }
    final rows = report.newRows;
    final what = rows == 0
        ? 'nothing new'
        : '$rows recovered message${rows == 1 ? '' : 's'}';
    return report.complete
        ? 'Checked — $what.'
        : 'Partial check ($what so far) — more remains; check again.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          KvSpace.gutter,
          KvSpace.m,
          KvSpace.gutter,
          KvSpace.l + inset,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Text(
                'History & backup',
                style: theme.textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: KvSpace.m),
            _BackupBlock(
              messaging: widget.messaging,
              onBackUp: widget.onBackUp == null
                  ? null
                  : () {
                      Navigator.of(context).pop();
                      widget.onBackUp!();
                    },
            ),
            const Divider(height: KvSpace.xl),
            Text(
              'Your Kaspa node only keeps recent history (about 30 hours). '
              'Messages sent while the app is closed longer than that — or '
              'past the quick catch-up window — need an archive to recover.',
              // Prose is Inter (§4 role map) — bare bodySmall is the mono
              // data face here.
              style: theme.textTheme.bodySmall?.copyWith(
                color: KvColor.textSecondary,
                fontFamily: KvFont.ui,
              ),
            ),
            const SizedBox(height: KvSpace.m),
            // **`KvToggle`, not `SwitchListTile`** (D-206, landed at UX-3).
            // This was the app's last Material switch, and it was the one
            // thing standing between `SwitchThemeData` and retirement: the
            // theme existed only to paint it, and a framework `Switch` slides
            // its thumb under reduced motion, which BG-9 forbids. Two other
            // laws move with it — an unthemed `Switch` resolves its selected
            // track to `colorScheme.primary`, i.e. teal as a status (BG-2),
            // and its unselected state to `outline` on
            // `surfaceContainerHighest`, measured at 1.20:1 against WCAG
            // 1.4.11's 3:1 (`ux-auditor`, this sitting). The surface itself
            // is still UX-6's to rewrite; this is the one widget swap that
            // makes the theme's removal true.
            KvToggle(
              on: _enabled,
              title: 'Recover missed messages from an archive',
              sub: _enabled
                  ? 'The archive below is asked for messages your node no '
                        'longer holds.'
                  : 'Nothing is fetched. Only what your own node still holds '
                        'is recovered.',
              disabledReason: 'Saving…',
              onChanged: _busy ? null : (on) => _apply(enabled: on),
            ),
            const SizedBox(height: KvSpace.s),
            // The privacy disclosure — the price and the guarantee, plainly.
            Container(
              padding: const EdgeInsets.all(KvSpace.sm),
              decoration: BoxDecoration(
                color: KvColor.surfaceAlt,
                borderRadius: BorderRadius.circular(KvRadius.card),
              ),
              child: Text(
                'What the archive operator learns: which addresses and '
                'conversation tags you look up, and when you check.\n\n'
                'What they can never do: read your messages. Everything stays '
                'sealed to keys they do not have.\n\n'
                'What they also learn when you back up conversations: that '
                'your main address parked a backup, and roughly how many '
                'contacts it holds (from its size). Not who they are — that '
                'stays sealed to your own key.\n\n'
                'What they CAN do: leave history out, and add a message of '
                'their own. Your receive address is the key messages are '
                'sealed to, and it is what the wallet hands them to search '
                'on — so a dishonest archive can write something your wallet '
                'will open, and stamp any transaction ID and time on it. '
                'Anything an archive supplies is labelled in the thread until '
                'your own node has seen it.\n\n'
                'Off, everything works against your node alone — only '
                'history past its horizon stays unrecoverable.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: KvColor.textSecondary,
                  fontFamily: KvFont.ui,
                ),
              ),
            ),
            if (_enabled) ...[
              const SizedBox(height: KvSpace.m),
              TextField(
                controller: _endpoint,
                enabled: !_busy,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: KvFont.mono,
                ),
                decoration: const InputDecoration(
                  labelText: 'Archive endpoint',
                  helperText:
                      'Any compatible indexer — the default is a community '
                      'service; self-hosting yours keeps the graph at home.',
                ),
                onSubmitted: (_) => _apply(enabled: true),
              ),
              const SizedBox(height: KvSpace.m),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _checkNow,
                icon: _busy
                    ? const KvLoader.inline()
                    : const Icon(Icons.cloud_download_outlined, size: 18),
                label: const Text('Check now'),
              ),
            ],
            if (_line != null) ...[
              const SizedBox(height: KvSpace.s),
              Text(
                _line!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: KvColor.textSecondary,
                  fontFamily: KvFont.ui,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
