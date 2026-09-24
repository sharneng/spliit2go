import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/models/activity.dart';
import 'package:spliit2go/services/activity_date_group.dart';

// Issue #91: the activity log's nine sections, the same rules as
// spliit-web's activity-list.tsx and spliit-ios's ActivityDateGroup.
void main() {
  // Wednesday 12 August 2026, noon.
  final now = DateTime(2026, 8, 12, 12);

  ActivityDateGroup bucket(DateTime local, {DateTime? asOf, int firstWeekday = DateTime.sunday}) =>
      activityDateGroupFor(local, now: asOf ?? now, firstWeekday: firstWeekday);

  test('earlier today is today', () {
    expect(bucket(DateTime(2026, 8, 12, 0, 1)), ActivityDateGroup.today);
  });

  test('a future time is today, whether later today or on a later day', () {
    expect(bucket(DateTime(2026, 8, 12, 23, 59)), ActivityDateGroup.today);
    expect(bucket(DateTime(2026, 8, 14, 9)), ActivityDateGroup.today);
  });

  test('the day before is yesterday', () {
    expect(bucket(DateTime(2026, 8, 11, 23, 59)), ActivityDateGroup.yesterday);
    expect(bucket(DateTime(2026, 8, 11, 0, 0)), ActivityDateGroup.yesterday);
  });

  test('earlier this week, from the week start to the day before yesterday', () {
    expect(bucket(DateTime(2026, 8, 10)), ActivityDateGroup.earlierThisWeek);
    expect(bucket(DateTime(2026, 8, 9)), ActivityDateGroup.earlierThisWeek); // Sunday
  });

  test('last week is the whole previous week', () {
    expect(bucket(DateTime(2026, 8, 8, 23)), ActivityDateGroup.lastWeek); // Saturday
    expect(bucket(DateTime(2026, 8, 2)), ActivityDateGroup.lastWeek); // Sunday
    expect(bucket(DateTime(2026, 8, 1, 23)), ActivityDateGroup.earlierThisMonth);
  });

  test('where the week starts moves both week boundaries', () {
    // With Monday starts, Sunday 9 Aug belongs to last week.
    expect(bucket(DateTime(2026, 8, 9), firstWeekday: DateTime.monday), ActivityDateGroup.lastWeek);
    expect(bucket(DateTime(2026, 8, 2), firstWeekday: DateTime.monday),
        ActivityDateGroup.earlierThisMonth);
  });

  test('yesterday wins over last week on the first day of a week', () {
    final monday = DateTime(2026, 8, 10, 9);
    expect(bucket(DateTime(2026, 8, 9, 20), asOf: monday, firstWeekday: DateTime.monday),
        ActivityDateGroup.yesterday);
  });

  test('last week holds across a month change and a year change', () {
    // Wed 2 Sep: last week is Sun 23 - Sat 29 Aug.
    expect(bucket(DateTime(2026, 8, 24), asOf: DateTime(2026, 9, 2)), ActivityDateGroup.lastWeek);
    // Tue 5 Jan 2027: last week is Sun 27 Dec - Sat 2 Jan.
    expect(bucket(DateTime(2026, 12, 28), asOf: DateTime(2027, 1, 5)), ActivityDateGroup.lastWeek);
    expect(bucket(DateTime(2026, 12, 26), asOf: DateTime(2027, 1, 5)), ActivityDateGroup.lastMonth);
  });

  test('months and years, after the week sections', () {
    expect(bucket(DateTime(2026, 7, 20)), ActivityDateGroup.lastMonth);
    expect(bucket(DateTime(2026, 3, 1)), ActivityDateGroup.earlierThisYear);
    expect(bucket(DateTime(2025, 12, 31)), ActivityDateGroup.lastYear);
    expect(bucket(DateTime(2024, 6, 1)), ActivityDateGroup.older);
  });

  test('a 23-hour day (US spring-forward) still makes the day before yesterday', () {
    // The US moves clocks forward on Sun 8 Mar 2026. Measuring the gap
    // in hours, as the old code did, would call this "today".
    expect(bucket(DateTime(2026, 3, 8, 0, 10), asOf: DateTime(2026, 3, 9, 0, 30)),
        ActivityDateGroup.yesterday);
  });

  test('only Today and Yesterday rows leave the date out', () {
    expect([for (final g in ActivityDateGroup.values) if (!g.needsDate) g],
        [ActivityDateGroup.today, ActivityDateGroup.yesterday]);
  });

  test('grouping uses the given local time, skips empty sections, keeps server order', () {
    Activity activity(String id, DateTime utc) => Activity(
        id: id, time: utc, activityType: ActivityType.updateGroup, expenseExists: false);
    // New York in August is UTC-4.
    DateTime newYork(DateTime t) {
      final w = t.toUtc().subtract(const Duration(hours: 4));
      return DateTime(w.year, w.month, w.day, w.hour, w.minute);
    }

    final sections = groupActivitiesByDate([
      activity('after-midnight-utc', DateTime.utc(2026, 8, 12, 3)), // 23:00 on the 11th
      activity('late-morning', DateTime.utc(2026, 8, 12, 15)), // 11:00 on the 12th
      activity('old', DateTime.utc(2024, 1, 1)),
    ], now: now, firstWeekday: DateTime.sunday, toLocal: newYork);

    expect([for (final (g, items) in sections) '${g.name}: ${items.map((a) => a.id).join(', ')}'], [
      'today: late-morning',
      'yesterday: after-midnight-utc',
      'older: old',
    ]);
  });
}
