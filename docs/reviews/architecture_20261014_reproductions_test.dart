import 'package:spliit2go/screens/expense_form/expense_form_model.dart';
import 'package:spliit2go/models/default_split.dart';

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

  test(
    'same group ID on two servers overwrites A and sends A pending row to B',
    () async {
      for (final server in ['a', 'b']) {
        await cacheJoinedGroup(
          db: db,
          group: Group(
            id: 'same-group',
            name: 'Server $server',
            currency: '\$',
            participants: const [],
          ),
          expenses: const [],
          serverUrl: 'https://$server.test',
          settings: _ReviewSettings(),
        );
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
            '[{"result":{"data":{"json":{"expenseId":"server-b"}}}}]',
            200,
          );
        }),
      );
      expect(await Outbox(db, api, groupId: 'same-group').flush(), 1);
      expect(sent!.url.host, 'b.test');
      expect(
        jsonDecode(sent!.body)['0']['json']['expenseFormValues']['title'],
        'From server A',
      );
    },
  );

  test(
      'a pre-create snapshot removes the just-synced row despite the generation guard',
      () async {
    await db.insertPending(pending('local-a'));
    final generation = db.expensesGeneration('same-group');
    await db.markSynced(localId: 'local-a', serverId: 'server-a');
    expect(
      await db.replaceServerExpenses(
        'same-group',
        const [],
        fetchedAtGeneration: generation,
      ),
      isTrue,
    );
    expect(await db.expensesForGroup('same-group'), isEmpty);
  });

  test(
    'server commit with lost response is followed by a second create',
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
            200,
          );
        }),
      );
      final outbox = Outbox(db, api, groupId: 'same-group');
      expect(await outbox.flush(), 0);
      expect(await outbox.flush(), 1);
      expect(serverCreates, 2);
    },
  );

  test(
    'cached New York midnight changes date when read in Los Angeles',
    () async {
      // Exactly the persisted epoch of DateTime(2026, 10, 9) in New York.
      final nyMidnight = DateTime.parse('2026-10-09T00:00:00-04:00');
      final e = pending('local-a');
      await db.insertPending(
        Expense(
          id: e.id,
          groupId: e.groupId,
          title: e.title,
          amountCents: e.amountCents,
          paidBy: e.paidBy,
          paidFor: e.paidFor,
          date: nyMidnight,
          pending: true,
        ),
      );
      final cached = (await db.expensesForGroup('same-group')).single;
      expect(cached.date.timeZoneOffset, const Duration(hours: -7));
      expect(cached.date.day, 8);
    },
  );

  test(
    'a repeated pagination cursor causes the same request to repeat',
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
                    'json': {'expenses': [], 'hasMore': true, 'nextCursor': 20},
                  },
                },
              },
            ]),
            200,
          );
        }),
      );
      await expectLater(api.fetchExpenses('same-group'), throwsStateError);
      expect(requested, hasLength(4));
      expect(requested[1], requested[2]);
      expect(requested[2], requested[3]);
    },
  );

  test(
    'a stale detail response overwrites newer summary receipt count and notes',
    () async {
      const group = Group(
        id: 'same-group',
        name: 'Trip',
        currency: r'$',
        participants: [],
      );
      await db.cacheGroup(group);
      Expense snapshot({
        required String title,
        required String notes,
        required int count,
        List<ExpenseDocument> docs = const [],
      }) =>
          Expense(
            id: 'remote',
            groupId: group.id,
            title: title,
            notes: notes,
            amountCents: 500,
            paidBy: 'p1',
            paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
            date: DateTime(2026, 10, 14),
            documentCount: count,
            documents: docs,
          );
      final oldResponse = snapshot(
        title: 'Before edit',
        notes: 'Old note',
        count: 1,
        docs: const [
          ExpenseDocument(
            id: 'old-doc',
            url: 'https://bucket.test/old',
            width: 1,
            height: 1,
          ),
        ],
      );
      // An edit and its new list have completed while the old full read is pending.
      db.markExpensesChanged(group.id);
      await db.replaceServerExpenses(group.id, [
        snapshot(title: 'Edited', notes: '', count: 2),
      ]);
      await db.cacheExpenseDetails(group.id, oldResponse);
      final row = (await db.expensesForGroup(group.id)).single;
      expect(row.title, 'Edited');
      expect(row.notes, 'Old note');
      expect(row.documentCount, 1);
      expect(row.detailsFetchedAt, isNotNull);
    },
  );

  test(
      'a delayed remembered split overwrites the split already edited by the user',
      () {
    const group = Group(
      id: 'same-group',
      name: 'Trip',
      currency: r'$',
      currencyCode: 'USD',
      participants: [
        Participant(id: 'p1', name: 'Alice'),
        Participant(id: 'p2', name: 'Bob'),
      ],
    );
    final model = ExpenseFormModel(group: group);
    addTearDown(model.dispose);
    model.amountController.text = '10';
    model.splitMode = SplitMode.byAmount;
    model.splitControllers['p1']!.text = '9';
    model.splitControllers['p2']!.text = '1';
    expect(model.paidFor()!.map((s) => s.shares), [900, 100]);
    // ExpenseScreen calls this when its asynchronous defaultSplitFor read completes.
    model.applyDefaultSplit(
      const DefaultSplit(splitMode: SplitMode.evenly, shares: {'p1': 1}),
    );
    expect(model.splitMode, SplitMode.evenly);
    expect(model.paidFor()!.map((s) => s.participantId), ['p1']);
  });

  // A6's Markdown image case is now test/widgets/notes_text_test.dart (#325).
}
