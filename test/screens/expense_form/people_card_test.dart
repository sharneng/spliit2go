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
import 'package:spliit2go/screens/expense_form/split_card.dart';
import 'package:spliit2go/screens/expense_screen.dart';
import 'package:spliit2go/sync/outbox.dart';
import 'package:spliit2go/widgets/grouped_section.dart';

// #260: who paid, and who it was for.
void main() {
  const banff = Group(
    id: 'g1',
    name: 'Banff Trip',
    currency: '\$',
    participants: [
      Participant(id: 'alex', name: 'Alex'),
      Participant(id: 'bea', name: 'Bea'),
      Participant(id: 'cid', name: 'Cid'),
    ],
  );

  Future<AppDatabase> open(WidgetTester tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(banff);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw http.ClientException('offline')),
    );
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ExpenseScreen(
        client: client,
        db: db,
        outbox: Outbox(db, client, groupId: 'g1'),
        group: banff,
        activeUserId: 'bea',
      ),
    ));
    await tester.pumpAndSettle();
    return db;
  }

  Finder paidByRow() => find.widgetWithText(GroupedRow, 'Paid by');
  Finder person(String name) =>
      find.descendant(of: find.byType(SplitCard), matching: find.widgetWithText(InkWell, name));
  Finder splitField(String name) => find.descendant(of: person(name), matching: find.byType(TextFormField));

  Future<void> mode(WidgetTester tester, String label) async {
    final segment = find.descendant(of: find.byType(SegmentedButton<SplitMode>), matching: find.text(label));
    await tester.ensureVisible(segment);
    await tester.tap(segment);
    await tester.pumpAndSettle();
  }

  testWidgets('Paid by names the active user "(you)" and picks from a sheet', (tester) async {
    final db = await open(tester);
    expect(find.descendant(of: paidByRow(), matching: find.text('Bea (you)')), findsOneWidget);

    await tester.tap(paidByRow());
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    // The current payer is checked, for a screen reader too.
    expect(
        tester.getSemantics(find.descendant(of: sheet, matching: find.text('Bea (you)'))),
        isSemantics(isChecked: true, hasCheckedState: true, isInMutuallyExclusiveGroup: true));
    await tester.tap(find.descendant(of: sheet, matching: find.text('Cid')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.descendant(of: paidByRow(), matching: find.text('Cid')), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Lunch');
    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '30');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(db.rowToExpense((await db.pendingExpenses()).single).paidBy, 'cid');
  });

  testWidgets('in Evenly a tap on a person leaves them out, dimmed; only Evenly has Select all / none',
      (tester) async {
    final db = await open(tester);
    expect(find.descendant(of: find.byType(SplitCard), matching: find.byType(Checkbox)), findsNothing);
    expect(find.text('Select none'), findsOneWidget);
    Color? nameColor() => tester.widget<Text>(find.descendant(of: person('Cid'), matching: find.text('Cid'))).style?.color;
    final color = nameColor();
    expect(tester.getSemantics(person('Cid')), isSemantics(hasCheckedState: true, isChecked: true));

    await tester.ensureVisible(person('Cid'));
    await tester.tap(find.text('Cid'));
    await tester.pumpAndSettle();
    expect(nameColor(), isNot(color));
    expect(tester.getSemantics(person('Cid')), isSemantics(hasCheckedState: true, isChecked: false));
    expect(find.text('Select all'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Lunch');
    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '30');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(db.rowToExpense((await db.pendingExpenses()).single).paidFor.map((s) => s.participantId), ['alex', 'bea']);
  });

  testWidgets('the amount goes under the value, and in large text the value under the name', (tester) async {
    await open(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '30');
    await mode(tester, 'Shares');
    final amount = find.descendant(of: person('Alex'), matching: find.text('\$10.00'));
    expect(tester.getTopLeft(amount).dy, greaterThan(tester.getBottomLeft(splitField('Alex')).dy - 1));
    expect(tester.getTopLeft(splitField('Alex')).dy, lessThan(tester.getBottomLeft(find.text('Alex')).dy));

    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(splitField('Alex')).dy, greaterThan(tester.getBottomLeft(find.text('Alex')).dy));
  });

  testWidgets('Shares has no Select all / none', (tester) async {
    await open(tester);
    await mode(tester, 'Shares');
    expect(find.text('Select none'), findsNothing);
    expect(find.text('Select all'), findsNothing);
  });

  testWidgets('an empty or 0 value isn\'t included, its name dimmed, and saves without them', (tester) async {
    final db = await open(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Lunch');
    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '30');
    // Unchecked in Evenly: no share when switching.
    await tester.ensureVisible(person('Cid'));
    await tester.tap(person('Cid'));
    await tester.pumpAndSettle();
    await mode(tester, 'Shares');
    expect(tester.widget<TextFormField>(splitField('Cid')).controller!.text, '');

    Color? nameColor(String name) =>
        tester.widget<Text>(find.descendant(of: person(name), matching: find.text(name))).style?.color;
    final dimmed = nameColor('Cid');
    expect(nameColor('Alex'), isNot(dimmed));

    await tester.enterText(splitField('Alex'), '0');
    await tester.enterText(splitField('Cid'), '2');
    await tester.pumpAndSettle();
    expect(nameColor('Alex'), dimmed);
    expect(nameColor('Cid'), isNot(dimmed));

    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    final saved = db.rowToExpense((await db.pendingExpenses()).single);
    expect(saved.splitMode, SplitMode.byShares);
    expect({for (final s in saved.paidFor) s.participantId: s.shares}, {'bea': 100, 'cid': 200});
  });

  testWidgets('a split that doesn\'t add up says so in red under the card', (tester) async {
    await open(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Lunch');
    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '30');
    await mode(tester, 'Amount');
    await tester.enterText(splitField('Alex'), '20');
    await tester.pumpAndSettle();
    // 20 + 10 + 10: the others kept what switching gave them.
    expect(find.text('\$10.00 over the total.'), findsOneWidget);
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    final error = tester.widget<Text>(find.textContaining('off by \$10.00'));
    expect(error.style?.color, Theme.of(tester.element(find.byType(SplitCard))).colorScheme.error);
  });
}
