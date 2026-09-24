import '../models/expense.dart';

/// The expenses whose title contains [query], ignoring case and the
/// query's surrounding whitespace (issue #39). Order is kept.
///
/// Titles only, as in Spliit: the server's `groups.expenses.list` filter is
/// `title: { contains: filter, mode: 'insensitive' }` (spliit-web
/// `src/lib/api.ts`), and spliit-ios searches through it. Here it runs over
/// the local cache instead, which holds every expense in the group, so it
/// covers the same ground, works offline, and finds unsynced expenses too.
///
/// A blank query matches nothing: an empty field is not a search.
List<Expense> searchExpenses(List<Expense> expenses, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const [];
  return [
    for (final e in expenses)
      if (e.title.toLowerCase().contains(needle)) e,
  ];
}
