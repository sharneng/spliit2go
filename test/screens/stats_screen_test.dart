import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/stats_screen.dart';
import 'package:spliit2go/sync/outbox.dart';

// Flat testWidgets calls, not group() -- `group` is also the fixture
// constant name below (see activity_screen_test.dart for the same note).
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

  // Amounts chosen so the summary "average" and the active user's
  // "share" don't coincidentally land on the same figure (with exactly
  // 2 participants splitting evenly, they otherwise always do) -- that
  // would make the \$-amount text finders below ambiguous.
  Future<AppDatabase> dbWithExpenses() async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.replaceServerExpenses('g1', [
      Expense(
        id: 'e1',
        groupId: 'g1',
        title: 'Groceries',
        amountCents: 9000,
        paidBy: 'alex',
        category: 9,
        paidFor: const [
          ExpenseShare(participantId: 'alex', shares: 1),
          ExpenseShare(participantId: 'bea', shares: 1),
        ],
        date: DateTime.utc(2026, 9, 1),
      ),
      Expense(
        id: 'e2',
        groupId: 'g1',
        title: 'Coffee',
        amountCents: 3000,
        paidBy: 'bea',
        category: 9,
        paidFor: const [
          ExpenseShare(participantId: 'alex', shares: 1),
          ExpenseShare(participantId: 'bea', shares: 1),
        ],
        date: DateTime.utc(2026, 9, 10),
      ),
      Expense(
        id: 'e3',
        groupId: 'g1',
        title: 'Museum tickets',
        amountCents: 5000,
        paidBy: 'bea',
        // A different category from e1/e2 -- otherwise, with only one
        // category in play, its total would coincidentally equal the
        // group total (17000 = $170.00), making that text finder
        // ambiguous below.
        category: 4,
        paidFor: const [
          ExpenseShare(participantId: 'alex', shares: 1),
          ExpenseShare(participantId: 'bea', shares: 1),
        ],
        date: DateTime.utc(2026, 9, 12),
      ),
    ]);
    return db;
  }

  testWidgets('shows summary, totals, participant, and category sections', (tester) async {
    // The Stats screen's ListView is taller than a default test
    // viewport once summary + totals + participant + category sections
    // are all populated, so widgets past the fold wouldn't otherwise be
    // built -- size the viewport generously instead of scrolling.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = await dbWithExpenses();
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => http.Response(
            jsonEncode([
              {
                'result': {
                  'data': {
                    'json': {
                      'categories': [
                        {'id': 9, 'name': 'Groceries', 'grouping': 'Food and Drink'},
                      ],
                    },
                  },
                },
              },
            ]),
            200,
          )),
    );
    final outbox = Outbox(db, client);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: StatsScreen(client: client, db: db, outbox: outbox, group: group, activeUserId: 'alex'),
    ));
    await tester.pumpAndSettle();

    // total = 17000, count = 3 -> average = 5667 (rounded); group total
    // 170.00; Alex paid only e1 (90.00); Alex's share across all three
    // (split evenly between just Alex and Bea) = 4500 + 1500 + 2500 = 8500.
    expect(find.text('3'), findsOneWidget); // expense count
    expect(find.text('\$56.67'), findsOneWidget); // average
    expect(find.text('\$170.00'), findsOneWidget); // group total
    // findsWidgets, not findsOneWidget: Alex is both the active user
    // (totals card's "You paid") and a row in the participant list
    // below, and those two show the same figure by construction.
    expect(find.text('\$90.00'), findsWidgets); // You paid
    expect(find.text('\$85.00'), findsOneWidget); // Your share
    // Category name resolved via the live fetch.
    expect(find.text('Groceries'), findsWidgets);
    expect(find.text('Alex'), findsOneWidget);
    expect(find.text('Bea'), findsOneWidget);
    // Drift's watch() stream (issue #47) schedules an internal
    // debounce/reconnect Timer when a subscriber cancels, which
    // happens when this widget is disposed. flutter_test's automatic
    // end-of-test teardown doesn't give that Timer a chance to fire
    // before its "no pending timers" invariant check, so we force
    // disposal ourselves here and pump once more to drain it.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('falls back to an id-based category label when the fetch fails', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = await dbWithExpenses();
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => http.Response('offline', 500)),
    );
    final outbox = Outbox(db, client);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: StatsScreen(client: client, db: db, outbox: outbox, group: group, activeUserId: null),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Category 9'), findsOneWidget);
    // No active user -- personal totals are hidden, with a hint instead.
    expect(find.text('Pick an active user to see your personal totals.'), findsOneWidget);
    expect(find.text('You paid'), findsNothing);
    // See the first test above for why. (issue #47)
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('shows an empty state with no expenses', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => http.Response('offline', 500)),
    );
    final outbox = Outbox(db, client);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: StatsScreen(client: client, db: db, outbox: outbox, group: group, activeUserId: null),
    ));
    await tester.pumpAndSettle();

    expect(find.text('No expenses yet.'), findsOneWidget);
    // See the first test above for why. (issue #47)
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
