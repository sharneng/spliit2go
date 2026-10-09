import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/models/category.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/theme.dart';
import 'package:spliit2go/widgets/expense_list.dart';
import 'package:spliit2go/widgets/grouped_section.dart';

// #207: an expense row in two lines -- what you lent or owe, who paid,
// and marks for repeats, receipts and notes.
void main() {
  const general = Category(id: 0, name: 'General', grouping: 'Uncategorized');

  // $30.00 split evenly three ways: $10.00 each.
  Expense expense({
    String paidBy = 'me',
    bool settlement = false,
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
        isSettlement: settlement,
        recurrenceRule: recurrence,
        documentCount: documents,
        notes: notes,
        pending: pending,
        syncFailed: syncFailed,
      );

  // What a screen reader says for the row.
  String spoken(WidgetTester tester) => tester.getSemantics(find.byType(ListTile)).label;

  Future<void> pump(WidgetTester tester, Expense e,
      {String? activeUserId = 'me',
      String? payer = 'Jo',
      Category category = general,
      ThemeData? theme}) async {
    await tester.pumpWidget(MaterialApp(
      theme: theme ?? spliit2goLightTheme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ExpenseTile(
          expense: e,
          category: category,
          currency: r'$',
          payer: payer,
          activeUserId: activeUserId,
          onTap: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  // #224: a settlement isn't an expense, and looks it.
  testWidgets('a settlement: a fixed emerald banknote on the lines\' color, an italic title',
      (tester) async {
    const groceries = Category(id: 9, name: 'Groceries', grouping: 'Food and Drink');
    await pump(tester, expense(settlement: true), category: groceries);
    final icon = tester.widget<Icon>(find.byIcon(LucideIcons.banknote));
    expect(icon.color, spliit2goLightTheme.colorScheme.primary);
    expect(find.byIcon(LucideIcons.shoppingCart), findsNothing);
    final circle = tester.widget<Container>(
        find.ancestor(of: find.byIcon(LucideIcons.banknote), matching: find.byType(Container)).first);
    expect((circle.decoration! as BoxDecoration).color,
        spliit2goLightTheme.scaffoldBackgroundColor);
    final title = tester.widget<Text>(find.text('Dinner')).style!;
    expect(title.fontStyle, FontStyle.italic);
    expect(title.fontWeight, FontWeight.w400);

    // In dark mode, on the lines' lighter tone, which stands off the card.
    await pump(tester, expense(settlement: true), category: groceries, theme: spliit2goDarkTheme);
    final darkCircle = tester.widget<Container>(
        find.ancestor(of: find.byIcon(LucideIcons.banknote), matching: find.byType(Container)).first);
    expect((darkCircle.decoration! as BoxDecoration).color, GroupedDivider.darkColor);
    expect(tester.widget<Icon>(find.byIcon(LucideIcons.banknote)).color,
        spliit2goDarkTheme.colorScheme.primary);

    // An expense keeps its category's icon and a bold title.
    await pump(tester, expense(), category: groceries);
    expect(find.byIcon(LucideIcons.shoppingCart), findsOneWidget);
    expect(tester.widget<Text>(find.text('Dinner')).style!.fontStyle, isNull);
    expect(tester.widget<Text>(find.text('Dinner')).style!.fontWeight, FontWeight.w600);
  });

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

  testWidgets('a settlement shows who paid but no lent or owed amount', (tester) async {
    await pump(tester, expense(paidBy: 'jo', settlement: true));
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

    test('each takes the next of the seven by name, starting over; you are emerald in place of yours',
        () {
      final colors = participantColors(people, 'c');
      expect(colors['c'], monogramPalette[0]);
      final others = monogramPalette.sublist(1);
      expect([for (final id in ['a', 'b', 'd', 'e', 'f', 'g', 'h', 'i', 'j']) colors[id]],
          [others[0], others[1], others[3], others[4], others[5], others[6], others[0], others[1], null]);
    });

    test('picking someone else as you recolors only the two of you (#218)', () {
      final asC = participantColors(people, 'c');
      final asE = participantColors(people, 'e');
      final none = participantColors(people, null);
      for (final id in ['a', 'b', 'd', 'f', 'g', 'h', 'i']) {
        expect(asE[id], asC[id], reason: id);
        expect(asE[id], none[id], reason: id);
      }
      expect(asE['c'], none['c']);
      expect(asE['e'], monogramPalette[0]);
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

  testWidgets('a settlement is read as paid back', (tester) async {
    await pump(tester, expense(paidBy: 'jo', settlement: true));
    expect(spoken(tester), 'Dinner. Jo paid back \$30.00 on Oct 6, 2026, General.');
    await pump(tester, expense(settlement: true));
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
    expect(spoken(tester), endsWith('。您应付 \$10.00。'));
  });

  // #208 review: at phone widths and large text sizes the second line
  // must neither overflow nor let what you owe run into the payer. The
  // test font's glyphs are a full em wide, wider than the phones' fonts,
  // so this errs on the strict side.
  group('fits a phone', () {
    for (final width in [320.0, 360.0, 390.0]) {
      for (final scale in [1.0, 1.5, 2.0]) {
        testWidgets('${width.toInt()} wide, text at ${scale}x', (tester) async {
          tester.view.physicalSize = Size(width * 3, 1600 * 3);
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(MaterialApp(
            theme: spliit2goLightTheme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MediaQuery.withClampedTextScaling(
              minScaleFactor: scale,
              maxScaleFactor: scale,
              child: Scaffold(
                body: ExpenseDateList(
                  expenses: [
                    expense(paidBy: 'jo', recurrence: RecurrenceRule.monthly, documents: 1),
                  ],
                  currency: r'$',
                  categoryFor: (_) => general,
                  participants: const [
                    Participant(id: 'me', name: 'Me'),
                    Participant(id: 'jo', name: 'Bartholomew Montgomery'),
                    Participant(id: 'al', name: 'Al'),
                  ],
                  activeUserId: 'me',
                  onTap: (_) {},
                ),
              ),
            ),
          ));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          final owe = tester.getRect(find.text('\$10.00'));
          final payer = tester.getRect(find.text('Bartholomew Montgomery'));
          final row = tester.getRect(find.byType(ExpenseTile));
          expect(owe.overlaps(payer), isFalse, reason: '$owe overlaps $payer');
          // At the usual text size there's room for the marks.
          if (scale == 1.0) expect(find.byIcon(LucideIcons.repeat), findsOneWidget);
          for (final part in [owe, payer]) {
            expect(row.contains(part.topLeft) && row.contains(part.bottomRight - const Offset(1, 1)),
                isTrue,
                reason: '$part outside $row');
          }
        });
      }
    }
  });
}
