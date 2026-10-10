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
import 'package:spliit2go/screens/expense_form/currency_card.dart';
import 'package:spliit2go/screens/expense_form/split_card.dart';
import 'package:spliit2go/screens/expense_screen.dart';
import 'package:spliit2go/sync/outbox.dart';
import 'package:spliit2go/screens/expense_form/form_text.dart';
import 'package:spliit2go/theme.dart';
import 'package:spliit2go/widgets/category_icon.dart';
import 'package:spliit2go/widgets/grouped_section.dart';
import 'package:spliit2go/widgets/segmented_pill.dart';

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
  Future<(AppDatabase, List<bool?>)> open(WidgetTester tester, {Expense? editing, Expense? draft}) async {
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
                initialDraft: draft,
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

  // An edit leaving its saved kind converts it (#272); otherwise it switches.
  Future<void> pickKind(WidgetTester tester, String kind, {String verb = 'Switch'}) async {
    await tester.tap(find.byTooltip('$verb to ${kind.toLowerCase()}'));
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
      // No Amount: the To amounts make it (#262), and the title is filled.
      expect(find.byKey(CurrencyCard.amountFieldKey), findsNothing);
      expect(tester.widget<TextFormField>(title()).controller!.text, 'Settlement');
      await tester.enterText(title(), 'Bea paid Alex');
      await tester.enterText(find.byKey(SplitCard.valueKey('alex')), '30');
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      final saved = db.rowToExpense((await db.pendingExpenses()).single);
      expect((saved.isSettlement, saved.category, saved.amountCents, saved.splitMode), (true, 1, 3000, SplitMode.byAmount));
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
      await pickKind(tester, 'Expense', verb: 'Convert');
      await tester.tap(find.text('Convert'));
      await tester.pumpAndSettle();
      expect(find.text('Edit expense'), findsOneWidget);
      // The category it had all along: see the model's categoryToSave.
      expect(find.widgetWithText(GroupedRow, 'Category'), findsOneWidget);
    });
  });

  group('changing the kind asks first, when it would surprise (#272)', () {
    final saved = Expense(
      id: 'e1',
      groupId: 'g1',
      title: 'Groceries',
      amountCents: 3000,
      paidBy: 'bea',
      paidFor: const [ExpenseShare(participantId: 'alex', shares: 100)],
      splitMode: SplitMode.evenly,
      category: 8,
      date: DateTime.utc(2026, 10, 1),
    );

    testWidgets('a fresh form switches straight away, back and forth', (tester) async {
      await open(tester);
      await pickKind(tester, 'Settlement');
      expect(find.text('New settlement'), findsOneWidget);
      await pickKind(tester, 'Expense');
      expect(find.text('New expense'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a changed new form asks; Cancel keeps the kind', (tester) async {
      await open(tester);
      await tester.enterText(title(), 'Groceries');
      await pickKind(tester, 'Settlement');
      expect(find.text('Change to a settlement?'), findsOneWidget);
      expect(
          find.text('A settlement records money paid back. Its amount is what each person received, '
              'and it has no category.'),
          findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('New expense'), findsOneWidget);

      await pickKind(tester, 'Settlement');
      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      expect(find.text('New settlement'), findsOneWidget);
      // Back asks too: the title is still the user's.
      await pickKind(tester, 'Expense');
      expect(find.text('Change to an expense?'), findsOneWidget);
    });

    testWidgets('an edit asks only when leaving its saved kind, and says so', (tester) async {
      await open(tester, editing: saved);
      await pickKind(tester, 'Settlement', verb: 'Convert');
      for (final paragraph in [
        'Are you sure you want to convert this existing expense to a settlement?',
        'A settlement records money paid back. Its amount is what each person received, and it has no category.',
        'The conversion is saved only when you tap Save (✓).',
      ]) {
        expect(find.text(paragraph), findsOneWidget);
      }
      await tester.tap(find.text('Convert'));
      await tester.pumpAndSettle();
      expect(find.text('Edit settlement'), findsOneWidget);

      // Back to what's saved: no question.
      await pickKind(tester, 'Expense');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Edit expense'), findsOneWidget);
    });

    testWidgets('Mark as paid has no kind button', (tester) async {
      await open(tester,
          draft: Expense(
            id: '',
            groupId: 'g1',
            title: 'Bea paid Alex',
            amountCents: 3000,
            paidBy: 'bea',
            paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
            date: DateTime.utc(2026, 10, 1),
            isSettlement: true,
          ));
      expect(find.text('New settlement'), findsOneWidget);
      expect(find.byTooltip('Switch to expense'), findsNothing);
      expect(find.byTooltip('Save'), findsOneWidget);
    });
  });

  group('a picker takes the focus from a text field, so closing it doesn\'t scroll back (#267)', () {
    Future<void> check(WidgetTester tester, String row, Future<void> Function() pick) async {
      await open(tester);
      await tester.tap(title());
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TextFormField>(), isNotNull);
      final r = find.widgetWithText(GroupedRow, row);
      await tester.ensureVisible(r);
      await tester.pumpAndSettle();
      await tester.tap(r);
      await tester.pumpAndSettle();
      await pick();
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>(), isNull);
    }

    testWidgets('Paid by', (tester) => check(tester, 'Paid by', () => tester.tap(find.text('Bea').last)));
    testWidgets('Repeat', (tester) => check(tester, 'Repeat', () => tester.tap(find.text('Weekly').last)));
    testWidgets('Date', (tester) => check(tester, 'Date', () => tester.tap(find.text('OK'))));
  });

  group('rows: a dimmed label, the value in the primary color (#274)', () {
    // Not the split mode's "Amount".
    Finder amountLabel() => find.descendant(of: find.byType(CurrencyCard), matching: find.text('Amount'));

    testWidgets('labels are dimmed; values and the category icon are at the end', (tester) async {
      await open(tester);
      final context = tester.element(find.byType(ExpenseScreen));
      final dimmed = SpliitColors.of(context).secondaryContent;
      for (final label in ['Category', 'Date', 'Repeat', 'Paid by']) {
        expect(tester.widget<Text>(find.text(label)).style?.color, dimmed, reason: label);
      }
      expect(tester.widget<Text>(amountLabel()).style?.color, dimmed);
      expect(tester.widget<Text>(find.text('Never')).style, formValueStyle(context));
      final category = find.widgetWithText(GroupedRow, 'Category');
      expect(tester.widget<GroupedRow>(category).leading, isNull);
      expect(tester.getCenter(find.descendant(of: category, matching: find.byType(CategoryIconGlyph))).dx,
          greaterThan(tester.getCenter(find.text('Category')).dx));
    });

    testWidgets('the currency symbol is always right before the amount, and its error under the row',
        (tester) async {
      await open(tester);
      final amount = find.byKey(CurrencyCard.amountFieldKey);
      final symbol = find.text('\$ ');
      expect(symbol, findsOneWidget);
      double gap() => tester.getTopLeft(amount).dx - tester.getTopRight(symbol).dx;
      expect(gap(), lessThan(1));

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid amount'), findsOneWidget);
      // Under the row, starting where its label does.
      expect(tester.getTopLeft(find.text('Enter a valid amount')).dx, tester.getTopLeft(amountLabel()).dx);

      // A tap on the label puts the cursor in the field.
      await tester.tap(amountLabel());
      await tester.pump();
      expect(tester.widget<EditableText>(find.descendant(of: amount, matching: find.byType(EditableText))).focusNode.hasFocus,
          isTrue);
      await tester.enterText(amount, '12');
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid amount'), findsNothing);
      expect(symbol, findsOneWidget);
      expect(gap(), lessThan(1));
    });

    testWidgets('Select none doesn\'t make the Paid for caption taller than the others', (tester) async {
      await open(tester);
      final caption = find.widgetWithText(GroupedCaption, 'Paid for');
      final withLink = tester.getSize(caption).height;
      await tester.ensureVisible(find.text('Shares'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Shares'));
      await tester.pumpAndSettle();
      expect(find.text('Select none'), findsNothing);
      expect(tester.getSize(caption).height, closeTo(withLink, 4));
    });

    testWidgets('the split mode is a pill with the chosen mode selected', (tester) async {
      await open(tester);
      final pill = find.byType(SegmentedPill<SplitMode>);
      expect(tester.widget<SegmentedPill<SplitMode>>(pill).selected, SplitMode.evenly);
      await tester.ensureVisible(pill);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Percent'));
      await tester.pumpAndSettle();
      expect(tester.widget<SegmentedPill<SplitMode>>(pill).selected, SplitMode.byPercentage);
      expect(tester.getSemantics(find.text('Percent')), matchesSemantics(isButton: true, isSelected: true,
          hasSelectedState: true, isInMutuallyExclusiveGroup: true, hasTapAction: false, label: 'Percent'));
    });
  });

  testWidgets('Notes come last, 12 lines before they scroll (#268)', (tester) async {
    await open(tester);
    final notes = find.widgetWithText(GroupedSection, 'Notes');
    expect(tester.getTopLeft(notes).dy, greaterThan(tester.getTopLeft(find.widgetWithText(GroupedSection, 'Receipts')).dy));
    final field = tester.widget<TextField>(find.descendant(of: notes, matching: find.byType(TextField)));
    expect(field.maxLines, 12);
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
