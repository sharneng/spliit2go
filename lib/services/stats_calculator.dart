import '../models/expense.dart';
import '../models/group.dart';
import 'expense_shares.dart';

/// Client-side stats calculations (issue #27), computed entirely from the
/// local expense cache -- same rationale as balance_calculator.dart:
/// works offline, and avoids reverse-engineering the server's
/// `groups.stats.overview` tRPC procedure (whose exact shape hasn't been
/// verified live the way the expense/balance endpoints were).
///
/// A first pass only: summary totals, group/participant/category
/// spending. Deliberately NOT ported from spliit-app/spliit's
/// lib/totals.ts: month-by-month trend charts, recurring-spending
/// projections, and a date-range selector -- those need their own design
/// pass (see issue #27) and a chart-rendering approach this app doesn't
/// have yet. "All time" is the only range this first pass supports.
///
/// Every function here excludes reimbursement expenses from spending
/// totals, matching the web app's lib/totals.ts (a settlement isn't new
/// spending, so counting it would double-count money that already
/// appeared in the expense it's settling).

class SpendingSummary {
  final int expenseCount;
  final int totalCents;
  final int averageCents;
  final String? largestTitle;
  final int? largestCents;
  final DateTime? firstDate;
  final DateTime? lastDate;

  const SpendingSummary({
    required this.expenseCount,
    required this.totalCents,
    required this.averageCents,
    this.largestTitle,
    this.largestCents,
    this.firstDate,
    this.lastDate,
  });
}

class ParticipantSpending {
  final String participantId;
  final String name;
  final int paidCents;
  final int paidCount;
  final int shareCents;

  const ParticipantSpending({
    required this.participantId,
    required this.name,
    required this.paidCents,
    required this.paidCount,
    required this.shareCents,
  });
}

class CategorySpending {
  final int categoryId;
  final int totalCents;

  const CategorySpending({required this.categoryId, required this.totalCents});
}

/// The group's total non-reimbursement spending, in cents.
int totalGroupSpendingCents(List<Expense> expenses) => expenses
    .where((e) => !e.isReimbursement)
    .fold(0, (sum, e) => sum + e.amountCents);

/// High-level summary metrics: how many expenses there are, the average
/// and largest, and the active date span -- mirrors the web app's
/// `getSpendingSummary`.
SpendingSummary computeSpendingSummary(List<Expense> expenses) {
  final relevant = expenses.where((e) => !e.isReimbursement).toList();
  final count = relevant.length;
  final total = relevant.fold<int>(0, (sum, e) => sum + e.amountCents);

  Expense? largest;
  for (final e in relevant) {
    if (largest == null || e.amountCents > largest.amountCents) largest = e;
  }

  final dates = relevant.map((e) => e.date).toList()..sort();

  return SpendingSummary(
    expenseCount: count,
    totalCents: total,
    averageCents: count == 0 ? 0 : (total / count).round(),
    largestTitle: largest?.title,
    largestCents: largest?.amountCents,
    firstDate: dates.isEmpty ? null : dates.first,
    lastDate: dates.isEmpty ? null : dates.last,
  );
}

/// For every participant: how much they paid, how many expenses they
/// paid for, and their total share of the group's spending -- mirrors
/// the web app's `getSpendingByParticipant`. Sorted by amount paid,
/// descending.
List<ParticipantSpending> computeParticipantSpending(
  List<Participant> participants,
  List<Expense> expenses,
) {
  final paid = {for (final p in participants) p.id: 0};
  final paidCount = {for (final p in participants) p.id: 0};
  final share = {for (final p in participants) p.id: 0};

  for (final e in expenses) {
    if (e.isReimbursement) continue;

    if (paid.containsKey(e.paidBy)) {
      paid[e.paidBy] = paid[e.paidBy]! + e.amountCents;
      paidCount[e.paidBy] = paidCount[e.paidBy]! + 1;
    }
    for (final entry in expenseShareCents(e).entries) {
      if (share.containsKey(entry.key)) {
        share[entry.key] = share[entry.key]! + entry.value;
      }
    }
  }

  final result = [
    for (final p in participants)
      ParticipantSpending(
        participantId: p.id,
        name: p.name,
        paidCents: paid[p.id] ?? 0,
        paidCount: paidCount[p.id] ?? 0,
        shareCents: share[p.id] ?? 0,
      ),
  ];
  result.sort((a, b) => b.paidCents.compareTo(a.paidCents));
  return result;
}

/// Total spending per category id -- mirrors the web app's
/// `getSpendingByCategory`. Zero-total categories are dropped; sorted
/// highest to lowest spend. Category *names* aren't resolved here (this
/// app doesn't cache the category list locally) -- see StatsScreen for
/// how it looks names up, with an id-only fallback when offline.
List<CategorySpending> computeCategorySpending(List<Expense> expenses) {
  final totals = <int, int>{};
  for (final e in expenses) {
    if (e.isReimbursement) continue;
    totals[e.category] = (totals[e.category] ?? 0) + e.amountCents;
  }

  final result = totals.entries
      .where((entry) => entry.value != 0)
      .map((entry) => CategorySpending(categoryId: entry.key, totalCents: entry.value))
      .toList();
  result.sort((a, b) => b.totalCents.compareTo(a.totalCents));
  return result;
}

/// How much [participantId] has paid across the group's non-reimbursement
/// expenses. Null input yields null (no active user picked yet), mirroring
/// how the "Totals" card on the web app's stats page hides these two rows
/// entirely without an active user selected.
int? activeUserPaidCents(String? participantId, List<Expense> expenses) {
  if (participantId == null) return null;
  return expenses
      .where((e) => !e.isReimbursement && e.paidBy == participantId)
      .fold(0, (sum, e) => sum + e.amountCents);
}

/// [participantId]'s total share of the group's non-reimbursement
/// spending -- what they'd owe if nothing had been paid yet.
int? activeUserShareCents(String? participantId, List<Expense> expenses) {
  if (participantId == null) return null;
  var sum = 0;
  for (final e in expenses) {
    if (e.isReimbursement) continue;
    sum += expenseShareCents(e)[participantId] ?? 0;
  }
  return sum;
}
