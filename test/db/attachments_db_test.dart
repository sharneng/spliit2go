import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';

// Issue #124: receipt photos not on their expense yet.
void main() {
  ReceiptAttachmentsCompanion attachment(String id, {String groupId = 'g1'}) =>
      ReceiptAttachmentsCompanion.insert(
        id: id,
        groupId: groupId,
        expenseId: 'e-$groupId',
        fileName: '$id.img',
        bytes: 3,
        width: 600,
        height: 900,
        state: AttachmentState.local,
        createdAt: DateTime(2026, 9, 27),
      );

  test('leaving a group removes its photos, and only its', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.addAttachments([attachment('a1'), attachment('a2', groupId: 'g2')]);

    await db.leaveGroup('g1');

    expect(await db.attachmentFileNames(), {'a2.img'});
  });

  test('failed ones wait for Retry; the rest are for the outbox', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.addAttachments([attachment('a1'), attachment('a2')]);
    await db.updateAttachment(
        'a2', const ReceiptAttachmentsCompanion(state: Value(AttachmentState.failed)));

    expect([for (final a in await db.attachmentsToSync('g1')) a.id], ['a1']);
    await db.retryAttachment('a2');
    expect([for (final a in await db.attachmentsToSync('g1')) a.id], ['a1', 'a2']);
  });

  test('a version 14 database migrates, with no photos waiting', () async {
    final dir = await Directory.systemTemp.createTemp('attachments-v14-migration-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.customStatement('DROP TABLE receipt_attachments');
    await old.customStatement('PRAGMA user_version = 14');
    await old.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.attachmentFileNames(), isEmpty);
    await db.addAttachments([attachment('a1')]);
    expect(await db.attachmentFileNames(), {'a1.img'});
  });
}
