import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/services/exchange_rates.dart';

import '../support/error_log.dart';

// #252: exchange rates from Frankfurter v2, kept for offline use. See
// docs/decisions/currency-conversion.md.
void main() {
  late AppDatabase db;
  late DateTime now;
  late List<Uri> requests;
  late bool offline;

  /// A day's answer: rates against EUR, each from [date] unless listed.
  String table(Map<String, double> rates, String date, [Map<String, String> dates = const {}]) =>
      jsonEncode([
        for (final e in rates.entries)
          {'date': dates[e.key] ?? date, 'base': 'EUR', 'quote': e.key, 'rate': e.value},
      ]);

  // Sunday 2026-10-04: the ECB's numbers are Friday's.
  const ecbRates = {'EUR': 1.0, 'USD': 1.1225, 'JPY': 172.5, 'GBP': 0.85033};
  const averagedRates = {'USD': 1.1279, 'JPY': 173.1, 'GBP': 0.851, 'VND': 29263.0};

  late String Function(Uri uri) answer;

  ExchangeRates service() => ExchangeRates(
        db,
        now: () => now,
        client: MockClient((req) async {
          requests.add(req.url);
          if (offline) throw http.ClientException('offline');
          return http.Response(answer(req.url), 200);
        }),
      );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    now = DateTime.utc(2026, 10, 9, 12);
    requests = [];
    offline = false;
    answer = (uri) => uri.queryParameters['providers'] == 'ecb'
        ? table(ecbRates, '2026-10-02')
        : table(averagedRates, '2026-10-04', {'GBP': '2026-10-03'});
  });
  tearDown(() => db.close());

  group('a rate', () {
    test('is worked out from the ECB table when it has both currencies', () async {
      final rate = await service().rate(DateTime(2026, 10, 4), 'USD', 'JPY');
      expect(rate.rate, roundToSignificant(172.5 / 1.1225));
      expect(rate.source, RateSource.ecb);
      expect(rate.publishedOn, DateTime.utc(2026, 10, 2));
      expect(rate.offline, isFalse);
      expect(requests.single.queryParameters,
          {'base': 'EUR', 'date': '2026-10-04', 'providers': 'ecb'});
    });

    test('uses the averaged table for both currencies when the ECB lacks one', () async {
      final rate = await service().rate(DateTime(2026, 10, 4), 'VND', 'USD');
      expect(rate.rate, roundToSignificant(1.1279 / 29263));
      expect(rate.source, RateSource.averaged);
      expect(requests.map((u) => u.queryParameters['providers']), ['ecb', null]);
    });

    test('keeps 6 significant figures of a small rate', () async {
      final rate = await service().rate(DateTime(2026, 10, 4), 'VND', 'EUR');
      expect(rate.rate, 0.0000341728);
    });

    test("is from the older of the two currencies' dates", () async {
      final rate = await service().rate(DateTime(2026, 10, 4), 'VND', 'GBP');
      expect(rate.publishedOn, DateTime.utc(2026, 10, 3));
    });

    test('uses the undated request for today, and clamps a future day to today', () async {
      final rates = service();
      await rates.rate(DateTime(2026, 10, 30), 'USD', 'JPY');
      expect(requests.single.queryParameters, {'base': 'EUR', 'providers': 'ecb'});
      expect(await db.rateDay('2026-10-09', 'ecb'), isNotNull);
    });

    test('throws NoPublishedRate when neither table has the pair', () async {
      await expectLater(
          service().rate(DateTime(2026, 10, 4), 'XYZ', 'USD'), throwsA(isA<NoPublishedRate>()));
    });

    test('the same currency needs no request', () async {
      expect((await service().rate(DateTime(2026, 10, 4), 'EUR', 'EUR')).rate, 1);
      expect(requests, isEmpty);
    });

    test('requests in flight for the same day are shared', () async {
      final rates = service();
      await Future.wait([
        rates.rate(DateTime(2026, 10, 4), 'USD', 'JPY'),
        rates.rate(DateTime(2026, 10, 4), 'GBP', 'JPY'),
      ]);
      expect(requests, hasLength(1));
    });
  });

  group('a saved day', () {
    test('fetched 3 or more days after it is final: never fetched again', () async {
      final rates = service();
      await rates.rate(DateTime(2026, 10, 4), 'USD', 'JPY'); // fetched on 10-09
      now = now.add(const Duration(days: 60));
      await rates.rate(DateTime(2026, 10, 4), 'USD', 'JPY');
      expect(requests, hasLength(1));
    });

    test('fetched earlier is provisional: reused for 3 hours, then fetched again', () async {
      final rates = service();
      await rates.rate(DateTime(2026, 10, 8), 'USD', 'JPY');
      now = now.add(const Duration(hours: 2, minutes: 59));
      await rates.rate(DateTime(2026, 10, 8), 'USD', 'JPY');
      expect(requests, hasLength(1));
      now = now.add(const Duration(minutes: 1));
      await rates.rate(DateTime(2026, 10, 8), 'USD', 'JPY');
      expect(requests, hasLength(2));
    });

    test('a provisional day stays provisional however old it gets', () async {
      final rates = service();
      await rates.rate(DateTime(2026, 10, 8), 'USD', 'JPY');
      now = now.add(const Duration(days: 30));
      await rates.rate(DateTime(2026, 10, 8), 'USD', 'JPY');
      expect(requests, hasLength(2));
      // Fetched again 30 days on: final now.
      now = now.add(const Duration(days: 30));
      await rates.rate(DateTime(2026, 10, 8), 'USD', 'JPY');
      expect(requests, hasLength(2));
    });

    test('"Use the published rate" fetches it again even when recent', () async {
      final rates = service();
      await rates.rate(DateTime(2026, 10, 8), 'USD', 'JPY');
      await rates.rate(DateTime(2026, 10, 8), 'USD', 'JPY', force: true);
      expect(requests, hasLength(2));
    });
  });

  group('offline', () {
    test('uses the saved day, marked offline, even past its 3 hours', () async {
      final rates = service();
      await rates.rate(DateTime(2026, 10, 8), 'USD', 'JPY');
      now = now.add(const Duration(hours: 5));
      offline = true;
      final rate = await rates.rate(DateTime(2026, 10, 8), 'USD', 'JPY');
      expect(rate.offline, isTrue);
      expect(rate.rate, roundToSignificant(172.5 / 1.1225));
    });

    test('otherwise the newest earlier day with both currencies', () async {
      final rates = service();
      await rates.rate(DateTime(2026, 10, 3), 'VND', 'USD');
      answer = (uri) => uri.queryParameters['providers'] == 'ecb'
          ? table(ecbRates, '2026-10-05')
          : table({'USD': 1.13}, '2026-10-05');
      await rates.rate(DateTime(2026, 10, 5), 'USD', 'JPY'); // no VND that day
      offline = true;
      final rate = await rates.rate(DateTime(2026, 10, 7), 'VND', 'USD');
      expect(rate.offline, isTrue);
      expect(rate.publishedOn, DateTime.utc(2026, 10, 4));
      expect(rate.rate, roundToSignificant(1.1279 / 29263));
    });

    test('never a later day', () async {
      final rates = service();
      await rates.rate(DateTime(2026, 10, 8), 'USD', 'JPY');
      offline = true;
      await expectLater(
          rates.rate(DateTime(2026, 10, 1), 'USD', 'JPY'), throwsA(isA<RatesUnavailable>()));
    });

    test('with nothing saved: unavailable, and not logged', () async {
      offline = true;
      await expectLater(
          service().rate(DateTime(2026, 10, 4), 'USD', 'JPY'), throwsA(isA<RatesUnavailable>()));
    });

    test('a malformed answer is logged, and what was saved stays', () async {
      final rates = service();
      await rates.rate(DateTime(2026, 10, 8), 'USD', 'JPY');
      now = now.add(const Duration(hours: 4));
      answer = (_) => '{"error":"nope"}';
      expectUnexpectedError<FormatException>('Fetching ecb exchange rates for 2026-10-08');
      final rate = await rates.rate(DateTime(2026, 10, 8), 'USD', 'JPY');
      expect(rate.offline, isTrue);
      expect(rate.rate, roundToSignificant(172.5 / 1.1225));
    });
  });

  group('downloading ahead', () {
    test('fetches today and the past 7 days from both sources, then nothing for 3 hours', () async {
      final rates = service();
      await rates.downloadAhead();
      expect(requests, hasLength(16));
      expect(requests.where((u) => !u.queryParameters.containsKey('date')), hasLength(2));
      requests.clear();
      await rates.downloadAhead();
      expect(requests, isEmpty);
    });

    test('after 3 hours, fetches only the days still provisional', () async {
      final rates = service();
      await rates.downloadAhead();
      requests.clear();
      now = now.add(const Duration(hours: 3));
      await rates.downloadAhead();
      // Fetched on 10-09: 10-06 and earlier were 3 or more days later.
      expect({for (final u in requests) u.queryParameters['date'] ?? 'today'},
          {'today', '2026-10-08', '2026-10-07'});
      expect(requests, hasLength(6));
    });

    test('Update ignores the 3 hours', () async {
      final rates = service();
      await rates.downloadAhead();
      requests.clear();
      await rates.downloadAhead(force: true);
      expect(requests, hasLength(6));
    });

    test('a day saved early is fetched again after days offline, even past a week', () async {
      final rates = service();
      await rates.downloadAhead();
      now = now.add(const Duration(days: 10));
      requests.clear();
      await rates.downloadAhead();
      final dates = {for (final u in requests) u.queryParameters['date'] ?? 'today'};
      expect(dates, containsAll(['2026-10-09', '2026-10-08', '2026-10-07']));
    });

    test('stops at the first failure and throws it', () async {
      offline = true;
      await expectLater(service().downloadAhead(), throwsA(isA<http.ClientException>()));
      expect(requests, hasLength(1));
    });

    test('runs for a favorite, or a group with a conversion in the last 30 days', () async {
      final rates = service();
      await rates.downloadAheadFor(groupCurrencyCode: 'EUR', favorite: false, expenses: [
        (originalCurrency: 'JPY', date: DateTime(2026, 9, 1)),
        (originalCurrency: null, date: DateTime(2026, 10, 8)),
      ]);
      expect(requests, isEmpty);
      await rates.downloadAheadFor(groupCurrencyCode: '', favorite: true, expenses: []);
      expect(requests, isEmpty);
      await rates.downloadAheadFor(
          groupCurrencyCode: 'EUR', favorite: false, expenses: [(originalCurrency: 'JPY', date: DateTime(2026, 10, 1))]);
      expect(requests, hasLength(16));
      requests.clear();
      offline = true;
      now = now.add(const Duration(hours: 4));
      await rates.downloadAheadFor(groupCurrencyCode: 'EUR', favorite: true, expenses: []);
      expect(requests, hasLength(1));
    });

    test('says what is saved', () async {
      final rates = service();
      expect(await rates.saved(), isNull);
      await rates.rate(DateTime(2026, 10, 4), 'VND', 'USD');
      final saved = (await rates.saved())!;
      expect(saved.publishedOn, DateTime.utc(2026, 10, 4));
      expect(saved.currencies, 5); // EUR, USD, JPY, GBP, VND
    });
  });

  test('clean-up deletes days fetched over 180 days ago, but keeps each source\'s newest', () async {
    final rates = service();
    await rates.rate(DateTime(2026, 10, 3), 'VND', 'USD');
    await rates.rate(DateTime(2026, 10, 4), 'VND', 'USD');
    now = now.add(const Duration(days: 181));
    await rates.cleanUp();
    expect([for (final r in await db.allRateDays()) '${r.day}/${r.source}'],
        unorderedEquals(['2026-10-04/ecb', '2026-10-04/averaged']));
  });

  test('a saved day round-trips through its row', () {
    final day = parseRateDay(table(averagedRates, '2026-10-04', {'GBP': '2026-10-03'}),
        day: '2026-10-04', source: RateSource.averaged, fetchedAt: DateTime.utc(2026, 10, 9));
    expect(day.publishedOn, '2026-10-04');
    expect(day.publishedOnExceptions, {'GBP': '2026-10-03'});
    final back = RateDay.fromRow(day.toRow());
    expect(back.perEuro, day.perEuro);
    expect(back.publishedOnExceptions, day.publishedOnExceptions);
  });
}
