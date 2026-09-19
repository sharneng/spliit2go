import '../services/date_span_calculator.dart';

/// Formats [d] as an unambiguous, locale-agnostic YYYY-MM-DD -- e.date
/// (and everything a [DateSpan] is built from) is a date-only value
/// (see decisions/date-handling.md and lib/services/date_only.dart), so
/// there's no time-of-day or timezone to render, only the calendar
/// date. Matches what GroupScreen's expense list and StatsScreen
/// already rendered before this was extracted into one shared helper.
String formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Formats a [DateSpan] for display: '—' when null (no cached expenses
/// to span yet), a single date when the span is exactly one day, or
/// "first – last" otherwise.
String formatDateSpan(DateSpan? span) {
  if (span == null) return '—';
  if (span.first == span.last) return formatDate(span.first);
  return '${formatDate(span.first)} – ${formatDate(span.last)}';
}
