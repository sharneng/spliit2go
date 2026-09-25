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

  testWidgets('shows the group total, participant, and category sections', (tester) async {
    // The Stats screen's ListView is taller than a default test
    // viewport once the group + participant + category sections
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
    final outbox = Outbox(db, client, groupId: 'g1');

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: StatsScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    // #103: one "The group" figure replaces the old Summary and Totals
    // cards.
    expect(find.text('The group'), findsOneWidget);
    expect(find.text('Total group spending'), findsOneWidget);
    expect(find.text('\$170.00'), findsOneWidget); // group total
    expect(find.text('Settling up is not spending, so reimbursements are left out of every figure here.'),
        findsOneWidget);
    for (final gone in ['Summary', 'Totals', 'Average expense', 'Largest expense', 'Active span', 'You paid', 'Your share']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
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
    final outbox = Outbox(db, client, groupId: 'g1');

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: StatsScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Category 9'), findsOneWidget);
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
    final outbox = Outbox(db, client, groupId: 'g1');

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: StatsScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    expect(find.text('No expenses yet.'), findsOneWidget);
    // See the first test above for why. (issue #47)
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  Future<void> pumpStats(WidgetTester tester, AppDatabase db,
      {Locale locale = const Locale('en'), TransitionBuilder? builder}) async {
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => http.Response('offline', 500)),
    );
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: builder,
      home: StatsScreen(client: client, db: db, outbox: Outbox(db, client, groupId: 'g1'), group: group),
    ));
    await tester.pumpAndSettle();
  }

  Expense expense(String id, int cents, {bool reimbursement = false}) => Expense(
        id: id,
        groupId: 'g1',
        title: 'Expense $id',
        amountCents: cents,
        paidBy: 'alex',
        paidFor: const [ExpenseShare(participantId: 'bea', shares: 1)],
        isReimbursement: reimbursement,
        date: DateTime.utc(2026, 9, 1),
      );

  Finder headline(String amount) => find.byWidgetPredicate(
      (w) => w is Text && w.data == amount && w.style?.fontWeight == FontWeight.bold);

  testWidgets('the group total leaves reimbursements out (#103)', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.replaceServerExpenses('g1', [expense('e1', 4000), expense('r1', 1500, reimbursement: true)]);
    await pumpStats(tester, db);

    expect(headline('\$40.00'), findsOneWidget);
    expect(find.text('\$55.00'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a negative total reads as earnings, unsigned (#103)', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.replaceServerExpenses('g1', [expense('e1', 1000), expense('e2', -2500)]);
    await pumpStats(tester, db);

    expect(find.text('Total group earnings'), findsOneWidget);
    expect(find.text('Total group spending'), findsNothing);
    expect(headline('\$15.00'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('only settlements: still the empty state', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.replaceServerExpenses('g1', [expense('r1', 1500, reimbursement: true)]);
    await pumpStats(tester, db);

    expect(find.text('No expenses yet.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  // The old Summary card overflowed on a phone (#103's first screenshot).
  for (final (label, locale) in [('English', const Locale('en')), ('French', const Locale('fr'))]) {
    testWidgets('$label at double text size on a narrow phone: the group section fits (#103)',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.replaceServerExpenses('g1', [expense('e1', 1307155)]);
      await pumpStats(tester, db, locale: locale, builder: spliit2goAppBuilder);

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  }
}
