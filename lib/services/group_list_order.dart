import '../db/app_database.dart';
import 'date_span_calculator.dart';

enum GroupListSort { firstExpense, lastExpense, created, lastOpened }

GroupListSort groupListSortFromTag(String? value) =>
    GroupListSort.values.firstWhere((sort) => sort.name == value,
        orElse: () => GroupListSort.lastOpened);

int compareGroupRows(
    GroupRow a, GroupRow b, GroupListSort sort, Map<String, DateSpan?> spans) {
  DateTime? date(GroupRow row) => switch (sort) {
        GroupListSort.firstExpense => spans[row.id]?.first,
        GroupListSort.lastExpense => spans[row.id]?.last,
        GroupListSort.created => row.createdAt,
        GroupListSort.lastOpened => row.lastOpenedAt,
      };
  final ad = date(a);
  final bd = date(b);
  final order = ad == null
      ? (bd == null ? 0 : 1)
      : bd == null
          ? -1
          : bd.compareTo(ad);
  return order != 0 ? order : a.id.compareTo(b.id);
}
