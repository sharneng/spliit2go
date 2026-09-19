import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/services/date_span_calculator.dart';
import 'package:spliit2go/utils/date_format.dart';

void main() {
  group('formatDate', () {
    test('renders as zero-padded YYYY-MM-DD', () {
      expect(formatDate(DateTime.utc(2026, 3, 5)), '2026-03-05');
    });

    test('does not perform any timezone conversion', () {
      // date_only.dart's UTC-midnight convention (decisions/date-
      // handling.md) means every date this ever receives is already a
      // UTC DateTime -- formatDate must render its year/month/day as
      // given, not re-derive them via .toLocal().
      expect(formatDate(DateTime.utc(2026, 12, 31)), '2026-12-31');
    });
  });

  group('formatDateSpan', () {
    test('renders an em-dash placeholder for a null span', () {
      expect(formatDateSpan(null), '—');
    });

    test('renders a single date when the span is exactly one day', () {
      final span = DateSpan(first: DateTime.utc(2026, 5, 1), last: DateTime.utc(2026, 5, 1));
      expect(formatDateSpan(span), '2026-05-01');
    });

    test('renders both dates separated by an en dash otherwise', () {
      final span = DateSpan(first: DateTime.utc(2026, 1, 2), last: DateTime.utc(2026, 6, 15));
      expect(formatDateSpan(span), '2026-01-02 – 2026-06-15');
    });
  });
}
