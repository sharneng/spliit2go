import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/group.dart';

// #301: schema 21 records when a group last refreshed.
void main() {
  test('a schema 20 database keeps its groups, never refreshed so far', () async {
    final dir = await Directory.systemTemp.createTemp('group_refreshed_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');

    // Schema 20 is today's without the column.
    final current = AppDatabase(NativeDatabase(file));
    await current.cacheGroup(const Group(id: 'g1', name: 'Banff Trip', currency: '\$', participants: []));
    await current.customStatement('ALTER TABLE "groups" DROP COLUMN refreshed_at');
    await current.customStatement('PRAGMA user_version = 20');
    await current.close();

    final migrated = AppDatabase(NativeDatabase(file));
    addTearDown(migrated.close);
    final row = await migrated.groupRow('g1');
    expect(row!.name, 'Banff Trip');
    expect(row.refreshedAt, isNull);

    await migrated.setGroupRefreshed('g1', at: DateTime(2026, 10, 13));
    expect((await migrated.groupRow('g1'))!.refreshedAt, DateTime(2026, 10, 13));
  });
}
