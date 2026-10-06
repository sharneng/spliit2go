import '../db/app_database.dart';
import 'date_span_calculator.dart';

enum GroupListSort { firstExpense, lastExpense, created, lastOpened }

GroupListSort groupListSortFromTag(String? value) =>
    GroupListSort.values.firstWhere((sort) => sort.name == value,
        orElse: () => GroupListSort.lastOpened);

/// The date [row] is sorted by under [sort], which is also the one date
/// its list row shows (#201), or null when it has none.
DateTime? groupSortDate(
        GroupRow row, GroupListSort sort, Map<String, DateSpan?> spans) =>
    switch (sort) {
      GroupListSort.firstExpense => spans[row.id]?.first,
      GroupListSort.lastExpense => spans[row.id]?.last,
      GroupListSort.created => row.createdAt,
      GroupListSort.lastOpened => row.lastOpenedAt,
    };

int compareGroupRows(
    GroupRow a, GroupRow b, GroupListSort sort, Map<String, DateSpan?> spans) {
  final ad = groupSortDate(a, sort, spans);
  final bd = groupSortDate(b, sort, spans);
  // No date first: most likely a group just created or joined, with no
  // expenses yet (#201 review).
  final order = ad == null
      ? (bd == null ? 0 : -1)
      : bd == null
          ? 1
          : bd.compareTo(ad);
  return order != 0 ? order : a.id.compareTo(b.id);
}
