import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/group_screen.dart';
import 'package:spliit2go/sync/outbox.dart';

void main() {
  // Every request throws, simulating no connectivity -- matches what a
  // real network failure looks like to SpliitClient's callers.
  SpliitClient offlineClient() => SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw Exception('offline')),
      );

  // Regression test for the headline bug found 2026-09-16: before the
  // Groups table was actually wired up, _group only ever came from a
  // live fetchGroup() call in _refresh(), which throws when offline --
  // so a cold offline start left the add button permanently disabled,
  // with no way to recover, even though the expense list loaded fine
  // from its own (already-working) cache.
  testWidgets(
    'add button is enabled on a cold offline start, as long as the group '
    'was cached from an earlier successful fetch',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await db.cacheGroup(const Group(
        id: 'g1',
        name: 'Banff Trip',
        currency: '\$',
        participants: [Participant(id: 'p1', name: 'Ken')],
      ));

      final client = offlineClient();
      final outbox = Outbox(db, client);

      await tester.pumpWidget(MaterialApp(
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      final fab = tester.widget<FloatingActionButton>(find.byType(FloatingActionButton));
      expect(fab.onPressed, isNotNull);
    },
  );

  testWidgets(
    'add button stays disabled offline when nothing has ever been cached',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final client = offlineClient();
      final outbox = Outbox(db, client);

      await tester.pumpWidget(MaterialApp(
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      final fab = tester.widget<FloatingActionButton>(find.byType(FloatingActionButton));
      expect(fab.onPressed, isNull);
    },
  );
}
