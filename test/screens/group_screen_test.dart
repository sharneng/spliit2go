import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/activity_screen.dart';
import 'package:spliit2go/screens/balances_screen.dart';
import 'package:spliit2go/screens/group_screen.dart';
import 'package:spliit2go/screens/stats_screen.dart';
import 'package:spliit2go/sync/outbox.dart';
import 'package:spliit2go/widgets/category_icon.dart';

void main() {
  // GroupScreen's _resolveActiveUser awaits
  // SettingsService.defaultActiveUserName() -> SharedPreferences.
  // getInstance(); without this it hangs forever in a widget test.
  SharedPreferences.setMockInitialValues({});

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
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      final fab = tester.widget<FloatingActionButton>(find.byType(FloatingActionButton));
      expect(fab.onPressed, isNotNull);
      // Drift's watch() stream (issue #47) schedules an internal
      // debounce/reconnect Timer when a subscriber cancels, which
      // happens when this widget is disposed. flutter_test's automatic
      // end-of-test teardown doesn't give that Timer a chance to fire
      // before its "no pending timers" invariant check, so we force
      // disposal ourselves here and pump once more to drain it.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
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
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      final fab = tester.widget<FloatingActionButton>(find.byType(FloatingActionButton));
      expect(fab.onPressed, isNull);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  group('tap-to-edit (issue #17)', () {
    const cachedGroup = Group(
      id: 'g1',
      name: 'Banff Trip',
      currency: '\$',
      participants: [Participant(id: 'p1', name: 'Ken')],
    );

    Expense syncedExpense() => Expense(
          id: 'e1',
          groupId: 'g1',
          title: 'Coffee',
          amountCents: 500,
          paidBy: 'p1',
          paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
          date: DateTime.utc(2026, 9, 16),
        );

    testWidgets('tapping a synced expense fetches it fresh and opens the edit screen',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.cacheGroup(cachedGroup);
      await db.replaceServerExpenses('g1', [syncedExpense()]);

      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          if (req.url.toString().contains('groups.expenses.get')) {
            return http.Response(
              '[{"result":{"data":{"json":{"expense":{'
              '"id":"e1","title":"Coffee","amount":500,"paidBy":"p1",'
              '"paidFor":[{"participant":"p1","shares":1}],"splitMode":"EVENLY",'
              '"category":0,"notes":"","expenseDate":"2026-09-16T00:00:00.000Z",'
              '"isReimbursement":false}}}}}]',
              200,
            );
          }
          throw Exception('offline'); // fetchGroup/fetchExpenses -- _refresh falls back to cache
        }),
      );
      final outbox = Outbox(db, client);

      await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Coffee'));
      await tester.pumpAndSettle();

      expect(find.text('Edit expense'), findsOneWidget);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('tapping a synced expense while offline shows an error, no navigation',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.cacheGroup(cachedGroup);
      await db.replaceServerExpenses('g1', [syncedExpense()]);

      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw Exception('offline')),
      );
      final outbox = Outbox(db, client);

      await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Coffee'));
      await tester.pumpAndSettle();

      expect(find.text('Edit expense'), findsNothing);
      expect(find.textContaining('needs a connection'), findsOneWidget);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('a still-pending (not yet synced) expense is not tappable', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.cacheGroup(cachedGroup);
      await db.insertPending(Expense(
        id: 'local-1',
        groupId: 'g1',
        title: 'Snacks',
        amountCents: 300,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        date: DateTime.utc(2026, 9, 16),
        pending: true,
      ));

      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw Exception('offline')),
      );
      final outbox = Outbox(db, client);

      await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      final tile = tester.widget<ListTile>(find.widgetWithText(ListTile, 'Snacks'));
      expect(tile.onTap, isNull);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  });

  group('sync failure retry/delete (issue #44)', () {
    const cachedGroup = Group(
      id: 'g1',
      name: 'Banff Trip',
      currency: '\$',
      participants: [Participant(id: 'p1', name: 'Ken')],
    );

    Expense pendingExpense() => Expense(
          id: 'local-1',
          groupId: 'g1',
          title: 'Snacks',
          amountCents: 300,
          paidBy: 'p1',
          paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
          date: DateTime.utc(2026, 9, 16),
          pending: true,
        );

    // A row only ever becomes syncFailed the way the outbox itself sets
    // it -- via AppDatabase.recordSyncFailure, called from
    // Outbox.flush() -- never by constructing an Expense with
    // syncFailed already set: insertPending's own toCompanion()
    // deliberately doesn't forward that field (or lastError), since a
    // freshly-queued offline add can never have failed a sync attempt
    // yet. Seeding it this way exercises the exact same path
    // production code takes.
    Future<void> insertFailedExpense(AppDatabase db) async {
      await db.insertPending(pendingExpense());
      await db.recordSyncFailure(
        id: 'local-1',
        error: "SpliitApiException(400): participant doesn't exist",
        retryCount: 1,
        failed: true,
      );
    }

    testWidgets('a sync-failed expense shows an error badge instead of "syncing…"',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.cacheGroup(cachedGroup);
      await insertFailedExpense(db);

      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw Exception('not used')),
      );
      final outbox = Outbox(db, client);

      await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      expect(find.text('sync failed'), findsOneWidget);
      expect(find.text('syncing…'), findsNothing);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('tapping a sync-failed expense opens retry/delete options with the error message',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.cacheGroup(cachedGroup);
      await insertFailedExpense(db);

      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw Exception('not used')),
      );
      final outbox = Outbox(db, client);

      await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Snacks'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't sync this expense"), findsOneWidget);
      expect(find.textContaining("participant doesn't exist"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      // Deliberately no "edit" option -- see _showSyncFailureOptions's
      // own doc comment (this app is view+add only, never offline
      // edit).
      expect(find.text('Edit'), findsNothing);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('Retry re-queues the expense and a subsequent flush can sync it',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.cacheGroup(cachedGroup);
      await insertFailedExpense(db);

      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          if (req.url.toString().contains('expenses.create')) {
            return http.Response('[{"result":{"data":{"json":{"expenseId":"server-1"}}}}]', 200);
          }
          // groups.get / groups.expenses.list follow-up refresh.
          throw Exception('offline');
        }),
      );
      final outbox = Outbox(db, client);

      await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Snacks'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('sync failed'), findsNothing);
      final rows = await db.expensesForGroup('g1');
      expect(rows.single.id, 'server-1');
      expect(rows.single.pending, isFalse);
      expect(rows.single.syncFailed, isFalse);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('Delete removes the sync-failed expense from the list and the local db',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.cacheGroup(cachedGroup);
      await insertFailedExpense(db);

      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw Exception('not used')),
      );
      final outbox = Outbox(db, client);

      await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Snacks'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Snacks'), findsNothing);
      expect(await db.expensesForGroup('g1'), isEmpty);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  });

  // Regression coverage for issue #28: each expense row leads with its
  // category's icon (a banknote here, since this synced expense has no
  // category set and the offline test client never resolves a real
  // categories.list -- see _categoryFor/_loadCategories in
  // group_screen.dart).
  testWidgets('an expense row shows a leading category icon', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(const Group(
      id: 'g1',
      name: 'Banff Trip',
      currency: '\$',
      participants: [Participant(id: 'p1', name: 'Ken')],
    ));
    await db.replaceServerExpenses('g1', [
      Expense(
        id: 'e1',
        groupId: 'g1',
        title: 'Coffee',
        amountCents: 500,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        date: DateTime.utc(2026, 9, 16),
      ),
    ]);

    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw Exception('offline')),
    );
    final outbox = Outbox(db, client);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
    ));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Coffee'),
        matching: find.byType(CategoryIconGlyph),
      ),
      findsOneWidget,
    );
    // See the first test above for why. (issue #47)
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  group('bottom-nav tabs (issue #38)', () {
    const cachedGroup = Group(
      id: 'g1',
      name: 'Banff Trip',
      currency: '\$',
      participants: [Participant(id: 'p1', name: 'Ken')],
    );

    Future<void> pumpGroupScreen(WidgetTester tester, AppDatabase db) async {
      await db.cacheGroup(cachedGroup);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw Exception('offline')),
      );
      final outbox = Outbox(db, client);
      await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('shows all four destinations in the bottom nav bar', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpGroupScreen(tester, db);

      expect(find.byType(NavigationDestination), findsNWidgets(4));
      expect(find.text('Expenses'), findsOneWidget);
      expect(find.text('Balance'), findsOneWidget);
      expect(find.text('Stats'), findsOneWidget);
      expect(find.text('Activities'), findsOneWidget);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('the add button and search icon only show on the Expenses tab', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpGroupScreen(tester, db);

      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.byIcon(Icons.search), findsOneWidget);

      await tester.tap(find.text('Balance'));
      await tester.pumpAndSettle();

      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byIcon(Icons.search), findsNothing);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('tapping Balance shows BalancesScreen embedded, without pushing a new route',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpGroupScreen(tester, db);

      await tester.tap(find.text('Balance'));
      await tester.pumpAndSettle();

      expect(find.byType(BalancesScreen), findsOneWidget);
      // Embedded (not pushed): still just the one GroupScreen AppBar
      // titled with the group's name, not a second "Balances" AppBar.
      expect(find.text('Balances'), findsNothing);
      expect(find.text('Banff Trip'), findsOneWidget);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('tapping Stats shows StatsScreen embedded, without pushing a new route',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpGroupScreen(tester, db);

      await tester.tap(find.text('Stats'));
      await tester.pumpAndSettle();

      expect(find.byType(StatsScreen), findsOneWidget);
      expect(find.text('Banff Trip'), findsOneWidget);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('tapping Activities shows ActivityScreen embedded, without pushing a new route',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpGroupScreen(tester, db);

      await tester.tap(find.text('Activities'));
      await tester.pumpAndSettle();

      expect(find.byType(ActivityScreen), findsOneWidget);
      expect(find.text('Banff Trip'), findsOneWidget);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('tapping the search icon on the Expenses tab shows the placeholder message',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpGroupScreen(tester, db);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      expect(find.text('Search is coming soon (issue #39).'), findsOneWidget);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('switching back to Expenses shows the expense list again', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpGroupScreen(tester, db);

      await tester.tap(find.text('Stats'));
      await tester.pumpAndSettle();
      expect(find.byType(StatsScreen), findsOneWidget);

      await tester.tap(find.text('Expenses'));
      await tester.pumpAndSettle();

      expect(find.byType(StatsScreen), findsNothing);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  });
}
