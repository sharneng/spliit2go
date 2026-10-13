import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/expense_form/currency_card.dart';
import 'package:spliit2go/screens/expense_screen.dart';
import 'package:spliit2go/sync/outbox.dart';
import 'package:spliit2go/utils/markdown_note.dart';
import 'package:spliit2go/widgets/segmented_pill.dart';

// Issue #311: the form's Markdown switch saves the notes behind the marker,
// which the field never shows, and adds Edit and Preview.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const group = Group(
    id: 'g1',
    name: 'Banff Trip',
    currency: '\$',
    participants: [
      Participant(id: 'alex', name: 'Alex'),
      Participant(id: 'bea', name: 'Bea'),
    ],
  );

  final markdownExpense = Expense(
    id: 'e1',
    groupId: 'g1',
    title: 'Hotel',
    amountCents: 9000,
    paidBy: 'bea',
    paidFor: const [
      ExpenseShare(participantId: 'alex', shares: 1),
      ExpenseShare(participantId: 'bea', shares: 1),
    ],
    notes: '$markdownMarker\n## Booking\nRoom 25',
    date: DateTime.utc(2026, 10, 10),
  );

  /// The form, adding or editing [existing]; the requests it sends land in
  /// [sent].
  Future<AppDatabase> pump(WidgetTester tester, {Expense? existing, List<http.Request>? sent}) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        if (!req.url.path.endsWith('groups.expenses.update')) throw http.ClientException('offline');
        sent?.add(req);
        return http.Response('[{"result":{"data":{"json":{"expenseId":"e1"}}}}]', 200);
      }),
    );
    await tester.runAsync(() => db.cacheGroup(group));
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ExpenseScreen(
        client: client,
        db: db,
        outbox: Outbox(db, client, groupId: 'g1'),
        group: group,
        existingExpense: existing,
      ),
    ));
    await tester.pumpAndSettle();
    return db;
  }

  Finder notesField() => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'Anything worth remembering?');

  Future<void> tapMarkdown(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Markdown'));
    await tester.tap(find.text('Markdown'));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String segment) async {
    final finder = find.descendant(of: find.byType(SegmentedPill<bool>), matching: find.text(segment));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('off by default: no Edit or Preview, and the notes saved as typed', (tester) async {
    final db = await pump(tester);
    expect(find.text('Markdown'), findsOneWidget);
    expect(find.byType(SegmentedPill<bool>), findsNothing);

    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Hotel');
    await tester.enterText(find.byKey(CurrencyCard.amountFieldKey), '90');
    await tester.enterText(notesField(), '# Room 25');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    expect(db.rowToExpense((await db.pendingExpenses()).single).notes, '# Room 25');
  });

  testWidgets('on: saved behind the marker, and Preview shows it rendered', (tester) async {
    final db = await pump(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Hotel');
    await tester.enterText(find.byKey(CurrencyCard.amountFieldKey), '90');
    await tapMarkdown(tester);

    await choose(tester, 'Preview');
    expect(find.text('Nothing to preview yet'), findsOneWidget);
    await choose(tester, 'Edit');
    await tester.enterText(notesField(), '## Booking\nRoom 25');
    await choose(tester, 'Preview');
    expect(notesField(), findsNothing);
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.textContaining('##', findRichText: true), findsNothing);

    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(db.rowToExpense((await db.pendingExpenses()).single).notes, '$markdownMarker\n## Booking\nRoom 25');
  });

  testWidgets('editing a markdown note: the switch on, the field without the marker', (tester) async {
    await pump(tester, existing: markdownExpense);

    expect(tester.widget<TextField>(notesField()).controller!.text, '## Booking\nRoom 25');
    expect(find.byType(SegmentedPill<bool>), findsOneWidget);
  });

  testWidgets('turning it off saves the note plain', (tester) async {
    final sent = <http.Request>[];
    await pump(tester, existing: markdownExpense, sent: sent);
    await tapMarkdown(tester);
    expect(find.byType(SegmentedPill<bool>), findsNothing);

    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    final body = sent.single.body;
    expect(body, contains(jsonEncode('## Booking\nRoom 25')));
    expect(body, isNot(contains(markdownMarker)));
  });

  testWidgets('a note the marker takes past the limit is refused, in Edit, not cut (PR #312 review)',
      (tester) async {
    final db = await pump(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Hotel');
    await tester.enterText(find.byKey(CurrencyCard.amountFieldKey), '90');
    final full = 'x' * expenseNotesMax;
    await tester.enterText(notesField(), full);
    await tapMarkdown(tester);
    await choose(tester, 'Preview');

    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    expect(await db.pendingExpenses(), isEmpty);
    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.text('${markdownMarker.length + 1} characters too long'), findsOneWidget);
    expect(tester.widget<TextField>(notesField()).controller!.text, full);
  });

  testWidgets('markdown keeps its leading spaces: preview, save and edit (PR #312 review)', (tester) async {
    const body = '    confirmation = 25';
    final db = await pump(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Hotel');
    await tester.enterText(find.byKey(CurrencyCard.amountFieldKey), '90');
    await tapMarkdown(tester);
    await tester.enterText(notesField(), '$body\n');
    await choose(tester, 'Preview');
    expect(tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data, body);

    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    final saved = db.rowToExpense((await db.pendingExpenses()).single);
    expect(saved.notes, '$markdownMarker\n$body');
  });

  testWidgets('editing keeps them too', (tester) async {
    const body = '    confirmation = 25';
    await pump(tester,
        existing: Expense(
          id: 'e1',
          groupId: 'g1',
          title: 'Hotel',
          amountCents: 9000,
          paidBy: 'bea',
          paidFor: const [ExpenseShare(participantId: 'bea', shares: 1)],
          notes: '$markdownMarker\n$body',
          date: DateTime.utc(2026, 10, 10),
        ));
    expect(tester.widget<TextField>(notesField()).controller!.text, body);
  });
}
