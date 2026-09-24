import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/expense_search_screen.dart';
import 'package:spliit2go/sync/outbox.dart';
import 'package:spliit2go/widgets/section_heading.dart';

// Issue #39: search filters the group's cached expenses by title as you
// type, offline too.
void main() {
  // Not named `group`: that would hide flutter_test's group().
  const banff = Group(
    id: 'g1',
    name: 'Banff Trip',
    currency: '\$',
    participants: [Participant(id: 'p1', name: 'Ken')],
  );

  Expense expense(String id, String title,
          {DateTime? date, bool pending = false, String notes = ''}) =>
      Expense(
        id: id,
        groupId: 'g1',
        title: title,
        amountCents: 500,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        notes: notes,
        date: date ?? DateTime(2026, 9, 16),
        pending: pending,
      );

  Future<AppDatabase> seededDb() async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.cacheGroup(banff);
    await db.replaceServerExpenses('g1', [
      expense('e1', 'Dinner at Lupo'),
      expense('e2', 'Groceries', notes: 'dinner supplies'),
      expense('e3', 'Late dinner', date: DateTime(2025, 3, 2)),
    ]);
    await db.insertPending(expense('local-1', 'Pending DINNER', pending: true));
    return db;
  }

  Future<void> pumpSearch(WidgetTester tester, AppDatabase db,
      {VoidCallback? onExpensesChanged}) async {
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw Exception('offline')),
    );
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ExpenseSearchScreen(
        group: banff,
        db: db,
        client: client,
        outbox: Outbox(db, client, groupId: 'g1'),
        onExpensesChanged: onExpensesChanged,
      ),
    ));
    await tester.pumpAndSettle();
  }

  // Drift's watch() leaves a timer behind on cancel (issue #47).
  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('opens with the field focused and a prompt, not the whole list',
      (tester) async {
    final db = await seededDb();
    addTearDown(db.close);
    await pumpSearch(tester, db);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);
    expect(find.text('Search expenses'), findsOneWidget); // hint
    expect(find.text('Search this group'), findsOneWidget);
    expect(find.text('Dinner at Lupo'), findsNothing);
    expect(find.byTooltip('Clear search'), findsNothing);
    await teardown(tester);
  });

  testWidgets('typing filters titles live, ignoring case, pending ones included, under date sections',
      (tester) async {
    final db = await seededDb();
    addTearDown(db.close);
    await pumpSearch(tester, db);

    await tester.enterText(find.byType(TextField), 'dinner');
    await tester.pump();

    expect(find.widgetWithText(ListTile, 'Dinner at Lupo'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Late dinner'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Pending DINNER'), findsOneWidget);
    // A match in the notes only doesn't count, as in Spliit.
    expect(find.widgetWithText(ListTile, 'Groceries'), findsNothing);
    expect(find.byType(SectionHeading), findsWidgets);

    await tester.enterText(find.byType(TextField), 'dinner at');
    await tester.pump();

    expect(find.widgetWithText(ListTile, 'Dinner at Lupo'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Late dinner'), findsNothing);
    await teardown(tester);
  });

  testWidgets('no match says so, quoting the query', (tester) async {
    final db = await seededDb();
    addTearDown(db.close);
    await pumpSearch(tester, db);

    await tester.enterText(find.byType(TextField), ' taxi ');
    await tester.pump();

    expect(find.text('No matching expenses'), findsOneWidget);
    expect(find.text('No expense here has “taxi” in its title.'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    await teardown(tester);
  });

  testWidgets('Clear empties the field, keeps it focused and brings the prompt back',
      (tester) async {
    final db = await seededDb();
    addTearDown(db.close);
    await pumpSearch(tester, db);

    await tester.enterText(find.byType(TextField), 'groc');
    await tester.pump();
    expect(find.widgetWithText(ListTile, 'Groceries'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
    expect(field.focusNode!.hasFocus, isTrue);
    expect(find.text('Search this group'), findsOneWidget);
    expect(find.byTooltip('Clear search'), findsNothing);
    await teardown(tester);
  });

  testWidgets('results follow the local db: a deleted expense drops out', (tester) async {
    final db = await seededDb();
    addTearDown(db.close);
    await pumpSearch(tester, db);

    await tester.enterText(find.byType(TextField), 'dinner');
    await tester.pump();
    expect(find.widgetWithText(ListTile, 'Late dinner'), findsOneWidget);

    await tester.runAsync(() => db.removeDeletedExpense('g1', 'e3'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ListTile, 'Late dinner'), findsNothing);
    expect(find.widgetWithText(ListTile, 'Dinner at Lupo'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('tapping a result opens its details sheet and drops the keyboard',
      (tester) async {
    final db = await seededDb();
    addTearDown(db.close);
    await pumpSearch(tester, db);

    await tester.enterText(find.byType(TextField), 'lupo');
    await tester.pump();
    await tester.tap(find.widgetWithText(ListTile, 'Dinner at Lupo'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(
        find.descendant(of: find.byType(BottomSheet), matching: find.text('Dinner at Lupo')),
        findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isFalse);
    await teardown(tester);
  });
}
