import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/expense_screen.dart';
import 'package:spliit2go/sync/outbox.dart';
import 'package:spliit2go/widgets/grouped_section.dart';

import '../../support/haptics.dart';

// #259: the form's frame: ✕ and ✓, the Expense/Settlement title, and
// where a refused save takes you.
void main() {
  const banff = Group(
    id: 'g1',
    name: 'Banff Trip',
    currency: '\$',
    participants: [
      Participant(id: 'alex', name: 'Alex'),
      Participant(id: 'bea', name: 'Bea'),
    ],
  );

  /// Opens the form over a page, as the group screen does; returns what
  /// it was closed with.
  Future<(AppDatabase, List<bool?>)> open(WidgetTester tester, {Expense? editing}) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(banff);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw http.ClientException('offline')),
    );
    final popped = <bool?>[];
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => popped.add(await Navigator.of(context).push<bool>(MaterialPageRoute(
              builder: (_) => ExpenseScreen(
                client: client,
                db: db,
                outbox: Outbox(db, client, groupId: 'g1'),
                group: banff,
                existingExpense: editing,
              ),
            ))),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return (db, popped);
  }

  Finder title() => find.widgetWithText(TextFormField, 'Title');

  Future<void> close(WidgetTester tester) async {
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
  }

  Future<void> pickKind(WidgetTester tester, String kind) async {
    await tester.tap(find.byTooltip('Switch to ${kind.toLowerCase()}'));
    await tester.pumpAndSettle();
  }

  group('✕', () {
    testWidgets('closes an untouched form without asking', (tester) async {
      final (_, popped) = await open(tester);
      await close(tester);
      expect(find.byType(ExpenseScreen), findsNothing);
      expect(popped, [null]);
    });

    testWidgets('asks before discarding a change; Cancel stays, Discard leaves', (tester) async {
      final (_, popped) = await open(tester);
      await tester.enterText(title(), 'Lunch');
      await close(tester);
      expect(find.text('Discard changes?'), findsOneWidget);
      // Nothing about receipts: none were added.
      expect(find.textContaining('receipts'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(ExpenseScreen), findsOneWidget);

      await close(tester);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(ExpenseScreen), findsNothing);
      expect(popped, [null]);
    });

    testWidgets('a change undone is no change', (tester) async {
      await open(tester);
      await tester.enterText(title(), 'Lunch');
      await tester.enterText(title(), '');
      await pickKind(tester, 'Settlement');
      await pickKind(tester, 'Expense');
      await close(tester);
      expect(find.byType(ExpenseScreen), findsNothing);
    });
  });

  group('one tap switches between an expense and a settlement', () {
    testWidgets('a new settlement hides the category and saves as a Payment', (tester) async {
      final (db, popped) = await open(tester);
      expect(find.text('New expense'), findsOneWidget);
      expect(find.widgetWithText(GroupedRow, 'Category'), findsOneWidget);

      // The button shows the kind it switches to.
      expect(find.widgetWithIcon(IconButton, Icons.payments_outlined), findsOneWidget);
      await pickKind(tester, 'Settlement');

      expect(find.text('New settlement'), findsOneWidget);
      expect(find.byTooltip('Switch to expense'), findsOneWidget);
      expect(find.widgetWithIcon(IconButton, Icons.receipt_long_outlined), findsOneWidget);
      expect(find.widgetWithText(GroupedRow, 'Category'), findsNothing);
      await tester.enterText(title(), 'Bea paid Alex');
      await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '30');
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      final saved = db.rowToExpense((await db.pendingExpenses()).single);
      expect((saved.isSettlement, saved.category), (true, 1));
      expect(popped, [true]);
    });

    testWidgets('an edited settlement is titled so, and keeps its category hidden', (tester) async {
      await open(tester,
          editing: Expense(
            id: 'e1',
            groupId: 'g1',
            title: 'Paid back',
            amountCents: 3000,
            paidBy: 'bea',
            paidFor: const [ExpenseShare(participantId: 'alex', shares: 100)],
            splitMode: SplitMode.evenly,
            category: 8,
            date: DateTime.utc(2026, 10, 1),
            isSettlement: true,
          ));
      expect(find.text('Edit settlement'), findsOneWidget);
      expect(find.widgetWithText(GroupedRow, 'Category'), findsNothing);
      await pickKind(tester, 'Expense');
      expect(find.text('Edit expense'), findsOneWidget);
      // The category it had all along: see the model's categoryToSave.
      expect(find.widgetWithText(GroupedRow, 'Category'), findsOneWidget);
    });
  });

  testWidgets('a refused save scrolls up to the first field that needs fixing', (tester) async {
    final haptics = recordHaptics(tester);
    await open(tester);
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(title().hitTestable(), findsNothing);

    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(title().hitTestable(), findsOneWidget);
    expect(find.text('Required'), findsOneWidget);
    expect(haptics, isNotEmpty);
  });
}
