import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';

// Issue #123: what the cache knows about an expense's receipts, and when
// it stops knowing it.
void main() {
  Expense expense(String id, {String groupId = 'g1', int documents = 0}) => Expense(
        id: id,
        groupId: groupId,
        title: id,
        amountCents: 100,
        paidBy: 'p1',
        paidFor: const [],
        date: DateTime(2026, 9, 20),
        documentCount: documents,
      );

  ExpenseDocument doc(String id) =>
      ExpenseDocument(id: id, url: 'https://bucket.test/$id.jpg', width: 600, height: 900);

  Future<void> storeFile(AppDatabase db, String url, {String groupId = 'g1'}) =>
      db.saveReceiptFile(ReceiptFilesCompanion.insert(
        url: url,
        groupId: groupId,
        fileName: '${url.hashCode}.img',
        bytes: 10,
        kind: ReceiptFileKind.viewing,
        lastUsedAt: DateTime(2026, 9, 27),
      ));

  Future<Set<String>> storedUrls(AppDatabase db) async =>
      {for (final f in await db.allReceiptFiles()) f.url};

  test('the list\'s document count is cached with each expense', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.replaceServerExpenses('g1', [expense('e1', documents: 2), expense('e2')]);

    final rows = await db.expensesForGroup('g1');
    expect({for (final r in rows) r.id: db.rowToExpense(r).documentCount}, {'e1': 2, 'e2': 0});
  });

  test('stored documents come back in the server\'s order', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheExpenseDocuments('g1', 'e1', [doc('b'), doc('a')]);

    expect((await db.watchExpenseDocuments('e1').first).map((d) => d.id), ['b', 'a']);

    // Storing again replaces them.
    await db.cacheExpenseDocuments('g1', 'e1', [doc('c')]);
    expect((await db.watchExpenseDocuments('e1').first).map((d) => d.id), ['c']);
  });

  // #127: a changed count keeps the list, so unchanged receipts aren't
  // downloaded again; it's unknown until the expense is read again.
  test('a refresh keeps lists, even of changed counts, and drops those of expenses gone or emptied',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.replaceServerExpenses('g1', [
      expense('same', documents: 1),
      expense('changed', documents: 1),
      expense('emptied', documents: 1),
      expense('gone', documents: 1),
    ]);
    await db.replaceServerExpenses('g2', [expense('other', groupId: 'g2', documents: 1)]);
    for (final (group, id) in [
      ('g1', 'same'),
      ('g1', 'changed'),
      ('g1', 'emptied'),
      ('g1', 'gone'),
      ('g2', 'other'),
    ]) {
      await db.cacheExpenseDocuments(group, id, [doc(id)]);
      await storeFile(db, doc(id).url, groupId: group);
    }
    // A viewed receipt of an expense this device never cached (Activity).
    await storeFile(db, 'https://bucket.test/activity.jpg');

    await db.replaceServerExpenses('g1', [
      expense('same', documents: 1),
      expense('changed', documents: 2),
      expense('emptied', documents: 0),
    ]);

    expect((await db.watchExpenseDocuments('same').first).map((d) => d.id), ['same']);
    expect((await db.watchExpenseDocuments('changed').first).map((d) => d.id), ['changed']);
    expect(await db.expensesWithUnreadDocuments('g1'), ['changed']);
    expect(await db.watchExpenseDocuments('emptied').first, isEmpty);
    expect(await db.watchExpenseDocuments('gone').first, isEmpty);
    expect(await db.watchExpenseDocuments('other').first, hasLength(1));
    expect(await storedUrls(db), {doc('same').url, doc('changed').url, doc('other').url});
    // Only the known list counts as available.
    expect(await db.receiptAvailability('g1'), (total: 3, available: 1));
  });

  test('a deleted expense takes its documents and files with it', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.replaceServerExpenses('g1', [expense('e1', documents: 1), expense('e2', documents: 1)]);
    for (final id in ['e1', 'e2']) {
      await db.cacheExpenseDocuments('g1', id, [doc(id)]);
      await storeFile(db, doc(id).url);
    }

    await db.removeDeletedExpense('g1', 'e1');

    expect(await db.watchExpenseDocuments('e1').first, isEmpty);
    expect(await storedUrls(db), {doc('e2').url});
  });

  test('leaving a group forgets its documents and files, and only its own', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    for (final group in ['g1', 'g2']) {
      await db.cacheExpenseDocuments(group, 'e-$group', [doc(group)]);
      await storeFile(db, doc(group).url, groupId: group);
    }

    await db.leaveGroup('g1');

    expect(await db.watchExpenseDocuments('e-g1').first, isEmpty);
    expect(await storedUrls(db), {doc('g2').url});
  });

  test('a version 11 cache migrates: counts start at 0 until the next refresh', () async {
    final dir = await Directory.systemTemp.createTemp('receipts-migration-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.replaceServerExpenses('g1', [expense('e1', documents: 3)]);
    await old.customStatement('ALTER TABLE expenses DROP COLUMN documents_json');
    await old.customStatement('ALTER TABLE expenses DROP COLUMN document_count');
    await old.customStatement('DROP TABLE expense_documents');
    await old.customStatement('DROP TABLE receipt_files');
    await old.customStatement('DROP TABLE cached_categories');
    await old.customStatement('DROP TABLE receipt_attachments');
    await old.customStatement('ALTER TABLE groups DROP COLUMN receipt_download_problem');
    await old.customStatement('ALTER TABLE groups DROP COLUMN receipts_checked_activity_id');
    await old.customStatement('ALTER TABLE groups DROP COLUMN receipts_checked_at');
    await old.customStatement('PRAGMA user_version = 11');
    await old.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final row = (await db.expensesForGroup('g1')).single;
    expect(row.id, 'e1');
    expect(row.documentCount, 0);
    await db.cacheExpenseDocuments('g1', 'e1', [doc('d1')]);
    expect(await db.watchExpenseDocuments('e1').first, hasLength(1));
    expect(await db.allReceiptFiles(), isEmpty);
  });

  test('a version 12 cache migrates, keeping a queued expense with no receipts', () async {
    final dir = await Directory.systemTemp.createTemp('receipts-v12-migration-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.insertPending(Expense(
        id: 'local-1',
        groupId: 'g1',
        title: 'Coffee',
        amountCents: 100,
        paidBy: 'p1',
        paidFor: const [],
        date: DateTime(2026, 9, 23),
        pending: true));
    await old.customStatement('ALTER TABLE expenses DROP COLUMN documents_json');
    await old.customStatement('DROP TABLE cached_categories');
    await old.customStatement('DROP TABLE receipt_attachments');
    await old.customStatement('ALTER TABLE groups DROP COLUMN receipt_download_problem');
    await old.customStatement('ALTER TABLE groups DROP COLUMN receipts_checked_activity_id');
    await old.customStatement('ALTER TABLE groups DROP COLUMN receipts_checked_at');
    await old.customStatement('PRAGMA user_version = 12');
    await old.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final row = (await db.pendingExpensesForGroup('g1')).single;
    expect(row.documentsJson, isNull);
    expect(db.rowToExpense(row).documents, isEmpty);
  });

  // #203: a device that ran PR #144's first build is at version 16
  // without the activity-log columns.
  test('a version 16 cache missing the activity-log columns gets them', () async {
    final dir = await Directory.systemTemp.createTemp('receipts-v16-repair-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.cacheGroup(const Group(id: 'g1', name: 'Trip', currency: r'$', participants: []));
    await old.recordGroupOpened('g1', serverUrl: 'https://example.test');
    await old.customStatement('ALTER TABLE groups DROP COLUMN receipts_checked_activity_id');
    await old.customStatement('ALTER TABLE groups DROP COLUMN receipts_checked_at');
    await old.customStatement('PRAGMA user_version = 16');
    await old.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    await db.setReceiptsChecked('g1', activityId: 'a1', at: DateTime.utc(2026, 10, 6));
    final row = (await db.groupRow('g1'))!;
    expect(row.receiptsCheckedActivityId, 'a1');
    expect(row.serverUrl, 'https://example.test');
  });

  test('a complete version 16 cache upgrades untouched', () async {
    final dir = await Directory.systemTemp.createTemp('receipts-v16-upgrade-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.cacheGroup(const Group(id: 'g1', name: 'Trip', currency: r'$', participants: []));
    await old.recordGroupOpened('g1', serverUrl: 'https://example.test');
    await old.setReceiptsChecked('g1', activityId: 'a1', at: DateTime.utc(2026, 10, 6));
    await old.customStatement('PRAGMA user_version = 16');
    await old.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect((await db.groupRow('g1'))!.receiptsCheckedActivityId, 'a1');
  });
}
