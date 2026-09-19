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
/// Every [ExpenseRow.date] is normalized to its bare calendar date
/// (year/month/day, time-of-day dropped) before comparison. Most
/// expense dates are already date-only (see decisions/date-handling.md
/// and lib/services/date_only.dart), but a newly-added pending expense
/// is dated with the real DateTime.now() at creation time (add_expense_
/// screen.dart has no date picker yet), so two pending expenses added
/// on the same calendar day at different times would otherwise compare
/// as different DateTimes and render as a spurious same-day range like
/// "2026-01-02 -- 2026-01-02" instead of collapsing to a single date
/// (caught in review of this feature -- see issue #55).
///
/// Null if [rows] is empty -- a group with no cached expenses at all
/// (a just-joined group whose expenses haven't been fetched down yet,
/// or a genuinely brand-new group with zero expenses).
DateSpan? computeDateSpan(List<ExpenseRow> rows) {
  if (rows.isEmpty) return null;
  DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
  var first = dateOnly(rows.first.date);
  var last = first;
  for (final row in rows.skip(1)) {
    final d = dateOnly(row.date);
    if (d.isBefore(first)) first = d;
    if (d.isAfter(last)) last = d;
  }
  return DateSpan(first: first, last: last);
}
