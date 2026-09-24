import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/expense.dart';

// Issue #92: a pending expense remembers who added it, so the outbox
// credits them in Spliit's activity log when it finally syncs.
void main() {
  final pending = Expense(
      id: 'local-1',
      groupId: 'g1',
      title: 'Dinner',
      amountCents: 100,
      paidBy: 'p1',
      paidFor: const [],
      date: DateTime(2026, 9, 23),
      pending: true);

  test('a pending expense stores who added it', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.insertPending(pending, addedByParticipantId: 'p2');
    expect((await db.pendingExpensesForGroup('g1')).single.addedByParticipantId, 'p2');
  });

  test('with no active user it stores nobody', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.insertPending(pending);
    expect((await db.pendingExpensesForGroup('g1')).single.addedByParticipantId, isNull);
  });

  test('a version 10 cache migrates, keeping a queued expense with nobody credited', () async {
    final dir = await Directory.systemTemp.createTemp('expense-attribution-migration-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.insertPending(pending);
    await old.customStatement(
        'ALTER TABLE expenses DROP COLUMN added_by_participant_id');
    await old.customStatement('PRAGMA user_version = 10');
    await old.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final row = (await db.pendingExpensesForGroup('g1')).single;
    expect(row.id, 'local-1');
    expect(row.pending, isTrue);
    expect(row.addedByParticipantId, isNull);
  });
}
