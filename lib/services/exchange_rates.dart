import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../db/app_database.dart';
import 'error_reporting.dart';

/// Where a day of rates comes from (#252): the ECB's own table, or
/// Frankfurter's average of every central bank it follows.
enum RateSource {
  ecb('ecb'),
  averaged('averaged');

  const RateSource(this.key);

  /// Stored in [RateDays.source].
  final String key;

  static RateSource fromKey(String key) => values.firstWhere((s) => s.key == key);
}

/// One saved or fetched day of rates against EUR (#252).
@immutable
class RateDay {
  const RateDay({
    required this.day,
    required this.source,
    required this.perEuro,
    required this.publishedOn,
    this.publishedOnExceptions = const {},
    required this.fetchedAt,
  });

  /// yyyy-MM-dd, the day asked for.
  final String day;
  final RateSource source;

  /// Units of each currency per 1 EUR.
  final Map<String, double> perEuro;

  /// The date most of the rates are from, yyyy-MM-dd.
  final String publishedOn;

  /// The currencies whose rate is from another date.
  final Map<String, String> publishedOnExceptions;
  final DateTime fetchedAt;

  /// Fetched 3 or more days after the day itself: it can't change any
  /// more. Until then it's provisional, however old the day becomes.
  bool get isFinal => !fetchedAt.toUtc().isBefore(parseDay(day).add(const Duration(days: 3)));

  bool has(String code) => code == 'EUR' || perEuro.containsKey(code);

  double _perEuro(String code) => code == 'EUR' ? 1 : perEuro[code]!;

  String _publishedOn(String code) => publishedOnExceptions[code] ?? publishedOn;

  /// 1 [from] in [to], worked out through EUR; both must be [has].
  double rate(String from, String to) => _perEuro(to) / _perEuro(from);

  /// The older of the two currencies' publication dates: the pair's rate
  /// is no newer than that.
  String publishedOnFor(String from, String to) {
    final dates = [
      if (from != 'EUR') _publishedOn(from),
      if (to != 'EUR') _publishedOn(to),
    ]..sort();
    return dates.isEmpty ? publishedOn : dates.first;
  }

  int get currencyCount => {...perEuro.keys, 'EUR'}.length;

  RateDayRow toRow() => RateDayRow(
        day: day,
        source: source.key,
        perEuroJson: jsonEncode(perEuro),
        publishedOn: publishedOn,
        publishedOnExceptionsJson: jsonEncode(publishedOnExceptions),
        fetchedAt: fetchedAt,
      );

  factory RateDay.fromRow(RateDayRow row) => RateDay(
        day: row.day,
        source: RateSource.fromKey(row.source),
        perEuro: {
          for (final e in (jsonDecode(row.perEuroJson) as Map<String, dynamic>).entries)
            e.key: (e.value as num).toDouble(),
        },
        publishedOn: row.publishedOn,
        publishedOnExceptions:
            (jsonDecode(row.publishedOnExceptionsJson) as Map<String, dynamic>).cast<String, String>(),
        fetchedAt: row.fetchedAt,
      );
}

/// A rate for the form: 1 unit of the paid-in currency in the group's.
@immutable
class ExchangeRate {
  const ExchangeRate({
    required this.rate,
    required this.publishedOn,
    required this.source,
    this.offline = false,
  });

  /// Rounded to 6 significant figures: the one value shown, saved and
  /// used for the amount, so they can't disagree.
  final double rate;

  /// The day the rate is from, as a date-only UTC value.
  final DateTime publishedOn;
  final RateSource source;

  /// Couldn't reach Frankfurter: a saved day that may be out of date, or
  /// an earlier day's rate.
  final bool offline;
}

/// Frankfurter has no rate for the pair on that day: type one.
class NoPublishedRate implements Exception {
  const NoPublishedRate();
}

/// Frankfurter couldn't be reached, and nothing saved has the pair.
class RatesUnavailable implements Exception {
  const RatesUnavailable();
}

/// What's saved, for App settings › Storage.
@immutable
class SavedRates {
  const SavedRates({required this.publishedOn, required this.currencies});

  /// The newest saved day's publication date.
  final DateTime publishedOn;
  final int currencies;
}

/// yyyy-MM-dd as a UTC midnight.
DateTime parseDay(String day) {
  final parts = day.split('-').map(int.parse).toList();
  return DateTime.utc(parts[0], parts[1], parts[2]);
}

/// A date's yyyy-MM-dd, from its year, month and day.
String dayKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}'
    '-${date.day.toString().padLeft(2, '0')}';

/// [value] to [digits] significant figures.
double roundToSignificant(double value, [int digits = 6]) =>
    double.parse(value.toStringAsPrecision(digits));

/// Exchange rates from Frankfurter v2, kept on the phone for offline use
/// (#252). See docs/decisions/currency-conversion.md.
///
/// Only ever whole days against EUR, in two tables: the ECB's, used when
/// it has both currencies (the same rates spliit-web and spliit-ios
/// use), otherwise the averaged one for both.
class ExchangeRates {
  ExchangeRates(
    this.db, {
    http.Client? client,
    DateTime Function()? now,
    this.baseUrl = 'https://api.frankfurter.dev/v2',
  })  : _client = client ?? newClient(),
        _now = now ?? DateTime.now;

  final AppDatabase db;
  final http.Client _client;
  final DateTime Function() _now;
  final String baseUrl;

  /// A provisional day fetched this long ago is fetched again.
  static const recheckAfter = Duration(hours: 3);

  /// Days fetched longer ago than this are cleaned up.
  static const keepFor = Duration(days: 180);

  /// The client [of] uses. Tests make it offline, so no screen test
  /// reaches Frankfurter.
  @visibleForTesting
  static http.Client Function() newClient = http.Client.new;

  static final _byDb = Expando<ExchangeRates>('ExchangeRates');

  /// The service for [db], shared by every screen using it.
  static ExchangeRates of(AppDatabase db) => _byDb[db] ??= ExchangeRates(db);

  @visibleForTesting
  static void use(ExchangeRates rates) => _byDb[rates.db] = rates;

  /// Requests in flight, per day and source, so scrolling through dates
  /// doesn't fire requests side by side.
  final _inFlight = <String, Future<RateDay>>{};

  /// Today, UTC.
  String get _today => dayKey(_now().toUtc());

  /// [date]'s day, a future one clamped to today.
  String clampDay(DateTime date) {
    final day = dayKey(date);
    final today = _today;
    return day.compareTo(today) > 0 ? today : day;
  }

  /// 1 [from] in [to] on [date]. Throws [NoPublishedRate] or
  /// [RatesUnavailable]. [force] ("Use the published rate") fetches the
  /// day again even when what's saved is recent.
  Future<ExchangeRate> rate(DateTime date, String from, String to, {bool force = false}) async {
    final day = clampDay(date);
    if (from == to) {
      return ExchangeRate(rate: 1, publishedOn: parseDay(day), source: RateSource.ecb);
    }
    try {
      for (final source in RateSource.values) {
        final table = await _day(day, source, force: force);
        if (table.has(from) && table.has(to)) return _rateFrom(table, from, to);
      }
      throw const NoPublishedRate();
    } on _Unreachable {
      return _offlineRate(day, from, to);
    }
  }

  ExchangeRate _rateFrom(RateDay table, String from, String to, {bool offline = false}) =>
      ExchangeRate(
        rate: roundToSignificant(table.rate(from, to)),
        publishedOn: parseDay(table.publishedOnFor(from, to)),
        source: table.source,
        offline: offline,
      );

  /// The saved day even if it's out of date, otherwise the newest earlier
  /// day with both currencies; ECB first on each day.
  Future<ExchangeRate> _offlineRate(String day, String from, String to) async {
    final byDay = <String, Map<RateSource, RateDay>>{};
    for (final row in await db.allRateDays()) {
      if (row.day.compareTo(day) > 0) continue;
      (byDay[row.day] ??= {})[RateSource.fromKey(row.source)] = RateDay.fromRow(row);
    }
    final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final d in days) {
      for (final source in RateSource.values) {
        final table = byDay[d]![source];
        if (table != null && table.has(from) && table.has(to)) {
          return _rateFrom(table, from, to, offline: true);
        }
      }
    }
    throw const RatesUnavailable();
  }

  bool _isRecent(RateDay saved) => _now().difference(saved.fetchedAt) < recheckAfter;

  /// [day] from [source]: saved if final or recent, otherwise fetched.
  /// Throws [_Unreachable] when it has to be fetched and can't be.
  Future<RateDay> _day(String day, RateSource source, {bool force = false}) async {
    final row = await db.rateDay(day, source.key);
    final saved = row == null ? null : RateDay.fromRow(row);
    if (saved != null && !force && (saved.isFinal || _isRecent(saved))) return saved;
    return _fetchAndSave(day, source);
  }

  Future<RateDay> _fetchAndSave(String day, RateSource source) {
    final key = '$day/${source.key}';
    return _inFlight[key] ??= () async {
      try {
        final table = await _fetch(day, source);
        await db.saveRateDay(table.toRow());
        return table;
      } catch (e, st) {
        // Offline is expected and not logged; a malformed answer is
        // logged once, and what's saved stays.
        ErrorReporter.instance.report(e, st, operation: 'Fetching ${source.key} exchange rates for $day');
        throw _Unreachable(e);
      } finally {
        // After the first await, so always after the assignment below.
        _inFlight.remove(key);
      }
    }();
  }

  /// Today uses the undated request: a dated one for today can be cached
  /// half-finished for a day.
  Future<RateDay> _fetch(String day, RateSource source) async {
    final fetchedAt = _now();
    final uri = Uri.parse('$baseUrl/rates').replace(queryParameters: {
      'base': 'EUR',
      if (day != dayKey(fetchedAt.toUtc())) 'date': day,
      if (source == RateSource.ecb) 'providers': 'ecb',
    });
    final response = await _client.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode == 429 || response.statusCode >= 500) {
      throw HttpException('Frankfurter answered ${response.statusCode}', uri: uri);
    }
    if (response.statusCode != 200) {
      throw FormatException('Frankfurter answered ${response.statusCode}: ${response.body}');
    }
    return parseRateDay(response.body, day: day, source: source, fetchedAt: fetchedAt);
  }

  /// Fetches what downloading ahead needs (#252), for both sources:
  /// today, any of the past 7 days not saved yet, and every saved day
  /// that's still provisional, if fetched more than 3 hours ago, or
  /// whatever its age when [force] (Update). Stops at the first failure
  /// and throws it.
  Future<void> downloadAhead({bool force = false}) async {
    final now = _now();
    final today = parseDay(_today);
    final saved = {
      for (final row in await db.allRateDays()) '${row.day}/${row.source}': RateDay.fromRow(row),
    };
    final days = {
      for (var i = 0; i <= 7; i++) dayKey(today.subtract(Duration(days: i))),
      for (final s in saved.values)
        if (!s.isFinal) s.day,
    }.toList()
      ..sort((a, b) => b.compareTo(a));
    for (final day in days) {
      for (final source in RateSource.values) {
        final s = saved['$day/${source.key}'];
        final due = s == null ||
            (!s.isFinal && (force || now.difference(s.fetchedAt) >= recheckAfter));
        if (!due) continue;
        try {
          await _fetchAndSave(day, source);
        } on _Unreachable catch (e) {
          Error.throwWithStackTrace(e.error, StackTrace.current);
        }
      }
    }
  }

  /// Downloads ahead after a group refreshes, if it can convert (an ISO
  /// code) and is a favorite or has a conversion in the last 30 days.
  /// Failures stay quiet: the form says so when it needs a rate.
  Future<void> downloadAheadFor({
    required String? groupCurrencyCode,
    required bool favorite,
    required Iterable<({String? originalCurrency, DateTime date})> expenses,
  }) async {
    if (groupCurrencyCode == null || groupCurrencyCode.isEmpty) return;
    final since = _now().subtract(const Duration(days: 30));
    final converts = favorite ||
        expenses.any((e) => e.originalCurrency != null && !e.date.isBefore(since));
    if (!converts) return;
    try {
      await downloadAhead();
    } catch (_) {
      // Already reported by the fetch.
    }
  }

  /// Deletes days fetched more than 180 days ago, except each source's
  /// newest day. Run at startup.
  Future<void> cleanUp() async {
    try {
      await db.deleteRateDaysFetchedBefore(_now().subtract(keepFor));
    } catch (e, st) {
      ErrorReporter.instance.report(e, st, operation: 'Cleaning up exchange rates');
    }
  }

  /// The newest saved day, for App settings; null when none is saved.
  Future<SavedRates?> saved() async {
    final rows = await db.allRateDays();
    if (rows.isEmpty) return null;
    final newestDay = rows.first.day;
    final tables = [for (final r in rows) if (r.day == newestDay) RateDay.fromRow(r)];
    final codes = {'EUR', for (final t in tables) ...t.perEuro.keys};
    final published = (tables.map((t) => t.publishedOn).toList()..sort()).last;
    return SavedRates(publishedOn: parseDay(published), currencies: codes.length);
  }
}

/// Frankfurter's answer for a day: `[{"date","base","quote","rate"}]`.
/// Throws [FormatException] when it isn't that.
@visibleForTesting
RateDay parseRateDay(String body,
    {required String day, required RateSource source, required DateTime fetchedAt}) {
  final decoded = jsonDecode(body);
  if (decoded is! List) throw FormatException('Expected a list of rates', body);
  final perEuro = <String, double>{};
  final dates = <String, String>{};
  for (final item in decoded) {
    if (item is! Map ||
        item['quote'] is! String ||
        item['rate'] is! num ||
        item['date'] is! String ||
        item['base'] != 'EUR') {
      throw FormatException('Unexpected rate', item);
    }
    final rate = (item['rate'] as num).toDouble();
    if (rate <= 0) throw FormatException('Unexpected rate', item);
    final quote = item['quote'] as String;
    if (quote == 'EUR') continue;
    perEuro[quote] = rate;
    dates[quote] = item['date'] as String;
  }
  // The date most rates are from; the others listed as exceptions.
  final counts = <String, int>{};
  for (final d in dates.values) {
    counts[d] = (counts[d] ?? 0) + 1;
  }
  final publishedOn = counts.isEmpty
      ? day
      : (counts.entries.toList()
            ..sort((a, b) => b.value != a.value ? b.value - a.value : b.key.compareTo(a.key)))
          .first
          .key;
  return RateDay(
    day: day,
    source: source,
    perEuro: perEuro,
    publishedOn: publishedOn,
    publishedOnExceptions: {
      for (final e in dates.entries)
        if (e.value != publishedOn) e.key: e.value,
    },
    fetchedAt: fetchedAt,
  );
}

/// A day that had to be fetched and couldn't be.
class _Unreachable implements Exception {
  const _Unreachable(this.error);
  final Object error;
}
