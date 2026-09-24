import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/expense.dart';

// Issue #88: same-day expenses are ordered newest-created first, like
// Spliit's own list (expenseDate desc, then createdAt desc).
void main() {
  Expense expense(String id, DateTime date, {DateTime? createdAt, bool pending = false}) => Expense(
      id: id,
      groupId: 'g1',
      title: id,
      amountCents: 100,
      paidBy: 'p1',
      paidFor: const [],
      date: date,
      createdAt: createdAt,
      pending: pending);

  test('orders by date, then creation time, newest first; unknown creation time last', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final day = DateTime(2026, 9, 20);
    await db.replaceServerExpenses('g1', [
      expense('same-day-early', day, createdAt: DateTime.utc(2026, 9, 20, 8)),
      expense('same-day-unknown', day),
      expense('earlier-day', DateTime(2026, 9, 19), createdAt: DateTime.utc(2026, 9, 21)),
      expense('same-day-late', day, createdAt: DateTime.utc(2026, 9, 20, 18)),
    ]);
    await db.insertPending(
        expense('same-day-offline', day, createdAt: DateTime.utc(2026, 9, 22), pending: true));

    final expected = [
      'same-day-offline',
      'same-day-late',
      'same-day-early',
      'same-day-unknown',
      'earlier-day',
    ];
    expect((await db.expensesForGroup('g1')).map((r) => r.id), expected);
    expect((await db.watchExpensesForGroup('g1').first).map((r) => r.id), expected);
  });

  test('an offline expense that kept its time of day still ties on the calendar day (#89 review)',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    // Fetched: dated at midnight, created at noon.
    await db.replaceServerExpenses('g1', [
      expense('server', DateTime(2026, 9, 23), createdAt: DateTime(2026, 9, 23, 12)),
      expense('next-day', DateTime(2026, 9, 24), createdAt: DateTime(2026, 9, 24, 1)),
    ]);
    // Added offline earlier that morning, so its date carries 10:00.
    await db.insertPending(expense('offline', DateTime(2026, 9, 23, 10),
        createdAt: DateTime(2026, 9, 23, 10), pending: true));

    const expected = ['next-day', 'server', 'offline'];
    expect((await db.expensesForGroup('g1')).map((r) => r.id), expected);
    expect((await db.watchExpensesForGroup('g1').first).map((r) => r.id), expected);
  });

  test('createdAt round-trips through the cache', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final created = DateTime.utc(2026, 9, 20, 8, 30, 15);
    await db.replaceServerExpenses('g1', [expense('e1', DateTime(2026, 9, 20), createdAt: created)]);

    final back = db.rowToExpense((await db.expensesForGroup('g1')).single);
    expect(back.createdAt!.isAtSameMomentAs(created), isTrue);
  });

  test('a version 9 cache migrates, keeping its expenses with no creation time yet', () async {
    final dir = await Directory.systemTemp.createTemp('expense-created-at-migration-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.replaceServerExpenses('g1', [expense('e1', DateTime(2026, 9, 20))]);
    await old.customStatement('ALTER TABLE expenses DROP COLUMN created_at');
    await old.customStatement('PRAGMA user_version = 9');
    await old.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final row = (await db.expensesForGroup('g1')).single;
    expect(row.id, 'e1');
    expect(row.createdAt, isNull);
  });
}
