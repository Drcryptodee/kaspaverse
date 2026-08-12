import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../rust/api/dag.dart';
import 'format.dart';
import 'theme/tokens.dart';
import 'widgets/glass_panel.dart';
import 'widgets/haptics.dart';
import 'widgets/kv_loader.dart';
import 'widgets/status_beacon.dart';

/// The network details sheet — sovereignty made visible: which public node,
/// how fresh, what the chain clock reads. Frosted (§8: the screen's one blur,
/// over real content). Values stay live via the same listenables the home
/// watches.
///
/// Extracted from `home_screen.dart` unchanged (Track 2). It was private there,
/// which meant the Settings screen's Network row had no way to reach it and the
/// only options were to duplicate the surface or move it. A second copy of a
/// status readout is two places to disagree about the same truth — the exact
/// thing C7 exists to forbid — so it moved.
class NetworkSheet extends StatefulWidget {
  const NetworkSheet({
    super.key,
    required this.connected,
    required this.endpoint,
    required this.virtualDaaScore,
    required this.error,
    required this.lastUpdate,
    required this.clock,
    this.reconnecting,
    this.onReconnect,
    this.searching,
    this.osOffline,
    this.disconnectedAt,
  });

  final ValueListenable<bool> connected;
  final ValueListenable<String?> endpoint;
  final ValueListenable<BigInt?> virtualDaaScore;
  final ValueListenable<String?> error;
  final ValueListenable<DateTime?> lastUpdate;
  final DateTime Function() clock;
  final ValueListenable<bool>? reconnecting;
  final Future<void> Function()? onReconnect;

  /// C7: the same three truths the beacon renders — the sheet is where the
  /// user goes to understand, so it must never disagree with the chip. ONE
  /// writer (ChainService) feeds both; the sheet's own poll stays scoped to
  /// the block-age line it already owned.
  final ValueListenable<bool>? searching;
  final ValueListenable<bool>? osOffline;
  final ValueListenable<DateTime?>? disconnectedAt;

  /// Show this sheet over [context] — the one presentation path, so the home
  /// beacon tap and the Settings row can never drift in how it is presented.
  static Future<void> show(BuildContext context, NetworkSheet sheet) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      elevation: 0,
      // Without this the height is capped at 9/16 of the screen, and this sheet
      // overflowed by 15 px at default text scale on a 411×731 phone — at 1.3×
      // the Reconnect button laid out below the screen edge (deleting C4's
      // manual kick) and the DS-6 sovereignty line rendered entirely off it.
      //
      // The defect predates the extraction and travelled with the file, which is
      // the lesson: moving a private surface into a shared one gives its unfixed
      // layout bugs a second entry point (ux-auditor, Track 2 re-audit).
      isScrollControlled: true,
      builder: (_) => sheet,
    );
  }

  @override
  State<NetworkSheet> createState() => _NetworkSheetState();
}

class _NetworkSheetState extends State<NetworkSheet> {
  Timer? _poll;
  int? _blockAgeSecs;
  bool _haveStatus = false;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    // Poll the honest block-age while the sheet is open (P3): the precise
    // scan-liveness signal, straight from the monitor's heartbeat.
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refreshStatus());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    try {
      final status = await dagStatus();
      if (!mounted) return;
      setState(() {
        _blockAgeSecs = status.lastBlockAgeSecs?.toInt();
        _haveStatus = true;
      });
    } catch (_) {
      // A failed pull just leaves the last-known age; never crash the sheet.
    }
  }

  /// The transport-scan liveness line: the scan runs on every block, so the
  /// block-age IS its freshness. Honest about "never" before the first block.
  ///
  /// C7 addendum: *live* is a claim about the LINK, not about the age alone.
  /// This line rides a 2 s poll while the link notifiers are pushed, so a
  /// just-dropped socket could otherwise read "live — scanning every block"
  /// beside a Status row saying *phone offline* — two truths on one surface,
  /// the exact disagreement C7 exists to forbid. The link decides whether the
  /// scan may claim liveness; the age only refines the claim.
  String _scanLine(BeaconState state) {
    final linkUp = state == BeaconState.connected;
    if (!_haveStatus || _blockAgeSecs == null) {
      return linkUp ? 'waiting for first block…' : 'not scanning — no link';
    }
    final age = _blockAgeSecs!;
    if (!linkUp) return '$age s since last block';
    if (age <= 5) return 'live — scanning every block';
    return '$age s since last block';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: GlassPanel(
        frosted: true,
        radius: const BorderRadius.vertical(
          top: Radius.circular(KvRadius.card),
        ),
        padding: const EdgeInsets.all(KvSpace.gutter),
        child: SingleChildScrollView(
          child: AnimatedBuilder(
            animation: Listenable.merge([
              widget.connected,
              widget.endpoint,
              widget.virtualDaaScore,
              widget.error,
              widget.lastUpdate,
              if (widget.reconnecting != null) widget.reconnecting!,
              if (widget.searching != null) widget.searching!,
              if (widget.osOffline != null) widget.osOffline!,
              if (widget.disconnectedAt != null) widget.disconnectedAt!,
            ]),
            builder: (context, _) {
              final last = widget.lastUpdate.value;
              final now = widget.clock();
              final age = last == null ? null : now.difference(last);
              final droppedAt = widget.disconnectedAt?.value;
              final busy = widget.reconnecting?.value ?? false;
              // C7 addendum: the button's busy state rides the HUNT, not the
              // dispatch. `reconnecting` clears the instant the race is spawned
              // (tens of ms, by design since R0) — a label that lives less than
              // a frame is a label nobody reads. `hunting` lasts as long as the
              // search actually does, and is the same bit the beacon renders.
              final hunting = busy || (widget.searching?.value ?? false);
              final state = evaluateBeacon(
                connected: widget.connected.value,
                age: age,
                error: widget.error.value,
                searching: hunting,
                osOffline: widget.osOffline?.value ?? false,
                sinceDrop: droppedAt == null ? null : now.difference(droppedAt),
              );
              final status = switch (state) {
                BeaconState.error => widget.error.value ?? 'connection error',
                BeaconState.offline => 'phone offline — no network',
                BeaconState.connecting => 'finding a node…',
                BeaconState.stale =>
                  age == null
                      ? 'no recent update'
                      : 'as of ${formatAge(age)} ago',
                BeaconState.connected => 'live',
              };
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Network', style: theme.textTheme.titleMedium),
                  const SizedBox(height: KvSpace.m),
                  _DetailRow(label: 'Status', value: status),
                  _DetailRow(
                    label: 'DAA score',
                    value: formatScore(widget.virtualDaaScore.value),
                    mono: true,
                  ),
                  _DetailRow(label: 'Transport scan', value: _scanLine(state)),
                  _DetailRow(
                    label: 'Node',
                    value: widget.endpoint.value ?? '—',
                    mono: true,
                  ),
                  const SizedBox(height: KvSpace.m),
                  if (widget.onReconnect != null)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        // Never disabled while hunting: a tap mid-search IS C4's
                        // kick, and greying the button out would delete that
                        // affordance exactly when the user most wants it. Repeat
                        // taps are already harmless — ChainService.reconnect()
                        // returns early while a dispatch is in flight.
                        onPressed: () {
                          KvHaptic.selection();
                          widget.onReconnect!();
                        },
                        icon: hunting
                            ? const KvLoader.inline()
                            : const Icon(Icons.refresh, size: 18),
                        // "Searching…", not "Reconnecting…": the hunt is just as
                        // often the engine's own (first connect, watchdog) as a
                        // user's tap, and this label must be true in all three.
                        label: Text(hunting ? 'Searching…' : 'Reconnect'),
                      ),
                    ),
                  const SizedBox(height: KvSpace.m),
                  Text(
                    'KaspaVerse talks to public Kaspa nodes directly — '
                    'no middlemen, no trackers.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: KvColor.textTertiary,
                      fontFamily: KvFont.ui,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.mono = false,
  });

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: KvSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            // Token-derived, not a bespoke dp. At 1.3× the labels wrap inside
            // this box; the scroll view above is what keeps that contained.
            width: KvSpace.xxl * 2,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: KvColor.textSecondary,
                fontFamily: KvFont.ui,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: mono
                  ? theme.textTheme.bodySmall
                  : theme.textTheme.bodySmall?.copyWith(fontFamily: KvFont.ui),
            ),
          ),
        ],
      ),
    );
  }
}
