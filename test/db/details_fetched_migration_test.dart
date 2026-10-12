import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/expense.dart';

// #237: schema 20 records when an expense's details were read in full.
void main() {
  test('a schema 19 database keeps its expenses, with their details unknown', () async {
    final dir = await Directory.systemTemp.createTemp('details_fetched_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');

    // Schema 19 is today's without the column.
    final current = AppDatabase(NativeDatabase(file));
    await current.replaceServerExpenses('g1', [
      Expense(id: 'e1', groupId: 'g1', title: 'Lunch', amountCents: 100, paidBy: 'p1', paidFor: const [],
          date: DateTime(2026, 10, 1)),
    ]);
    await current.customStatement('ALTER TABLE expenses DROP COLUMN details_fetched_at');
    await current.customStatement('PRAGMA user_version = 19');
    await current.close();

    final migrated = AppDatabase(NativeDatabase(file));
    addTearDown(migrated.close);
    final row = (await migrated.expensesForGroup('g1')).single;
    expect(row.title, 'Lunch');
    expect(row.detailsFetchedAt, isNull);
  });
}
