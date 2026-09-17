import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
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
    final outbox = Outbox(db, client);

    await tester.pumpWidget(MaterialApp(
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
    final outbox = Outbox(db, client);

    await tester.pumpWidget(MaterialApp(
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
                'time': '2026-09-16T12:00:00.000Z',
                'activityType': 'CREATE_EXPENSE',
                'participantId': 'alex',
                'expenseId': 'e1',
                'data': 'Groceries',
                'expense': {'id': 'e1'},
              },
              {
                'id': 'a2',
                'time': '2026-09-16T09:00:00.000Z',
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
    final outbox = Outbox(db, client);

    await tester.pumpWidget(MaterialApp(
      home: ActivityScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Expense "Groceries" created by Alex.'), findsOneWidget);
    // No participantId on the group-settings activity -- falls back to
    // "Someone" rather than a blank or an id.
    expect(find.text('Group settings were modified by Someone.'), findsOneWidget);
    // Both activities happened today, so they share a single "Today"
    // header rather than one each.
    expect(find.text('Today'), findsOneWidget);
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
                'time': '2026-09-16T12:00:00.000Z',
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
    final outbox = Outbox(db, client);

    await tester.pumpWidget(MaterialApp(
      home: ActivityScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    final tile = tester.widget<ListTile>(find.byType(ListTile).first);
    expect(tile.onTap, isNull);
    expect(tile.trailing, isNull);
  });

  testWidgets('"Load more" fetches the next page and appends it', (tester) async {
    final db = await newDb();
    addTearDown(db.close);
    var calls = 0;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            pageBody(
              activities: [
                {
                  'id': 'a1',
                  'time': '2026-09-16T12:00:00.000Z',
                  'activityType': 'UPDATE_GROUP',
                  'participantId': null,
                  'expenseId': null,
                  'data': null,
                },
              ],
              hasMore: true,
              nextCursor: 1,
            ),
            200,
          );
        }
        return http.Response(
          pageBody(
            activities: [
              {
                'id': 'a2',
                'time': '2026-09-15T12:00:00.000Z',
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
        );
      }),
    );
    final outbox = Outbox(db, client);

    await tester.pumpWidget(MaterialApp(
      home: ActivityScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Load more'), findsOneWidget);
    expect(find.text('Yesterday'), findsNothing);

    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Load more'), findsNothing);
  });

  testWidgets('tapping an activity with a surviving expense opens it', (tester) async {
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
                  'time': '2026-09-16T12:00:00.000Z',
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
    final outbox = Outbox(db, client);

    await tester.pumpWidget(MaterialApp(
      home: ActivityScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Expense "Groceries" created by Alex.'));
    await tester.pumpAndSettle();

    expect(find.text('Groceries'), findsWidgets);
  });
}
