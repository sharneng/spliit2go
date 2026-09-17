import '../models/balance.dart';
import '../models/expense.dart';
import '../models/group.dart';

/// Computes each participant's net balance from a group's expenses --
/// client-side, deliberately, rather than calling a server endpoint for
/// it. Two reasons: it works offline (balances need to reflect any
/// still-pending local expenses, which the server doesn't know about
/// yet), and it avoids reverse-engineering another tRPC procedure whose
/// exact shape we haven't verified live the way groups.expenses.list and
/// groups.expenses.create were (see decisions/mobile-platform.md).
///
/// A reimbursement expense (see [Settlement]) needs no special-casing
/// here: it's just a normal expense where the person settling up is
/// `paidBy` and the person being paid back is the sole `paidFor` entry,
/// so the ordinary paid-minus-owed math already nets it out correctly.
///
/// Positive [Balance.netCents] means the group owes that participant
/// money overall; negative means they owe the group.
List<Balance> computeBalances(List<Participant> participants, List<Expense> expenses) {
  final net = {for (final p in participants) p.id: 0};

  for (final e in expenses) {
    net[e.paidBy] = (net[e.paidBy] ?? 0) + e.amountCents;
    if (e.paidFor.isEmpty) continue;

    if (e.splitMode == SplitMode.byAmount) {
      // Each share IS the exact cents that participant owes.
      for (final s in e.paidFor) {
        net[s.participantId] = (net[s.participantId] ?? 0) - s.shares;
      }
      continue;
    }

    // byShares / byPercentage are "proportional weight" splits as far
    // as this math cares -- a percentage-mode share is proportional to
    // the whole regardless of what scale it's stored on (out of 100,
    // out of 10000, ...), since we only ever use it relative to the
    // total.
    //
    // SplitMode.evenly is deliberately NOT treated as weighted by
    // ExpenseShare.shares, even though it's stored in the very same
    // field -- verified against a real group (github.com/sharneng/
    // spliit2go/issues/20) where the web app's own "Evenly" expenses
    // carried non-uniform shares values (e.g. 100/100/200, presumably
    // left over from switching split modes in the web UI, or some
    // other web-app-internal bookkeeping) that the web app's own
    // balance math visibly ignores -- an evenly split expense there
    // paid out as a true equal share per included participant, not
    // weighted by those numbers. Using [ExpenseShare.shares] for
    // evenly here reproduced that exact (wrong) weighted result and
    // was off by tens of dollars against the web/iOS balance for a
    // real multi-expense group.
    final weights = e.splitMode == SplitMode.evenly
        ? List<int>.filled(e.paidFor.length, 1)
        : e.paidFor.map((s) => s.shares).toList();
    final totalShares = weights.fold<int>(0, (sum, w) => sum + w);
    if (totalShares <= 0) continue;

    // Largest-remainder rounding so the split always sums to exactly
    // amountCents, rather than losing or gaining a cent to naive
    // per-share rounding. Note: when a remainder has to be distributed
    // among participants with an exactly-tied fractional share (a
    // perfectly even split that isn't evenly divisible by amountCents,
    // e.g. $1.00 split 3 ways), which participant(s) get the extra
    // cent(s) here is decided by paidFor list order, which hasn't been
    // verified to match the server's own tie-break -- expect balances
    // to be exactly right in total but occasionally off by a cent or
    // two per participant in that specific case.
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

    for (var i = 0; i < e.paidFor.length; i++) {
      final pid = e.paidFor[i].participantId;
      net[pid] = (net[pid] ?? 0) - owed[i];
    }
  }

  return [for (final p in participants) Balance(participantId: p.id, netCents: net[p.id] ?? 0)];
}

/// A minimal-transaction-count greedy settlement: repeatedly pays the
/// largest debtor toward the largest creditor until everyone's at zero.
/// This is an independent (simpler) implementation of the same idea as
/// Spliit's own "suggested reimbursements" -- it isn't guaranteed to
/// produce byte-identical suggestions to the server's algorithm, but it
/// produces a correct, minimal-ish set of transfers, and -- unlike
/// calling the server for this -- it works offline and reflects pending
/// local expenses immediately.
List<Settlement> suggestSettlements(List<Balance> balances) {
  final creditors = balances.where((b) => b.netCents > 0).toList()
    ..sort((a, b) => b.netCents.compareTo(a.netCents));
  final debtors = balances.where((b) => b.netCents < 0).toList()
    ..sort((a, b) => a.netCents.compareTo(b.netCents)); // most negative first

  final creditAmounts = creditors.map((b) => b.netCents).toList();
  final debtAmounts = debtors.map((b) => -b.netCents).toList();

  final settlements = <Settlement>[];
  var i = 0, j = 0;
  while (i < debtors.length && j < creditors.length) {
    final pay = debtAmounts[i] < creditAmounts[j] ? debtAmounts[i] : creditAmounts[j];
    if (pay > 0) {
      settlements.add(Settlement(
        fromId: debtors[i].participantId,
        toId: creditors[j].participantId,
        amountCents: pay,
      ));
    }
    debtAmounts[i] -= pay;
    creditAmounts[j] -= pay;
    if (debtAmounts[i] == 0) i++;
    if (creditAmounts[j] == 0) j++;
  }
  return settlements;
}
