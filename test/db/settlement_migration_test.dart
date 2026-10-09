import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/expense.dart';

// #242: schema 18 renames expenses.is_reimbursement to is_settlement,
// keeping the flag on cached and pending settlements alike.
void main() {
  test('a schema 17 database keeps its settlements, cached and pending', () async {
    final dir = await Directory.systemTemp.createTemp('settlement_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');

    Expense expense(String id, {required bool settlement}) => Expense(
          id: id,
          groupId: 'g1',
          title: id,
          amountCents: 1000,
          paidBy: 'alex',
          paidFor: const [ExpenseShare(participantId: 'bea', shares: 1)],
          isSettlement: settlement,
          date: DateTime.utc(2026, 9, 1),
        );

    // Schema 17 is today's but for the column's old name: build today's,
    // then take it back.
    final current = AppDatabase(NativeDatabase(file));
    await current.replaceServerExpenses('g1', [expense('paid', settlement: true), expense('dinner', settlement: false)]);
    await current.insertPending(expense('pending', settlement: true));
    await current.customStatement('ALTER TABLE expenses RENAME COLUMN is_settlement TO is_reimbursement');
    await current.customStatement('PRAGMA user_version = 17');
    await current.close();

    final migrated = AppDatabase(NativeDatabase(file));
    addTearDown(migrated.close);
    final columns = {
      for (final c in await migrated.customSelect('PRAGMA table_info(expenses)').get()) c.read<String>('name'),
    };
    expect(columns, contains('is_settlement'));
    expect(columns, isNot(contains('is_reimbursement')));
    final rows = {for (final r in await migrated.expensesForGroup('g1')) r.id: r.isSettlement};
    expect(rows, {'paid': true, 'dinner': false, 'pending': true});
  });
}
