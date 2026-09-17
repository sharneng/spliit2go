import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/models/balance.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/services/balance_calculator.dart';

void main() {
  const alex = Participant(id: 'alex', name: 'Alex');
  const bea = Participant(id: 'bea', name: 'Bea');
  const cid = Participant(id: 'cid', name: 'Cid');
  final participants = [alex, bea, cid];

  Expense evenExpense({required int amountCents}) => Expense(
        id: 'e1',
        groupId: 'g1',
        title: 'Groceries',
        amountCents: amountCents,
        paidBy: 'alex',
        paidFor: const [
          ExpenseShare(participantId: 'alex', shares: 1),
          ExpenseShare(participantId: 'bea', shares: 1),
          ExpenseShare(participantId: 'cid', shares: 1),
        ],
        date: DateTime.utc(2026, 9, 16),
      );

  group('computeBalances', () {
    // The exact scenario driven live on spliit.app during UI research:
    // $90 groceries, paid by Alex, split evenly three ways -> Alex +60,
    // Bea -30, Cid -30 (see decisions/feature-backlog.md).
    test('evenly split: payer is net-positive, others net-negative', () {
      final balances = computeBalances(participants, [evenExpense(amountCents: 9000)]);
      final byId = {for (final b in balances) b.participantId: b.netCents};
      expect(byId['alex'], 6000);
      expect(byId['bea'], -3000);
      expect(byId['cid'], -3000);
    });

    test('evenly split with a remainder distributes the odd cent, summing exactly', () {
      // 100 cents / 3 doesn't divide evenly -- the split must still sum
      // to exactly the expense amount, not leave a cent unaccounted for.
      final balances = computeBalances(participants, [evenExpense(amountCents: 100)]);
      final owedSum = balances.fold<int>(0, (sum, b) => sum + b.netCents);
      // Payer paid 100, so the net across all three balances the payer's
      // credit against the sum of what was actually distributed as owed.
      expect(owedSum, 0);
    });

    // Regression test for github.com/sharneng/spliit2go/issues/20: a
    // real group had SplitMode.evenly expenses whose ExpenseShare.shares
    // were non-uniform (e.g. 100/100/200, apparently left over from
    // switching split modes in the web app's UI) -- treating those as
    // real weights (the way byShares/byPercentage correctly do) split
    // the expense unevenly and threw the computed balance off by tens of
    // dollars against the web/iOS app's own (correctly equal-split)
    // result for the same group. Evenly must split equally per included
    // participant regardless of whatever's actually stored in shares.
    test('evenly split ignores non-uniform shares values (issue #20)', () {
      final expense = Expense(
        id: 'e1',
        groupId: 'g1',
        title: 'test',
        amountCents: 33400,
        paidBy: 'alex',
        paidFor: const [
          ExpenseShare(participantId: 'bea', shares: 100),
          ExpenseShare(participantId: 'alex', shares: 100),
          ExpenseShare(participantId: 'cid', shares: 200),
        ],
        splitMode: SplitMode.evenly,
        date: DateTime.utc(2026, 9, 16),
      );

      final balances = computeBalances(participants, [expense]);
      final byId = {for (final b in balances) b.participantId: b.netCents};

      // A true equal three-way split of $334.00 is ~$111.33 each
      // (largest-remainder rounding settles the odd cent on whichever
      // participant the tie-break lands on -- not asserted exactly
      // here), NOT weighted 100/100/200, which would have put Cid at
      // exactly double what Alex/Bea owed -- the actual bug reported in
      // #20.
      expect(byId['bea'], inInclusiveRange(-11134, -11133));
      expect(byId['cid'], inInclusiveRange(-11134, -11133));
      // The old (buggy) weighted math put Cid at roughly -16700 (double
      // Bea's share) -- assert we're nowhere near that.
      expect((byId['bea']! - byId['cid']!).abs(), lessThanOrEqualTo(1));
      expect(byId['alex'], greaterThan(0));
      final owedSum = balances.fold<int>(0, (sum, b) => sum + b.netCents);
      expect(owedSum, 0);
    });

    test('byAmount split uses each share as exact cents, not a proportion', () {
      final expense = Expense(
        id: 'e2',
        groupId: 'g1',
        title: 'Dinner',
        amountCents: 5000,
        paidBy: 'alex',
        paidFor: const [
          ExpenseShare(participantId: 'bea', shares: 3000),
          ExpenseShare(participantId: 'cid', shares: 2000),
        ],
        splitMode: SplitMode.byAmount,
        date: DateTime.utc(2026, 9, 16),
      );
      final balances = computeBalances(participants, [expense]);
      final byId = {for (final b in balances) b.participantId: b.netCents};
      expect(byId['alex'], 5000);
      expect(byId['bea'], -3000);
      expect(byId['cid'], -2000);
    });

    test('byShares split is proportional to each participant\'s weight', () {
      final expense = Expense(
        id: 'e3',
        groupId: 'g1',
        title: 'Rent',
        amountCents: 9000,
        paidBy: 'alex',
        paidFor: const [
          ExpenseShare(participantId: 'alex', shares: 2),
          ExpenseShare(participantId: 'bea', shares: 1),
        ],
        splitMode: SplitMode.byShares,
        date: DateTime.utc(2026, 9, 16),
      );
      final balances = computeBalances([alex, bea], [expense]);
      final byId = {for (final b in balances) b.participantId: b.netCents};
      // Alex paid 9000, owes 2/3 (6000) of it himself -> net +3000.
      expect(byId['alex'], 3000);
      // Bea owes 1/3 (3000) and paid nothing -> net -3000.
      expect(byId['bea'], -3000);
    });

    test('a reimbursement expense needs no special-casing to net out correctly', () {
      // Bea settles her $30 debt to Alex: paidBy=Bea, sole paidFor=Alex --
      // exactly the shape the web app's "Mark as paid" link produces
      // (see decisions/feature-backlog.md).
      final settlement = Expense(
        id: 'settle-1',
        groupId: 'g1',
        title: 'Reimbursement',
        amountCents: 3000,
        paidBy: 'bea',
        paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
        isReimbursement: true,
        date: DateTime.utc(2026, 9, 16),
      );
      final balances =
          computeBalances(participants, [evenExpense(amountCents: 9000), settlement]);
      final byId = {for (final b in balances) b.participantId: b.netCents};
      expect(byId['bea'], 0);
      expect(byId['alex'], 3000);
      expect(byId['cid'], -3000);
    });

    test('a pending (not-yet-synced) expense counts toward balances too', () {
      final pending = evenExpense(amountCents: 3000);
      final balances = computeBalances(participants, [
        Expense(
          id: pending.id,
          groupId: pending.groupId,
          title: pending.title,
          amountCents: pending.amountCents,
          paidBy: pending.paidBy,
          paidFor: pending.paidFor,
          date: pending.date,
          pending: true,
        ),
      ]);
      final byId = {for (final b in balances) b.participantId: b.netCents};
      expect(byId['alex'], 2000);
    });
  });

  group('suggestSettlements', () {
    test('suggests minimal transfers from each debtor to the single creditor', () {
      final balances = computeBalances(participants, [evenExpense(amountCents: 9000)]);
      final settlements = suggestSettlements(balances);
      expect(settlements, hasLength(2));
      expect(
        settlements.map((s) => (s.fromId, s.toId, s.amountCents)),
        containsAll([('bea', 'alex', 3000), ('cid', 'alex', 3000)]),
      );
    });

    test('nets to nothing when everyone is already even', () {
      final balances = [
        for (final p in participants) Balance(participantId: p.id, netCents: 0),
      ];
      expect(suggestSettlements(balances), isEmpty);
    });
  });
}
