import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/send.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/send/send_screen.dart';
import 'package:kaspaverse/src/ui/send/signing_ceremony.dart';
import 'package:kaspaverse/src/ui/widgets/kv_address.dart';
import 'package:kaspaverse/src/ui/widgets/kv_burial_mark.dart';
import 'package:kaspaverse/src/ui/widgets/tx_status_chip.dart';

import '../support/preview_harness.dart';

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

SignableSummaryDto _summary() => SignableSummaryDto(
  kind: SignableKind.payment,
  destination: _addr,
  amountSompi: BigInt.from(1240000000),
  feeSompi: BigInt.from(315400),
  totalSompi: BigInt.from(1240315400),
  mass: BigInt.from(2036),
  txCount: 1,
  utxoCount: 2,
  payloadLen: 0,
  payloadKind: 'none',
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

Widget _sendScreen() => SendScreen(
  mature: ValueNotifier<BigInt?>(BigInt.from(2597792200)),
  prepare: (_, _) async => _summary(),
  commit: (_) async => _sent(),
  abandon: () async {},
  feePreview: (_, _) async => BigInt.from(315400),
  minimumSendable: () async => BigInt.from(20000000),
);

void main() {
  setUpAll(loadBundledFonts);

  /// Renders one surface at BOTH geometries. The floor is where things break;
  /// a preview that only shows the reference is the comfortable half.
  void surface(String name, Widget Function() build) {
    for (final size in PreviewSize.all) {
      testWidgets('preview: $name @ ${size.label}', (tester) async {
        await renderSurface(tester, name: name, child: build(), size: size);
      }, skip: !previewRequested);
    }
  }

  group('surface previews (tier 2 — no device)', () {
    surface('send__empty', _sendScreen);

    surface(
      'ceremony__confirm',
      () => SigningCeremony(
        summary: _summary(),
        commit: (_) async => _sent(),
        abandon: () async {},
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

    surface(
      'burial__ladder',
      () => const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              KvBurialMark(
                state: TxChipState.accepted,
                confirmations: 42,
                maturity: MaturityState.pending,
                verbose: true,
              ),
              SizedBox(height: 12),
              KvBurialMark(
                state: TxChipState.accepted,
                confirmations: 420,
                maturity: MaturityState.accepted,
              ),
              SizedBox(height: 12),
              KvBurialMark(
                state: TxChipState.accepted,
                confirmations: 4200,
                maturity: MaturityState.confirmed,
              ),
            ],
          ),
        ),
      ),
    );
  });
}
