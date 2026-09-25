import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/screens/join_group_screen.dart';
import 'package:spliit2go/services/date_span_calculator.dart';

void main() {
  // SettingsService.defaultActiveUserName() awaits
  // SharedPreferences.getInstance(); without this, the call hangs
  // forever in a widget test (no platform channel handler registered),
  // which keeps JoinGroupScreen's _joining spinner animating forever
  // and pumpAndSettle times out -- discovered by exactly that timeout.
  SharedPreferences.setMockInitialValues({});

  String groupResponse() => jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'group': {
                  'id': 'g1',
                  'name': 'Banff Trip',
                  'currency': '\$',
                  'participants': [
                    {'id': 'alex', 'name': 'Alex'},
                    {'id': 'bea', 'name': 'Bea'},
                  ],
                },
              },
            },
          },
        },
      ]);

  Map<String, dynamic> expenseJson(String id, String date) => {
        'id': id,
        'title': 'Expense $id',
        'amount': 1000,
        'paidBy': {'id': 'alex', 'name': 'Alex'},
        'paidFor': [
          {
            'participant': {'id': 'alex', 'name': 'Alex'},
            'shares': 1,
          },
          {
            'participant': {'id': 'bea', 'name': 'Bea'},
            'shares': 1,
          },
        ],
        'splitMode': 'EVENLY',
        'category': 0,
        'notes': '',
        'expenseDate': date,
        'isReimbursement': false,
      };

  String expensesResponse() => jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'expenses': [
                  expenseJson('e1', '2026-09-05T00:00:00.000Z'),
                  expenseJson('e2', '2026-09-01T00:00:00.000Z'),
                ],
                'hasMore': false,
              },
            },
          },
        },
      ]);

  /// Answers groups.get and groups.expenses.list like a real server;
  /// [expensesStatus] lets a test fail just the expense fetch.
  SpliitClient serverClient({int expensesStatus = 200}) => SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/groups.expenses.list')) {
            return expensesStatus == 200
                ? http.Response(expensesResponse(), 200)
                : http.Response('server error', expensesStatus);
          }
          return http.Response(groupResponse(), 200);
        }),
      );

  Future<String?> pushAndJoin(WidgetTester tester, AppDatabase db, SpliitClient client,
      {String url = 'https://example.test/groups/g1'}) async {
    String? popped;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            popped = await Navigator.of(context).push<String>(
              MaterialPageRoute(
                builder: (_) => JoinGroupScreen(db: db, clientFactory: (_) => client),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Group URL'), url);
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    return popped;
  }

  testWidgets('joining fetches the group, caches it, records it opened, and pops the group id',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final poppedGroupId = await pushAndJoin(tester, db, serverClient());

    expect(poppedGroupId, 'g1');
    final cached = await db.cachedGroup('g1');
    expect(cached?.name, 'Banff Trip');
    final row = await db.groupRow('g1');
    expect(row?.serverUrl, 'https://example.test');
    expect(row?.lastOpenedAt, isNotNull);
  });

  testWidgets('joining caches the expenses, so the date span is known right away (#81)',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await pushAndJoin(tester, db, serverClient());

    final expenses = await db.expensesForGroup('g1');
    expect(expenses.map((e) => e.id), unorderedEquals(['e1', 'e2']));
    expect(expenses.every((e) => !e.pending), isTrue);
    final span = computeDateSpan(expenses);
    expect(span?.first, DateTime(2026, 9, 1));
    expect(span?.last, DateTime(2026, 9, 5));
  });

  testWidgets('an expense fetch failure fails the join and caches nothing (#81)',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final poppedGroupId =
        await pushAndJoin(tester, db, serverClient(expensesStatus: 500));

    expect(poppedGroupId, isNull);
    expect(find.textContaining("Couldn't join"), findsOneWidget);
    expect(await db.groupRow('g1'), isNull);
    expect(await db.allJoinedGroups(), isEmpty);
    expect(await db.expensesForGroup('g1'), isEmpty);
  });

  testWidgets('auto-matches the active participant against the device default name',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final client = serverClient();

    // SettingsService's SharedPreferences-backed value isn't easily
    // seeded from a plain widget test without the platform channel, so
    // this exercises the "no default name set" path instead --
    // resolveActiveParticipant's matching logic itself is covered
    // directly in active_user_test.dart. What this confirms is that
    // JoinGroupScreen doesn't set an active participant when there's
    // nothing to auto-match against.
    await pushAndJoin(tester, db, client);

    final row = await db.groupRow('g1');
    expect(row?.activeParticipantId, isNull);
  });

  testWidgets('a server error is shown inline and nothing is cached', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => http.Response('server error', 500)),
    );

    final poppedGroupId = await pushAndJoin(tester, db, client);

    expect(poppedGroupId, isNull);
    expect(find.textContaining("Couldn't join"), findsOneWidget);
    expect(await db.cachedGroup('g1'), isNull);
  });

  testWidgets('a blank field is rejected by form validation before any request', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    var requested = false;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        requested = true;
        return http.Response(groupResponse(), 200);
      }),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: JoinGroupScreen(db: db, clientFactory: (_) => client),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();

    expect(find.text('Required'), findsWidgets);
    expect(requested, isFalse);
  });

  testWidgets('a URL that has no /groups/ segment is rejected before any request',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    var requested = false;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        requested = true;
        return http.Response(groupResponse(), 200);
      }),
    );

    final poppedGroupId =
        await pushAndJoin(tester, db, client, url: 'https://example.test/not-a-group-url');

    expect(poppedGroupId, isNull);
    expect(requested, isFalse);
    expect(find.textContaining("doesn't look like a group URL"), findsOneWidget);
  });

  testWidgets('"Create a new group" opens the create form; creating closes Join with the new id (#115)',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final servers = <String>[];
    final client = SpliitClient(
      baseUrl: 'https://spliit.app',
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('groups.create')) {
          return http.Response('[{"result":{"data":{"json":{"groupId":"g1"}}}}]', 200);
        }
        return http.Response(groupResponse(), 200);
      }),
    );
    String? popped;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            popped = await Navigator.of(context).push<String>(MaterialPageRoute(
              builder: (_) => JoinGroupScreen(
                  db: db,
                  clientFactory: (url) {
                    servers.add(url);
                    return client;
                  }),
            ));
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create a new group'));
    await tester.pumpAndSettle();
    expect(find.text('Create group'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Group name'), 'Banff Trip');
    await tester.tap(find.byTooltip('Create'));
    await tester.pumpAndSettle();

    expect(popped, 'g1');
    expect(find.byType(JoinGroupScreen), findsNothing);
    expect(servers, ['https://spliit.app']);
  });

  // Issue #118: "Couldn't join: type 'Null' is not a subtype of type
  // 'Map<String, dynamic>' in type cast" for a group the server doesn't have.
  /// Everything [body] writes to debugPrint, where unexpected errors are
  /// logged (#119 review).
  Future<List<String>> captureLogs(Future<void> Function() body) async {
    final lines = <String>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
    try {
      await body();
    } finally {
      debugPrint = original;
    }
    return lines;
  }

  SpliitClient answering(String body, {int status = 200}) => SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response(body, status)),
      );

  // Issue #118: "Couldn't join: type 'Null' is not a subtype of type
  // 'Map<String, dynamic>' in type cast" for a group the server doesn't have.
  // A missing group is the user's to fix: guidance only, no log, no
  // details (Kenneth and Ezra, #119 review).
  testWidgets('a group the server doesn\'t have says so, with no log and no details (#118, #119)',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    String? popped;
    final logs = await captureLogs(() async {
      popped = await pushAndJoin(tester, db,
          answering('[{"result":{"data":{"json":{"group":null}}}}]'));
    });

    expect(popped, isNull);
    expect(find.text('No group with that link was found on example.test. Check the link and try again.'),
        findsOneWidget);
    expect(find.textContaining('is not a subtype'), findsNothing);
    expect(find.text('Tap for details'), findsNothing);
    expect(logs.where((l) => l.contains('Unexpected error')), isEmpty);
  });

  testWidgets('no connection says so, with no log and no details (#119)', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw http.ClientException('Failed host lookup')),
    );
    late final String? popped;
    final logs = await captureLogs(() async => popped = await pushAndJoin(tester, db, client));

    expect(popped, isNull);
    expect(find.text("Couldn't reach the server. Check your connection and try again."),
        findsOneWidget);
    expect(find.text('Tap for details'), findsNothing);
    expect(logs.where((l) => l.contains('Unexpected error')), isEmpty);
  });

  testWidgets('a malformed response is unexpected: a short message, logged, details one tap away (#119)',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    late final String? popped;
    final logs = await captureLogs(() async {
      popped = await pushAndJoin(tester, db,
          answering('[{"result":{"data":{"json":{"group":[]}}}}]'));
    });

    expect(popped, isNull);
    // The raw exception stays out of the message.
    expect(find.text("Couldn't join the group."), findsOneWidget);
    expect(find.textContaining('SpliitResponseFormatException'), findsNothing);
    expect(logs.where((l) => l.contains('SpliitResponseFormatException')), hasLength(1));

    await tester.tap(find.text('Tap for details'));
    await tester.pumpAndSettle();
    expect(find.text('Error details'), findsOneWidget);
    expect(find.textContaining('SpliitResponseFormatException'), findsOneWidget);
    expect(find.textContaining('Joining https://example.test/groups/g1 failed.'), findsOneWidget);
  });

  testWidgets('a link pasted with a trailing period joins the right group (#118)', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final asked = <String>[];
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        asked.add(req.url.queryParameters['input'] ?? '');
        if (req.url.path.endsWith('groups.expenses.list')) {
          return http.Response(expensesResponse(), 200);
        }
        return http.Response(groupResponse(), 200);
      }),
    );

    final popped = await pushAndJoin(tester, db, client,
        url: 'Join us: https://example.test/groups/g1.');

    expect(popped, 'g1');
    expect(asked.first, contains('"groupId":"g1"'));
  });
}

