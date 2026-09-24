import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/models/group_organization.dart';
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
    await db.setGroupOrganization('a', GroupOrganization.archived);
    await db.cacheGroup(
        const Group(id: 'a', name: 'Renamed', currency: '€', participants: []));
    final row = (await db.groupRow('a'))!;
    expect(row.organization, GroupOrganization.archived);
    expect(row.createdAt!.isAtSameMomentAs(created), isTrue);
    expect(await db.mostRecentlyOpenedGroup(), isNull);
    expect(await db.pendingExpensesForGroup('a'), hasLength(1));
    expect(await db.allJoinedGroups(), hasLength(1));
    await db.setGroupOrganization('a', GroupOrganization.active);
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
    // Reconstruct the actual v7 table by removing the creation timestamp and organization column.
    for (final column in ['created_at', 'organization']) {
      await old.customStatement('ALTER TABLE groups DROP COLUMN $column');
    }
    await old.customStatement('ALTER TABLE expenses DROP COLUMN created_at');
    await old.customStatement(
        'ALTER TABLE expenses DROP COLUMN added_by_participant_id');
    await old.customStatement('PRAGMA user_version = 7');
    await old.close();
    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final row = (await db.groupRow('a'))!;
    expect(row.name, 'Existing');
    expect(row.createdAt, isNull);
    expect(row.organization, GroupOrganization.active);
    await db.setGroupOrganization('a', GroupOrganization.favorite);
    expect((await db.groupRow('a'))!.organization, GroupOrganization.favorite);
  });
  test('v8 flags migrate to exclusive states and obsolete columns are removed',
      () async {
    final dir = await Directory.systemTemp.createTemp('group-v8-migration-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    final old = AppDatabase(NativeDatabase(file));
    for (final id in ['active', 'favorite', 'archived', 'both']) {
      await old.cacheGroup(Group(
          id: id,
          name: id,
          currency: r'$',
          participants: const [Participant(id: 'p', name: 'Person')],
          createdAt: DateTime.utc(2025, 1, 2)));
      await old.recordGroupOpened(id, serverUrl: 'https://example.test');
    }
    await old.insertPending(Expense(
        id: 'pending',
        groupId: 'both',
        title: 'Offline',
        amountCents: 1250,
        paidBy: 'p',
        paidFor: const [],
        pending: true,
        date: DateTime(2026)));
    await old.customStatement('ALTER TABLE groups DROP COLUMN organization');
    await old.customStatement('ALTER TABLE expenses DROP COLUMN created_at');
    await old.customStatement(
        'ALTER TABLE expenses DROP COLUMN added_by_participant_id');
    await old.customStatement(
        'ALTER TABLE groups ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0');
    await old.customStatement(
        'ALTER TABLE groups ADD COLUMN is_archived INTEGER NOT NULL DEFAULT 0');
    await old.customStatement(
        "UPDATE groups SET is_favorite = 1 WHERE id IN ('favorite', 'both')");
    await old.customStatement(
        "UPDATE groups SET is_archived = 1 WHERE id IN ('archived', 'both')");
    await old.customStatement('PRAGMA user_version = 8');
    await old.close();
    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    for (final entry in {
      'active': GroupOrganization.active,
      'favorite': GroupOrganization.favorite,
      'archived': GroupOrganization.archived,
      'both': GroupOrganization.archived,
    }.entries) {
      final row = (await db.groupRow(entry.key))!;
      expect(row.organization, entry.value);
      expect(row.createdAt!.isAtSameMomentAs(DateTime.utc(2025, 1, 2)), isTrue);
      expect(row.serverUrl, 'https://example.test');
      expect(row.lastOpenedAt, isNotNull);
      expect((await db.cachedGroup(entry.key))!.participants.single.name,
          'Person');
    }
    expect((await db.pendingExpensesForGroup('both')).single.amountCents, 1250);
    final columns = await db.customSelect('PRAGMA table_info(groups)').get();
    expect(columns.map((row) => row.read<String>('name')),
        isNot(anyOf(contains('is_favorite'), contains('is_archived'))));
    await db.setGroupOrganization('both', GroupOrganization.active);
    expect((await db.groupRow('both'))!.organization, GroupOrganization.active);
  });
}
