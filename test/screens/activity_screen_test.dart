import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/main.dart' show spliit2goAppBuilder;
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/activity_screen.dart';
import 'package:spliit2go/sync/outbox.dart';

// Flat testWidgets calls throughout this file, not group() -- `group` is
// also the name of the fixture constant below, and flutter_test's
// group() would be shadowed by it if used here (see
// group_settings_screen_test.dart / expense_screen_test.dart for the
// same pattern).
void main() {
  const group = Group(
    id: 'g1',
    name: 'Banff Trip',
    currency: '\$',
    participants: [
      Participant(id: 'alex', name: 'Alex'),
      Participant(id: 'bea', name: 'Bea'),
    ],
  );

  Future<AppDatabase> newDb() async => AppDatabase(NativeDatabase.memory());

  // Built from DateTime.now() rather than a fixed calendar date, so the
  // Today/Yesterday grouping this test asserts on doesn't go stale the
  // day after it's written.
  final now = DateTime.now();
  String isoToday(int hour) =>
      DateTime(now.year, now.month, now.day, hour).toUtc().toIso8601String();

  String pageBody({
    required List<Map<String, dynamic>> activities,
    required bool hasMore,
    required int nextCursor,
  }) {
    return jsonEncode([
      {
        'result': {
          'data': {
            'json': {
              'activities': activities,
              'hasMore': hasMore,
              'nextCursor': nextCursor,
            },
          },
        },
      },
    ]);
  }

  Map<String, dynamic> activityJson(String id, String isoTime) => {
        'id': id,
        'time': isoTime,
        'activityType': 'UPDATE_GROUP',
        'participantId': null,
        'expenseId': null,
        'data': null,
      };

  /// A fake server paging [pages] by cursor: each is (activities, hasMore,
  /// nextCursor). Records every requested cursor. [before] can hold a
  /// response back (a Completer) or throw to fail it.
  ({SpliitClient client, List<int> cursors}) pagedServer(
    Map<int, (List<Map<String, dynamic>>, bool, int)> pages, {
    Future<void> Function(int cursor)? before,
  }) {
    final cursors = <int>[];
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        final input = jsonDecode(req.url.queryParameters['input']!) as Map<String, dynamic>;
        final cursor = ((input['0'] as Map)['json'] as Map)['cursor'] as int;
        cursors.add(cursor);
        if (before != null) await before(cursor);
        final (activities, hasMore, nextCursor) = pages[cursor]!;
        return http.Response(
            pageBody(activities: activities, hasMore: hasMore, nextCursor: nextCursor), 200);
      }),
    );
    return (client: client, cursors: cursors);
  }

  Future<void> pumpActivity(
    WidgetTester tester,
    SpliitClient client,
    AppDatabase db, {
    Locale locale = const Locale('en'),
    DateTime Function()? now,
    DateTime Function(DateTime)? toLocal,
    TransitionBuilder? builder,
  }) async {
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: builder,
      home: ActivityScreen(
        client: client,
        db: db,
        outbox: Outbox(db, client, groupId: 'g1'),
        group: group,
        now: now ?? DateTime.now,
        toLocal: toLocal ?? (t) => t.toLocal(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// New York time, pinned regardless of the test machine's own zone:
  /// UTC-4, or UTC-5 from 06:00 UTC on 1 Nov 2026 (clocks go back).
  DateTime newYork(DateTime t) {
    final utc = t.toUtc();
    final offset = utc.isBefore(DateTime.utc(2026, 11, 1, 6)) ? 4 : 5;
    final w = utc.subtract(Duration(hours: offset));
    return DateTime(w.year, w.month, w.day, w.hour, w.minute);
  }

  /// Reads a UTC moment's own fields as local time: "UTC is local".
  DateTime wallClock(DateTime t) {
    final u = t.toUtc();
    return DateTime(u.year, u.month, u.day, u.hour, u.minute);
  }

  testWidgets('shows an empty state when there is no activity', (tester) async {
    final db = await newDb();
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient(
        (req) async => http.Response(
          pageBody(activities: [], hasMore: false, nextCursor: 0),
          200,
        ),
      ),
    );
    final outbox = Outbox(db, client, groupId: 'g1');

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ActivityScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    expect(find.text('There is not yet any activity in your group.'), findsOneWidget);
  });

  testWidgets('shows an error with a retry button when the fetch fails', (tester) async {
    final db = await newDb();
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => http.Response('offline', 500)),
    );
    final outbox = Outbox(db, client, groupId: 'g1');

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ActivityScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't load activity"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('renders a summary row per activity, resolving the participant name', (tester) async {
    final db = await newDb();
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient(
        (req) async => http.Response(
          pageBody(
            activities: [
              {
                'id': 'a1',
                'time': isoToday(12),
                'activityType': 'CREATE_EXPENSE',
                'participantId': 'alex',
                'expenseId': 'e1',
                'data': 'Groceries',
                'expense': {'id': 'e1'},
              },
              {
                'id': 'a2',
                'time': isoToday(9),
                'activityType': 'UPDATE_GROUP',
                'participantId': null,
                'expenseId': null,
                'data': null,
              },
            ],
            hasMore: false,
            nextCursor: 2,
          ),
          200,
        ),
      ),
    );
    final outbox = Outbox(db, client, groupId: 'g1');

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ActivityScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Expense "Groceries" created by Alex.'), findsOneWidget);
    // No participantId on the group-settings activity -- falls back to
    // "Someone" rather than a blank or an id.
    expect(find.text('Group settings were modified by Someone.'), findsOneWidget);
    // Both activities happened today, so they share a single "Today"
    // header rather than one each.
    expect(find.text('TODAY'), findsOneWidget);
  });

  testWidgets('an activity for a since-deleted expense is not tappable', (tester) async {
    final db = await newDb();
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient(
        (req) async => http.Response(
          pageBody(
            activities: [
              {
                'id': 'a1',
                'time': isoToday(12),
                'activityType': 'DELETE_EXPENSE',
                'participantId': 'alex',
                'expenseId': 'e1',
                'data': 'Dinner',
                'expense': null,
              },
            ],
            hasMore: false,
            nextCursor: 1,
          ),
          200,
        ),
      ),
    );
    final outbox = Outbox(db, client, groupId: 'g1');

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ActivityScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    final tile = tester.widget<ListTile>(find.byType(ListTile).first);
    expect(tile.onTap, isNull);
    expect(tile.trailing, isNull);
  });

  List<Map<String, dynamic>> todays(List<String> ids, {int hour = 12}) =>
      [for (final id in ids) activityJson(id, isoToday(hour))];

  testWidgets('pages load on their own until the screen is full or the log ends (#91)',
      (tester) async {
    final db = await newDb();
    addTearDown(db.close);
    final server = pagedServer({
      0: (todays(['a1', 'a2']), true, 2),
      2: (todays(['a3', 'a4']), true, 4),
      4: (todays(['a5']), false, 5),
    });

    await pumpActivity(tester, server.client, db);

    expect(server.cursors, [0, 2, 4]);
    expect(find.byType(ListTile), findsNWidgets(5));
    expect(find.text('Load more'), findsNothing);
    // A section continuing across pages keeps a single heading.
    expect(find.text('TODAY'), findsOneWidget);
  });

  testWidgets('scrolling near the end loads the next page, one request at a time (#91)',
      (tester) async {
    final db = await newDb();
    addTearDown(db.close);
    final gate = Completer<void>();
    final server = pagedServer({
      0: (todays([for (var i = 0; i < 30; i++) 'first-$i']), true, 30),
      30: (todays(['last']), false, 31),
    }, before: (cursor) => cursor == 30 ? gate.future : Future.value());

    await pumpActivity(tester, server.client, db);
    expect(server.cursors, [0], reason: 'a full first page waits for scrolling');

    for (var i = 0; i < 4; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pump();
    }
    expect(server.cursors, [0, 30], reason: 'repeated scrolling while loading asks once');

    gate.complete();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(server.cursors, [0, 30], reason: 'nothing more once the log ends');
  });

  testWidgets('a failed page keeps what is shown, waits for Retry, then asks for the same page (#91)',
      (tester) async {
    final db = await newDb();
    addTearDown(db.close);
    var failNext = true;
    final server = pagedServer({
      0: (todays(['a1']), true, 1),
      1: (todays(['a2']), false, 2),
    }, before: (cursor) async {
      if (cursor == 1 && failNext) {
        failNext = false;
        throw Exception('offline');
      }
    });

    await pumpActivity(tester, server.client, db);
    expect(server.cursors, [0, 1]);
    expect(find.byType(ListTile), findsOneWidget);
    expect(find.textContaining("Couldn't load activity"), findsOneWidget);

    // No automatic retry, however the list is poked.
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(server.cursors, [0, 1]);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(server.cursors, [0, 1, 1]);
    expect(find.byType(ListTile), findsNWidgets(2));
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('overlapping pages show each activity once; the next cursor still comes from the server (#91)',
      (tester) async {
    final db = await newDb();
    addTearDown(db.close);
    final server = pagedServer({
      0: (todays(['a1', 'a2']), true, 2),
      2: (todays(['a2', 'a3']), true, 5),
      5: (todays(['a4']), false, 6),
    });

    await pumpActivity(tester, server.client, db);

    expect(server.cursors, [0, 2, 5]);
    expect(find.byType(ListTile), findsNWidgets(4));
  });

  testWidgets('a page that does not move the cursor stops loading instead of looping (#91)',
      (tester) async {
    final db = await newDb();
    addTearDown(db.close);
    final server = pagedServer({0: (todays(['a1']), true, 0)});

    await pumpActivity(tester, server.client, db);

    expect(server.cursors, [0]);
    expect(find.byType(ListTile), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('leaving the screen while a page is loading is harmless (#91)', (tester) async {
    final db = await newDb();
    addTearDown(db.close);
    final gate = Completer<void>();
    final server = pagedServer({0: (todays(['a1']), false, 1)}, before: (_) => gate.future);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ActivityScreen(
          client: server.client, db: db, outbox: Outbox(db, server.client, groupId: 'g1'), group: group),
    ));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('times are shown and grouped in local time, either side of UTC midnight (#91)',
      (tester) async {
    final db = await newDb();
    addTearDown(db.close);
    final server = pagedServer({
      0: ([
        activityJson('after', '2026-09-24T04:30:00.000Z'), // 00:30 on the 24th in New York
        activityJson('before', '2026-09-24T03:30:00.000Z'), // 23:30 on the 23rd
      ], false, 2),
    });

    await pumpActivity(tester, server.client, db,
        now: () => DateTime(2026, 9, 24, 12), toLocal: newYork);

    double top(Finder f) => tester.getTopLeft(f).dy;
    expect(top(find.text('TODAY')), lessThan(top(find.text('00:30'))));
    expect(top(find.text('00:30')), lessThan(top(find.text('YESTERDAY'))));
    expect(top(find.text('YESTERDAY')), lessThan(top(find.text('23:30'))));
  });

  testWidgets('the night clocks go back, both 01:30s are yesterday (#91)', (tester) async {
    final db = await newDb();
    addTearDown(db.close);
    final server = pagedServer({
      0: ([
        activityJson('second', '2026-11-01T06:30:00.000Z'), // 01:30 EST
        activityJson('first', '2026-11-01T05:30:00.000Z'), // 01:30 EDT
      ], false, 2),
    });

    await pumpActivity(tester, server.client, db,
        now: () => DateTime(2026, 11, 2, 9), toLocal: newYork);

    expect(find.text('YESTERDAY'), findsOneWidget);
    expect(find.text('01:30'), findsNWidgets(2));
  });

  testWidgets('rows outside Today and Yesterday show the date as well as the time (#91)',
      (tester) async {
    final db = await newDb();
    addTearDown(db.close);
    final server = pagedServer({
      0: ([
        activityJson('today', '2026-09-24T09:05:00.000Z'),
        activityJson('earlier', '2026-09-10T09:05:00.000Z'),
      ], false, 2),
    });

    await pumpActivity(tester, server.client, db,
        now: () => DateTime(2026, 9, 24, 12), toLocal: wallClock);

    expect(find.text('09:05'), findsOneWidget);
    expect(find.text('EARLIER THIS MONTH'), findsOneWidget);
    expect(find.text('Sep 10, 2026 09:05'), findsOneWidget);
  });

  testWidgets('French at double text size on a narrow phone, in the real app wrapper (#91)',
      (tester) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final db = await newDb();
    addTearDown(db.close);
    final server = pagedServer({
      0: ([
        activityJson('week', '2026-09-22T09:05:00.000Z'),
        activityJson('year', '2026-02-10T09:05:00.000Z'),
      ], false, 2),
    });

    await pumpActivity(tester, server.client, db,
        locale: const Locale('fr'),
        now: () => DateTime(2026, 9, 24, 12),
        toLocal: wallClock,
        builder: spliit2goAppBuilder);

    expect(tester.takeException(), isNull);
    expect(find.text('PLUS TÔT CETTE SEMAINE'), findsOneWidget);
    // Read as a heading, in its natural case.
    expect(find.bySemanticsLabel('Plus tôt cette semaine'), findsOneWidget);
    semantics.dispose();
  });

  // Issue #90: opens the details sheet, not the edit form. This expense
  // isn't cached, so the sheet fetches it from the server.
  testWidgets('tapping an activity with a surviving expense opens its details', (tester) async {
    final db = await newDb();
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        if (req.url.toString().contains('groups.activities.list')) {
          return http.Response(
            pageBody(
              activities: [
                {
                  'id': 'a1',
                  'time': isoToday(12),
                  'activityType': 'CREATE_EXPENSE',
                  'participantId': 'alex',
                  'expenseId': 'e1',
                  'data': 'Groceries',
                  'expense': {'id': 'e1'},
                },
              ],
              hasMore: false,
              nextCursor: 1,
            ),
            200,
          );
        }
        if (req.url.toString().contains('groups.expenses.get')) {
          return http.Response(
            jsonEncode([
              {
                'result': {
                  'data': {
                    'json': {
                      'expense': {
                        'id': 'e1',
                        'title': 'Groceries',
                        'amount': 9000,
                        'paidBy': 'alex',
                        'paidFor': [
                          {'participant': 'alex', 'shares': 1},
                          {'participant': 'bea', 'shares': 1},
                        ],
                        'expenseDate': '2026-09-16T00:00:00.000Z',
                        'category': 0,
                      },
                    },
                  },
                },
              },
            ]),
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    );
    final outbox = Outbox(db, client, groupId: 'g1');

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ActivityScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Expense "Groceries" created by Alex.'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('\$90.00'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Edit'), findsOneWidget);
    expect(find.text('Edit expense'), findsNothing);

    // The sheet watches the db (see group_screen_test's teardown note).
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
