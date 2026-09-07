import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;

import '../../rust/api/send.dart';
import '../../rust/api/transport.dart';
import '../../services/contacts_service.dart';
import '../../services/messaging_service.dart';
import '../format.dart';
import '../send/confirm_send_flow.dart';
import '../theme/kv_page_route.dart';
import '../error_text.dart';
import '../theme/tokens.dart';
import '../widgets/entrance.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_address.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_contact.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_icon_button.dart';
import '../widgets/kv_reading.dart';
import '../widgets/kv_rows.dart';
import '../widgets/kv_search_field.dart';
import '../widgets/kv_sheet.dart';
import '../widgets/kv_tabs.dart';
import '../widgets/kv_two_pane.dart';
import 'history_fill_sheet.dart';
import 'thread_screen.dart';

/// Transport contacts (P2.3 — §4: transport UI, not a messenger): the
/// conversation list, contact-add via address, and the incoming-handshake
/// accept card. Everything rendered here is public-wire-class data
/// (addresses, aliases, status) — decrypted content appears only inside a
/// [ThreadScreen] pull.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key, this.messaging});

  /// Test seam; defaults to the singleton.
  final MessagingService? messaging;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  MessagingService get _messaging =>
      widget.messaging ?? MessagingService.instance;

  /// Which lane is showing — `M1`'s Chats, or `M2`'s Requests.
  int _tab = 0;

  /// `M1`'s search. Local, over the two public-wire fields the row already
  /// holds; nothing is decrypted and nothing leaves the device.
  final _search = TextEditingController();
  String _query = '';

  /// The price of a handshake, from the crate that spends it.
  BigInt get _bond => _messaging.handshakeBondSompi;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _messaging.refresh();
    // The gap notice's inputs resolve in Rust seconds-to-minutes after
    // unlock (gap-age retry budget; the auto-fill runs after the node
    // catch-up) — with fill OFF and no inbound traffic no ping ever fires,
    // so re-ask on every entry to this surface (consensus-audit finding:
    // "never silence" must not depend on luck).
    _messaging.refreshFillState();
  }

  Future<void> _addContact() async {
    // `M3 · New handshake` — a pushed page, not a sheet.
    final entered = await Navigator.of(context)
        .push<({String address, String name})>(
          KvPageRoute<({String address, String name})>(
            builder: (_) => NewHandshakeScreen(bond: _bond),
          ),
        );
    if (!mounted || entered == null || entered.address.isEmpty) return;
    final address = entered.address;
    // **The name is written BEFORE the request goes out**, so the row the
    // handshake creates already carries it rather than showing an address
    // until the user goes back and renames it. Device-only (D-049); a failure
    // here must never block the request, which is the thing that costs money.
    if (entered.name.isNotEmpty) {
      try {
        await _messaging.setContactName(address, entered.name);
      } catch (_) {
        // A local label is a convenience; the handshake is the point.
      }
    }
    if (!mounted) return;

    // Already a contact? Open the thread instead of quoting a bond.
    //
    // This used to refuse with a snackbar telling the user to go and find the
    // conversation themselves — the app knowing the answer and making them do
    // the work, after a confirm sheet had already offered to spend 0.2 KAS.
    // Rust owns the rule (its prepare path still refuses, so a race cannot
    // mint a duplicate); this only asks the question early enough to be useful.
    try {
      final route = await _messaging.existingConversation(address);
      if (route != null) {
        await _messaging.refresh();
        if (!mounted) return;
        final conversation = _messaging.conversations.value
            .where((c) => c.conversationId == route.conversationId)
            .firstOrNull;
        if (conversation != null) {
          // They already invited US. Accepting refunds the bond they paid and
          // opens the conversation; sending our own would spend a second one
          // and leave theirs stranded.
          if (route.acceptFirst) {
            await _accept(conversation);
          } else {
            _openThread(conversation);
          }
          return;
        }
      }
    } catch (_) {
      // A failed lookup must never block adding a contact — fall through to
      // the invitation, where Rust's own refusal is the real guard.
    }

    await _runPrepare(
      () => _messaging.prepareHandshake(address),
      // The SENDER's word for this, not the receiver's: the button behind
      // this beat says "Review request" and the sheet after it says "Confirm
      // contact request". "Invitation" is what the other side's app calls it
      // once it arrives — using it here makes three consecutive beats name
      // the same thing three ways.
      preparingObject: 'contact request',
      contextNote:
          'Carries a ${kasCanonical(_bond)} KAS bond — the network norm. It '
          'comes back when they accept; if they already have you as a contact '
          'their app completes the chat silently and the bond is not '
          'returned.',
    );
  }

  Future<void> _accept(ConversationDto conversation) async {
    await _runPrepare(
      () => _messaging.prepareAccept(conversation.conversationId),
      // "acceptance", not "reply": this send refunds the bond and opens the
      // conversation — it is not a message. Reads as one chain into the
      // sheet's own "Confirm accept" ("your accept" is ungrammatical).
      preparingObject: 'acceptance',
      contextNote:
          'Returns the ${kasCanonical(_bond)} KAS bond to the sender and opens '
          'the conversation.',
    );
  }

  /// The D-138 backup (`self_stash`): park every conversation on chain, sealed
  /// to our own key, so a restore-from-seed finds contacts and not just money.
  Future<void> _backUp() async {
    await _runPrepare(
      _messaging.prepareStash,
      // A backup is not a message, and the shared ceremony would otherwise
      // call it one — on the confirm sheet AND on the card before it.
      title: 'Confirm backup',
      preparingObject: 'backup',
      contextNote:
          'Parks your conversation list on Kaspa, sealed to your own key, so '
          'your recovery phrase can bring your contacts back too. The amount '
          'returns to you — only the network fee is spent.',
    );
    await _messaging.refreshFillState();
  }

  /// The shared ceremony over [runConfirmSend] (V5): the summary — mode,
  /// title, payload facts included — is Rust's decode (B7); this surface
  /// keeps only its own error style (snackbar) and list refresh.
  Future<void> _runPrepare(
    Future<SignableSummaryDto> Function() prepare, {
    required String contextNote,
    required String preparingObject,
    String? title,
  }) async {
    try {
      await runConfirmSend(
        context,
        prepare: prepare,
        commit: _messaging.commit,
        abandon: _messaging.abandon,
        contextNote: contextNote,
        title: title,
        preparingObject: preparingObject,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(displayError(e))));
    }
    await _messaging.refresh();
  }

  void _openThread(ConversationDto conversation) {
    Navigator.of(context).push(
      KvPageRoute<void>(
        builder: (_) => ThreadScreen(
          conversationId: conversation.conversationId,
          contactLabel: contactLabel(conversation),
          contactAddress: conversation.contactAddress,
          superseded: conversation.superseded,
          messaging: _messaging,
        ),
      ),
    );
  }

  /// The expired-invitation exit (V5, finding 15 — INV-6 instinct: every
  /// state has a unilateral out). One tap, founder-ruled: the card's copy
  /// already explains, so no second confirm. Same reversible hide lane
  /// as hide — the row is tombstoned, not deleted, so the counterparty's
  /// alias survives and a later message still finds its home.
  Future<void> _dismissExpired(ConversationDto conversation) async {
    KvHaptic.selection();
    await _messaging.hide(conversation.conversationId);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Invitation dismissed.')));
  }

  /// Long-press: name the contact, or hide the conversation.
  ///
  /// Hide used to be the whole long-press. Naming belongs on the same gesture —
  /// both are "this row, not this message" — and putting a second step in front
  /// of hide is a feature, not a cost: it is the one local action that makes a
  /// conversation disappear.
  Future<void> _rowActions(ConversationDto conversation) async {
    KvHaptic.selection();
    final action = await Navigator.of(context).push<String>(
      KvSheetRoute<String>(
        builder: (_) => _RowActionsSheet(
          label: contactLabel(conversation),
          bond: _bond,
          canName: conversation.contactAddress.isNotEmpty,
          // Active rows ONLY. On an invitation, "start over" would hide the card
          // permanently — `may_unhide` refuses `PendingInbound` — and spend 0.2
          // KAS of ours while stranding the 0.2 KAS bond they already paid, which
          // only Accept can return.
          // Never on a REPLACED row. Start over retires every Active thread with
          // this contact — including the working successor the card body has
          // just told the user to open. Highest-cost mis-tap in the surface,
          // offered on the card the app itself labelled broken. Costs no exit:
          // the successor is always sendable, and Start over is available there.
          canStartOver:
              conversation.status == 'active' &&
              conversation.contactAddress.isNotEmpty &&
              !conversation.superseded,
          // Nothing to clear on an invitation but the handshake row, which is
          // deliberately kept (a bond gate reads it) — so it would report "0
          // messages cleared" over a card that visibly still has a row on it.
          canClear: conversation.status != 'pending_in',
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'name') {
      await _nameContact(conversation);
    } else if (action == 'restart') {
      await _startOver(conversation);
    } else if (action == 'clear') {
      await _clearMessages(conversation);
    } else if (action == 'hide') {
      await _hide(conversation);
    }
  }

  /// The per-contact exit (INV-6): hide this thread, then send them a fresh
  /// contact request.
  ///
  /// **It has to be its own door, and that is the point.** Going through
  /// `_addContact` cannot work: `existingConversation` finds the hidden row,
  /// un-hides it (the only thing that restores a hidden conversation) and
  /// hands it straight back — so "hide it, then re-invite" was "hide it, then
  /// un-hide it", and a contact whose only live thread was broken had no exit
  /// but deleting every conversation they had.
  ///
  /// **`startOver` is ONE Rust call, not hide-then-invite from here.** Doing it
  /// as two half-applied in exactly the case it exists for: with two live
  /// threads on one address, hiding one leaves the other Active and the
  /// handshake then refuses — after the first thread's messages are already
  /// gone. Rust retires them all, so the prepare that follows succeeds by
  /// construction. A failure aborts before any spend.
  Future<void> _startOver(ConversationDto conversation) async {
    final confirmed = await Navigator.of(context).push<bool>(
      KvSheetRoute<bool>(
        builder: (_) =>
            _StartOverSheet(label: contactLabel(conversation), bond: _bond),
      ),
    );
    if (confirmed != true) return;
    final WipeReportDto retired;
    try {
      retired = await _messaging.startOver(conversation.contactAddress);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(displayError(e))));
      return;
    }
    if (!mounted) return;
    // The sheet promised the messages do not come back. Without a durable floor
    // an opt-in history catch-up can return them, and the user is the only one
    // who can act on that — so it rides the CONFIRM SHEET's own note, not a
    // SnackBar. A SnackBar here is buried within a frame: `_runPrepare` opens a
    // modal bottom sheet over exactly where it renders, on the one path that
    // also spends 0.2 KAS.
    final bond =
        'Carries a ${kasCanonical(_bond)} KAS bond — the network norm. It '
        'comes back when they accept; if their app still has you as a contact '
        'it may complete the chat silently and the bond is not returned.';
    await _runPrepare(
      () => _messaging.prepareHandshake(conversation.contactAddress),
      preparingObject: 'contact request',
      contextNote: retired.floorPersisted
          ? bond
          : 'Your old messages were deleted, but history catch-up could not be '
                'stopped for them — they may come back. $bond',
    );
  }

  /// The total erase: every conversation, every message, every local trace.
  ///
  /// Irreversible, so the confirm names the COUNT rather than asking "are you
  /// sure" — a number the user can check against what they think they have is
  /// a far better guard than a second tap, and it costs no new widget.
  ///
  /// Deliberately not a hold-to-confirm: DS §3 rations the glow treatment to
  /// primary actions and live data, and dressing a destructive erase in the
  /// signing control's teal would say the opposite of what it does.
  Future<void> _wipeAll() async {
    KvHaptic.selection();
    // Asked of Rust, never counted off this screen's list: that list filters
    // hidden conversations and the wipe destroys them too, so the visible
    // number would under-promise by exactly the rows the user already tried to
    // put out of sight — and the number is the consent.
    final WipeReportDto preview;

    try {
      preview = await _messaging.wipePreview();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(displayError(e))));
      return;
    }
    if (!mounted) return;
    if (preview.conversations == 0 && preview.messages == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('There is nothing to delete.')),
      );
      return;
    }
    final confirmed = await Navigator.of(context).push<bool>(
      KvSheetRoute<bool>(
        builder: (_) => _WipeAllSheet(preview: preview, bond: _bond),
      ),
    );
    if (confirmed != true) return;
    try {
      final report = await _messaging.wipeAll();
      // **The address book's cache goes with the store it mirrors.** The wipe
      // clears `contact.names` as a side file, but `ContactsService` holds the
      // last read in memory — so the first frames of the next Send screen
      // would paint contacts the wipe destroyed, which is the exact "claim
      // about data that no longer exists" `WipeReportDto` documents itself
      // against (`wallet-security-auditor`, UX-R2B).
      await ContactsService.instance.refresh();
      if (!mounted) return;
      final deleted =
          'Deleted ${report.conversations} conversation'
          '${report.conversations == 1 ? '' : 's'} '
          'and ${report.messages} message'
          '${report.messages == 1 ? '' : 's'}.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          // The floor is what makes the erase stick against the next history
          // catch-up. If it did not persist, the sheet's "cannot be undone"
          // is not yet true and the user is the only one who can act on it —
          // so this is the one outcome that gets its own sentence and its own
          // dwell time, rather than a success line that quietly isn't.
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
      if (!mounted) return;
      // Never a silent failure on a destructive action: the user must not walk
      // away believing their messages are gone when they are still here.
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(displayError(e))));
    }
  }

  /// Empty one thread, keep the conversation. The narrow half of "delete this
  /// chat" — the row stays listed and stays sendable, so a counterparty who
  /// never re-announces themselves is not orphaned (the reason hide
  /// tombstones rather than deletes).
  Future<void> _clearMessages(ConversationDto conversation) async {
    final confirmed = await Navigator.of(context).push<bool>(
      KvSheetRoute<bool>(
        builder: (_) => _ClearMessagesSheet(label: contactLabel(conversation)),
      ),
    );
    if (confirmed != true) return;
    try {
      final report = await _messaging.clearMessages(
        conversation.conversationId,
      );
      if (!mounted) return;
      final n = report.messages;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: report.floorPersisted
              ? const Duration(seconds: 4)
              : const Duration(seconds: 10),
          content: Text(
            report.floorPersisted
                ? (n == 1 ? '1 message cleared.' : '$n messages cleared.')
                : '$n cleared — but history catch-up could not be stopped for '
                      'this thread, so they may come back.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      // A partial clear is real — some rows ARE gone. Say what went wrong
      // rather than a count, which would read as "nothing happened".
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(displayError(e))));
    }
  }

  /// Give this address a local name — or clear it back to the address.
  Future<void> _nameContact(ConversationDto conversation) async {
    // **The house part, not a second copy** (BG-21). `_NameSheet` was a
    // hand-rolled Material sheet doing exactly what `showContactNameSheet`
    // already does for the Send screen's address book — same question, same
    // address, two shapes (`ux-auditor` BLOCK, UX-R5).
    final name = await showContactNameSheet(
      context,
      address: conversation.contactAddress,
      initial: conversation.contactName,
    );
    if (!mounted || name == null) return;
    await _messaging.setContactName(conversation.contactAddress, name);
  }

  /// The zombie-cleanup affordance (D-068): confirm → hide. Local only;
  /// nothing leaves the device. The row is tombstoned, so their next message
  /// reopens the thread.
  Future<void> _hide(ConversationDto conversation) async {
    final confirmed = await Navigator.of(context).push<bool>(
      KvSheetRoute<bool>(
        builder: (_) => _HideSheet(
          label: contactLabel(conversation),
          isInvitation: conversation.status == 'pending_in',
        ),
      ),
    );
    if (confirmed != true) return;
    await _messaging.hide(conversation.conversationId);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Conversation hidden.')));
  }

  /// **One card: the tab row, then this tab's rows** (`M1` measured at 4× —
  /// a single `plate` at radius 28, the house hairline between rows at a
  /// 69 dp pitch, and the tabs inside it above the first rule).
  ///
  /// It was a `TabBar` over a `ListView` of separate `Material` cards with
  /// 12 dp of ground between them: five plates where the render draws one.
  /// [KvRowContainer]'s `header` slot is the seat the money screen's
  /// Activity · Tokens row already uses, so the tabs need no second shape.
  Widget _card({
    required List<ConversationDto> rows,
    required String emptyCopy,
    required int requestCount,
    Widget? gloss,
  }) {
    return KvRowContainer(
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          KvTabs(
            tabs: [
              const KvTab('Chats'),
              // A count, never a red dot: the number is the useful part, and
              // each one of these asks the user to spend.
              KvTab('Requests', count: requestCount == 0 ? null : requestCount),
            ],
            index: _tab,
            onSelect: (i) {
              KvHaptic.selection();
              setState(() => _tab = i);
            },
          ),
          ?gloss,
        ],
      ),
      children: [
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: KvSpace.l),
            child: Text(
              emptyCopy,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 13,
                height: 18 / 13,
                fontWeight: FontWeight.w400,
                fontVariations: KvWeight.w400,
                color: KvColor.inkDim,
              ),
            ),
          )
        else
          for (final (index, conversation) in rows.indexed)
            Entrance(
              index: index,
              child: _ConversationRow(
                conversation: conversation,
                onOpen: () => _openThread(conversation),
                onAccept: () => _accept(conversation),
                onActions: () => _rowActions(conversation),
                onIgnore: () => _hide(conversation),
                onDismissExpired: () => _dismissExpired(conversation),
              ),
            ),
      ],
    );
  }

  /// `M5 · Message settings` — the overflow's sheet. It replaced a
  /// `PopupMenuButton` holding one item: a Material menu on a screen with no
  /// other Material left on it.
  Future<void> _messageSettings() async {
    KvHaptic.selection();
    final action = await Navigator.of(context).push<String>(
      KvSheetRoute<String>(builder: (_) => _MessageSettingsSheet(bond: _bond)),
    );
    if (!mounted || action == null) return;
    if (action == 'history') {
      await showHistoryFillSheet(context, _messaging, onBackUp: _backUp);
    } else if (action == 'wipe') {
      await _wipeAll();
    }
  }

  /// Name and address, folded to one case and matched as substrings — the two
  /// things `M1`'s field says it searches. Nothing leaves the device and
  /// nothing is decrypted: both fields are already on the row.
  bool _matches(ConversationDto c) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final name = c.contactName?.toLowerCase() ?? '';
    return name.contains(q) || c.contactAddress.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        child: Column(
          children: [
            KvTopBar(
              title: 'Messages',
              page: true,
              onBack: () => Navigator.of(context).maybePop(),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The V2b visible toggle's home (D-074): reachable ALWAYS,
                  // not only when the gap banner shows.
                  KvIconButton(
                    mark: KvGlyph.history,
                    label: 'History & backup',
                    tone: KvColor.inkNav,
                    onTap: () {
                      KvHaptic.selection();
                      showHistoryFillSheet(
                        context,
                        _messaging,
                        onBackUp: _backUp,
                      );
                    },
                  ),
                  // **No gap between them, and that is the render.** `M1`
                  // measures the two discs at x 272.0..315.8 and 324.0..367.8
                  // — 8 dp apart, which is exactly what two adjacent 52 dp
                  // targets holding 44 dp discs already produce. A
                  // `touchGap` here made it 16, and the 8 dp it stole came
                  // out of the title: at 320 dp / 1.3× the bar rendered
                  // `Messag / es`, a word broken mid-syllable — D-285's
                  // finding one file over, found the same way, in the floor
                  // frame.
                  KvIconButton(
                    mark: KvGlyph.kebab,
                    label: 'Message settings',
                    tone: KvColor.inkNav,
                    onTap: _messageSettings,
                  ),
                ],
              ),
            ),
            Expanded(
              child: KvColumn(
                child: ValueListenableBuilder<List<ConversationDto>>(
                  valueListenable: _messaging.conversations,
                  builder: (context, conversations, _) {
                    // Chats are the conversations you can actually open; every
                    // invitation waiting on YOU lives in Requests. Keeping them
                    // in one list meant a bond-spending Accept card sat between
                    // two threads, and a stranger could push your real
                    // conversations down the screen by inviting you.
                    final chats = conversations
                        .where((c) => c.status != 'pending_in')
                        .where(_matches)
                        .toList();
                    // **The badge counts every request, the list draws the
                    // matching ones.** Both were taken from the filtered set,
                    // so typing anything into the Chats search silently zeroed
                    // the Requests count and suppressed the gloss's price —
                    // and each of those rows is a stranger's bonded money
                    // waiting on a decision (`wallet-security-auditor`, UX-R5;
                    // the tab's own design note says a Requests tab reading
                    // nothing must MEAN nobody is waiting on you).
                    final pending = conversations
                        .where((c) => c.status == 'pending_in')
                        .toList();
                    final requests = pending.where(_matches).toList();
                    final searching = _query.trim().isNotEmpty;
                    return Column(
                      children: [
                        const SizedBox(height: KvSpace.sm),
                        KvSearchField(
                          hint: 'Search people or addresses',
                          controller: _search,
                          onChanged: (q) => setState(() => _query = q),
                        ),
                        const SizedBox(height: KvSpace.m),
                        // The honest gap notice (D-074: never silence) —
                        // renders only when history may be incomplete; tap
                        // opens the fill sheet.
                        HistoryNoticeBanner(
                          messaging: _messaging,
                          onBackUp: _backUp,
                        ),
                        Expanded(
                          child: KvScrollEdge(
                            ground: KvColor.abyss,
                            child: ListView(
                              padding: const EdgeInsets.only(bottom: KvSpace.m),
                              children: [
                                if (_tab == 0)
                                  _card(
                                    rows: chats,
                                    requestCount: pending.length,
                                    emptyCopy: searching
                                        ? 'No conversation matches '
                                              '\u201c${_query.trim()}\u201d.'
                                        : 'No conversations yet.\nStart one by '
                                              'address \u2014 the handshake '
                                              'rides the Kaspa L1 itself.',
                                  )
                                else
                                  _card(
                                    rows: requests,
                                    requestCount: pending.length,
                                    // `M2` puts the explainer inside the card,
                                    // under the tabs and above the first
                                    // request — it defines what this tab IS,
                                    // and it names the price of accepting.
                                    gloss: _RequestsGloss(
                                      bond: _bond,
                                      canAccept: pending.any(
                                        (c) => !c.inviteExpired,
                                      ),
                                    ),
                                    emptyCopy: searching
                                        ? 'No request matches '
                                              '\u201c${_query.trim()}\u201d.'
                                        : 'No one is waiting on you.\n'
                                              'Invitations from people you '
                                              'have not met appear here.',
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            // `M1`'s foot: the one lit control on the screen, 56 deep and
            // 24 clear of the bottom edge (measured — the pill runs
            // y 772.0..828.0 in an 852 dp window).
            //
            // **Inside `KvColumn`, like everything else on the screen.** It
            // sat outside, taking only the gutter — so at `expanded` the pill
            // measured **1100 dp** across a 480 dp content column, and 835 at
            // `expanded short`: the one lit control on the screen, 2.3× the
            // width of the list it belongs to (BG-33, `ux-auditor` BLOCK,
            // UX-R5, read off the frames).
            KvColumn(
              child: Padding(
                padding: const EdgeInsets.only(
                  top: KvSpace.sm,
                  bottom: KvSpace.l,
                ),
                child: KvAction(
                  label: 'New handshake',
                  primary: true,
                  mark: KvGlyph.userPlus,
                  onTap: () {
                    KvHaptic.selection();
                    _addContact();
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Long-press actions for one row. Two choices, named plainly — a menu this
/// short does not need icons or a title bar competing with them.
class _RowActionsSheet extends StatelessWidget {
  const _RowActionsSheet({
    required this.label,
    required this.canName,
    required this.bond,
    this.canStartOver = false,
    this.canClear = true,
  });

  final String label;

  /// An invitation carries no address until its sender is recorded, and a
  /// name is keyed on the address — so there is nothing to name yet.
  final bool canName;

  /// Active conversations only, and never a replaced one. Starting over hides
  /// the thread, and hiding an invitation is permanent — it would bury the only
  /// route to refunding the bond the counterparty already paid, while spending
  /// one of ours. On a replaced row it would retire the working successor too.
  final bool canStartOver;

  /// An invitation's only message row is its handshake, which the clear
  /// deliberately keeps (a bond gate reads it) — so clearing one is a no-op
  /// that reports zero.
  final bool canClear;

  /// The price of the request `Start over` sends, from Rust rather than from
  /// a string — the same figure `M2`'s gloss quotes, and the same reason.
  final BigInt bond;

  @override
  Widget build(BuildContext context) {
    return KvSheet(
      title: label,
      cancelLabel: 'Close',
      cancelTone: KvColor.inkDim,
      onCancel: () => Navigator.of(context).pop(),
      child: KvRowContainer(
        // A card inside a sheet is `chip` (§1.1, D-293).
        ground: KvColor.chip,
        children: [
          if (canName)
            KvRow(
              dense: true,
              ground: KvColor.chip,
              titleLines: 2,
              leading: const KvRowDisc.neutral(mark: KvGlyph.identity),
              title: 'Name this contact',
              sub: 'Shown only on this device',
              trailing: const KvGlyphIcon(
                KvGlyph.chevron,
                size: 20,
                tone: KvColor.etch,
              ),
              onTap: () => Navigator.of(context).pop('name'),
            ),
          if (canStartOver)
            KvRow(
              dense: true,
              ground: KvColor.chip,
              titleLines: 2,
              leading: const KvRowDisc.neutral(mark: KvGlyph.userPlus),
              title: 'Start over with this contact',
              sub:
                  'Deletes your messages and sends a new request '
                  '(${kasCanonical(bond)} KAS)',
              subLines: 2,
              trailing: const KvGlyphIcon(
                KvGlyph.chevron,
                size: 20,
                tone: KvColor.etch,
              ),
              onTap: () => Navigator.of(context).pop('restart'),
            ),
          KvRow(
            dense: true,
            ground: KvColor.chip,
            // A label WRAPS; only a number may not (BG-14). At 320 dp / 1.3×
            // these came out `History & bac…`, `Handsh…`, `Delete all mes…` —
            // and `Handsh…` names nothing (`ux-auditor`, D-293's own defect at
            // a new call site).
            titleLines: 2,
            leading: const KvRowDisc.neutral(mark: KvGlyph.trash),
            title: 'Clear messages',
            // The distinction from Hide, in one line: this one keeps the
            // conversation working. Without it the two read as the same
            // gesture and the user picks the wrong one. And a greyed-out row
            // with no reason is worse than no row — say why on the one card
            // where the user would ask.
            sub: canClear
                ? 'Empties the thread; you can still message'
                : 'Nothing to clear until you accept',
            subLines: 2,
            trailing: KvGlyphIcon(
              KvGlyph.chevron,
              size: 20,
              tone: canClear ? KvColor.etch : Colors.transparent,
            ),
            onTap: canClear ? () => Navigator.of(context).pop('clear') : null,
          ),
          KvRow(
            dense: true,
            ground: KvColor.chip,
            // A label WRAPS; only a number may not (BG-14). At 320 dp / 1.3×
            // these came out `History & bac…`, `Handsh…`, `Delete all mes…` —
            // and `Handsh…` names nothing (`ux-auditor`, D-293's own defect at
            // a new call site).
            titleLines: 2,
            leading: const KvRowDisc.neutral(mark: KvGlyph.eyeOff),
            title: 'Hide conversation',
            // Says the destructive half FIRST. It read as the gentlest item
            // in the menu and it purges the thread.
            sub: 'Clears the thread; comes back if they write',
            subLines: 2,
            trailing: const KvGlyphIcon(
              KvGlyph.chevron,
              size: 20,
              tone: KvColor.etch,
            ),
            onTap: () => Navigator.of(context).pop('hide'),
          ),
        ],
      ),
    );
  }
}

/// Contact display label: the name the user gave this address, else the
/// address itself (truncated). Identity is still pubkeys + aliases (D-049) —
/// a name is a local label over the top, never a claim about who someone is,
/// and never anything the counterparty can set.
String contactLabel(ConversationDto c) {
  final name = c.contactName;
  if (name != null && name.isNotEmpty) return name;
  return c.contactAddress.isEmpty
      ? 'Unknown sender'
      : truncateAddressPayload(c.contactAddress);
}

/// **One conversation, as `M1` draws it** — the person disc, their name, one
/// line saying what this row IS, and the time of its last activity.
///
/// ## What the render asks for that this build does not draw
///
/// `M1`'s second line is the **last message** (*"Got it, thank you — confirmed
/// on my side"*) and its trailing column carries an **unread count**. Neither
/// is drawn here, and neither is a styling decision:
///
///  - **The preview.** `transport_conversations` is registered in the Source
///    of Truth as *public-wire-class data only*, and message bodies are
///    `MessageRecord.envelope` — sealed at rest (§0.4), opened on view, inside
///    the thread's own state object, which disposes them with the screen. A
///    preview means opening the newest envelope of every conversation on every
///    list refresh and holding that plaintext in a list widget that outlives
///    any thread. That is a custody change, not a layout one.
///  - **The count.** There is **no read state anywhere in the stack** — not in
///    `TransportStore`, not on the DTO, not in the service. A number here
///    would have nothing behind it.
///
/// So the second line carries what the row honestly knows, which is its
/// **state** — an invitation, a replaced thread, one awaiting their accept —
/// and nothing at all where the row has no news. An openable conversation is
/// one line and a time, and that is the whole row.
///
/// **The address is deliberately NOT here, and this was reconsidered rather
/// than assumed.** A name is a local label over an address (D-049), and the
/// counterparty surface is what an address-poisoning attack aims at — so the
/// key belongs beside the name. But it belongs where it is *actionable*: in
/// `M4`'s bar, which is the render's own answer, and which is the screen a
/// user is looking at when they attach a payment to a person. On a list of
/// five rows the address is five 19-character strings nobody reads, and the
/// pre-UX-R5 rule — a name **replaces** the address, never sits beside it —
/// is already pinned by a test. The render agrees: `M1`'s second line is a
/// message, never a key.
class _ConversationRow extends StatelessWidget {
  const _ConversationRow({
    required this.conversation,
    required this.onOpen,
    required this.onAccept,
    required this.onActions,
    required this.onIgnore,
    required this.onDismissExpired,
  });

  final ConversationDto conversation;
  final VoidCallback onOpen;
  final VoidCallback onAccept;
  final VoidCallback onActions;
  final VoidCallback onIgnore;
  final VoidCallback onDismissExpired;

  @override
  Widget build(BuildContext context) {
    final c = conversation;
    // Rust's expiry taxonomy (V5, finding 15): an expired pending-inbound
    // invitation can NEVER be accepted (its bond is pruned) — the row tells
    // the truth and offers the exit instead of a dead Accept.
    final expired = c.status == 'pending_in' && c.inviteExpired;
    final pendingIn = c.status == 'pending_in' && !expired;
    final pendingOut = c.status == 'pending_out';
    // Rust's derived rule: a newer live thread with this same contact exists,
    // so this one's alias reaches nobody. It stays open and readable — the
    // history is real — but it can no longer be typed in.
    final replaced = c.superseded;
    final initial = c.contactName?.trim();

    // ORDER MATTERS, AND IT MUST MATCH THE ACTION CHAIN BELOW. When the label
    // said one thing and the body another, a `pending_in` row could render
    // "Wants to connect" over the Replaced body — losing its Accept button and
    // with it the only route to refunding the counterparty's bond.
    final String? state = expired
        ? 'Invitation expired'
        : pendingIn
        ? 'Wants to connect'
        : replaced
        ? 'Replaced by a newer thread'
        : pendingOut
        ? 'Awaiting their accept'
        : null;

    // A request or an expired invitation is answered on the row, so the row
    // itself is not a door — its actions are (BG-12: one target, one act).
    final opens = !(pendingIn || expired);

    // **`ExcludeSemantics` wraps the ROW, never the actions.** It dropped the
    // whole subtree's semantics, taking `KvAction`'s and `_TextAction`'s own
    // nodes with it: `find.text('Accept…')` matched and
    // `find.bySemanticsLabel('Accept…')` found nothing, so a screen-reader user
    // could not reach the only control that returns a stranger's bond, nor
    // Dismiss an expired invitation (`wallet-security-auditor`, UX-R5 — a
    // regression against the `FilledButton` this replaced, invisible to the
    // widget tests because `find.text` matches straight through).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: opens,
          label: state == null ? contactLabel(c) : '${contactLabel(c)}, $state',
          child: ExcludeSemantics(
            child: KvRow(
              dense: true,
              // Two disc seats, not five (see [KvRowDisc.initial]): a contact
              // we hold wears their initial on the teal tint; a stranger
              // asking to be let in wears the neutral `userPlus`, which is
              // `M2`'s own disc.
              // **[KvContactAvatar], the house part** — `chip` + `ink` for a
              // contact we hold, the `inkMeta` `identity` glyph for a stranger
              // (§4 as amended v4.8, measured off `S6a`/`S6`/`S8`). This drew
              // its own `tealTint` disc for a beat, which is the face §4
              // reserves for the wallet's own mark, so one contact wore two
              // faces across Send and Messages (`ux-auditor` BLOCK, BG-21).
              // A request keeps `userPlus`: a stranger asking to be let in is
              // not the same object as a contact with no name.
              leading: pendingIn || expired
                  ? const KvRowDisc.neutral(mark: KvGlyph.userPlus)
                  : KvContactAvatar(name: initial, size: KvRowDisc.person),
              title: contactLabel(c),
              // **An unnamed contact's name IS a key, so it is drawn as one.**
              // `contactLabel` returns an already-truncated
              // `kaspa:qz7u…ellj43pf`, and `KvRow.title` is a UI-face `Text`
              // with `overflow: ellipsis` — at 320 dp / 1.3× the row ellipsised
              // it a SECOND time, to `kaspa:qz…`, where two different keys
              // sharing a 4-character head render as identical rows. Measured
              // on the real screen: a 103.8 dp title box against 198.6 needed
              // (`wallet-security-auditor`, UX-R5). The whole address goes
              // through `KvAddress` instead, which weights both ends, scales to
              // its own floor rather than clipping, and asserts against exactly
              // this double truncation.
              titleWidget:
                  (initial == null || initial.isEmpty) &&
                      c.contactAddress.isNotEmpty
                  ? KvAddress(
                      c.contactAddress,
                      form: KvAddressForm.compact,
                      fontSize: 13,
                    )
                  : null,
              subWidget: state == null
                  ? null
                  : Text(
                      state,
                      // Two lines: at 320 dp / 1.3× `Replaced by a newer
                      // thread` came out `Replaced by a new…`, losing the word
                      // that names the state (BG-20/BG-14, `ux-auditor`).
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 12,
                        height: 16 / 12,
                        fontWeight: FontWeight.w400,
                        fontVariations: KvWeight.w400,
                        color: KvColor.inkMeta,
                      ),
                    ),
              trailing: _When(unixMs: c.lastActivityUnixMs),
              // A record's own time is not a value, so the trailing column
              // needs none of `KvRow`'s width for a figure — leaving it to
              // the name, which is the part that ellipsises.
              trailingCap: 96,
              onTap: opens ? onOpen : null,
              // Long-press anywhere on the row → name / start over / clear /
              // hide (D-068). It was `InkWell.onLongPress` on the old card.
              onLongPress: onActions,
            ),
          ),
        ),
        if (expired)
          _RequestActions(
            accept: null,
            // **Founder-ruled wording (V5, finding 15)** — kept verbatim. The
            // bond is pruned, so the copy makes no transient promise and
            // offers the exit instead. A longer sentence explaining the
            // pruning horizon was drafted here and withdrawn: the words on a
            // terminal state are his call, not a rewrite's.
            acceptReason:
                'This invitation has expired and can no longer be accepted.',
            onIgnore: onDismissExpired,
            ignoreLabel: 'Dismiss',
          )
        else if (pendingIn)
          _RequestActions(accept: onAccept, onIgnore: onIgnore),
      ],
    );
  }
}

/// A conversation's last activity, in the trailing column — `09:44` today,
/// `Yesterday`, a weekday inside the week, then a date (`M1`, which draws all
/// four). The clock is mono and the words are not: BG-30 sets a figure in the
/// mono face and words in the UI face, and `Yesterday` is not a figure.
class _When extends StatelessWidget {
  const _When({required this.unixMs});

  final BigInt unixMs;

  @override
  Widget build(BuildContext context) {
    final at = DateTime.fromMillisecondsSinceEpoch(unixMs.toInt());
    final now = DateTime.now();
    final day = DateTime(at.year, at.month, at.day);
    final today = DateTime(now.year, now.month, now.day);
    final days = today.difference(day).inDays;
    final (String text, bool mono) = days == 0
        ? (
            '${at.hour.toString().padLeft(2, '0')}:'
                '${at.minute.toString().padLeft(2, '0')}',
            true,
          )
        : days == 1
        ? ('Yesterday', false)
        : days < 7
        ? (_weekdays[at.weekday - 1], false)
        : ('${at.day} ${_months[at.month - 1]}', true);
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.end,
      style: TextStyle(
        fontFamily: mono ? KvFont.mono : KvFont.ui,
        fontSize: 12,
        height: 16 / 12,
        fontWeight: FontWeight.w400,
        fontVariations: KvWeight.w400,
        color: KvColor.inkMeta,
        fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
      ),
    );
  }
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// `M2`'s action row under a request: one raised **Accept…** and one quiet
/// **Ignore**.
///
/// **The render draws a third, `Block`, and this build does not.** There is no
/// blocklist anywhere in the stack — not in `TransportStore`, not on the
/// inbound scan — so the word would name a promise nothing keeps: a blocked
/// stranger's next handshake would arrive exactly as before. It needs a
/// persisted set the scan consults before it mints a row, which is Rust work
/// and a T3 change, not a button. Said in the sitting.
///
/// **Ignore is real and already built**: it is the D-068 hide — local, silent
/// to the counterparty, and reversible, because their next message reopens the
/// thread. That is what "ignore" means, and it is why the word is not
/// "Delete".
///
/// The ellipsis on Accept is load-bearing (BG-11): accepting posts a bond, so
/// it opens the confirm ceremony rather than spending on the tap.
class _RequestActions extends StatelessWidget {
  const _RequestActions({
    required this.accept,
    required this.onIgnore,
    this.acceptReason,
    this.ignoreLabel = 'Ignore',
  });

  final VoidCallback? accept;
  final String? acceptReason;
  final VoidCallback onIgnore;
  final String ignoreLabel;

  @override
  Widget build(BuildContext context) {
    final accept = this.accept;
    return Padding(
      // **Aligned with the row's own text column**, which is where `M2` puts
      // them: its Accept pill starts at x 97.0 — the container's content edge
      // (44) plus the disc and the gap [KvRow] sets between them. The actions
      // belong to the message above them, and a pill under the disc reads as
      // belonging to the card instead.
      padding: const EdgeInsets.only(
        left: KvSpace.rowDisc + KvSpace.sm,
        bottom: KvSpace.sm,
      ),
      // **A `Wrap`, not a `Row`.** `KvSectionHeader`'s lesson (D-285) and
      // `KvRow`'s (D-293), for the third time and found the same way: at
      // 320 dp / 1.3× the pill and the quiet action overran the indented row
      // by 25 dp in the floor frame. A `Wrap` needs no threshold and no
      // measurement — side by side while they fit, stacked the moment they do
      // not, and neither word ever ellipsises.
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: KvSpace.s,
        children: [
          if (accept != null)
            // `KvAction` stretches to the width it is given, and a `Wrap`
            // child is given none — an unbounded width is a layout assertion,
            // not a wide button. `IntrinsicWidth` bounds it at its own
            // content, which is what `M2` draws: a pill around the words, with
            // the quiet action beside it.
            IntrinsicWidth(
              child: KvAction.raised(
                label: 'Accept…',
                // **52, the floor** (BG-12, raised at v4.2 with nothing
                // grandfathered). It was `touchTarget - s` = 44, on the one
                // control that returns a stranger's bonded money, next to an
                // `Ignore` that was correctly 52 (`ux-auditor` BLOCK, UX-R5).
                height: KvSpace.touchTarget,
                onTap: () {
                  KvHaptic.selection();
                  accept();
                },
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: Text(
                acceptReason!,
                style: const TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 12,
                  height: 16 / 12,
                  fontWeight: FontWeight.w400,
                  fontVariations: KvWeight.w400,
                  color: KvColor.inkMeta,
                ),
              ),
            ),
          _TextAction(label: ignoreLabel, onTap: onIgnore),
        ],
      ),
    );
  }
}

/// A word that acts, with no pill under it (`M2`'s `Ignore`, §4's ghost
/// action). `inkDim`, never teal: BG-2 rations `primary` to the one lit
/// control, and this row's lit control is Accept.
class _TextAction extends StatelessWidget {
  const _TextAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            KvHaptic.selection();
            onTap();
          },
          child: SizedBox(
            height: KvSpace.touchTarget,
            // **`Align(widthFactor: 1)`, not `Center`.** A `Wrap` hands its
            // children a LOOSE width constraint, and a bare `Center` takes all
            // of it — so `Ignore` claimed the whole row and pushed itself onto
            // a second line beside a pill a third of the width. `widthFactor`
            // sizes the box to the word, which is what makes the two sit
            // together while they fit. The 52 dp height is untouched: a target
            // never shrinks (BG-12).
            child: Align(
              alignment: Alignment.center,
              widthFactor: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: KvSpace.sm),
                child: Text(
                  label,
                  style: const TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 14,
                    height: 20 / 14,
                    fontWeight: FontWeight.w600,
                    fontVariations: KvWeight.w600,
                    color: KvColor.inkDim,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `M2`'s explainer, inside the card under the tabs: what this lane is, and
/// what accepting costs. The figure is [MessagingService.handshakeBondSompi]
/// — Rust's own `HANDSHAKE_BOND_SOMPI` — never a literal, because the render's
/// own `0.0001 KAS` is a designer's placeholder and the real bond is 0.2.
class _RequestsGloss extends StatelessWidget {
  const _RequestsGloss({required this.bond, required this.canAccept});

  final BigInt bond;

  /// Whether any row in this lane can actually be accepted.
  ///
  /// **A lane holding only EXPIRED invitations must not price accepting.**
  /// Their bonds are past the node's pruning horizon and can never be
  /// returned — the row's own copy says so — and a header offering to spend
  /// over it is V5 finding-15's transient promise, one level up
  /// (`consensus-auditor`, UX-R5).
  final bool canAccept;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: KvSpace.sm),
      child: Text.rich(
        TextSpan(
          children: [
            const TextSpan(
              text: 'Strangers who paid to open a conversation with you.',
            ),
            // **One obligation, not two.** `transport_prepare_accept` builds
            // exactly ONE send of `HANDSHAKE_BOND_SOMPI` back to the sender —
            // the refund IS the handshake response, there is no second half.
            // The old wording ("returns their bond AND posts your half of the
            // handshake — 0.20 KAS") read as either 0.20 or 0.40
            // (`consensus-auditor`, traced to the prepare).
            if (canAccept) ...[
              const TextSpan(text: ' Accepting returns their '),
              TextSpan(
                text: kasCanonical(bond),
                style: const TextStyle(
                  fontFamily: KvFont.mono,
                  color: KvColor.inkDim,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const TextSpan(text: ' KAS bond and opens the conversation.'),
            ],
          ],
        ),
        style: const TextStyle(
          fontFamily: KvFont.ui,
          fontSize: 13,
          height: 18 / 13,
          fontWeight: FontWeight.w400,
          fontVariations: KvWeight.w400,
          color: KvColor.inkMeta,
        ),
      ),
    );
  }
}

/// Confirm hiding a conversation (the zombie-cleanup affordance). Honest copy:
/// this is local only — it removes nothing from the chain and tells the
/// counterpart nothing.
/// **The confirm sheet these four ceremonies share** (`ux-auditor` BLOCK,
/// UX-R5).
///
/// Hide · Start over · Delete all · Clear messages were four hand-rolled
/// `showModalBottomSheet` columns: a centred `titleMedium`, their own gutter,
/// a `FilledButton.tonal` and a `TextButton`. Four Material surfaces on a
/// screen with no Material left on it, and four chances to disagree about
/// where a confirm's title sits (BG-21). The words are untouched; only the
/// shape moved onto [KvSheet], which owns the grabber, the gutter, the air
/// above the act, the scrim tap and D-277's red way out.
///
/// **The act is `raised`, never `primary`, on every one of them.** Three of
/// the four destroy something, and §3 rations teal to the signing control —
/// dressing an erase in it would say the opposite of what it does (D-262's
/// own reasoning for refusing the glow on this screen's wipe).
class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({
    required this.title,
    required this.act,
    required this.body,
    this.subject,
    this.destructive = false,
  });

  final String title;

  /// Verb plus object, never "Confirm" (BG-11).
  final String act;

  /// What the act costs, in the user's words.
  final Widget body;

  /// The thing being acted on — a contact's label, on its own line.
  final String? subject;

  /// The total erase, and nothing else. See [KvAction.destructive]: the added
  /// ceremony weight is a `risk` fill, because a `raised` act here reads
  /// identical to the benign "Clear messages" confirm one gesture away and the
  /// two do very different things.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final subject = this.subject;
    return KvSheet(
      title: title,
      onCancel: () => Navigator.of(context).pop(false),
      foot: destructive
          ? KvAction.destructive(
              label: act,
              onTap: () => Navigator.of(context).pop(true),
            )
          : KvAction.raised(
              label: act,
              onTap: () => Navigator.of(context).pop(true),
            ),
      // `KvSheet` flexes its body and leaves the scrolling to the caller,
      // which is what keeps the act out of the scroll (D-221 §1). The wipe's
      // body is five paragraphs and overflowed by 32 dp without this.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (subject != null) ...[
              Text(
                subject,
                style: const TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 16,
                  height: 20 / 16,
                  fontWeight: FontWeight.w600,
                  fontVariations: KvWeight.w600,
                  color: KvColor.ink,
                ),
              ),
              const SizedBox(height: KvSpace.sm),
            ],
            DefaultTextStyle(
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 13,
                height: 18 / 13,
                fontWeight: FontWeight.w400,
                fontVariations: KvWeight.w400,
                color: KvColor.inkDim,
              ),
              child: body,
            ),
          ],
        ),
      ),
    );
  }
}

class _HideSheet extends StatelessWidget {
  const _HideSheet({required this.label, required this.isInvitation});

  final String label;
  final bool isInvitation;

  @override
  Widget build(BuildContext context) {
    return _ConfirmSheet(
      title: 'Hide conversation',
      act: 'Hide',
      subject: label,
      body: Text(
        isInvitation
            ? 'Turns down this invitation and clears it from your device. '
                  "Nothing is deleted on-chain and they aren't notified, but "
                  "you won't hear from them again unless they send a new "
                  'request.'
            : 'Clears the messages from your device and hides the thread. '
                  "Nothing is deleted on-chain and they aren't notified, so "
                  'they can still write to you — a new message brings the '
                  'thread back.',
      ),
    );
  }
}

class _StartOverSheet extends StatelessWidget {
  const _StartOverSheet({required this.label, required this.bond});

  final String label;

  /// The price of the request this sheet is about to send, from Rust.
  final BigInt bond;

  @override
  Widget build(BuildContext context) {
    return _ConfirmSheet(
      title: 'Start over',
      act: 'Review request',
      subject: label,
      body: Text(
        'Deletes your messages with this contact — every conversation you '
        'have with them — hides those threads, and sends a fresh contact '
        'request carrying the usual ${kasCanonical(bond)} KAS bond.\n\n'
        'Use this when messages stop getting through. It works best when they '
        'have also cleared their side — an app that still has you as a '
        'contact may accept silently and send nothing back, in which case the '
        'bond is not returned. A thread comes back if they write to it again '
        '— the messages do not.',
      ),
    );
  }
}

class _WipeAllSheet extends StatelessWidget {
  const _WipeAllSheet({required this.preview, required this.bond});

  /// Rust's count of what the wipe would destroy — hidden rows included.
  final WipeReportDto preview;

  /// The bond each stranded sender paid, from Rust. This sheet is the one
  /// irreversible ceremony in the surface and the figure it quotes is
  /// **somebody else's money** that the erase makes unreturnable — the last
  /// place a remembered constant belongs (`consensus-auditor` BLOCK, UX-R5:
  /// the literal survived the sweep here because it was split across two
  /// source lines, where the grep that found the others could not see it).
  final BigInt bond;

  @override
  Widget build(BuildContext context) {
    final conversationCount = preview.conversations;
    final messageCount = preview.messages;
    final plural = conversationCount == 1 ? '' : 's';
    return _ConfirmSheet(
      title: 'Delete all messages',
      act: 'Delete $conversationCount conversation$plural',
      destructive: true,
      body: Text(
        'This deletes $conversationCount conversation$plural and '
        '$messageCount message${messageCount == 1 ? '' : 's'} from this '
        'device, including any you have hidden. It cannot be undone.\n\n'
        'Messages already sent stay on Kaspa permanently — this clears your '
        'copy, not the chain, and this app will not fetch them back, '
        'including from your backup. Your wallet and coins are not '
        'touched.\n\n'
        'A contact can appear again as a new request — their messages do not '
        'come back.\n\n'
        '${preview.pendingBonds > 0 ? 'This also deletes '
                  '${preview.pendingBonds} unanswered contact '
                  'request${preview.pendingBonds == 1 ? '' : 's'} — the '
                  '${kasCanonical(bond)} KAS bond each sender paid can no '
                  'longer be returned to them.\n\n' : ''}'
        'To talk to someone again afterwards, one of you has to send a new '
        'contact request. Asking them to start it is the reliable way round: '
        'an app that still remembers you may not answer a repeat request.',
      ),
    );
  }
}

class _ClearMessagesSheet extends StatelessWidget {
  const _ClearMessagesSheet({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return _ConfirmSheet(
      title: 'Clear messages',
      act: 'Clear messages',
      subject: label,
      body: const Text(
        'Empties this thread on your device. The conversation stays on your '
        'list. Messages already on Kaspa stay there permanently; this only '
        'clears your copy.',
      ),
    );
  }
}

/// **`M3 · New handshake`** — a screen, not a sheet.
///
/// It was `_AddContactSheet`: a raw-Material bottom sheet with a `titleMedium`
/// heading, a `TextField` and a `FilledButton`. `M3` is one of the four
/// approved messages renders and draws a pushed page — an explainer card, two
/// labelled fields and a foot action that states its own refusal
/// (`ux-auditor` BLOCK, UX-R5).
///
/// **Two of the render's objects are not built, and both have a reason rather
/// than an omission:**
///
///  - **The scan button** beside Paste. There is no camera in this app: the
///    Send screen deferred the scanner to its own sitting (2026-09-04) because
///    a camera is a new dependency and a new runtime permission, which is a
///    T3 supply-chain question and not a control. Drawing the button here
///    would be the second surface promising it.
///  - **`FIRST MESSAGE · OPTIONAL`.** `transport_prepare_handshake` takes a
///    destination and nothing else — the handshake payload has no free-text
///    field, so a message typed here would go nowhere. Adding one is a wire
///    change (§0.6), not a screen.
///
/// **The name field IS built** and is real: it writes through
/// `setContactName` before the request is prepared, so the row the request
/// creates already carries the name. Device-only, never on the wire (D-049).
class NewHandshakeScreen extends StatefulWidget {
  const NewHandshakeScreen({super.key, required this.bond});

  /// What the request costs, from Rust.
  final BigInt bond;

  @override
  State<NewHandshakeScreen> createState() => _NewHandshakeScreenState();
}

class _NewHandshakeScreenState extends State<NewHandshakeScreen> {
  final _address = TextEditingController();
  final _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    _address.addListener(_onAddress);
  }

  @override
  void dispose() {
    _address.removeListener(_onAddress);
    _address.dispose();
    _name.dispose();
    super.dispose();
  }

  void _onAddress() => setState(() {});

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _address.text = text;
  }

  @override
  Widget build(BuildContext context) {
    final address = _address.text.trim();
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        child: Column(
          children: [
            KvTopBar(
              title: 'New handshake',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: KvColumn(
                child: ListView(
                  padding: const EdgeInsets.only(
                    top: KvSpace.sm,
                    bottom: KvSpace.m,
                  ),
                  children: [
                    // The explainer card: `M3` puts the mark in a teal disc
                    // beside the prose, which is `KvRowDisc.ours` — the one
                    // `primaryMuted` object on the screen (BG-2, ambient).
                    KvRowContainer(
                      divided: false,
                      inset: const EdgeInsets.all(KvSpace.s20),
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const KvRowDisc.ours(mark: KvGlyph.userPlus),
                            const SizedBox(width: KvSpace.m),
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    const TextSpan(
                                      text:
                                          'A handshake is a small on-chain '
                                          'message to their address. Once they '
                                          'answer, you both derive a shared '
                                          'key and every message travels as a '
                                          'Kaspa transaction — private, '
                                          'unstoppable, and paid for. Costs ',
                                    ),
                                    TextSpan(
                                      text: kasCanonical(widget.bond),
                                      style: const TextStyle(
                                        fontFamily: KvFont.mono,
                                        color: KvColor.ink,
                                        fontFeatures: [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                    const TextSpan(
                                      text:
                                          ' KAS, refunded when they accept, '
                                          'plus the network fee.',
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
                          ],
                        ),
                      ],
                    ),
                    const KvSectionHeader('Their address'),
                    _Field(
                      controller: _address,
                      hint: 'kaspa:…',
                      mono: true,
                      autofocus: true,
                      maxLines: 2,
                      trailing: KvPasteChip(onTap: _paste),
                    ),
                    const KvSectionHeader(
                      'Name',
                      gloss: 'stays on this device',
                    ),
                    _Field(controller: _name, hint: 'e.g. Mara'),
                  ],
                ),
              ),
            ),
            KvColumn(
              child: Padding(
                padding: const EdgeInsets.only(
                  top: KvSpace.sm,
                  bottom: KvSpace.l,
                ),
                child: KvAction(
                  label: 'Review request',
                  primary: true,
                  // The refusal IS the label (BG-27 / the disabled form): the
                  // pill says what it is waiting for rather than looking live
                  // and swallowing a tap.
                  disabledReason: address.isEmpty
                      ? 'Enter an address to continue'
                      : null,
                  // Not an unmade choice — see [KvAction.disabledMark].
                  disabledMark: false,
                  onTap: () => Navigator.of(
                    context,
                  ).pop((address: address, name: _name.text.trim())),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One labelled field on `M3` — a `plate` pill on the ground, the house
/// control height, with an optional ghost action inside it.
class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.hint,
    this.trailing,
    this.mono = false,
    this.autofocus = false,
    this.maxLines = 1,
  });

  final TextEditingController controller;
  final String hint;
  final Widget? trailing;
  final bool mono;
  final bool autofocus;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: KvSpace.control),
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.s20),
      decoration: BoxDecoration(
        color: KvColor.plate,
        borderRadius: BorderRadius.circular(KvRadius.control),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: autofocus,
              minLines: 1,
              maxLines: maxLines,
              cursorColor: KvColor.primary,
              style: TextStyle(
                fontFamily: mono ? KvFont.mono : KvFont.ui,
                fontSize: mono ? 13 : 15,
                height: mono ? 20 / 13 : 20 / 15,
                fontWeight: FontWeight.w400,
                fontVariations: KvWeight.w400,
                color: KvColor.ink,
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: KvSpace.m),
                hintText: hint,
                hintStyle: TextStyle(
                  fontFamily: mono ? KvFont.mono : KvFont.ui,
                  fontSize: mono ? 13 : 15,
                  height: mono ? 20 / 13 : 20 / 15,
                  fontWeight: FontWeight.w400,
                  fontVariations: KvWeight.w400,
                  color: KvColor.inkMeta,
                ),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _MessageSettingsSheet extends StatelessWidget {
  const _MessageSettingsSheet({required this.bond});

  final BigInt bond;

  @override
  Widget build(BuildContext context) {
    return KvSheet(
      title: 'Message settings',
      cancelLabel: 'Close',
      // `risk` is the sheet law's default for the way out (D-277), and this
      // sheet's exit closes rather than cancels anything — a quiet one.
      cancelTone: KvColor.inkDim,
      onCancel: () => Navigator.of(context).pop(),
      child: KvRowContainer(
        // Inside a sheet, so `chip` — a `plate` card on a `plate` panel draws
        // nothing at all (§1.1, D-293).
        ground: KvColor.chip,
        children: [
          KvRow(
            dense: true,
            ground: KvColor.chip,
            // A label WRAPS; only a number may not (BG-14). At 320 dp / 1.3×
            // these came out `History & bac…`, `Handsh…`, `Delete all mes…` —
            // and `Handsh…` names nothing (`ux-auditor`, D-293's own defect at
            // a new call site).
            titleLines: 2,
            leading: const KvRowDisc.neutral(mark: KvGlyph.history),
            title: 'History & backup',
            sub:
                'Fill in what the node missed, and park your contacts on '
                'chain',
            subLines: 2,
            trailing: const KvGlyphIcon(
              KvGlyph.chevron,
              size: 20,
              tone: KvColor.etch,
            ),
            onTap: () => Navigator.of(context).pop('history'),
          ),
          KvRow(
            dense: true,
            ground: KvColor.chip,
            // A label WRAPS; only a number may not (BG-14). At 320 dp / 1.3×
            // these came out `History & bac…`, `Handsh…`, `Delete all mes…` —
            // and `Handsh…` names nothing (`ux-auditor`, D-293's own defect at
            // a new call site).
            titleLines: 2,
            leading: const KvRowDisc.neutral(mark: KvGlyph.userPlus),
            title: 'Handshake bond',
            sub:
                'What a stranger posts to reach you — returned when you '
                'accept',
            // Three, not two. `T2`'s rule: an explanation that ellipsises is
            // worse than no explanation, and this one names the condition on
            // getting the money back.
            subLines: 3,
            // The default 132 is sized for a balance; this figure is four
            // characters and a unit, and the room it held in reserve was
            // ellipsising the sentence beside it (D-293's rule, the same trade
            // the address row makes).
            trailingCap: 80,
            // **The figure is mono, the unit is not** (BG-30). Set wholly
            // mono it also wrapped to `0.20` / `KAS` at 320 dp / 1.3×, which
            // BG-5 forbids outright — `_RequestsGloss` one class away already
            // did it correctly (`ux-auditor` BLOCK, UX-R5).
            trailing: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: kasCanonical(bond),
                    style: const TextStyle(
                      fontFamily: KvFont.mono,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const TextSpan(
                    text: ' KAS',
                    style: TextStyle(fontFamily: KvFont.ui),
                  ),
                ],
              ),
              maxLines: 1,
              style: const TextStyle(
                fontSize: 13,
                height: 18 / 13,
                color: KvColor.inkDim,
              ),
            ),
          ),
          KvRow(
            dense: true,
            ground: KvColor.chip,
            // A label WRAPS; only a number may not (BG-14). At 320 dp / 1.3×
            // these came out `History & bac…`, `Handsh…`, `Delete all mes…` —
            // and `Handsh…` names nothing (`ux-auditor`, D-293's own defect at
            // a new call site).
            titleLines: 2,
            // **`risk`, and the only place on this sheet that takes it.**
            // §3 rations the hue to fund risk and DESTRUCTION, and this is the
            // app's single irreversible gesture — the `PopupMenuItem` it
            // replaced already painted its mark `KvColor.error` for exactly
            // that reason. A neutral disc would make the erase look like the
            // two rows above it, which are a sheet and a figure. The mark is
            // `trash`, added for it: `close` says *dismiss*, and BG-25 asks
            // the app to own the mark rather than borrow a near-enough one.
            leading: const KvRowDisc(
              mark: KvGlyph.trash,
              tint: KvColor.riskTint,
              tone: KvColor.risk,
            ),
            title: 'Delete all messages',
            sub: 'Every conversation, on this device',
            trailing: const KvGlyphIcon(
              KvGlyph.chevron,
              size: 20,
              tone: KvColor.etch,
            ),
            onTap: () => Navigator.of(context).pop('wipe'),
          ),
        ],
      ),
    );
  }
}
