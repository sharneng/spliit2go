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
import 'package:spliit2go/models/category.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/expense_details_sheet.dart';
import 'package:spliit2go/sync/outbox.dart';

// Issue #90: tapping an expense shows its details in a sheet, with Edit,
// Retry and Discard inside it depending on the expense's state.
void main() {
  // Not named `group`: that would hide flutter_test's group().
  const banff = Group(
    id: 'g1',
    name: 'Banff Trip',
    currency: '\$',
    participants: [
      Participant(id: 'alex', name: 'Alex'),
      Participant(id: 'bea', name: 'Bea'),
    ],
  );
  const diningOut = Category(id: 8, name: 'Dining Out', grouping: 'Food and Drink');

  Expense dinner({String title = 'Dinner'}) => Expense(
        id: 'e1',
        groupId: 'g1',
        title: title,
        amountCents: 6000,
        paidBy: 'bea',
        paidFor: const [
          ExpenseShare(participantId: 'alex', shares: 2),
          ExpenseShare(participantId: 'bea', shares: 1),
        ],
        splitMode: SplitMode.byShares,
        category: 8,
        notes: 'Birthday dinner',
        date: DateTime(2026, 9, 16),
        recurrenceRule: RecurrenceRule.weekly,
        originalAmountCents: 5500,
        originalCurrency: 'EUR',
        conversionRate: 1.09,
      );

  /// groups.expenses.get's response for [dinner].
  String expenseResponse({String title = 'Dinner'}) => jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'expense': {
                  'id': 'e1',
                  'title': title,
                  'amount': 6000,
                  'paidBy': 'bea',
                  'paidFor': [
                    {'participant': 'alex', 'shares': 2},
                    {'participant': 'bea', 'shares': 1},
                  ],
                  'splitMode': 'BY_SHARES',
                  'category': 8,
                  'notes': 'Birthday dinner',
                  'expenseDate': '2026-09-16T00:00:00.000Z',
                  'isReimbursement': false,
                },
              },
            },
          },
        },
      ]);

  const notFound =
      '[{"error":{"json":{"message":"Expense not found","code":-32004,"data":{"code":"NOT_FOUND"}}}}]';

  SpliitClient serverClient(Future<http.Response> Function(http.Request req) handler) =>
      SpliitClient(baseUrl: 'https://example.test', httpClient: MockClient(handler));

  final offlineClient = serverClient((_) async => throw Exception('offline'));

  bool? result;
  setUp(() => result = null);

  /// A screen with a button that opens the sheet and records what
  /// showExpenseDetails returned.
  Future<void> openSheet(
    WidgetTester tester,
    AppDatabase db, {
    SpliitClient? client,
    bool fetchIfMissing = false,
    Stream<bool> connectivity = const Stream.empty(),
    String? activeUserId,
    Locale locale = const Locale('en'),
    TransitionBuilder? builder,
  }) async {
    final c = client ?? offlineClient;
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: builder,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                result = await showExpenseDetails(
                  context,
                  expenseId: 'e1',
                  group: banff,
                  db: db,
                  client: c,
                  outbox: Outbox(db, c, groupId: 'g1'),
                  categories: const [diningOut],
                  activeUserId: activeUserId,
                  fetchIfMissing: fetchIfMissing,
                  connectivity: connectivity,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// The sheet watches its row in drift; tear the tree down this way or
  /// the watch's zero-length timer fails the test (issue #47).
  Future<void> closeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// Room for the whole sheet, so nothing sits below a lazy list's fold.
  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<AppDatabase> cachedDb([Expense? e]) async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.replaceServerExpenses('g1', [e ?? dinner()]);
    return db;
  }

  Finder inSheet(Finder f) => find.descendant(of: find.byType(BottomSheet), matching: f);

  testWidgets('shows a cached expense\'s details, offline', (tester) async {
    tallView(tester);
    final db = await cachedDb();
    addTearDown(db.close);
    await openSheet(tester, db, activeUserId: 'bea');

    expect(inSheet(find.text('Dinner')), findsOneWidget);
    expect(inSheet(find.text('\$60.00')), findsOneWidget);
    expect(inSheet(find.text('Originally €55.00')), findsOneWidget);
    expect(inSheet(find.text('Repeats weekly')), findsOneWidget);
    expect(inSheet(find.text('Sep 16, 2026')), findsOneWidget);
    expect(inSheet(find.text('Dining Out')), findsOneWidget);
    // Bea paid, and is this device's active user.
    expect(inSheet(find.text('Bea (you)')), findsNWidgets(2));
    // By shares, 2:1 -- the same apportionment Balances and Stats use.
    expect(inSheet(find.text('Shares')), findsOneWidget);
    expect(inSheet(find.text('\$40.00')), findsOneWidget);
    expect(inSheet(find.text('\$20.00')), findsOneWidget);
    expect(inSheet(find.text('Birthday dinner')), findsOneWidget);
    expect(inSheet(find.widgetWithText(FilledButton, 'Edit')), findsOneWidget);
    expect(inSheet(find.text('Reimbursement')), findsNothing);

    // Dismissing isn't a change.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(result, isFalse);
    await closeTree(tester);
  });

  testWidgets('an evenly split reimbursement with no extras', (tester) async {
    tallView(tester);
    final db = await cachedDb(Expense(
      id: 'e1',
      groupId: 'g1',
      title: 'Payback',
      amountCents: 1000,
      paidBy: 'alex',
      paidFor: const [ExpenseShare(participantId: 'bea', shares: 1)],
      isReimbursement: true,
      date: DateTime(2026, 9, 16),
    ));
    addTearDown(db.close);
    await openSheet(tester, db);

    expect(inSheet(find.text('Reimbursement')), findsOneWidget);
    expect(inSheet(find.text('Evenly')), findsOneWidget);
    expect(inSheet(find.textContaining('Originally')), findsNothing);
    expect(inSheet(find.textContaining('Repeats')), findsNothing);
    expect(inSheet(find.text('Notes')), findsNothing);
    // No active user: nobody is marked "you". Category 0 reads General.
    expect(inSheet(find.textContaining('(you)')), findsNothing);
    expect(inSheet(find.text('General')), findsOneWidget);
    await closeTree(tester);
  });

  testWidgets('a participant no longer in the group reads "Someone"', (tester) async {
    tallView(tester);
    final db = await cachedDb(Expense(
      id: 'e1',
      groupId: 'g1',
      title: 'Taxi',
      amountCents: 1000,
      paidBy: 'gone',
      paidFor: const [
        ExpenseShare(participantId: 'gone', shares: 1),
        ExpenseShare(participantId: 'alex', shares: 1),
      ],
      date: DateTime(2026, 9, 16),
    ));
    addTearDown(db.close);
    await openSheet(tester, db);

    expect(inSheet(find.text('Someone')), findsNWidgets(2));
    expect(inSheet(find.text('Alex')), findsOneWidget);
    await closeTree(tester);
  });

  testWidgets('known offline: Edit is disabled with the reason shown, until back online',
      (tester) async {
    final db = await cachedDb();
    addTearDown(db.close);
    final online = StreamController<bool>();
    addTearDown(online.close);
    await openSheet(tester, db, connectivity: online.stream);

    online.add(false);
    await tester.pumpAndSettle();
    FilledButton edit() =>
        tester.widget<FilledButton>(inSheet(find.widgetWithText(FilledButton, 'Edit')));
    expect(edit().onPressed, isNull);
    expect(inSheet(find.text('Editing an expense needs a connection.')), findsOneWidget);

    online.add(true);
    await tester.pumpAndSettle();
    expect(edit().onPressed, isNotNull);
    expect(inSheet(find.text('Editing an expense needs a connection.')), findsNothing);
    await closeTree(tester);
  });

  testWidgets('Edit on an expense deleted elsewhere says so and stays open', (tester) async {
    final db = await cachedDb();
    addTearDown(db.close);
    await openSheet(tester, db, client: serverClient((_) async => http.Response(notFound, 404)));

    await tester.tap(inSheet(find.widgetWithText(FilledButton, 'Edit')));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet(find.text('This expense is no longer available.')), findsOneWidget);
    expect(find.text('Edit expense'), findsNothing);
    await closeTree(tester);
  });

  testWidgets('a saved edit is reported as a change', (tester) async {
    tallView(tester);
    final db = await cachedDb();
    addTearDown(db.close);
    var updates = 0;
    await openSheet(tester, db, client: serverClient((req) async {
      final url = req.url.toString();
      if (url.contains('groups.expenses.get')) return http.Response(expenseResponse(), 200);
      if (url.contains('groups.expenses.update')) {
        updates++;
        return http.Response('[{"result":{"data":{"json":{"expenseId":"e1"}}}}]', 200);
      }
      return http.Response('offline', 500);
    }));

    await tester.tap(inSheet(find.widgetWithText(FilledButton, 'Edit')));
    await tester.pumpAndSettle();
    expect(find.text('Edit expense'), findsOneWidget);

    final save = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(updates, 1);
    expect(find.text('Edit expense'), findsNothing);
    expect(result, isTrue);
    await closeTree(tester);
  });

  testWidgets('the sheet follows its row: updates when it changes, closes when it goes',
      (tester) async {
    final db = await cachedDb();
    addTearDown(db.close);
    await openSheet(tester, db);

    // A refresh brings someone else's edit.
    await tester.runAsync(() => db.replaceServerExpenses('g1', [dinner(title: 'Team dinner')]));
    await tester.pumpAndSettle();
    expect(inSheet(find.text('Team dinner')), findsOneWidget);

    // A refresh no longer has it.
    await tester.runAsync(() => db.replaceServerExpenses('g1', []));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(result, isFalse);
    await closeTree(tester);
  });

  group('pending and failed expenses', () {
    Expense snacks() => Expense(
          id: 'e1',
          groupId: 'g1',
          title: 'Snacks',
          amountCents: 300,
          paidBy: 'alex',
          paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
          date: DateTime(2026, 9, 16),
          pending: true,
        );

    Future<AppDatabase> failedDb() async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.insertPending(snacks());
      await db.recordSyncFailure(
          id: 'e1', error: 'SpliitApiException(400): bad request', retryCount: 1, failed: true);
      return db;
    }

    testWidgets('a pending expense can be viewed but not edited', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.insertPending(snacks());
      await openSheet(tester, db);

      expect(inSheet(find.text('Snacks')), findsOneWidget);
      expect(inSheet(find.textContaining('Waiting to sync')), findsOneWidget);
      expect(inSheet(find.widgetWithText(FilledButton, 'Edit')), findsNothing);
      await closeTree(tester);
    });

    testWidgets('Retry requeues it and reports a change', (tester) async {
      final db = await failedDb();
      addTearDown(db.close);
      await openSheet(tester, db);

      expect(inSheet(find.text("Couldn't sync this expense")), findsOneWidget);
      expect(inSheet(find.textContaining('bad request')), findsOneWidget);
      await tester.tap(inSheet(find.text('Retry')));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(result, isTrue);
      final row = (await tester.runAsync(() => db.pendingExpensesForGroup('g1')))!.single;
      expect(row.syncFailed, isFalse);
      await closeTree(tester);
    });

    testWidgets('Discard removes this device\'s copy and reports a change', (tester) async {
      final db = await failedDb();
      addTearDown(db.close);
      await openSheet(tester, db);

      await tester.tap(inSheet(find.text('Discard')));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(result, isTrue);
      expect(await tester.runAsync(() => db.expensesForGroup('g1')), isEmpty);
      await closeTree(tester);
    });

    testWidgets('a retry elsewhere while the sheet is open takes Discard away', (tester) async {
      final db = await failedDb();
      addTearDown(db.close);
      await openSheet(tester, db);
      expect(inSheet(find.text('Discard')), findsOneWidget);

      await tester.runAsync(() => db.retrySyncFailure('e1'));
      await tester.pumpAndSettle();

      expect(inSheet(find.text('Discard')), findsNothing);
      expect(inSheet(find.textContaining('Waiting to sync')), findsOneWidget);
      await closeTree(tester);
    });
  });

  group('Activity: an expense this device may not have cached', () {
    testWidgets('a cache hit shows the cached copy without asking the server', (tester) async {
      final db = await cachedDb();
      addTearDown(db.close);
      var fetches = 0;
      await openSheet(tester, db, fetchIfMissing: true, client: serverClient((_) async {
        fetches++;
        return http.Response(expenseResponse(title: 'From server'), 200);
      }));

      expect(inSheet(find.text('Dinner')), findsOneWidget);
      expect(fetches, 0);
      await closeTree(tester);
    });

    testWidgets('a cache miss loads it from the server', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await openSheet(tester, db,
          fetchIfMissing: true,
          client: serverClient((_) async => http.Response(expenseResponse(), 200)));

      expect(inSheet(find.text('Dinner')), findsOneWidget);
      expect(inSheet(find.widgetWithText(FilledButton, 'Edit')), findsOneWidget);
      await closeTree(tester);
    });

    testWidgets('deleted on the server: "no longer available"', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await openSheet(tester, db,
          fetchIfMissing: true,
          client: serverClient((_) async => http.Response(notFound, 404)));

      expect(inSheet(find.text('This expense is no longer available.')), findsOneWidget);
      expect(inSheet(find.text('Retry')), findsNothing);
      await closeTree(tester);
    });

    testWidgets('offline with nothing cached says details need a connection', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await openSheet(tester, db, fetchIfMissing: true, connectivity: Stream.value(false));

      expect(inSheet(find.text('Opening this expense needs a connection.')), findsOneWidget);
      await closeTree(tester);
    });

    testWidgets('a failed load can be retried', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      var fail = true;
      await openSheet(tester, db,
          fetchIfMissing: true,
          client: serverClient((_) async =>
              fail ? http.Response('server error', 500) : http.Response(expenseResponse(), 200)));

      expect(inSheet(find.text("Couldn't load this expense.")), findsOneWidget);
      fail = false;
      await tester.tap(inSheet(find.text('Retry')));
      await tester.pumpAndSettle();
      expect(inSheet(find.text('Dinner')), findsOneWidget);
      await closeTree(tester);
    });
  });

  testWidgets('without a server fallback, a missing expense reads "no longer available"',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await openSheet(tester, db);

    expect(inSheet(find.text('This expense is no longer available.')), findsOneWidget);
    await closeTree(tester);
  });

  for (final locale in const [Locale('en'), Locale('fr'), Locale('zh')]) {
    testWidgets('fits a narrow phone at double text size ($locale)', (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.replaceServerExpenses('g1', [dinner(title: 'A long expense title that wraps')]);
      await openSheet(tester, db,
          locale: locale,
          activeUserId: 'bea',
          connectivity: Stream.value(false),
          builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ));

      // Drag the sheet open fully and scroll it to the end.
      await tester.drag(find.byType(BottomSheet), const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(BottomSheet), const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await closeTree(tester);
    });
  }
}
