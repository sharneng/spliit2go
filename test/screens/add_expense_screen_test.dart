import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  Future<void> pumpScreen(WidgetTester tester, AppDatabase db) async {
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw Exception('offline')),
    );
    final outbox = Outbox(db, client);
    await tester.pumpWidget(MaterialApp(
      home: AddExpenseScreen(client: client, db: db, outbox: outbox, group: group),
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
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Cid'));
    await tester.pumpAndSettle();
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
    await tester.tap(find.widgetWithText(DropdownButtonFormField<SplitMode>, 'Evenly'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unevenly – By amount').last);
    await tester.pumpAndSettle();

    final amountFields = find.byType(TextFormField);
    // Title, Amount, then one per participant (alex, bea, cid) in order.
    await tester.enterText(amountFields.at(2), '30');
    await tester.enterText(amountFields.at(3), '30');
    await tester.enterText(amountFields.at(4), '20'); // 30+30+20 = 80, not 90

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
    await tester.tap(find.widgetWithText(DropdownButtonFormField<SplitMode>, 'Evenly'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unevenly – By amount').last);
    await tester.pumpAndSettle();

    final amountFields = find.byType(TextFormField);
    await tester.enterText(amountFields.at(2), '50');
    await tester.enterText(amountFields.at(3), '30');
    await tester.enterText(amountFields.at(4), '10');

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
    await tester.tap(find.widgetWithText(DropdownButtonFormField<SplitMode>, 'Evenly'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unevenly – By percentage').last);
    await tester.pumpAndSettle();

    final amountFields = find.byType(TextFormField);
    await tester.enterText(amountFields.at(2), '50');
    await tester.enterText(amountFields.at(3), '30');
    await tester.enterText(amountFields.at(4), '10'); // sums to 90, not 100

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(await db.pendingExpenses(), isEmpty);
    expect(find.textContaining('must add up to 100'), findsOneWidget);
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

}
