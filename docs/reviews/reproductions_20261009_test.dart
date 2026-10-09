import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/screens/join_group_screen.dart';
import 'package:spliit2go/services/settings_service.dart';
import 'package:spliit2go/sync/outbox.dart';

// Characterization tests: these PASS when the reviewed defect is present.
// Kept outside test/ so the normal suite does not require bugs to remain.
class _ReviewSettings extends SettingsService {
  @override
  Future<String?> defaultActiveUserName() async => null;
}

void main() {
  late AppDatabase db;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  Expense pending(String id) => Expense(
        id: id,
        groupId: 'same-group',
        title: 'From server A',
        amountCents: 500,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        date: DateTime(2026, 10, 9),
        pending: true,
      );

  test('same group ID on two servers overwrites A and sends A pending row to B',
      () async {
    for (final server in ['a', 'b']) {
      await cacheJoinedGroup(
          db: db,
          group: Group(
              id: 'same-group',
              name: 'Server $server',
              currency: '\$',
              participants: const []),
          expenses: const [],
          serverUrl: 'https://$server.test',
          settings: _ReviewSettings());
      if (server == 'a') await db.insertPending(pending('local-a'));
    }
    final rows = await db.allJoinedGroups();
    expect(rows, hasLength(1));
    expect(rows.single.serverUrl, 'https://b.test');
    http.Request? sent;
    final api = SpliitClient(
        baseUrl: rows.single.serverUrl,
        httpClient: MockClient((r) async {
          sent = r;
          return http.Response(
              '[{"result":{"data":{"json":{"expenseId":"server-b"}}}}]', 200);
        }));
    expect(await Outbox(db, api, groupId: 'same-group').flush(), 1);
    expect(sent!.url.host, 'b.test');
    expect(jsonDecode(sent!.body)['0']['json']['expenseFormValues']['title'],
        'From server A');
  });

  test(
      'a pre-create snapshot removes the just-synced row despite the generation guard',
      () async {
    await db.insertPending(pending('local-a'));
    final generation = db.expensesGeneration('same-group');
    await db.markSynced(localId: 'local-a', serverId: 'server-a');
    expect(
        await db.replaceServerExpenses('same-group', const [],
            fetchedAtGeneration: generation),
        isTrue);
    expect(await db.expensesForGroup('same-group'), isEmpty);
  });

  test('server commit with lost response is followed by a second create',
      () async {
    await db.insertPending(pending('local-a'));
    var serverCreates = 0;
    final api = SpliitClient(
        baseUrl: 'https://a.test',
        httpClient: MockClient((r) async {
          serverCreates++;
          if (serverCreates == 1) {
            throw http.ClientException('Response lost after server committed');
          }
          return http.Response(
              '[{"result":{"data":{"json":{"expenseId":"server-second"}}}}]',
              200);
        }));
    final outbox = Outbox(db, api, groupId: 'same-group');
    expect(await outbox.flush(), 0);
    expect(await outbox.flush(), 1);
    expect(serverCreates, 2);
  });

  test('cached New York midnight changes date when read in Los Angeles',
      () async {
    // Exactly the persisted epoch of DateTime(2026, 10, 9) in New York.
    final nyMidnight = DateTime.parse('2026-10-09T00:00:00-04:00');
    final e = pending('local-a');
    await db.insertPending(Expense(
        id: e.id,
        groupId: e.groupId,
        title: e.title,
        amountCents: e.amountCents,
        paidBy: e.paidBy,
        paidFor: e.paidFor,
        date: nyMidnight,
        pending: true));
    final cached = (await db.expensesForGroup('same-group')).single;
    expect(cached.date.timeZoneOffset, const Duration(hours: -7));
    expect(cached.date.day, 8);
  });

  test('a repeated pagination cursor causes the same request to repeat',
      () async {
    final requested = <Uri>[];
    final api = SpliitClient(
        baseUrl: 'https://a.test',
        httpClient: MockClient((r) async {
          requested.add(r.url);
          if (requested.length == 4) {
            throw StateError('Stop the endless test server');
          }
          return http.Response(
              jsonEncode([
                {
                  'result': {
                    'data': {
                      'json': {
                        'expenses': [],
                        'hasMore': true,
                        'nextCursor': 20,
                      }
                    }
                  }
                }
              ]),
              200);
        }));
    await expectLater(api.fetchExpenses('same-group'), throwsStateError);
    expect(requested, hasLength(4));
    expect(requested[1], requested[2]);
    expect(requested[2], requested[3]);
  });
}
