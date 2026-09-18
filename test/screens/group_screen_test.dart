import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/group_screen.dart';
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
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Coffee'));
      await tester.pumpAndSettle();

      expect(find.text('Edit expense'), findsOneWidget);
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
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Coffee'));
      await tester.pumpAndSettle();

      expect(find.text('Edit expense'), findsNothing);
      expect(find.textContaining('needs a connection'), findsOneWidget);
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
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();

      final tile = tester.widget<ListTile>(find.widgetWithText(ListTile, 'Snacks'));
      expect(tile.onTap, isNull);
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
  });
}
