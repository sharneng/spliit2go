import '../db/app_database.dart';

/// The earliest and latest date among a set of expenses -- e.g. a
/// group's whole cached history (issue #55).
class DateSpan {
  final DateTime first;
  final DateTime last;

  const DateSpan({required this.first, required this.last});
}

/// [DateSpan] across every one of [rows], including reimbursements/
/// settlements -- unlike StatsScreen's spending-summary firstDate/
/// lastDate (stats_calculator.dart's [SpendingSummary]), which
/// deliberately excludes settlements as "not new spending" for a
/// spending total. This is meant to answer "how long has this group
/// been active" rather than "how much have we spent", and a settlement
/// is still a dated event in the group's history, so nothing here is
/// filtered out -- issue #55 defines it plainly as "first expense date
/// to last expense date in the group".
///
/// Null if [rows] is empty -- a group with no cached expenses at all
/// (a just-joined group whose expenses haven't been fetched down yet,
/// or a genuinely brand-new group with zero expenses).
DateSpan? computeDateSpan(List<ExpenseRow> rows) {
  if (rows.isEmpty) return null;
  var first = rows.first.date;
  var last = rows.first.date;
  for (final row in rows.skip(1)) {
    if (row.date.isBefore(first)) first = row.date;
    if (row.date.isAfter(last)) last = row.date;
  }
  return DateSpan(first: first, last: last);
}
