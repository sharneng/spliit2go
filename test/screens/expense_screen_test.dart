import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/expense_screen.dart';
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
    // Mirrors real usage: this screen is only ever reached from
    // GroupScreen, which has already cached the group by the time it's
    // opened -- needed here so the remembered-default-split feature
    // (issue #29) has a Groups row to write to/read from.
    await db.cacheGroup(group);
    await tester.pumpWidget(MaterialApp(
      home: ExpenseScreen(
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

  // Taps the named segment of the "Paid for" section's SegmentedButton
  // (issue #29's replacement for the old split-mode dropdown). Scoped to
  // that widget specifically, since e.g. 'Amount' is ambiguous with the
  // main Amount field's own label text.
  Future<void> selectSplitMode(WidgetTester tester, String label) async {
    final finder = find.descendant(
      of: find.byType(SegmentedButton<SplitMode>),
      matching: find.text(label),
    );
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
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
    await selectSplitMode(tester, 'Amount');

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
    await selectSplitMode(tester, 'Amount');

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
    await selectSplitMode(tester, 'Percent');

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
    await selectSplitMode(tester, 'Percent');

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

  // The mock server's category list used by the picker tests below --
  // two groupings, matching Spliit's real shape (categories.list returns
  // {id, name, grouping}), so grouping and cross-group search can both be
  // exercised.
  String categoriesResponseBody() => '[{"result":{"data":{"json":{"categories":'
      '[{"id":0,"name":"General","grouping":"Uncategorized"},'
      '{"id":9,"name":"Groceries","grouping":"Food and Drink"},'
      '{"id":8,"name":"Dining Out","grouping":"Food and Drink"},'
      '{"id":20,"name":"Gas/Fuel","grouping":"Transportation"}]}}}}]';

  testWidgets('loads categories from the server and selecting one updates the field',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        expect(req.url.toString(), contains('categories.list'));
        return http.Response(categoriesResponseBody(), 200);
      }),
    );
    final outbox = Outbox(db, client);

    await tester.pumpWidget(MaterialApp(
      home: ExpenseScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    // Categories loaded successfully (would still show just 'General' if
    // the fetch had failed) -- open the picker, confirm it's there, and
    // pick a category. Checking the field's displayed value directly
    // (rather than saving and reading the persisted expense back)
    // sidesteps needing a full save-flow round trip through a form this
    // test isn't otherwise exercising.
    await tester.ensureVisible(find.widgetWithText(InputDecorator, 'General'));
    await tester.tap(find.widgetWithText(InputDecorator, 'General'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Groceries'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(InputDecorator, 'Groceries'), findsOneWidget);
  });

  testWidgets('falls back to General only when categories.list is unreachable',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpScreen(tester, db); // pumpScreen's client always throws (offline)

    expect(find.widgetWithText(InputDecorator, 'General'), findsOneWidget);
  });

  testWidgets('category picker groups categories under their grouping header', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response(categoriesResponseBody(), 200)),
      );
      final outbox = Outbox(db, client);

      await tester.pumpWidget(MaterialApp(
        home: ExpenseScreen(client: client, db: db, outbox: outbox, group: group),
      ));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.widgetWithText(InputDecorator, 'General'));
      await tester.tap(find.widgetWithText(InputDecorator, 'General'));
      await tester.pumpAndSettle();

      // Grouping headers are shown, and "Groceries"/"Dining Out" both
      // appear once each under "Food and Drink" -- not flattened into
      // one long undifferentiated list.
      expect(find.text('Food and Drink'), findsOneWidget);
      expect(find.text('Transportation'), findsOneWidget);
      expect(find.text('Groceries'), findsOneWidget);
      expect(find.text('Dining Out'), findsOneWidget);
      expect(find.text('Gas/Fuel'), findsOneWidget);
    });

  testWidgets('category picker type-ahead search narrows the list to matching categories', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response(categoriesResponseBody(), 200)),
      );
      final outbox = Outbox(db, client);

      await tester.pumpWidget(MaterialApp(
        home: ExpenseScreen(client: client, db: db, outbox: outbox, group: group),
      ));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.widgetWithText(InputDecorator, 'General'));
      await tester.tap(find.widgetWithText(InputDecorator, 'General'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Search categories'), 'gas');
      await tester.pumpAndSettle();

      expect(find.text('Gas/Fuel'), findsOneWidget);
      expect(find.text('Groceries'), findsNothing);
      expect(find.text('Dining Out'), findsNothing);
      // A grouping with no matches under the current query is hidden
      // entirely, not shown as an empty section.
      expect(find.text('Food and Drink'), findsNothing);
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
        home: ExpenseScreen(
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
        home: ExpenseScreen(
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
        home: ExpenseScreen(
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
        home: ExpenseScreen(
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

  // A group with no currencyCode (the module-level `group` fixture, and
  // every group that predates issue #23) can't offer currency-picker
  // conversion -- there's no code to look up an exchange rate with.
  const groupWithCurrencyCode = Group(
    id: 'g2',
    name: 'Tokyo Trip',
    currency: '\$',
    currencyCode: 'USD',
    participants: [
      Participant(id: 'alex', name: 'Alex'),
      Participant(id: 'bea', name: 'Bea'),
    ],
  );

  testWidgets(
      "paid-in-a-different-currency shows a disabled field when the group's currency has no code",
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpScreen(tester, db); // module-level `group` has no currencyCode

    await tester.ensureVisible(find.widgetWithText(CheckboxListTile, 'Paid in a different currency'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Paid in a different currency'));
    await tester.pumpAndSettle();

    expect(find.text('Conversion unavailable'), findsOneWidget);
    // Nothing to tap -- picking a currency needs a real code to convert
    // against, which this group doesn't have.
    expect(find.widgetWithText(InputDecorator, 'Select'), findsNothing);
  });

  testWidgets('picking an original currency from the picker saves its code (issue #23)',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw Exception('offline')),
    );
    final outbox = Outbox(db, client);

    await tester.pumpWidget(MaterialApp(
      home: ExpenseScreen(client: client, db: db, outbox: outbox, group: groupWithCurrencyCode),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Dinner');
    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '50');

    await tester.ensureVisible(find.widgetWithText(CheckboxListTile, 'Paid in a different currency'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Paid in a different currency'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Original amount'), '5000');
    await tester.tap(find.widgetWithText(InputDecorator, 'Select'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Search currency...'), 'Yen');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Japanese Yen (JPY)'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(InputDecorator, 'Japanese Yen (JPY)'), findsOneWidget);

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final pending = await db.pendingExpenses();
    expect(pending, hasLength(1));
    expect(pending.single.originalCurrency, 'JPY');
  });

  // issue #29: "Paid for" UX rework (segmented control, select all/none,
  // live preview, footer hint, remembered default split). Not wrapped in
  // its own group() -- this file's module-level `group` fixture (a
  // Group instance) shadows the flutter_test group() function for the
  // rest of main()'s body once declared, same as everywhere else here.
  testWidgets('"Select all"/"Select none" toggles every participant and flips its own label',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpScreen(tester, db);

      // Everyone starts included -> the link offers the opposite.
      expect(find.widgetWithText(TextButton, 'Select none'), findsOneWidget);

      await tester.ensureVisible(find.widgetWithText(TextButton, 'Select none'));
      await tester.tap(find.widgetWithText(TextButton, 'Select none'));
      await tester.pumpAndSettle();

      expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Alex')).value,
          isFalse);
      expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Cid')).value,
          isFalse);
      expect(find.widgetWithText(TextButton, 'Select all'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Select all'));
      await tester.pumpAndSettle();

      expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Alex')).value,
          isTrue);
      expect(find.widgetWithText(TextButton, 'Select none'), findsOneWidget);
    });

    testWidgets('evenly split shows a live per-participant \$ preview once the amount is entered',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpScreen(tester, db);

      await fillCommonFields(tester, amount: '90');
      await tester.pumpAndSettle();

      // \$90 evenly among 3 participants -> \$30.00 each.
      expect(find.text('\$30.00'), findsNWidgets(3));
    });

    testWidgets('percent mode footer shows "still to allocate" before percentages sum to 100',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpScreen(tester, db);

      await fillCommonFields(tester, amount: '90');
      await selectSplitMode(tester, 'Percent');

      final splitFields = find.byType(TextFormField);
      await tester.enterText(splitFields.at(2), '50');
      await tester.pumpAndSettle();

      expect(find.textContaining('still to allocate'), findsOneWidget);
      // Nothing was submitted yet -- this is the live hint, not the
      // Save-attempt blocking error.
      expect(find.textContaining('currently'), findsNothing);
    });

    testWidgets('a successful save with "Save as default split" checked is applied to the next '
        'new expense in the same group', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpScreen(tester, db);

      await fillCommonFields(tester, amount: '90');
      await selectSplitMode(tester, 'Shares');

      final splitFields = find.byType(TextFormField);
      await tester.enterText(splitFields.at(2), '2'); // alex
      await tester.enterText(splitFields.at(3), '1'); // bea
      await tester.enterText(splitFields.at(4), '1'); // cid

      await tester.ensureVisible(find.widgetWithText(CheckboxListTile, 'Save as default split'));
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Save as default split'));
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(await db.defaultSplitFor('g1'), isNotNull);

      // Fully tear down the first screen's widget tree (and its
      // now-history-less Navigator) before pumping a second MaterialApp
      // -- otherwise Flutter's element reconciliation reuses the
      // existing Navigator element instead of creating a fresh one, and
      // rebuilding it after its only route was just popped crashes.
      await tester.pumpWidget(const SizedBox());

      // Re-open the screen for a brand-new expense in the same group.
      await pumpScreen(tester, db);

      final segmented =
          tester.widget<SegmentedButton<SplitMode>>(find.byType(SegmentedButton<SplitMode>));
      expect(segmented.selected, {SplitMode.byShares});
      final reopenedFields = find.byType(TextFormField);
      expect(tester.widget<TextFormField>(reopenedFields.at(2)).controller!.text, '2');
      expect(tester.widget<TextFormField>(reopenedFields.at(3)).controller!.text, '1');
      expect(tester.widget<TextFormField>(reopenedFields.at(4)).controller!.text, '1');
    });

  // issue #33: the per-participant split value field should be
  // right-aligned in every non-evenly mode.
  testWidgets('the per-participant split value field is right-aligned', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpScreen(tester, db);

    await fillCommonFields(tester, amount: '90');
    await selectSplitMode(tester, 'Shares');

    // TextFormField doesn't expose textAlign as a public field itself --
    // it's forwarded into the TextField it builds internally, so check
    // that descendant instead.
    final textField = tester.widget<TextField>(find.descendant(
      of: find.byType(TextFormField).at(2),
      matching: find.byType(TextField),
    ));
    expect(textField.textAlign, TextAlign.right);
  });

  // issue #34: Shares and Percentage should both accept a decimal point,
  // not just whole numbers -- and (see _buildPaidFor's doc comment) the
  // wire value is the typed decimal x100, the same transform
  // spliit-web's own form applies, so decimal precision survives the trip.
  testWidgets('by-shares split accepts a decimal number of shares', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpScreen(tester, db);

    await fillCommonFields(tester, amount: '90');
    await selectSplitMode(tester, 'Shares');

    final splitFields = find.byType(TextFormField);
    await tester.enterText(splitFields.at(2), '1.5'); // alex
    await tester.enterText(splitFields.at(3), '1'); // bea
    await tester.enterText(splitFields.at(4), '1'); // cid

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final pending = await db.pendingExpenses();
    expect(pending, hasLength(1));
    final expense = db.rowToExpense(pending.single);
    final byId = {for (final s in expense.paidFor) s.participantId: s.shares};
    // 1.5 x100 = 150 -- the same x100 scale Percentage already used, now
    // applied to Shares too so a fractional value survives on the wire.
    expect(byId, {'alex': 150, 'bea': 100, 'cid': 100});
  });

  testWidgets('by-percentage split accepts decimal percentages that sum to exactly 100',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpScreen(tester, db);

    await fillCommonFields(tester, amount: '90');
    await selectSplitMode(tester, 'Percent');

    final splitFields = find.byType(TextFormField);
    await tester.enterText(splitFields.at(2), '33.3');
    await tester.enterText(splitFields.at(3), '33.3');
    await tester.enterText(splitFields.at(4), '33.4'); // 33.3+33.3+33.4 = 100.0 exactly

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final pending = await db.pendingExpenses();
    expect(pending, hasLength(1));
    final expense = db.rowToExpense(pending.single);
    final byId = {for (final s in expense.paidFor) s.participantId: s.shares};
    // Basis points: 3330 + 3330 + 3340 = 10000 exactly.
    expect(byId, {'alex': 3330, 'bea': 3330, 'cid': 3340});
  });

  testWidgets('by-percentage footer reports a fractional "still to allocate" amount',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpScreen(tester, db);

    await fillCommonFields(tester, amount: '90');
    await selectSplitMode(tester, 'Percent');

    final splitFields = find.byType(TextFormField);
    await tester.enterText(splitFields.at(2), '33.3');
    await tester.pumpAndSettle();

    // 100 - (33.3 + 1 + 1, the other two rows' unchanged "1" default) = 64.7
    expect(find.textContaining('64.7% still to allocate'), findsOneWidget);
  });
}
