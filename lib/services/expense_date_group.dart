import 'dart:ui' show Locale;

import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/date_symbols.dart';

import '../models/expense.dart';

/// The sections the expense list is divided into, in display order --
/// the same seven, with the same rules, as spliit-web
/// (`src/lib/date-groups.ts`) and spliit-ios (`ExpenseDateGroup.swift`).
/// See the write-up on issue #88.
enum ExpenseDateGroup {
  upcoming,
  thisWeek,
  earlierThisMonth,
  lastMonth,
  earlierThisYear,
  lastYear,
  older,
}

/// Which section an expense dated [date] goes in, as of [today]: the
/// first rule that matches, in [ExpenseDateGroup] order.
///
/// Both are compared as calendar dates, like spliit-web: an expense date
/// is date-only (docs/decisions/date-handling.md), and the time of day an
/// offline-added expense carries is ignored. spliit-ios compares the
/// server's UTC-midnight instant instead, which files expenses a day
/// early west of UTC. [firstWeekday] is a [DateTime.weekday] value.
ExpenseDateGroup expenseDateGroupFor(
  DateTime date, {
  required DateTime today,
  required int firstWeekday,
}) {
  final day = DateTime(date.year, date.month, date.day);
  final now = DateTime(today.year, today.month, today.day);
  if (day.isAfter(now)) return ExpenseDateGroup.upcoming;
  // Day arithmetic via the constructor, not Duration, so a DST change
  // inside the week can't shift the boundary by an hour.
  final weekStart =
      DateTime(now.year, now.month, now.day - (now.weekday - firstWeekday + 7) % 7);
  if (!day.isBefore(weekStart)) return ExpenseDateGroup.thisWeek;
  if (day.year == now.year && day.month == now.month) {
    return ExpenseDateGroup.earlierThisMonth;
  }
  final lastMonth = DateTime(now.year, now.month - 1);
  if (day.year == lastMonth.year && day.month == lastMonth.month) {
    return ExpenseDateGroup.lastMonth;
  }
  if (day.year == now.year) return ExpenseDateGroup.earlierThisYear;
  if (day.year == now.year - 1) return ExpenseDateGroup.lastYear;
  return ExpenseDateGroup.older;
}

/// [expenses] split into their non-empty sections, in display order,
/// keeping the given order within each section.
List<(ExpenseDateGroup, List<Expense>)> groupExpensesByDate(
  List<Expense> expenses, {
  required DateTime today,
  required int firstWeekday,
}) {
  final byGroup = <ExpenseDateGroup, List<Expense>>{};
  for (final e in expenses) {
    byGroup
        .putIfAbsent(
            expenseDateGroupFor(e.date, today: today, firstWeekday: firstWeekday),
            () => [])
        .add(e);
  }
  return [
    for (final group in ExpenseDateGroup.values)
      if (byGroup[group] case final items?) (group, items),
  ];
}

/// The first day of the week (a [DateTime.weekday]) where the phone is
/// set up, decided by its region whatever the language: Sunday for en_US
/// or zh_US, Monday for en_GB, en_FR or fr_FR. Kenneth's call in #88, the
/// same as spliit-ios. Only a locale with no region falls back to its
/// language's default (via intl: en means en_US, so Sunday), then to
/// Monday, the same fallback as spliit-web.
int firstWeekdayFor(Locale deviceLocale) {
  final region = deviceLocale.countryCode?.toUpperCase();
  if (region != null && region.isNotEmpty) {
    if (_sundayRegions.contains(region)) return DateTime.sunday;
    if (_saturdayRegions.contains(region)) return DateTime.saturday;
    if (_fridayRegions.contains(region)) return DateTime.friday;
    return DateTime.monday;
  }
  final symbols = dateTimeSymbolMap()[deviceLocale.languageCode];
  // intl counts 0 = Monday .. 6 = Sunday.
  return symbols is DateSymbols ? symbols.FIRSTDAYOFWEEK + 1 : DateTime.monday;
}

// Unicode CLDR 48 week data (weekData/firstDay in
// common/supplemental/supplementalData.xml); every region not listed
// starts on Monday, CLDR's world default. Kept here rather than looked up
// in intl, whose locale list misses most language/region pairs (zh_US,
// en_FR) and keys a language's home region by the bare language (fr).
const _fridayRegions = {'MV'};
const _saturdayRegions = {
  'AF', 'BH', 'DJ', 'DZ', 'EG', 'IQ', 'IR', 'JO', 'KW', 'LY', 'OM', 'QA', 'SD',
  'SY',
};
const _sundayRegions = {
  'AG', 'AS', 'BD', 'BR', 'BS', 'BT', 'BW', 'BZ', 'CA', 'CO', 'DM', 'DO', 'ET',
  'GT', 'GU', 'HK', 'HN', 'ID', 'IL', 'IN', 'IS', 'JM', 'JP', 'KE', 'KH', 'KR',
  'LA', 'MH', 'MM', 'MO', 'MT', 'MX', 'MZ', 'NI', 'NP', 'PA', 'PE', 'PH', 'PK',
  'PR', 'PT', 'PY', 'SA', 'SG', 'SV', 'TH', 'TT', 'TW', 'UM', 'US', 'VE', 'VI',
  'WS', 'YE', 'ZA', 'ZW',
};
