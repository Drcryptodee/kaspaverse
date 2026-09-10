import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/contacts_service.dart';
import '../../services/messaging_service.dart';
import '../../rust/api/send.dart';
import '../../rust/api/transport.dart';
import '../error_text.dart';
import '../format.dart';
import '../send/confirm_send_flow.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_reading.dart';
import '../widgets/kv_rows.dart';
import '../widgets/kv_sheet.dart';
import '../widgets/kv_toggle.dart';
import '../widgets/kv_two_pane.dart';
import '../theme/kv_page_route.dart';
import 'blocked_addresses_screen.dart';
import 'contacts_screen.dart' show signingToggleSub, signingToggleTitle;
import 'history_fill_sheet.dart';

/// **Message settings — a screen in Settings, not a sheet on the thread.**
///
/// Founder ruling, 2026-09-08: *"Move the message settings sheet content into
/// 'Messages' in settings screen. the 'App' section (move the settings there
/// too and delete the coming soon thingy now that we have message settings)."*
///
/// It had been a sheet reached from the messages overflow, and Settings' own
/// `Messages` row was a *Coming soon* page whose sub-line said the settings
/// were *"not built yet"* — which was true of the location and not of the
/// settings. One home, and both doors open it (24d).
///
/// **The flows it runs live here as free functions** ([runMessageBackUp],
/// [runMessageWipe]) rather than as methods of whichever screen mounted it:
/// they are a ceremony and a confirm over `MessagingService`, they need no
/// screen state, and leaving them on the contacts screen is what would have
/// made this page impossible to reach from Settings.
class MessageSettingsScreen extends StatefulWidget {
  const MessageSettingsScreen({super.key, this.messaging});

  /// Test seam; defaults to the singleton.
  final MessagingService? messaging;

  @override
  State<MessageSettingsScreen> createState() => _MessageSettingsScreenState();
}

class _MessageSettingsScreenState extends State<MessageSettingsScreen> {
  MessagingService get _messaging =>
      widget.messaging ?? MessagingService.instance;

  /// Null until the preference has been read — the row is absent rather than
  /// guessed at, because a switch that flicks from a guess to the truth on the
  /// second frame is a control lying about the state it governs (BG-24).
  bool? _signing;

  /// Why the last flip did not stick, said under the row rather than in a
  /// toast (§4: this language has no toasts).
  String? _signingError;

  /// How many addresses are blocked — `M5`'s figure under the row. Null
  /// until Rust has answered, so the line is absent rather than a guess.
  int? _blockedCount;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSigning());
    unawaited(_loadBlocked());
  }

  Future<void> _loadBlocked() async {
    try {
      final rows = await _messaging.blockedContacts();
      if (mounted) setState(() => _blockedCount = rows.length);
    } catch (_) {
      // Unreadable stays unsaid; the screen behind the row says its own truth.
    }
  }

  /// The sub-line under `Blocked addresses`: `M5`'s bare count, in mono
  /// (BG-30, D-259 — the render draws `1` and the render wins). Absent until
  /// Rust has answered, so the line is never a guess.
  Widget? get _blockedSub {
    final n = _blockedCount;
    if (n == null) return null;
    return Text(
      '$n',
      style: const TextStyle(
        fontFamily: KvFont.mono,
        fontSize: 13,
        height: 17 / 13,
        fontWeight: FontWeight.w400,
        fontVariations: KvWeight.w400,
        fontFeatures: [FontFeature.tabularFigures()],
        color: KvColor.inkMeta,
      ),
    );
  }

  Future<void> _openBlocked() async {
    KvHaptic.selection();
    await Navigator.of(context).push(
      KvPageRoute<void>(
        builder: (_) => BlockedAddressesScreen(messaging: _messaging),
      ),
    );
    if (mounted) await _loadBlocked();
  }

  Future<void> _loadSigning() async {
    try {
      final signing = await _messaging.messageSigning();
      if (mounted) setState(() => _signing = signing);
    } catch (_) {
      // Unreadable reads as the ceremony, which is the safe state and the one
      // Rust falls back to as well.
      if (mounted) setState(() => _signing = true);
    }
  }

  Future<void> _setSigning(bool signing) async {
    KvHaptic.selection();
    setState(() {
      _signing = signing;
      _signingError = null;
    });
    try {
      await _messaging.setMessageSigning(signing);
    } catch (e) {
      // The switch springs back to what is actually stored, and the sub-line
      // says why.
      if (!mounted) return;
      setState(() {
        _signing = !signing;
        _signingError = displayError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final signing = _signing;
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        child: Column(
          children: [
            KvTopBar(
              title: 'Messages',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: KvColumn(
                child: KvScrollEdge(
                  ground: KvColor.abyss,
                  child: ListView(
                    padding: const EdgeInsets.only(
                      top: KvSpace.xs,
                      bottom: KvSpace.l,
                    ),
                    children: [
                      const KvSectionHeader('Sending'),
                      // **It eases in** (BG-24): the preference is read
                      // asynchronously, so without this a ~70 dp card appears
                      // between two frames and shoves what is below it down.
                      AnimatedSize(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : KvMotion.calm,
                        curve: KvMotion.curve,
                        alignment: Alignment.topCenter,
                        child: signing == null
                            ? const SizedBox(width: double.infinity)
                            : KvRowContainer(
                                children: [
                                  KvToggle(
                                    bare: true,
                                    on: !signing,
                                    title: signingToggleTitle,
                                    sub:
                                        _signingError ??
                                        signingToggleSub(signing),
                                    onChanged: (off) => _setSigning(!off),
                                  ),
                                ],
                              ),
                      ),
                      const KvSectionHeader('History'),
                      // **The gap notice's seat** (founder, 2026-09-08). It had
                      // been a banner under the conversation list's search
                      // field, drawing 32 dp in from an edge everything around
                      // it met at 16; it belongs to this row, so it hangs under
                      // it — inside the same card, over the container's own
                      // hairline — and pushes `Delete all messages` down for
                      // exactly as long as it has something to say.
                      //
                      // It eases, like the signing row above it: the four seams
                      // it reads answer after the first frame, and a notice
                      // that appears between two frames shoves the app's one
                      // irreversible gesture out from under a thumb already on
                      // its way down (BG-24).
                      AnimatedSize(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : KvMotion.calm,
                        curve: KvMotion.curve,
                        alignment: Alignment.topCenter,
                        child: AnimatedBuilder(
                          animation: historyAlertListenable(_messaging),
                          builder: (context, _) {
                            final alert = historyAlert(_messaging);
                            return KvRowContainer(
                              children: [
                                KvRow(
                                  // A label WRAPS; only a number may not
                                  // (BG-14).
                                  titleLines: 2,
                                  leading: const KvRowDisc.neutral(
                                    mark: KvGlyph.history,
                                  ),
                                  title: 'History & backup',
                                  sub:
                                      'Fill in what the node missed, and park '
                                      'your contacts on chain',
                                  subLines: 2,
                                  trailing: const KvGlyphIcon(
                                    KvGlyph.chevron,
                                    size: 20,
                                    tone: KvColor.etch,
                                  ),
                                  onTap: () =>
                                      runMessageHistory(context, _messaging),
                                ),
                                if (alert != null)
                                  HistoryNoticeLine(
                                    text: alert,
                                    onTap: () =>
                                        runMessageHistory(context, _messaging),
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                      // **`M5`'s `Blocked addresses` row** (D-308) — the
                      // render draws it with its count; the screen behind it
                      // is where a block is lifted deliberately.
                      const KvSectionHeader('Contacts'),
                      KvRowContainer(
                        children: [
                          KvRow(
                            titleLines: 2,
                            leading: const KvRowDisc.neutral(mark: KvGlyph.ban),
                            title: 'Blocked addresses',
                            subWidget: _blockedSub,
                            trailing: const KvGlyphIcon(
                              KvGlyph.chevron,
                              size: 20,
                              tone: KvColor.etch,
                            ),
                            onTap: _openBlocked,
                          ),
                        ],
                      ),
                      const KvSectionHeader('Danger'),
                      KvRowContainer(
                        children: [
                          KvRow(
                            titleLines: 2,
                            // **`risk`, and the only place on this screen that
                            // takes it.** §3 rations the hue to fund risk and
                            // DESTRUCTION, and this is the app's single
                            // irreversible messaging gesture. The whole row
                            // wears it, not just the disc (founder,
                            // 2026-09-08).
                            leading: const KvRowDisc(
                              mark: KvGlyph.trash,
                              tint: KvColor.riskTint,
                              tone: KvColor.risk,
                            ),
                            tone: KvColor.risk,
                            title: 'Delete all messages',
                            sub: 'Every conversation, on this device',
                            trailing: const KvGlyphIcon(
                              KvGlyph.chevron,
                              size: 20,
                              tone: KvColor.etch,
                            ),
                            onTap: () => runMessageWipe(context, _messaging),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The shared prepare-and-confirm for the two spends this surface can make.
///
/// A free function because the flows it serves are now reachable from two
/// screens, and neither owns the ceremony — `runConfirmSend` does.
Future<void> _runPrepare(
  BuildContext context,
  MessagingService messaging,
  Future<SignableSummaryDto> Function() prepare, {
  required String contextNote,
  required String preparingObject,
  String? title,
}) async {
  try {
    await runConfirmSend(
      context,
      prepare: prepare,
      commit: messaging.commit,
      abandon: messaging.abandon,
      contextNote: contextNote,
      title: title,
      preparingObject: preparingObject,
    );
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(displayError(e))));
  }
  await messaging.refresh();
}

/// The D-138 backup (`self_stash`): park every conversation on chain, sealed to
/// our own key, so a restore-from-seed finds contacts and not just money.
Future<void> runMessageBackUp(
  BuildContext context,
  MessagingService messaging,
) async {
  await _runPrepare(
    context,
    messaging,
    messaging.prepareStash,
    // A backup is not a message, and the shared ceremony would otherwise call
    // it one — on the confirm sheet AND on the card before it.
    title: 'Confirm backup',
    preparingObject: 'backup',
    contextNote:
        'Parks your conversation list on Kaspa, sealed to your own key, so '
        'your recovery phrase can bring your contacts back too. The amount '
        'returns to you — only the network fee is spent.',
  );
  await messaging.refreshFillState();
}

/// Open the history-fill sheet with the backup wired into it.
Future<void> runMessageHistory(
  BuildContext context,
  MessagingService messaging,
) async {
  KvHaptic.selection();
  await showHistoryFillSheet(
    context,
    messaging,
    onBackUp: () => runMessageBackUp(context, messaging),
  );
}

/// **Erase every conversation and every message on this device.**
///
/// The number in the confirm is asked of Rust, never counted off a screen's
/// list: that list filters hidden conversations and the wipe destroys them
/// too, so the visible number would under-promise by exactly the rows the user
/// already tried to put out of sight — and the number is the consent.
Future<void> runMessageWipe(
  BuildContext context,
  MessagingService messaging,
) async {
  KvHaptic.selection();
  final WipeReportDto preview;
  try {
    preview = await messaging.wipePreview();
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(displayError(e))));
    return;
  }
  if (!context.mounted) return;
  if (preview.conversations == 0 && preview.messages == 0) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('There is nothing to delete.')),
    );
    return;
  }
  // **The bond figure comes from Rust**, never a Dart literal: this sheet
  // quotes somebody else's money that the erase makes unreturnable
  // (`consensus-auditor` BLOCK, UX-R5).
  final bond = messaging.handshakeBondSompi;
  if (!context.mounted) return;
  final choice = await Navigator.of(context).push<String>(
    KvSheetRoute<String>(
      builder: (_) => _WipeConfirmSheet(preview: preview, bond: bond),
    ),
  );
  if (!context.mounted) return;
  // **The stash, offered before the erase** (D-307 (b)): the backup is what
  // keeps replies working afterwards, and the founder's own wipe is what
  // taught us that. The delete is not re-opened behind it — a fresh backup is
  // unproven until a walk reads it back, and putting the erase under the same
  // thumb a second later would invite deleting before it is findable.
  if (choice == 'backup') {
    await runMessageBackUp(context, messaging);
    return;
  }
  if (choice != 'delete') return;
  try {
    final report = await messaging.wipeAll();
    // **The address book's cache goes with the store it mirrors.** The wipe
    // clears `contact.names` as a side file, but `ContactsService` holds the
    // last read in memory — so the first frames of the next Send screen would
    // paint contacts the wipe destroyed (`wallet-security-auditor`, UX-R2B).
    await ContactsService.instance.refresh();
    if (!context.mounted) return;
    final deleted =
        'Deleted ${report.conversations} conversation'
        '${report.conversations == 1 ? '' : 's'} '
        'and ${report.messages} message'
        '${report.messages == 1 ? '' : 's'}.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        // The floor is what makes the erase stick against the next history
        // catch-up. If it did not persist, the sheet's "cannot be undone" is
        // not yet true and the user is the only one who can act on it.
        duration: report.floorPersisted
            ? const Duration(seconds: 4)
            : const Duration(seconds: 10),
        content: Text(
          report.floorPersisted
              ? deleted
              : '$deleted But history catch-up could not be stopped — '
                    'turn off History & backup, or they may come back.',
        ),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    // Never a silent failure on a destructive action: the user must not walk
    // away believing their messages are gone when they are still here.
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(displayError(e))));
  }
}

/// **The one irreversible ceremony in the messages lane**, moved here with the
/// settings it belongs to and **with its copy intact**.
///
/// Every clause below was won by an audit or a founder ruling and none of it
/// is decoration: the count includes hidden rows (which is why it is asked of
/// Rust and never counted off a list), the chain sentence stops the sheet
/// implying an erase it cannot perform, the bond sentence names somebody
/// else's money that this makes unreturnable — its figure comes from Rust
/// because a remembered constant here was a `consensus-auditor` BLOCK — and
/// the last paragraph is the repair instruction, which is the useful half.
/// A figure inside the sheet's prose: mono, tabular, the body's own ink
/// (BG-30 — *speak and count in different faces*).
TextSpan _figure(String text) => TextSpan(
  text: text,
  style: const TextStyle(
    fontFamily: KvFont.mono,
    fontFeatures: [FontFeature.tabularFigures()],
  ),
);

class _WipeConfirmSheet extends StatelessWidget {
  const _WipeConfirmSheet({required this.preview, required this.bond});

  /// Rust's count of what the wipe would destroy — hidden rows included.
  final WipeReportDto preview;

  /// The bond each stranded sender paid, from Rust.
  final BigInt bond;

  @override
  Widget build(BuildContext context) {
    final conversationCount = preview.conversations;
    final messageCount = preview.messages;
    final plural = conversationCount == 1 ? '' : 's';
    return KvSheet(
      title: 'Delete all messages',
      onCancel: () => Navigator.of(context).pop(),
      // **Two acts, the repair above the erase.** The backup is offered here
      // because this sheet is where the founder learned what a wipe costs
      // (D-307): it is raised, never teal — it spends a fee and it is not the
      // sheet's subject — and the erase keeps §3's red below it, nearest the
      // thumb, as every destructive act on a sheet does.
      foot: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KvAction.raised(
            label: 'Back up first…',
            onTap: () => Navigator.of(context).pop('backup'),
          ),
          const SizedBox(height: KvSpace.s),
          KvAction.destructive(
            label: 'Delete $conversationCount conversation$plural',
            onTap: () => Navigator.of(context).pop('delete'),
          ),
        ],
      ),
      // `KvSheet` flexes its body and leaves the scrolling to the caller,
      // which is what keeps the act out of the scroll (D-221 §1). The body
      // is long enough to sit under the fold at 320 dp / 1.3×, so the edge
      // says so rather than clipping the sentence that justifies the backup
      // act (`ux-auditor`, MSG-BLOCK).
      child: KvScrollEdge(
        ground: KvColor.plate,
        child: SingleChildScrollView(
          // **Every figure in mono** (BG-30): the counts, the bond, and the
          // handshake's price — the same span `M2`'s gloss sets the bond in.
          child: Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'This deletes '),
                _figure('$conversationCount'),
                TextSpan(text: ' conversation$plural and '),
                _figure('$messageCount'),
                TextSpan(
                  text:
                      ' message${messageCount == 1 ? '' : 's'} from this '
                      'device, including any you have hidden. KaspaVerse '
                      'cannot undo it.\n\n'
                      'Messages already sent stay on Kaspa permanently. This '
                      'clears your copy, not the chain, and this app will not '
                      'fetch them back, even with History & backup on. Your '
                      'wallet and coins are not touched.\n\n',
                ),
                if (preview.pendingBonds > 0) ...[
                  const TextSpan(text: 'This also deletes '),
                  _figure('${preview.pendingBonds}'),
                  TextSpan(
                    text:
                        ' unanswered contact '
                        'request${preview.pendingBonds == 1 ? '' : 's'}. The ',
                  ),
                  _figure(kasCanonical(bond)),
                  const TextSpan(
                    text:
                        ' KAS bond each sender paid can no longer be returned '
                        'to them.\n\n',
                  ),
                ],
                // D-307: what a wipe does to the people who still write to
                // you. Their message reopens the thread; the reply is the
                // part that costs, and the backup is what makes it not cost.
                const TextSpan(
                  text:
                      'Contacts who still have you can write to you '
                      'afterwards; their next message reopens the thread. '
                      'Replying costs a new handshake (',
                ),
                _figure(kasCanonical(bond)),
                const TextSpan(
                  text:
                      ' KAS). A backup keeps your side of every handshake, so '
                      'a reply needs no new handshake.\n\n'
                      // D-308: the one thing a wipe deliberately leaves
                      // standing.
                      'Blocked addresses stay blocked.',
                ),
              ],
            ),
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 14,
              height: 20 / 14,
              fontWeight: FontWeight.w400,
              fontVariations: KvWeight.w400,
              color: KvColor.inkDim,
            ),
          ),
        ),
      ),
    );
  }
}
