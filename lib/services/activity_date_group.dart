import '../models/activity.dart';

/// The sections the activity log is divided into, in display order --
/// the same nine, with the same rules, as spliit-web (activity-list.tsx)
/// and spliit-ios (ActivityDateGroup.swift). Finer than the expense
/// list's sections: most of a log is from the last day or two. See
/// issue #91.
enum ActivityDateGroup {
  today,
  yesterday,
  earlierThisWeek,
  lastWeek,
  earlierThisMonth,
  lastMonth,
  earlierThisYear,
  lastYear,
  older;

  /// Whether a row here has to show its date as well as its time: Today
  /// and Yesterday already name the day, every other heading a span.
  bool get needsDate => this != today && this != yesterday;
}

/// Which section an activity at local time [local] goes in, as of the
/// local time [now]: the first rule that matches, in [ActivityDateGroup]
/// order. A future time (a phone clock behind the server's) is Today,
/// like spliit-ios. [firstWeekday] is a [DateTime.weekday] value.
ActivityDateGroup activityDateGroupFor(
  DateTime local, {
  required DateTime now,
  required int firstWeekday,
}) {
  // Calendar arithmetic on UTC dates: no daylight-saving change can make
  // a day 23 or 25 hours long, whatever the phone's time zone.
  final day = DateTime.utc(local.year, local.month, local.day);
  final today = DateTime.utc(now.year, now.month, now.day);
  if (!day.isBefore(today)) return ActivityDateGroup.today;
  if (day == DateTime.utc(today.year, today.month, today.day - 1)) {
    return ActivityDateGroup.yesterday;
  }
  final thisWeek = DateTime.utc(
      today.year, today.month, today.day - (today.weekday - firstWeekday + 7) % 7);
  if (!day.isBefore(thisWeek)) return ActivityDateGroup.earlierThisWeek;
  final lastWeek = DateTime.utc(thisWeek.year, thisWeek.month, thisWeek.day - 7);
  if (!day.isBefore(lastWeek)) return ActivityDateGroup.lastWeek;
  if (day.year == today.year && day.month == today.month) {
    return ActivityDateGroup.earlierThisMonth;
  }
  final lastMonth = DateTime.utc(today.year, today.month - 1);
  if (day.year == lastMonth.year && day.month == lastMonth.month) {
    return ActivityDateGroup.lastMonth;
  }
  if (day.year == today.year) return ActivityDateGroup.earlierThisYear;
  if (day.year == today.year - 1) return ActivityDateGroup.lastYear;
  return ActivityDateGroup.older;
}

/// [activities] split into their non-empty sections, in display order,
/// keeping the server's order within each. [toLocal] turns an activity's
/// UTC moment into the phone's local time -- the same conversion the rows
/// must use to show it.
List<(ActivityDateGroup, List<Activity>)> groupActivitiesByDate(
  List<Activity> activities, {
  required DateTime now,
  required int firstWeekday,
  required DateTime Function(DateTime) toLocal,
}) {
  final byGroup = <ActivityDateGroup, List<Activity>>{};
  for (final a in activities) {
    byGroup
        .putIfAbsent(
            activityDateGroupFor(toLocal(a.time), now: now, firstWeekday: firstWeekday),
            () => [])
        .add(a);
  }
  return [
    for (final group in ActivityDateGroup.values)
      if (byGroup[group] case final items?) (group, items),
  ];
}
