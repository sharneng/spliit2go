import '../models/expense.dart';
import '../models/group.dart';
import 'expense_shares.dart';

/// Client-side stats calculations (issue #27), computed entirely from the
/// local expense cache -- same rationale as balance_calculator.dart:
/// works offline, and avoids reverse-engineering the server's
/// `groups.stats.overview` tRPC procedure (whose exact shape hasn't been
/// verified live the way the expense/balance endpoints were).
///
/// A first pass only: group, participant and category spending.
/// Deliberately NOT ported from spliit-app/spliit's lib/totals.ts: month-by-month trend charts, recurring-spending
/// projections, and a date-range selector -- those need their own design
/// pass (see issue #27) and a chart-rendering approach this app doesn't
/// have yet. "All time" is the only range this first pass supports.
///
/// Every function here excludes reimbursement expenses from spending
/// totals, matching the web app's lib/totals.ts (a settlement isn't new
/// spending, so counting it would double-count money that already
/// appeared in the expense it's settling).

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
