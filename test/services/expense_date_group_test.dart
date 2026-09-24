import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/services/expense_date_group.dart';

// Mirrors spliit-ios's ExpenseDateGroupTests (same fixed "today", same
// cases), plus the edges written up on issue #88.
void main() {
  // Wednesday 12 August 2026.
  final today = DateTime(2026, 8, 12, 12);

  ExpenseDateGroup bucket(DateTime date,
          {DateTime? asOf, int firstWeekday = DateTime.sunday}) =>
      expenseDateGroupFor(date, today: asOf ?? today, firstWeekday: firstWeekday);

  DateTime daysFromToday(int days) => DateTime(2026, 8, 12 + days);
  DateTime monthsFromToday(int months) => DateTime(2026, 8 + months, 12);

  test('a future expense is upcoming', () {
    expect(bucket(daysFromToday(1)), ExpenseDateGroup.upcoming);
    expect(bucket(daysFromToday(30)), ExpenseDateGroup.upcoming);
  });

  test('today and earlier this week are this week', () {
    expect(bucket(daysFromToday(0)), ExpenseDateGroup.thisWeek);
    expect(bucket(daysFromToday(-1)), ExpenseDateGroup.thisWeek);
    expect(bucket(daysFromToday(-2)), ExpenseDateGroup.thisWeek);
  });

  test('earlier in the same month, but a previous week, is earlier this month', () {
    expect(bucket(daysFromToday(-9)), ExpenseDateGroup.earlierThisMonth);
  });

  test('the previous calendar month is last month', () {
    expect(bucket(monthsFromToday(-1)), ExpenseDateGroup.lastMonth);
  });

  test('earlier in the same year is earlier this year', () {
    expect(bucket(monthsFromToday(-3)), ExpenseDateGroup.earlierThisYear);
    expect(bucket(monthsFromToday(-7)), ExpenseDateGroup.earlierThisYear);
  });

  test('the previous calendar year is last year', () {
    expect(bucket(monthsFromToday(-12)), ExpenseDateGroup.lastYear);
    expect(bucket(monthsFromToday(-19)), ExpenseDateGroup.lastYear);
  });

  test('anything older is older', () {
    expect(bucket(monthsFromToday(-25)), ExpenseDateGroup.older);
    expect(bucket(monthsFromToday(-60)), ExpenseDateGroup.older);
  });

  test('where the week starts moves the this-week boundary', () {
    final sunday9Aug = daysFromToday(-3);
    expect(bucket(sunday9Aug, firstWeekday: DateTime.sunday), ExpenseDateGroup.thisWeek);
    expect(bucket(sunday9Aug, firstWeekday: DateTime.monday),
        ExpenseDateGroup.earlierThisMonth);
  });

  test('a week crossing into a new month stays this week, not last month', () {
    final wednesday2Sep = DateTime(2026, 9, 2);
    for (final firstWeekday in [DateTime.sunday, DateTime.monday]) {
      expect(bucket(DateTime(2026, 8, 31), asOf: wednesday2Sep, firstWeekday: firstWeekday),
          ExpenseDateGroup.thisWeek);
    }
  });

  test('in January, December is last month and the rest of last year is last year', () {
    final january = DateTime(2027, 1, 15);
    expect(bucket(DateTime(2026, 12, 20), asOf: january), ExpenseDateGroup.lastMonth);
    expect(bucket(DateTime(2026, 11, 20), asOf: january), ExpenseDateGroup.lastYear);
  });

  test('only the calendar date counts, not the time of day', () {
    // An offline-added expense carries the time it was entered.
    expect(bucket(DateTime(2026, 8, 12, 23, 59), asOf: DateTime(2026, 8, 12, 0, 1)),
        ExpenseDateGroup.thisWeek);
  });

  group('groupExpensesByDate', () {
    Expense expense(String id, DateTime date) => Expense(
        id: id, groupId: 'g1', title: id, amountCents: 100, paidBy: 'p1', paidFor: const [], date: date);

    test('skips empty sections, keeps display order, and keeps order within a section', () {
      final sections = groupExpensesByDate([
        expense('older', DateTime(2020, 1, 1)),
        expense('today-b', daysFromToday(0)),
        expense('upcoming', daysFromToday(3)),
        expense('today-a', daysFromToday(0)),
      ], today: today, firstWeekday: DateTime.sunday);

      expect(sections.map((s) => s.$1), [
        ExpenseDateGroup.upcoming,
        ExpenseDateGroup.thisWeek,
        ExpenseDateGroup.older,
      ]);
      expect(sections[1].$2.map((e) => e.id), ['today-b', 'today-a']);
    });

    test('no expenses, no sections', () {
      expect(groupExpensesByDate(const [], today: today, firstWeekday: DateTime.sunday), isEmpty);
    });
  });

  group('firstWeekdayFor (the phone region decides)', () {
    test('uses the region when there is one', () {
      expect(firstWeekdayFor(const Locale('en', 'US')), DateTime.sunday);
      expect(firstWeekdayFor(const Locale('en', 'GB')), DateTime.monday);
      expect(firstWeekdayFor(const Locale('zh', 'TW')), DateTime.sunday);
      expect(firstWeekdayFor(const Locale('fr', 'CA')), DateTime.sunday);
    });

    test('falls back to the language, then to Monday', () {
      expect(firstWeekdayFor(const Locale('fr')), DateTime.monday);
      expect(firstWeekdayFor(const Locale('en')), DateTime.sunday);
      expect(firstWeekdayFor(const Locale('xx')), DateTime.monday);
      expect(firstWeekdayFor(const Locale('fr', 'XX')), DateTime.monday);
    });
  });
}
