import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/rust/api/send.dart';
import 'package:kaspaverse/src/rust/api/transport.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/biometric_copy.dart';
import 'package:kaspaverse/src/services/rate_service.dart';
import 'package:kaspaverse/src/ui/home_screen.dart';
import 'package:kaspaverse/src/ui/node/node_screen.dart';
import 'package:kaspaverse/src/ui/receive/receive_screen.dart';
import 'package:kaspaverse/src/ui/secret/secret_keyboard.dart';
import 'package:kaspaverse/src/ui/send/send_screen.dart';
import 'package:kaspaverse/src/ui/settings/about_screen.dart';
import 'package:kaspaverse/src/ui/settings/security_screen.dart';
import 'package:kaspaverse/src/ui/settings/settings_scopes.dart';
import 'package:kaspaverse/src/ui/settings/settings_screen.dart';
import 'package:kaspaverse/src/ui/settings/wallet_screen.dart';
import 'package:kaspaverse/src/ui/tx/tx_detail_screen.dart';
import 'package:kaspaverse/src/ui/send/signing_ceremony.dart';
import 'package:kaspaverse/src/ui/widgets/kv_address.dart';
import 'package:kaspaverse/src/ui/widgets/kv_burial_gauge.dart';
import 'package:kaspaverse/src/ui/widgets/kv_burial_mark.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_coming_soon.dart';
import 'package:kaspaverse/src/ui/widgets/kv_contact.dart';
import 'package:kaspaverse/src/ui/widgets/kv_drawer.dart';
import 'package:kaspaverse/src/ui/widgets/kv_glyph.dart';
import 'package:kaspaverse/src/ui/widgets/kv_rows.dart';
import 'package:kaspaverse/src/ui/widgets/kv_mark.dart';
import 'package:kaspaverse/src/ui/widgets/kv_keypad.dart';
import 'package:kaspaverse/src/ui/widgets/kv_toggle.dart';

import 'package:kaspaverse/src/ui/messages/blocked_addresses_screen.dart';
import 'package:kaspaverse/src/ui/messages/contacts_screen.dart';
import 'package:kaspaverse/src/ui/messages/thread_screen.dart';
import 'package:kaspaverse/src/services/messaging_service.dart';
import 'package:kaspaverse/src/ui/onboarding_surface.dart';
import 'package:kaspaverse/src/ui/create_screen.dart';
import 'package:kaspaverse/src/ui/restore_screen.dart';
import 'package:kaspaverse/src/ui/unlock_surface.dart';
import 'package:kaspaverse/src/rust/api/vault.dart' as vault_api;
import 'package:kaspaverse/src/ui/widgets/kv_chrome.dart';
import 'package:kaspaverse/src/ui/passphrase_unlock_screen.dart';
import 'package:kaspaverse/src/ui/secret/bip39_wordlist.dart';
import 'package:kaspaverse/src/ui/secret/secret_screen_guard.dart';
import 'package:kaspaverse/src/ui/widgets/kv_toggle.dart' show KvToggle;
import '../support/preview_harness.dart';
import '../support/maturity.dart';

/// **The surface catalogue.** Every entry renders a REAL widget with fixture
/// data — never the founder's wallet, so a preview carries no address, no
/// balance and no txid that belongs to anyone. That is what makes a preview
/// safe to look at anywhere, including on a phone or in a shared page.
///
/// Run it: `tools/preview.sh` (or `KV_PREVIEW=1 flutter test test/preview
/// --update-goldens`). Without `KV_PREVIEW=1` every case is skipped, so the
/// gate's `flutter test` sees a no-op instead of a generator writing files on
/// every run.
///
/// **Adding a surface is the point.** This list is the queue `design-uplift`
/// previews before it is allowed to edit anything, so a screen absent here is a
/// screen whose redesign can only be judged after it ships.
const _addr =
    'kaspa:qz5a8jtqt3l3nf8zxve9eu0qtrkewc5e0yn465djghw4438jqdecc6jzqunth';

SignableSummaryDto _summary({
  SignableKind kind = SignableKind.payment,
  String? payloadKind,
  int payloadLen = 0,
}) => SignableSummaryDto(
  kind: kind,
  destination: _addr,
  amountSompi: BigInt.from(1240000000),
  feeSompi: BigInt.from(315400),
  totalSompi: BigInt.from(1240315400),
  mass: BigInt.from(2036),
  txCount: 1,
  utxoCount: 2,
  payloadLen: payloadLen,
  // Null, not `'none'`: a payment carries no payload, and a fixture that
  // says `none` puts a line on the ceremony that the shipped path never
  // draws — a preview lying about the surface it exists to show. A MESSAGE
  // does carry one, and passes it.
  payloadKind: payloadKind,
  nonce: BigInt.one,
  resultingCoins: 1,
  feeStrategy: FeeStrategyKind.senderPays,
  priorityFeeSompi: BigInt.zero,
);

SendOutcomeDto _sent() => SendOutcomeDto(
  finalTxid: 'e154009eae73d2ef9cab0a80dc42a62ebb91f93cbdeab514a57ca3b01d7e5d34',
  submitted: 1,
  total: 1,
  partial: false,
);

/// The address book the previews are drawn against (`S6a`'s own three names).
///
/// Wired, because the contacts card, the monogram on the recipient row, the
/// match card and *Save as contact* are all absent from a preview built
/// without it — and those are exactly the parts UX-R2B added.
ContactsScope _contacts() {
  final list = ValueNotifier<List<ContactDto>>([
    const ContactDto(address: _addr, name: 'Mara'),
    ContactDto(address: 'kaspa:qpz3${'x' * 59}', name: 'Jonas'),
    ContactDto(address: 'kaspa:qz9c${'y' * 59}', name: 'Dev fund'),
  ]);
  return ContactsScope(
    contacts: list,
    refresh: () async {},
    save: (_, _) async {},
  );
}

/// **The messages surfaces** (`M1` · `M2` · `M4`, UX-R5).
///
/// The service is a singleton with static seams, so the fixture sets them and
/// the screen pulls through the same path the app does — no widget here is fed
/// a list it could not have got from Rust.
ConversationDto _conv(
  String id, {
  String status = 'active',
  String? name,
  bool expired = false,
  int agoMinutes = 3,
  String address = _addr,
  String? preview,
  int unread = 0,
  // A request carries no address until the node names its sender; `resolved`
  // is the card after that lookup — the one `M2` draws, and the one that can
  // be blocked.
  bool resolved = false,
  bool blocked = false,
  bool replyNeedsHandshake = false,
}) => ConversationDto(
  conversationId: id,
  contactAddress: status == 'pending_in' && !resolved ? '' : address,
  // A revived row (D-307) holds no alias of ours — the flag derives from that
  // in Rust, and the fixture keeps the two consistent.
  myAlias: replyNeedsHandshake ? '' : 'fa6d1afa79e1',
  theirAlias: 'a1e1b60b5fca',
  status: status,
  initiatedByMe: status != 'pending_in',
  createdUnixMs: BigInt.from(
    DateTime.now().millisecondsSinceEpoch - 86400000 * 9,
  ),
  lastActivityUnixMs: BigInt.from(
    DateTime.now().millisecondsSinceEpoch - agoMinutes * 60000,
  ),
  inviteExpired: expired,
  contactName: name,
  preview: preview,
  unread: unread,
  blocked: blocked,
  replyNeedsHandshake: replyNeedsHandshake,
);

/// One blocked address, for `M5`'s count and the list behind it (D-308).
List<BlockedContactDto> _blockedRows() => [
  BlockedContactDto(
    address: _addr,
    contactName: 'Mara',
    sinceUnixMs: BigInt.from(
      DateTime.now().millisecondsSinceEpoch - 86400000 * 3,
    ),
  ),
];

Widget _blocked({bool empty = false}) {
  MessagingService.blockedContactsFn = () async =>
      empty ? const [] : _blockedRows();
  return BlockedAddressesScreen(messaging: MessagingService.instance);
}

Widget _chats({bool requests = false, bool empty = false, int? gapMinutes}) {
  MessagingService.conversationsFn = () async => empty
      ? const []
      : [
          // **`M1`'s own rows, previews and counts included** — the render
          // draws these five and this fixture is a transcription of it, so a
          // frame that differs from the picture is a defect rather than a
          // different sample.
          _conv(
            'c1',
            name: 'Mara',
            preview: 'Got it, thank you — confirmed on my side',
          ),
          _conv(
            'c2',
            name: 'Jonas',
            agoMinutes: 60 * 26,
            preview: 'Sent — thanks for waiting',
            unread: 1,
          ),
          // The long one. Rust bounds the string for custody; what puts the
          // `…` on the glass is the FRAME, so this row is the one that proves
          // the ellipsis at every geometry.
          _conv(
            'c3',
            name: 'Dev fund',
            agoMinutes: 60 * 24 * 3,
            preview:
                'Q3 grant released · 150 KAS to the treasury multisig, with '
                'the remainder scheduled for the next epoch',
          ),
          _conv(
            'c4',
            name: 'Anna',
            agoMinutes: 60 * 24 * 4,
            preview: 'Can you resend the invoice?',
            unread: 3,
          ),
          // **A thread awaiting their accept**, so the amber clock badge on
          // the disc is in the frame rather than only in a widget test — it
          // is a mark whose whole job is to be seen.
          _conv('c6', name: 'Tomas', status: 'pending_out', agoMinutes: 60 * 5),
          // **One UNNAMED contact, deliberately.** Every chat in this fixture
          // had a name, so the floor frame never drew a row whose title is an
          // address — which is why a title that ellipsised `kaspa:qz7u…ellj43pf`
          // down to `kaspa:qz…` at 320 dp / 1.3× went unseen
          // (`wallet-security-auditor`, UX-R5). A frame that only shows the
          // easy case is the comfortable half.
          _conv('c5', agoMinutes: 60 * 24 * 26),
          // **`M2`'s three words on the first request** (D-308): the node
          // has named its sender, so `Block` is buildable and drawn. The
          // second is still unresolved — the card that cannot carry it.
          _conv('r1', status: 'pending_in', resolved: true, agoMinutes: 120),
          _conv('r2', status: 'pending_in', agoMinutes: 60 * 30),
          // **A blocked address knocking again**: the state line says so,
          // Accept stays (it lifts the block), Block is gone.
          _conv(
            'r3',
            status: 'pending_in',
            resolved: true,
            blocked: true,
            agoMinutes: 60 * 4,
          ),
        ];
  // `M5`'s count under `Blocked addresses`, and the wipe sheet's own numbers
  // — the bonds clause included, so the frame draws every paragraph.
  MessagingService.blockedContactsFn = () async => _blockedRows();
  MessagingService.wipePreviewFn = () async => WipeReportDto(
    conversations: 6,
    messages: 41,
    pendingBonds: 2,
    sideFilesCleared: 0,
    floorPersisted: false,
  );
  // **A gap, when a case asks for one.** The history notice renders only when
  // history may be incomplete, so the resting fixture cannot draw it and the
  // one surface built for it would have no frame at all (D-309).
  MessagingService.gapAgeFn = () async => gapMinutes == null
      ? null
      : GapAgeDto(gapMinutes: BigInt.from(gapMinutes), beyondHorizon: false);
  MessagingService.fillConfigFn = () async =>
      const FillConfigDto(enabled: false, endpoint: '', defaultEndpoint: '');
  MessagingService.fillStatusFn = () async => null;
  MessagingService.stashStateFn = () async => StashStateDto(
    lastUnixMs: BigInt.from(DateTime.now().millisecondsSinceEpoch - 7200000),
    confirmedReadable: true,
    covered: 5,
    total: 5,
  );
  MessagingService.instance.refresh();
  return ContactsScreen(messaging: MessagingService.instance);
}

Widget _thread({bool revived = false}) {
  // **A revived thread** (D-307): the row holds no alias of ours, so the
  // composer's seat carries the state, the cost and the handshake door.
  MessagingService.conversationsFn = () async => [
    _conv('c2', name: 'Jonas', replyNeedsHandshake: revived),
  ];
  MessagingService.instance.refresh();
  final now = DateTime.now().millisecondsSinceEpoch;
  final rows = [
    _msg(
      't1',
      now - 86400000 - 3600000,
      'Invoice for the print run is 40 — send when you can.',
    ),
    _msg('t2', now - 86400000 - 1800000, 'Will do tonight.', outbound: true),
    _msg('t3', now - 900000, 'Sent — thanks for waiting.', outbound: true),
    // **The founder's own five-line message** (2026-09-08), kept verbatim as
    // the wrap fixture: it took five lines here and four in WhatsApp and
    // Telegram, the fifth holding one word.
    _msg(
      't4',
      now - 600000,
      "yooooooooo avi, la tu la France de la tu la casa del Carmen y me when "
          "you're back in the field of software and the desire to have you "
          "registered",
      outbound: true,
    ),
  ];
  MessagingService.commFeePreviewFn = (_, _) async => BigInt.from(14300);
  MessagingService.messageSigningFn = () async => true;
  MessagingService.threadSinceFn = (_, _) async => ThreadDeltaDto(
    messages: rows,
    statuses: [
      for (final m in rows)
        // Accepted, so the frames show the delivered double check inside the
        // bubbles and the honest block time beside them.
        MessageStatusDto(
          txid: m.txid,
          tombstoned: false,
          acceptance: TxStatusDto(
            kind: TxStatusKind.accepted,
            blueDepth: BigInt.from(12),
            acceptedUnixMs: BigInt.from(m.unixMs.toInt() + 900),
          ),
        ),
    ],
  );
  return ThreadScreen(
    conversationId: 'c2',
    contactLabel: 'Jonas',
    // 67 characters — `mainnetAddressLengths` is {67, 69} and a fixture the
    // wallet's own shape check would reject is a frame drawn of a world that
    // cannot exist (`consensus-auditor`, UX-R5).
    contactAddress: 'kaspa:qpz3${'x' * 52}41k8t',
    messaging: MessagingService.instance,
  );
}

ThreadMessageDto _msg(
  String txid,
  int unixMs,
  String text, {
  bool outbound = false,
  FrameDto? frame,
  AttachmentDto? attachment,
  String provenance = 'node',
}) => ThreadMessageDto(
  txid: txid,
  kind: 'comm',
  outbound: outbound,
  unixMs: BigInt.from(unixMs),
  text: text,
  readable: true,
  frame: frame,
  attachment: attachment,
  tombstoned: false,
  provenance: provenance,
);

/// **The seats the house marks took over from `Icons.*` at UX-R8, in a
/// thread** — because a glyph on the sheet is a shape and a glyph in its seat
/// is a design (L205). `files: false` is an archive-restored row and the
/// `archive` marker it earns; `files: true` is a text file (`file`), a picture
/// (`image`) and a body that claimed to be a file and was not (`alert`). The
/// challenge card and the three game events this fixture also seated were
/// removed with the chat's game surface (D-322, founder 2026-09-11).
Widget _threadFrames({bool files = false}) {
  MessagingService.conversationsFn = () async => [_conv('c2', name: 'Jonas')];
  MessagingService.instance.refresh();
  // A fixed clock, so the frame is the same picture at every render: the
  // times it shows are the fixture's, not the machine's (the catalogue diff
  // at UX-R8 was half wall-clock noise).
  final now = DateTime(2026, 9, 10, 12).millisecondsSinceEpoch;
  AttachmentDto file(
    String name,
    String kind, {
    String? text,
    bool broken = false,
  }) => AttachmentDto(
    name: name,
    sizeBytes: BigInt.from(18432),
    kind: kind,
    text: text,
    broken: broken,
    viewMime: 'application/octet-stream',
  );
  // Two pictures, because the thread sits at its latest row and a frame is
  // one screen tall: the archive half and the file half.
  final rows = files
      ? [
          _msg(
            'f5',
            now - 1800000,
            '',
            attachment: file(
              'notes.txt',
              'text',
              text: 'Meet at the print shop.',
            ),
          ),
          _msg('f6', now - 1700000, '', attachment: file('proof.png', 'image')),
          _msg(
            'f7',
            now - 1600000,
            '',
            attachment: file('invoice.pdf', 'other', broken: true),
          ),
        ]
      : [
          _msg(
            'f0',
            now - 86400000 * 2,
            'Found the old thread — restoring it here.',
            provenance: 'archive',
          ),
          _msg('f1', now - 3600000, 'Thanks — got it.', outbound: true),
        ];
  MessagingService.commFeePreviewFn = (_, _) async => BigInt.from(14300);
  MessagingService.messageSigningFn = () async => true;
  MessagingService.threadSinceFn = (_, _) async => ThreadDeltaDto(
    messages: rows,
    statuses: [
      for (final m in rows)
        MessageStatusDto(
          txid: m.txid,
          tombstoned: false,
          acceptance: TxStatusDto(
            kind: TxStatusKind.accepted,
            blueDepth: BigInt.from(12),
            acceptedUnixMs: BigInt.from(m.unixMs.toInt() + 900),
          ),
        ),
    ],
  );
  return ThreadScreen(
    conversationId: 'c2',
    contactLabel: 'Jonas',
    contactAddress: 'kaspa:qpz3${'x' * 52}41k8t',
    messaging: MessagingService.instance,
  );
}

Widget _sendScreen({bool book = true, BigInt? mature}) => SendScreen(
  mature: ValueNotifier<BigInt?>(mature ?? BigInt.from(2597792200)),
  prepare: (_, _) async => _summary(),
  commit: (_) async => _sent(),
  abandon: () async {},
  feePreview: (_, _) async => BigInt.from(315400),
  minimumSendable: () async => BigInt.from(20000000),
  contacts: book ? _contacts() : null,
  fiat: _fiat(),
  // **Wired, because `Send max` is absent from the screen without it** — and
  // absent from every preview of the screen with it. D-223 gave that chip the
  // app's one teal EDGE, so a fixture that omits the callback silently hides
  // the control the founder is most likely to want looked at (D-229 audit).
  prepareSweep: (_) async => _summary(),
);

/// A small, plausible feed: one send still counting, one buried.
List<ActivityRecord> _activity() => [
  // Still counting: 47 DAA below the tip, so the burial mark streams `Seen 47`.
  ActivityRecord(
    txid: 'a' * 64,
    valueSompi: BigInt.from(100000000),
    unixtimeMsec: BigInt.from(
      DateTime(2026, 8, 30, 11, 16, 50, 103).millisecondsSinceEpoch,
    ),
    blockDaaScore: BigInt.from(526633400),
    acceptedDaaScore: BigInt.from(526633400),
    direction: ActivityDirection.outgoing,
    isCoinbase: false,
    maturity: MaturityState.pending,
    stalled: false,
  ),
  // Long buried: past both thresholds, so the mark reads `final`.
  ActivityRecord(
    txid: 'b' * 64,
    valueSompi: BigInt.from(2500000000),
    unixtimeMsec: BigInt.from(
      DateTime(2026, 8, 30, 9, 53, 20).millisecondsSinceEpoch,
    ),
    blockDaaScore: BigInt.from(526000000),
    direction: ActivityDirection.incoming,
    isCoinbase: false,
    maturity: MaturityState.confirmed,
    stalled: false,
  ),
];

Widget _home({List<ActivityRecord>? activity}) => HomeScreen(
  chain: ChainScope(
    connected: ValueNotifier(true),
    virtualDaaScore: ValueNotifier<BigInt?>(BigInt.from(526633447)),
    error: ValueNotifier<String?>(null),
    // FRESH on purpose. A stale plate suppresses the live depth (BG-8), which
    // is correct behaviour and hides the streaming case this surface exists to
    // show — the first render of it read a bare `Seen` for exactly that reason.
    // One second behind the clock, comfortably inside `KvFreshness.staleAfter`.
    lastUpdate: ValueNotifier<DateTime?>(DateTime(2026, 8, 30, 11, 16, 29)),
  ),
  wallet: WalletScope(
    maturity: kTestMaturity,
    mature: ValueNotifier<BigInt?>(BigInt.from(2597792200)),
    pending: ValueNotifier<BigInt?>(BigInt.zero),
    activity: ValueNotifier(activity ?? _activity()),
    syncing: ValueNotifier(false),
    utxoIndexMissing: ValueNotifier(false),
  ),
  clock: () => DateTime(2026, 8, 30, 11, 16, 30),
  // **All four routes wired, because a null route removes the CONTROL, not
  // just its destination.** Without these the catalogue rendered a money
  // screen with no Send, no Receive and an empty nav rail — the two controls
  // BG-12 puts in the resting thumb arc were absent from every contact sheet,
  // and a variation proposed against that picture would be designing around a
  // hole. Same class as the `Send max` fixture gap (D-229); L125 again — a
  // fixture is a claim.
  receiveRoute: (_) => const SizedBox.shrink(),
  sendRoute: (_, _) => const SizedBox.shrink(),
  detailRoute: (_, _, _) => const SizedBox.shrink(),
  // **The `≈` line is one of BG-28's always-true five**, so a fixture with no
  // rate seam renders a money plate that is missing a fifth of itself — and
  // every contact sheet would show the incomplete one. L125 again: a fixture
  // is a claim, and a missing one claims a line does not exist.
  fiat: _fiat(),
);

/// A settled rate: on, quoted, and fresh — so the plate shows the restatement
/// rather than the `≈ —` the first seconds of a launch show.
FiatScope _fiat() => FiatScope(
  enabled: ValueNotifier<bool?>(true),
  quote: ValueNotifier<KvRateQuote?>(
    KvRateQuote(
      usdPerKas: 0.0821,
      fetchedAt: DateTime(2026, 8, 30, 11, 16, 25),
      source: 'preview',
    ),
  ),
);

/// The money screen **with news**: a deposit arriving, a send still in flight,
/// and a link the wallet cannot fully trust — the three things that used to
/// resize the balance card and now share the status panel beneath it (BG-28).
///
/// It exists because `home__funded` renders none of them, so the panel was
/// absent from every contact sheet and the first version of it shipped unlooked
/// at. Same class as the `Send max` fixture gap (D-229); L125 again — a fixture
/// is a claim, and a missing one is a claim that a state does not exist.
Widget _homeStatus() => HomeScreen(
  chain: ChainScope(
    connected: ValueNotifier(true),
    virtualDaaScore: ValueNotifier<BigInt?>(BigInt.from(526633447)),
    error: ValueNotifier<String?>(null),
    lastUpdate: ValueNotifier<DateTime?>(DateTime(2026, 8, 30, 11, 16, 29)),
  ),
  wallet: WalletScope(
    maturity: kTestMaturity,
    mature: ValueNotifier<BigInt?>(BigInt.from(2597792200)),
    pending: ValueNotifier<BigInt?>(BigInt.from(20035640)),
    outgoing: ValueNotifier<BigInt?>(BigInt.from(100000000)),
    activity: ValueNotifier(_activity()),
    syncing: ValueNotifier(true),
    utxoIndexMissing: ValueNotifier(false),
  ),
  clock: () => DateTime(2026, 8, 30, 11, 16, 30),
  receiveRoute: (_) => const SizedBox.shrink(),
  sendRoute: (_, _) => const SizedBox.shrink(),
  fiat: _fiat(),
);

/// **The money screen inside the app's navigation**, which is the only way it
/// is ever seen.
///
/// Without this the four frames would be four pictures of a page with no
/// drawer, no rail and no standing panel — a contact sheet that says
/// "responsive" while proving nothing, and the exact class of fixture gap
/// D-229 recorded. `KvNav` is what turns one page into `compact` pushed,
/// `medium` rail and `expanded` standing.
Widget _shell(Widget home, {int selected = 0}) => KvNav(
  selected: selected,
  header: const KvWalletIdentity(name: 'Main wallet', address: _addr),
  destinations: [
    KvDestination(mark: KvGlyph.money, label: 'Wallet', onTap: () {}),
    KvDestination(mark: KvGlyph.chat, label: 'Messages', onTap: () {}),
    KvDestination(mark: KvGlyph.games, label: 'Games', onTap: () {}),
    const KvDestination(mark: KvGlyph.finance, label: 'Finance'),
    const KvDestination(mark: KvGlyph.identity, label: 'Identity'),
  ],
  // The render's second group and its foot (`S2 · Drawer`, D-261).
  secondary: [
    KvDestination(mark: KvGlyph.settings, label: 'Settings', onTap: () {}),
    KvDestination(
      mark: KvGlyph.network,
      label: 'Network',
      live: ValueNotifier(true),
      onTap: () {},
    ),
    KvDestination(mark: KvGlyph.shield, label: 'Security', onTap: () {}),
    KvDestination(mark: KvGlyph.help, label: 'Help', onTap: () {}),
  ],
  footer: [KvDestination(mark: KvGlyph.lock, label: 'Lock', onTap: () {})],
  child: home,
);

/// Summons the drawer the way a thumb does — the `compact` posture, and a
/// no-op in the classes where navigation already stands.
/// A feed long enough that the rows actually scroll.
List<ActivityRecord> _longActivity() {
  final base = _activity();
  return [
    for (var i = 0; i < 9; i++)
      for (final r in base)
        ActivityRecord(
          txid: '${i.toString().padLeft(2, '0')}${r.txid.substring(2)}',
          valueSompi: r.valueSompi,
          unixtimeMsec: r.unixtimeMsec,
          blockDaaScore: r.blockDaaScore,
          acceptedDaaScore: r.acceptedDaaScore,
          maturity: r.maturity,
          direction: r.direction,
          isCoinbase: r.isCoinbase,
          stalled: r.stalled,
          counterpartyAddress: r.counterpartyAddress,
          feeSompi: r.feeSompi,
        ),
  ];
}

Future<void> _openAll(WidgetTester tester) async {
  await tester.tap(find.text('All'));
  await tester.pump();
  await tester.pump(KvMotion.calm);
  await tester.pump(KvMotion.calm);
}

/// Drag the rows so the plate yields its clock.
Future<void> _readLedger(WidgetTester tester) async {
  await tester.drag(find.byType(Scrollable).last, const Offset(0, -120));
  await tester.pump();
  await tester.pump(KvMotion.calm);
  await tester.pump(KvMotion.calm);
}

Future<void> _summonDrawer(WidgetTester tester) async {
  final avatar = find.bySemanticsLabel('Open navigation');
  if (avatar.evaluate().isEmpty) return;
  await tester.tap(avatar);
}

/// Types an amount on the pad and pastes a destination — the state in which the
/// send screen actually has a fee, an address review and a live Review button.
/// Paste a destination and walk to step 2 (UX-R2 — Send is two steps now).
Future<void> _pasteDestination(WidgetTester tester) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => call.method == 'Clipboard.getData'
        ? <String, dynamic>{'text': _addr}
        : null,
  );
  await tester.tap(
    find.byWidgetPredicate((w) => w is KvGlyphIcon && w.mark == KvGlyph.paste),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// Step 1 with a destination in it, checked — `S6b`.
Future<void> _checkedDestination(WidgetTester tester) async {
  await _pasteDestination(tester);
}

/// Step 2 with a figure on the pad — `S6`.
Future<void> _typeASend(WidgetTester tester) async {
  await _pasteDestination(tester);
  await tester.tap(find.text('Continue to amount'));
  await tester.pump();
  await tester.pump(KvMotion.enter);
  await tester.pump(KvMotion.enter);
  // Scoped to the pad: an unscoped `find.text('.')` matches whatever else on
  // the screen happens to render that glyph, and at the floor geometry it
  // typed `124` instead of `12.4` — a harness artifact that would have read as
  // a screen defect.
  // A short window leaves the pad below the fold AND outside the cache
  // extent, so it is not built at all — `ensureVisible` cannot reach a widget
  // that does not exist. Jump the list first, then scroll to each key.
  final scroll = tester.state<ScrollableState>(
    find
        .descendant(
          of: find.byKey(SendScreen.scrollTarget),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  scroll.position.jumpTo(scroll.position.maxScrollExtent);
  await tester.pump();
  for (final key in ['1', '2', '.', '4']) {
    final cap = find.descendant(
      of: find.byType(KvKeypad),
      matching: find.text(key),
    );
    // A short window puts the pad below the fold; a catalogue frame is a
    // rendering exercise and must not fail because a key needed scrolling to.
    await tester.ensureVisible(cap);
    await tester.pump();
    await tester.tap(cap);
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 600));
}

/// The ceremony **over the page it was built on** (`S7`), composed rather than
/// navigated: a catalogue frame is a rendering exercise, and driving three
/// steps and a push through five window classes fails for reasons that are
/// about the harness rather than about the design. The layering is the point,
/// and this shows exactly it — the scrimmed, blurred Send screen under a
/// floating sheet.
Widget _ceremonyOverSend({bool book = true}) => Stack(
  children: [
    _sendScreen(book: book),
    SigningCeremony(
      summary: _summary(),
      commit: (_) async => _sent(),
      abandon: () async {},
      contacts: book ? _contacts() : null,
      fiat: _fiat(),
      explorerUrl: (txid) async => 'https://explorer.kaspa.org/txs/$txid',
      openUrl: (_) async => true,
      acceptanceStatus: (_) async => TxStatusDto(
        kind: TxStatusKind.accepted,
        blueDepth: BigInt.from(42),
        acceptedUnixMs: BigInt.from(
          DateTime(2026, 8, 30, 11, 16, 50, 103).millisecondsSinceEpoch,
        ),
      ),
    ),
  ],
);

/// **The MESSAGE sending sheet** — the same ceremony over the thread, carrying
/// the founder's signing toggle (2026-09-08).
///
/// It is a self-send, so the sheet leads with the fee and says the value
/// returns; the toggle sits last, under every fact and above the hold. This is
/// the funds surface the toggle changes, so it gets its own frame rather than
/// being judged from a widget test.
Widget _messageCeremony() => Stack(
  children: [
    _thread(),
    SigningCeremony(
      title: 'Confirm message',
      summary: _summary(
        kind: SignableKind.selfSendFrame,
        payloadKind: 'comm',
        payloadLen: 214,
      ),
      commit: (_) async => _sent(),
      abandon: () async {},
      fiat: _fiat(),
      footer: _PreviewSigningToggle(),
    ),
  ],
);

/// The toggle exactly as the thread builds it, without the service round trip
/// a preview run has no native library for.
class _PreviewSigningToggle extends StatelessWidget {
  @override
  Widget build(BuildContext context) => KvToggle(
    bare: true,
    ground: KvColor.plate,
    on: false,
    // The shipped strings, not a copy — a fixture that paraphrases is a frame
    // of a screen that does not exist.
    title: signingToggleTitle,
    sub: signingToggleSub(true),
    onChanged: (_) {},
  );
}

/// **Scroll the message ceremony to its foot**, at the floor geometry where
/// its restatement no longer fits in one view.
///
/// A clip that scrolls is reachable and a clip that does not is a defect, and
/// the difference is not visible in a resting frame — so it gets one of its
/// own (`ux-auditor`, 2026-09-08).
Future<void> _scrollTheCeremony(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.drag(find.byType(ListView).last, const Offset(0, -260));
  await tester.pumpAndSettle();
}

/// All the way to the receipt (`S8`).
Future<void> _completeASend(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.textContaining('Hold to send')),
  );
  await tester.pump();
  await tester.pump(KvMotion.deliberate + const Duration(milliseconds: 20));
  await gesture.up();
  await tester.pumpAndSettle();
}

/// The hold, part-way round — the one state a still frame cannot reach by
/// waiting, and the one BG-6 is about.
Future<void> _armTheHold(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.textContaining('Hold to send')),
  );
  addTearDown(() async => gesture.up());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 340));
}

/// `T5`, and the two states of its node row the happy path cannot show
/// (BG-20): a dark hunt with the cadence in the disc, and a live node that
/// says it is not synced.
Widget _node({bool hunting = false, bool? synced = true}) => NodeScreen(
  scope: NodeScope(
    connected: ValueNotifier(!hunting),
    activeEndpoint: ValueNotifier<String?>(
      hunting ? null : 'wss://isla.kaspa.red',
    ),
    virtualDaaScore: ValueNotifier<BigInt?>(BigInt.from(526633447)),
    pinnedNode: ValueNotifier<String?>(null),
    pinDropped: ValueNotifier(false),
    setPinnedNode: (_) async {},
    searching: ValueNotifier(hunting),
    lastUpdate: ValueNotifier<DateTime?>(DateTime(2026, 8, 30, 11, 16)),
    // **`T5`'s two live seats, wired** — the `Switch node` glow pill and the
    // connection card's measured reading. Left unwired the frames showed a
    // composition the design does not have: no pill at all, and `No reading`
    // where the render draws `151 ms · Slow`. A preview fixture that omits a
    // seam is a picture of the fallback, not of the screen.
    onReconnect: () async {},
    probeLink: ({required bool peers}) async =>
        (latencyMs: 151, peers: 14, synced: synced),
    testNode: (_) async =>
        (latencyMs: 84, serverVersion: '1.0.1', daa: BigInt.from(528980542)),
  ),
  // `T5`'s SOURCES card needs both seams to draw both rows.
  explorer: ExplorerScope(
    read: () async => const ExplorerChoice(
      txTemplate: 'https://explorer.kaspa.org/txs/{txid}',
      addressTemplate: 'https://explorer.kaspa.org/addresses/{address}',
      defaults: [],
    ),
    write: (_, _) async {},
  ),
  rate: RateScope(
    enabled: ValueNotifier<bool?>(true),
    endpoint: ValueNotifier('https://api.kaspa.org/info/price'),
    defaultEndpoint: ValueNotifier('https://api.kaspa.org/info/price'),
    quote: ValueNotifier(null),
    error: ValueNotifier(null),
    setConfig: ({required bool enabled, required String endpoint}) async {},
    load: () async {},
  ),
);

/// Open the pin, type a node, and test it — `T5`'s field row with its answer.
Future<void> _testANode(WidgetTester tester) async {
  // Pumped by hand: the latency dot breathes for as long as there is a
  // reading, so a settle would wait on an animation whose point is not to stop.
  // Below the fold at 320 dp: a `ListView` builds only what the viewport
  // reaches, so the toggle is dragged into view before it is tapped.
  await tester.dragUntilVisible(
    find.text('Use my own node'),
    find.byType(ListView),
    const Offset(0, -200),
  );
  await tester.pump();
  await tester.tap(find.text('Use my own node'));
  await tester.pump();
  await tester.pump(KvMotion.enter);
  await tester.enterText(find.byType(TextField).first, 'ws://mine.local:17110');
  await tester.pump();
  await tester.tap(find.text('Test'));
  await tester.pump();
  await tester.pump(KvMotion.enter);
}

/// **The settings group's five seams, in the state a frame should be read
/// in** (UX-R4): fingerprint enrolled, a 30 s lock grace, both wallet tools
/// wired, the network row on public nodes. A preview built on the *empty*
/// state proves nothing about the screen the founder actually opens.
SecurityScope _securityScope({int grace = 30, String state = pathAReady}) =>
    SecurityScope(
      biometricStatus: () async => 'ready',
      pathAState: () async => state,
      enroll: () async => true,
      clearEnrollment: () async {},
      lockGraceSecs: ValueNotifier(grace),
      setLockGraceSecs: (_) async {},
      lockNow: () async {},
      // A resolved kind, so the frame shows the row a user reads and not the
      // one-frame "unknown" state the harness would otherwise leave it in
      // (`ux-auditor`, UX-R8 re-review).
      inputKind: () async => vault_api.VaultInputKind.passphrase,
    );

/// `T4`'s own numbers, so the preview is a picture of the render and not of a
/// convenient wallet: 31 receive addresses, **3** of them funded — 27.72 ·
/// 0.40 · 0.00905522 — at indices 0, 2 and 14, and 28 empty behind `Show`.
/// A fixture is a claim (L125).
String _bech32(int seed) {
  const alphabet = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
  return [
    for (var i = 0; i < 5; i++) alphabet[(seed * (i + 3) + i * 7) % 32],
  ].join();
}

List<WalletAddressDto> _addressFixture() {
  const funded = {0: 2772000000, 2: 40000000, 14: 905522};
  return [
    for (var i = 0; i < 31; i++)
      WalletAddressDto(
        index: i,
        // Distinct head AND tail per index. A fixture whose rows all compact
        // to the same `qr7m…gfx9t` is a picture of one address repeated
        // thirty-one times, which is not what the screen does (L125).
        address:
            'kaspa:${_bech32(i * 7 + 3)}${'v4k2xn8hq3l6t0wc5yd1sfp7ug' * 2}'
            '${_bech32(i * 11 + 5)}',
        balanceSompi: BigInt.from(funded[i] ?? 0),
        // Index 7 holds a covenant-bound coin: the wallet refuses to move
        // it on every path (D-211), so it is reported and NOT spendable.
        lockedSompi: BigInt.from(i == 7 ? 150000000 : 0),
        // Index 3 has nothing spendable but something on its way, which is the
        // row that must NOT be filed under "empty" (the L92 scar).
        settling: i == 3,
        coinCount: funded.containsKey(i) ? 1 : (i == 7 ? 1 : 0),
      ),
  ];
}

WalletSettingsScope _walletScope({
  bool addresses = true,
  String? mergeRefusal,
}) => WalletSettingsScope(
  receiveAddress: () async => _addr,
  listAddresses: addresses ? () async => _addressFixture() : null,
  receiveRoute: (address, label) => const SizedBox.shrink(),
  deepScan: () async => DeepScanReport(
    depth: 0,
    receiveSeen: 12,
    changeSeen: 6,
    receiveWatched: 42,
    changeWatched: 36,
    widened: false,
  ),
  consolidate: () async => throw UnimplementedError(),
  consolidateEstimate: mergeRefusal != null
      ? () async => throw mergeRefusal
      : () async => ConsolidateEstimateDto(
          feeSompi: BigInt.from(40000),
          utxoCount: 38,
          resultingCoins: 1,
          addressCount: 3,
        ),
  commitSend: (_) async => throw UnimplementedError(),
  abandonSend: () async {},
);

Widget _settings() => SettingsScreen(
  security: _securityScope(),
  wallet: _walletScope(),
  about: const AboutScope(packageInfo: _packageInfo),
  network: NetworkSettingsScope(
    route: (_) => const SizedBox.shrink(),
    pinnedNode: ValueNotifier(null),
    rateEnabled: ValueNotifier(true),
  ),
);

Widget _security() => SecurityScreen(scope: _securityScope());

Widget _walletSettings() => WalletScreen(scope: _walletScope());

/// The seam absent — the card falls back to the one address the wallet can
/// always name, which is what `T4` shipped before the list existed.
Widget _walletNoList() => WalletScreen(scope: _walletScope(addresses: false));

/// Nothing to merge: the wallet in its BEST state. The bar takes the disabled
/// form (the reason as the label), never a live control over nothing.
Widget _walletMerged() => WalletScreen(
  scope: _walletScope(
    mergeRefusal:
        'nothing to merge — your spendable coins are already consolidated',
  ),
);

/// Open the empty tail. `Show` and `All` set the same flag; this taps `Show`.
Future<void> _showAllAddresses(WidgetTester tester) async {
  await tester.tap(find.text('Show'));
  await tester.pump();
  await tester.pump(KvMotion.enter);
}

Widget _about() => AboutScreen(
  scope: AboutScope(
    // **Wired, because a null seam removes the CONTROL, not just its
    // destination** — without `openUrl` the source row loses its external
    // mark, and without a signature the card renders its own failure state.
    // A preview built on those is a preview of a screen nobody has (L125).
    packageInfo: () async => const {
      'version': '1.0.0',
      'build': '3041',
      'signature':
          'a1f39c204b7e88d10e52c6aa71b93f04d2e85c179a0b6e33f41022cd'
          '8b7ae059',
    },
    openUrl: (_) async => true,
  ),
);

/// `T3` — the ceremony over its own screen, which is how it is read.
/// Receive over one of the wallet's own addresses, with the picker wired.
/// `index` picks which: 0 is the default, 5 is the fresh one the render draws.
Widget _receive({int index = 0}) {
  final rows = _addressFixture();
  return ReceiveScreen(
    fetch: () async => rows[index].address,
    index: index,
    addresses: () async => rows,
    share: (_) async => true,
  );
}

Future<void> _openReceivePicker(WidgetTester tester) async {
  await tester.tap(find.byType(ReceiveScreen).hitTestable());
  await tester.pump();
  await tester.tap(find.text('Main'));
  await tester.pump();
  await tester.pump(KvMotion.enter);
}

Future<void> _openLockTimer(WidgetTester tester) async {
  await tester.tap(find.text('Lock when I leave'));
  await tester.pump();
  await tester.pump(KvMotion.enter);
}

Future<Map<String, String>> _packageInfo() async => const {
  'version': '1.0.0',
  'build': '1',
};

/// One send, forty-two blocks deep, with the explorer exit resolved to a
/// plausible host. Fixture data only — no preview ever carries an address, a
/// balance or a txid that belongs to anyone.
/// **The terminal rung, at the same footprint** (BG-20) — the state the
/// happy-path still cannot show: the chip wears `S9`'s check on the blue pill
/// D-248 seated, and the gauge's fill lands on its ceiling.
Widget _txDetailSettled() => _txDetail(daa: 458174000 + 420);

/// The two frames UX-R3's first beat never opened: a **coinbase** row, whose
/// ceiling is the pin's 1,000 (D-249's safety branch), and a **named**
/// counterparty in the lifecycle chip.
const _payee =
    'kaspa:qr7m4h6xk2f9v0s8d3n5t1w7y2b4c6e8g0j2l4n6p8r0t2v4x6z8a0c2e4g6';

Widget _txDetailCoinbase() => _txDetail(daa: 458173900 + 150, coinbase: true);
Widget _txDetailNamed() => _txDetail(named: true);

Widget _txDetail({
  int daa = 458174042,
  bool coinbase = false,
  bool named = false,
}) => TxDetailScreen(
  txid: 'e154009eae73d2ef9cab0a80dc42a62ebb91f93cbdeab514a57ca3b01d7e5d34',
  // A receive's `To` is the wallet's own address (D-276).
  receiveAddress: () async => _addr,
  activity: ValueNotifier<List<ActivityRecord>>([
    ActivityRecord(
      txid: 'e154009eae73d2ef9cab0a80dc42a62ebb91f93cbdeab514a57ca3b01d7e5d34',
      valueSompi: BigInt.from(1240000000),
      // A local `DateTime`, never a bare epoch constant (L173) — a frame
      // rendered on a UTC runner and one rendered here must show the same
      // wall clock, or the catalogue documents the author's timezone.
      unixtimeMsec: BigInt.from(
        DateTime(2026, 8, 30, 3, 48).millisecondsSinceEpoch,
      ),
      blockDaaScore: BigInt.from(458173900),
      acceptedDaaScore: BigInt.from(458174000),
      direction: coinbase
          ? ActivityDirection.incoming
          : ActivityDirection.outgoing,
      isCoinbase: coinbase,
      // `S9` draws a named counterparty and a fee; the fixture carries both so
      // the still shows the composition the render does rather than a stripped
      // version of it. Fixture data only — no preview ever carries an address,
      // a balance or a txid that belongs to anyone.
      counterpartyAddress: coinbase ? null : _payee,
      feeSompi: coinbase ? null : BigInt.from(10000),
      // A mined output is `Pending` at the pin until its own maturity; a spend
      // with an accepting score is `Confirmed` (what the chain layer emits).
      maturity: coinbase ? MaturityState.pending : MaturityState.confirmed,
      stalled: false,
    ),
  ]),
  contacts: named
      ? ContactsScope(
          contacts: ValueNotifier<List<ContactDto>>([
            const ContactDto(address: _payee, name: 'Mara'),
          ]),
          refresh: () async {},
          save: (_, _) async {},
        )
      : null,
  virtualDaaScore: ValueNotifier<BigInt?>(BigInt.from(daa)),
  stale: ValueNotifier<bool>(false),
  maturity: kTestMaturity,
  // `S9` draws the `≈` restatement under the figure, and BG-5 permits it on a record
  // (D-267). Without a scope the line renders nothing at all, so a preview
  // without one would show a composition the design does not have.
  fiat: _fiat(),
  explorerUrl: (txid) async => 'https://explorer.kaspa.org/txs/$txid',
  openUrl: (_) async => true,
  onSendAgain: (_) {},
  onShare: (_) {},
);

/// The gauge at one reading per decade, so the declared scale can be read off
/// a still: 1 lands on its own graduation, 1,000 seats the bracket.
Widget _gaugeLadder() => const Scaffold(
  body: Padding(
    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 48),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        KvBurialGauge(
          stalled: false,
          confirmations: 1,
          maturity: MaturityState.pending,
          direction: ActivityDirection.outgoing,
          isCoinbase: false,
          thresholds: kTestMaturity,
        ),
        SizedBox(height: 32),
        KvBurialGauge(
          stalled: false,
          confirmations: 10,
          maturity: MaturityState.pending,
          direction: ActivityDirection.outgoing,
          isCoinbase: false,
          thresholds: kTestMaturity,
        ),
        SizedBox(height: 32),
        KvBurialGauge(
          stalled: false,
          confirmations: 340,
          maturity: MaturityState.accepted,
          direction: ActivityDirection.outgoing,
          isCoinbase: false,
          thresholds: kTestMaturity,
        ),
        SizedBox(height: 32),
        KvBurialGauge(
          stalled: false,
          confirmations: 4200,
          maturity: MaturityState.confirmed,
          direction: ActivityDirection.outgoing,
          isCoinbase: false,
          thresholds: kTestMaturity,
        ),
      ],
    ),
  ),
);

Future<void> _openRequestsTab(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.text('Requests'));
  await tester.pumpAndSettle();
}

/// Long-press a row, then take its Hide confirm — the shared `_ConfirmSheet`.
Future<void> _openHideConfirm(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.longPress(find.byType(KvRow).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Hide conversation'));
  await tester.pumpAndSettle();
}

/// Long-press a row, then take its Block confirm (D-308).
Future<void> _openBlockConfirm(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.longPress(find.byType(KvRow).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Block contact'));
  await tester.pumpAndSettle();
}

/// The Requests lane, then the first card's `Block` — the invitation variant
/// of the confirm.
Future<void> _openRequestBlockConfirm(WidgetTester tester) async {
  await _openRequestsTab(tester);
  await tester.tap(find.text('Block').first);
  await tester.pumpAndSettle();
}

/// The thread's overflow, with its Block row.
Future<void> _openThreadActions(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.bySemanticsLabel('Thread actions'));
  await tester.pumpAndSettle();
}

/// The blocked list's one row, then its Unblock confirm.
Future<void> _openUnblockConfirm(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.text('Mara'));
  await tester.pumpAndSettle();
}

/// Message settings, then the erase — the one sheet with two acts.
Future<void> _openWipeSheet(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.bySemanticsLabel('Message settings'));
  await tester.pumpAndSettle();
  // The row sits under the fold at the short geometry now that `Contacts`
  // is above it, and a `ListView` child under the fold is not built.
  await tester.scrollUntilVisible(
    find.text('Delete all messages'),
    120,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Delete all messages').last);
  await tester.pumpAndSettle();
}

/// It is reached through message settings now — the bar no longer carries it
/// (founder, 2026-09-08).
Future<void> _openHistorySheet(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.bySemanticsLabel('Message settings'));
  await tester.pumpAndSettle();
  await tester.tap(find.bySemanticsLabel('History & backup'));
  await tester.pumpAndSettle();
}

/// **Type into the composer, so the fee and the lit send mark are in a frame.**
///
/// An empty composer is the honest resting state and it is what
/// `messages__thread` shows — but it draws neither of the two things this
/// sitting built there. A control that only ever appears mid-interaction is
/// exactly the kind that ships wrong, so it gets a frame of its own.
Future<void> _typeADraft(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'on my way — ten minutes');
  // Past the composer's 250 ms fee debounce, so the quote has landed.
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

/// It pushes a SCREEN now (founder, 2026-09-08) — the settings live in
/// Settings › App › Messages and the overflow opens the same page.
Future<void> _openMessageSettings(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.bySemanticsLabel('Message settings'));
  await tester.pumpAndSettle();
}

void main() {
  // A render is a claim about now: a frame a renamed fixture left behind is
  // read as current the moment someone opens it (this happened, six hours
  // stale, in the sitting that had replaced the design it showed).
  setUpAll(() async {
    clearPreviousFrames();
    await loadBundledFonts();
    // **Set once, for the whole file** (`ffi-leak-auditor` · `consensus`,
    // UX-R5). A fixture that sets a mutable static leaks it into every later
    // test in the isolate; a `tearDown` that restores it to the real bridge
    // fn is worse — the next preview to render `ContactsScreen` outside the
    // messages fixture would then call into an uninitialized `RustLib`. There
    // is no native library in a preview run at all, so the seam is the file's.
    MessagingService.handshakeBondFn = () => BigInt.from(20000000);
  });

  /// Renders one surface at BOTH geometries. The floor is where things break;
  /// a preview that only shows the reference is the comfortable half.
  void surface(
    String name,
    Widget Function() build, {
    Future<void> Function(WidgetTester tester)? act,
  }) {
    for (final size in PreviewSize.all) {
      testWidgets('preview: $name @ ${size.label}', (tester) async {
        await renderSurface(
          tester,
          name: name,
          child: build(),
          size: size,
          act: act,
        );
      }, skip: !previewRequested);
    }
  }

  /// Renders one surface in **all four BG-33 spec frames plus the floor**.
  ///
  /// Use this for anything already built to `KvWindowClass`; `surface()` stays
  /// the two-geometry form for surfaces still wearing Black Glass, which have
  /// no four-frame answer yet and would only produce four identical stretched
  /// columns — a picture that says "responsive" while proving nothing.
  /// Tap Unlock and let the lane throw `key_invalidated`, which is the only
  /// way to reach the notice state — it is a consequence, never a flag.
  Future<void> failBiometricUnlock(WidgetTester tester) async {
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
  }

  Future<void> openWalletsSheet(WidgetTester tester) async {
    await tester.tap(find.text(KvWalletIdentity.soleWalletName));
    await tester.pumpAndSettle();
  }

  void framedSurface(
    String name,
    Widget Function() build, {
    Future<void> Function(WidgetTester tester)? act,
  }) {
    for (final size in PreviewSize.allFrames) {
      testWidgets('preview: $name @ ${size.label}', (tester) async {
        await renderSurface(
          tester,
          name: name,
          child: build(),
          size: size,
          act: act,
        );
      }, skip: !previewRequested);
    }
  }

  group('surface previews (tier 2 — no device)', () {
    // `find.bySemanticsLabel` needs the semantics tree built.
    setUp(() => SemanticsBinding.instance.ensureSemantics());
    // **The money screen, in all four window classes** (BG-33, UX-R1): the
    // pushed drawer at `compact`, the 80 dp rail at `medium`, ledger + detail
    // beside a standing drawer at `expanded`, and the `KvMoneyBar` collapse at
    // `expanded short`.
    framedSurface('home__funded', () => _shell(_home()));
    framedSurface('home__status', () => _shell(_homeStatus()));
    framedSurface('home__drawer', () => _shell(_home()), act: _summonDrawer);
    // `All` — the feed on its own surface (founder, 2026-09-06), and what a
    // scroll costs: the chain clock, and nothing else.
    framedSurface(
      'home__activity_all',
      () => _shell(_home(activity: _longActivity())),
      act: _openAll,
    );
    // **Enough rows to scroll.** With the two-row feed the drag produces no
    // downward delta, nothing yields, and the frame shows the resting state
    // under a name claiming otherwise — a picture that lies (L125).
    framedSurface(
      'home__reading',
      () => _shell(_home(activity: _longActivity())),
      act: _readLedger,
    );
    // A drawer destination without a feature behind it (D-261).
    framedSurface(
      'coming_soon_page',
      () => const KvComingSoonPage(
        mark: KvGlyph.games,
        name: 'Games',
        sentence: 'Not built yet. The arcade will live here.',
      ),
    );
    // **Receive, in all four frames** (`S5`, UX-R2): the card, the tile, the
    // address that copies on tap, and the two actions at the foot.
    framedSurface(
      'receive__address',
      () => ReceiveScreen(fetch: () async => _addr, share: (_) async => true),
    );

    // **The picker's three states** (UX-R4b), against the founder's renders:
    // the default address with its pill, a fresh one chosen, and the sheet.
    framedSurface('receive__picker_default', () => _receive());
    // Index 9 is fresh; index 5 is the row that is USED only because this
    // phone handed it out, and the sheet frame is where that one is read.
    framedSurface('receive__picker_fresh', () => _receive(index: 9));
    // **All five frames for the sheet**: `KvSheet` transforms at `medium`+
    // (560 wide, floating, four radii) and a picker nobody has seen there is
    // a picker whose widest form is unjudged (§3a.2).
    framedSurface(
      'receive__picker_sheet',
      () => _receive(),
      act: _openReceivePicker,
    );
    // **The failed state, at the same footprint** (BG-20) — the one no
    // happy-path preview can show.
    framedSurface(
      'receive__failed',
      () => ReceiveScreen(
        fetch: () async => throw const AppError(message: 'the vault is locked'),
      ),
    );
    // **`T5`, in all five frames** (UX-R3): the connection card, the node row
    // and its `Switch node` pill. It clamps with `KvColumn` now, so the four
    // spec frames say something rather than showing one stretched column.
    framedSurface('node__connected', _node);
    surface('node__hunting', () => _node(hunting: true));
    surface('node__unsynced', () => _node(synced: false));
    surface('node__test', _node, act: _testANode);
    // **`T1` · `T2` · `T3` · `T4` · `T6`, the whole group** (UX-R4). The root
    // and Security owe a one-view fit, so both are framed: a frame is where
    // the fit is *read*, and the guard in `settings_group_test` is where it is
    // proven.
    framedSurface('settings__root', _settings);
    framedSurface('settings__security', _security);
    surface('settings__lock_timer', _security, act: _openLockTimer);
    framedSurface('settings__wallet', _walletSettings);
    surface('settings__wallet_fit', _walletSettings);
    framedSurface(
      'settings__wallet_all',
      _walletSettings,
      act: _showAllAddresses,
    );
    framedSurface('settings__wallet_nomerge', _walletMerged);
    framedSurface('settings__wallet_noseam', _walletNoList);
    framedSurface('settings__about', _about);

    // **Send, both steps, in all four frames** (`S6a` · `S6b` · `S6`).
    // **UX-R5 — the messages group.** `M1`'s list, `M2`'s requests lane with
    // its gloss and its two actions, `M1` with nothing in it, and `M4`'s
    // thread. Every one at the 320 dp / 1.3× floor as well as the reference,
    // because that is where this line's composition defects have all been
    // found.
    framedSurface('messages__chats', _chats);
    // **All four frames, not two.** The register's C/M/E/S/F columns cannot be
    // ticked off a two-geometry render, and the `Wrap` action row is the layout
    // most likely to move at 700/1180 — so it was the one never drawn there
    // (`ux-auditor` 24d, UX-R5).
    framedSurface(
      'messages__requests',
      () => _chats(requests: true),
      act: _openRequestsTab,
    );
    surface('messages__empty', () => _chats(empty: true));
    framedSurface('messages__thread', _thread);
    framedSurface('messages__thread_frames', _threadFrames);
    framedSurface('messages__thread_files', () => _threadFrames(files: true));
    // The composer mid-draft: the live fee above the mark, and the mark lit
    // (BG-27) — neither of which the resting frame above can show.
    framedSurface('messages__composing', _thread, act: _typeADraft);
    framedSurface('messages__history', _chats, act: _openHistorySheet);
    framedSurface(
      'messages__handshake',
      () => NewHandshakeScreen(bond: BigInt.from(20000000)),
    );
    framedSurface('messages__settings', _chats, act: _openMessageSettings);
    // **The notice in its only seat** (D-309). It hangs under `History &
    // backup`, inside the card and over the container's own hairline, and it
    // pushes `Delete all messages` down for as long as it has something to
    // say — none of which the quiet frame above can show.
    framedSurface(
      'messages__settings_notice',
      () => _chats(gapMinutes: 235),
      act: _openMessageSettings,
    );
    // And the other half of the same truth: the list says it with the dot on
    // its settings mark, never with a plate under the search field.
    framedSurface('messages__chats_alert', () => _chats(gapMinutes: 235));
    // The confirm ceremony, which had no frame at all.
    framedSurface('messages__confirm', _chats, act: _openHideConfirm);
    // **Block, and the list behind it** (D-308): the confirm off a row's
    // long-press, the wipe sheet with its backup door and the D-307 copy, and
    // the Blocked addresses screen no render covers.
    framedSurface('messages__block', _chats, act: _openBlockConfirm);
    // The request's own variant of the sheet, the thread's overflow with its
    // new row, the unblock confirm, and the list with nobody in it.
    framedSurface(
      'messages__block_request',
      () => _chats(requests: true),
      act: _openRequestBlockConfirm,
    );
    framedSurface('messages__thread_actions', _thread, act: _openThreadActions);
    framedSurface('messages__unblock', _blocked, act: _openUnblockConfirm);
    framedSurface('messages__blocked_empty', () => _blocked(empty: true));
    framedSurface('messages__wipe', _chats, act: _openWipeSheet);
    framedSurface('messages__blocked', _blocked);
    // **The revived thread** (D-307): readable, and the composer's seat holds
    // the handshake door instead of a field.
    framedSurface('messages__thread_revived', () => _thread(revived: true));

    framedSurface('send__recipient', _sendScreen);
    framedSurface('send__checked', _sendScreen, act: _checkedDestination);
    framedSurface('send__amount', _sendScreen, act: _typeASend);
    // **The amber state, which is the one the founder asked to be able to
    // read** (2026-09-04): a shortfall notice under the fee row, and it has to
    // clear the pad rather than sitting half under it.
    framedSurface(
      'send__short',
      () => _sendScreen(mature: BigInt.from(1000000000)),
      act: _typeASend,
    );
    // **The stranger's half of both steps** (UX-R2B): no card to pick from,
    // *Save as contact* on the checked line, and the recipient row wearing
    // §4's stranger disc instead of a monogram.
    framedSurface('send__recipient_nobook', () => _sendScreen(book: false));
    framedSurface(
      'send__checked_nobook',
      () => _sendScreen(book: false),
      act: _checkedDestination,
    );

    // **The ceremony as a sheet over the page it was built on** (`S7`) — and
    // the hold part-way round, which is the state BG-6 is about.
    framedSurface('ceremony__review', _ceremonyOverSend);
    framedSurface('ceremony__holding', _ceremonyOverSend, act: _armTheHold);
    // The message ceremony, with the signing toggle under the facts.
    framedSurface('ceremony__message', _messageCeremony);
    // Its foot, where the toggle lives at the floor geometry.
    framedSurface(
      'ceremony__message_foot',
      _messageCeremony,
      act: _scrollTheCeremony,
    );

    // **The receipt** (`S8`): a place, not a modal.
    framedSurface('ceremony__sent', _ceremonyOverSend, act: _completeASend);
    // The receipt for an address the book does not know: *Save as contact*
    // stands where the name would be, and never the word "Unknown".
    framedSurface(
      'ceremony__sent_nobook',
      () => _ceremonyOverSend(book: false),
      act: _completeASend,
    );

    // ── UX-R6 · onboarding, create and restore (`O1`–`O7`) ───────────────
    //
    // Every seam injected, so a preview run never touches the vault, the
    // ceremony channel or a biometric prompt. `O3` and `O4` are absent on
    // purpose and it is not an omission: the word reveal and its quiz are a
    // separate FLAG_SECURE Activity (D-039) and no Flutter harness can render
    // them — they are settled on glass, and nowhere else.
    framedSurface('onboarding__welcome', () => const OnboardingSurface());
    framedSurface('onboarding__passphrase', _createScreen);
    framedSurface('onboarding__extra_word', _createScreen, act: _toExtraWord);
    framedSurface(
      'onboarding__extra_word_on',
      _createScreen,
      act: _openTheExtraWord,
    );
    // **The D-312 states, framed** — the pad choice and the reveal. Both are
    // new geometry: the number pad is 236 dp where the keyboard is 248, the
    // commit control disappears on the PIN path, and the revealed field GROWS.
    // None of that had a picture until now.
    framedSurface('onboarding__pin', _createScreen, act: _toPinPad);
    framedSurface(
      'onboarding__extra_word_revealed',
      _createScreen,
      act: _revealTheExtraWord,
    );
    framedSurface('onboarding__biometrics', _createScreen, act: _toBiometrics);
    framedSurface('restore__words', _restoreScreen);
    framedSurface('restore__typing', _restoreScreen, act: _typeAWord);
    framedSurface('restore__picked', _restoreScreen, act: _pickWords);
    // **The four steps that had no frame at any geometry** — and one of them
    // is the typo trap, which is the whole safety property of the restore
    // ceremony (`ux-auditor`, UX-R6: *four of restore's five steps have no
    // frame*). The address preview is where a wrong word becomes visible as a
    // different wallet, and it was unlooked-at.
    framedSurface('restore__extra_word', _restoreScreen, act: _toRestoreExtra);
    framedSurface('restore__preview', _restoreScreen, act: _toRestorePreview);
    framedSurface(
      'restore__passphrase',
      _restoreScreen,
      act: _toRestorePassphrase,
    );
    framedSurface(
      'restore__biometrics',
      _restoreScreen,
      act: _toRestoreBiometrics,
    );
    // **The locked vault, in every state it has** (UX-R7, render
    // `Unlock-selection.png`). This is the only screen a sealed wallet ever
    // shows, so each of its states gets a picture rather than the resting one
    // standing in for all of them (L205: three states shipped with no frames
    // is how a 34 dp overflow and a truncated secret reached an auditor).
    framedSurface(
      'unlock__locked',
      () => UnlockSurface(
        probe: () async => true,
        unlock: () async => true,
        inputKind: () async => vault_api.VaultInputKind.passphrase,
        lockedAt: ValueNotifier<DateTime?>(DateTime(2026, 9, 9, 9, 41)),
      ),
    );
    // A cold start onto a sealed vault: no transition was witnessed, so the
    // `Locked at` seat is empty and holds its height (BG-24).
    framedSurface(
      'unlock__locked_cold',
      () => UnlockSurface(
        probe: () async => true,
        unlock: () async => true,
        inputKind: () async => vault_api.VaultInputKind.passphrase,
        lockedAt: ValueNotifier<DateTime?>(null),
      ),
    );
    // No biometric on offer — Path B takes the primary pill.
    framedSurface(
      'unlock__no_biometric',
      () => UnlockSurface(
        probe: () async => false,
        unlock: () async => true,
        inputKind: () async => vault_api.VaultInputKind.digits,
        lockedAt: ValueNotifier<DateTime?>(DateTime(2026, 9, 9, 9, 41)),
      ),
    );
    // `Unlock-selection (1).png` — the fingerprints changed and the Keystore
    // key is gone until it is set up again.
    framedSurface(
      'unlock__key_invalidated',
      () => UnlockSurface(
        probe: () async => true,
        unlock: () async =>
            throw PlatformException(code: biometricKeyInvalidated),
        inputKind: () async => vault_api.VaultInputKind.passphrase,
        lockedAt: ValueNotifier<DateTime?>(DateTime(2026, 9, 9, 9, 41)),
      ),
      act: failBiometricUnlock,
    );
    // `Unlock-selection (2).png` — the switcher, shown before it is built
    // (D-313 §1).
    framedSurface(
      'unlock__wallets_sheet',
      () => UnlockSurface(
        probe: () async => true,
        unlock: () async => true,
        inputKind: () async => vault_api.VaultInputKind.passphrase,
        lockedAt: ValueNotifier<DateTime?>(DateTime(2026, 9, 9, 9, 41)),
      ),
      act: openWalletsSheet,
    );
    // The two states this group adds that would otherwise ship with no
    // picture (L205: a builder's obligation, not a reviewer's catch). The
    // lost-secret sheet was a third until the founder removed it (D-316 §6).
    framedSurface(
      'unlock__failed_attempt',
      () => UnlockSurface(
        probe: () async => true,
        unlock: () async => false,
        inputKind: () async => vault_api.VaultInputKind.passphrase,
        lockedAt: ValueNotifier<DateTime?>(DateTime(2026, 9, 9, 9, 41)),
      ),
      act: failBiometricUnlock,
    );
    framedSurface(
      'unlock__unlocking',
      () => UnlockSurface(
        probe: () async => true,
        // Never completes, so the pill stays in its busy form for the shot.
        unlock: () => Completer<bool>().future,
        inputKind: () async => vault_api.VaultInputKind.passphrase,
        lockedAt: ValueNotifier<DateTime?>(DateTime(2026, 9, 9, 9, 41)),
      ),
      act: failBiometricUnlock,
    );
    // **The refusal surface** — the one state in this group that cannot be
    // faked on a device without actually switching a service on, and the one
    // that appears in front of a user who is probably relying on it.
    framedSurface(
      'guard__accessibility_refusal',
      () => SecretScreenGuard(
        title: 'your passphrase',
        checkAccessibility: () async => true,
        setSecure: ({required bool enable}) async {},
        child: const SizedBox.shrink(),
      ),
    );
    framedSurface(
      'unlock__passphrase',
      () => PassphraseUnlockScreen(
        unlock: (p) async {},
        checkAccessibility: () async => false,
        setSecure: ({required bool enable}) async {},
      ),
    );

    surface(
      'address__chunked',
      () => const Scaffold(
        body: Padding(
          padding: EdgeInsets.all(16),
          child: KvAddress(_addr, form: KvAddressForm.chunked),
        ),
      ),
    );

    surface(
      'address__chunked_selectable',
      () => const Scaffold(
        body: Padding(
          padding: EdgeInsets.all(16),
          child: KvAddress(
            _addr,
            form: KvAddressForm.chunked,
            selectable: true,
          ),
        ),
      ),
    );

    // The two drawn caps BG-25 put here (D-229) ship on this surface and had
    // nowhere to be looked at. `design-uplift` cannot touch a surface that is
    // not in this catalogue, so a screen with new marks on it belongs in it.
    surface(
      'keyboard__secret',
      () => Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SecretKeyboard(onChar: (_) {}, onBackspace: () {}),
        ),
      ),
    );

    // **The transaction detail and its gauge** — UX-5's new surface, and the
    // one place in the app where a declared logarithmic scale is drawn. A
    // still is exactly the right instrument for judging an axis.
    // **`S9`, in all five frames** (UX-R3).
    framedSurface('tx__detail', _txDetail);
    surface('tx__detail_settled', _txDetailSettled);
    surface('tx__detail_coinbase', _txDetailCoinbase);
    surface('tx__detail_named', _txDetailNamed);

    // The gauge alone, at four readings that sit on the four decades. Whether
    // a log axis reads as a scale rather than as a progress bar is a judgement
    // a contact sheet settles and an argument does not (D-228's ladder).
    surface('tx__gauge_ladder', _gaugeLadder);

    surface(
      'burial__ladder',
      () => const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              KvBurialMark(
                stalled: false,
                confirmations: 42,
                maturity: MaturityState.pending,
                direction: ActivityDirection.outgoing,
                isCoinbase: false,
                thresholds: kTestMaturity,
              ),
              SizedBox(height: 12),
              KvBurialMark(
                stalled: false,
                confirmations: 420,
                maturity: MaturityState.accepted,
                direction: ActivityDirection.outgoing,
                isCoinbase: false,
                thresholds: kTestMaturity,
              ),
              SizedBox(height: 12),
              KvBurialMark(
                stalled: false,
                confirmations: 4200,
                maturity: MaturityState.confirmed,
                direction: ActivityDirection.outgoing,
                isCoinbase: false,
                thresholds: kTestMaturity,
              ),
            ],
          ),
        ),
      ),
    );

    // ── Deep V6 · UX-R0's own surfaces ──────────────────────────────────────

    // **The mark, at every canon size and in all three styles** (§4a). It is
    // LOCKED, so this sheet is the record of what "locked" looks like: a later
    // sitting that redraws, traces or tidies it has a picture to be wrong
    // against. The gap between stem and chevron is the thing to look at — it
    // is why the stroke CLIMBS as the mark shrinks.
    framedSurface('mark__ladder', _markLadder);

    // **Every coming-soon placement** (§4, D-247). This is the founder's own
    // acceptance condition rendered: where a feature does not exist yet, the
    // surface says so in the seat the feature will occupy. Four features, one
    // sheet, and the answer to "where do I build next" is a picture.
    framedSurface('coming_soon__all', _comingSoon);
  });
}

/// The locked mark at its canon sizes, plus the bare and tile styles.
Widget _markLadder() => const Scaffold(
  body: Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 20,
          runSpacing: 20,
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            KvMark(size: 96),
            KvMark(size: 64),
            KvMark(size: 40),
            KvMark(size: 28),
            KvMark(size: 24, halo: false),
          ],
        ),
        SizedBox(height: 28),
        Wrap(
          spacing: 20,
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            KvMark(size: 40, style: KvMarkStyle.bare),
            KvMark(size: 28, style: KvMarkStyle.bare),
            KvMark(size: 64, style: KvMarkStyle.tile),
          ],
        ),
      ],
    ),
  ),
);

/// The four unbuilt features, each in the plate it will be replaced by.
///
/// **Scrolls, because the catalogue is the artificial case.** In the build each
/// of these sits alone in a different screen's list; four stacked in one 320 dp
/// frame at 1.3× is a density no real surface has, and the floor frame caught
/// it on the first render. A `SingleChildScrollView` is what the real seats
/// are, so the sheet shows the plates at their true size rather than four
/// squeezed ones (BG-14 — the layout survives the floor; it is not exempted
/// from it).
Widget _comingSoon() => const Scaffold(
  body: SafeArea(
    child: SingleChildScrollView(
      padding: EdgeInsets.all(KvSpace.gutter),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          KvComingSoon(mark: KvGlyph.games, name: 'Arcade'),
          SizedBox(height: KvSpace.sm),
          KvComingSoon(mark: KvGlyph.assets, name: 'Assets'),
          SizedBox(height: KvSpace.sm),
          KvComingSoon(mark: KvGlyph.finance, name: 'Swaps'),
          SizedBox(height: KvSpace.sm),
          KvComingSoon(mark: KvGlyph.contracts, name: 'Contracts'),
        ],
      ),
    ),
  ),
);

// ── UX-R6 fixtures ────────────────────────────────────────────────────────

/// The create ceremony with every platform seam injected: the native reveal
/// answers `true` without an Activity, the seal writes nothing, and the
/// biometric probe reports a phone that can offer enrolment.
Widget _createScreen() => CreateScreen(
  begin: () async {},
  reveal: () async => true,
  abandon: () async {},
  seal: (p, x, k) async {},
  biometricStatus: () async => 'ready',
  enroll: () async => true,
  // A phone that CAN hardware-bind, so the PIN is reachable at all — the
  // refusal path is a screen of its own and belongs in the widget suite, not
  // in a picture (D-312).
  deviceBinding: () async => true,
  checkAccessibility: () async => false,
  setSecure: ({required bool enable}) async {},
);

Widget _restoreScreen() => RestoreScreen(
  wordlist: const Bip39Wordlist.forTest([
    'gravity',
    'grace',
    'grain',
    'grant',
    'anchor',
    'orbit',
    'ripple',
  ]),
  setSecure: ({required bool enable}) async {},
  checkAccessibility: () async => false,
  preview: (phrase, extra) async =>
      'kaspa:qz0k5x8m3n7p2q9r4s6t1u8v3w5y7z2a4b6c8d0e2f4g6h8j',
  commit: (phrase, extra, pass) async {},
  biometricStatus: () async => 'ready',
  enroll: () async => true,
);

Future<void> _settleCeremony(WidgetTester tester) async {
  // Not `pumpAndSettle`: the guard and the preparing beat spin an infinite
  // animation, which would hang it.
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Tap something that may be under the fold. The short landscape frame gives
/// a ceremony ~350 dp of body under a pinned keyboard, so every control on
/// these screens is reached rather than aimed at.
Future<void> _reachCeremony(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f.first);
  await _settleCeremony(tester);
  await tester.tap(f.first);
  await _settleCeremony(tester);
}

Future<void> _typePassphrase(WidgetTester tester) async {
  await _settleCeremony(tester);
  for (final c in ['s', 'e', 'v', 'e', 'n', 'p', 'a', 's', 's']) {
    await tester.tap(find.text(c).first);
    await _settleCeremony(tester);
  }
}

/// `O5`, as it opens: the question, the switch off, one way on.
Future<void> _toExtraWord(WidgetTester tester) async {
  await _typePassphrase(tester);
  await _reachCeremony(tester, find.text('Next'));
}

/// `O5` with the switch thrown — the fields, the notice plate and the skip.
Future<void> _openTheExtraWord(WidgetTester tester) async {
  await _toExtraWord(tester);
  await _reachCeremony(tester, find.byType(KvToggle));
  await _reachCeremony(tester, find.text('Type it here'));
  for (final c in ['h', 'a', 'r', 'b', 'o', 'u', 'r']) {
    await tester.tap(find.text(c).first);
    await _settleCeremony(tester);
  }
}

/// **`O2` on the PIN pad** (D-312): six wells, the number pad, no commit.
///
/// This state had no frame at any geometry, and that is exactly how a 34 dp
/// overflow at 915 × 412 reached an auditor instead of a golden — on the one
/// screen whose own comments record a previous BLOCK at that frame
/// (`ux-auditor`, D-312).
Future<void> _toPinPad(WidgetTester tester) async {
  await _settleCeremony(tester);
  await _reachCeremony(tester, find.text('Use a 6-digit PIN'));
  for (final d in ['4', '8', '1']) {
    await tester.tap(find.text(d).first);
    await _settleCeremony(tester);
  }
}

/// **`O5` with the eye held down** (D-312 §3) — the one state where a secret is
/// legible, and the state that has to be looked at at every geometry, because
/// the field grows to hold the whole word rather than fading its tail.
Future<void> _revealTheExtraWord(WidgetTester tester) async {
  await _openTheExtraWord(tester);
  final eye = find.byWidgetPredicate(
    (w) => w is KvGlyphIcon && w.mark == KvGlyph.eye,
  );
  await tester.ensureVisible(eye.first);
  await _settleCeremony(tester);
  // Held, not tapped: the reveal is a press that ends on release, so the frame
  // has to be taken with the finger still down.
  await tester.startGesture(tester.getCenter(eye.first));
  await _settleCeremony(tester);
}

/// `O6`, reached the way a user reaches it: through the seal.
Future<void> _toBiometrics(WidgetTester tester) async {
  await _toExtraWord(tester);
  await _reachCeremony(tester, find.text('Continue — 12 words only'));
}

/// `O7` mid-word: the prefix in its own chip, the suggestions above the keys.
Future<void> _typeAWord(WidgetTester tester) async {
  await tester.pumpAndSettle();
  for (final c in ['g', 'r', 'a']) {
    await _reachCeremony(tester, find.text(c));
  }
}

/// `O7` with a tray that has grown — the geometry the pinned foot exists for.
Future<void> _pickWords(WidgetTester tester) async {
  await tester.pumpAndSettle();
  for (var i = 0; i < 7; i++) {
    await _reachCeremony(tester, find.text('g'));
    await _reachCeremony(tester, find.text('grace'));
  }
}

/// Fill the tray, then leave the words with the switch in the given position.
Future<void> _restoreWords(WidgetTester tester, {required bool extra}) async {
  await tester.pumpAndSettle();
  if (extra) {
    await _reachCeremony(tester, find.text('13th word'));
  }
  for (var i = 0; i < 12; i++) {
    await _reachCeremony(tester, find.text('g'));
    await _reachCeremony(tester, find.text('grace'));
  }
  await _reachCeremony(tester, find.widgetWithText(KvAction, 'Continue'));
}

Future<void> _toRestoreExtra(WidgetTester tester) =>
    _restoreWords(tester, extra: true);

Future<void> _toRestorePreview(WidgetTester tester) =>
    _restoreWords(tester, extra: false);

Future<void> _toRestorePassphrase(WidgetTester tester) async {
  await _toRestorePreview(tester);
  await _reachCeremony(
    tester,
    find.widgetWithText(KvAction, 'This is my wallet'),
  );
}

Future<void> _toRestoreBiometrics(WidgetTester tester) async {
  await _toRestorePassphrase(tester);
  for (final c in ['s', 'e', 'v', 'e', 'n']) {
    await _reachCeremony(tester, find.text(c));
  }
  await _reachCeremony(tester, find.widgetWithText(KvAction, 'Restore wallet'));
}
