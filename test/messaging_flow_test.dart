import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}) => ThreadMessageDto(
  txid: txid,
  kind: kind,
  outbound: outbound,
  unixMs: BigInt.one,
  text: text,
  readable: readable,
);

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
      // The value line is the computed floor, exact — never a magic 0.2.
      expect(
        find.textContaining('Hold to send 0.12000000 KAS'),
        findsOneWidget,
      );
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
  });
}
