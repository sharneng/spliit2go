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
/// The abbreviated-month form (`yMMMd`) wherever a date stands on its
/// own: it reads at a glance, and it's the same pattern everywhere, so
/// there's one place to change it. A list row, where dates are read down
/// a column, uses [formatShortDate] instead.
///
/// [locale] is required, for the same reason as `formatMoney`'s: it must
/// be the resolved app locale (`Localizations.localeOf(context)`), and a
/// forgotten call site should fail to compile rather than silently show
/// the wrong language after a live switch. Inside the app, `intl`'s date
/// symbols for [locale] are loaded by MaterialApp's own localizations
/// delegates; a caller outside a widget tree (a unit test) has to call
/// `initializeDateFormatting` first.
///
/// Without the year when [withYear] is false (#226), CLDR's month and day
/// for [locale]: `Sep 19`, `19 sept.`, `9月19日`.
String formatDate(DateTime d, {required Locale locale, bool withYear = true}) =>
    (withYear ? DateFormat.yMMMd(locale.toString()) : DateFormat.MMMd(locale.toString())).format(d);

/// Formats [d] as [locale]'s own all-numeric date, zero-padded so every
/// date has the same width (#207): `09/09/2026` (en-US), `09/09/2026`
/// (fr, en-GB: day first), `2026/09/09` (zh). For the expense list, where
/// what follows the date should line up row to row; drawn with tabular
/// figures, so the digits are equal widths too.
///
/// The order and separators are CLDR's for [locale] (`DateFormat.yMd`),
/// only padded, so each reader sees their own convention: `09/10/2026` is
/// September 10th in en-US and October 9th in en-GB, which is only
/// ambiguous to someone reading another locale's dates. Like
/// [formatDate], a date-only value, formatted without conversion.
String formatShortDate(DateTime d, {required Locale locale}) {
  final pattern = DateFormat.yMd(locale.toString()).pattern!;
  // A lone M or d (CLDR's unpadded month or day) becomes MM or dd. Quoted
  // literal text, which these patterns don't use today, is left alone.
  final padded = pattern.splitMapJoin(RegExp(r"'[^']*'"),
      onMatch: (m) => m[0]!,
      onNonMatch: (text) =>
          text.replaceAllMapped(RegExp(r'(?<![Md])([Md])(?![Md])'), (m) => '${m[1]}${m[1]}'));
  return DateFormat(padded, locale.toString()).format(d);
}

/// Formats [t]'s time of day for people to read (#233): 24-hour `HH:mm`
/// when [use24HourFormat] (the device's own setting,
/// `MediaQuery.alwaysUse24HourFormatOf`), otherwise [locale]'s own clock,
/// `9:07 AM` in en, `09:07` in fr.
String formatTimeOfDay(DateTime t, {required Locale locale, required bool use24HourFormat}) =>
    _time(DateFormat(null, locale.toString()), use24HourFormat).format(t);

/// [t]'s date and time together, joined the way [locale] joins them:
/// "Sep 12, 2026 9:03 AM". Without the year when [withYear] is false
/// (#233), CLDR's month-and-day form for [locale]: "Sep 12", "12 sept.",
/// "9月12日". Like [formatTimeOfDay], formats [t]'s own fields: convert a
/// real moment with `toLocal()` first.
String formatDateTime(DateTime t,
    {required Locale locale, required bool use24HourFormat, bool withYear = true}) {
  final date = withYear ? DateFormat.yMMMd(locale.toString()) : DateFormat.MMMd(locale.toString());
  return _time(date, use24HourFormat).format(t);
}

DateFormat _time(DateFormat format, bool use24HourFormat) =>
    use24HourFormat ? format.add_Hm() : format.add_jm();

/// Whether [t] is recent enough to show without its year (#233): within
/// ten months before [now], so it can't be read as the same month a year
/// on. Anything later than [now] counts as recent too.
bool isWithinTenMonths(DateTime t, {required DateTime now}) =>
    !t.isBefore(DateTime(now.year, now.month - 10, now.day));

/// Formats a [DateSpan] for display: '—' when null (no cached expenses
/// to span yet), a single date when the span is exactly one day, or
/// "first – last" otherwise.
String formatDateSpan(DateSpan? span, {required Locale locale}) {
  if (span == null) return '—';
  if (span.first == span.last) return formatDate(span.first, locale: locale);
  return '${formatDate(span.first, locale: locale)} – ${formatDate(span.last, locale: locale)}';
}
