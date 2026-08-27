import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/prefs.dart';
import 'package:kaspaverse/src/services/rate_service.dart';

/// The fiat rate is the app's **one unverifiable claim** (INV-8's carve-out,
/// D-191), so what is tested here is not "does a number arrive" but the four
/// properties that make the carve-out survivable:
///
/// 1. **Off is enforced at the egress**, not at the caller.
/// 2. **A failure never invents a price**, and never destroys a true one.
/// 3. **The switch acts on the frame the user flips it**, not at the next poll.
/// 4. **The clock runs only while a surface renders a price** — a locked
///    wallet talks to nobody.
void main() {
  // The service observes the app lifecycle (its clock stops when the app goes
  // to the background), so it needs a binding — the same reason
  // `vault_service_test` initialises one.
  TestWidgetsFlutterBinding.ensureInitialized();

  const config = RateConfigDto(
    enabled: true,
    endpoint: 'https://api.example/price',
    defaultEndpoint: 'https://api.example/price',
  );

  final rate = RateService.instance;

  setUp(() {
    rate.reset();
    rate.clock = () => DateTime(2026, 8, 27, 12);
    RateService.readConfigFn = () async => config;
    RateService.writeConfigFn = (_, _) async {};
    RateService.fetchQuoteFn = () async => RateQuoteDto(
      usdPerKas: 0.02864504,
      fetchedAtUnixMs: BigInt.from(
        DateTime(2026, 8, 27, 12).millisecondsSinceEpoch,
      ),
      source: 'https://api.example/price',
    );
  });

  tearDown(rate.reset);

  test(
    'a price arrives with its source and its time, and restates a balance',
    () async {
      await rate.refresh();
      final quote = rate.quote.value!;
      expect(quote.usdPerKas, 0.02864504);
      expect(quote.source, 'https://api.example/price');
      // 1,284.5027 KAS at that price. The multiplication is display-only
      // arithmetic on a display-only number — the balance itself never leaves
      // `BigInt` sompi (BG-5).
      final value = quote.usdFor(BigInt.from(128450270000));
      expect(value, closeTo(36.79, 0.01));
    },
  );

  test(
    'the off switch is enforced where the socket is, not where the caller is',
    () async {
      // Rust answers `None` when the rate is disabled and opens nothing. Even a
      // caller holding a stale `enabled == true` must end up off, because the
      // authority is the layer that would have made the request.
      RateService.fetchQuoteFn = () async => null;
      rate.enabled.value = true;
      await rate.refresh();
      expect(rate.enabled.value, isFalse);
      expect(rate.quote.value, isNull);
    },
  );

  test('switching it off clears the figure in the same frame', () async {
    await rate.refresh();
    expect(rate.quote.value, isNotNull);
    // A switch that leaves the old number sitting on the plate until the next
    // poll has not visibly done anything.
    await rate.setConfig(enabled: false, endpoint: config.endpoint);
    expect(rate.quote.value, isNull);
  });

  test(
    'a failed fetch keeps the last true price and never invents one',
    () async {
      await rate.refresh();
      final kept = rate.quote.value;
      expect(kept, isNotNull);

      RateService.fetchQuoteFn = () async => throw StateError('no network');
      await rate.refresh();
      expect(
        rate.quote.value,
        same(kept),
        reason: 'a price that was true when fetched stays, with its age',
      );
      expect(
        rate.error.value,
        isNotNull,
        reason: 'and the failure is nameable',
      );

      // A first fetch that fails leaves nothing rather than something.
      rate.reset();
      RateService.fetchQuoteFn = () async => throw StateError('no network');
      await rate.refresh();
      expect(rate.quote.value, isNull);
    },
  );

  test('a refusal from Rust leaves the stored posture alone', () async {
    RateService.writeConfigFn = (_, _) async =>
        throw StateError('the rate source must start with https://');
    await expectLater(
      rate.setConfig(enabled: true, endpoint: 'http://cleartext.example'),
      throwsStateError,
    );
    // Nothing was adopted locally: what the glass shows is what Rust stored.
    expect(rate.endpoint.value, isNot('http://cleartext.example'));
  });

  test('age is shown only once it can mislead — both propositions', () {
    // `L126`: a mechanism that degrades only under pressure is tested with the
    // pressure OFF as well as on. A staleness rule asserted only in its stale
    // case passes just as happily when it fires on every fresh quote.
    final at = DateTime(2026, 8, 27, 12);
    rate.quote.value = KvRateQuote(
      usdPerKas: 0.03,
      fetchedAt: at,
      source: 'https://api.example/price',
    );

    rate.clock = () =>
        at.add(RateService.staleAfter - const Duration(seconds: 1));
    expect(rate.quoteIsStale, isFalse, reason: 'a fresh rate says nothing');

    rate.clock = () => at.add(RateService.staleAfter);
    expect(rate.quoteIsStale, isTrue, reason: 'and an old one says how old');

    rate.quote.value = null;
    expect(
      rate.quoteIsStale,
      isFalse,
      reason: 'no quote is not a stale quote — it is `—`',
    );
  });

  test('the clock runs only while something renders a price', () async {
    var fetches = 0;
    RateService.fetchQuoteFn = () async {
      fetches++;
      return RateQuoteDto(
        usdPerKas: 0.03,
        fetchedAtUnixMs: BigInt.from(0),
        source: 'https://api.example/price',
      );
    };

    rate.attach();
    await pumpEventQueue();
    expect(fetches, 1, reason: 'the first attach asks once');

    // A second surface joins and leaves: the shared clock is not restarted and
    // not stopped under the first one's feet.
    rate.attach();
    rate.detach();
    await pumpEventQueue();
    expect(fetches, 1);

    rate.detach();
    // Nothing left to render a price. The quote is deliberately KEPT so a
    // re-attach paints last-known truth with its age rather than flashing `—`
    // at a user who just came back (BG-8).
    expect(rate.quote.value, isNotNull);
  });

  test('replacing the source clears the figure the old one gave', () async {
    await rate.refresh();
    expect(rate.quote.value, isNotNull);
    // A price from a vendor the user just replaced is a different claim, not
    // cached truth — and leaving it standing puts a reading under a row that
    // now names a different source.
    RateService.readConfigFn = () async => const RateConfigDto(
      enabled: true,
      endpoint: 'https://other.example/price',
      defaultEndpoint: 'https://api.example/price',
    );
    RateService.fetchQuoteFn = () async => throw StateError('unreachable');
    await rate.setConfig(
      enabled: true,
      endpoint: 'https://other.example/price',
    );
    expect(rate.quote.value, isNull);
  });

  test('a result from a source that is no longer chosen is dropped', () async {
    // Reachable with no failure at all: a refresh in flight against the old
    // endpoint lands after the user has replaced it, and the in-flight swallow
    // means no new fetch runs for up to `refreshEvery`.
    await rate.loadConfig();
    RateService.fetchQuoteFn = () async => RateQuoteDto(
      usdPerKas: 0.99,
      fetchedAtUnixMs: BigInt.from(0),
      source: 'https://stale-vendor.example/price',
    );
    await rate.refresh();
    expect(
      rate.quote.value,
      isNull,
      reason: 'the price named a source that is not the chosen one',
    );
  });

  test('the clock stops when the app goes to the background', () async {
    // Mounted is not visible. With any auto-lock grace above zero a
    // backgrounded wallet keeps the money screen alive for up to fifteen
    // minutes, and a timer that ignored that would go on asking a price vendor
    // for a figure nobody can see — from a phone in a pocket
    // (`wallet-security-auditor`). `ChainService` drops its socket on
    // background for the same reason; this follows it.
    var fetches = 0;
    RateService.fetchQuoteFn = () async {
      fetches++;
      return RateQuoteDto(
        usdPerKas: 0.03,
        fetchedAtUnixMs: BigInt.from(0),
        source: 'https://api.example/price',
      );
    };
    rate.attach();
    await pumpEventQueue();
    expect(fetches, 1);

    rate.didChangeAppLifecycleState(AppLifecycleState.paused);
    await pumpEventQueue();
    expect(fetches, 1, reason: 'a backgrounded app asks nobody anything');

    // And coming back is exactly when a stale price is worth replacing.
    rate.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(fetches, 2);
    rate.detach();
  });

  test('the posture is UNKNOWN until it has been read', () async {
    // `true` as an initialiser was a claim, not a default: a user who had
    // switched fiat off got `≈ —` on the plate for as long as the read took,
    // on every launch. Unknown is a third state and the glass renders it as
    // nothing (`wallet-security-auditor`).
    expect(rate.enabled.value, isNull);
    await rate.loadConfig();
    expect(rate.enabled.value, isTrue);
  });

  test('two overlapping refreshes make one request', () async {
    var fetches = 0;
    RateService.fetchQuoteFn = () async {
      fetches++;
      await Future<void>.delayed(Duration.zero);
      return RateQuoteDto(
        usdPerKas: 0.03,
        fetchedAtUnixMs: BigInt.from(0),
        source: 'https://api.example/price',
      );
    };
    await Future.wait([rate.refresh(), rate.refresh()]);
    expect(fetches, 1, reason: 'a fetch in flight swallows the second call');
  });
}
