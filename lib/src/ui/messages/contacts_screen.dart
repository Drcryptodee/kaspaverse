import 'package:flutter/material.dart';

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
    final address = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AddContactSheet(),
    );
    if (address == null || address.isEmpty) return;

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
          'Carries a 0.2 KAS bond — the network norm. It comes back when they '
          'accept; if they already have you as a contact their app completes '
          'the chat silently and the bond is not returned.',
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
          'Returns the 0.2 KAS bond to the sender and opens the conversation.',
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
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RowActionsSheet(
        label: contactLabel(conversation),
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
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _StartOverSheet(label: contactLabel(conversation)),
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
    const bond =
        'Carries a 0.2 KAS bond — the network norm. It comes back when they '
        'accept; if their app still has you as a contact it may complete the '
        'chat silently and the bond is not returned.';
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
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _WipeAllSheet(preview: preview),
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
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ClearMessagesSheet(label: contactLabel(conversation)),
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
    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _NameSheet(
        address: conversation.contactAddress,
        current: conversation.contactName ?? '',
      ),
    );
    if (!mounted || name == null) return;
    await _messaging.setContactName(conversation.contactAddress, name);
  }

  /// The zombie-cleanup affordance (D-068): confirm → hide. Local only;
  /// nothing leaves the device. The row is tombstoned, so their next message
  /// reopens the thread.
  Future<void> _hide(ConversationDto conversation) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      // L87, the instance that outlived the lesson: without this the sheet is
      // capped at 9/16 of the screen, and at large text scales a confirm sheet
      // clips the very button it exists to ask for.
      isScrollControlled: true,
      builder: (_) => _HideSheet(
        label: contactLabel(conversation),
        isInvitation: conversation.status == 'pending_in',
      ),
    );
    if (confirmed != true) return;
    await _messaging.hide(conversation.conversationId);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Conversation hidden.')));
  }

  /// One tab's list, or its own empty state — the copy differs because the
  /// two emptinesses mean different things.
  Widget _list(List<ConversationDto> rows, String emptyCopy) {
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(KvSpace.xl),
          child: Text(
            emptyCopy,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: KvColor.textSecondary),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(KvSpace.gutter),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: KvSpace.sm),
      itemBuilder: (context, index) {
        final conversation = rows[index];
        return Entrance(
          index: index,
          child: _ConversationCard(
            conversation: conversation,
            onOpen: () => _openThread(conversation),
            onAccept: () => _accept(conversation),
            onHide: () => _rowActions(conversation),
            onDismissExpired: () => _dismissExpired(conversation),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
        actions: [
          // The V2b visible toggle's home (D-074): reachable ALWAYS, not
          // only when the gap banner shows.
          IconButton(
            tooltip: 'History & backup',
            icon: const Icon(Icons.history),
            onPressed: () {
              KvHaptic.selection();
              showHistoryFillSheet(context, _messaging, onBackUp: _backUp);
            },
          ),
          // The total erase. Behind an overflow rather than a bare icon: it is
          // the one gesture on this screen that cannot be undone, and it must
          // never sit one mis-tap away from "History & backup", which is its
          // exact opposite.
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (value) {
              if (value == 'wipe') _wipeAll();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'wipe',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.delete_forever_outlined,
                    // §3: `error` is rationed to fund risk and DESTRUCTION;
                    // `warning` is the degraded-state voice. Amber on the app's
                    // one irreversible action was the wrong register.
                    color: KvColor.error,
                  ),
                  title: Text('Delete all messages'),
                  subtitle: Text('Every conversation, on this device'),
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add contact',
        onPressed: () {
          KvHaptic.selection();
          _addContact();
        },
        child: const Icon(Icons.person_add_alt),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // The honest gap notice (D-074: never silence) — renders only
            // when history may be incomplete; tap opens the fill sheet.
            HistoryNoticeBanner(messaging: _messaging, onBackUp: _backUp),
            Expanded(
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
                      .toList();
                  final requests = conversations
                      .where((c) => c.status == 'pending_in')
                      .toList();
                  return _ConversationTabs(
                    chats: _list(
                      chats,
                      'No conversations yet.\nAdd a contact by address — '
                      'the handshake rides the Kaspa L1 itself.',
                    ),
                    requests: _list(
                      requests,
                      'No one is waiting on you.\nInvitations from people you '
                      "haven't met appear here.",
                    ),
                    requestCount: requests.length,
                  );
                },
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          KvSpace.gutter,
          KvSpace.m,
          KvSpace.gutter,
          KvSpace.l,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: Text(label, style: theme.textTheme.titleMedium)),
            const SizedBox(height: KvSpace.m),
            if (canName)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.badge_outlined),
                title: const Text('Name this contact'),
                subtitle: const Text('Shown only on this device'),
                onTap: () => Navigator.of(context).pop('name'),
              ),
            if (canStartOver)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.restart_alt),
                title: const Text('Start over with this contact'),
                subtitle: const Text(
                  'Deletes your messages and sends a new request (0.2 KAS)',
                ),
                onTap: () => Navigator.of(context).pop('restart'),
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('Clear messages'),
              // The distinction from Hide, in one line: this one keeps the
              // conversation working. Without it the two read as the same
              // gesture and the user picks the wrong one.
              // A greyed-out row with no reason is worse than no row. Say
              // why on the one card where the user would ask.
              subtitle: Text(
                canClear
                    ? 'Empties the thread; you can still message'
                    : 'Nothing to clear until you accept',
              ),
              enabled: canClear,
              onTap: () => Navigator.of(context).pop('clear'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.visibility_off_outlined),
              title: const Text('Hide conversation'),
              // Says the destructive half FIRST. It read as the gentlest item
              // in the menu and it purges the thread.
              subtitle: const Text(
                'Clears the thread; comes back if they write',
              ),
              onTap: () => Navigator.of(context).pop('hide'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Name a contact. The address stays visible while typing — the name is a
/// label over an identity, never a replacement for it.
class _NameSheet extends StatefulWidget {
  const _NameSheet({required this.address, required this.current});

  final String address;
  final String current;

  @override
  State<_NameSheet> createState() => _NameSheetState();
}

class _NameSheetState extends State<_NameSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.current,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
                'Name this contact',
                style: theme.textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: KvSpace.m),
            // The address stays on screen: a name is a label the user chose,
            // and the identity underneath it is what actually routes.
            Text(
              truncateAddressPayload(widget.address),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: KvColor.textSecondary,
                fontFamily: KvFont.mono,
              ),
            ),
            const SizedBox(height: KvSpace.m),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: 40,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name',
                helperText:
                    'Stored on this device only — never sent, never '
                    'in a backup.',
              ),
              onSubmitted: (v) => Navigator.of(context).pop(v),
            ),
            const SizedBox(height: KvSpace.m),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(_controller.text),
              child: const Text('Save'),
            ),
            if (widget.current.isNotEmpty) ...[
              const SizedBox(height: KvSpace.s),
              TextButton(
                // Clearing sends an empty name, which Rust treats as "remove"
                // rather than "store a blank".
                onPressed: () => Navigator.of(context).pop(''),
                child: const Text('Remove name'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The Chats / Requests split.
///
/// **Both tabs always render, even at zero.** A tab bar that appears when the
/// first invitation lands would move the list out from under a finger already
/// travelling toward it, and the count is the honest signal anyway: a Requests
/// tab reading nothing says "nobody is waiting on you", which is information.
class _ConversationTabs extends StatelessWidget {
  const _ConversationTabs({
    required this.chats,
    required this.requests,
    required this.requestCount,
  });

  final Widget chats;
  final Widget requests;
  final int requestCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            labelStyle: theme.textTheme.titleMedium,
            tabs: [
              const Tab(text: 'Chats'),
              Tab(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Requests'),
                    if (requestCount > 0) ...[
                      const SizedBox(width: KvSpace.xs),
                      // A count, never a red dot: the number is the useful
                      // part, and each one of these asks the user to spend.
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: KvSpace.xs,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: KvColor.chip,
                          border: Border.all(color: KvColor.edgeHi),
                          borderRadius: BorderRadius.circular(KvRadius.chip),
                        ),
                        child: Text(
                          '$requestCount',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: KvColor.ink,
                            fontFamily: KvFont.ui,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          Expanded(child: TabBarView(children: [chats, requests])),
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

class _ConversationCard extends StatelessWidget {
  const _ConversationCard({
    required this.conversation,
    required this.onOpen,
    required this.onAccept,
    required this.onHide,
    required this.onDismissExpired,
  });

  final ConversationDto conversation;
  final VoidCallback onOpen;
  final VoidCallback onAccept;
  final VoidCallback onHide;
  final VoidCallback onDismissExpired;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = conversation;
    // Rust's expiry taxonomy (V5, finding 15): an expired pending-inbound
    // invitation can NEVER be accepted (its bond is pruned) — the card tells
    // the truth and offers the exit instead of a dead Accept.
    final expired = c.status == 'pending_in' && c.inviteExpired;
    final pendingIn = c.status == 'pending_in' && !expired;
    final pendingOut = c.status == 'pending_out';
    // Rust's derived rule: a newer live thread with this same contact exists,
    // so this one's alias reaches nobody. It stays open and readable — the
    // history is real — but it can no longer be typed in.
    final replaced = c.superseded;

    // ORDER MATTERS, AND IT MUST MATCH THE BODY CHAIN BELOW. When the label
    // said one thing and the body another, a `pending_in` row could render
    // "Wants to connect" over the Replaced body — losing its Accept button and
    // with it the only route to refunding the counterparty's bond. Rust also
    // refuses to mark an invitation superseded, so this is belt and braces;
    // the two orderings are kept identical so they cannot drift again.
    final (String statusLine, Color statusColor) = expired
        ? ('Invitation expired', KvColor.textTertiary)
        : pendingIn
        ? ('Wants to connect', KvColor.textSecondary)
        : replaced
        ? ('Replaced', KvColor.textTertiary)
        : pendingOut
        ? ('Awaiting their accept', KvColor.textTertiary)
        : ('Active', KvColor.inkDim); // teal is never a status (BG-2/BG-7)

    return Material(
      color: KvColor.surface,
      borderRadius: BorderRadius.circular(KvRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(KvRadius.card),
        // A pending-inbound card's action is its own button (Accept, or the
        // expired-invitation Dismiss), not a thread.
        onTap: (pendingIn || expired) ? null : onOpen,
        // Long-press anywhere on the card → hide (zombie cleanup, D-068).
        onLongPress: onHide,
        child: Padding(
          padding: const EdgeInsets.all(KvSpace.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    expired
                        ? Icons.mail_outline
                        : pendingIn
                        ? Icons.mark_email_unread_outlined
                        : replaced
                        ? Icons.history
                        : Icons.forum_outlined,
                    size: 20,
                    color: statusColor,
                  ),
                  const SizedBox(width: KvSpace.s),
                  Expanded(
                    child: Text(
                      contactLabel(c),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: KvFont.mono,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: KvSpace.xs),
              Text(
                statusLine,
                style: theme.textTheme.labelSmall?.copyWith(color: statusColor),
              ),
              if (expired) ...[
                const SizedBox(height: KvSpace.sm),
                Text(
                  // Honest terminal copy (founder-ruled wording, V5): the
                  // bond is pruned — no transient promise, and an exit.
                  'This invitation has expired and can no longer be accepted.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: KvColor.textSecondary,
                  ),
                ),
                const SizedBox(height: KvSpace.sm),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: onDismissExpired,
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Dismiss'),
                  ),
                ),
              ] else if (pendingIn) ...[
                const SizedBox(height: KvSpace.sm),
                Text(
                  'Accepting returns their 0.2 KAS bond and opens an '
                  'encrypted conversation.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: KvColor.textSecondary,
                  ),
                ),
                const SizedBox(height: KvSpace.sm),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: () {
                      KvHaptic.selection();
                      onAccept();
                    },
                    icon: const Icon(Icons.handshake_outlined, size: 18),
                    label: const Text('Accept'),
                  ),
                ),
              ] else if (replaced) ...[
                const SizedBox(height: KvSpace.sm),
                Text(
                  // Says what happened, what it means, and where to go — the
                  // three things the silence never said.
                  'They started a new conversation with you. This one is '
                  'history only — open the newer thread to message them.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: KvColor.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Confirm hiding a conversation (the zombie-cleanup affordance). Honest copy:
/// this is local only — it removes nothing from the chain and tells the
/// counterpart nothing.
class _HideSheet extends StatelessWidget {
  const _HideSheet({required this.label, this.isInvitation = false});

  final String label;

  /// Hiding means two different things, and the sheet must not promise the
  /// wrong one. On a conversation you already have it is a mute — they can
  /// still write and the thread comes back. On an invitation you never took
  /// up it is a block: their messages are refused from then on, because that
  /// card spends a bond and a stranger must not be able to re-arm it.
  final bool isInvitation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          KvSpace.gutter,
          KvSpace.m,
          KvSpace.gutter,
          KvSpace.l,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Text(
                'Hide conversation',
                style: theme.textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: KvSpace.m),
            Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: KvFont.mono,
              ),
            ),
            const SizedBox(height: KvSpace.sm),
            Text(
              isInvitation
                  ? 'Turns down this invitation and clears it from your '
                        "device. Nothing is deleted on-chain and they aren't "
                        "notified, but you won't hear from them again unless "
                        'they send a new request.'
                  : 'Clears the messages from your device and hides the '
                        "thread. Nothing is deleted on-chain and they aren't "
                        'notified, so they can still write to you — a new '
                        'message brings the thread back.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: KvColor.textSecondary,
              ),
            ),
            const SizedBox(height: KvSpace.l),
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Hide'),
            ),
            const SizedBox(height: KvSpace.s),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Confirm starting a conversation over with one contact.
///
/// The copy has to be honest about the one thing that decides whether this
/// works: a client that still remembers you may answer a repeat request with
/// silence. That is not a defect we can fix from here — it is how the wire
/// protocol behaves — so the sheet says it rather than promising a repair.
class _StartOverSheet extends StatelessWidget {
  const _StartOverSheet({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          KvSpace.gutter,
          KvSpace.m,
          KvSpace.gutter,
          KvSpace.l,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Text('Start over', style: theme.textTheme.titleMedium),
            ),
            const SizedBox(height: KvSpace.m),
            Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: KvFont.mono,
              ),
            ),
            const SizedBox(height: KvSpace.sm),
            Text(
              'Deletes your messages with this contact — every conversation '
              'you have with them — hides those threads, and sends a fresh '
              'contact request carrying the usual 0.2 KAS bond.\n\n'
              'Use this when messages stop getting through. It works best when '
              'they have also cleared their side — an app that still has you '
              'as a contact may accept silently and send nothing back, in '
              'which case the bond is not returned. A thread comes back if '
              'they write to it again — the messages do not.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: KvColor.textSecondary,
              ),
            ),
            const SizedBox(height: KvSpace.l),
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Review request'),
            ),
            const SizedBox(height: KvSpace.s),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Confirm the total erase.
///
/// Three things this copy must do, in order: name what goes (with a number the
/// user can check), name the one thing that CANNOT go (the chain — D-088; this
/// app never implies deletion it cannot perform), and name the consequence
/// people actually care about, which is that contacts have to handshake again.
///
/// That last line is not a warning bolted on — it is the useful half. A
/// counterparty who still remembers you answers a repeat handshake with
/// silence, so after this the reliable move is for THEM to start the new
/// conversation. Saying so here is what turns a destructive button into the
/// repair gesture it actually is.
class _WipeAllSheet extends StatelessWidget {
  const _WipeAllSheet({required this.preview});

  /// Rust's count of what the wipe would destroy — hidden rows included.
  final WipeReportDto preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final conversationCount = preview.conversations;
    final messageCount = preview.messages;
    final plural = conversationCount == 1 ? '' : 's';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          KvSpace.gutter,
          KvSpace.m,
          KvSpace.gutter,
          KvSpace.l,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Text(
                'Delete all messages',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: KvColor.error,
                ),
              ),
            ),
            const SizedBox(height: KvSpace.m),
            Text(
              'This deletes $conversationCount conversation$plural and '
              '$messageCount message${messageCount == 1 ? '' : 's'} from this '
              'device, including any you have hidden. It cannot be undone.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: KvSpace.sm),
            Text(
              'Messages already sent stay on Kaspa permanently — this clears '
              'your copy, not the chain, and this app will not fetch them '
              'back, including from your backup. Your wallet and coins are '
              'not touched.\n\n'
              'A contact can appear again as a new request — their messages do '
              'not come back.\n\n'
              '${preview.pendingBonds > 0 ? 'This also deletes '
                        '${preview.pendingBonds} unanswered contact '
                        'request${preview.pendingBonds == 1 ? '' : 's'} — the 0.2 '
                        'KAS bond each sender paid can no longer be returned to '
                        'them.\n\n' : ''}'
              'To talk to someone again afterwards, one of you has to send a '
              'new contact request. Asking them to start it is the reliable '
              'way round: an app that still remembers you may not answer a '
              'repeat request.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: KvColor.textSecondary,
              ),
            ),
            const SizedBox(height: KvSpace.l),
            // FILLED, not tonal — this is where the added ceremony weight
            // lives. A tonal button here reads identical to the benign "Clear
            // messages" confirm one gesture away, and the two do very
            // different things. No new widget, no hold gesture: DS §8's
            // hold-to-sign is the SIGNING ceremony, and its glow is rationed
            // to value-committing primary actions — dressing an erase in that
            // register would say "this is the thing you want".
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: KvColor.error,
                foregroundColor: KvColor.surface,
              ),
              child: Text('Delete $conversationCount conversation$plural'),
            ),
            const SizedBox(height: KvSpace.s),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Confirm emptying ONE thread while keeping the conversation.
///
/// The copy's whole job is to separate this from Hide, which sits directly
/// beneath it in the same menu and also purges content. Says what survives
/// (the conversation), what does not (the words), and the one thing neither
/// gesture can do (reach the chain — D-088).
class _ClearMessagesSheet extends StatelessWidget {
  const _ClearMessagesSheet({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          KvSpace.gutter,
          KvSpace.m,
          KvSpace.gutter,
          KvSpace.l,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Text('Clear messages', style: theme.textTheme.titleMedium),
            ),
            const SizedBox(height: KvSpace.m),
            Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: KvFont.mono,
              ),
            ),
            const SizedBox(height: KvSpace.sm),
            Text(
              'Empties this thread on your device. The conversation stays on '
              'your list. Messages already on Kaspa stay there permanently; '
              'this only clears your copy.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: KvColor.textSecondary,
              ),
            ),
            const SizedBox(height: KvSpace.l),
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Clear messages'),
            ),
            const SizedBox(height: KvSpace.s),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Address entry for a new contact — validation stays in Rust (the prepare
/// call is the authority); this sheet only collects the string.
class _AddContactSheet extends StatefulWidget {
  const _AddContactSheet();

  @override
  State<_AddContactSheet> createState() => _AddContactSheetState();
}

class _AddContactSheetState extends State<_AddContactSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
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
              child: Text('Add contact', style: theme.textTheme.titleMedium),
            ),
            const SizedBox(height: KvSpace.l),
            TextField(
              controller: _controller,
              autofocus: true,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: KvFont.mono,
              ),
              decoration: const InputDecoration(
                labelText: 'Kaspa address',
                hintText: 'kaspa:…',
              ),
              maxLines: 2,
              minLines: 1,
            ),
            const SizedBox(height: KvSpace.s),
            Text(
              'A contact request costs a 0.2 KAS bond — refunded when they '
              'accept. Both of you message over Kaspa itself; no server.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: KvColor.textSecondary,
              ),
            ),
            const SizedBox(height: KvSpace.l),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(_controller.text.trim()),
              child: const Text('Review request'),
            ),
          ],
        ),
      ),
    );
  }
}
