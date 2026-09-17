import '../models/expense.dart';

/// Splits one expense's amount among its [Expense.paidFor] participants,
/// in cents. Factored out of [computeBalances] (see balance_calculator.dart)
/// so the exact same per-expense apportionment backs both balances and
/// the stats tab's per-participant "share" figures (issue #27) -- these
/// two views need to agree, the same way they do in the web app's own
/// lib/totals.ts (`getExpenseShares`) and lib/shares.ts.
///
/// [SplitMode.evenly] is deliberately NOT weighted by [ExpenseShare.shares]
/// even though it's stored in the same field -- see the note in
/// balance_calculator.dart's doc comment (verified against issue #20:
/// the web app's own "Evenly" expenses can carry non-uniform shares
/// values left over from switching split modes, and its balance math
/// visibly ignores them).
///
/// Uses largest-remainder rounding so the returned amounts always sum to
/// exactly [Expense.amountCents] -- see balance_calculator.dart's doc
/// comment for the same caveat about tie-break order on an exactly-tied
/// remainder.
///
/// Returns an empty map for an expense with no [Expense.paidFor] entries.
Map<String, int> expenseShareCents(Expense e) {
  if (e.paidFor.isEmpty) return const {};

  if (e.splitMode == SplitMode.byAmount) {
    return {for (final s in e.paidFor) s.participantId: s.shares};
  }

  final weights = e.splitMode == SplitMode.evenly
      ? List<int>.filled(e.paidFor.length, 1)
      : e.paidFor.map((s) => s.shares).toList();
  final totalShares = weights.fold<int>(0, (sum, w) => sum + w);
  if (totalShares <= 0) return const {};

  final raw = List<double>.generate(
      e.paidFor.length, (i) => e.amountCents * weights[i] / totalShares);
  final floors = raw.map((r) => r.floor()).toList();
  final distributed = floors.fold<int>(0, (a, b) => a + b);
  final remainder = e.amountCents - distributed;

  final byRemainder = List<int>.generate(raw.length, (i) => i)
    ..sort((a, b) => (raw[b] - floors[b]).compareTo(raw[a] - floors[a]));

  final owed = List<int>.from(floors);
  for (var i = 0; i < remainder; i++) {
    owed[byRemainder[i % byRemainder.length]] += 1;
  }

  return {
    for (var i = 0; i < e.paidFor.length; i++) e.paidFor[i].participantId: owed[i],
  };
}
