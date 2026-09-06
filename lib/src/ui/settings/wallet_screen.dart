import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../rust/api/send.dart' show ConsolidateEstimateDto;
import '../../rust/api/wallet.dart' show DeepScanReport, WalletAddressDto;
import '../address_text.dart';
import '../error_text.dart';
import '../format.dart';
import '../send/signing_ceremony.dart';
import '../theme/kv_page_route.dart';
import '../theme/kv_window.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_amount.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_loader.dart';
import '../widgets/kv_rows.dart';
import '../widgets/kv_tabs.dart';
import '../widgets/kv_two_pane.dart';
import 'settings_scopes.dart';

/// **`T4 · Wallet` — addresses & coins.**
///
/// Two things live here: what the wallet *is* (its addresses) and what you can
/// do to it (deepen the watch window, merge its coins). The render composes
/// both and this now ships both — the `ADDRESSES` list arrived with
/// `list_addresses()`, the seam an earlier sitting named as missing rather
/// than faked.
///
/// **The list is a re-projection, not a second measurement.** Every figure
/// beside an address comes from the engine's live `UtxoContext` through
/// `list_addresses` — the same set a send spends from — so nothing on this
/// screen probes the node and no figure here is a second opinion about money
/// the wallet already tracks.
///
/// **That is not the same as agreeing with the home screen, and the claim
/// used to say it was.** The headline balance is `sum(mature) + consumed −
/// outgoing` at the pin, so an in-flight send moves the two apart; and the
/// merge planner draws from `drain_included`, which withholds coins reserved
/// for live conversations that a row here still counts. Both differences are
/// correct and neither is hidden: the screen prints no total, the header
/// counts addresses, and the merge sentence takes the planner's own numbers
/// (`consensus`, this sitting).
///
/// **It shows the receive branch, and prints no total.** Change addresses are
/// not drawn (they are not addresses anyone hands out), and a mature balance
/// excludes coins still maturing — so the rows do not sum to the wallet's
/// balance and the screen must never imply that they do. The header counts
/// *addresses*. A row with nothing spendable but something arriving says
/// `Pending` rather than sitting silently at zero (the L92 scar).
///
/// **`With funds` / `All` and `Show` are ONE state.** The founder described
/// them as the same act — *"tapping on the All button also does this feature
/// that show does"* — so they set the same flag and each reflects the other;
/// two controls disagreeing about one fact is C7.
///
/// **The revealed tail is bounded and scrolls inside the card.** Thirty-one
/// rows would push the tools off the screen, which is exactly what he asked
/// not to happen: *"a substantial length but not so down below the screen
/// view, because you will make it so users can scroll those."* Nothing else in
/// the house scrolls inside a card, so the pattern is stated here and guarded
/// by its own test.
///
/// **Explain before you price** (BG-11): the merge disclosure states what
/// merging *is* and what it costs before the action bar prints a fee, and that
/// fee is `consolidate_estimate()`'s — the pinned Generator's own number over a
/// plan that is built and dropped, never stashed. The binding figure is still
/// the ceremony's, over the plan actually being signed, which is why the bar
/// says `≈`.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key, required this.scope, this.onScanned});

  final WalletSettingsScope scope;

  /// The root's Wallet sub-line follows what a scan learned here, so the two
  /// surfaces cannot disagree about how wide the watch window is.
  final ValueChanged<DeepScanReport>? onScanned;

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  /// **The widest the address card may grow at rest.** Four rows and a peek of
  /// a fifth: the peek is the affordance — a list clipped flush at a row edge
  /// looks finished, and the founder's whole ask was that the reveal not push
  /// the page away. 4 × [KvRow.height] + half a row.
  static const double _listMax = KvRow.height * 4.5;

  /// **And the widest it grows once you start reading it.** The founder's
  /// second ask (2026-09-06): *"when scrolling on the all addresses to see
  /// more, the view expands down and pushes what's below it… but not entirely
  /// past the bottom of the screen, and scrolling the opposite direction snaps
  /// the view back."*
  ///
  /// A share of the FRAME rather than a count of rows, because the constraint
  /// he stated is about the screen and not about the list.
  ///
  /// **0.62, derived rather than liked.** The card's top sits about 56 dp into
  /// the page (a 52 dp section break plus its lead), and the page's viewport is
  /// the frame less the top bar and the pinned action bar — call it 140. So the
  /// card's bottom stays on screen while `cap ≤ frame − 196`, which is 0.77 of
  /// an 851 dp frame, 0.73 of the 720 floor and 0.52 of the 412 dp landscape
  /// short frame. 0.62 clears all three with room, and still nearly doubles the
  /// card: 528 dp on the reference frame against 288 at rest. Floored at
  /// [_listMax] so a short frame can never make reading *shrink* the card.
  static double _tallCap(double frame) => math.max(_listMax, frame * 0.62);

  /// How far the list must be dragged before the card grows. Small enough to
  /// feel immediate, large enough that a thumb resting on a row while tapping
  /// it does not resize the screen underneath.
  static const double _readingThreshold = 6;

  String? _address;
  bool _addressFailed = false;

  /// The receive branch with what each address holds. Null before the first
  /// answer; the card keeps its footprint either way (BG-20).
  List<WalletAddressDto>? _addresses;
  bool _addressesFailed = false;

  /// `All` and `Show` are the same fact, so they are the same field.
  bool _showAll = false;

  /// **The card has grown to meet a scroll.** Set on the first real downward
  /// drag inside the addresses, cleared when they come back to rest at the
  /// top. See [_tallCap].
  bool _reading = false;

  /// What a merge would cost, from a plan built and dropped. Null while it is
  /// being asked for; [_mergeRefusal] carries the answer when there is nothing
  /// to merge, which is the wallet in its BEST state and never an error.
  ConsolidateEstimateDto? _estimate;
  String? _mergeRefusal;

  /// What the last scan found, in this session. Null before one has run — and
  /// the row shows no datum rather than a `—`, because an action that has not
  /// been taken has nothing to be unknown about (BG-8).
  String? _scanOutcome;
  bool _scanFailed = false;

  String? _mergeOutcome;
  bool _mergeFailed = false;

  /// Which row is working. One at a time: both of these are long, and two in
  /// flight is two ways for one wallet to be re-derived at once.
  String? _busy;

  @override
  void initState() {
    super.initState();
    _readAddress();
    _readAddresses();
    _readEstimate();
  }

  /// The list. Absent seam ⇒ nothing is asked and the card falls back to the
  /// one address the wallet can always answer for.
  Future<void> _readAddresses() async {
    final list = widget.scope.listAddresses;
    if (list == null) return;
    try {
      final addresses = await list();
      if (mounted) {
        setState(() {
          _addresses = addresses;
          _addressesFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _addressesFailed = true);
    }
  }

  /// The resting fee. Refusals are already English from Rust; "nothing to
  /// merge" is not a fault and is not dressed as one.
  Future<void> _readEstimate() async {
    final estimate = widget.scope.consolidateEstimate;
    if (estimate == null) return;
    try {
      final answer = await estimate();
      if (mounted) {
        setState(() {
          _estimate = answer;
          _mergeRefusal = null;
        });
      }
    } catch (e) {
      if (mounted) {
        final message = displayError(e);
        setState(() {
          _estimate = null;
          _mergeRefusal = message;
          // **Say it on the row too, before the tap.** The bar already knows
          // there is nothing to merge; making the user press a control to be
          // told what the screen had already worked out is the same discourtesy
          // §8 forbids in its other direction. Only the BENIGN refusal is
          // promoted — a transient "still connecting" belongs on the disabled
          // control, not printed as a finding over a wallet that is fine.
          //
          // **Only when nothing fresher is showing.** A merge sets
          // `Merged — waiting for the network` and then refreshes this
          // estimate, which now truthfully refuses — and promoting that
          // unconditionally erased the acknowledgement of a broadcast
          // transaction within a few hundred milliseconds of the hold
          // (`wallet-security`, this sitting).
          if (_mergeOutcome == null && message.startsWith('nothing to merge')) {
            _mergeOutcome = message;
            _mergeFailed = false;
          }
        });
      }
    }
  }

  Future<void> _readAddress() async {
    try {
      final address = await widget.scope.receiveAddress();
      if (mounted) setState(() => _address = address);
    } catch (_) {
      if (mounted) setState(() => _addressFailed = true);
    }
  }

  Future<void> _scan() async {
    if (_busy != null) return;
    KvHaptic.selection();
    setState(() {
      _busy = 'scan';
      _scanOutcome = null;
      _scanFailed = false;
    });
    try {
      final report = await widget.scope.deepScan();
      // The scan is bounded at 180 s Rust-side, which is ample time to leave
      // the screen — and setState on a disposed State throws, then throws
      // again inside the catch as an unhandled async error.
      if (!mounted) return;
      widget.onScanned?.call(report);
      // A widened window is a longer list, possibly new funded addresses —
      // and therefore possibly a different merge: coins the wallet could not
      // see a moment ago are coins the planner could not draw on.
      unawaited(_readAddresses());
      unawaited(_readEstimate());
      setState(() {
        // "Nothing new" is the wallet in its BEST state and must not read
        // like a failure — most taps land here, on a wallet that was already
        // complete.
        _scanOutcome = report.widened
            ? 'Found more addresses — watching '
                  '${report.receiveSeen + report.changeSeen}'
            : 'Nothing new found — watching '
                  '${report.receiveSeen + report.changeSeen}';
      });
    } catch (_) {
      // Our own words, never the platform's. Never a silent "done": a scan
      // that says it worked and quietly found nothing is the original defect
      // wearing a new button.
      if (mounted) {
        setState(() {
          _scanOutcome = "Couldn't finish the scan — try again";
          _scanFailed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// Prepare in Rust, then hand the summary to the ONE signing surface — the
  /// same anti-blind-signing ceremony every send uses (BG-6).
  Future<void> _merge() async {
    final scope = widget.scope;
    final consolidate = scope.consolidate;
    final commit = scope.commitSend;
    final abandon = scope.abandonSend;
    if (consolidate == null || commit == null || abandon == null) return;
    if (_busy != null) return;
    KvHaptic.selection();
    setState(() {
      _busy = 'merge';
      _mergeOutcome = null;
      _mergeFailed = false;
    });
    try {
      final summary = await consolidate();
      if (!mounted) return;
      final outcome = await showSigningCeremony(
        context,
        summary: summary,
        commit: commit,
        abandon: abandon,
      );
      if (!mounted) return;
      if (outcome != null && !outcome.partial && outcome.error == null) {
        setState(() {
          // Amber, not green: the line reports that the merge was
          // BROADCAST. BG-7 gives `ok` to things confirmed and amber to "not
          // yet certain", and a self-send just handed to a node is on the
          // `Pending` rung — never *settling*, which D-248 retired.
          _mergeOutcome = 'Merged — waiting for the network';
          _mergeFailed = true;
        });
        // The coins have moved: both the list and the price are now stale.
        unawaited(_readAddresses());
        unawaited(_readEstimate());
      }
    } catch (e) {
      if (!mounted) return;
      // Rust's refusals are already plain English; render them, not a shrug.
      // "Nothing to merge" is the wallet in its BEST state and keeps the
      // quiet tone; a real failure keeps the honest amber.
      final message = displayError(e);
      setState(() {
        _mergeOutcome = message;
        _mergeFailed = !message.startsWith('nothing to merge');
      });
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canMerge = widget.scope.canMerge;
    final gutter = KvWindow.of(context).gutter;
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        child: Column(
          children: [
            KvTopBar(
              title: 'Wallet',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: KvColumn(
                gutter: false,
                child: Column(
                  children: [
                    Expanded(
                      child: ListView(
                        padding: EdgeInsets.fromLTRB(
                          gutter,
                          KvSpace.xs,
                          gutter,
                          canMerge ? KvSpace.s20 : KvSpace.l,
                        ),
                        children: [
                          KvSectionHeader('Addresses', trailing: _filter()),
                          _addressCard(),
                          const KvSectionHeader('Tools'),
                          KvRowContainer(
                            children: [
                              _tool(
                                mark: KvGlyph.layers,
                                title: 'Scan for more addresses',
                                sub:
                                    'Looks deeper for funds at addresses '
                                    'another wallet app may have created from '
                                    'these words',
                                outcome: _scanOutcome,
                                failed: _scanFailed,
                                busy: _busy == 'scan',
                                onTap: _scan,
                              ),
                              if (canMerge)
                                _tool(
                                  mark: KvGlyph.merge,
                                  title: 'Merge coins',
                                  // No fee COUNT and no "all your coins": a
                                  // pile too big for one transaction merges in
                                  // bounded passes, each paying its own fee
                                  // (D-170), and coins reserved for live
                                  // conversations stay where they are. The
                                  // ceremony carries the real numbers.
                                  sub: _mergeSub(),
                                  outcome: _mergeOutcome,
                                  failed: _mergeFailed,
                                  busy: _busy == 'merge',
                                  onTap: _canMergeNow ? _merge : null,
                                ),
                            ],
                          ),
                          if (canMerge) ...[
                            const SizedBox(height: KvSpace.m),
                            // BG-11, and the render's own info card: the
                            // disclosure sits **before** anything is priced.
                            // The price itself is the ceremony's, from the
                            // prepared plan.
                            // **Three lines, and the fee is not among them.**
                            // It used to end "and you see the exact fee
                            // before you hold to sign" — a promise about a
                            // later screen, written when nothing here could
                            // show a price. The bar below now shows one, so
                            // the sentence was BG-19 (nothing twice on one
                            // surface) and it cost the screen its one-view
                            // fit by exactly 14 dp. The render puts the fee
                            // in this card; we put it on the control, which
                            // is closer to the act.
                            const _Notice(
                              'Merging is an ordinary send to yourself. It '
                              'pays one fee now and makes every later send '
                              'cheaper. Nothing leaves the wallet.',
                            ),
                          ],
                        ],
                      ),
                    ),
                    // **Pinned, not in flow.** It is the screen's one primary
                    // action and the list above it can grow by four rows under
                    // the user's thumb; an action bar that scrolled away when
                    // the addresses opened would be reachable exactly when it
                    // was not needed. The render seats it 25 dp off the frame's
                    // foot at 56 high (measured), which is [KvSpace.control].
                    if (canMerge)
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          gutter,
                          0,
                          gutter,
                          KvSpace.l,
                        ),
                        child: _mergeBar(),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The `With funds · N | All · M` filter, seated in the section break.
  ///
  /// Drawn only once the list has landed: a filter offering counts it does not
  /// have would either invent them or print `—` twice in a control, and a
  /// control is not a place to say "unknown" (BG-8 is about data, §8 about
  /// controls).
  Widget? _filter() {
    final addresses = _addresses;
    if (addresses == null) return null;
    final funded = addresses.where(_hasSomething).length;
    return KvSegmented(
      options: [
        KvSegmentedOption('With funds', count: funded),
        KvSegmentedOption('All', count: addresses.length),
      ],
      index: _showAll ? 1 : 0,
      onSelect: (i) {
        KvHaptic.selection();
        setState(() => _showAll = i == 1);
      },
    );
  }

  /// An address worth showing under `With funds`: it holds something, or
  /// something is on its way to it. The second half is the point — an address
  /// mid-deposit filed under "empty addresses hidden" is money the wallet has
  /// hidden from its owner.
  static bool _hasSomething(WalletAddressDto a) =>
      a.balanceSompi > BigInt.zero || a.lockedSompi > BigInt.zero || a.settling;

  Widget _addressCard() {
    final addresses = _addresses;

    // No seam, or it has not answered yet: the one address the wallet can
    // always name, which is what this screen shipped before the list existed.
    if (addresses == null) {
      return KvRowContainer(
        children: [
          KvRow(
            title: 'Receive address',
            subWidget: _addressLine(),
            dense: true,
            trailing: _addressesFailed
                ? null
                : (widget.scope.listAddresses == null
                      ? _chevron()
                      : const KvLoader.inline()),
            semanticLabel: 'Receive address',
            onTap: widget.scope.receiveRoute == null
                ? null
                : () => _openReceive(_address, 'Receive'),
          ),
          if (_addressesFailed)
            const _Fault(
              "Couldn't read the wallet's addresses. The one above is still "
              'good to receive at.',
            ),
        ],
      );
    }

    final shown = _showAll
        ? addresses
        : addresses.where(_hasSomething).toList(growable: false);
    final hidden = addresses.length - shown.length;

    return KvRowContainer(
      // The rows live in their own scroll view, so the rules between them
      // cannot come from the container — the list draws them from the same
      // part (`KvHairline`).
      divided: false,
      children: [
        // **The card grows to meet a reader and returns when they stop.**
        // Expand on the first real downward drag inside the list; collapse the
        // moment it comes back to rest at its own top. Deliberately NOT "any
        // upward scroll": a card that shrank halfway through a list would move
        // the rows out from under the thumb reading them, and the top is the
        // one position a user unambiguously means *done*.
        NotificationListener<ScrollUpdateNotification>(
          onNotification: (notification) {
            // Only this list's own scroll — the page's notifications bubble
            // through here too, and a page drag must not resize the card.
            if (notification.depth != 0) return false;
            final pixels = notification.metrics.pixels;
            final delta = notification.scrollDelta ?? 0;
            final next = _reading
                ? pixels > 0
                : delta > 0 && pixels > _readingThreshold;
            if (next != _reading) setState(() => _reading = next);
            return false;
          },
          child: AnimatedContainer(
            // `calm`, not `fast`: this is a container changing size under the
            // reader's own thumb, and the house reserves `fast` for a tint or
            // a thumb sliding. Reduced motion collapses it (BG-9).
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : KvMotion.calm,
            curve: KvMotion.out,
            constraints: BoxConstraints(
              maxHeight: _reading
                  ? _tallCap(MediaQuery.sizeOf(context).height)
                  : _listMax,
            ),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              // Below the cap nothing scrolls, so the page's own scroll keeps
              // working over the card; at the cap this list takes the drag.
              physics: const ClampingScrollPhysics(),
              itemCount: shown.length,
              itemBuilder: (context, i) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (i > 0) const KvHairline(),
                  _addressRow(shown[i]),
                ],
              ),
            ),
          ),
        ),
        // **The summary is the card's footer, not the list's last row.**
        // Inside the scroll it went below the fold at 320 dp / 1.3× — the one
        // frame where a user most needs the way out of a clipped list, and the
        // control that opens it was the thing clipped. Found in a preview
        // frame, not in an argument.
        if (hidden > 0) ...[const KvHairline(), _hiddenRow(hidden)],
      ],
    );
  }

  /// One address: what it is called, the address itself, and what can be spent
  /// from it right now.
  Widget _addressRow(WalletAddressDto a) {
    final isDefault = a.index == 0;
    // `Receive 02`, zero-padded, as `T4` prints it — the index is a slot in a
    // derivation path and a padded slot sorts and scans as one.
    final label = isDefault
        ? 'Main'
        : 'Receive ${a.index.toString().padLeft(2, '0')}';
    // **Spoken and printed must be the same figure** (`kv_amount.dart`'s own
    // rule, 2026-09-04). This said `${a.balanceSompi} sompi` — a hundred
    // million times the number on the glass, read out to the one user who
    // cannot check it against the row (`wallet-security`, this sitting).
    final locked = a.lockedSompi > BigInt.zero
        ? ', ${_kas(a.lockedSompi)} KAS locked in a contract'
        : '';
    final spoken = a.balanceSompi > BigInt.zero
        ? '$label, ${_kas(a.balanceSompi)} KAS$locked'
        : (a.settling
              ? '$label, pending$locked'
              : (locked.isEmpty ? '$label, empty' : '$label$locked'));
    return KvRow(
      title: label,
      badge: isDefault ? const _DefaultChip() : null,
      subWidget: Padding(
        padding: const EdgeInsets.only(top: KvSpace.xs),
        child: AddressText(a.address, tight: true),
      ),
      dense: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: KvAmount(
              a.balanceSompi,
              role: KvAmountRole.row,
              showUnit: false,
              // An address holding nothing is a fact, not a fault — it recedes
              // rather than shouting a zero at the same weight as a balance.
              muted: a.balanceSompi == BigInt.zero,
            ),
          ),
          const SizedBox(width: KvSpace.s),
          _chevron(),
        ],
      ),
      // BG-7's amber: not yet certain. Never `ok` — nothing has settled.
      // `Locked` wins the slot when both apply: a coin the wallet will never
      // move is a harder fact than one that is merely on its way.
      trailingMeta: a.lockedSompi > BigInt.zero
          ? const _Meta('Locked')
          : (a.settling ? const _Meta('Pending') : null),
      semanticLabel: spoken,
      onTap: widget.scope.receiveRoute == null
          ? null
          : () => _openReceive(a.address, label),
    );
  }

  /// The render's summary line: how many addresses are folded away, and the
  /// word that opens them.
  ///
  /// **52 dp, where the render draws 41.5.** The whole row is the target and
  /// BG-12 does not bend for a picture — the same ruling `dense` already
  /// carries (a row's box is a thumb target and a target never scales). Said
  /// out loud rather than filed: it is a 10 dp divergence from `T4`.
  Widget _hiddenRow(int hidden) {
    final plural = hidden == 1 ? 'address' : 'addresses';
    return Semantics(
      button: true,
      label: 'Show $hidden empty $plural',
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            KvHaptic.selection();
            setState(() => _showAll = true);
          },
          child: SizedBox(
            height: KvSpace.touchTarget,
            child: Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        // BG-30: the figure is mono, the words are not.
                        TextSpan(
                          text: '$hidden',
                          style: const TextStyle(
                            fontFamily: KvFont.mono,
                            fontWeight: FontWeight.w500,
                            fontVariations: KvWeight.w500,
                          ),
                        ),
                        TextSpan(text: ' empty $plural hidden'),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 13,
                      height: 18 / 13,
                      color: KvColor.inkMeta,
                    ),
                  ),
                ),
                const SizedBox(width: KvSpace.sm),
                const Text(
                  'Show',
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 14,
                    height: 20 / 14,
                    fontWeight: FontWeight.w600,
                    fontVariations: KvWeight.w600,
                    color: KvColor.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The merge row's sub-line. It grows a sentence of real counts once the
  /// estimate lands (`38 coins across 3 addresses → 1`) and says the plain
  /// thing until then — never a placeholder shaped like a number.
  String _mergeSub() {
    final estimate = _estimate;
    const tail = 'Later sends then need fewer of them and pay a smaller fee.';
    if (estimate == null) {
      return 'Combines the coins you can spend into one. $tail';
    }
    // **The planner's own count, not "addresses with a balance".** Those two
    // disagree the moment a coin is covenant-bound or reserved for a live
    // conversation, and this row is the sentence a user reads before opening a
    // signing ceremony (`wallet-security`, L129).
    final addresses = estimate.addressCount;
    final across = addresses == 0
        ? ''
        : ' across $addresses ${addresses == 1 ? 'address' : 'addresses'}';
    return '${estimate.utxoCount} coins$across → '
        '${estimate.resultingCoins}. $tail';
  }

  /// The pinned action bar.
  ///
  /// Three states, and the footprint never moves between them (BG-20/BG-24):
  /// waiting for a price, priced, and refused. Refused takes the disabled form
  /// the founder approved on the selection sheet — **the reason is the label**
  /// — so the bar never sits there tappable with nothing behind it (§8).
  Widget _mergeBar() {
    final estimate = _estimate;
    if (!_canMergeNow) {
      return KvAction(
        label: 'Merge coins',
        primary: false,
        height: KvSpace.control,
        // The first clause, which is the reason; the whole sentence is already
        // on the row above, where there is room for it.
        disabledReason: _shortRefusal(_mergeRefusal!),
        onTap: () {},
      );
    }
    return KvAction(
      label: estimate == null
          ? 'Merge coins'
          : 'Merge coins, fee about ${_kas(estimate.feeSompi)} KAS',
      primary: false,
      mark: KvGlyph.merge,
      height: KvSpace.control,
      labelWidget: estimate == null ? null : _feeLabel(estimate),
      onTap: _busy == null ? _merge : () {},
    );
  }

  /// Whether merging is offered at all — **the one fact the row and the bar
  /// both read**, so they can never disagree about it (C7, the same rule
  /// `All`/`Show` follow above).
  ///
  /// Only the settled refusal closes the act. A transient one — "wallet is
  /// still connecting" — leaves both live, because tapping IS the retry and a
  /// control disabled over a condition that clears by itself has no way back.
  bool get _canMergeNow {
    final refusal = _mergeRefusal;
    return refusal == null || !refusal.startsWith('nothing to merge');
  }

  /// `Merge coins · ≈ 0.0004 KAS fee` — words in the UI face, the figure in
  /// mono (BG-30), as `T4` sets it.
  Widget _feeLabel(ConsolidateEstimateDto estimate) => Text.rich(
    TextSpan(
      children: [
        const TextSpan(text: 'Merge coins · ≈ '),
        TextSpan(
          text: _kas(estimate.feeSompi),
          style: const TextStyle(
            fontFamily: KvFont.mono,
            fontWeight: FontWeight.w600,
            fontVariations: KvWeight.w600,
          ),
        ),
        const TextSpan(text: ' KAS fee'),
      ],
    ),
    textAlign: TextAlign.center,
    style: const TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 16,
      height: 20 / 16,
      fontWeight: FontWeight.w600,
      fontVariations: KvWeight.w600,
      color: KvColor.ink,
    ),
  );

  /// Sompi → the KAS the bar prints. The ONE conversion site is `format.dart`
  /// (§5); nothing here does arithmetic on money.
  static String _kas(BigInt sompi) {
    final parts = kasParts(sompi);
    return '${parts.integer}.${trimFraction(parts.fraction)}';
  }

  /// Rust's refusals are whole sentences ("nothing to merge — your spendable
  /// coins are already consolidated"). A pill holds the clause; the row above
  /// holds the sentence.
  static String _shortRefusal(String refusal) {
    final clause = refusal.split(' — ').first.trim();
    if (clause.isEmpty) return 'Nothing to merge';
    return clause[0].toUpperCase() + clause.substring(1);
  }

  Widget _chevron() =>
      const KvGlyphIcon(KvGlyph.chevron, size: 16, tone: KvColor.etch);

  void _openReceive(String? address, String label) {
    final route = widget.scope.receiveRoute;
    if (route == null || address == null) return;
    KvHaptic.selection();
    Navigator.of(
      context,
    ).push(KvPageRoute<void>(builder: (_) => route(address, label)));
  }

  /// The address as the house draws one: BG-15's compact form, scheme
  /// tertiary, payload mono, with the §11 spoken label. Never hand-formatted.
  Widget _addressLine() {
    final address = _address;
    if (address != null) {
      return Padding(
        padding: const EdgeInsets.only(top: KvSpace.xs),
        child: AddressText(address),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: KvSpace.xs),
      child: Text(
        _addressFailed ? 'Unavailable — the vault did not answer' : 'Reading…',
        style: TextStyle(
          fontFamily: KvFont.ui,
          fontSize: 12,
          height: 17 / 12,
          color: _addressFailed ? KvColor.warn : KvColor.inkMeta,
        ),
      ),
    );
  }

  /// A tool row: the render's disc, its title, what it does, and — once it has
  /// been run — what happened, on its own line under the explanation.
  Widget _tool({
    required KvGlyph mark,
    required String title,
    required String sub,
    required String? outcome,
    required bool failed,
    required bool busy,
    required VoidCallback? onTap,
  }) {
    return KvRow(
      leading: KvRowDisc.neutral(mark: mark),
      title: title,
      subWidget: _ToolSub(sub: sub, outcome: outcome, failed: failed),
      dense: true,
      // BG-14's floor: at 320 dp / 1.3× `Scan for more addresses` came out
      // `Scan for more a…`, which names nothing. A label wraps; only a number
      // may not (D-282 set the same on `T1` and `T2`).
      titleLines: 2,
      trailing: busy
          ? const KvLoader.inline()
          : const KvGlyphIcon(KvGlyph.chevron, size: 16, tone: KvColor.etch),
      semanticLabel: outcome == null ? '$title. $sub' : '$title. $outcome',
      onTap: busy ? null : onTap,
    );
  }
}

class _ToolSub extends StatelessWidget {
  const _ToolSub({
    required this.sub,
    required this.outcome,
    required this.failed,
  });

  final String sub;
  final String? outcome;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          sub,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 12,
            height: 17 / 12,
            color: KvColor.inkMeta,
          ),
        ),
        if (outcome case final outcome?)
          Padding(
            padding: const EdgeInsets.only(top: KvSpace.xs),
            child: Text(
              outcome,
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 12,
                height: 17 / 12,
                fontWeight: FontWeight.w600,
                fontVariations: KvWeight.w600,
                color: failed ? KvColor.warn : KvColor.inkDim,
              ),
            ),
          ),
      ],
    );
  }
}

/// The render's information card: an `info` mark on the left, a paragraph
/// beside it, on the home's own plate with no border.
class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => KvRowContainer(
    inset: const EdgeInsets.symmetric(
      vertical: KvSpace.s14,
      horizontal: KvSpace.s18,
    ),
    divided: false,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: KvGlyphIcon(KvGlyph.info, size: 16, tone: KvColor.inkMeta),
          ),
          const SizedBox(width: KvSpace.sm),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 13,
                height: 19 / 13,
                color: KvColor.inkDim,
              ),
            ),
          ),
        ],
      ),
    ],
  );
}

/// The green `Default` pill beside `Main` (`T4`). `okTint` ground, `ok` ink —
/// BG-7's settled green, because "this is the one" is a fact and not a state
/// that might change while you look at it.
class _DefaultChip extends StatelessWidget {
  const _DefaultChip();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: KvSpace.s, vertical: 2),
    decoration: BoxDecoration(
      color: KvColor.okTint,
      borderRadius: BorderRadius.circular(KvRadius.control),
    ),
    child: const Text(
      'Default',
      maxLines: 1,
      style: TextStyle(
        fontFamily: KvFont.ui,
        fontSize: 11,
        height: 16 / 11,
        fontWeight: FontWeight.w600,
        fontVariations: KvWeight.w600,
        color: KvColor.ok,
      ),
    ),
  );
}

/// A line under a card's rows when the seam behind them failed. Amber, and it
/// says what is still true — a fault that only names what broke leaves the
/// user unable to act.
class _Fault extends StatelessWidget {
  const _Fault(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: KvSpace.s),
    child: Text(
      text,
      style: const TextStyle(
        fontFamily: KvFont.ui,
        fontSize: 12,
        height: 17 / 12,
        fontWeight: FontWeight.w600,
        fontVariations: KvWeight.w600,
        color: KvColor.warn,
      ),
    ),
  );
}

/// A one-word amber note under a row's value — `Pending`, `Locked`. BG-7's
/// amber, never `ok`: both words name something that has NOT settled into
/// spendable money.
class _Meta extends StatelessWidget {
  const _Meta(this.word);

  final String word;

  @override
  Widget build(BuildContext context) => Text(
    word,
    style: const TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 11,
      height: 16 / 11,
      fontWeight: FontWeight.w600,
      fontVariations: KvWeight.w600,
      color: KvColor.warn,
    ),
  );
}
