import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/rate_service.dart' show KvRateQuote;
import '../error_text.dart';
import '../format.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_cadence.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_status_chip.dart';
import '../widgets/kv_streaming_count.dart';
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
    this.onReconnect,
    this.refreshConfig,
    this.blockAgeSecs,
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

  /// The user's own "try now" — since P0b (D-213) a bounded find-then-swap
  /// hunt behind the live bind rather than the drop-then-hunt it was named
  /// for; [_Reconnect] carries which of the three things a tap actually does.
  ///
  /// **It lands here because the money screen's only node door is this
  /// screen.** UX-2 replaced the home beacon with the plate's network chip,
  /// which opens this surface, and UX-3 then collapsed the network sheet into
  /// it — so this is now the single site. Leaving it only on the sheet would
  /// have put the escape hatch three taps from the screen where a dead link is
  /// actually noticed. The watchdog reconnects on its own either way —
  /// this is agency, not the only path.
  final Future<void> Function()? onReconnect;

  /// Re-read the node choice from Rust so the surface can open cold and paint
  /// the truth rather than the last thing the app happened to see.
  final Future<void> Function()? refreshConfig;

  /// Seconds since the node last handed us a block, polled while this screen
  /// is open — the transport scan's own freshness.
  ///
  /// **Carried across from `NetworkSheet` when UX-3 collapsed the two
  /// surfaces**, and it is the one thing that sheet rendered and this screen
  /// did not. Dropping it would have made the sovereign path the poorer one
  /// (D-207 clause c): a user who came here to understand their link would
  /// have lost the most precise liveness signal the app has by the surface
  /// being merged rather than by anyone deciding to remove it.
  final Future<int?> Function()? blockAgeSecs;
}

/// Where a transaction or an address opens when a link leads out of the
/// wallet — **a template, never a vendor list** (D-207, amending D-192's
/// closed two-vendor choice: a list only we can edit is not a sovereignty
/// decision either).
class ExplorerScope {
  const ExplorerScope({required this.read, required this.write});

  /// `(txTemplate, addressTemplate, defaults)`. The defaults are one-tap
  /// starting points, not the only options.
  final Future<ExplorerChoice> Function() read;

  /// Persist both templates. **Rust validates** — Dart builds and parses no
  /// URL — so this throws with the refusal the user must read.
  final Future<void> Function(String txTemplate, String addressTemplate) write;
}

/// The explorer choice as the surface needs it.
@immutable
class ExplorerChoice {
  const ExplorerChoice({
    required this.txTemplate,
    required this.addressTemplate,
    required this.defaults,
  });

  final String txTemplate;
  final String addressTemplate;
  final List<ExplorerOption> defaults;
}

/// One shipped explorer, offered and replaceable.
@immutable
class ExplorerOption {
  const ExplorerOption({
    required this.name,
    required this.txTemplate,
    required this.addressTemplate,
  });

  final String name;
  final String txTemplate;
  final String addressTemplate;
}

/// The fiat rate — the one claim in this app consensus cannot re-verify, and
/// therefore the one with a switch on it (INV-8's carve-out, D-191).
class RateScope {
  const RateScope({
    required this.enabled,
    required this.endpoint,
    required this.defaultEndpoint,
    required this.quote,
    required this.error,
    required this.setConfig,
    required this.load,
  });

  /// `null` until the stored posture has been read.
  final ValueListenable<bool?> enabled;
  final ValueListenable<String> endpoint;
  final ValueListenable<String> defaultEndpoint;

  /// The live price, or null — which is what `—` means on the money plate.
  final ValueListenable<KvRateQuote?> quote;

  /// Why the last fetch produced nothing. Shown here, where the source is
  /// chosen, and never on the money plate (D-193).
  final ValueListenable<String?> error;

  /// Throws the bridge's refusal — an endpoint is validated in Rust.
  final Future<void> Function({required bool enabled, required String endpoint})
  setConfig;

  /// Re-read the stored posture so this surface opens cold on the truth.
  final Future<void> Function() load;
}

/// **Node & connection** — the INV-8 escape hatch, made reachable.
///
/// The sovereign-node line (D-187) shipped the Rust validation, the bridge and
/// the service seam gate-green with no way for a user to get to any of it. This
/// is that way. A sovereignty statement wearing a diagnostic's precision: who
/// serves you, how freshly, and the standing offer to serve yourself.
class NodeScreen extends StatefulWidget {
  const NodeScreen({
    super.key,
    required this.scope,
    this.explorer,
    this.rate,
    this.clock = DateTime.now,
  });

  final NodeScope scope;

  /// The explorer choice. Absent ⇒ the section does not render, rather than
  /// rendering dead: a control wired to nothing is a drawing of a feature
  /// wearing a real screen (D-206).
  final ExplorerScope? explorer;

  /// The fiat rate's source. Absent ⇒ the section does not render.
  final RateScope? rate;

  /// Injectable so a test can render a fixed age rather than race the wall
  /// clock — the same seam `HomeScreen` takes.
  final DateTime Function() clock;

  @override
  State<NodeScreen> createState() => _NodeScreenState();
}

class _NodeScreenState extends State<NodeScreen> {
  final TextEditingController _url = TextEditingController();

  /// The explorer's two templates, as typed. Separate controllers because a
  /// transaction page and an address page are different paths on every
  /// explorer that has both.
  final TextEditingController _txTemplate = TextEditingController();
  final TextEditingController _addressTemplate = TextEditingController();

  /// The rate's source, as typed.
  final TextEditingController _rateEndpoint = TextEditingController();

  /// What the last attempt to pin or unpin said, in plain English. Null while
  /// nothing has gone wrong.
  String? _problem;
  bool _busy = false;

  /// Refusals from the two preference sections, kept apart from [_problem] so
  /// a rejected explorer template never overwrites what the link just said.
  String? _explorerProblem;
  String? _rateProblem;
  bool _explorerBusy = false;
  bool _rateBusy = false;

  /// The stored explorer choice, once read. Null until the first read lands —
  /// the section paints its fields from the seam, never from a guess.
  ExplorerChoice? _explorerChoice;

  /// The user has asked for a pinned node, whether or not one is live yet.
  bool _wantPin = false;

  /// What the field was seeded with. While the text still equals this, the
  /// user has not typed and a fresher pin from Rust may replace it; the moment
  /// they have, their draft wins.
  String _seeded = '';

  /// The transport scan's freshness, polled while this screen is open, and
  /// whether a poll has ever landed. Both, because "0 s since the last block"
  /// and "we have never been told" are different sentences (the sheet's own
  /// `_haveStatus` distinction, carried across).
  int? _blockAgeSecs;
  bool _haveBlockAge = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _seeded = widget.scope.pinnedNode.value ?? '';
    _url.text = _seeded;
    _wantPin = widget.scope.pinnedNode.value != null;
    _startScanPoll();
    _loadExplorer();
    _loadRate();
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
    _poll?.cancel();
    _url.dispose();
    _txTemplate.dispose();
    _addressTemplate.dispose();
    _rateEndpoint.dispose();
    super.dispose();
  }

  /// Poll the honest block-age while this screen is open — the scan runs on
  /// every block, so the block-age IS its freshness (the sheet's 2 s cadence,
  /// unchanged). Absent seam ⇒ no poll and no line, never a fabricated age.
  void _startScanPoll() {
    final read = widget.scope.blockAgeSecs;
    if (read == null) return;
    unawaited(_refreshScan());
    _poll = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refreshScan()),
    );
  }

  Future<void> _refreshScan() async {
    final read = widget.scope.blockAgeSecs;
    if (read == null) return;
    try {
      final age = await read();
      if (!mounted) return;
      setState(() {
        _blockAgeSecs = age;
        _haveBlockAge = true;
      });
    } catch (_) {
      // A failed pull leaves the last-known age standing; never crash the
      // screen a user opened to diagnose a link.
    }
  }

  Future<void> _loadExplorer() async {
    final scope = widget.explorer;
    if (scope == null) return;
    try {
      final choice = await scope.read();
      if (!mounted) return;
      setState(() {
        _explorerChoice = choice;
        // Only while untouched — the same rule the node field follows: a
        // fresher read must never overwrite a draft mid-edit.
        if (_txTemplate.text.isEmpty) _txTemplate.text = choice.txTemplate;
        if (_addressTemplate.text.isEmpty) {
          _addressTemplate.text = choice.addressTemplate;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _explorerProblem = displayError(e));
    }
  }

  Future<void> _loadRate() async {
    final scope = widget.rate;
    if (scope == null) return;
    try {
      await scope.load();
    } catch (_) {
      // The notifiers keep whatever they last knew.
    }
    if (!mounted) return;
    if (_rateEndpoint.text.isEmpty) {
      // `setState`, not a bare assignment: the section decides whether to show
      // the field by comparing the FIELD against the shipped default, and a
      // controller write notifies the controller's own listeners, not this
      // build. Without it the section kept the frame it painted before the
      // config arrived — an empty field standing open on a wallet whose rate
      // is simply off.
      setState(() => _rateEndpoint.text = scope.endpoint.value);
    }
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

  /// The transport-scan liveness line, in the sheet's shipped wording (D-196:
  /// take the copy verbatim — a redesign changes form, not voice).
  ///
  /// The scan runs on every block, so the block-age IS its freshness, and the
  /// line is honest about "never" before the first one lands.
  String _scanLine({required bool connected}) {
    if (!_haveBlockAge || _blockAgeSecs == null) {
      return connected ? 'waiting for first block…' : 'not scanning — no link';
    }
    final age = _blockAgeSecs!;
    if (!connected) return '$age s since last block';
    if (age <= 5) return 'live — scanning every block';
    return '$age s since last block';
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
            KvRail(
              title: 'Node & connection',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  KvSpace.gutter,
                  KvSpace.m,
                  KvSpace.gutter,
                  KvSpace.xxl,
                ),
                children: [
                  const KvRuledLabel('Serving you'),
                  const SizedBox(height: KvSpace.s),
                  _servingPlate(),
                  _reconnect(),
                  const SizedBox(height: KvSpace.sm),
                  // BG-17 / ux-auditor 30: every endpoint row states what that
                  // endpoint can see and what it can lie about. A node is the
                  // strongest of the three because its answers are checked —
                  // and saying so is what makes the other two labels mean
                  // something by contrast.
                  const _TrustLabel(
                    'A node hands you blocks and takes your signed '
                    'transactions. It can go quiet or fall behind, and it sees '
                    'the addresses you ask about — it cannot forge a balance, '
                    'change an amount, or spend anything.',
                  ),
                  const SizedBox(height: KvSpace.l),
                  const KvRuledLabel('Use my own node'),
                  const SizedBox(height: KvSpace.s),
                  _picker(),
                  ..._explorerSection(),
                  ..._rateSection(),
                  const SizedBox(height: KvSpace.l),
                  // The F9d fix (D-207 clause a): the shipped line read
                  // *"KaspaVerse talks to public Kaspa nodes directly — no
                  // middlemen, no trackers"*, which was true of the money and
                  // false of the page it now shares with a price source. An
                  // unqualified promise beside two named egresses is the
                  // census contradicting itself.
                  const _TrustLabel(
                    'Nothing else reaches out. Your balance, your history and '
                    'your sends go to a Kaspa node and nowhere else — the '
                    'price source and the explorer above are the only other '
                    'places this app can reach, and both are yours to change '
                    'or switch off.',
                  ),
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
        //
        // Connected AND hunting is no longer that contradiction, though: since
        // P0b it is the swap hunt, where the link genuinely IS working while a
        // bounded errand looks for a different node behind it. Rendering that
        // as *Looking for a node…* would understate a wallet that can spend
        // right now — so it gets its own arm, ABOVE the dark-hunt one, and
        // says both halves of the truth.
        final (KvLampTone tone, String words) = switch (true) {
          _ when offline => (KvLampTone.warn, 'Your phone has no network.'),
          _ when connected && hunting => (
            KvLampTone.ok,
            'Answering — and looking for a different node. This one keeps '
                'working until another answers.',
          ),
          _ when hunting => (KvLampTone.warn, 'Looking for a node…'),
          // **The directory is named where it acts** (D-207 census; founder
          // call 2026-08-27). "A public community node" said which KIND of
          // node was answering and left out who chose it — and the PNN
          // resolver walk was the census's first unnamed row. A user cannot
          // consent to a discovery service they have never been told exists.
          _ when connected => (
            KvLampTone.ok,
            pinned == null
                ? 'Answering — a public community node, found for you by the '
                      'public node directory.'
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
              // **Streamed, not stepped** (BG-18 / D-226) — the same law as
              // the money plate's chain clock. It was MISSED here in the first
              // pass: the fix went to the surface being looked at rather than
              // to every surface that renders a DAA, which is L83's shape, and
              // the founder caught it on glass. `formatScore` still renders
              // DS-1's dash when there is no reading at all.
              KvStreamingCount(
                value: s.virtualDaaScore.value,
                stalled: !connected,
                builder: (context, shown) => _Reading(
                  label: 'DAA',
                  value: formatScore(shown),
                  stale: !connected,
                  age: connected ? null : _ageLabel(),
                ),
              ),
              // The sheet's scan line, carried across intact. *Live* is a
              // claim about the LINK, not about the age alone: this line
              // rides a 2 s poll while the link notifiers are pushed, so a
              // just-dropped socket could otherwise read "live — scanning
              // every block" beside a status chip saying the phone is
              // offline. The link decides whether the scan may claim
              // liveness; the age only refines the claim (C7).
              if (s.blockAgeSecs != null)
                _Reading(
                  label: 'Transport scan',
                  // The `!hunting` term SURVIVES find-then-swap (P0b), on
                  // purpose. A swap hunt genuinely is scanning while it runs,
                  // so this line understates it — but the moment a winner
                  // lands, `install_bind` retires the incumbent and Dart's
                  // snapshot can still read `connected` for up to one poll.
                  // *live — scanning every block* is the strongest claim on
                  // this screen; understating it for a few seconds costs the
                  // user nothing, and overstating it across a cut-over is the
                  // P0.3 scar. The lamp above carries the swap's good news.
                  value: _scanLine(
                    connected: connected && !hunting && !offline,
                  ),
                  numeric: false,
                ),
              if (pinned != null)
                _Reading(label: 'You pinned', value: pinned, wrap: true),
            ],
          ),
        );
      },
    );
  }

  /// The user's own "try now", under the plate that says who is answering.
  ///
  /// Absent when the seam is not wired, rather than present and dead: BG-12
  /// forbids a disabled control with no stated reason, and "no callback" is
  /// not a reason anyone can act on.
  Widget _reconnect() {
    final s = widget.scope;
    final tap = s.onReconnect;
    if (tap == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: Listenable.merge([
        s.connected,
        s.pinnedNode,
        if (s.searching != null) s.searching!,
        if (s.reconnecting != null) s.reconnecting!,
      ]),
      builder: (context, _) {
        // The busy state rides the HUNT, not the dispatch: `reconnecting`
        // clears the instant the race is spawned (tens of ms, by design since
        // R0), and a label that lives less than a frame is a label nobody
        // reads. `searching` lasts as long as the search actually does — the
        // same bit the money plate's cadence renders.
        final hunting =
            (s.searching?.value ?? false) || (s.reconnecting?.value ?? false);
        return Padding(
          padding: const EdgeInsets.only(top: KvSpace.sm),
          child: _Reconnect(
            hunting: hunting,
            connected: s.connected.value,
            pinned: s.pinnedNode.value != null,
            onTap: () => unawaited(tap()),
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
            // The startup refusal yields to a FRESHER answer: once the user
            // has acted and been told what happened, restating the boot-time
            // notice beside it is the same fact twice, in two amber plates,
            // spending an emission to say nothing new (D-192 / BG-2).
            if (dropped && _problem == null) ...[
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
              _Action(
                label: 'Use this node',
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

  /// **Where a link out of the wallet goes** — two templates, freely
  /// replaceable, with the two audited defaults as one-tap starting points.
  ///
  /// Returns an empty list when the seam is absent, so the section is missing
  /// rather than dead (`_reconnect`'s rule).
  List<Widget> _explorerSection() {
    final scope = widget.explorer;
    final choice = _explorerChoice;
    if (scope == null) return const [];
    final tx = _txTemplate.text.trim();
    final address = _addressTemplate.text.trim();
    final unchanged =
        choice != null &&
        tx == choice.txTemplate &&
        address == choice.addressTemplate;
    final canSave =
        !_explorerBusy && tx.isNotEmpty && address.isNotEmpty && !unchanged;
    return [
      const SizedBox(height: KvSpace.l),
      const KvRuledLabel('Explorer'),
      const SizedBox(height: KvSpace.s),
      // The defaults are offered, never enforced. `kas.fyi` — which the design
      // export named — has shut down, and a closed list is how that becomes
      // the user's problem instead of ours (D-192 → D-207).
      if (choice != null && choice.defaults.isNotEmpty)
        Wrap(
          spacing: KvSpace.s,
          runSpacing: KvSpace.s,
          children: [
            for (final option in choice.defaults)
              _Pick(
                label: option.name,
                selected:
                    tx == option.txTemplate &&
                    address == option.addressTemplate,
                onTap: _explorerBusy
                    ? null
                    : () {
                        KvHaptic.selection();
                        setState(() {
                          _txTemplate.text = option.txTemplate;
                          _addressTemplate.text = option.addressTemplate;
                        });
                      },
              ),
          ],
        ),
      const SizedBox(height: KvSpace.sm),
      _UrlField(
        controller: _txTemplate,
        enabled: !_explorerBusy,
        hint: 'https://explorer.example/txs/{txid}',
        label: 'Transaction link',
        onChanged: () => setState(() {}),
        onSubmitted: canSave ? _saveExplorer : null,
      ),
      const SizedBox(height: KvSpace.s),
      _UrlField(
        controller: _addressTemplate,
        enabled: !_explorerBusy,
        hint: 'https://explorer.example/addresses/{address}',
        label: 'Address link',
        onChanged: () => setState(() {}),
        onSubmitted: canSave ? _saveExplorer : null,
      ),
      const SizedBox(height: KvSpace.s),
      _Action(
        label: 'Use this explorer',
        enabled: canSave,
        // BG-12: a disabled control always says why, in words.
        reason: _explorerBusy
            ? 'Saving…'
            : tx.isEmpty || address.isEmpty
            ? 'Both links need an address before they can be saved.'
            : 'These are already your explorer links.',
        onTap: _saveExplorer,
      ),
      if (_explorerProblem != null) ...[
        const SizedBox(height: KvSpace.s),
        _Fault(_explorerProblem!),
      ],
      const SizedBox(height: KvSpace.sm),
      const _TrustLabel(
        'An explorer is an outbound link and nothing more. Opening one hands '
        'that site the id you are looking at and the network address you are '
        'looking from; it shows you its own view of the chain, and nothing it '
        'says is ever read back into this wallet.',
      ),
    ];
  }

  Future<void> _saveExplorer() async {
    final scope = widget.explorer;
    if (scope == null || _explorerBusy) return;
    setState(() {
      _explorerBusy = true;
      _explorerProblem = null;
    });
    try {
      await scope.write(_txTemplate.text.trim(), _addressTemplate.text.trim());
      await _loadExplorer();
    } catch (e) {
      if (mounted) setState(() => _explorerProblem = displayError(e));
    } finally {
      if (mounted) setState(() => _explorerBusy = false);
    }
  }

  /// **The one claim consensus cannot check**, with its switch beside it.
  List<Widget> _rateSection() {
    final scope = widget.rate;
    if (scope == null) return const [];
    return [
      const SizedBox(height: KvSpace.l),
      const KvRuledLabel('Fiat value'),
      const SizedBox(height: KvSpace.s),
      AnimatedBuilder(
        animation: Listenable.merge([
          scope.enabled,
          scope.endpoint,
          scope.quote,
          scope.error,
        ]),
        builder: (context, _) {
          final posture = scope.enabled.value;
          // Not yet read: say so, and offer no control. A toggle drawn `off`
          // over a posture nobody has read yet is a switch reporting a state
          // it does not know (`wallet-security-auditor`).
          if (posture == null) {
            return const _TrustLabel('Reading your setting…');
          }
          final on = posture;
          final typed = _rateEndpoint.text.trim();
          final canSave =
              !_rateBusy && typed.isNotEmpty && typed != scope.endpoint.value;
          final quote = scope.quote.value;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KvToggle(
                on: on,
                title: 'Show what your balance is worth',
                sub: on
                    ? 'A dollar figure sits under your balance. It never '
                          'prices a fee, sizes a send, or appears on anything '
                          'you sign.'
                    : 'Your balance is shown in KAS only. Nothing is fetched '
                          'and no price source is contacted.',
                disabledReason: 'Saving…',
                onChanged: _rateBusy
                    ? null
                    : (next) => unawaited(
                        _saveRate(
                          enabled: next,
                          endpoint: scope.endpoint.value,
                        ),
                      ),
              ),
              // **The field appears whenever there is something to repair**,
              // not only while the rate is on. A stored endpoint Rust refuses
              // loads as `enabled: false` with the bad endpoint KEPT — so that
              // the row can show what was refused — and gating the field on
              // `on` hid the only control that could fix it: turning the
              // toggle back on re-posts the same bad endpoint, is refused
              // again, and leaves the user in a loop with no field
              // (`consensus-auditor`, this sitting).
              if (on || typed != scope.defaultEndpoint.value) ...[
                const SizedBox(height: KvSpace.sm),
                _UrlField(
                  controller: _rateEndpoint,
                  enabled: !_rateBusy,
                  hint: scope.defaultEndpoint.value,
                  label: 'Price source',
                  onChanged: () => setState(() {}),
                  onSubmitted: canSave
                      ? () => unawaited(_saveRate(enabled: on, endpoint: typed))
                      : null,
                ),
                const SizedBox(height: KvSpace.s),
                _Action(
                  label: 'Use this source',
                  enabled: canSave,
                  reason: _rateBusy
                      ? 'Saving…'
                      : typed.isEmpty
                      ? 'Type the address of a price source first.'
                      : 'This is already your price source.',
                  // `enabled: on`, never `true`: the field fixes the
                  // address, the toggle decides whether it is used. A repair
                  // that also switched the rate back on would take a decision
                  // the user did not make.
                  onTap: () =>
                      unawaited(_saveRate(enabled: on, endpoint: typed)),
                ),
                if (on) ...[
                  const SizedBox(height: KvSpace.sm),
                  // What the source actually said, so the setting is verifiable
                  // rather than declarative. `—` when there is no usable price:
                  // the law's own rendering of an unknown rate (BG-5), never a
                  // number nobody vouched for.
                  // **The unit is silk-screened on the LABEL**, which is
                  // where an instrument puts it — and it keeps the value a
                  // pure number, so it can hold BG-14's no-truncation rule
                  // honestly. As `Price | \$0.02864504 per KAS` the row was
                  // 19 characters against a 176dp column and clipped ~1.7 of
                  // them at 320dp/1.3x, unit-first (`ux-auditor`, measured).
                  _Reading(
                    label: 'Price, per KAS',
                    value: quote == null
                        ? '—'
                        // **Every significant digit, no trailing zeros** (D-210,
                        // written against the unit rather than against KAS). A
                        // rate of 0.0712 is `\$0.0712`, never `\$0.07120000` —
                        // padding says a precision the source did not give.
                        : '\$${trimTrailingZeros(quote.usdPerKas)}',
                  ),
                  if (quote != null)
                    _Reading(
                      label: 'As of',
                      numeric: false,
                      value:
                          '${formatAge(widget.clock().difference(quote.fetchedAt))} ago',
                    ),
                ],
              ],
              if (scope.error.value != null) ...[
                const SizedBox(height: KvSpace.s),
                _Fault(displayError(scope.error.value!)),
              ],
              if (_rateProblem != null) ...[
                const SizedBox(height: KvSpace.s),
                _Fault(_rateProblem!),
              ],
              const SizedBox(height: KvSpace.sm),
              const _TrustLabel(
                'A price is the one thing here that no node, no block and no '
                'proof can check — so it is display only, and switching it '
                'off costs you nothing but the figure. The source sees that '
                'this wallet asked for a price, and the network address it '
                'asked from; it never learns what you hold.',
              ),
            ],
          );
        },
      ),
    ];
  }

  Future<void> _saveRate({
    required bool enabled,
    required String endpoint,
  }) async {
    final scope = widget.rate;
    if (scope == null || _rateBusy) return;
    setState(() {
      _rateBusy = true;
      _rateProblem = null;
    });
    try {
      await scope.setConfig(enabled: enabled, endpoint: endpoint);
      if (mounted) _rateEndpoint.text = scope.endpoint.value;
    } catch (e) {
      // The refusal is the message: an endpoint Rust would not store must not
      // leave the row looking as though it had been.
      if (mounted) setState(() => _rateProblem = displayError(e));
    } finally {
      if (mounted) setState(() => _rateBusy = false);
    }
  }
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
    this.numeric = true,
  });

  final String label;
  final String value;
  final bool wrap;

  /// Is this reading a NUMBER or an identifier? Only those may not wrap
  /// (BG-14: *labels wrap or shrink, a number scales down and never
  /// truncates*), and everything else on this plate is a sentence.
  ///
  /// It exists because the collapse got it wrong: the scan line arrived from
  /// `NetworkSheet._DetailRow`, which set no `maxLines` and therefore wrapped,
  /// landed in a row that clips at one line, and read *"live — scanning every
  /// b"* at 320dp — with no ellipsis, and invisible to every test, because a
  /// clipped `Text` inside an `Expanded` raises no overflow (`ux-auditor`,
  /// measured: 27 characters at 0.60 em needs 210.6dp against 176dp).
  final bool numeric;

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
                    maxLines: numeric ? (wrap ? 3 : 1) : null,
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
    this.hint = 'ws://192.168.1.40:17110',
    this.label,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback? onSubmitted;

  /// The shape of the thing being asked for, shown in the empty field.
  final String hint;

  /// What this field is, when the section holds more than one of them. A
  /// screen with three URL boxes and no labels is a screen you have to guess
  /// at — and the guess costs the user their explorer link.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final field = KvSurface.control(
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
        // **Every border named, and `filled: false`.** `border:
        // InputBorder.none` alone is not enough: `applyDefaults` merges
        // `filled`, `fillColor`, `enabledBorder` and `focusedBorder` from the
        // theme, and `InputDecorator` reaches for `enabledBorder` BEFORE it
        // ever consults `border` — so the field painted a `well` fill and a
        // 5dp-radius outline INSIDE its own pill, and a 1.5dp white rectangle
        // on focus (`ux-auditor`, this sitting). The surface around it is the
        // container; the field draws nothing.
        decoration: InputDecoration(
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: KvSpace.sm),
          hintText: hint,
          hintStyle: const TextStyle(
            fontFamily: KvFont.mono,
            fontSize: 13,
            height: 20 / 13,
            color: KvColor.inkMeta,
          ),
        ),
      ),
    );
    if (label == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label!,
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 12,
            height: 17 / 12,
            color: KvColor.inkMeta,
          ),
        ),
        const SizedBox(height: KvSpace.xs),
        field,
      ],
    );
  }
}

/// What an endpoint can see, and what it can lie about — in plain words,
/// beside the row that points at it (BG-17; `ux-auditor` item 30).
///
/// **Not a disclosure string** the user is asked to accept: it is the sentence
/// that makes the switch beside it meaningful. A row naming only the class of
/// service ("an explorer", "a node") is what D-192 refused — *a departure you
/// cannot name is not one you consented to*.
class _TrustLabel extends StatelessWidget {
  const _TrustLabel(this.words);

  final String words;

  @override
  Widget build(BuildContext context) => Text(
    words,
    style: const TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 12,
      height: 17 / 12,
      // Information is colourless (BG-7), and 6.08:1 on the ground clears AA
      // for a paragraph a user is expected to actually read.
      color: KvColor.inkMeta,
    ),
  );
}

/// A refusal, in the words the layer that refused used.
///
/// **Deliberately not a `KvStatusChip`.** Every chip carries a lamp, and BG-2
/// (as clarified at D-209) rations lamps to two per screen, never two saying
/// the same thing. This screen already spends both in its compound failure
/// state — the serving plate's status and the pin's refusal — so a lamped
/// chip on each of the two preference sections would have taken a bad moment
/// to four. Amber plus the words carries the meaning, which is all BG-7 asks:
/// every hue travels with words, and the words survive greyscale alone.
class _Fault extends StatelessWidget {
  const _Fault(this.words);

  final String words;

  @override
  Widget build(BuildContext context) => Text(
    words,
    style: const TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 12,
      height: 17 / 12,
      color: KvColor.warn,
    ),
  );
}

/// A one-tap starting point. Selected = the templates in the fields are
/// exactly this option's, so the state is derived rather than remembered and
/// cannot disagree with what the fields say.
class _Pick extends StatelessWidget {
  const _Pick({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(KvRadius.control),
          child: Container(
            // The visual is the pill; the target is the 48dp row it sits in
            // (BG-12 permits the smaller visual and requires this to say so).
            height: KvSpace.touchTarget,
            padding: const EdgeInsets.symmetric(horizontal: KvSpace.m),
            decoration: BoxDecoration(
              color: selected ? KvColor.keyPressed : KvColor.control,
              borderRadius: BorderRadius.circular(KvRadius.control),
              border: Border.all(
                color: selected ? KvColor.edgeHi : KvColor.hairline,
              ),
            ),
            // **A `Row` at `MainAxisSize.min`, NOT `alignment: Alignment.center`
            // on the Container.** Setting `alignment` makes a `Container`
            // expand to its maximum constraint, so inside the `Wrap` each pick
            // took a whole line and the two-way choice rendered as two
            // full-width buttons stacked down an already-long screen (found on
            // glass, 2026-08-28 device pass). The Row sizes to its child and
            // still centres it vertically in the 48dp target.
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: KvFont.mono,
                    fontSize: 12,
                    height: 17 / 12,
                    color: selected ? KvColor.ink : KvColor.inkDim,
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

/// The user's own "try now" — and since P0b the label names which of the three
/// things a tap actually does, because they stopped being the same action.
///
/// The copy was the retired network sheet's, verbatim (D-196), for as long as
/// both surfaces existed; UX-3 collapsed the sheet into this screen, so this is
/// now the single site and the phrasing answers to the engine instead.
class _Reconnect extends StatelessWidget {
  const _Reconnect({
    required this.hunting,
    required this.connected,
    required this.pinned,
    required this.onTap,
  });

  final bool hunting;
  final bool connected;
  final bool pinned;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // **One control, three states, and until P0b the copy was identical in
    // all of them** — including the one where a tap was the only input in the
    // app that could turn a working wallet into a five-minute outage.
    //
    // - Hunting: "Searching…", not "Reconnecting…" — the hunt is just as often
    //   the FIRST connection of a session, and a second press while one is in
    //   flight is swallowed by the service's own guard.
    // - Connected, unpinned: the engine now holds the live link while it looks
    //   (find-then-swap), so the honest verb is what the tap actually does —
    //   it finds a different node, it does not reconnect this one.
    // - Connected, pinned: there IS no different node to find, so a tap can
    //   only mean "redial mine", and that one still drops the link first. It
    //   says so underneath rather than leaving the user to discover it, which
    //   is how this defect was found in the first place.
    // - Dark: "Reconnect", unchanged.
    final label = switch (true) {
      _ when hunting => 'Searching…',
      _ when connected && pinned => 'Redial your node',
      _ when connected => 'Find a different node',
      _ => 'Reconnect',
    };
    final caption = !hunting && connected && pinned
        ? 'Drops the link you have and dials your node again.'
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _button(label),
        if (caption != null) ...[
          const SizedBox(height: KvSpace.xs),
          Text(
            caption,
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

  Widget _button(String label) {
    return Semantics(
      button: true,
      label: label,
      child: ExcludeSemantics(
        child: InkWell(
          // **Never disabled while hunting** — a tap mid-search IS C4's kick,
          // and greying the control out deletes that affordance exactly when
          // the user most wants it. Repeat taps are already harmless:
          // `ChainService.reconnect()` returns early while a dispatch is in
          // flight.
          //
          // This shipped correctly on the network sheet, with that reasoning
          // written beside it, and UX-2 dropped it when the action moved here
          // — the engine's own hunt keeps `searching` true, so the button was
          // dead from the moment the screen opened. Found on glass; the test
          // that "proved" the swallow had codified the regression.
          onTap: () {
            KvHaptic.selection();
            onTap();
          },
          borderRadius: BorderRadius.circular(KvRadius.control),
          child: KvSurface.control(
            width: double.infinity,
            height: KvSpace.control,
            alignment: Alignment.center,
            // **No meter here.** The serving plate twelve lines above already
            // runs a cadence for this exact fact, and BG-2 counts emitting
            // objects: with one on the plate, one on the pin field's failure
            // state and a lamp, a second here took the screen to four against
            // a cap of three (`ux-auditor`, measured). The label swapping to
            // `Searching…` is the signal, and it says more than a meter can.
            child: Text(
              label,
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 15,
                height: 20 / 15,
                fontWeight: FontWeight.w600,
                color: hunting ? KvColor.inkMeta : KvColor.inkBright,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Names the action and its object (BG-11), and says why it cannot be pressed
/// when it cannot be pressed (BG-12).
///
/// One renderer for all three of this screen's commits — the pin, the explorer
/// and the price source. They were one control when the screen had one
/// setting; three copies of it is how they start disagreeing about what a
/// disabled button looks like.
class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.enabled,
    required this.reason,
    required this.onTap,
  });

  /// Verb plus object, never "Save" (BG-11).
  final String label;

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
          label: label,
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(KvRadius.control),
            child: KvSurface.control(
              width: double.infinity,
              height: KvSpace.control,
              alignment: Alignment.center,
              // No meter, for the reason `_Reconnect` has none: applying a
              // pin re-links, and the serving plate above is already running
              // a cadence for exactly that. BG-2 counts emitting objects, and
              // this screen's compound failure state was measured at five.
              //
              // Nothing replaces it, because nothing had to: `canApply` is
              // false while the write is in flight, so the control is already
              // disabled and already states why — *"Setting the node…"*, the
              // shipped string. A second busy label beside it would have been
              // one invented string saying what a working one already said
              // (D-196).
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 15,
                  height: 20 / 15,
                  fontWeight: FontWeight.w600,
                  color: enabled ? KvColor.inkBright : KvColor.inkMeta,
                ),
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
