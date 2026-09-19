import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/services/date_span_calculator.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Expense expense(String id, DateTime date, {bool isReimbursement = false}) => Expense(
        id: id,
        groupId: 'g1',
        title: 'Coffee',
        amountCents: 500,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        date: date,
        isReimbursement: isReimbursement,
        pending: true,
      );

  test('returns null for an empty list', () {
    expect(computeDateSpan([]), isNull);
  });

  test('a single expense spans just its own date', () async {
    await db.insertPending(expense('e1', DateTime.utc(2026, 3, 5)));
    final rows = await db.expensesForGroup('g1');

    final span = computeDateSpan(rows);

    expect(span!.first, DateTime.utc(2026, 3, 5));
    expect(span.last, DateTime.utc(2026, 3, 5));
  });

  test('spans from the earliest to the latest date regardless of insertion order', () async {
    await db.insertPending(expense('e1', DateTime.utc(2026, 6, 15)));
    await db.insertPending(expense('e2', DateTime.utc(2026, 1, 2)));
    await db.insertPending(expense('e3', DateTime.utc(2026, 3, 20)));
    final rows = await db.expensesForGroup('g1');

    final span = computeDateSpan(rows);

    expect(span!.first, DateTime.utc(2026, 1, 2));
    expect(span.last, DateTime.utc(2026, 6, 15));
  });

  // Unlike SpendingSummary's firstDate/lastDate (stats_calculator.dart),
  // which deliberately excludes reimbursements as "not new spending",
  // computeDateSpan counts every cached expense -- a settlement is still
  // a dated event in the group's history (issue #55 defines the span as
  // "first expense date to last expense date", with no carve-out for
  // reimbursements).
  test('includes reimbursement expenses in the span, unlike the spending summary', () async {
    await db.insertPending(expense('e1', DateTime.utc(2026, 2, 1)));
    await db.insertPending(
        expense('e2', DateTime.utc(2026, 8, 30), isReimbursement: true));
    final rows = await db.expensesForGroup('g1');

    final span = computeDateSpan(rows);

    expect(span!.first, DateTime.utc(2026, 2, 1));
    expect(span.last, DateTime.utc(2026, 8, 30));
  });
}
