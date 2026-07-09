import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/rust/api/send.dart';
import 'package:kaspaverse/src/rust/api/transport.dart';
import 'package:kaspaverse/src/services/messaging_service.dart';
import 'package:kaspaverse/src/ui/messages/contacts_screen.dart';
import 'package:kaspaverse/src/ui/messages/thread_screen.dart';

ConversationDto conversation(
  String id, {
  String status = 'active',
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
);

ThreadMessageDto message(
  String txid, {
  String kind = 'comm',
  bool outbound = false,
  String text = 'hello over L1',
  bool readable = true,
  FrameDto? frame,
  bool tombstoned = false,
}) => ThreadMessageDto(
  txid: txid,
  kind: kind,
  outbound: outbound,
  unixMs: BigInt.one,
  text: text,
  readable: readable,
  frame: frame,
  tombstoned: tombstoned,
);

FrameDto frameDto({
  required String kind,
  String game = '',
  String stake = '',
  String id = '',
  String detail = '',
}) => FrameDto(kind: kind, game: game, stake: stake, id: id, detail: detail);

TransportSendSummaryDto summary({BigInt? amount}) => TransportSendSummaryDto(
  nonce: BigInt.from(7),
  destination:
      'kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf',
  amountSompi: amount ?? BigInt.from(20000000),
  feeSompi: BigInt.from(31000),
  totalSompi: (amount ?? BigInt.from(20000000)) + BigInt.from(31000),
  mass: BigInt.from(2000),
  txCount: 1,
  utxoCount: 1,
  payloadLen: 154,
  payloadKind: 'handshake',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StreamController<String> pings;

  setUp(() async {
    pings = StreamController<String>();
    MessagingService.pingFactory = () => pings.stream;
    MessagingService.startFn = () async {};
    MessagingService.conversationsFn = () async => const [];
    MessagingService.threadFn = (_) async => const [];
    MessagingService.commitFn = (_) async => const SendOutcomeDto(
      finalTxid: 'ab',
      submitted: 1,
      total: 1,
      partial: false,
    );
    MessagingService.abandonFn = () async {};
    MessagingService.hideFn = (_) async {};
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
    });
  });

  group('ContactsScreen', () {
    testWidgets('empty state invites a contact add', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      await tester.pump();
      expect(find.textContaining('No conversations yet'), findsOneWidget);
      expect(find.byIcon(Icons.person_add_alt), findsOneWidget);
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

      expect(find.text('Wants to connect'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.textContaining('0.2 KAS bond'), findsOneWidget);
      // No address is claimed before the node resolves the sender.
      expect(find.text('Unknown sender'), findsOneWidget);
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
      // The confirm sheet is honest about being local-only.
      expect(find.text('Hide conversation'), findsOneWidget);
      expect(find.textContaining('your device only'), findsOneWidget);

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

    testWidgets('renders decrypted rows and system handshake rows', (
      tester,
    ) async {
      MessagingService.threadFn = (_) async => [
        message('tx0', kind: 'handshake'),
        message('tx1', text: 'gm — first L1 DM'),
        message('tx2', outbound: true, text: 'gm right back'),
        message('tx3', readable: false, text: ''),
      ];
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      expect(find.text('Handshake received'), findsOneWidget);
      expect(find.text('gm — first L1 DM'), findsOneWidget);
      expect(find.text('gm right back'), findsOneWidget);
      // An unopenable envelope is shown honestly, never hidden.
      expect(find.text('Unreadable message'), findsOneWidget);
    });

    testWidgets('a locked vault shows the locked state, not content', (
      tester,
    ) async {
      MessagingService.threadFn = (_) async =>
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
        return summary(amount: BigInt.from(12000000));
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
      MessagingService.threadFn = (_) async {
        pulls++;
        return const [];
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
      MessagingService.threadFn = (_) async {
        pulls++;
        return const [];
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
      MessagingService.threadFn = (_) async => [challengeRow()];
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
      MessagingService.threadFn = (_) async => [challengeRow(stake: '')];
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
        return summary();
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
      MessagingService.threadFn = (_) async => [challengeRow()];
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
        MessagingService.threadFn = (_) async => [
          message(
            'txr',
            text: '🏁 I won',
            frame: frameDto(kind: 'result', id: 'a1b2c3d4', detail: 'win'),
          ),
        ];
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
      MessagingService.threadFn = (_) async => [challengeRow()];
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Decline'));
      await tester.pumpAndSettle();

      expect(find.text('Declined'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Accept'), findsNothing);
      expect(accepts, 0, reason: 'Decline sends no frame (no decline kind)');
    });

    testWidgets('an outbound challenge shows sent, not Accept', (tester) async {
      MessagingService.threadFn = (_) async => [challengeRow(outbound: true)];
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
        return summary();
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
