import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/rust/api/send.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/biometric_copy.dart';
import 'package:kaspaverse/src/services/rate_service.dart';
import 'package:kaspaverse/src/ui/home_screen.dart';
import 'package:kaspaverse/src/ui/node/node_screen.dart';
import 'package:kaspaverse/src/ui/receive/receive_screen.dart';
import 'package:kaspaverse/src/ui/secret/secret_keyboard.dart';
import 'package:kaspaverse/src/ui/send/send_screen.dart';
import 'package:kaspaverse/src/ui/settings_screen.dart';
import 'package:kaspaverse/src/ui/tx/tx_detail_screen.dart';
import 'package:kaspaverse/src/ui/send/signing_ceremony.dart';
import 'package:kaspaverse/src/ui/widgets/kv_address.dart';
import 'package:kaspaverse/src/ui/widgets/kv_burial_gauge.dart';
import 'package:kaspaverse/src/ui/widgets/kv_burial_mark.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_coming_soon.dart';
import 'package:kaspaverse/src/ui/widgets/kv_drawer.dart';
import 'package:kaspaverse/src/ui/widgets/kv_glyph.dart';
import 'package:kaspaverse/src/ui/widgets/kv_mark.dart';
import 'package:kaspaverse/src/ui/widgets/kv_keypad.dart';
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
    unixtimeMsec: BigInt.from(1788085010103),
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
    unixtimeMsec: BigInt.from(1788080000000),
    blockDaaScore: BigInt.from(526000000),
    direction: ActivityDirection.incoming,
    isCoinbase: false,
    maturity: MaturityState.confirmed,
    stalled: false,
  ),
];

Widget _home() => HomeScreen(
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
    mature: ValueNotifier<BigInt?>(BigInt.from(2597792200)),
    pending: ValueNotifier<BigInt?>(BigInt.zero),
    activity: ValueNotifier(_activity()),
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
    const KvDestination(
      mark: KvGlyph.games,
      label: 'Games',
      tag: 'Coming soon',
    ),
    const KvDestination(
      mark: KvGlyph.finance,
      label: 'Finance',
      tag: 'Coming soon',
    ),
    const KvDestination(
      mark: KvGlyph.identity,
      label: 'Identity',
      tag: 'Coming soon',
    ),
  ],
  footer: [
    KvDestination(mark: KvGlyph.settings, label: 'Settings', onTap: () {}),
    KvDestination(mark: KvGlyph.lock, label: 'Lock', onTap: () {}),
  ],
  child: home,
);

/// Summons the drawer the way a thumb does — the `compact` posture, and a
/// no-op in the classes where navigation already stands.
Future<void> _summonDrawer(WidgetTester tester) async {
  final avatar = find.bySemanticsLabel('Open navigation');
  if (avatar.evaluate().isEmpty) return;
  await tester.tap(avatar);
}

/// Types an amount on the pad and pastes a destination — the state in which the
/// send screen actually has a fee, an address review and a live Review button.
Future<void> _typeASend(WidgetTester tester) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => call.method == 'Clipboard.getData'
        ? <String, dynamic>{'text': _addr}
        : null,
  );
  // Scoped to the pad: an unscoped `find.text('.')` matches whatever
  // else on the screen happens to render that glyph, and at the floor
  // geometry it typed `124` instead of `12.4` — a harness artifact that
  // would have read as a screen defect.
  for (final key in ['1', '2', '.', '4']) {
    await tester.tap(
      find.descendant(of: find.byType(KvKeypad), matching: find.text(key)),
    );
    await tester.pump();
  }
  await tester.tap(
    find.byWidgetPredicate((w) => w is KvGlyphIcon && w.mark == KvGlyph.paste),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Widget _node() => NodeScreen(
  scope: NodeScope(
    connected: ValueNotifier(true),
    activeEndpoint: ValueNotifier<String?>('wss://isla.kaspa.red'),
    virtualDaaScore: ValueNotifier<BigInt?>(BigInt.from(526633447)),
    pinnedNode: ValueNotifier<String?>(null),
    pinDropped: ValueNotifier(false),
    setPinnedNode: (_) async {},
    lastUpdate: ValueNotifier<DateTime?>(DateTime(2026, 8, 30, 11, 16)),
  ),
);

Widget _settings() => SettingsScreen(
  security: SecurityScope(
    biometricStatus: () async => 'ready',
    pathAState: () async => pathANone,
    enroll: () async => true,
    clearEnrollment: () async {},
    lockGraceSecs: ValueNotifier(0),
    setLockGraceSecs: (_) async {},
  ),
  wallet: WalletSettingsScope(
    receiveAddress: () async => _addr,
    deepScan: () async =>
        DeepScanReport(depth: 0, receiveSeen: 0, changeSeen: 0, widened: false),
  ),
  about: const AboutScope(packageInfo: _packageInfo),
);

Future<Map<String, String>> _packageInfo() async => const {
  'version': '1.0.0',
  'build': '1',
};

/// One send, forty-two blocks deep, with the explorer exit resolved to a
/// plausible host. Fixture data only — no preview ever carries an address, a
/// balance or a txid that belongs to anyone.
Widget _txDetail() => TxDetailScreen(
  txid: 'e154009eae73d2ef9cab0a80dc42a62ebb91f93cbdeab514a57ca3b01d7e5d34',
  activity: ValueNotifier<List<ActivityRecord>>([
    ActivityRecord(
      txid: 'e154009eae73d2ef9cab0a80dc42a62ebb91f93cbdeab514a57ca3b01d7e5d34',
      valueSompi: BigInt.from(1240000000),
      unixtimeMsec: BigInt.from(1788058080000),
      blockDaaScore: BigInt.from(458173900),
      acceptedDaaScore: BigInt.from(458174000),
      direction: ActivityDirection.outgoing,
      isCoinbase: false,
      maturity: MaturityState.pending,
      stalled: false,
    ),
  ]),
  virtualDaaScore: ValueNotifier<BigInt?>(BigInt.from(458174042)),
  stale: ValueNotifier<bool>(false),
  explorerUrl: (txid) async => 'https://explorer.kaspa.org/txs/$txid',
  openUrl: (_) async => true,
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
          state: TxChipState.accepted,
          confirmations: 1,
          maturity: MaturityState.pending,
        ),
        SizedBox(height: 32),
        KvBurialGauge(
          state: TxChipState.accepted,
          confirmations: 10,
          maturity: MaturityState.pending,
        ),
        SizedBox(height: 32),
        KvBurialGauge(
          state: TxChipState.accepted,
          confirmations: 340,
          maturity: MaturityState.accepted,
        ),
        SizedBox(height: 32),
        KvBurialGauge(
          state: TxChipState.accepted,
          confirmations: 4200,
          maturity: MaturityState.confirmed,
        ),
      ],
    ),
  ),
);

void main() {
  setUpAll(loadBundledFonts);

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
    // **The money screen, in all four window classes** (BG-33, UX-R1): the
    // pushed drawer at `compact`, the 80 dp rail at `medium`, ledger + detail
    // beside a standing drawer at `expanded`, and the `KvMoneyBar` collapse at
    // `expanded short`.
    framedSurface('home__funded', () => _shell(_home()));
    framedSurface('home__status', () => _shell(_homeStatus()));
    framedSurface('home__drawer', () => _shell(_home()), act: _summonDrawer);
    surface('receive__address', () => ReceiveScreen(fetch: () async => _addr));

    // **The failed state, at the same footprint** — the composition UX-5 owes
    // (BG-20), and the one no happy-path preview can show.
    surface(
      'receive__failed',
      () => ReceiveScreen(
        fetch: () async => throw const AppError(message: 'the vault is locked'),
      ),
    );
    surface('node__connected', _node);
    surface('settings__root', _settings);
    surface('send__empty', _sendScreen);

    // **The send screen doing its job**, which no preview has ever shown: an
    // amount typed on the pad, a destination pasted, the chunked address
    // review, the live fee and Review enabled. `send__empty` renders the one
    // state where none of that exists.
    surface('send__typed', _sendScreen, act: _typeASend);

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
    surface('tx__detail', _txDetail);

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
                state: TxChipState.accepted,
                confirmations: 42,
                maturity: MaturityState.pending,
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
