import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:spliit2go/services/date_span_calculator.dart';
import 'package:spliit2go/utils/date_format.dart';

void main() {
  const en = Locale('en');
  const fr = Locale('fr');
  const zh = Locale('zh', 'CN');

  // Inside the app, MaterialApp's localizations delegates load intl's
  // date symbols for the active locale; a bare unit test has to do it.
  setUpAll(() async {
    await initializeDateFormatting('fr');
    await initializeDateFormatting('zh_CN');
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

  group('formatTimeOfDay', () {
    test('is 24-hour HH:mm', () {
      final t = DateTime(2026, 3, 5, 9, 7);
      expect(formatTimeOfDay(t, locale: en), '09:07');
      expect(formatTimeOfDay(t, locale: fr), '09:07');
    });
  });
}
