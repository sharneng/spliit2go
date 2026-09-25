import 'dart:async';
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
import 'package:spliit2go/main.dart' show spliit2goAppBuilder;
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/activity_screen.dart';
import 'package:spliit2go/screens/balances_screen.dart';
import 'package:spliit2go/screens/expense_search_screen.dart';
import 'package:spliit2go/screens/group_screen.dart';
import 'package:spliit2go/screens/group_settings_screen.dart';
import 'package:spliit2go/screens/stats_screen.dart';
import 'package:spliit2go/sync/outbox.dart';
import 'package:spliit2go/widgets/category_icon.dart';

void main() {
  // GroupScreen's _resolveActiveUser awaits
  // SettingsService.defaultActiveUserName() -> SharedPreferences.
  // getInstance(); without this it hangs forever in a widget test.
  // "Ken" auto-matches every group here, so the one-time "Who are you?"
  // prompt (issue #85, tested in group_screen_active_user_test.dart)
  // stays out of the way.
  SharedPreferences.setMockInitialValues({'default_active_user_name': 'Ken'});

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
      final outbox = Outbox(db, client, groupId: 'g1');

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
      final outbox = Outbox(db, client, groupId: 'g1');

      await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      final fab = tester.widget<FloatingActionButton>(find.byType(FloatingActionButton));
      expect(fab.onPressed, isNull);
      // No group name yet: the title falls back to the app's name (#105).
      expect(find.widgetWithText(AppBar, 'Spliit2Go'), findsOneWidget);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  // Issue #90: a tap opens the details sheet; editing (issue #17) is an
  // explicit action inside it.
  group('tap to view, then edit (issues #17, #90)', () {
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

    testWidgets('tapping a synced expense shows its details; Edit fetches it fresh and opens the form',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.cacheGroup(cachedGroup);
      await db.replaceServerExpenses('g1', [syncedExpense()]);

      var fetches = 0;
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          if (req.url.toString().contains('groups.expenses.get')) {
            fetches++;
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
      final outbox = Outbox(db, client, groupId: 'g1');

      await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Coffee'));
      await tester.pumpAndSettle();

      // Viewing reads the cache: nothing fetched yet, no edit form.
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(fetches, 0);
      expect(find.text('Edit expense'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Edit'));
      await tester.pumpAndSettle();

      expect(fetches, 1);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Edit expense'), findsOneWidget);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('offline, the details still show and Edit explains itself inside the sheet',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.cacheGroup(cachedGroup);
      await db.replaceServerExpenses('g1', [syncedExpense()]);

      final client = SpliitClient(
        baseUrl: 'https://example.test',
        // What the http client actually throws with no connection, which
        // the shared policy (#119) reads as a connection problem.
        httpClient: MockClient((req) async => throw http.ClientException('offline')),
      );
      final outbox = Outbox(db, client, groupId: 'g1');

      await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Coffee'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Edit'));
      await tester.pumpAndSettle();

      expect(find.text('Edit expense'), findsNothing);
      // Inside the sheet, not a SnackBar hidden behind it.
      expect(
          find.descendant(
              of: find.byType(BottomSheet),
              matching: find.text('Editing an expense needs a connection.')),
          findsOneWidget);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('a still-pending (not yet synced) expense opens its details, without Edit',
        (tester) async {
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
      final outbox = Outbox(db, client, groupId: 'g1');

      await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Snacks'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.textContaining('Waiting to sync'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Edit'), findsNothing);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    // Issue #90 part 2: Delete, end to end through the list.
    String groupJson() =>
        '[{"result":{"data":{"json":{"group":{"id":"g1","name":"Banff Trip",'
        '"currency":"\$","participants":[{"id":"p1","name":"Ken"}]}}}}}]';
    String listJson(List<String> titles) => '[{"result":{"data":{"json":{"expenses":['
        '${titles.map((t) => '{"id":"$t","title":"$t","amount":500,"paidBy":"p1",'
            '"paidFor":[{"participant":"p1","shares":1}],"splitMode":"EVENLY","category":0,'
            '"notes":"","expenseDate":"2026-09-16T00:00:00.000Z","isReimbursement":false}').join(',')}'
        '],"hasMore":false}}}}]';
    Expense cached(String id) => Expense(
          id: id,
          groupId: 'g1',
          title: id,
          amountCents: 500,
          paidBy: 'p1',
          paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
          date: DateTime.utc(2026, 9, 16),
        );

    Future<void> deleteFromList(WidgetTester tester, String title) async {
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byType(BottomSheet), matching: find.widgetWithText(OutlinedButton, 'Delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byWidgetPredicate((w) => w is AlertDialog), matching: find.text('Delete')));
      await tester.pumpAndSettle();
    }

    testWidgets('Delete removes it from the list, credited to you, even when the refresh after fails',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.cacheGroup(cachedGroup);
      await db.replaceServerExpenses('g1', [cached('Coffee'), cached('Tea')]);
      http.Request? deleted;
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          if (req.url.toString().contains('groups.expenses.delete')) {
            deleted = req;
            return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
          }
          throw Exception('offline'); // every refresh fails
        }),
      );
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(
            client: client, db: db, outbox: Outbox(db, client, groupId: 'g1'), groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      await deleteFromList(tester, 'Coffee');

      expect((jsonDecode(deleted!.body) as Map)['0']['json']['participantId'], 'p1');
      expect(find.text('Coffee'), findsNothing);
      expect(find.text('Tea'), findsOneWidget);
      expect((await db.expensesForGroup('g1')).map((e) => e.id), ['Tea']);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('a refresh already in flight when the delete lands does not bring it back',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.cacheGroup(cachedGroup);
      await db.replaceServerExpenses('g1', [cached('Coffee'), cached('Tea')]);
      final staleList = Completer<http.Response>();
      var lists = 0;
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          final url = req.url.toString();
          if (url.contains('groups.expenses.delete')) {
            return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
          }
          if (url.contains('groups.expenses.list')) {
            lists++;
            // The first refresh fetched before the delete: held, then
            // answers with the old list.
            if (lists == 1) return staleList.future;
            return http.Response(listJson(['Tea']), 200);
          }
          if (url.contains('groups.get')) return http.Response(groupJson(), 200);
          throw Exception('offline');
        }),
      );
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(
            client: client, db: db, outbox: Outbox(db, client, groupId: 'g1'), groupId: 'g1'),
      ));
      await tester.pumpAndSettle();
      expect(lists, 1); // the startup refresh is waiting on its list

      await deleteFromList(tester, 'Coffee');
      expect(lists, 2); // the delete's own refresh came and went

      staleList.complete(http.Response(listJson(['Coffee', 'Tea']), 200));
      await tester.pumpAndSettle();

      expect(find.text('Coffee'), findsNothing);
      expect((await db.expensesForGroup('g1')).map((e) => e.id), ['Tea']);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  });

  // Issue #44's retry/delete, folded into the details sheet (issue #90).
  group('sync failure retry/discard (issues #44, #90)', () {
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
      final outbox = Outbox(db, client, groupId: 'g1');

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

    testWidgets('a sync-failed expense opens its details with the error, Retry and Discard',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.cacheGroup(cachedGroup);
      await insertFailedExpense(db);

      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw Exception('not used')),
      );
      final outbox = Outbox(db, client, groupId: 'g1');

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
      expect(find.text('Discard'), findsOneWidget);
      // Deliberately no Edit: it never reached the server, and this app
      // is view+add only offline, never offline edit.
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
      final outbox = Outbox(db, client, groupId: 'g1');

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

    testWidgets('Discard removes the sync-failed expense from the list and the local db',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.cacheGroup(cachedGroup);
      await insertFailedExpense(db);

      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw Exception('not used')),
      );
      final outbox = Outbox(db, client, groupId: 'g1');

      await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Snacks'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
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
    final outbox = Outbox(db, client, groupId: 'g1');

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
      final outbox = Outbox(db, client, groupId: 'g1');
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

    testWidgets('the add button only shows on the Expenses tab; search is in the bottom bar on every tab (#84)',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpGroupScreen(tester, db);

      final searchInAppBar =
          find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.search));
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.byIcon(Icons.search), findsOneWidget);
      expect(searchInAppBar, findsNothing);

      for (final tab in ['Balance', 'Stats', 'Activities']) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();

        expect(find.byType(FloatingActionButton), findsNothing);
        expect(find.byIcon(Icons.search), findsOneWidget);
        expect(searchInAppBar, findsNothing);
      }
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

    testWidgets('the search button opens search; Back returns to the Expenses tab (#39)',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpGroupScreen(tester, db);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      expect(find.byType(ExpenseSearchScreen), findsOneWidget);
      expect(find.text('Search this group'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(ExpenseSearchScreen), findsNothing);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('the search button opens search from another tab too, and Back keeps that tab (#39, #84)',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpGroupScreen(tester, db);

      await tester.tap(find.text('Stats'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      expect(find.byType(ExpenseSearchScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(StatsScreen), findsOneWidget);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    // Issue #3: a ⋯ menu in place of the settings button, like spliit-ios.
    Future<List<(Uri, String?)>> pumpWithShare(WidgetTester tester, AppDatabase db,
        {bool cacheGroup = true}) async {
      if (cacheGroup) await db.cacheGroup(cachedGroup);
      final shared = <(Uri, String?)>[];
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw Exception('offline')),
      );
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(
          client: client,
          db: db,
          outbox: Outbox(db, client, groupId: 'g1'),
          groupId: 'g1',
          shareLink: (link, subject) async => shared.add((link, subject)),
        ),
      ));
      await tester.pumpAndSettle();
      return shared;
    }

    testWidgets('the top bar has a ⋯ menu with Group settings and Share group (#3)', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpWithShare(tester, db);

      expect(find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.settings_outlined)),
          findsNothing);
      await tester.tap(find.byTooltip('Group actions'));
      await tester.pumpAndSettle();
      expect(find.text('Group settings'), findsOneWidget);
      expect(find.text('Share group'), findsOneWidget);

      await tester.tap(find.text('Group settings'));
      await tester.pumpAndSettle();
      expect(find.byType(GroupSettingsScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('Share group shares <server>/groups/<id> with the group name, offline too (#3)',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final shared = await pumpWithShare(tester, db);

      await tester.tap(find.byTooltip('Group actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share group'));
      await tester.pumpAndSettle();

      expect(shared, [(Uri.parse('https://example.test/groups/g1'), 'Banff Trip')]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('before the group has ever loaded, settings is disabled but sharing still works (#3)',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final shared = await pumpWithShare(tester, db, cacheGroup: false);

      await tester.tap(find.byTooltip('Group actions'));
      await tester.pumpAndSettle();
      final settings = tester.widget<PopupMenuItem<Object?>>(find.ancestor(
          of: find.text('Group settings'), matching: find.byWidgetPredicate((w) => w is PopupMenuItem)));
      expect(settings.enabled, isFalse);
      await tester.tap(find.text('Share group'));
      await tester.pumpAndSettle();

      expect(shared, [(Uri.parse('https://example.test/groups/g1'), null)]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    NavigationDestinationLabelBehavior labelBehavior(WidgetTester tester) =>
        tester.widget<NavigationBar>(find.byType(NavigationBar)).labelBehavior!;

    testWidgets('tab labels show when they fit beside the search button (#84)', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpGroupScreen(tester, db);

      expect(labelBehavior(tester), NavigationDestinationLabelBehavior.alwaysShow);
      final screenHeight = tester.getSize(find.byType(GroupScreen)).height;
      expect(tester.getTopLeft(find.byType(NavigationBar)).dy,
          screenHeight - tester.getSize(find.byType(NavigationBar)).height,
          reason: 'the bottom bar must stay at its own height, not take over the screen');
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('tab labels hide, but stay as tooltips, when a label is too wide for its tab (#84)',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpGroupScreen(tester, db);

      expect(labelBehavior(tester), NavigationDestinationLabelBehavior.alwaysHide);
      expect(find.byTooltip('Stats'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.bar_chart_outlined));
      await tester.pumpAndSettle();
      expect(find.byType(StatsScreen), findsOneWidget);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    // Landscape on a phone with a side cutout and a home indicator.
    void useLandscapeWithInsets(WidgetTester tester) {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(left: 47, right: 47, bottom: 21);
      addTearDown(tester.view.reset);
    }

    Future<void> pumpWithBuilder(WidgetTester tester, AppDatabase db,
        {Locale locale = const Locale('en'), TransitionBuilder? builder}) async {
      await db.cacheGroup(cachedGroup);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw Exception('offline')),
      );
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: builder,
        home: GroupScreen(
            client: client, db: db, outbox: Outbox(db, client, groupId: 'g1'), groupId: 'g1'),
      ));
      await tester.pumpAndSettle();
    }

    void expectBottomBarInsideSafeArea(WidgetTester tester) {
      final search = tester.getRect(find.byIcon(Icons.search));
      final bar = tester.getRect(find.byType(NavigationBar));
      expect(bar.left, 47, reason: 'tabs start at the safe edge, not doubly inset');
      expect(search.right, lessThanOrEqualTo(844 - 47));
      expect(bar.bottom, 390 - 21);
      expect(search.top, greaterThanOrEqualTo(bar.top));
      expect(search.bottom, lessThanOrEqualTo(bar.bottom));
    }

    testWidgets('the whole bottom bar, search included, stays inside safe-area insets (#84 review)',
        (tester) async {
      useLandscapeWithInsets(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpWithBuilder(tester, db);

      expectBottomBarInsideSafeArea(tester);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('inside the app-wide SafeArea too, the insets are not applied twice (#84 review)',
        (tester) async {
      useLandscapeWithInsets(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpWithBuilder(tester, db, builder: spliit2goAppBuilder);

      expectBottomBarInsideSafeArea(tester);
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('French at double text size on a narrow phone hides labels without overflowing (#84 review)',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpWithBuilder(tester, db, locale: const Locale('fr'));

      expect(tester.takeException(), isNull);
      expect(labelBehavior(tester), NavigationDestinationLabelBehavior.alwaysHide);
      expect(find.byTooltip('Statistiques'), findsOneWidget);
      expect(tester.getRect(find.byIcon(Icons.search)).right, lessThanOrEqualTo(360));
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

  group('date sections (issue #88)', () {
    // Relative to the real today, so each lands in the same section
    // whatever day the tests run.
    Expense dated(String title, DateTime date) => Expense(
        id: title,
        groupId: 'g1',
        title: title,
        amountCents: 100,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        date: date);

    testWidgets('expenses sit under their date headings, in display order', (tester) async {
      final semantics = tester.ensureSemantics();
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.cacheGroup(const Group(
          id: 'g1', name: 'Banff Trip', currency: '\$', participants: [Participant(id: 'p1', name: 'Ken')]));
      final now = DateTime.now();
      await db.replaceServerExpenses('g1', [
        dated('Long ago', DateTime(now.year - 3, 1, 1)),
        dated('Tomorrow', DateTime(now.year, now.month, now.day + 1)),
        dated('Today', DateTime(now.year, now.month, now.day)),
      ]);
      final client = offlineClient();
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(client: client, db: db, outbox: Outbox(db, client, groupId: 'g1'), groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      final order = ['UPCOMING', 'Tomorrow', 'THIS WEEK', 'Today', 'OLDER', 'Long ago'];
      for (var i = 1; i < order.length; i++) {
        expect(top(order[i]), greaterThan(top(order[i - 1])), reason: '${order[i]} after ${order[i - 1]}');
      }
      expect(find.text('EARLIER THIS MONTH'), findsNothing, reason: 'empty sections are skipped');
      // Read as a heading, in its natural case.
      expect(find.bySemanticsLabel('This week'), findsOneWidget);
      semantics.dispose();
      // See the first test above for why. (issue #47)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  });
}
