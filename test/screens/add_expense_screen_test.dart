import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/add_expense_screen.dart';
import 'package:spliit2go/sync/outbox.dart';

void main() {
  const group = Group(
    id: 'g1',
    name: 'Banff Trip',
    currency: '\$',
    participants: [
      Participant(id: 'alex', name: 'Alex'),
      Participant(id: 'bea', name: 'Bea'),
      Participant(id: 'cid', name: 'Cid'),
    ],
  );

  Future<void> pumpScreen(WidgetTester tester, AppDatabase db, {String? initialPaidBy}) async {
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw Exception('offline')),
    );
    final outbox = Outbox(db, client);
    await tester.pumpWidget(MaterialApp(
      home: AddExpenseScreen(
        client: client,
        db: db,
        outbox: outbox,
        group: group,
        initialPaidBy: initialPaidBy,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> fillCommonFields(WidgetTester tester, {required String amount}) async {
    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Groceries');
    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), amount);
  }

  testWidgets('evenly split (default): every participant included, no per-person input',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpScreen(tester, db);

    await fillCommonFields(tester, amount: '90');
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final pending = await db.pendingExpenses();
    expect(pending, hasLength(1));
    final expense = db.rowToExpense(pending.single);
    expect(expense.splitMode, SplitMode.evenly);
    expect(expense.paidFor.map((s) => s.participantId).toSet(), {'alex', 'bea', 'cid'});
    expect(expense.paidFor.every((s) => s.shares == 1), isTrue);
  });

  testWidgets('excluding a participant leaves them out of paidFor', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpScreen(tester, db);

    await fillCommonFields(tester, amount: '90');
    await tester.ensureVisible(find.widgetWithText(CheckboxListTile, 'Cid'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Cid'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final pending = await db.pendingExpenses();
    final expense = db.rowToExpense(pending.single);
    expect(expense.paidFor.map((s) => s.participantId).toSet(), {'alex', 'bea'});
  });

  testWidgets('by-amount split rejects amounts that don\'t add up to the total',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpScreen(tester, db);

    await fillCommonFields(tester, amount: '90');
    await tester.ensureVisible(find.widgetWithText(DropdownButtonFormField<SplitMode>, 'Evenly'));
    await tester.tap(find.widgetWithText(DropdownButtonFormField<SplitMode>, 'Evenly'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Unevenly – By amount').last);
    await tester.tap(find.text('Unevenly – By amount').last);
    await tester.pumpAndSettle();

    final amountFields = find.byType(TextFormField);
    // Title, Amount, then one per participant (alex, bea, cid) in order.
    await tester.enterText(amountFields.at(2), '30');
    await tester.enterText(amountFields.at(3), '30');
    await tester.enterText(amountFields.at(4), '20'); // 30+30+20 = 80, not 90

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(await db.pendingExpenses(), isEmpty);
    expect(find.textContaining('must add up to the total'), findsOneWidget);
  });

  testWidgets('by-amount split with matching amounts saves with exact per-person shares',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpScreen(tester, db);

    await fillCommonFields(tester, amount: '90');
    await tester.ensureVisible(find.widgetWithText(DropdownButtonFormField<SplitMode>, 'Evenly'));
    await tester.tap(find.widgetWithText(DropdownButtonFormField<SplitMode>, 'Evenly'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Unevenly – By amount').last);
    await tester.tap(find.text('Unevenly – By amount').last);
    await tester.pumpAndSettle();

    final amountFields = find.byType(TextFormField);
    await tester.enterText(amountFields.at(2), '50');
    await tester.enterText(amountFields.at(3), '30');
    await tester.enterText(amountFields.at(4), '10');

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final pending = await db.pendingExpenses();
    final expense = db.rowToExpense(pending.single);
    expect(expense.splitMode, SplitMode.byAmount);
    final byId = {for (final s in expense.paidFor) s.participantId: s.shares};
    expect(byId, {'alex': 5000, 'bea': 3000, 'cid': 1000});
  });

  testWidgets('by-percentage split rejects percentages that don\'t sum to 100',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpScreen(tester, db);

    await fillCommonFields(tester, amount: '90');
    await tester.ensureVisible(find.widgetWithText(DropdownButtonFormField<SplitMode>, 'Evenly'));
    await tester.tap(find.widgetWithText(DropdownButtonFormField<SplitMode>, 'Evenly'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Unevenly – By percentage').last);
    await tester.tap(find.text('Unevenly – By percentage').last);
    await tester.pumpAndSettle();

    final amountFields = find.byType(TextFormField);
    await tester.enterText(amountFields.at(2), '50');
    await tester.enterText(amountFields.at(3), '30');
    await tester.enterText(amountFields.at(4), '10'); // sums to 90, not 100

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(await db.pendingExpenses(), isEmpty);
    expect(find.textContaining('must add up to 100'), findsOneWidget);
  });

  // Regression test for issue #18: the server expects shares to sum to
  // 10000 (basis points), not the 100 the UI takes from the user.
  testWidgets('by-percentage split sends shares as basis points (issue #18)',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpScreen(tester, db);

    await fillCommonFields(tester, amount: '90');
    await tester.ensureVisible(find.widgetWithText(DropdownButtonFormField<SplitMode>, 'Evenly'));
    await tester.tap(find.widgetWithText(DropdownButtonFormField<SplitMode>, 'Evenly'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Unevenly – By percentage').last);
    await tester.tap(find.text('Unevenly – By percentage').last);
    await tester.pumpAndSettle();

    final amountFields = find.byType(TextFormField);
    await tester.enterText(amountFields.at(2), '50');
    await tester.enterText(amountFields.at(3), '30');
    await tester.enterText(amountFields.at(4), '20'); // sums to 100

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final pending = await db.pendingExpenses();
    final expense = db.rowToExpense(pending.single);
    expect(expense.splitMode, SplitMode.byPercentage);
    final byId = {for (final s in expense.paidFor) s.participantId: s.shares};
    expect(byId, {'alex': 5000, 'bea': 3000, 'cid': 2000});
  });

  testWidgets('defaults "Paid by" to the saved active user, when they\'re in this group',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpScreen(tester, db, initialPaidBy: 'bea');

    final dropdown =
        tester.widget<DropdownButtonFormField<String>>(find.byType(DropdownButtonFormField<String>));
    expect(dropdown.initialValue, 'bea');
  });

  testWidgets('falls back to the first participant when there\'s no saved active user',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpScreen(tester, db);

    final dropdown =
        tester.widget<DropdownButtonFormField<String>>(find.byType(DropdownButtonFormField<String>));
    expect(dropdown.initialValue, 'alex');
  });

  testWidgets('loads categories from the server and selecting one updates the field',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        expect(req.url.toString(), contains('categories.list'));
        return http.Response(
          '[{"result":{"data":{"json":{"categories":'
          '[{"id":0,"name":"General"},{"id":16,"name":"Groceries"}]}}}}]',
          200,
        );
      }),
    );
    final outbox = Outbox(db, client);

    await tester.pumpWidget(MaterialApp(
      home: AddExpenseScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    // Categories loaded successfully (would still show just 'General' if
    // the fetch had failed) -- open the picker, confirm it's there, and
    // pick it. Checking the field's value directly (rather than saving
    // and reading the persisted expense back) sidesteps needing a full
    // save-flow round trip through a form this test isn't otherwise
    // exercising.
    await tester.ensureVisible(find.widgetWithText(DropdownButtonFormField<int>, 'General'));
    await tester.tap(find.widgetWithText(DropdownButtonFormField<int>, 'General'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Groceries').last);
    await tester.tap(find.text('Groceries').last);
    await tester.pumpAndSettle();

    final dropdown = tester
        .widget<DropdownButtonFormField<int>>(find.byType(DropdownButtonFormField<int>));
    expect(dropdown.initialValue, 16);
  });

  testWidgets('falls back to General only when categories.list is unreachable',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpScreen(tester, db); // pumpScreen's client always throws (offline)

    expect(find.widgetWithText(DropdownButtonFormField<int>, 'General'), findsOneWidget);
  });

  final existingExpenseForEdit = Expense(
      id: 'e1',
      groupId: 'g1',
      title: 'Groceries',
      amountCents: 9000,
      paidBy: 'bea',
      paidFor: const [
        ExpenseShare(participantId: 'alex', shares: 1),
        ExpenseShare(participantId: 'bea', shares: 1),
      ],
      splitMode: SplitMode.evenly,
      category: 0,
      notes: 'weekly shop',
      date: DateTime.utc(2026, 9, 10),
      recurrenceRule: RecurrenceRule.weekly,
    );

    testWidgets('shows "Edit expense" and prefills fields from the existing expense',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw Exception('offline')),
      );
      final outbox = Outbox(db, client);

      await tester.pumpWidget(MaterialApp(
        home: AddExpenseScreen(
          client: client,
          db: db,
          outbox: outbox,
          group: group,
          existingExpense: existingExpenseForEdit,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Edit expense'), findsOneWidget);
      expect(find.text('Groceries'), findsOneWidget);
      expect(find.text('90.00'), findsOneWidget);
      expect(find.text('weekly shop'), findsOneWidget);
      final paidByDropdown = tester
          .widget<DropdownButtonFormField<String>>(find.byType(DropdownButtonFormField<String>));
      expect(paidByDropdown.initialValue, 'bea');
      // 'cid' wasn't in the existing expense's paidFor -- should come up
      // unchecked, not defaulted to included the way a brand-new add does.
      final cidTile =
          tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Cid'));
      expect(cidTile.value, isFalse);
    });

    // Regression test for issue #18's edit-mode side: a byPercentage
    // expense's shares are basis points on the wire (5000 = 50%) --
    // prefilling the per-participant text field with the raw wire value
    // would show "5000" instead of "50".
    testWidgets("prefills a byPercentage expense's shares as whole percent, not basis points",
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw Exception('offline')),
      );
      final outbox = Outbox(db, client);
      final percentageExpense = Expense(
        id: 'e2',
        groupId: 'g1',
        title: 'Rent',
        amountCents: 100000,
        paidBy: 'bea',
        paidFor: const [
          ExpenseShare(participantId: 'alex', shares: 5000),
          ExpenseShare(participantId: 'bea', shares: 3000),
          ExpenseShare(participantId: 'cid', shares: 2000),
        ],
        splitMode: SplitMode.byPercentage,
        date: DateTime.utc(2026, 9, 10),
      );

      await tester.pumpWidget(MaterialApp(
        home: AddExpenseScreen(
          client: client,
          db: db,
          outbox: outbox,
          group: group,
          existingExpense: percentageExpense,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('50'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
      expect(find.text('20'), findsOneWidget);
      expect(find.text('5000'), findsNothing);
    });

    testWidgets('saving calls SpliitClient.updateExpense, not createExpense/insertPending',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      http.Request? captured;
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('[{"result":{"data":{"json":{"expenseId":"e1"}}}}]', 200);
        }),
      );
      final outbox = Outbox(db, client);

      await tester.pumpWidget(MaterialApp(
        home: AddExpenseScreen(
          client: client,
          db: db,
          outbox: outbox,
          group: group,
          existingExpense: existingExpenseForEdit,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextFormField, 'Groceries'), 'Groceries (updated)');
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.url.toString(), contains('groups.expenses.update'));
      // Edit mode never writes a local pending row -- there's no offline
      // queueing path for edits (see the screen's class doc comment).
      expect(await db.pendingExpenses(), isEmpty);
    });

    testWidgets('save failure (e.g. offline) shows an error and stays on the form',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw Exception('offline')),
      );
      final outbox = Outbox(db, client);

      await tester.pumpWidget(MaterialApp(
        home: AddExpenseScreen(
          client: client,
          db: db,
          outbox: outbox,
          group: group,
          existingExpense: existingExpenseForEdit,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't save"), findsOneWidget);
      // Still on the edit screen (didn't pop), and nothing was queued.
      expect(find.text('Edit expense'), findsOneWidget);
      expect(await db.pendingExpenses(), isEmpty);
    });
}
