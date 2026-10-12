import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/expense.dart';

// Issue #237: the expense list sends neither notes nor the rate, so the
// cache knows them only once an expense is read in full, until the next
// refresh.
void main() {
  Expense expense(String id, {String notes = '', double? rate, bool pending = false, int documents = 0}) =>
      Expense(
        id: id,
        groupId: 'g1',
        title: id,
        amountCents: 100,
        paidBy: 'p1',
        paidFor: const [],
        notes: notes,
        date: DateTime(2026, 10, 1),
        originalAmountCents: rate == null ? null : 80,
        originalCurrency: rate == null ? null : 'EUR',
        conversionRate: rate,
        pending: pending,
        documentCount: documents,
      );

  const receipt = ExpenseDocument(id: 'd1', url: 'https://bucket.test/d1.jpg', width: 600, height: 900);

  Future<Expense> cached(AppDatabase db, String id) async =>
      db.rowToExpense((await db.expensesForGroup('g1')).firstWhere((r) => r.id == id));

  test('a full read stores the notes, the rate and the documents, and marks them known', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.replaceServerExpenses('g1', [expense('e1', documents: 1)]);
    expect((await cached(db, 'e1')).detailsFetchedAt, isNull);

    final fresh = Expense(
      id: 'e1',
      groupId: 'g1',
      title: 'e1',
      amountCents: 100,
      paidBy: 'p1',
      paidFor: const [],
      notes: 'Split the tip',
      date: DateTime(2026, 10, 1),
      conversionRate: 1.25,
      documents: const [receipt],
    );
    await db.cacheExpenseDetails('g1', fresh, at: DateTime(2026, 10, 12));

    final e = await cached(db, 'e1');
    expect(e.notes, 'Split the tip');
    expect(e.conversionRate, 1.25);
    expect(e.detailsFetchedAt, DateTime(2026, 10, 12));
    expect((await db.watchExpenseDocuments('e1').first).map((d) => d.id), ['d1']);
  });

  test('a refresh clears them again: the list doesn\'t send them', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.replaceServerExpenses('g1', [expense('e1')]);
    await db.cacheExpenseDetails('g1', expense('e1', notes: 'Split the tip', rate: 1.25));

    await db.replaceServerExpenses('g1', [expense('e1')]);

    final e = await cached(db, 'e1');
    expect(e.notes, '');
    expect(e.conversionRate, isNull);
    expect(e.detailsFetchedAt, isNull);
  });

  test('a pending expense keeps its own', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.insertPending(expense('local-1', notes: 'Mine', pending: true));

    await db.cacheExpenseDetails('g1', expense('local-1', notes: 'Theirs'));

    final e = await cached(db, 'local-1');
    expect(e.notes, 'Mine');
    expect(e.detailsFetchedAt, isNull);
  });

  test('once synced, a pending expense\'s details are known: they\'re what it sent', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.insertPending(expense('local-1', notes: 'Mine', pending: true));

    await db.markSynced(localId: 'local-1', serverId: 'e1');

    final e = await cached(db, 'e1');
    expect(e.notes, 'Mine');
    expect(e.detailsFetchedAt, isNotNull);
  });
}
