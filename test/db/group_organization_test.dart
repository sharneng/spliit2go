import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/models/expense.dart';

void main() {
  test(
      'organization survives refresh; archive preserves pending expenses and skips startup',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final created = DateTime.utc(2025, 2, 3);
    await db.cacheGroup(Group(
        id: 'a',
        name: 'Trip',
        currency: r'$',
        participants: [],
        createdAt: created));
    await db.recordGroupOpened('a', serverUrl: 'https://example.test');
    await db.insertPending(Expense(
        id: 'e',
        groupId: 'a',
        title: 'Pending',
        amountCents: 100,
        paidBy: 'p',
        paidFor: const [],
        pending: true,
        date: DateTime(2026)));
    await db.setGroupOrganization('a', favorite: true, archived: true);
    await db.cacheGroup(
        const Group(id: 'a', name: 'Renamed', currency: '€', participants: []));
    final row = (await db.groupRow('a'))!;
    expect(row.isFavorite, isTrue);
    expect(row.isArchived, isTrue);
    expect(row.createdAt!.isAtSameMomentAs(created), isTrue);
    expect(await db.mostRecentlyOpenedGroup(), isNull);
    expect(await db.pendingExpensesForGroup('a'), hasLength(1));
    expect(await db.allJoinedGroups(), hasLength(1));
    await db.setGroupOrganization('a', archived: false);
    expect((await db.mostRecentlyOpenedGroup())!.id, 'a');
    expect((await db.cachedGroup('a'))!.createdAt!.isAtSameMomentAs(created),
        isTrue);
  });

  test('version 7 cache migrates without losing group data', () async {
    final dir = await Directory.systemTemp.createTemp('group-migration-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    await old.cacheGroup(const Group(
        id: 'a', name: 'Existing', currency: r'$', participants: []));
    await old.recordGroupOpened('a', serverUrl: 'https://example.test');
    // Reconstruct the actual v7 table by removing only the v8 additions.
    for (final column in ['created_at', 'is_favorite', 'is_archived']) {
      await old.customStatement('ALTER TABLE groups DROP COLUMN $column');
    }
    await old.customStatement('PRAGMA user_version = 7');
    await old.close();
    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final row = (await db.groupRow('a'))!;
    expect(row.name, 'Existing');
    expect(row.createdAt, isNull);
    expect(row.isFavorite, isFalse);
    expect(row.isArchived, isFalse);
    await db.setGroupOrganization('a', favorite: true);
    expect((await db.groupRow('a'))!.isFavorite, isTrue);
  });
}
