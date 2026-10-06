import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/models/category.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/theme.dart';
import 'package:spliit2go/widgets/expense_list.dart';

// #207: an expense row in two lines -- what you lent or owe, who paid,
// and marks for repeats, receipts and notes.
void main() {
  const general = Category(id: 0, name: 'General', grouping: 'Uncategorized');

  // $30.00 split evenly three ways: $10.00 each.
  Expense expense({
    String paidBy = 'me',
    bool reimbursement = false,
    RecurrenceRule recurrence = RecurrenceRule.none,
    int documents = 0,
    String notes = '',
    bool pending = false,
    bool syncFailed = false,
    List<String> paidFor = const ['me', 'jo', 'al'],
  }) =>
      Expense(
        id: 'e1',
        groupId: 'g1',
        title: 'Dinner',
        amountCents: 3000,
        paidBy: paidBy,
        paidFor: [for (final p in paidFor) ExpenseShare(participantId: p, shares: 1)],
        date: DateTime(2026, 10, 6),
        isReimbursement: reimbursement,
        recurrenceRule: recurrence,
        documentCount: documents,
        notes: notes,
        pending: pending,
        syncFailed: syncFailed,
      );

  // What a screen reader says for the row.
  String spoken(WidgetTester tester) => tester.getSemantics(find.byType(ListTile)).label;

  Future<void> pump(WidgetTester tester, Expense e,
      {String? activeUserId = 'me', String? payer = 'Jo'}) async {
    await tester.pumpWidget(MaterialApp(
      theme: spliit2goLightTheme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ExpenseTile(
          expense: e,
          category: general,
          currency: r'$',
          payer: payer,
          activeUserId: activeUserId,
          onTap: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('you paid: "You", and what the others owe you, in green', (tester) async {
    await pump(tester, expense());
    expect(find.text('You'), findsOneWidget);
    expect(spoken(tester), 'Dinner. You paid \$30.00 on Oct 6, 2026, General. You lent \$20.00.');
    expect(tester.widget<Text>(find.text('\$20.00')).style!.color,
        SpliitColors.light.moneyPositive);
  });

  testWidgets('someone else paid: their name, and your share in red', (tester) async {
    await pump(tester, expense(paidBy: 'jo'));
    expect(find.text('Jo'), findsOneWidget);
    expect(spoken(tester), 'Dinner. Jo paid \$30.00 on Oct 6, 2026, General. You owe \$10.00.');
    expect(tester.widget<Text>(find.text('\$10.00')).style!.color,
        SpliitColors.light.moneyNegative);
  });

  testWidgets('nothing lent or owed when you are not in it, or nobody is you',
      (tester) async {
    await pump(tester, expense(paidBy: 'jo', paidFor: ['jo', 'al']));
    expect(find.text('\$10.00'), findsNothing);
    expect(find.text('\$15.00'), findsNothing);

    await pump(tester, expense(), activeUserId: null, payer: 'Me');
    expect(find.text('\$20.00'), findsNothing);
    expect(find.text('Me'), findsOneWidget);
  });

  testWidgets('a reimbursement shows who paid but no lent or owed amount', (tester) async {
    await pump(tester, expense(paidBy: 'jo', reimbursement: true));
    expect(find.text('Jo'), findsOneWidget);
    expect(find.text('\$10.00'), findsNothing);
  });

  testWidgets('marks for repeats, receipts and notes, only when there are some',
      (tester) async {
    await pump(tester, expense());
    expect(spoken(tester), isNot(anyOf(contains('Repeats'), contains('receipts'), contains('notes'))));

    await pump(tester,
        expense(recurrence: RecurrenceRule.monthly, documents: 2, notes: 'Tip included'));
    expect(spoken(tester), endsWith('Repeats. Has receipts. Has notes.'));
  });

  testWidgets('a pending or failed expense shows its sync state in place of the payer',
      (tester) async {
    await pump(tester, expense(paidBy: 'jo', pending: true));
    expect(find.text('syncing…'), findsOneWidget);
    expect(find.text('Jo'), findsNothing);
    // Who paid is still read out.
    expect(spoken(tester), 'Dinner. Jo paid \$30.00 on Oct 6, 2026, General. You owe \$10.00. syncing…');

    await pump(tester, expense(paidBy: 'jo', pending: true, syncFailed: true));
    expect(find.text('sync failed'), findsOneWidget);
  });

  testWidgets('a long payer name is cut short, not wrapped', (tester) async {
    await pump(tester, expense(paidBy: 'jo'),
        payer: 'Bartholomew Montgomery-Fitzwilliam the Third');
    final name = tester.widget<Text>(find.textContaining('Bartholomew'));
    expect(name.maxLines, 1);
    expect(name.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  group('participantColors', () {
    final people = [
      for (final id in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i']) Participant(id: id, name: id),
    ];

    test('you are emerald; the others take the rest in order, then start over', () {
      final colors = participantColors(people, 'c');
      expect(colors['c'], monogramPalette[0]);
      expect([for (final id in ['a', 'b', 'd', 'e', 'f', 'g', 'h', 'i', 'j']) colors[id]], [
        ...monogramPalette.sublist(1),
        monogramPalette[1],
        null,
      ]);
    });

    test('with nobody as you, nobody is emerald', () {
      final colors = participantColors(people, null);
      expect(colors.values, isNot(contains(monogramPalette[0])));
      expect(colors['a'], monogramPalette[1]);
    });

    test('by name, so the server\'s changing order doesn\'t recolor anyone', () {
      const yu = Participant(id: 'p1', name: 'Yu');
      const jenny = Participant(id: 'p2', name: 'Jenny');
      const helen = Participant(id: 'p3', name: 'helen');
      final one = participantColors([yu, jenny, helen], null);
      expect(participantColors([jenny, helen, yu], null), one);
      expect([one['p3'], one['p2'], one['p1']], monogramPalette.sublist(1, 4));
    });
  });

  testWidgets('a screen reader hears the title first, then a sentence of who paid',
      (tester) async {
    await pump(tester,
        expense(paidBy: 'jo', recurrence: RecurrenceRule.monthly, documents: 1, notes: 'x'));
    expect(spoken(tester),
        'Dinner. Jo paid \$30.00 on Oct 6, 2026, General. You owe \$10.00. '
        'Repeats. Has receipts. Has notes.');
  });

  testWidgets('a reimbursement is read as paid back', (tester) async {
    await pump(tester, expense(paidBy: 'jo', reimbursement: true));
    expect(spoken(tester), 'Dinner. Jo paid back \$30.00 on Oct 6, 2026, General.');
    await pump(tester, expense(reimbursement: true));
    expect(spoken(tester), 'Dinner. You paid back \$30.00 on Oct 6, 2026, General.');
  });

  testWidgets('a payer the group doesn\'t know is left out of the sentence', (tester) async {
    await pump(tester, expense(paidBy: 'gone'), payer: null);
    expect(spoken(tester), 'Dinner. \$30.00 on Oct 6, 2026, General. You owe \$10.00.');
  });

  testWidgets('in Chinese, the sentences end with 。', (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      theme: spliit2goLightTheme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ExpenseTile(
          expense: expense(paidBy: 'jo'),
          category: general,
          currency: r'$',
          payer: 'Jo',
          activeUserId: 'me',
          onTap: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(spoken(tester), startsWith('Dinner。Jo 于 2026年10月6日 支付 \$30.00，'));
    expect(spoken(tester), endsWith('。你应付 \$10.00。'));
  });
}
