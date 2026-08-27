import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../format.dart';
import '../theme/tokens.dart';
import '../widgets/kv_cadence.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_status_chip.dart';
import '../widgets/kv_surface.dart';
import '../widgets/status_beacon.dart' show formatAge;
import '../widgets/kv_toggle.dart';

/// Everything [NodeScreen] needs, as listenables and callbacks — the same
/// service-singleton → `ValueNotifier` shape the rest of `lib/src/ui` consumes,
/// so the screen is testable without a native library and there is exactly one
/// writer (`ChainService`) behind every value on it.
class NodeScope {
  const NodeScope({
    required this.connected,
    required this.activeEndpoint,
    required this.virtualDaaScore,
    required this.pinnedNode,
    required this.pinDropped,
    required this.setPinnedNode,
    required this.lastUpdate,
    this.searching,
    this.osOffline,
    this.reconnecting,
    this.refreshConfig,
  });

  final ValueListenable<bool> connected;

  /// The endpoint the socket is bound to right now, or null while dark. This
  /// is deliberately **not** the same value as [pinnedNode]: showing what the
  /// user chose beside what the link actually did is how they verify the pin
  /// rather than take our word for it (`NodeConfigDto`).
  final ValueListenable<String?> activeEndpoint;

  final ValueListenable<BigInt?> virtualDaaScore;

  /// The pinned node, or null for public discovery (the default).
  final ValueListenable<String?> pinnedNode;

  /// A stored pin was refused when the wallet loaded it.
  final ValueListenable<bool> pinDropped;

  /// Pin the wallet to one node, or clear the pin with null (D-187).
  ///
  /// **Rust validates, persists and re-links.** Dart never parses a URL and
  /// never decides what a pin means — a second, weaker guard on this side is
  /// precisely the thing INV-9's reasoning forbids. This throws, and the throw
  /// is the message the user must see.
  final Future<void> Function(String? url) setPinnedNode;

  final ValueListenable<bool>? searching;
  final ValueListenable<bool>? osOffline;
  final ValueListenable<bool>? reconnecting;

  /// When the last fresh snapshot landed. BG-8 requires a dimmed reading to
  /// carry a **visible age**: `ChainService` deliberately keeps the last-known
  /// DAA when a dropped link emits nulls, which is only honest if the screen
  /// says the number is old.
  ///
  /// **Required, deliberately.** It was optional for one revision and the sole
  /// production factory took the option, so every disconnect would have
  /// captioned a ninety-second-old score `never updated` — an assertion worse
  /// than the dimming it was meant to explain, and one no widget test could
  /// see because the fixtures all pass it. Required makes the omission a
  /// compile error instead of a caption.
  final ValueListenable<DateTime?> lastUpdate;

  /// Re-read the node choice from Rust so the surface can open cold and paint
  /// the truth rather than the last thing the app happened to see.
  final Future<void> Function()? refreshConfig;
}

/// **Node & connection** — the INV-8 escape hatch, made reachable.
///
/// The sovereign-node line (D-187) shipped the Rust validation, the bridge and
/// the service seam gate-green with no way for a user to get to any of it. This
/// is that way. A sovereignty statement wearing a diagnostic's precision: who
/// serves you, how freshly, and the standing offer to serve yourself.
class NodeScreen extends StatefulWidget {
  const NodeScreen({super.key, required this.scope, this.clock = DateTime.now});

  final NodeScope scope;

  /// Injectable so a test can render a fixed age rather than race the wall
  /// clock — the same seam `NetworkSheet` and `HomeScreen` take.
  final DateTime Function() clock;

  @override
  State<NodeScreen> createState() => _NodeScreenState();
}

class _NodeScreenState extends State<NodeScreen> {
  final TextEditingController _url = TextEditingController();

  /// What the last attempt to pin or unpin said, in plain English. Null while
  /// nothing has gone wrong.
  String? _problem;
  bool _busy = false;

  /// The user has asked for a pinned node, whether or not one is live yet.
  bool _wantPin = false;

  /// What the field was seeded with. While the text still equals this, the
  /// user has not typed and a fresher pin from Rust may replace it; the moment
  /// they have, their draft wins.
  String _seeded = '';

  @override
  void initState() {
    super.initState();
    _seeded = widget.scope.pinnedNode.value ?? '';
    _url.text = _seeded;
    _wantPin = widget.scope.pinnedNode.value != null;
    // Open cold and paint the truth (BG-8): the notifiers may be carrying
    // whatever the last poll saw, and a node surface that shows a stale pin is
    // the one lie this whole feature exists to prevent.
    widget.scope.refreshConfig?.call().then((_) {
      if (!mounted) return;
      final live = widget.scope.pinnedNode.value;
      // Only while the field is untouched. Adopting on `isEmpty` alone left a
      // stale pin standing in the box beside the fresh one in the reading —
      // with Apply lit, offering to re-pin the address that had just changed.
      if (_url.text == _seeded && (live ?? '') != _seeded) {
        setState(() {
          _seeded = live ?? '';
          _url.text = _seeded;
          _wantPin = live != null;
        });
      }
    });
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  /// Errors from the seam are **not** all the same failure, and telling the
  /// user the wrong one is worse than saying nothing.
  ///
  /// `dagSetNodeConfig` persists and applies a validated URL *before* the first
  /// dial, so a throw means either *rejected at validation* (nothing changed)
  /// or *accepted, and the first dial failed* (the pin is live and its retry
  /// loop is running). The service refreshes the config on both arms, so after
  /// the throw the notifier itself distinguishes them — which is why this reads
  /// [NodeScope.pinnedNode] rather than guessing from the message.
  Future<void> _apply(String? url) async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await widget.scope.setPinnedNode(url);
      if (!mounted) return;
      setState(() => _problem = null);
    } catch (e) {
      if (!mounted) return;
      final live = widget.scope.pinnedNode.value;
      setState(() {
        // Three beats, every time: what happened → what it means for your
        // funds → what to do (BG-11).
        if (url == null) {
          // Clearing has the same two outcomes as pinning, for the same
          // reason: `save` writes the cleared config BEFORE the monitor is
          // reached, so a throw can arrive with the pin already gone. Resolve
          // it the same way — by reading what is live, never by trusting
          // which call threw.
          _url.text = live ?? '';
          _problem = live == null
              ? 'The pin is cleared, but the wallet has not moved off that '
                    'node yet. Your money is safe — nothing was sent. It '
                    'changes over on the next reconnect: $e'
              : 'The pin could not be cleared, so you are still on the node '
                    'below. Your money is safe — nothing was sent. Try '
                    'again: $e';
        } else if (live == url) {
          // The seam persists and applies a validated URL BEFORE its first
          // dial, so this branch means the pin is LIVE and its retry loop is
          // running. Saying "not accepted" here would be the opposite of true.
          _problem =
              'Pinned, but the wallet has not reached it yet. Your money is '
              'safe — nothing was sent. It keeps trying: $e';
        } else {
          _problem = 'That node was not accepted, so nothing changed. $e';
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// How old the last snapshot is, in the shipped `formatAge` wording. Falls
  /// back to naming the absence rather than inventing a duration.
  String _ageLabel() {
    final last = widget.scope.lastUpdate.value;
    if (last == null) return 'never updated';
    return 'as of ${formatAge(widget.clock().difference(last))} ago';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            // BG-14: the top 52dp belongs to the real system status bar.
            const SizedBox(height: KvSpace.statusBarReserve),
            _Rail(onBack: () => Navigator.of(context).maybePop()),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  KvSpace.gutter,
                  KvSpace.m,
                  KvSpace.gutter,
                  KvSpace.xxl,
                ),
                children: [
                  const _RuledLabel('Serving you'),
                  const SizedBox(height: KvSpace.s),
                  _servingPlate(),
                  const SizedBox(height: KvSpace.l),
                  const _RuledLabel('Use my own node'),
                  const SizedBox(height: KvSpace.s),
                  _picker(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _servingPlate() {
    final s = widget.scope;
    return AnimatedBuilder(
      animation: Listenable.merge([
        s.connected,
        s.activeEndpoint,
        s.virtualDaaScore,
        s.pinnedNode,
        s.pinDropped,
        if (s.searching != null) s.searching!,
        if (s.osOffline != null) s.osOffline!,
        if (s.reconnecting != null) s.reconnecting!,
      ]),
      builder: (context, _) {
        final connected = s.connected.value;
        final offline = s.osOffline?.value ?? false;
        final hunting =
            (s.searching?.value ?? false) || (s.reconnecting?.value ?? false);
        final endpoint = s.activeEndpoint.value;
        final pinned = s.pinnedNode.value;

        // Hunting outranks connected, and the order is the point: the socket
        // can be alive in the snapshot while a race bounces it underneath
        // (`ChainService._linkTick`). Reading `connected` first would print
        // "Answering" beside a meter that is visibly searching — the words and
        // the cadence disagreeing about one link, which is the exact split C7
        // forbids and the P0.3 scar cost.
        final (KvLampTone tone, String words) = switch (true) {
          _ when offline => (KvLampTone.warn, 'Your phone has no network.'),
          _ when hunting => (KvLampTone.warn, 'Looking for a node…'),
          _ when connected => (
            KvLampTone.ok,
            pinned == null
                ? 'Answering — a public community node.'
                : 'Answering — the node you pinned.',
          ),
          _ => (KvLampTone.warn, 'No node is answering yet.'),
        };

        return KvSurface(
          padding: const EdgeInsets.all(KvSpace.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      endpoint ?? 'not connected',
                      maxLines: 2,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        fontFamily: KvFont.mono,
                        fontSize: 13,
                        height: 18 / 13,
                        color: endpoint == null ? KvColor.inkMeta : KvColor.ink,
                      ),
                    ),
                  ),
                  const SizedBox(width: KvSpace.s),
                  // Motion means something is happening (D-192): the meter runs
                  // while the link is being hunted and freezes the rest of the
                  // time, including on a healthy screen.
                  KvCadence(running: hunting || (!connected && !offline)),
                ],
              ),
              const SizedBox(height: KvSpace.sm),
              KvStatusChip(tone: tone, words: words, maxLines: null),
              const SizedBox(height: KvSpace.sm),
              Container(height: 1, color: KvColor.plateDivider),
              // BG-8, all three states. `ChainService` deliberately KEEPS the
              // last-known score when a dropped link emits nulls — which is
              // only honest if the screen dims it and says how old it is. A
              // disconnected reading at full brightness is the P0.3 scar.
              _Reading(
                label: 'DAA',
                value: formatScore(s.virtualDaaScore.value),
                stale: !connected,
                age: connected ? null : _ageLabel(),
              ),
              if (pinned != null)
                _Reading(label: 'You pinned', value: pinned, wrap: true),
            ],
          ),
        );
      },
    );
  }

  Widget _picker() {
    final s = widget.scope;
    return AnimatedBuilder(
      animation: Listenable.merge([s.pinnedNode, s.pinDropped]),
      builder: (context, _) {
        final pinned = s.pinnedNode.value;
        final dropped = s.pinDropped.value;
        // The switch reads as "I want my own node", which is true the moment
        // the user asks for it and stays true while a pin exists. Deriving it
        // from `pinned` alone made turning it ON do nothing visible, because
        // asking for a pin and having one are not the same state.
        final on = _wantPin || pinned != null;
        final typed = _url.text.trim();
        final canApply = !_busy && typed.isNotEmpty && typed != pinned;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            KvToggle(
              on: on,
              title: 'Pin a node I run',
              sub: pinned != null
                  ? 'A pinned node never silently falls back to a public one.'
                  : 'The wallet reaches Kaspa through public community nodes. '
                        'Pin your own and it will use nothing else.',
              disabledReason: 'Setting the node…',
              // Turning it on pins nothing yet — there is no address to pin. It
              // opens the field, and the pin happens when the user says which
              // node. Turning it off clears the pin at once: that is the safe
              // direction and it needs no second step.
              onChanged: _busy
                  ? null
                  : (next) {
                      setState(() => _wantPin = next);
                      if (!next) {
                        _url.clear();
                        if (pinned != null) _apply(null);
                      }
                    },
            ),
            if (dropped) ...[
              const SizedBox(height: KvSpace.sm),
              const KvStatusChip(
                tone: KvLampTone.warn,
                plated: true,
                maxLines: null,
                words:
                    'The node you pinned was refused when the wallet started, '
                    'so you are back on public nodes. Your money is safe. '
                    'Check the address below and set it again.',
              ),
            ],
            if (on) ...[
              const SizedBox(height: KvSpace.sm),
              _UrlField(
                controller: _url,
                enabled: !_busy,
                onChanged: () => setState(() {}),
                onSubmitted: canApply ? () => _apply(typed) : null,
              ),
              const SizedBox(height: KvSpace.s),
              _Apply(
                busy: _busy,
                enabled: canApply,
                // BG-12: a disabled control always says why, in words.
                reason: _busy
                    ? 'Setting the node…'
                    : typed.isEmpty
                    ? 'Type the address of your node first.'
                    : 'This is already the node you pinned.',
                onTap: () => _apply(typed),
              ),
            ],
            if (_problem != null) ...[
              const SizedBox(height: KvSpace.sm),
              KvStatusChip(
                tone: KvLampTone.warn,
                plated: true,
                maxLines: null,
                words: _problem!,
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(KvSpace.m, KvSpace.s, KvSpace.m, 0),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: 'Back',
            child: InkWell(
              onTap: onBack,
              borderRadius: BorderRadius.circular(KvRadius.control),
              child: const SizedBox(
                width: KvSpace.touchTarget,
                height: KvSpace.touchTarget,
                child: Center(
                  child: RotatedBox(
                    quarterTurns: 2,
                    child: KvGlyphIcon(KvMark.chevron, tone: KvColor.inkNav),
                  ),
                ),
              ),
            ),
          ),
          // Expanded rather than two Spacers: at 1.3x on a 320dp screen the
          // title is wider than what is left between two 48dp targets, and a
          // Spacer cannot give any of it back. A label WRAPS (BG-14); only a
          // number is forbidden from doing so.
          const Expanded(
            child: Text(
              'Node & connection',
              textAlign: TextAlign.center,
              maxLines: 2,
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: KvColor.inkDim,
              ),
            ),
          ),
          // Balances the back target so the title sits centred.
          const SizedBox(width: KvSpace.touchTarget),
        ],
      ),
    );
  }
}

/// A tick, then a sentence-case label — where an instrument silk-screens the
/// name of a section.
class _RuledLabel extends StatelessWidget {
  const _RuledLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(width: KvSpace.s, height: 1, color: KvColor.inkMeta),
      const SizedBox(width: KvSpace.s),
      // Flexible for the same reason as the rail's title: at 1.3x this label
      // is wider than a 320dp gutter leaves it.
      Flexible(
        child: Text(
          text,
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 13,
            height: 18 / 13,
            color: KvColor.inkDim,
          ),
        ),
      ),
    ],
  );
}

/// A label and its reading. Mono and tabular on the value, because every value
/// on this screen is an identifier or a counter.
class _Reading extends StatelessWidget {
  const _Reading({
    required this.label,
    required this.value,
    this.wrap = false,
    this.stale = false,
    this.age,
  });

  final String label;
  final String value;
  final bool wrap;

  /// Dims to [KvFreshness.opacityStale] — dimmed cached truth beats a shimmer,
  /// and beats a confident number nobody can vouch for (BG-8).
  final bool stale;

  /// How old the reading is, in words. BG-8 requires this whenever [stale].
  final String? age;

  @override
  Widget build(BuildContext context) {
    assert(
      !stale || age != null,
      'A dimmed reading carries a visible age (BG-8) — dimming alone says '
      '"old" without saying how old, which is the half-truth the law names.',
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: KvSpace.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: KvSpace.xxl * 2,
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 13,
                height: 18 / 13,
                color: KvColor.inkMeta,
              ),
            ),
          ),
          Expanded(
            child: Opacity(
              opacity: stale ? KvFreshness.opacityStale : 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    maxLines: wrap ? 3 : 1,
                    overflow: TextOverflow.clip,
                    style: const TextStyle(
                      fontFamily: KvFont.mono,
                      fontSize: 13,
                      height: 18 / 13,
                      color: KvColor.ink,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (age != null)
                    Text(
                      age!,
                      style: const TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 12,
                        height: 17 / 12,
                        color: KvColor.inkMeta,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The node address, typed.
///
/// A bare [TextField] inside a control surface rather than an
/// [InputDecorator]: the decorator resolves `bodyLarge` and `labelStyle` from
/// the theme, which is a live divergence UX-6 owns — and a field this screen
/// can draw itself has no reason to wait for it. The **mono** face is right
/// here on its own merits: a node URL is an identifier to be compared
/// character by character, exactly like an address.
class _UrlField extends StatelessWidget {
  const _UrlField({
    required this.controller,
    required this.enabled,
    required this.onChanged,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return KvSurface.control(
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.m,
        vertical: KvSpace.xs,
      ),
      child: TextField(
        controller: controller,
        enabled: enabled,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.done,
        onChanged: (_) => onChanged(),
        onSubmitted: (_) => onSubmitted?.call(),
        style: const TextStyle(
          fontFamily: KvFont.mono,
          fontSize: 13,
          height: 20 / 13,
          color: KvColor.ink,
        ),
        decoration: const InputDecoration(
          border: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: KvSpace.sm),
          hintText: 'ws://192.168.1.40:17110',
          hintStyle: TextStyle(
            fontFamily: KvFont.mono,
            fontSize: 13,
            height: 20 / 13,
            color: KvColor.inkMeta,
          ),
        ),
      ),
    );
  }
}

/// Names the action and its object (BG-11), and says why it cannot be pressed
/// when it cannot be pressed (BG-12).
class _Apply extends StatelessWidget {
  const _Apply({
    required this.busy,
    required this.enabled,
    required this.reason,
    required this.onTap,
  });

  final bool busy;
  final bool enabled;
  final String reason;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          enabled: enabled,
          label: 'Use this node',
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(KvRadius.control),
            child: KvSurface.control(
              width: double.infinity,
              height: KvSpace.control,
              alignment: Alignment.center,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (busy) ...[
                    const KvCadence(running: true),
                    const SizedBox(width: KvSpace.s),
                  ],
                  Text(
                    'Use this node',
                    style: TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: enabled ? KvColor.inkBright : KvColor.inkMeta,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!enabled) ...[
          const SizedBox(height: KvSpace.xs),
          Text(
            reason,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 12,
              height: 17 / 12,
              color: KvColor.inkMeta,
            ),
          ),
        ],
      ],
    );
  }
}
