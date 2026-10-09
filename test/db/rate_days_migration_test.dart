import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';

// #252: schema 19 adds the exchange-rate cache.
void main() {
  test('a schema 18 database gains an empty rate cache', () async {
    final dir = await Directory.systemTemp.createTemp('rate_days_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');

    // Schema 18 is today's without the table.
    final current = AppDatabase(NativeDatabase(file));
    await current.customStatement('DROP TABLE rate_days');
    await current.customStatement('PRAGMA user_version = 18');
    await current.close();

    final migrated = AppDatabase(NativeDatabase(file));
    addTearDown(migrated.close);
    expect(await migrated.allRateDays(), isEmpty);
    final row = RateDayRow(
      day: '2026-10-04',
      source: 'ecb',
      perEuroJson: '{"USD":1.1225}',
      publishedOn: '2026-10-02',
      publishedOnExceptionsJson: '{}',
      fetchedAt: DateTime.utc(2026, 10, 9),
    );
    await migrated.saveRateDay(row);
    expect((await migrated.rateDay('2026-10-04', 'ecb'))!.perEuroJson, '{"USD":1.1225}');
  });
}
