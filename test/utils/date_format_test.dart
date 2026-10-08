import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:spliit2go/services/date_span_calculator.dart';
import 'package:spliit2go/utils/date_format.dart';

void main() {
  const en = Locale('en');
  const fr = Locale('fr');
  const zh = Locale('zh');

  // Inside the app, MaterialApp's localizations delegates load intl's
  // date symbols for the active locale; a bare unit test has to do it.
  setUpAll(() async {
    await initializeDateFormatting('fr');
    await initializeDateFormatting('zh');
    await initializeDateFormatting('en_GB');
    await initializeDateFormatting('de');
  });

  group('formatDate', () {
    test('renders a locale-appropriate calendar date', () {
      final d = DateTime.utc(2026, 3, 5);
      expect(formatDate(d, locale: en), 'Mar 5, 2026');
      expect(formatDate(d, locale: fr), '5 mars 2026');
      expect(formatDate(d, locale: zh), '2026年3月5日');
    });

    test('does not perform any timezone conversion', () {
      // date_only.dart's UTC-midnight convention (decisions/date-
      // handling.md) means every date this ever receives is already a
      // UTC DateTime -- formatDate must render its year/month/day as
      // given, not re-derive them via .toLocal().
      expect(formatDate(DateTime.utc(2026, 12, 31), locale: en), 'Dec 31, 2026');
      expect(formatDate(DateTime.utc(2026, 1, 1), locale: en), 'Jan 1, 2026');
    });
  });

  group('formatDateSpan', () {
    test('renders an em-dash placeholder for a null span', () {
      expect(formatDateSpan(null, locale: en), '—');
      expect(formatDateSpan(null, locale: zh), '—');
    });

    test('renders a single date when the span is exactly one day', () {
      final span = DateSpan(first: DateTime.utc(2026, 5, 1), last: DateTime.utc(2026, 5, 1));
      expect(formatDateSpan(span, locale: en), 'May 1, 2026');
    });

    test('renders both dates separated by an en dash otherwise', () {
      final span = DateSpan(first: DateTime.utc(2026, 1, 2), last: DateTime.utc(2026, 6, 15));
      expect(formatDateSpan(span, locale: en), 'Jan 2, 2026 – Jun 15, 2026');
      expect(formatDateSpan(span, locale: fr), '2 janv. 2026 – 15 juin 2026');
      expect(formatDateSpan(span, locale: zh), '2026年1月2日 – 2026年6月15日');
    });
  });

  // #233: read by people, so the device's 24-hour setting, else the
  // locale's own clock.
  group('formatTimeOfDay', () {
    final t = DateTime(2026, 3, 5, 21, 7);
    test('24-hour HH:mm when the device says so', () {
      expect(formatTimeOfDay(t, locale: en, use24HourFormat: true), '21:07');
      expect(formatTimeOfDay(t, locale: zh, use24HourFormat: true), '21:07');
    });
    test('otherwise the locale\'s own clock', () {
      expect(formatTimeOfDay(t, locale: en, use24HourFormat: false), '9:07\u202fPM');
      expect(formatTimeOfDay(t, locale: const Locale('en', 'GB'), use24HourFormat: false), '21:07');
      expect(formatTimeOfDay(t, locale: fr, use24HourFormat: false), '21:07');
    });
  });

  group('formatDateTime', () {
    final t = DateTime(2026, 9, 12, 9, 3);
    test('with the year', () {
      expect(formatDateTime(t, locale: en, use24HourFormat: false), 'Sep 12, 2026 9:03\u202fAM');
      expect(formatDateTime(t, locale: fr, use24HourFormat: true), '12 sept. 2026 09:03');
    });
    test('without it: CLDR\'s month and day', () {
      expect(formatDateTime(t, locale: en, use24HourFormat: false, withYear: false), 'Sep 12 9:03\u202fAM');
      expect(formatDateTime(t, locale: const Locale('en', 'GB'), use24HourFormat: true, withYear: false),
          '12 Sept 09:03');
      expect(formatDateTime(t, locale: fr, use24HourFormat: true, withYear: false), '12 sept. 09:03');
      expect(formatDateTime(t, locale: zh, use24HourFormat: true, withYear: false), '9月12日 09:03');
    });
  });

  group('isWithinTenMonths', () {
    final now = DateTime(2026, 10, 8, 12);
    test('ten months back to the day', () {
      expect(isWithinTenMonths(DateTime(2025, 12, 8), now: now), isTrue);
      expect(isWithinTenMonths(DateTime(2025, 12, 7, 23, 59), now: now), isFalse);
      expect(isWithinTenMonths(DateTime(2025, 10, 8), now: now), isFalse);
      expect(isWithinTenMonths(DateTime(2026, 10, 9), now: now), isTrue, reason: 'a clock behind the server');
    });
  });

  // #207: the expense list's dates, one width each.
  group('formatShortDate', () {
    test('each locale\'s own numeric order and separators, zero-padded', () {
      final d = DateTime(2026, 9, 9);
      expect(formatShortDate(d, locale: en), '09/09/2026');
      expect(formatShortDate(DateTime(2026, 9, 10), locale: en), '09/10/2026');
      expect(formatShortDate(DateTime(2026, 9, 10), locale: const Locale('en', 'GB')),
          '10/09/2026');
      expect(formatShortDate(DateTime(2026, 9, 10), locale: fr), '10/09/2026');
      expect(formatShortDate(d, locale: zh), '2026/09/09');
      expect(formatShortDate(d, locale: const Locale('de')), '09.09.2026');
    });

    test('every date of a locale is the same length', () {
      for (final locale in [en, fr, zh]) {
        final lengths = {
          for (final d in [DateTime(2026, 1, 1), DateTime(2026, 9, 9), DateTime(2026, 12, 31)])
            formatShortDate(d, locale: locale).length,
        };
        expect(lengths, hasLength(1), reason: '$locale');
      }
    });
  });
}
