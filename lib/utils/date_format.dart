import 'package:flutter/widgets.dart' show Locale;
import 'package:intl/intl.dart';

import '../services/date_span_calculator.dart';

/// Formats [d] as a locale-appropriate calendar date -- `Sep 19, 2026`
/// (en), `19 sept. 2026` (fr), `2026年9月19日` (zh). e.date (and
/// everything a [DateSpan] is built from) is a date-only value (see
/// decisions/date-handling.md and lib/services/date_only.dart), so
/// there's no time-of-day or timezone to render, only the calendar date;
/// [DateFormat] prints the year/month/day fields it's given without
/// converting them, which is what keeps that true. This changes only how
/// an already-correct date is displayed (issue #51, item 5), not any date
/// semantics.
///
/// The abbreviated-month form (`yMMMd`) rather than an all-numeric one:
/// it's unambiguous in every locale (`1/2/2026` is January 2nd in en-US
/// and February 1st in en-GB), and it's the same pattern everywhere so
/// there's one place to change it.
///
/// [locale] is required, for the same reason as `formatMoney`'s: it must
/// be the resolved app locale (`Localizations.localeOf(context)`), and a
/// forgotten call site should fail to compile rather than silently show
/// the wrong language after a live switch. Inside the app, `intl`'s date
/// symbols for [locale] are loaded by MaterialApp's own localizations
/// delegates; a caller outside a widget tree (a unit test) has to call
/// `initializeDateFormatting` first.
String formatDate(DateTime d, {required Locale locale}) =>
    DateFormat.yMMMd(locale.toString()).format(d);

/// Formats [t]'s time of day as 24-hour `HH:mm` in [locale]'s digits.
String formatTimeOfDay(DateTime t, {required Locale locale}) =>
    DateFormat.Hm(locale.toString()).format(t);

/// Formats a [DateSpan] for display: '—' when null (no cached expenses
/// to span yet), a single date when the span is exactly one day, or
/// "first – last" otherwise.
String formatDateSpan(DateSpan? span, {required Locale locale}) {
  if (span == null) return '—';
  if (span.first == span.last) return formatDate(span.first, locale: locale);
  return '${formatDate(span.first, locale: locale)} – ${formatDate(span.last, locale: locale)}';
}
