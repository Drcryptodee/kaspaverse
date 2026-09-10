import 'dart:async';

import 'package:flutter/material.dart';

import '../../rust/api/transport.dart';
import '../../services/messaging_service.dart';
import '../error_text.dart';
import '../format.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_address.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_contact.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_loader.dart';
import '../widgets/kv_reading.dart';
import '../widgets/kv_rows.dart';
import '../widgets/kv_two_pane.dart';
import 'contacts_screen.dart' show confirmAct;

/// **The addresses the user refused** (D-308), behind `M5`'s `Blocked
/// addresses` row — and the one place a block is lifted on purpose.
///
/// No render covers this surface, so it is composed as the archetype it is
/// (§0b): a settings list of people, one row each, the way the address book
/// and the conversation list already draw a person — the name the user gave
/// them, else their key in the house's own address part. The row is a door
/// to its confirm, never a swipe: unblocking hands someone a way back into
/// your messages, and a gesture you can make by accident is the wrong shape
/// for that.
///
/// What is NOT here: any way to add an address by hand. A block is a decision
/// about a person you have heard from, made where you heard from them (a
/// request, a thread); typing a key into a list would let a mistyped one
/// refuse a stranger who never wrote.
class BlockedAddressesScreen extends StatefulWidget {
  const BlockedAddressesScreen({super.key, this.messaging});

  /// Test seam; defaults to the singleton.
  final MessagingService? messaging;

  @override
  State<BlockedAddressesScreen> createState() => _BlockedAddressesScreenState();
}

class _BlockedAddressesScreenState extends State<BlockedAddressesScreen> {
  MessagingService get _messaging =>
      widget.messaging ?? MessagingService.instance;

  /// Null until Rust has answered — the list is absent rather than empty,
  /// because *Nobody is blocked* is a claim and a blank frame is not.
  List<BlockedContactDto>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final rows = await _messaging.blockedContacts();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = displayError(e));
    }
  }

  Future<void> _unblock(BlockedContactDto row) async {
    KvHaptic.selection();
    // The same sheet the block was confirmed on (BG-21). Raised, never teal:
    // it spends nothing, and it is the reversal of a refusal.
    final confirmed = await confirmAct(
      context,
      title: 'Unblock',
      act: 'Unblock',
      subject: _label(row),
      subjectAddress: row.address,
      body:
          'Their messages can reach you again; the next one reopens the '
          'thread. KaspaVerse sends them nothing.',
    );
    if (!confirmed || !mounted) return;
    try {
      await _messaging.unblock(row.address);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Unblocked.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(displayError(e))));
    }
    await _load();
  }

  /// One person, as the conversation list draws one (`ux-auditor`,
  /// MSG-BLOCK): the disc is THEIRS — the initial on the house avatar, or the
  /// `identity` glyph for an unnamed key — not the screen's own `ban`
  /// restated on every row (BG-19). The date is a figure and sets mono
  /// (BG-30), through the same day formatter the chats list uses.
  Widget _row(BlockedContactDto row) {
    final name = row.contactName;
    final named = name != null && name.isNotEmpty;
    return KvRow(
      leading: KvContactAvatar(
        name: named ? name : null,
        size: KvRowDisc.person,
      ),
      title: _label(row),
      // An unnamed address IS a key, so it is drawn as one (the conversation
      // list's own rule).
      titleWidget: named
          ? null
          : KvAddress(row.address, form: KvAddressForm.compact, fontSize: 13),
      subWidget: Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: 'Since '),
            TextSpan(
              text: dayLabel(
                DateTime.fromMillisecondsSinceEpoch(row.sinceUnixMs.toInt()),
                DateTime.now(),
              ),
              style: const TextStyle(
                fontFamily: KvFont.mono,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: KvFont.ui,
          fontSize: 13,
          height: 17 / 13,
          fontWeight: FontWeight.w400,
          fontVariations: KvWeight.w400,
          color: KvColor.inkMeta,
        ),
      ),
      trailing: const KvGlyphIcon(
        KvGlyph.chevron,
        size: 20,
        tone: KvColor.etch,
      ),
      onTap: () => _unblock(row),
    );
  }

  /// The name the user gave the address, else the address itself — the same
  /// rule `contactLabel` applies on the conversation list.
  String _label(BlockedContactDto row) {
    final name = row.contactName;
    if (name != null && name.isNotEmpty) return name;
    return truncateAddressPayload(row.address);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final error = _error;
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        child: Column(
          children: [
            KvTopBar(
              title: 'Blocked addresses',
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
                      // **The arrival eases** (BG-24): the rows answer after
                      // the first frame, and a list appearing where a loader
                      // stood is a cut.
                      AnimatedSwitcher(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : KvMotion.calm,
                        switchInCurve: KvMotion.curve,
                        switchOutCurve: KvMotion.curve,
                        child: error != null
                            ? _Gloss(error, key: const ValueKey('error'))
                            : rows == null
                            ? const Padding(
                                key: ValueKey('loading'),
                                padding: EdgeInsets.symmetric(
                                  vertical: KvSpace.l,
                                ),
                                child: Center(child: KvLoader()),
                              )
                            : rows.isEmpty
                            ? const _Gloss(
                                'Nobody is blocked. Block someone from their '
                                'request or from inside a conversation.',
                                key: ValueKey('empty'),
                              )
                            : Column(
                                key: const ValueKey('rows'),
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // What a block is, in the words the confirm
                                  // used, so the list explains itself to a
                                  // reader who has not blocked anyone in a
                                  // while.
                                  const _Gloss(
                                    "Their messages don't reach you. A new "
                                    'request from them still does, and '
                                    'accepting it unblocks them.',
                                  ),
                                  KvRowContainer(
                                    children: [
                                      for (final row in rows) _row(row),
                                    ],
                                  ),
                                ],
                              ),
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

/// A sentence above or instead of the list, in the settings screens' own
/// explainer face.
class _Gloss extends StatelessWidget {
  const _Gloss(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    // Vertical air only: the column has already applied the gutter, and a
    // second horizontal inset here put the words 4 dp in from the plate's
    // edge (L195; `ux-auditor`, MSG-BLOCK).
    return Padding(
      padding: const EdgeInsets.only(top: KvSpace.s, bottom: KvSpace.m),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: KvFont.ui,
          fontSize: 13,
          height: 18 / 13,
          fontWeight: FontWeight.w400,
          fontVariations: KvWeight.w400,
          color: KvColor.inkDim,
        ),
      ),
    );
  }
}
