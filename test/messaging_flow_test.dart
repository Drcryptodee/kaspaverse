import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/rust/api/send.dart';
import 'package:kaspaverse/src/rust/api/transport.dart';
import 'package:kaspaverse/src/services/messaging_service.dart';
import 'package:kaspaverse/src/ui/error_text.dart';
import 'package:kaspaverse/src/ui/messages/contacts_screen.dart';
import 'package:kaspaverse/src/ui/messages/history_fill_sheet.dart';
import 'package:kaspaverse/src/ui/messages/thread_screen.dart';

ConversationDto conversation(
  String id, {
  String status = 'active',
  bool inviteExpired = false,
  String? contactName,
  String address =
      'kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf',
}) => ConversationDto(
  conversationId: id,
  contactAddress: status == 'pending_in' ? '' : address,
  myAlias: 'fa6d1afa79e1',
  theirAlias: 'a1e1b60b5fca',
  status: status,
  initiatedByMe: status != 'pending_in',
  createdUnixMs: BigInt.one,
  lastActivityUnixMs: BigInt.two,
  inviteExpired: inviteExpired,
  contactName: contactName,
);

ThreadMessageDto message(
  String txid, {
  String kind = 'comm',
  bool outbound = false,
  String text = 'hello over L1',
  bool readable = true,
  FrameDto? frame,
  bool tombstoned = false,
  String provenance = 'node',
  AttachmentDto? attachment,
  BigInt? unixMs,
}) => ThreadMessageDto(
  txid: txid,
  kind: kind,
  outbound: outbound,
  unixMs: unixMs ?? BigInt.one,
  text: text,
  readable: readable,
  frame: frame,
  tombstoned: tombstoned,
  provenance: provenance,
  attachment: attachment,
);

FrameDto frameDto({
  required String kind,
  String game = '',
  String stake = '',
  String id = '',
  String detail = '',
}) => FrameDto(kind: kind, game: game, stake: stake, id: id, detail: detail);

/// Wrap a message list as the V2 incremental pull's answer — statuses mirror
/// each row's tombstone flag; [acceptance] (txid → status) drives the chips.
ThreadDeltaDto delta(
  List<ThreadMessageDto> messages, {
  Map<String, TxStatusDto> acceptance = const {},
}) => ThreadDeltaDto(
  messages: messages,
  statuses: [
    for (final m in messages)
      MessageStatusDto(
        txid: m.txid,
        tombstoned: m.tombstoned,
        acceptance: acceptance[m.txid],
      ),
  ],
);

TxStatusDto status(TxStatusKind kind, {int? depth}) => TxStatusDto(
  kind: kind,
  blueDepth: depth == null ? null : BigInt.from(depth),
  waitedMs: null,
);

SignableSummaryDto summary({
  BigInt? amount,
  SignableKind kind = SignableKind.bondRefund,
  String payloadKind = 'handshake',
}) => SignableSummaryDto(
  nonce: BigInt.from(7),
  kind: kind,
  destination:
      'kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf',
  amountSompi: amount ?? BigInt.from(20000000),
  feeSompi: BigInt.from(31000),
  totalSompi: (amount ?? BigInt.from(20000000)) + BigInt.from(31000),
  mass: BigInt.from(2000),
  txCount: 1,
  utxoCount: 1,
  payloadLen: 154,
  payloadKind: payloadKind,
  feeStrategy: FeeStrategyKind.senderPays,
  priorityFeeSompi: BigInt.zero,
);

/// Invitations live in the Requests tab now — go there before looking for one.
Future<void> openRequests(WidgetTester tester) async {
  await tester.tap(find.text('Requests'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StreamController<String> pings;

  setUp(() async {
    pings = StreamController<String>();
    MessagingService.pingFactory = () => pings.stream;
    MessagingService.startFn = () async {};
    MessagingService.conversationsFn = () async => const [];
    MessagingService.threadFn = (_) async => const [];
    MessagingService.threadSinceFn = (_, _) async => delta(const []);
    MessagingService.commitFn = (_) async => const SendOutcomeDto(
      finalTxid: 'ab',
      submitted: 1,
      total: 1,
      partial: false,
    );
    MessagingService.abandonFn = () async {};
    MessagingService.hideFn = (_) async {};
    // V2b fill seams: default = no gap, fill off, no run (the fresh-install
    // §0 posture) — individual tests override.
    MessagingService.gapAgeFn = () async => null;
    MessagingService.fillConfigFn = () async => const FillConfigDto(
      enabled: false,
      endpoint: 'https://indexer.kasia.fyi',
      defaultEndpoint: 'https://indexer.kasia.fyi',
    );
    MessagingService.setFillConfigFn = (_, _) async {};
    MessagingService.fillNowFn = () async => FillReportDto(
      ran: true,
      complete: true,
      pages: 0,
      newRows: 0,
      atUnixMs: BigInt.zero,
    );
    MessagingService.fillStatusFn = () async => null;
    // D-138 backup seam: nothing to back up on a fresh install, so the notice
    // is silent by default — individual tests override.
    MessagingService.existingConversationFn = (_) async => null;
    MessagingService.stashStateFn = () async => StashStateDto(
      lastUnixMs: BigInt.zero,
      confirmedReadable: false,
      covered: 0,
      total: 0,
    );
    await MessagingService.instance.reset();
  });

  tearDown(() async {
    await MessagingService.instance.reset();
    // Not awaited: a single-subscription controller that never got a listener
    // (tests that don't call start) would never complete its close() future.
    unawaited(pings.close());
  });

  group('MessagingService', () {
    test('start pulls conversations and pings trigger a re-pull', () async {
      var pulls = 0;
      MessagingService.conversationsFn = () async {
        pulls++;
        return [conversation('c1')];
      };
      final service = MessagingService.instance;
      await service.start();
      expect(pulls, 1);
      expect(service.conversations.value, hasLength(1));

      pings.add('c1');
      await Future<void>.delayed(Duration.zero);
      expect(pulls, 2, reason: 'a ping re-pulls the list');
      expect(service.lastPing.value, 'c1');
    });

    test(
      'the empty sentinel ping refreshes notice inputs, never threads',
      () async {
        var conversationPulls = 0;
        var gapPulls = 0;
        MessagingService.conversationsFn = () async {
          conversationPulls++;
          return const [];
        };
        MessagingService.gapAgeFn = () async {
          gapPulls++;
          return null;
        };
        final service = MessagingService.instance;
        await service.start(); // one pull of each at start
        pings.add(''); // Rust: gap resolved / fill reported
        await Future<void>.delayed(Duration.zero);
        expect(gapPulls, 2, reason: 'the sentinel re-pulls the notice inputs');
        expect(conversationPulls, 1, reason: 'no conversation changed');
        expect(
          service.lastPing.value,
          isNull,
          reason: 'thread views never see the sentinel',
        );
      },
    );

    test('enabling the fill saves config then runs a fill at once', () async {
      final calls = <String>[];
      MessagingService.setFillConfigFn = (enabled, endpoint) async {
        calls.add('set:$enabled:$endpoint');
      };
      MessagingService.fillConfigFn = () async => const FillConfigDto(
        enabled: true,
        endpoint: 'https://indexer.kasia.fyi',
        defaultEndpoint: 'https://indexer.kasia.fyi',
      );
      MessagingService.fillNowFn = () async {
        calls.add('fill');
        return FillReportDto(
          ran: true,
          complete: true,
          pages: 2,
          newRows: 3,
          atUnixMs: BigInt.one,
        );
      };
      final service = MessagingService.instance;
      await service.setFillConfig(enabled: true, endpoint: '  ');
      expect(calls, [
        'set:true:  ',
        'fill',
      ], reason: 'the founder test: flip on → history arrives, no restart');
      expect(service.lastFill.value?.newRows, 3);

      // Turning OFF must not fire a network check.
      calls.clear();
      await service.setFillConfig(enabled: false, endpoint: 'x');
      expect(calls, ['set:false:x']);
    });

    test('historyNotice: every gap × fill-posture cell is honest', () {
      GapAgeDto gap(int? minutes, {bool horizon = false}) => GapAgeDto(
        gapMinutes: minutes == null ? null : BigInt.from(minutes),
        beyondHorizon: horizon,
      );
      const off = FillConfigDto(
        enabled: false,
        endpoint: 'e',
        defaultEndpoint: 'e',
      );
      const on = FillConfigDto(
        enabled: true,
        endpoint: 'e',
        defaultEndpoint: 'e',
      );
      FillReportDto report({bool complete = true, String? error}) =>
          FillReportDto(
            ran: true,
            complete: complete,
            pages: 1,
            newRows: 0,
            error: error,
            atUnixMs: BigInt.one,
          );

      // No gap signal / gap the node rewind already covers → quiet.
      expect(historyNotice(gap: null, config: off, report: null), isNull);
      expect(historyNotice(gap: gap(5), config: off, report: null), isNull);
      expect(historyNotice(gap: gap(20), config: off, report: null), isNull);

      // A real residual gap, fill OFF → the notice invites the fix.
      expect(
        historyNotice(gap: gap(235), config: off, report: null),
        contains('may be missing'),
      );
      // Beyond the pruning horizon → notice even with no minute figure.
      expect(
        historyNotice(gap: gap(null, horizon: true), config: off, report: null),
        contains('may be missing'),
      );

      // Fill ON: complete run heals; a failed or absent run never silences.
      expect(
        historyNotice(gap: gap(235), config: on, report: report()),
        isNull,
      );
      expect(
        historyNotice(
          gap: gap(235),
          config: on,
          report: report(complete: false, error: 'timed out'),
        ),
        contains('incomplete'),
      );
      expect(
        historyNotice(gap: gap(235), config: on, report: null),
        contains('missing'),
      );
    });

    test('backupNotice speaks ONLY when nothing is backed up at all', () {
      StashStateDto state(
        int covered,
        int total, {
        int last = 1,
        bool readable = true,
      }) => StashStateDto(
        lastUnixMs: BigInt.from(last),
        confirmedReadable: readable,
        covered: covered,
        total: total,
      );

      // Never measured yet — say nothing rather than claim a zero.
      expect(backupNotice(null, archiveEnabled: true), isNull);
      // Nothing to back up.
      expect(backupNotice(state(0, 0, last: 0), archiveEnabled: true), isNull);

      // THE one state worth interrupting for: conversations exist and no
      // backup does. Name the consequence, not the mechanism.
      final never = backupNotice(state(0, 2, last: 0), archiveEnabled: true);
      expect(never, contains('backed up'));
      expect(never, contains('money'));
      expect(never, contains('contacts'));

      // Founder ruling: everything else is a detail and belongs in the sheet.
      // A warning you cannot act on becomes wallpaper, and takes the one that
      // matters down with it.
      expect(backupNotice(state(3, 3), archiveEnabled: true), isNull);
      expect(
        backupNotice(state(1, 3), archiveEnabled: true),
        isNull,
        reason: 'partial coverage is a detail, not an interruption',
      );
      expect(
        backupNotice(state(3, 3, readable: false), archiveEnabled: true),
        isNull,
        reason: 'an unconfirmed read-back is visible one tap away',
      );
      expect(
        backupNotice(state(3, 3, readable: false), archiveEnabled: false),
        isNull,
      );
    });

    test('a history gap outranks the backup line — never two banners', () {
      // Both have something to say; the banner shows the gap, because messages
      // already missing beat messages that might be lost later.
      final gapText = historyNotice(
        gap: GapAgeDto(gapMinutes: BigInt.from(235), beyondHorizon: false),
        config: const FillConfigDto(
          enabled: false,
          endpoint: 'e',
          defaultEndpoint: 'e',
        ),
        report: null,
      );
      final backup = backupNotice(
        StashStateDto(
          lastUnixMs: BigInt.zero,
          confirmedReadable: false,
          covered: 0,
          total: 2,
        ),
        archiveEnabled: true,
      );
      expect(gapText, isNotNull);
      expect(backup, isNotNull);
      expect(gapText ?? backup, gapText, reason: 'the gap wins the one slot');
    });

    test('threads are pulled per call, never cached (§0.4)', () async {
      var pulls = 0;
      MessagingService.threadFn = (_) async {
        pulls++;
        return [message('tx1')];
      };
      final service = MessagingService.instance;
      await service.thread('c1');
      await service.thread('c1');
      expect(
        pulls,
        2,
        reason: 'every view pull decrypts fresh — nothing cached',
      );

      // The V2 incremental pull holds the same law: a pure forward, no cache.
      var deltas = 0;
      MessagingService.threadSinceFn = (_, _) async {
        deltas++;
        return delta([message('tx1')]);
      };
      await service.threadSince('c1', null);
      await service.threadSince('c1', 'tx1');
      expect(deltas, 2, reason: 'threadSince decrypts fresh per call too');
    });
  });

  group('file attachments', () {
    AttachmentDto file({
      String name = 'Algovelo.md',
      int size = 6847,
      String kind = 'text',
      String? text = '# Notes',
      bool broken = false,
      String viewMime = 'text/markdown',
    }) => AttachmentDto(
      name: name,
      sizeBytes: BigInt.from(size),
      kind: kind,
      text: text,
      broken: broken,
      viewMime: viewMime,
    );

    testWidgets('a file renders as a card, never as raw JSON', (tester) async {
      MessagingService.threadSinceFn = (_, _) async =>
          delta([message('tx1', text: '', attachment: file())]);
      await tester.pumpWidget(
        const MaterialApp(
          home: ThreadScreen(conversationId: 'c1', contactLabel: 'them'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Algovelo.md'), findsOneWidget);
      expect(find.text('6.7 KB'), findsOneWidget);
      expect(find.text('# Notes'), findsOneWidget);
      // The thing this whole lane exists to stop.
      expect(find.textContaining('"type":"file"'), findsNothing);
      expect(find.textContaining('base64'), findsNothing);
    });

    testWidgets('a file we will not interpret stays an inert card', (
      tester,
    ) async {
      MessagingService.threadSinceFn = (_, _) async => delta([
        message(
          'tx1',
          text: '',
          attachment: file(name: 'page.html', kind: 'other', text: null),
        ),
      ]);
      await tester.pumpWidget(
        const MaterialApp(
          home: ThreadScreen(conversationId: 'c1', contactLabel: 'them'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('page.html'), findsOneWidget);
      // No content is rendered for a type we refuse to interpret.
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('a broken file says so instead of dumping its body', (
      tester,
    ) async {
      MessagingService.threadSinceFn = (_, _) async => delta([
        message('tx1', text: '', attachment: file(broken: true, text: null)),
      ]);
      await tester.pumpWidget(
        const MaterialApp(
          home: ThreadScreen(conversationId: 'c1', contactLabel: 'them'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining("didn't decode"), findsOneWidget);
      // Nothing to save from a file that did not decode.
      expect(find.byIcon(Icons.download_outlined), findsNothing);
    });

    testWidgets('saving fetches the bytes only on demand', (tester) async {
      var fetches = 0;
      var wrote = '';
      MessagingService.attachmentBytesFn = (conversationId, txid) async {
        fetches++;
        return AttachmentBytesDto(
          name: 'Algovelo.md',
          bytes: Uint8List.fromList([1, 2, 3]),
        );
      };
      MessagingService.writeFileFn = (name, bytes) async {
        wrote = '$name:${bytes.length}';
        return 'content://downloads/1';
      };
      MessagingService.threadSinceFn = (_, _) async =>
          delta([message('tx1', text: '', attachment: file())]);
      await tester.pumpWidget(
        const MaterialApp(
          home: ThreadScreen(conversationId: 'c1', contactLabel: 'them'),
        ),
      );
      await tester.pumpAndSettle();

      // Drawing the card must not have pulled any bytes across the bridge.
      expect(fetches, 0, reason: 'bytes cross only when the user asks');

      await tester.tap(find.byIcon(Icons.download_outlined));
      await tester.pumpAndSettle();

      expect(fetches, 1);
      expect(wrote, 'Algovelo.md:3');
      expect(find.textContaining('Saved Algovelo.md'), findsOneWidget);
    });

    testWidgets('Open appears only after a save, with OUR media type', (
      tester,
    ) async {
      var opened = '';
      MessagingService.attachmentBytesFn = (_, _) async => AttachmentBytesDto(
        name: 'photo.jpg',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      MessagingService.writeFileFn = (_, _) async => 'content://downloads/9';
      MessagingService.openFileFn = (uri, mime) async {
        opened = '$uri|$mime';
        return true;
      };
      MessagingService.threadSinceFn = (_, _) async => delta([
        message(
          'tx1',
          text: '',
          attachment: file(
            name: 'photo.jpg',
            kind: 'other',
            text: null,
            viewMime: 'image/jpeg',
          ),
        ),
      ]);
      await tester.pumpWidget(
        const MaterialApp(
          home: ThreadScreen(conversationId: 'c1', contactLabel: 'them'),
        ),
      );
      await tester.pumpAndSettle();

      // Nothing to open before it has been saved — opening points at the
      // user's own file, so there is no copy to point at yet.
      expect(find.byIcon(Icons.open_in_new), findsNothing);

      await tester.tap(find.byIcon(Icons.download_outlined));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.open_in_new), findsOneWidget);

      await tester.tap(find.byIcon(Icons.open_in_new));
      await tester.pumpAndSettle();
      // The destination the user chose, and the type WE derived.
      expect(opened, 'content://downloads/9|image/jpeg');
    });

    testWidgets('a phone with nothing for the type says so plainly', (
      tester,
    ) async {
      MessagingService.attachmentBytesFn = (_, _) async =>
          AttachmentBytesDto(name: 'x.xyz', bytes: Uint8List.fromList([1]));
      MessagingService.writeFileFn = (_, _) async => 'content://downloads/9';
      MessagingService.openFileFn = (_, _) async => false;
      MessagingService.threadSinceFn = (_, _) async => delta([
        message(
          'tx1',
          text: '',
          attachment: file(kind: 'other', text: null),
        ),
      ]);
      await tester.pumpWidget(
        const MaterialApp(
          home: ThreadScreen(conversationId: 'c1', contactLabel: 'them'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.download_outlined));
      await tester.pumpAndSettle();
      // Let the "Saved" snackbar expire — only one shows at a time, so the
      // next would otherwise sit queued behind it.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.open_in_new));
      await tester.pumpAndSettle();

      expect(find.textContaining('No app on this phone'), findsOneWidget);
    });

    testWidgets('backing out of the picker says nothing at all', (
      tester,
    ) async {
      MessagingService.attachmentBytesFn = (_, _) async => AttachmentBytesDto(
        name: 'Algovelo.md',
        bytes: Uint8List.fromList([1]),
      );
      // null = the user cancelled.
      MessagingService.writeFileFn = (_, _) async => null;
      MessagingService.threadSinceFn = (_, _) async =>
          delta([message('tx1', text: '', attachment: file())]);
      await tester.pumpWidget(
        const MaterialApp(
          home: ThreadScreen(conversationId: 'c1', contactLabel: 'them'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.download_outlined));
      await tester.pumpAndSettle();

      // A cancel is a decision, not an error — no snackbar of any kind.
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('ContactsScreen', () {
    testWidgets('empty state invites a contact add', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pump();
      expect(find.textContaining('No conversations yet'), findsOneWidget);
      expect(find.byIcon(Icons.person_add_alt), findsOneWidget);
    });

    testWidgets('a residual gap raises the banner; tap opens the sheet with '
        'the toggle and the plain disclosure (D-074: never silence)', (
      tester,
    ) async {
      // Stub the SOURCES (the screen re-pulls on entry — the never-dark law),
      // then let the screen's own initState pull them.
      MessagingService.gapAgeFn = () async =>
          GapAgeDto(gapMinutes: BigInt.from(235), beyondHorizon: false);
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pumpAndSettle();

      expect(find.textContaining('may be missing'), findsOneWidget);

      await tester.tap(find.textContaining('may be missing'));
      await tester.pumpAndSettle();
      // The sheet: title, toggle, and the disclosure's two load-bearing
      // claims — what the operator LEARNS and what they can NEVER do.
      expect(find.text('History & backup'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsOneWidget);
      expect(find.textContaining('operator learns'), findsOneWidget);
      expect(find.textContaining('never'), findsWidgets);

      // Flip it on: config saves, a fill runs, the sheet reports counts.
      MessagingService.fillConfigFn = () async => const FillConfigDto(
        enabled: true,
        endpoint: 'https://indexer.kasia.fyi',
        defaultEndpoint: 'https://indexer.kasia.fyi',
      );
      MessagingService.fillNowFn = () async => FillReportDto(
        ran: true,
        complete: true,
        pages: 1,
        newRows: 2,
        atUnixMs: BigInt.one,
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 recovered messages'), findsOneWidget);
      // The endpoint surface appears with the enabled state (configurable —
      // D-070 clause 3: the hosted default is replaceable, not a dependency).
      expect(find.textContaining('indexer.kasia.fyi'), findsOneWidget);

      // The complete fill heals the banner (notice logic; live via merge).
      await tester.tap(find.text('Messages')); // dismiss the sheet
      await tester.pumpAndSettle();
      expect(find.textContaining('may be missing'), findsNothing);
    });

    testWidgets('the history sheet is reachable with NO gap (visible toggle)', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pumpAndSettle();
      expect(find.textContaining('may be missing'), findsNothing);
      await tester.tap(find.byIcon(Icons.history));
      await tester.pumpAndSettle();
      expect(find.text('History & backup'), findsOneWidget);
    });

    testWidgets('adding a contact you already have OPENS the thread', (
      tester,
    ) async {
      const addr =
          'kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf';
      var handshakes = 0;
      var asked = '';
      MessagingService.existingConversationFn = (address) async {
        asked = address;
        return const ContactRouteDto(conversationId: 'c1', acceptFirst: false);
      };
      MessagingService.prepareHandshakeFn = (_) async {
        handshakes++;
        return summary();
      };
      MessagingService.conversationsFn = () async => [conversation('c1')];
      await MessagingService.instance.refresh();
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, addr);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Review request'));
      await tester.pumpAndSettle();

      expect(asked, addr, reason: 'Rust is asked before a bond is quoted');
      expect(
        handshakes,
        0,
        reason: 'an existing contact must never mint a second invitation',
      );
      // The thread opened instead of a snackbar telling the user to find it.
      expect(find.byType(ThreadScreen), findsOneWidget);
    });

    testWidgets('adding someone who already invited YOU accepts theirs', (
      tester,
    ) async {
      const addr =
          'kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf';
      var handshakes = 0;
      var accepts = 0;
      MessagingService.existingConversationFn = (_) async =>
          const ContactRouteDto(conversationId: 'c1', acceptFirst: true);
      MessagingService.prepareHandshakeFn = (_) async {
        handshakes++;
        return summary();
      };
      MessagingService.prepareAcceptFn = (_) async {
        accepts++;
        return summary();
      };
      MessagingService.conversationsFn = () async => [
        conversation('c1', status: 'pending_in'),
      ];
      await MessagingService.instance.refresh();
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, addr);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Review request'));
      await tester.pumpAndSettle();

      expect(accepts, 1, reason: 'their bond is refunded, not a second spent');
      expect(handshakes, 0, reason: 'never a second invitation beside theirs');
      expect(find.text('Confirm accept'), findsOneWidget);
    });

    testWidgets('adding a NEW contact still runs the invitation ceremony', (
      tester,
    ) async {
      const addr =
          'kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf';
      var handshakes = 0;
      MessagingService.existingConversationFn = (_) async => null;
      MessagingService.prepareHandshakeFn = (_) async {
        handshakes++;
        return summary();
      };
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, addr);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Review request'));
      await tester.pumpAndSettle();

      expect(handshakes, 1);
      expect(find.byType(ThreadScreen), findsNothing);
    });

    testWidgets('a failed lookup never blocks adding a contact', (
      tester,
    ) async {
      const addr =
          'kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf';
      var handshakes = 0;
      MessagingService.existingConversationFn = (_) async =>
          throw const AppError(message: 'hub restarting');
      MessagingService.prepareHandshakeFn = (_) async {
        handshakes++;
        return summary();
      };
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, addr);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Review request'));
      await tester.pumpAndSettle();

      expect(
        handshakes,
        1,
        reason: 'the convenience lookup is a hint; Rust holds the real guard',
      );
    });

    testWidgets('a named contact shows its name, not its address', (
      tester,
    ) async {
      MessagingService.conversationsFn = () async => [
        conversation('c1', contactName: 'Alice'),
      ];
      await MessagingService.instance.refresh();
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Alice'), findsOneWidget);
      // The address is replaced in the label, not shown beside it.
      expect(find.textContaining('kaspa:'), findsNothing);
    });

    testWidgets('naming a contact writes through Rust and re-pulls', (
      tester,
    ) async {
      var written = '';
      MessagingService.setContactNameFn = (address, name) async {
        written = '$address=$name';
        return name.isEmpty ? null : name;
      };
      MessagingService.conversationsFn = () async => [conversation('c1')];
      await MessagingService.instance.refresh();
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Active'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Name this contact'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Alice');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(written, endsWith('=Alice'));
      expect(written, startsWith('kaspa:'));
    });

    testWidgets('an invitation has no address, so it cannot be named yet', (
      tester,
    ) async {
      MessagingService.conversationsFn = () async => [
        conversation('c1', status: 'pending_in'),
      ];
      await MessagingService.instance.refresh();
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pumpAndSettle();
      await openRequests(tester);

      await tester.longPress(find.text('Wants to connect'));
      await tester.pumpAndSettle();
      // Hiding is still offered; naming is not, because a name keys on the
      // address and this row has none until its sender is recorded.
      expect(find.text('Hide conversation'), findsOneWidget);
      expect(find.text('Name this contact'), findsNothing);
    });

    testWidgets('Chats holds conversations; Requests holds what wants a bond', (
      tester,
    ) async {
      MessagingService.conversationsFn = () async => [
        conversation('c1'),
        conversation('c2', status: 'pending_in'),
        conversation('c3', status: 'pending_out'),
      ];
      await MessagingService.instance.refresh();
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pumpAndSettle();

      // Chats: the two you can open. No Accept button — a card that spends
      // 0.2 KAS must never sit between two of your conversations.
      expect(find.text('Accept'), findsNothing);
      expect(find.text('Wants to connect'), findsNothing);
      // The count is on the tab, so an invitation is visible without
      // letting a stranger push your real threads down the screen.
      expect(find.text('1'), findsOneWidget);

      await openRequests(tester);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Wants to connect'), findsOneWidget);
    });

    testWidgets('both tabs render at zero, each saying its own thing', (
      tester,
    ) async {
      MessagingService.conversationsFn = () async => const [];
      await MessagingService.instance.refresh();
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pumpAndSettle();

      expect(find.textContaining('No conversations yet'), findsOneWidget);
      // No count badge when nobody is waiting.
      expect(find.text('0'), findsNothing);

      await openRequests(tester);
      expect(find.textContaining('No one is waiting on you'), findsOneWidget);
    });

    testWidgets('an inbound-pending row is an accept card, not a thread', (
      tester,
    ) async {
      MessagingService.conversationsFn = () async => [
        conversation('c1', status: 'pending_in'),
      ];
      await MessagingService.instance.refresh();
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pumpAndSettle();
      await openRequests(tester);

      expect(find.text('Wants to connect'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.textContaining('0.2 KAS bond'), findsOneWidget);
      // No address is claimed before the node resolves the sender.
      expect(find.text('Unknown sender'), findsOneWidget);
    });

    testWidgets(
      'an expired invite shows the terminal copy and Dismiss, never Accept',
      (tester) async {
        // Rust's taxonomy (V5, finding 15): past the pruning horizon the
        // accept can never resolve — no transient promise, and an exit.
        MessagingService.conversationsFn = () async => [
          conversation('c1', status: 'pending_in', inviteExpired: true),
        ];
        String? hidden;
        MessagingService.hideFn = (id) async => hidden = id;
        await MessagingService.instance.refresh();
        await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
        await tester.pumpAndSettle();
        await openRequests(tester);

        expect(find.text('Invitation expired'), findsOneWidget);
        expect(
          find.text(
            'This invitation has expired and can no longer be accepted.',
          ),
          findsOneWidget,
        );
        expect(find.text('Dismiss'), findsOneWidget);
        // The dead affordances are GONE, not disabled: no Accept, no
        // transient bond copy, no accept ceremony reachable.
        expect(find.text('Accept'), findsNothing);
        expect(find.textContaining('0.2 KAS bond'), findsNothing);

        // One tap dismisses (founder-ruled: the copy already explains) —
        // through the same reversible tombstone lane as hide.
        await tester.tap(find.text('Dismiss'));
        await tester.pumpAndSettle();
        expect(hidden, 'c1');
        expect(find.text('Invitation dismissed.'), findsOneWidget);
      },
    );

    testWidgets('a fresh inbound invite keeps the accept card', (tester) async {
      // The within-horizon half of the taxonomy: today's card unchanged.
      MessagingService.conversationsFn = () async => [
        conversation('c1', status: 'pending_in'),
      ];
      await MessagingService.instance.refresh();
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pumpAndSettle();
      await openRequests(tester);

      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Wants to connect'), findsOneWidget);
      expect(find.text('Dismiss'), findsNothing);
      expect(find.text('Invitation expired'), findsNothing);
    });

    testWidgets('accept runs prepare and opens the confirm ceremony', (
      tester,
    ) async {
      MessagingService.conversationsFn = () async => [
        conversation('c1', status: 'pending_in'),
      ];
      var prepared = '';
      MessagingService.prepareAcceptFn = (id) async {
        prepared = id;
        return summary();
      };
      await MessagingService.instance.refresh();
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pumpAndSettle();
      await openRequests(tester);

      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();

      expect(prepared, 'c1');
      // The B7 ceremony renders Rust's numbers: the refund is the headline.
      expect(find.text('Confirm accept'), findsOneWidget);
      expect(
        find.textContaining('Hold to send 0.20000000 KAS'),
        findsOneWidget,
      );
    });

    testWidgets('active rows open the thread', (tester) async {
      MessagingService.conversationsFn = () async => [conversation('c1')];
      await MessagingService.instance.refresh();
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Active'));
      await tester.pumpAndSettle();
      expect(find.byType(ThreadScreen), findsOneWidget);
    });

    testWidgets('long-press → confirm hides a conversation (D-068)', (
      tester,
    ) async {
      String? hidden;
      MessagingService.hideFn = (id) async => hidden = id;
      MessagingService.conversationsFn = () async => [conversation('c1')];
      await MessagingService.instance.refresh();
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Active'));
      await tester.pumpAndSettle();
      // Long-press now offers naming as well as hiding.
      await tester.tap(find.text('Hide conversation'));
      await tester.pumpAndSettle();
      // The confirm sheet is honest about being local-only — and, since the
      // row is now tombstoned rather than deleted, honest that hiding does
      // NOT stop the other side writing to you. The copy used to promise that
      // a new request would start a fresh conversation, which is impossible
      // against a counterparty whose client answers a known contact
      // idempotently and sends nothing.
      expect(find.text('Hide conversation'), findsOneWidget);
      expect(find.textContaining('from your device'), findsOneWidget);
      expect(
        find.textContaining('they can still write to you'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Hide'));
      await tester.pumpAndSettle();
      expect(hidden, 'c1', reason: 'the bridge hide ran for this conversation');
    });

    testWidgets('cancelling the hide sheet leaves the conversation', (
      tester,
    ) async {
      var hideCalls = 0;
      MessagingService.hideFn = (_) async => hideCalls++;
      MessagingService.conversationsFn = () async => [conversation('c1')];
      await MessagingService.instance.refresh();
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Active'));
      await tester.pumpAndSettle();
      // Long-press now offers naming as well as hiding.
      await tester.tap(find.text('Hide conversation'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(hideCalls, 0);
    });
  });

  group('ThreadScreen', () {
    Widget screen() => const MaterialApp(
      home: ThreadScreen(
        conversationId: 'c1',
        contactLabel: 'kaspa:qz7u…j43pf',
      ),
    );

    /// A thread with no dates and no clock is a wall of text you cannot place
    /// in time — `unixMs` rode the DTO all along and the screen threw it away.
    testWidgets('days are separated and a run carries ONE time', (
      tester,
    ) async {
      final now = DateTime.now();
      BigInt at(DateTime t) => BigInt.from(t.millisecondsSinceEpoch);
      // Three inbound messages inside a minute (one run), then a reply, then a
      // message from the day before — which must open its own day.
      final today = DateTime(now.year, now.month, now.day, 10);
      final yesterday = today.subtract(const Duration(days: 1));
      MessagingService.threadSinceFn = (_, _) async => delta([
        message('tx0', text: 'day before', unixMs: at(yesterday)),
        message('tx1', text: 'one', unixMs: at(today)),
        message(
          'tx2',
          text: 'two',
          unixMs: at(today.add(const Duration(seconds: 30))),
        ),
        message(
          'tx3',
          text: 'three',
          unixMs: at(today.add(const Duration(minutes: 1))),
        ),
        message(
          'tx4',
          outbound: true,
          text: 'reply',
          unixMs: at(today.add(const Duration(minutes: 2))),
        ),
      ]);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);

      // The inbound run closes at 'three', so exactly one clock face for it —
      // plus one for the reply, which is its own run. Four messages today, two
      // times: stamping every line makes a fast exchange unreadable.
      final clock = RegExp(r'^\d{1,2}:\d{2}(\s?[AaPp][Mm])?$');
      final times = tester
          .widgetList<Text>(find.byType(Text))
          .where((t) => t.data != null && clock.hasMatch(t.data!))
          .length;
      expect(times, 3, reason: 'one per run: yesterday, the trio, the reply');
    });

    testWidgets('renders decrypted rows and system handshake rows', (
      tester,
    ) async {
      MessagingService.threadSinceFn = (_, _) async => delta([
        message('tx0', kind: 'handshake'),
        message('tx1', text: 'gm — first L1 DM'),
        message('tx2', outbound: true, text: 'gm right back'),
        message('tx3', readable: false, text: ''),
      ]);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      expect(find.text('Handshake received'), findsOneWidget);
      expect(find.text('gm — first L1 DM'), findsOneWidget);
      expect(find.text('gm right back'), findsOneWidget);
      // An unopenable envelope is shown honestly, never hidden.
      expect(find.text('Unreadable message'), findsOneWidget);
    });

    // F3. The store has recorded provenance since V5, but it never crossed the
    // FFI — so a row an indexer supplied rendered pixel-identically to one our
    // own node saw, under a disclosure promising the archive "can never fake a
    // message". It can: the app hands it the address messages are sealed to.
    testWidgets('an archive-supplied row says so; a node row stays clean', (
      tester,
    ) async {
      MessagingService.threadSinceFn = (_, _) async => delta([
        message('tx1', text: 'from your own node'),
        message(
          'tx2',
          text: 'handed over by an archive',
          provenance: 'archive',
        ),
      ]);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      expect(find.text('from your own node'), findsOneWidget);
      expect(find.text('handed over by an archive'), findsOneWidget);
      // The mark is a BOUNDARY, not a per-row tag: one line where our own
      // node's view takes over, however many restored rows sit above it. A
      // restored thread used to stamp every single bubble.
      //
      // "Some", not "everything": a node-scanned row sits ABOVE this archive
      // row, and the marker must not claim that one was restored too.
      expect(
        find.text('Some messages above were restored from an archive'),
        findsOneWidget,
        reason: 'the boundary is marked once, never per row',
      );
    });

    /// The founder's complaint, pinned: a restored thread stamped every
    /// bubble. Many archive rows must produce exactly ONE marker, sitting at
    /// the last of them — the point where the node's own view begins.
    testWidgets('a restored history is marked once, not once per message', (
      tester,
    ) async {
      MessagingService.threadSinceFn = (_, _) async => delta([
        message('a1', text: 'old one', provenance: 'archive'),
        message('a2', text: 'old two', provenance: 'archive'),
        message('a3', text: 'old three', provenance: 'archive'),
        message('n1', text: 'seen by our node'),
      ]);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      expect(find.text('old one'), findsOneWidget);
      expect(find.text('seen by our node'), findsOneWidget);
      expect(
        find.text('Everything above was restored from an archive'),
        findsOneWidget,
        reason: 'three restored rows, one boundary — not three badges',
      );
    });

    /// The fill runs at every open and lands rows in BLOCK-TIME order, so
    /// archive rows interleave with the user's own sent messages. A mid-thread
    /// run must not claim those were restored — the marker has to say "some",
    /// not "everything".
    testWidgets('a mid-thread restored run does not claim your own messages', (
      tester,
    ) async {
      MessagingService.threadSinceFn = (_, _) async => delta([
        message('a1', text: 'restored one', provenance: 'archive'),
        message('o1', text: 'mine', outbound: true, provenance: 'own'),
        message('a2', text: 'restored two', provenance: 'archive'),
        message('n1', text: 'from our node'),
      ]);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      expect(
        find.text('Everything above was restored from an archive'),
        findsOneWidget,
        reason: 'the LEADING run may say everything above',
      );
      expect(
        find.text('Some messages above were restored from an archive'),
        findsOneWidget,
        reason: 'the run above our own message may not',
      );
    });

    // The row class that matters MOST. The fill sweeps handshakes-by-receiver
    // and folds each hit as a FillSourced row, and a handshake row CREATES a
    // conversation — so an archive can manufacture a whole fake contact, not
    // merely append to an existing thread. The first cut of this fix rendered
    // the badge on comm rows only, which left exactly that unmarked while the
    // fill disclosure claimed everything archive-supplied was labelled.
    testWidgets('an archive-supplied HANDSHAKE row is marked too', (
      tester,
    ) async {
      MessagingService.threadSinceFn = (_, _) async =>
          delta([message('tx0', kind: 'handshake', provenance: 'archive')]);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      expect(find.text('Handshake received'), findsOneWidget);
      expect(
        find.text('Everything above was restored from an archive'),
        findsOneWidget,
      );
    });

    // Pre-V5 rows predate provenance entirely. Marking them "archive" would say
    // something false about rows that were almost certainly node-scanned.
    testWidgets(
      'a pre-provenance row is not accused of being archive-sourced',
      (tester) async {
        MessagingService.threadSinceFn = (_, _) async => delta([
          message('tx1', text: 'written before V5', provenance: 'unknown'),
        ]);
        await tester.pumpWidget(screen());
        await tester.pumpAndSettle();

        expect(find.text('written before V5'), findsOneWidget);
        expect(
          find.text('From an archive — not seen by your own node'),
          findsNothing,
        );
      },
    );

    testWidgets('a locked vault shows the locked state, not content', (
      tester,
    ) async {
      MessagingService.threadSinceFn = (_, _) async =>
          throw StateError('wallet is locked — unlock to read messages');
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.textContaining('unlock to read'), findsOneWidget);
      expect(find.textContaining('gm'), findsNothing);
    });

    testWidgets('compose runs prepare and the confirm ceremony', (
      tester,
    ) async {
      String? sentText;
      MessagingService.prepareCommFn = (id, text) async {
        sentText = text;
        return summary(
          amount: BigInt.from(12000000),
          kind: SignableKind.selfSendFrame,
          payloadKind: 'comm',
        );
      };
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'challenge you to RPS');
      await tester.tap(find.byIcon(Icons.send_outlined));
      await tester.pumpAndSettle();

      expect(sentText, 'challenge you to RPS');
      expect(find.text('Confirm message'), findsOneWidget);
      // A message is a self-send (D-069): the hold button never quotes the
      // returning value as if it were spent, the headline is the fee, and the
      // value is shown as returning to you — not a cost.
      expect(find.text('Hold to send message'), findsOneWidget);
      expect(find.textContaining('Hold to send 0.12000000'), findsNothing);
      expect(find.text('Costs you'), findsOneWidget);
      expect(find.text('Returns to you'), findsOneWidget);
    });

    testWidgets('a ping for another conversation does not re-pull', (
      tester,
    ) async {
      var pulls = 0;
      MessagingService.threadSinceFn = (_, _) async {
        pulls++;
        return delta(const []);
      };
      // Attach the service's ping pipeline.
      await MessagingService.instance.start();
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      final before = pulls;

      pings.add('OTHER');
      await tester.pump();
      expect(pulls, before, reason: 'foreign pings are ignored');

      pings.add('c1');
      await tester.pump();
      expect(pulls, before + 1, reason: 'own ping re-pulls');
    });

    testWidgets('two pings for the same conversation re-pull twice', (
      tester,
    ) async {
      var pulls = 0;
      MessagingService.threadSinceFn = (_, _) async {
        pulls++;
        return delta(const []);
      };
      await MessagingService.instance.start();
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      final before = pulls;

      pings.add('c1');
      await tester.pump();
      pings.add('c1');
      await tester.pump();
      expect(
        pulls,
        before + 2,
        reason:
            'a second message in the SAME conversation must still refresh '
            'the open thread (ValueNotifier equality trap — sitting find)',
      );
    });
  });

  group('ThreadScreen — V2 chips, ghost & incremental merge', () {
    Widget screen() => const MaterialApp(
      home: ThreadScreen(
        conversationId: 'c1',
        contactLabel: 'kaspa:qz7u…j43pf',
      ),
    );

    // NOTE: a live pending chip breathes on a repeating controller
    // (KvBreath), so these tests pump fixed durations instead of
    // pumpAndSettle (which would never settle) — the controller dies with
    // the screen (dispose).
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets(
      'outbound rows wear the tracker-driven chip; terminal rows stay quiet',
      (tester) async {
        MessagingService.threadSinceFn = (_, _) async => delta(
          [
            message('t1', outbound: true, text: 'one'),
            message('t2', outbound: true, text: 'two'),
            message('t3', outbound: true, text: 'three'),
            message('t4', outbound: true, text: 'four'),
            message('t5', text: 'inbound never wears a chip'),
          ],
          acceptance: {
            't1': status(TxStatusKind.submitted),
            't2': status(TxStatusKind.accepted),
            't3': status(TxStatusKind.stalled),
            't4': status(TxStatusKind.confirmed),
            't5': status(TxStatusKind.submitted),
          },
        );
        await tester.pumpWidget(screen());
        await settle(tester);

        expect(find.text('Pending'), findsOneWidget);
        expect(find.text('Accepted'), findsOneWidget);
        expect(find.text('Not accepted yet'), findsOneWidget);
        // Confirmed dissolves to quiet (founder-nodded); the inbound row is
        // chipless even while its watch reads submitted.
        expect(find.text('Confirmed'), findsNothing);
      },
    );

    testWidgets('thread chips stay numberless — the counter is an Activity '
        'affordance (founder call)', (tester) async {
      MessagingService.threadSinceFn = (_, _) async => delta(
        [message('t1', outbound: true, text: 'counting')],
        acceptance: {'t1': status(TxStatusKind.accepted, depth: 37)},
      );
      await tester.pumpWidget(screen());
      await settle(tester);
      expect(find.text('Accepted'), findsOneWidget);
      expect(find.textContaining('confirmations'), findsNothing);
    });

    testWidgets('a displaced send honestly reads Pending again', (
      tester,
    ) async {
      MessagingService.threadSinceFn = (_, _) async => delta(
        [message('t1', outbound: true, text: 'reorged')],
        acceptance: {'t1': status(TxStatusKind.displaced)},
      );
      await tester.pumpWidget(screen());
      await settle(tester);
      expect(find.text('Pending'), findsOneWidget);
    });

    testWidgets('a tombstoned row dims to the ghost with the honest line', (
      tester,
    ) async {
      MessagingService.threadSinceFn = (_, _) async => delta([
        message('t1', text: 'ghosted', tombstoned: true),
        message('t2', text: 'alive'),
      ]);
      await tester.pumpWidget(screen());
      await settle(tester);

      expect(find.text('Displaced by the network'), findsOneWidget);
      // Exactly one row wears the DS-1 stale dim (the ghost).
      final dimmed = tester
          .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
          .where((w) => w.opacity == 0.45);
      expect(dimmed.length, 1);
      // The content still renders — a ghost is dimmed truth, never hidden.
      expect(find.text('ghosted'), findsOneWidget);
    });

    testWidgets('a full re-pull after a degraded cursor never duplicates', (
      tester,
    ) async {
      MessagingService.threadSinceFn = (_, _) async =>
          delta([message('t1', text: 'only once')]);
      await MessagingService.instance.start();
      await tester.pumpWidget(screen());
      await settle(tester);

      pings.add('c1');
      await settle(tester);
      expect(
        find.text('only once'),
        findsOneWidget,
        reason:
            'rows are txid-keyed — a full-thread answer merges, '
            'never duplicates',
      );
    });

    testWidgets(
      'a row stranded behind the cursor heals via the statuses contract',
      (tester) async {
        // Consensus-audit V2 finding 1: an inbound handshake with a
        // sender-claimed old timestamp sorts BEHIND the cursor — the
        // incremental answer omits it from messages but its txid rides
        // statuses; the screen must full-re-pull once and render it.
        MessagingService.threadSinceFn = (_, after) async {
          if (after == null) {
            // Full pulls see everything, including the stranded row.
            return delta([
              message('t0', kind: 'handshake'),
              message('t1', text: 'anchor'),
            ]);
          }
          // Incremental answer: no new messages, but statuses reveal a
          // txid the view has never rendered.
          return ThreadDeltaDto(
            messages: const [],
            statuses: [
              MessageStatusDto(txid: 't0', tombstoned: false),
              MessageStatusDto(txid: 't1', tombstoned: false),
            ],
          );
        };
        await MessagingService.instance.start();
        await tester.pumpWidget(screen());
        await settle(tester);
        // First pull was already full (cursor null) — both rows render.
        expect(find.text('anchor'), findsOneWidget);

        // Simulate the stranded case: drop the handshake from the view by
        // starting a FRESH screen whose first (full) answer lacks t0, then
        // ping with the stranding incremental answer.
        var full = 0;
        MessagingService.threadSinceFn = (_, after) async {
          if (after == null) {
            full++;
            return delta([
              if (full > 1) message('t0', kind: 'handshake'),
              message('t1', text: 'anchor'),
            ]);
          }
          return ThreadDeltaDto(
            messages: const [],
            statuses: [
              MessageStatusDto(txid: 't0', tombstoned: false),
              MessageStatusDto(txid: 't1', tombstoned: false),
            ],
          );
        };
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(screen());
        await settle(tester);
        expect(find.text('Handshake received'), findsNothing);

        pings.add('c1');
        await settle(tester);
        expect(
          find.text('Handshake received'),
          findsOneWidget,
          reason:
              'an unknown statuses txid triggers ONE full re-pull that '
              'materializes the stranded row',
        );
        expect(find.text('anchor'), findsOneWidget); // still exactly one
      },
    );

    testWidgets('incremental pulls anchor on the last rendered txid', (
      tester,
    ) async {
      final cursors = <String?>[];
      MessagingService.threadSinceFn = (_, after) async {
        cursors.add(after);
        return delta([
          if (after == null) message('t1', text: 'first'),
          if (after == 't1') message('t2', text: 'second'),
        ]);
      };
      await MessagingService.instance.start();
      await tester.pumpWidget(screen());
      await settle(tester);
      expect(cursors, [null], reason: 'first pull takes the full thread');

      pings.add('c1');
      await settle(tester);
      expect(cursors, [null, 't1'], reason: 'later pulls decrypt the tail');
      expect(find.text('first'), findsOneWidget);
      expect(find.text('second'), findsOneWidget);
    });
  });

  group('ThreadScreen — kv:1: game frames (the safety spine)', () {
    Widget screen() => const MaterialApp(
      home: ThreadScreen(
        conversationId: 'c1',
        contactLabel: 'kaspa:qz7u…j43pf',
      ),
    );

    ThreadMessageDto challengeRow({
      bool outbound = false,
      String stake = '10',
    }) => message(
      'txc',
      outbound: outbound,
      text: '⚔️ Attack & Defend challenge — a duel.',
      frame: frameDto(
        kind: 'challenge',
        game: 'attack_defend',
        stake: stake,
        id: 'a1b2c3d4',
      ),
    );

    testWidgets('a challenge renders a card from its FIELDS, with actions', (
      tester,
    ) async {
      MessagingService.threadSinceFn = (_, _) async => delta([challengeRow()]);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      // The card is built from the JSON fields (game/stake), not the line.
      expect(find.text('Attack & Defend'), findsOneWidget);
      expect(find.textContaining('10 KAS'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Accept'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Decline'), findsOneWidget);
    });

    testWidgets('a friendly (no-stake) challenge reads "Friendly"', (
      tester,
    ) async {
      MessagingService.threadSinceFn = (_, _) async =>
          delta([challengeRow(stake: '')]);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(find.textContaining('Friendly'), findsOneWidget);
    });

    // Law (b): Accept opens the confirm ceremony and NEVER auto-broadcasts.
    testWidgets('Accept prepares + opens the ceremony, never auto-spends', (
      tester,
    ) async {
      var accepted = '';
      var commits = 0;
      MessagingService.prepareChallengeAcceptFn = (id, refId) async {
        accepted = '$id/$refId';
        return summary(kind: SignableKind.selfSendFrame, payloadKind: 'comm');
      };
      MessagingService.commitFn = (_) async {
        commits++;
        return const SendOutcomeDto(
          finalTxid: 'ab',
          submitted: 1,
          total: 1,
          partial: false,
        );
      };
      MessagingService.threadSinceFn = (_, _) async => delta([challengeRow()]);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
      await tester.pumpAndSettle();

      expect(accepted, 'c1/a1b2c3d4', reason: 'accept references the id');
      expect(find.text('Confirm accept'), findsOneWidget);
      // The only broadcast path is a completed hold-to-sign; a tap must not.
      expect(commits, 0, reason: 'Accept never auto-broadcasts (§0.5 law a)');
    });

    // Law (a): a forged result frame changes only pixels — inert, no action,
    // no spend, and framed as an unverified claim.
    testWidgets(
      'a forged result frame is an inert claim — no action, no spend',
      (tester) async {
        var commits = 0;
        MessagingService.commitFn = (_) async {
          commits++;
          return const SendOutcomeDto(
            finalTxid: 'ab',
            submitted: 1,
            total: 1,
            partial: false,
          );
        };
        MessagingService.threadSinceFn = (_, _) async => delta([
          message(
            'txr',
            text: '🏁 I won',
            frame: frameDto(kind: 'result', id: 'a1b2c3d4', detail: 'win'),
          ),
        ]);
        await tester.pumpWidget(screen());
        await tester.pumpAndSettle();

        expect(find.textContaining('Reported result'), findsOneWidget);
        expect(find.text('🏁 I won'), findsOneWidget);
        // Inert: no tappable action wired to a result, and nothing broadcast.
        expect(find.widgetWithText(FilledButton, 'Accept'), findsNothing);
        expect(commits, 0, reason: 'a frame binds no value (§0.3)');
      },
    );

    testWidgets('Decline retires the actions locally, sending nothing', (
      tester,
    ) async {
      var accepts = 0;
      MessagingService.prepareChallengeAcceptFn = (_, _) async {
        accepts++;
        return summary();
      };
      MessagingService.threadSinceFn = (_, _) async => delta([challengeRow()]);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Decline'));
      await tester.pumpAndSettle();

      expect(find.text('Declined'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Accept'), findsNothing);
      expect(accepts, 0, reason: 'Decline sends no frame (no decline kind)');
    });

    testWidgets('an outbound challenge shows sent, not Accept', (tester) async {
      MessagingService.threadSinceFn = (_, _) async =>
          delta([challengeRow(outbound: true)]);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(find.text('Challenge sent'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Accept'), findsNothing);
    });

    testWidgets('composing a challenge runs prepare + the confirm ceremony', (
      tester,
    ) async {
      String? convId;
      String? stake;
      MessagingService.prepareChallengeFn = (id, s) async {
        convId = id;
        stake = s;
        return summary(kind: SignableKind.selfSendFrame, payloadKind: 'comm');
      };
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.sports_esports_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Attack & Defend'), findsOneWidget);

      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == 'e.g. 10',
        ),
        '5',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Review challenge'));
      await tester.pumpAndSettle();

      expect(convId, 'c1');
      expect(stake, '5', reason: 'the display stake flows to the frame');
      expect(find.text('Confirm challenge'), findsOneWidget);
    });
  });

  group('displayError', () {
    test('unwraps AppError to its honest message', () {
      expect(
        displayError(const AppError(message: 'wallet is locked')),
        'wallet is locked',
      );
    });

    test('falls back to toString for foreign errors', () {
      expect(displayError(StateError('boom')), 'Bad state: boom');
    });
  });
}
