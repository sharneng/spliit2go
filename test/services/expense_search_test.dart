import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/services/expense_search.dart';

// Issue #39: search matches titles, case-insensitively, like Spliit's
// server-side filter (`contains`, `mode: 'insensitive'`).
void main() {
  Expense expense(String id, String title, {String notes = ''}) => Expense(
        id: id,
        groupId: 'g1',
        title: title,
        amountCents: 100,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        notes: notes,
        date: DateTime(2026, 9, 1),
      );

  final expenses = [
    expense('1', 'Dinner at Lupo'),
    expense('2', 'Groceries', notes: 'dinner supplies'),
    expense('3', 'Late DINNER'),
    expense('4', 'Café au lait'),
  ];

  List<String> ids(List<Expense> list) => [for (final e in list) e.id];

  test('matches part of a title, ignoring case, in the original order', () {
    expect(ids(searchExpenses(expenses, 'dinner')), ['1', '3']);
    expect(ids(searchExpenses(expenses, 'NER AT')), ['1']);
  });

  test('matches titles only, not notes', () {
    expect(ids(searchExpenses(expenses, 'supplies')), isEmpty);
  });

  test('ignores whitespace around the query but not inside it', () {
    expect(ids(searchExpenses(expenses, '  lupo ')), ['1']);
    expect(ids(searchExpenses(expenses, 'dinner  at')), isEmpty);
  });

  test('matches accented text as typed', () {
    expect(ids(searchExpenses(expenses, 'CAFÉ')), ['4']);
  });

  test('a blank query matches nothing', () {
    expect(searchExpenses(expenses, ''), isEmpty);
    expect(searchExpenses(expenses, '   '), isEmpty);
  });
}
