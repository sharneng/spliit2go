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
/// set up, from its locale's region: Sunday for en_US, Monday for en_GB
/// or fr. Kenneth's call in #88, the same as spliit-ios; Monday when the
/// locale is unknown, the same fallback as spliit-web.
int firstWeekdayFor(Locale deviceLocale) {
  final symbols = dateTimeSymbolMap();
  final country = deviceLocale.countryCode;
  final match = (country == null ? null : symbols['${deviceLocale.languageCode}_$country']) ??
      symbols[deviceLocale.languageCode];
  // intl counts 0 = Monday .. 6 = Sunday.
  return match is DateSymbols ? match.FIRSTDAYOFWEEK + 1 : DateTime.monday;
}
