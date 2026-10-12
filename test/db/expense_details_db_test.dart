import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/models/group_organization.dart';

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
    expect(e.documentCount, 1);
  });

  test('a full read\'s documents set the count: the list\'s may be older (PR #302 review)', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.replaceServerExpenses('g1', [expense('e1', documents: 2)]);

    await db.cacheExpenseDetails('g1', expense('e1'));

    expect((await cached(db, 'e1')).documentCount, 0);
  });

  test('a refresh clears them again in a group that isn\'t a favorite: the list doesn\'t send them',
      () async {
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

  group('a favorite keeps them through a refresh', () {
    Future<AppDatabase> favoriteWithNotes() async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.cacheGroup(const Group(id: 'g1', name: 'Banff Trip', currency: '\$', participants: []));
      await db.setGroupOrganization('g1', GroupOrganization.favorite);
      await db.replaceServerExpenses('g1', [expense('e1'), expense('e2')]);
      await db.cacheExpenseDetails('g1', expense('e1', notes: 'Split the tip', rate: 1.25));
      return db;
    }

    test('kept: the receipt downloader reads what changed', () async {
      final db = await favoriteWithNotes();
      addTearDown(db.close);

      await db.replaceServerExpenses('g1', [expense('e1'), expense('e2')]);

      final e = await cached(db, 'e1');
      expect((e.notes, e.conversionRate), ('Split the tip', 1.25));
      expect(e.detailsFetchedAt, isNotNull);
      expect(await db.expensesWithUnknownDetails('g1'), ['e2']);
    });

    test('not on a server without an activity log', () async {
      final db = await favoriteWithNotes();
      addTearDown(db.close);
      await db.setReceiptDownloadProblem('g1', AppDatabase.noActivityLog);

      await db.replaceServerExpenses('g1', [expense('e1')]);

      expect((await cached(db, 'e1')).detailsFetchedAt, isNull);
    });

    test('forgotten, one or all, they\'re read again', () async {
      final db = await favoriteWithNotes();
      addTearDown(db.close);
      await db.cacheExpenseDetails('g1', expense('e2'));

      await db.forgetExpenseDetails('g1', ids: ['e2']);
      expect(await db.expensesWithUnknownDetails('g1'), ['e2']);
      await db.forgetExpenseDetails('g1');
      expect(await db.expensesWithUnknownDetails('g1'), unorderedEquals(['e1', 'e2']));
    });
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
