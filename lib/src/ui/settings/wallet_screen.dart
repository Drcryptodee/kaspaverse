import 'package:flutter/material.dart';

import '../../rust/api/wallet.dart' show DeepScanReport;
import '../address_text.dart';
import '../error_text.dart';
import '../send/signing_ceremony.dart';
import '../theme/kv_page_route.dart';
import '../theme/kv_window.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_loader.dart';
import '../widgets/kv_rows.dart';
import '../widgets/kv_two_pane.dart';
import 'settings_scopes.dart';

/// **`T4 · Wallet` — addresses & coins.**
///
/// Two things live here: what the wallet *is* (its addresses) and what you can
/// do to it (deepen the watch window, merge its coins). The render composes
/// both; this build ships the second half whole and **cannot yet ship the
/// first**, which is stated here and was said in the sitting.
///
/// **The `ADDRESSES` list needs a seam that does not exist.** `T4` draws every
/// funded address with its own balance, a `With funds · 3 | All · 31`
/// segmented filter and an empty tail collapsed behind `Show`. Nothing in the
/// bridge enumerates the wallet's addresses: `WalletSnapshot` carries the
/// **aggregate** mature / pending / outgoing balance and an activity list,
/// `DeepScanReport` carries how deep discovery probed, and
/// `vault_receive_address()` answers with exactly one address. Rendering that
/// list means a new `list_addresses()` on the FFI surface returning public
/// address · label · balance — **a T3 change** (bridge DTO + codegen +
/// `ffi-leak`, `wallet-security`, `consensus` and `dependency-steward`), not a
/// composition a UX sitting may invent. Inventing it here would mean a row of
/// figures with nothing behind them on the screen that names the user's money.
///
/// So the screen ships the `ADDRESSES` header over the one address the wallet
/// really knows — **the receive address, which is a fact** — and the whole
/// `TOOLS` card, whose two rows are both live seams.
///
/// **Explain before you price** (BG-11): the merge disclosure states what
/// merging *is* and what it costs before the action bar prints a fee, and the
/// fee it prints is the one Rust returns from the prepared plan — never a
/// guess.
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
  String? _address;
  bool _addressFailed = false;

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
    final receiveRoute = widget.scope.receiveRoute;
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
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    KvWindow.of(context).gutter,
                    KvSpace.xs,
                    KvWindow.of(context).gutter,
                    KvSpace.l,
                  ),
                  children: [
                    const KvSectionHeader('Addresses'),
                    KvRowContainer(
                      children: [
                        KvRow(
                          title: 'Receive address',
                          subWidget: _addressLine(),
                          dense: true,
                          trailing: receiveRoute == null
                              ? null
                              : const KvGlyphIcon(
                                  KvGlyph.chevron,
                                  size: 16,
                                  tone: KvColor.etch,
                                ),
                          semanticLabel: 'Receive address',
                          onTap: receiveRoute == null
                              ? null
                              : () {
                                  KvHaptic.selection();
                                  Navigator.of(context).push(
                                    KvPageRoute<void>(builder: receiveRoute),
                                  );
                                },
                        ),
                      ],
                    ),
                    const KvSectionHeader('Tools'),
                    KvRowContainer(
                      children: [
                        _tool(
                          mark: KvGlyph.layers,
                          title: 'Scan for more addresses',
                          sub:
                              'Looks deeper for funds at addresses another '
                              'wallet app may have created from these words',
                          outcome: _scanOutcome,
                          failed: _scanFailed,
                          busy: _busy == 'scan',
                          onTap: _scan,
                        ),
                        if (canMerge)
                          _tool(
                            mark: KvGlyph.merge,
                            title: 'Merge coins',
                            // No fee COUNT and no "all your coins": a pile too
                            // big for one transaction merges in bounded
                            // passes, each paying its own fee (D-170), and
                            // coins reserved for live conversations stay
                            // where they are. The ceremony carries the real
                            // numbers.
                            sub:
                                'Combines the coins you can spend into one. '
                                'Later sends then need fewer of them and pay '
                                'a smaller fee.',
                            outcome: _mergeOutcome,
                            failed: _mergeFailed,
                            busy: _busy == 'merge',
                            onTap: _merge,
                          ),
                      ],
                    ),
                    if (canMerge) ...[
                      const SizedBox(height: KvSpace.m),
                      // BG-11, and the render's own info card: the disclosure
                      // sits **before** anything is priced. The price itself
                      // is the ceremony's, from the prepared plan.
                      const _Notice(
                        'Merging is an ordinary send to yourself. It pays one '
                        'network fee now and makes every later send cheaper. '
                        'Nothing leaves the wallet, and you see the exact fee '
                        'before you hold to sign.',
                      ),
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
    required VoidCallback onTap,
  }) {
    return KvRow(
      leading: KvRowDisc.neutral(mark: mark),
      title: title,
      subWidget: _ToolSub(sub: sub, outcome: outcome, failed: failed),
      dense: true,
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
