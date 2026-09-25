import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/services/stats_calculator.dart';

void main() {
  const alex = Participant(id: 'alex', name: 'Alex');
  const bea = Participant(id: 'bea', name: 'Bea');
  const cid = Participant(id: 'cid', name: 'Cid');
  final participants = [alex, bea, cid];

  Expense evenExpense({
    required String id,
    required int amountCents,
    required String paidBy,
    required DateTime date,
    String title = 'Groceries',
    int category = 0,
  }) =>
      Expense(
        id: id,
        groupId: 'g1',
        title: title,
        amountCents: amountCents,
        paidBy: paidBy,
        paidFor: const [
          ExpenseShare(participantId: 'alex', shares: 1),
          ExpenseShare(participantId: 'bea', shares: 1),
          ExpenseShare(participantId: 'cid', shares: 1),
        ],
        date: date,
        category: category,
      );

  group('totalGroupSpendingCents', () {
    test('sums non-reimbursement expenses only', () {
      final expenses = [
        evenExpense(id: 'e1', amountCents: 9000, paidBy: 'alex', date: DateTime.utc(2026, 9, 1)),
        Expense(
          id: 'e2',
          groupId: 'g1',
          title: 'settle up',
          amountCents: 3000,
          paidBy: 'bea',
          paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
          date: DateTime.utc(2026, 9, 2),
          isReimbursement: true,
        ),
      ];
      expect(totalGroupSpendingCents(expenses), 9000);
    });
  });

  group('computeParticipantSpending', () {
    test('tracks paid, paidCount, and share per participant, sorted by amount paid', () {
      final expenses = [
        evenExpense(id: 'e1', amountCents: 9000, paidBy: 'alex', date: DateTime.utc(2026, 9, 1)),
        evenExpense(id: 'e2', amountCents: 3000, paidBy: 'bea', date: DateTime.utc(2026, 9, 2)),
      ];
      final result = computeParticipantSpending(participants, expenses);

      expect(result.map((p) => p.participantId), ['alex', 'bea', 'cid']);
      final byId = {for (final p in result) p.participantId: p};
      expect(byId['alex']!.paidCents, 9000);
      expect(byId['alex']!.paidCount, 1);
      expect(byId['bea']!.paidCents, 3000);
      expect(byId['bea']!.paidCount, 1);
      expect(byId['cid']!.paidCents, 0);
      expect(byId['cid']!.paidCount, 0);
      // Each expense split evenly 3 ways: total share per participant is
      // a third of (9000 + 3000) = 4000.
      expect(byId['alex']!.shareCents, 4000);
      expect(byId['bea']!.shareCents, 4000);
      expect(byId['cid']!.shareCents, 4000);
    });

    test('an expense paid by someone outside the current participant list is dropped, not crashed on', () {
      final expenses = [
        evenExpense(id: 'e1', amountCents: 9000, paidBy: 'former-member', date: DateTime.utc(2026, 9, 1)),
      ];
      final result = computeParticipantSpending(participants, expenses);
      expect(result.every((p) => p.paidCents == 0), isTrue);
    });
  });

  group('computeCategorySpending', () {
    test('aggregates by category, drops zero totals, sorts highest first', () {
      final expenses = [
        evenExpense(id: 'e1', amountCents: 9000, paidBy: 'alex', date: DateTime.utc(2026, 9, 1), category: 9),
        evenExpense(id: 'e2', amountCents: 3000, paidBy: 'bea', date: DateTime.utc(2026, 9, 2), category: 9),
        evenExpense(id: 'e3', amountCents: 15000, paidBy: 'cid', date: DateTime.utc(2026, 9, 3), category: 4),
      ];
      final result = computeCategorySpending(expenses);
      expect(result.length, 2);
      expect(result[0].categoryId, 4);
      expect(result[0].totalCents, 15000);
      expect(result[1].categoryId, 9);
      expect(result[1].totalCents, 12000);
    });
  });
}
