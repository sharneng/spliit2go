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

  testWidgets('known offline: Edit and Delete are disabled with the reason shown, until back online',
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
    OutlinedButton delete() =>
        tester.widget<OutlinedButton>(inSheet(find.widgetWithText(OutlinedButton, 'Delete')));
    const reason = 'Editing or deleting an expense needs a connection.';
    expect(edit().onPressed, isNull);
    expect(delete().onPressed, isNull);
    expect(inSheet(find.text(reason)), findsOneWidget);

    online.add(true);
    await tester.pumpAndSettle();
    expect(edit().onPressed, isNotNull);
    expect(delete().onPressed, isNotNull);
    expect(inSheet(find.text(reason)), findsNothing);
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

  // #119 review: Edit used to call every non-404 failure a connection
  // problem, and drop the error.
  testWidgets('Edit on a malformed response says so, logged, with details', (tester) async {
    final db = await cachedDb();
    addTearDown(db.close);
    final logs = <String>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    // Restored in the test body: flutter_test checks debugPrint before
    // tear-downs run.
    try {
      await openSheet(tester, db,
          client: serverClient((_) async => http.Response('[{"result":{"data":{"json":{}}}}]', 200)));

      await tester.tap(inSheet(find.widgetWithText(FilledButton, 'Edit')));
      await tester.pumpAndSettle();

      expect(inSheet(find.text("Couldn't open this expense for editing.")), findsOneWidget);
      expect(inSheet(find.text('Editing an expense needs a connection.')), findsNothing);
      expect(inSheet(find.text('Tap for details')), findsOneWidget);
      expect(logs.where((l) => l.contains('Fetching expense e1 to edit')), hasLength(1));
      await closeTree(tester);
    } finally {
      debugPrint = original;
    }
  });

  testWidgets('Edit with no connection says so, with no details', (tester) async {
    final db = await cachedDb();
    addTearDown(db.close);
    await openSheet(tester, db,
        client: serverClient((_) async => throw http.ClientException('Failed host lookup')));

    await tester.tap(inSheet(find.widgetWithText(FilledButton, 'Edit')));
    await tester.pumpAndSettle();

    expect(inSheet(find.text('Editing an expense needs a connection.')), findsOneWidget);
    expect(inSheet(find.text('Tap for details')), findsNothing);
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

  group('Delete (#90 part 2)', () {
    const ok = '[{"result":{"data":{"json":{}}}}]';
    // AlertDialog.adaptive builds a subclass, which byType wouldn't match.
    Finder inDialog(Finder f) =>
        find.descendant(of: find.byWidgetPredicate((w) => w is AlertDialog), matching: f);

    Future<void> tapDelete(WidgetTester tester) async {
      await tester.tap(inSheet(find.widgetWithText(OutlinedButton, 'Delete')));
      await tester.pumpAndSettle();
    }

    testWidgets('asks first; Cancel changes nothing', (tester) async {
      final db = await cachedDb();
      addTearDown(db.close);
      var calls = 0;
      await openSheet(tester, db, client: serverClient((_) async {
        calls++;
        return http.Response(ok, 200);
      }));

      await tapDelete(tester);
      expect(inDialog(find.text('Delete this expense?')), findsOneWidget);
      expect(
          inDialog(find.text('"Dinner" will be deleted for everyone in the group. '
              "This can't be undone.")),
          findsOneWidget);
      await tester.tap(inDialog(find.text('Cancel')));
      await tester.pumpAndSettle();

      expect(calls, 0);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(await tester.runAsync(() => db.expensesForGroup('g1')), hasLength(1));
      await closeTree(tester);
    });

    testWidgets('confirmed: deletes on the server, credited to the active user, then locally',
        (tester) async {
      final db = await cachedDb();
      addTearDown(db.close);
      await db.cacheGroup(banff);
      await db.setActiveParticipant('g1', 'bea');
      http.Request? deleteRequest;
      await openSheet(tester, db, client: serverClient((req) async {
        if (req.url.toString().contains('groups.expenses.delete')) deleteRequest = req;
        return http.Response(ok, 200);
      }));

      await tapDelete(tester);
      await tester.tap(inDialog(find.text('Delete')));
      await tester.pumpAndSettle();

      final sent = (jsonDecode(deleteRequest!.body) as Map<String, dynamic>)['0']['json'];
      expect(sent, {'groupId': 'g1', 'expenseId': 'e1', 'participantId': 'bea'});
      expect(find.byType(BottomSheet), findsNothing);
      expect(result, isTrue);
      expect(await tester.runAsync(() => db.expensesForGroup('g1')), isEmpty);
      // A refresh already in flight can't bring it back.
      expect(db.expensesGeneration('g1'), 1);
      await closeTree(tester);
    });

    testWidgets('while it runs, nothing else can be tapped', (tester) async {
      final db = await cachedDb();
      addTearDown(db.close);
      final response = Completer<http.Response>();
      await openSheet(tester, db, client: serverClient((_) => response.future));

      await tapDelete(tester);
      await tester.tap(inDialog(find.text('Delete')));
      await tester.pump();
      await tester.pump();

      expect(
          tester.widget<FilledButton>(inSheet(find.widgetWithText(FilledButton, 'Edit'))).onPressed,
          isNull);
      expect(
          tester
              .widget<OutlinedButton>(inSheet(find.widgetWithText(OutlinedButton, 'Delete')))
              .onPressed,
          isNull);
      expect(inSheet(find.byType(CircularProgressIndicator)), findsOneWidget);

      response.complete(http.Response(ok, 200));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      await closeTree(tester);
    });

    testWidgets('a failure keeps the expense and says so in the sheet', (tester) async {
      final db = await cachedDb();
      addTearDown(db.close);
      await openSheet(tester, db, client: serverClient((req) async {
        if (req.url.toString().contains('groups.expenses.delete')) {
          return http.Response('server error', 500);
        }
        return http.Response(expenseResponse(), 200); // still there
      }));

      await tapDelete(tester);
      await tester.tap(inDialog(find.text('Delete')));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      // A server error is unexpected (#119 review): its own message, with
      // details, rather than "check your connection".
      expect(inSheet(find.text("Couldn't delete this expense.")), findsOneWidget);
      expect(inSheet(find.text('Tap for details')), findsOneWidget);
      expect(await tester.runAsync(() => db.expensesForGroup('g1')), hasLength(1));
      expect(db.expensesGeneration('g1'), 0);
      expect(
          tester
              .widget<OutlinedButton>(inSheet(find.widgetWithText(OutlinedButton, 'Delete')))
              .onPressed,
          isNotNull);
      await closeTree(tester);
    });

    testWidgets('offline: the expense stays, "check your connection", no details (#119)',
        (tester) async {
      final db = await cachedDb();
      addTearDown(db.close);
      var fetches = 0;
      await openSheet(tester, db, client: serverClient((req) async {
        if (req.url.toString().contains('groups.expenses.get')) fetches++;
        throw http.ClientException('Failed host lookup');
      }));

      await tapDelete(tester);
      await tester.tap(inDialog(find.text('Delete')));
      await tester.pumpAndSettle();

      expect(fetches, 1); // still double-checked, as before
      expect(inSheet(find.text("Couldn't delete this expense. Check your connection and try again.")),
          findsOneWidget);
      expect(inSheet(find.text('Tap for details')), findsNothing);
      expect(await tester.runAsync(() => db.expensesForGroup('g1')), hasLength(1));
      await closeTree(tester);
    });

    // Upstream errors when deleting an expense that's already gone (a
    // retry after a lost response), so "not found" afterwards means done.
    testWidgets('a failure for an expense that is already gone counts as deleted',
        (tester) async {
      final db = await cachedDb();
      addTearDown(db.close);
      await openSheet(tester, db, client: serverClient((req) async {
        if (req.url.toString().contains('groups.expenses.delete')) {
          return http.Response('internal error', 500);
        }
        return http.Response(notFound, 404);
      }));

      await tapDelete(tester);
      await tester.tap(inDialog(find.text('Delete')));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(result, isTrue);
      expect(await tester.runAsync(() => db.expensesForGroup('g1')), isEmpty);
      await closeTree(tester);
    });

    testWidgets('an expense opened from Activity, not cached, can be deleted', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await openSheet(tester, db, fetchIfMissing: true, client: serverClient((req) async {
        if (req.url.toString().contains('groups.expenses.delete')) return http.Response(ok, 200);
        return http.Response(expenseResponse(), 200);
      }));

      await tapDelete(tester);
      await tester.tap(inDialog(find.text('Delete')));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(result, isTrue);
      await closeTree(tester);
    });

    testWidgets('dismissed while deleting: the local copy still goes once the server confirms',
        (tester) async {
      final db = await cachedDb();
      addTearDown(db.close);
      final response = Completer<http.Response>();
      await openSheet(tester, db, client: serverClient((_) => response.future));

      await tapDelete(tester);
      await tester.tap(inDialog(find.text('Delete')));
      await tester.pump();
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);

      response.complete(http.Response(ok, 200));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(() => db.expensesForGroup('g1')), isEmpty);
      await closeTree(tester);
    });
  });

  // PR #95 left this: drift re-emits on every write to the table, and the
  // sheet refetched an uncached expense each time.
  testWidgets('an expense loaded from the server isn\'t refetched on unrelated writes',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    var fetches = 0;
    await openSheet(tester, db, fetchIfMissing: true, client: serverClient((_) async {
      fetches++;
      return http.Response(expenseResponse(), 200);
    }));
    expect(fetches, 1);

    // One unrelated write. (A second write in the same runAsync would
    // deadlock: the first one's stream refresh runs in the test's fake
    // zone and holds drift's lock until the test pumps.)
    await tester.runAsync(() async {
      await db.insertPending(Expense(
          id: 'other',
          groupId: 'g1',
          title: 'Other',
          amountCents: 100,
          paidBy: 'alex',
          paidFor: const [],
          date: DateTime(2026, 9, 16),
          pending: true));
    });
    await tester.pumpAndSettle();

    expect(fetches, 1);
    expect(inSheet(find.text('Dinner')), findsOneWidget);
    await closeTree(tester);
  });

  // PR #95 review (Ezra): dismissing the sheet (barrier, swipe, Back) pops
  // it without the sheet's own close path. A late Edit fetch or row change
  // landing during its closing animation must not pop a second route --
  // in the app, that's GroupScreen itself.
  group('a late callback after the sheet is dismissed', () {
    Future<(_PopCounter, AppDatabase)> openFromCaller(
        WidgetTester tester, SpliitClient client) async {
      final pops = _PopCounter();
      final db = await cachedDb();
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        navigatorObservers: [pops],
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showExpenseDetails(
                      context,
                      expenseId: 'e1',
                      group: banff,
                      db: db,
                      client: client,
                      outbox: Outbox(db, client, groupId: 'g1'),
                      connectivity: const Stream.empty(),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            )),
            child: const Text('caller'),
          ),
        ),
      ));
      await tester.tap(find.text('caller'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      pops.count = 0;
      return (pops, db);
    }

    testWidgets('an Edit fetch completing mid-dismissal pops nothing more', (tester) async {
      final response = Completer<http.Response>();
      final (pops, db) = await openFromCaller(tester, serverClient((_) => response.future));
      addTearDown(db.close);

      await tester.tap(inSheet(find.widgetWithText(FilledButton, 'Edit')));
      await tester.pump();
      await tester.tapAt(const Offset(20, 20)); // the modal barrier
      await tester.pump(const Duration(milliseconds: 10));
      response.complete(http.Response(expenseResponse(), 200));
      await tester.pumpAndSettle();

      expect(pops.count, 1);
      expect(find.text('open'), findsOneWidget); // the caller is still there
      expect(find.text('Edit expense'), findsNothing);
      await closeTree(tester);
    });

    // PR #96 review (Ezra): the Delete confirmation covers the sheet
    // without dismissing it. If the expense goes away meanwhile, the sheet
    // must close once the confirmation ends -- not pop the dialog, not
    // stay stuck showing a deleted expense, and not send the delete.
    Finder inDialog(Finder f) =>
        find.descendant(of: find.byWidgetPredicate((w) => w is AlertDialog), matching: f);

    Future<(_PopCounter, AppDatabase, List<String>)> confirmWhileItGoes(
        WidgetTester tester) async {
      final deletes = <String>[];
      final (pops, db) = await openFromCaller(tester, serverClient((req) async {
        if (req.url.toString().contains('groups.expenses.delete')) deletes.add(req.body);
        return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
      }));
      await tester.tap(inSheet(find.widgetWithText(OutlinedButton, 'Delete')));
      await tester.pumpAndSettle();
      expect(inDialog(find.text('Delete this expense?')), findsOneWidget);

      await tester.runAsync(() => db.replaceServerExpenses('g1', [])); // a refresh
      await tester.pumpAndSettle();
      // Still confirming: the dialog is untouched.
      expect(inDialog(find.text('Delete this expense?')), findsOneWidget);
      return (pops, db, deletes);
    }

    testWidgets('the expense going away during confirmation, then Cancel: the sheet closes',
        (tester) async {
      final (pops, db, deletes) = await confirmWhileItGoes(tester);
      addTearDown(db.close);

      await tester.tap(inDialog(find.text('Cancel')));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('open'), findsOneWidget); // the caller is still there
      expect(pops.count, 2); // the dialog, then the sheet
      expect(deletes, isEmpty);
      await closeTree(tester);
    });

    testWidgets('the expense going away during confirmation, then Delete: nothing is sent, '
        'the sheet closes', (tester) async {
      final (pops, db, deletes) = await confirmWhileItGoes(tester);
      addTearDown(db.close);

      await tester.tap(inDialog(find.text('Delete')));
      await tester.pumpAndSettle();

      expect(deletes, isEmpty);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(pops.count, 2);
      await closeTree(tester);
    });

    testWidgets('the expense coming back before Cancel keeps the sheet open', (tester) async {
      final (pops, db, deletes) = await confirmWhileItGoes(tester);
      addTearDown(db.close);

      await tester.runAsync(() => db.replaceServerExpenses('g1', [dinner()]));
      await tester.pumpAndSettle();
      await tester.tap(inDialog(find.text('Cancel')));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(inSheet(find.text('Dinner')), findsOneWidget);
      expect(pops.count, 1); // just the dialog
      expect(deletes, isEmpty);
      await closeTree(tester);
    });

    testWidgets('the expense disappearing mid-dismissal pops nothing more', (tester) async {
      final (pops, db) = await openFromCaller(tester, offlineClient);
      addTearDown(db.close);

      await tester.tapAt(const Offset(20, 20));
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(() => db.replaceServerExpenses('g1', []));
      await tester.pumpAndSettle();

      expect(pops.count, 1);
      expect(find.text('open'), findsOneWidget);
      await closeTree(tester);
    });
  });
}

class _PopCounter extends NavigatorObserver {
  int count = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => count++;
}
