import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/expense.dart';

// Issue #124: a pending expense's receipt photos.
void main() {
  Expense pending(String id, String groupId) => Expense(
        id: id,
        groupId: groupId,
        title: 'Coffee',
        amountCents: 500,
        paidBy: 'p1',
        paidFor: const [],
        date: DateTime(2026, 9, 27),
        pending: true,
      );

  ReceiptAttachmentsCompanion photo(String id, String expenseId, String groupId) =>
      ReceiptAttachmentsCompanion.insert(
        id: id,
        groupId: groupId,
        expenseId: expenseId,
        fileName: '$id.img',
        bytes: 3,
        width: 600,
        height: 900,
        state: AttachmentState.local,
        createdAt: DateTime(2026, 9, 27),
      );

  test('stored with their expense, and leaving the group removes them (only its)', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.insertPending(pending('e1', 'g1'), attachments: [photo('a1', 'e1', 'g1')]);
    await db.insertPending(pending('e2', 'g2'), attachments: [photo('a2', 'e2', 'g2')]);

    await db.leaveGroup('g1');

    expect(await db.attachmentFileNames(), {'a2.img'});
  });

  test('Retry keeps them; Sync without receipts drops them', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.insertPending(pending('e1', 'g1'), attachments: [photo('a1', 'e1', 'g1')]);
    await db.insertPending(pending('e2', 'g1'), attachments: [photo('a2', 'e2', 'g1')]);
    for (final id in ['e1', 'e2']) {
      await db.recordSyncFailure(id: id, error: 'x', retryCount: 1, failed: true);
    }

    expect(await db.retrySyncFailure('e1'), isTrue);
    expect(await db.retrySyncFailure('e2', withoutReceipts: true), isTrue);

    expect(await db.attachmentsFor('e1'), hasLength(1));
    expect(await db.attachmentsFor('e2'), isEmpty);
  });

  test('a stale Sync without receipts on an expense no longer failed keeps them', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.insertPending(pending('e1', 'g1'), attachments: [photo('a1', 'e1', 'g1')]);

    expect(await db.retrySyncFailure('e1', withoutReceipts: true), isFalse);
    expect(await db.attachmentsFor('e1'), hasLength(1));
  });

  test('a version 14 database migrates, with no photos waiting', () async {
    final dir = await Directory.systemTemp.createTemp('attachments-v14-migration-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.customStatement('DROP TABLE receipt_attachments');
    await old.customStatement('ALTER TABLE groups DROP COLUMN receipt_download_problem');
    await old.customStatement('PRAGMA user_version = 14');
    await old.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.attachmentFileNames(), isEmpty);
    await db.insertPending(pending('e1', 'g1'), attachments: [photo('a1', 'e1', 'g1')]);
    expect(await db.attachmentFileNames(), {'a1.img'});
  });
}
