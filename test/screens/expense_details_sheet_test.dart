import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/models/category.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/expense_details_sheet.dart';
import 'package:spliit2go/services/receipt_cache.dart';
import 'package:spliit2go/theme.dart';
import 'package:spliit2go/sync/outbox.dart';
import 'package:spliit2go/widgets/category_icon.dart';

import '../support/error_log.dart';
import '../support/haptics.dart';

// Issue #90: tapping an expense shows its details in a sheet, with Edit,
// Retry and Discard inside it depending on the expense's state.

/// The expense details' edit or delete button, an icon on a capsule
/// (#226), by its tooltip: still there while it shows a spinner.
Finder actionButton(String tooltip) =>
    find.ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton));

void main() {
  // Not named `group`: that would hide flutter_test's group().
  const banff = Group(
    id: 'g1',
    name: 'Banff Trip',
    currency: '\$',
    participants: [
      Participant(id: 'alex', name: 'Alex'),
      Participant(id: 'bea', name: 'Bea'),
    ],
  );
  const diningOut = Category(id: 8, name: 'Dining Out', grouping: 'Food and Drink');

  Expense dinner({String title = 'Dinner', SplitMode splitMode = SplitMode.byShares}) => Expense(
        id: 'e1',
        groupId: 'g1',
        title: title,
        amountCents: 6000,
        paidBy: 'bea',
        paidFor: splitMode == SplitMode.byPercentage
            // Basis points.
            ? const [
                ExpenseShare(participantId: 'alex', shares: 6667),
                ExpenseShare(participantId: 'bea', shares: 3333),
              ]
            : const [
                // Stored times 100, as the server does.
                ExpenseShare(participantId: 'alex', shares: 200),
                ExpenseShare(participantId: 'bea', shares: 100),
              ],
        splitMode: splitMode,
        category: 8,
        notes: 'Birthday dinner',
        date: DateTime(2026, 9, 16),
        recurrenceRule: RecurrenceRule.weekly,
        originalAmountCents: 5500,
        originalCurrency: 'EUR',
        conversionRate: 1.09,
      );

  /// groups.expenses.get's response for [dinner].
  String expenseResponse({String title = 'Dinner', List<Map<String, Object>>? documents}) =>
      jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'expense': {
                  'id': 'e1',
                  'title': title,
                  'amount': 6000,
                  'paidBy': 'bea',
                  'paidFor': [
                    {'participant': 'alex', 'shares': 2},
                    {'participant': 'bea', 'shares': 1},
                  ],
                  'splitMode': 'BY_SHARES',
                  'category': 8,
                  'notes': 'Birthday dinner',
                  'expenseDate': '2026-09-16T00:00:00.000Z',
                  'isReimbursement': false,
                  if (documents != null) 'documents': documents,
                },
              },
            },
          },
        },
      ]);

  const notFound =
      '[{"error":{"json":{"message":"Expense not found","code":-32004,"data":{"code":"NOT_FOUND"}}}}]';

  SpliitClient serverClient(Future<http.Response> Function(http.Request req) handler) =>
      SpliitClient(baseUrl: 'https://example.test', httpClient: MockClient(handler));

  final offlineClient = serverClient((_) async => throw http.ClientException('offline'));

  bool? result;
  setUp(() => result = null);

  /// A screen with a button that opens the sheet and records what
  /// showExpenseDetails returned.
  Future<void> openSheet(
    WidgetTester tester,
    AppDatabase db, {
    SpliitClient? client,
    bool fetchIfMissing = false,
    Stream<bool> connectivity = const Stream.empty(),
    String? activeUserId,
    Locale locale = const Locale('en'),
    TransitionBuilder? builder,
  }) async {
    final c = client ?? offlineClient;
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: builder,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                result = await showExpenseDetails(
                  context,
                  expenseId: 'e1',
                  group: banff,
                  db: db,
                  client: c,
                  outbox: Outbox(db, c, groupId: 'g1'),
                  categories: const [diningOut],
                  activeUserId: activeUserId,
                  fetchIfMissing: fetchIfMissing,
                  connectivity: connectivity,
                  now: () => DateTime(2026, 10, 8),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// The sheet watches its row in drift; tear the tree down this way or
  /// the watch's zero-length timer fails the test (issue #47).
  Future<void> closeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// Room for the whole sheet, so nothing sits below a lazy list's fold.
  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<AppDatabase> cachedDb([Expense? e]) async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.replaceServerExpenses('g1', [e ?? dinner()]);
    return db;
  }

  Finder inSheet(Finder f) => find.descendant(of: find.byType(BottomSheet), matching: f);

  testWidgets('shows a cached expense\'s details, offline', (tester) async {
    tallView(tester);
    final db = await cachedDb();
    addTearDown(db.close);
    await openSheet(tester, db, activeUserId: 'bea');

    expect(inSheet(find.text('Dinner')), findsOneWidget);
    expect(inSheet(find.text('\$60.00')), findsOneWidget);
    // After its currency's code, as every original: ¥ alone is yen or yuan.
    expect(inSheet(find.text('Originally EUR €55.00')), findsOneWidget);
    // Who, when and what in one sentence (#226): Bea paid, and is this
    // device's active user; within ten months, no year.
    // Then your part, as the list row's arrow (#226).
    expect(
        inSheet(find.text('Paid by you on Sep 16 under Dining Out, repeats weekly. You lent \$40.00.')),
        findsOneWidget);
    expect(inSheet(find.text('Bea (you)')), findsOneWidget);
    // By shares, 2:1: each person's shares, as entered (#226)...
    expect(inSheet(find.text('Shares')), findsOneWidget);
    expect(inSheet(find.text('2')), findsOneWidget);
    expect(inSheet(find.text('1')), findsOneWidget);
    // ...or what they come to -- the same apportionment Balances and
    // Stats use.
    await tester.tap(inSheet(find.text('Show amounts')));
    await tester.pumpAndSettle();
    expect(inSheet(find.text('\$40.00')), findsOneWidget);
    expect(inSheet(find.text('\$20.00')), findsOneWidget);
    expect(inSheet(find.text('2')), findsNothing);
    await tester.tap(inSheet(find.text('Hide amounts')));
    await tester.pumpAndSettle();
    expect(inSheet(find.text('2')), findsOneWidget);
    expect(inSheet(find.text('Birthday dinner')), findsOneWidget);
    expect(inSheet(actionButton('Edit')), findsOneWidget);
    // Dismissing isn't a change.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(result, isFalse);
    await closeTree(tester);
  });

  testWidgets('an evenly split settlement with no extras', (tester) async {
    tallView(tester);
    final db = await cachedDb(Expense(
      id: 'e1',
      groupId: 'g1',
      title: 'Payback',
      amountCents: 1000,
      paidBy: 'alex',
      paidFor: const [ExpenseShare(participantId: 'bea', shares: 1)],
      isSettlement: true,
      date: DateTime(2026, 9, 16),
    ));
    addTearDown(db.close);
    await openSheet(tester, db);

    // For settlement, not its category; no repeats (#226). Paid to one
    // person, named in the sentence instead of a list (#247).
    expect(inSheet(find.text('Paid by Alex to Bea on Sep 16 for settlement')), findsOneWidget);
    expect(inSheet(find.text('Paid for')), findsNothing);
    expect(inSheet(find.text('Evenly')), findsNothing);
    expect(inSheet(find.textContaining('Originally')), findsNothing);
    expect(inSheet(find.text('Notes')), findsNothing);
    // No active user: nobody is marked "you". An even split shows no shares.
    expect(inSheet(find.textContaining('(you)')), findsNothing);
    expect(inSheet(find.textContaining('share')), findsNothing);
    // Italic, as its row in the list (#224).
    expect(tester.widget<Text>(inSheet(find.text('Payback'))).style!.fontStyle, FontStyle.italic);
    await closeTree(tester);
  });

  // #226: the redesign.
  testWidgets('a top bar of the category, status and buttons above the title; one sentence',
      (tester) async {
    final semantics = tester.ensureSemantics();
    tallView(tester);
    final db = await cachedDb(dinner(title: 'A long title ' * 6));
    addTearDown(db.close);
    await openSheet(tester, db, activeUserId: 'bea');

    final title = tester.getRect(inSheet(find.textContaining('A long title')));
    for (final button in ['Edit', 'Delete']) {
      final rect = tester.getRect(inSheet(actionButton(button)));
      expect(rect.bottom, lessThanOrEqualTo(title.top), reason: '$button above the title');
    }
    // The title has the row to itself: as wide as the sheet allows.
    expect(title.right, greaterThan(tester.getRect(inSheet(actionButton('Delete'))).left));
    // Edit, the main action, rightmost; the category icon leading.
    expect(tester.getRect(inSheet(actionButton('Edit'))).left,
        greaterThan(tester.getRect(inSheet(actionButton('Delete'))).left));
    expect(tester.getRect(inSheet(find.byType(CategoryIconGlyph))).bottom,
        lessThanOrEqualTo(title.top));

    // The sentence's fixed words dimmed, its names, date and category not.
    final sentence = tester.widget<Text>(inSheet(find.textContaining('Paid by')));
    final spans = (sentence.textSpan! as TextSpan).children!.cast<TextSpan>();
    final colors = SpliitColors.of(tester.element(find.byType(BottomSheet)));
    final color = {for (final span in spans) span.text!: span.style?.color};
    final fixed = colors.secondaryContent;
    expect(color, {
      'Paid by ': fixed, 'you': null, ' on ': fixed, 'Sep 16': null, ' under ': fixed,
      'Dining Out': null, ', repeats ': fixed, 'weekly': null, '. You lent ': fixed,
      '\$40.00': colors.moneyPositive, '.': fixed,
    });

    // A monogram before each person.
    expect(inSheet(find.text('A')), findsOneWidget);
    expect(inSheet(find.text('B')), findsOneWidget);

    // The title and amount read as one.
    expect(find.bySemanticsLabel(RegExp(r'^A long title .*, \$60\.00, Originally EUR €55\.00$')),
        findsOneWidget);
    semantics.dispose();
    await closeTree(tester);
  });

  testWidgets('a split by percentages shows each share as a percent, decimals kept (#226)',
      (tester) async {
    tallView(tester);
    final db = await cachedDb(dinner(splitMode: SplitMode.byPercentage));
    addTearDown(db.close);
    await openSheet(tester, db);

    expect(inSheet(find.text('66.67%')), findsOneWidget);
    expect(inSheet(find.text('33.33%')), findsOneWidget);
    await closeTree(tester);

    // The smallest share isn't rounded to nothing (#236 review); every one
    // has two decimals, so they line up.
    for (final (shares, expected) in [
      ((1, 9999), ('0.01%', '99.99%')),
      ((5000, 5000), ('50.00%', '50.00%')),
    ]) {
      final split = Expense(
        id: 'e1',
        groupId: 'g1',
        title: 'Split',
        amountCents: 1000000,
        paidBy: 'alex',
        paidFor: [
          ExpenseShare(participantId: 'alex', shares: shares.$1),
          ExpenseShare(participantId: 'bea', shares: shares.$2),
        ],
        splitMode: SplitMode.byPercentage,
        date: DateTime(2026, 9, 16),
      );
      final db = await cachedDb(split);
      await openSheet(tester, db);
      expect(inSheet(find.text(expected.$1)), findsWidgets, reason: expected.$1);
      expect(inSheet(find.text(expected.$2)), findsWidgets, reason: expected.$2);
      await closeTree(tester);
      await db.close();
    }
  });

  testWidgets('a date over ten months old keeps its year (#226)', (tester) async {
    tallView(tester);
    final db = await cachedDb(Expense(
      id: 'e1',
      groupId: 'g1',
      title: 'Old',
      amountCents: 1000,
      paidBy: 'alex',
      paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
      date: DateTime(2025, 11, 30),
    ));
    addTearDown(db.close);
    await openSheet(tester, db);

    expect(inSheet(find.text('Paid by Alex for themselves on Nov 30, 2025 under General')), findsOneWidget);
    await closeTree(tester);
  });

  group('the sentence ends with your part (#226)', () {
    Expense payback() => Expense(
          id: 'e1',
          groupId: 'g1',
          title: 'Payback',
          amountCents: 1000,
          paidBy: 'alex',
          paidFor: const [ExpenseShare(participantId: 'bea', shares: 1)],
          isSettlement: true,
          date: DateTime(2026, 9, 16),
        );
    for (final (name, expense, me, ending) in [
      ('someone else paid', null, 'alex', '. You owe \$40.00.'),
      ("you're not in it", null, 'cara', ". You aren't involved."),
      ('no one is you', null, null, ' under Dining Out, repeats weekly'),
      ('a settlement paid to you', payback(), 'bea', '. You received \$10.00.'),
      ('a settlement you paid', payback(), 'alex', ' for settlement'),
      ('a settlement not yours', payback(), 'cara', ". You aren't involved."),
    ]) {
      testWidgets(name, (tester) async {
        tallView(tester);
        final db = await cachedDb(expense ?? dinner());
        addTearDown(db.close);
        await openSheet(tester, db, activeUserId: me);
        final sentence =
            tester.widget<Text>(inSheet(find.textContaining('Paid by'))).textSpan!.toPlainText();
        expect(sentence, endsWith(ending));
        await closeTree(tester);
      });
    }
  });

  testWidgets('a settlement received is in emerald', (tester) async {
    tallView(tester);
    final db = await cachedDb(Expense(
      id: 'e1',
      groupId: 'g1',
      title: 'Payback',
      amountCents: 1000,
      paidBy: 'alex',
      paidFor: const [ExpenseShare(participantId: 'bea', shares: 1)],
      isSettlement: true,
      date: DateTime(2026, 9, 16),
    ));
    addTearDown(db.close);
    await openSheet(tester, db, activeUserId: 'bea');
    final spans = (tester.widget<Text>(inSheet(find.textContaining('Paid by'))).textSpan!
            as TextSpan)
        .children!
        .cast<TextSpan>();
    final amount = spans.singleWhere((s) => s.text == '\$10.00');
    expect(amount.style!.color,
        Theme.of(tester.element(find.byType(BottomSheet))).colorScheme.primary);
    await closeTree(tester);
  });

  testWidgets('an original amount in an unknown currency shows its code once (#226)',
      (tester) async {
    tallView(tester);
    final db = await cachedDb(Expense(
      id: 'e1',
      groupId: 'g1',
      title: 'Lunch',
      amountCents: 1000,
      paidBy: 'alex',
      paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
      date: DateTime(2026, 9, 16),
      originalAmountCents: 900,
      originalCurrency: 'XYZ',
    ));
    addTearDown(db.close);
    await openSheet(tester, db);
    expect(inSheet(find.textContaining('Originally')), findsOneWidget);
    expect(tester.widget<Text>(inSheet(find.textContaining('Originally'))).data!
        .split('XYZ').length - 1, 1);
    await closeTree(tester);
  });

  testWidgets('an original amount in yen shows whole yen (#251)', (tester) async {
    tallView(tester);
    final db = await cachedDb(Expense(
      id: 'e1',
      groupId: 'g1',
      title: 'Ramen',
      amountCents: 610,
      paidBy: 'alex',
      paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
      date: DateTime(2026, 9, 16),
      originalAmountCents: 1000,
      originalCurrency: 'JPY',
      conversionRate: 0.0061,
    ));
    addTearDown(db.close);
    await openSheet(tester, db);
    expect(inSheet(find.text('Originally JPY ¥1,000')), findsOneWidget);
    await closeTree(tester);
  });

  testWidgets('a participant no longer in the group reads "Someone"', (tester) async {
    tallView(tester);
    final db = await cachedDb(Expense(
      id: 'e1',
      groupId: 'g1',
      title: 'Taxi',
      amountCents: 1000,
      paidBy: 'gone',
      paidFor: const [
        ExpenseShare(participantId: 'gone', shares: 1),
        ExpenseShare(participantId: 'alex', shares: 1),
      ],
      date: DateTime(2026, 9, 16),
    ));
    addTearDown(db.close);
    await openSheet(tester, db);

    expect(inSheet(find.text('Paid by Someone on Sep 16 under General')), findsOneWidget,
        reason: 'General named: the only place the category shows');
    expect(inSheet(find.text('Someone')), findsOneWidget);
    expect(inSheet(find.text('Alex')), findsOneWidget);
    await closeTree(tester);
  });

  testWidgets('known offline: Edit and Delete are disabled with the reason shown, until back online',
      (tester) async {
    final db = await cachedDb();
    addTearDown(db.close);
    final online = StreamController<bool>();
    addTearDown(online.close);
    await openSheet(tester, db, connectivity: online.stream);

    online.add(false);
    await tester.pumpAndSettle();
    IconButton edit() =>
        tester.widget<IconButton>(inSheet(actionButton('Edit')));
    IconButton delete() =>
        tester.widget<IconButton>(inSheet(actionButton('Delete')));
    const reason = 'Editing or deleting an expense needs a connection.';
    expect(edit().onPressed, isNull);
    expect(delete().onPressed, isNull);
    expect(inSheet(find.text(reason)), findsOneWidget);
    // Short in the top bar, the reason under it (#226).
    expect(inSheet(find.text('No connection')), findsOneWidget);

    online.add(true);
    await tester.pumpAndSettle();
    expect(inSheet(find.text('No connection')), findsNothing);
    expect(edit().onPressed, isNotNull);
    expect(delete().onPressed, isNotNull);
    expect(inSheet(find.text(reason)), findsNothing);
    await closeTree(tester);
  });

  testWidgets('Edit on an expense deleted elsewhere says so and stays open', (tester) async {
    final db = await cachedDb();
    addTearDown(db.close);
    await openSheet(tester, db, client: serverClient((_) async => http.Response(notFound, 404)));

    await tester.tap(inSheet(actionButton('Edit')));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet(find.text('This expense is no longer available.')), findsOneWidget);
    expect(find.text('Edit expense'), findsNothing);
    await closeTree(tester);
  });

  // #119 review: Edit used to call every non-404 failure a connection
  // problem, and drop the error.
  testWidgets('Edit on a malformed response says so, logged, with details', (tester) async {
    final db = await cachedDb();
    addTearDown(db.close);
    expectUnexpectedError<TypeError>('Fetching expense e1 to edit');
    await openSheet(tester, db,
        client: serverClient((_) async => http.Response('[{"result":{"data":{"json":{}}}}]', 200)));

    await tester.tap(inSheet(actionButton('Edit')));
    await tester.pumpAndSettle();

    expect(inSheet(find.text("Couldn't open this expense for editing.")), findsOneWidget);
    expect(inSheet(find.text('Editing an expense needs a connection.')), findsNothing);
    expect(inSheet(find.text('Tap for details')), findsOneWidget);
    expect(loggedUnexpectedErrors.where((e) => e.operation == 'Fetching expense e1 to edit'), hasLength(1));
    await closeTree(tester);
  });

  testWidgets('Edit with no connection says so, with no details', (tester) async {
    final db = await cachedDb();
    addTearDown(db.close);
    await openSheet(tester, db,
        client: serverClient((_) async => throw http.ClientException('Failed host lookup')));

    await tester.tap(inSheet(actionButton('Edit')));
    await tester.pumpAndSettle();

    expect(inSheet(find.text('Editing an expense needs a connection.')), findsOneWidget);
    expect(inSheet(find.text('Tap for details')), findsNothing);
    await closeTree(tester);
  });

  testWidgets('a saved edit is reported as a change', (tester) async {
    tallView(tester);
    final db = await cachedDb();
    addTearDown(db.close);
    var updates = 0;
    await openSheet(tester, db, client: serverClient((req) async {
      final url = req.url.toString();
      if (url.contains('groups.expenses.get')) return http.Response(expenseResponse(), 200);
      if (url.contains('groups.expenses.update')) {
        updates++;
        return http.Response('[{"result":{"data":{"json":{"expenseId":"e1"}}}}]', 200);
      }
      throw http.ClientException('offline');
    }));

    await tester.tap(inSheet(actionButton('Edit')));
    await tester.pumpAndSettle();
    expect(find.text('Edit expense'), findsOneWidget);

    final save = find.byTooltip('Save');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(updates, 1);
    expect(find.text('Edit expense'), findsNothing);
    expect(result, isTrue);
    await closeTree(tester);
  });

  // #128: Spliit's update deletes every document missing from the list
  // it's sent, so an edit that sent none removed receipts attached on the
  // web or iOS.
  testWidgets('an edit keeps the receipts attached elsewhere, ids and all', (tester) async {
    tallView(tester);
    final db = await cachedDb();
    addTearDown(db.close);
    // The images aren't what this test is about: the bucket is offline.
    ReceiptCache.use(ReceiptCache(db,
        httpClient: MockClient((_) async => throw http.ClientException('offline'))));
    const receipts = [
      {'id': 'd1', 'url': 'https://bucket.test/document-1.jpg', 'width': 1536, 'height': 2048},
      {'id': 'd2', 'url': 'https://bucket.test/document-2.jpg', 'width': 2048, 'height': 1024},
    ];
    http.Request? update;
    await openSheet(tester, db, client: serverClient((req) async {
      final url = req.url.toString();
      if (url.contains('groups.expenses.get')) {
        return http.Response(expenseResponse(documents: receipts), 200);
      }
      if (url.contains('groups.expenses.update')) {
        update = req;
        return http.Response('[{"result":{"data":{"json":{"expenseId":"e1"}}}}]', 200);
      }
      throw http.ClientException('offline');
    }));

    await tester.tap(inSheet(actionButton('Edit')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Dinner by the lake');
    final save = find.byTooltip('Save');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    final sent = jsonDecode(update!.body)['0']['json']['expenseFormValues'] as Map<String, dynamic>;
    expect(sent['title'], 'Dinner by the lake');
    expect(sent['documents'], receipts);
    await closeTree(tester);
  });

  testWidgets('the sheet follows its row: updates when it changes, closes when it goes',
      (tester) async {
    final db = await cachedDb();
    addTearDown(db.close);
    await openSheet(tester, db);

    // A refresh brings someone else's edit.
    await tester.runAsync(() => db.replaceServerExpenses('g1', [dinner(title: 'Team dinner')]));
    await tester.pumpAndSettle();
    expect(inSheet(find.text('Team dinner')), findsOneWidget);

    // A refresh no longer has it.
    await tester.runAsync(() => db.replaceServerExpenses('g1', []));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(result, isFalse);
    await closeTree(tester);
  });

  group('pending and failed expenses', () {
    Expense snacks() => Expense(
          id: 'e1',
          groupId: 'g1',
          title: 'Snacks',
          amountCents: 300,
          paidBy: 'alex',
          paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
          date: DateTime(2026, 9, 16),
          pending: true,
        );

    Future<AppDatabase> failedDb() async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.insertPending(snacks());
      await db.recordSyncFailure(
          id: 'e1', error: 'SpliitApiException(400): bad request', retryCount: 1, failed: true);
      return db;
    }

    testWidgets('a pending expense can be viewed but not edited', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.insertPending(snacks());
      await openSheet(tester, db);

      expect(inSheet(find.text('Snacks')), findsOneWidget);
      // A short status in the top bar, what it means under it (#226).
      expect(inSheet(find.text('Waiting to sync')), findsOneWidget);
      expect(inSheet(find.textContaining('once it reaches the server')), findsOneWidget);
      expect(inSheet(actionButton('Edit')), findsNothing);
      await closeTree(tester);
    });

    testWidgets('Retry requeues it and reports a change', (tester) async {
      final db = await failedDb();
      addTearDown(db.close);
      await openSheet(tester, db);

      expect(inSheet(find.text('Sync failed')), findsOneWidget);
      expect(inSheet(find.textContaining('bad request')), findsOneWidget);
      // Its buttons named in the hint, their icons drawn in it.
      expect(inSheet(find.byWidgetPredicate((w) => w is Icon && w.icon == Icons.refresh)),
          findsNWidgets(2));
      // Retry rightmost, Discard before it.
      expect(tester.getRect(inSheet(actionButton('Retry'))).left,
          greaterThan(tester.getRect(inSheet(actionButton('Discard'))).left));
      await tester.tap(inSheet(actionButton('Retry')));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(result, isTrue);
      final row = (await tester.runAsync(() => db.pendingExpensesForGroup('g1')))!.single;
      expect(row.syncFailed, isFalse);
      await closeTree(tester);
    });

    testWidgets('Discard removes this device\'s copy and reports a change', (tester) async {
      final db = await failedDb();
      addTearDown(db.close);
      await openSheet(tester, db);

      await tester.tap(inSheet(actionButton('Discard')));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(result, isTrue);
      expect(await tester.runAsync(() => db.expensesForGroup('g1')), isEmpty);
      await closeTree(tester);
    });

    testWidgets('a retry elsewhere while the sheet is open takes Discard away', (tester) async {
      final db = await failedDb();
      addTearDown(db.close);
      await openSheet(tester, db);
      expect(inSheet(actionButton('Discard')), findsOneWidget);

      await tester.runAsync(() => db.retrySyncFailure('e1'));
      await tester.pumpAndSettle();

      expect(inSheet(actionButton('Discard')), findsNothing);
      expect(inSheet(find.text('Waiting to sync')), findsOneWidget);
      await closeTree(tester);
    });
  });

  group('Activity: an expense this device may not have cached', () {
    testWidgets('a cache hit shows the cached copy without asking the server', (tester) async {
      final db = await cachedDb();
      addTearDown(db.close);
      var fetches = 0;
      await openSheet(tester, db, fetchIfMissing: true, client: serverClient((_) async {
        fetches++;
        return http.Response(expenseResponse(title: 'From server'), 200);
      }));

      expect(inSheet(find.text('Dinner')), findsOneWidget);
      expect(fetches, 0);
      await closeTree(tester);
    });

    testWidgets('a cache miss loads it from the server', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await openSheet(tester, db,
          fetchIfMissing: true,
          client: serverClient((_) async => http.Response(expenseResponse(), 200)));

      expect(inSheet(find.text('Dinner')), findsOneWidget);
      expect(inSheet(actionButton('Edit')), findsOneWidget);
      await closeTree(tester);
    });

    testWidgets('deleted on the server: "no longer available"', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await openSheet(tester, db,
          fetchIfMissing: true,
          client: serverClient((_) async => http.Response(notFound, 404)));

      expect(inSheet(find.text('This expense is no longer available.')), findsOneWidget);
      expect(inSheet(actionButton('Retry')), findsNothing);
      await closeTree(tester);
    });

    testWidgets('offline with nothing cached says details need a connection', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await openSheet(tester, db, fetchIfMissing: true, connectivity: Stream.value(false));

      expect(inSheet(find.text('Opening this expense needs a connection.')), findsOneWidget);
      await closeTree(tester);
    });

    testWidgets('a failed load can be retried', (tester) async {
      expectUnexpectedError<SpliitApiException>('Loading expense e1');
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      var fail = true;
      await openSheet(tester, db,
          fetchIfMissing: true,
          client: serverClient((_) async =>
              fail ? http.Response('server error', 500) : http.Response(expenseResponse(), 200)));

      expect(inSheet(find.text("Couldn't load this expense.")), findsOneWidget);
      fail = false;
      await tester.tap(inSheet(find.text('Retry')));
      await tester.pumpAndSettle();
      expect(inSheet(find.text('Dinner')), findsOneWidget);
      await closeTree(tester);
    });
  });

  testWidgets('without a server fallback, a missing expense reads "no longer available"',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await openSheet(tester, db);

    expect(inSheet(find.text('This expense is no longer available.')), findsOneWidget);
    await closeTree(tester);
  });

  // Every split mode: its label sits beside "Paid for" in the section's
  // caption, and "Pourcentage" is the longest (#183 review).
  for (final (locale, splitMode) in [
    for (final locale in const [Locale('en'), Locale('fr'), Locale('zh')])
      for (final splitMode in SplitMode.values) (locale, splitMode),
  ]) {
    testWidgets('fits a narrow phone at double text size ($locale, ${splitMode.name})',
        (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.replaceServerExpenses(
          'g1', [dinner(title: 'A long expense title that wraps', splitMode: splitMode)]);
      await openSheet(tester, db,
          locale: locale,
          activeUserId: 'bea',
          connectivity: Stream.value(false),
          builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ));

      // Drag the sheet open fully, then scroll its list to the notes, its
      // last part: the list is lazy, so the Paid for section on the way
      // isn't laid out until it's scrolled to.
      await tester.drag(find.byType(BottomSheet), const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
          find.text('Birthday dinner'), find.byType(BottomSheet), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(find.text('Birthday dinner'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await closeTree(tester);
    });
  }

  // #247: paid for one person, the sentence names them in place of the
  // Paid for list.
  group('one person paid for', () {
    Expense paid({required String by, required List<String> forIds, bool settlement = false}) => Expense(
          id: 'e1',
          groupId: 'g1',
          title: 'Coffee',
          amountCents: 1000,
          paidBy: by,
          paidFor: [for (final id in forIds) ExpenseShare(participantId: id, shares: 1)],
          isSettlement: settlement,
          category: 8,
          date: DateTime(2026, 9, 16),
        );
    String sentence(WidgetTester tester) =>
        tester.widget<Text>(inSheet(find.textContaining('Paid by'))).textSpan!.toPlainText();

    for (final (name, expense, me, start) in [
      ('an expense for someone', paid(by: 'alex', forIds: ['bea']), null,
          'Paid by Alex for Bea on Sep 16 under Dining Out'),
      ('an expense for you', paid(by: 'alex', forIds: ['bea']), 'bea',
          'Paid by Alex for you on Sep 16 under Dining Out. You owe'),
      ('an expense for yourself', paid(by: 'bea', forIds: ['bea']), 'bea',
          'Paid by you for yourself on Sep 16 under Dining Out'),
      ('an expense for themselves', paid(by: 'alex', forIds: ['alex']), 'bea',
          "Paid by Alex for themselves on Sep 16 under Dining Out. You aren't involved."),
      ('a settlement to someone', paid(by: 'alex', forIds: ['bea'], settlement: true), null,
          'Paid by Alex to Bea on Sep 16 for settlement'),
      ('a settlement to you', paid(by: 'alex', forIds: ['bea'], settlement: true), 'bea',
          'Paid by Alex to you on Sep 16 for settlement. You received'),
    ]) {
      testWidgets('$name: named in the sentence, no Paid for list', (tester) async {
        tallView(tester);
        final db = await cachedDb(expense);
        addTearDown(db.close);
        await openSheet(tester, db, activeUserId: me);
        expect(sentence(tester), startsWith(start));
        expect(inSheet(find.text('Paid for')), findsNothing);
        await closeTree(tester);
      });
    }

    testWidgets('paid for two: the list, and the sentence names no one', (tester) async {
      tallView(tester);
      final db = await cachedDb(paid(by: 'alex', forIds: ['alex', 'bea'], settlement: true));
      addTearDown(db.close);
      await openSheet(tester, db);
      expect(sentence(tester), 'Paid by Alex on Sep 16 for settlement');
      expect(inSheet(find.text('Paid for')), findsOneWidget);
      await closeTree(tester);
    });

    for (final locale in const [Locale('en'), Locale('fr'), Locale('zh')]) {
      testWidgets('fits a narrow phone at double text size ($locale)', (tester) async {
        tester.view.physicalSize = const Size(360, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final db = await cachedDb(paid(by: 'alex', forIds: ['bea'], settlement: true));
        addTearDown(db.close);
        await openSheet(tester, db,
            locale: locale,
            activeUserId: 'bea',
            builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ));
        expect(tester.takeException(), isNull);
        await closeTree(tester);
      });
    }

    for (final (locale, expected) in const [
      (Locale('fr'), 'Payé par Alex pour Bea le 16 sept. dans '),
      (Locale('zh'), '由Alex于9月16日为Bea支付，类别为'),
    ]) {
      testWidgets('in $locale', (tester) async {
        tallView(tester);
        final db = await cachedDb(paid(by: 'alex', forIds: ['bea']));
        addTearDown(db.close);
        await openSheet(tester, db, locale: locale);
        expect(tester.widget<Text>(inSheet(find.textContaining(expected))), isNotNull);
        await closeTree(tester);
      });
    }
  });

  group('Delete (#90 part 2)', () {
    const ok = '[{"result":{"data":{"json":{}}}}]';
    // AlertDialog.adaptive builds a subclass, which byType wouldn't match.
    Finder inDialog(Finder f) =>
        find.descendant(of: find.byWidgetPredicate((w) => w is AlertDialog), matching: f);

    Future<void> tapDelete(WidgetTester tester) async {
      await tester.tap(inSheet(actionButton('Delete')));
      await tester.pumpAndSettle();
    }

    testWidgets('asks first; Cancel changes nothing', (tester) async {
      final db = await cachedDb();
      addTearDown(db.close);
      var calls = 0;
      await openSheet(tester, db, client: serverClient((_) async {
        calls++;
        return http.Response(ok, 200);
      }));

      await tapDelete(tester);
      expect(inDialog(find.text('Delete this expense?')), findsOneWidget);
      expect(
          inDialog(find.text('"Dinner" will be deleted for everyone in the group. '
              "This can't be undone.")),
          findsOneWidget);
      await tester.tap(inDialog(find.text('Cancel')));
      await tester.pumpAndSettle();

      expect(calls, 0);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(await tester.runAsync(() => db.expensesForGroup('g1')), hasLength(1));
      await closeTree(tester);
    });

    testWidgets('confirmed: deletes on the server, credited to the active user, then locally',
        (tester) async {
      final db = await cachedDb();
      addTearDown(db.close);
      await db.cacheGroup(banff);
      await db.setActiveParticipant('g1', 'bea');
      http.Request? deleteRequest;
      await openSheet(tester, db, client: serverClient((req) async {
        if (req.url.toString().contains('groups.expenses.delete')) deleteRequest = req;
        return http.Response(ok, 200);
      }));

      final haptics = recordHaptics(tester);
      await tapDelete(tester);
      await tester.tap(inDialog(find.text('Delete')));
      await tester.pumpAndSettle();

      expect(haptics, ['HapticFeedbackType.lightImpact']); // #179
      final sent = (jsonDecode(deleteRequest!.body) as Map<String, dynamic>)['0']['json'];
      expect(sent, {'groupId': 'g1', 'expenseId': 'e1', 'participantId': 'bea'});
      expect(find.byType(BottomSheet), findsNothing);
      expect(result, isTrue);
      expect(await tester.runAsync(() => db.expensesForGroup('g1')), isEmpty);
      // A refresh already in flight can't bring it back.
      expect(db.expensesGeneration('g1'), 1);
      await closeTree(tester);
    });

    testWidgets('while it runs, nothing else can be tapped', (tester) async {
      final db = await cachedDb();
      addTearDown(db.close);
      final response = Completer<http.Response>();
      await openSheet(tester, db, client: serverClient((_) => response.future));

      await tapDelete(tester);
      await tester.tap(inDialog(find.text('Delete')));
      await tester.pump();
      await tester.pump();

      expect(
          tester.widget<IconButton>(inSheet(actionButton('Edit'))).onPressed,
          isNull);
      expect(
          tester.widget<IconButton>(inSheet(actionButton('Delete')))
              .onPressed,
          isNull);
      expect(inSheet(find.byType(CircularProgressIndicator)), findsOneWidget);

      response.complete(http.Response(ok, 200));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      await closeTree(tester);
    });

    testWidgets('a failure keeps the expense and says so in the sheet', (tester) async {
      expectUnexpectedError<SpliitApiException>('Deleting expense e1');
      final db = await cachedDb();
      addTearDown(db.close);
      await openSheet(tester, db, client: serverClient((req) async {
        if (req.url.toString().contains('groups.expenses.delete')) {
          return http.Response('server error', 500);
        }
        return http.Response(expenseResponse(), 200); // still there
      }));

      await tapDelete(tester);
      await tester.tap(inDialog(find.text('Delete')));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      // A server error is unexpected (#119 review): its own message, with
      // details, rather than "check your connection".
      expect(inSheet(find.text("Couldn't delete this expense.")), findsOneWidget);
      expect(inSheet(find.text('Tap for details')), findsOneWidget);
      expect(await tester.runAsync(() => db.expensesForGroup('g1')), hasLength(1));
      expect(db.expensesGeneration('g1'), 0);
      expect(
          tester.widget<IconButton>(inSheet(actionButton('Delete')))
              .onPressed,
          isNotNull);
      await closeTree(tester);
    });

    testWidgets('offline: the expense stays, "check your connection", no details (#119)',
        (tester) async {
      final db = await cachedDb();
      addTearDown(db.close);
      var fetches = 0;
      await openSheet(tester, db, client: serverClient((req) async {
        if (req.url.toString().contains('groups.expenses.get')) fetches++;
        throw http.ClientException('Failed host lookup');
      }));

      await tapDelete(tester);
      await tester.tap(inDialog(find.text('Delete')));
      await tester.pumpAndSettle();

      expect(fetches, 1); // still double-checked, as before
      expect(inSheet(find.text("Couldn't delete this expense. Check your connection and try again.")),
          findsOneWidget);
      expect(inSheet(find.text('Tap for details')), findsNothing);
      expect(await tester.runAsync(() => db.expensesForGroup('g1')), hasLength(1));
      await closeTree(tester);
    });

    // Upstream errors when deleting an expense that's already gone (a
    // retry after a lost response), so "not found" afterwards means done.
    testWidgets('a failure for an expense that is already gone counts as deleted',
        (tester) async {
      final db = await cachedDb();
      addTearDown(db.close);
      await openSheet(tester, db, client: serverClient((req) async {
        if (req.url.toString().contains('groups.expenses.delete')) {
          return http.Response('internal error', 500);
        }
        return http.Response(notFound, 404);
      }));

      await tapDelete(tester);
      await tester.tap(inDialog(find.text('Delete')));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(result, isTrue);
      expect(await tester.runAsync(() => db.expensesForGroup('g1')), isEmpty);
      await closeTree(tester);
    });

    testWidgets('an expense opened from Activity, not cached, can be deleted', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await openSheet(tester, db, fetchIfMissing: true, client: serverClient((req) async {
        if (req.url.toString().contains('groups.expenses.delete')) return http.Response(ok, 200);
        return http.Response(expenseResponse(), 200);
      }));

      await tapDelete(tester);
      await tester.tap(inDialog(find.text('Delete')));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(result, isTrue);
      await closeTree(tester);
    });

    testWidgets('dismissed while deleting: the local copy still goes once the server confirms',
        (tester) async {
      final db = await cachedDb();
      addTearDown(db.close);
      final response = Completer<http.Response>();
      await openSheet(tester, db, client: serverClient((_) => response.future));

      await tapDelete(tester);
      await tester.tap(inDialog(find.text('Delete')));
      await tester.pump();
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);

      response.complete(http.Response(ok, 200));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(() => db.expensesForGroup('g1')), isEmpty);
      await closeTree(tester);
    });
  });

  // PR #95 left this: drift re-emits on every write to the table, and the
  // sheet refetched an uncached expense each time.
  testWidgets('an expense loaded from the server isn\'t refetched on unrelated writes',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    var fetches = 0;
    await openSheet(tester, db, fetchIfMissing: true, client: serverClient((_) async {
      fetches++;
      return http.Response(expenseResponse(), 200);
    }));
    expect(fetches, 1);

    // One unrelated write. (A second write in the same runAsync would
    // deadlock: the first one's stream refresh runs in the test's fake
    // zone and holds drift's lock until the test pumps.)
    await tester.runAsync(() async {
      await db.insertPending(Expense(
          id: 'other',
          groupId: 'g1',
          title: 'Other',
          amountCents: 100,
          paidBy: 'alex',
          paidFor: const [],
          date: DateTime(2026, 9, 16),
          pending: true));
    });
    await tester.pumpAndSettle();

    expect(fetches, 1);
    expect(inSheet(find.text('Dinner')), findsOneWidget);
    await closeTree(tester);
  });

  // PR #95 review (Ezra): dismissing the sheet (barrier, swipe, Back) pops
  // it without the sheet's own close path. A late Edit fetch or row change
  // landing during its closing animation must not pop a second route --
  // in the app, that's GroupScreen itself.
  group('a late callback after the sheet is dismissed', () {
    Future<(_PopCounter, AppDatabase)> openFromCaller(
        WidgetTester tester, SpliitClient client) async {
      final pops = _PopCounter();
      final db = await cachedDb();
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        navigatorObservers: [pops],
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showExpenseDetails(
                      context,
                      expenseId: 'e1',
                      group: banff,
                      db: db,
                      client: client,
                      outbox: Outbox(db, client, groupId: 'g1'),
                      connectivity: const Stream.empty(),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            )),
            child: const Text('caller'),
          ),
        ),
      ));
      await tester.tap(find.text('caller'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      pops.count = 0;
      return (pops, db);
    }

    testWidgets('an Edit fetch completing mid-dismissal pops nothing more', (tester) async {
      final response = Completer<http.Response>();
      final (pops, db) = await openFromCaller(tester, serverClient((_) => response.future));
      addTearDown(db.close);

      await tester.tap(inSheet(actionButton('Edit')));
      await tester.pump();
      await tester.tapAt(const Offset(20, 20)); // the modal barrier
      await tester.pump(const Duration(milliseconds: 10));
      response.complete(http.Response(expenseResponse(), 200));
      await tester.pumpAndSettle();

      expect(pops.count, 1);
      expect(find.text('open'), findsOneWidget); // the caller is still there
      expect(find.text('Edit expense'), findsNothing);
      await closeTree(tester);
    });

    // PR #96 review (Ezra): the Delete confirmation covers the sheet
    // without dismissing it. If the expense goes away meanwhile, the sheet
    // must close once the confirmation ends -- not pop the dialog, not
    // stay stuck showing a deleted expense, and not send the delete.
    Finder inDialog(Finder f) =>
        find.descendant(of: find.byWidgetPredicate((w) => w is AlertDialog), matching: f);

    Future<(_PopCounter, AppDatabase, List<String>)> confirmWhileItGoes(
        WidgetTester tester) async {
      final deletes = <String>[];
      final (pops, db) = await openFromCaller(tester, serverClient((req) async {
        if (req.url.toString().contains('groups.expenses.delete')) deletes.add(req.body);
        return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
      }));
      await tester.tap(inSheet(actionButton('Delete')));
      await tester.pumpAndSettle();
      expect(inDialog(find.text('Delete this expense?')), findsOneWidget);

      await tester.runAsync(() => db.replaceServerExpenses('g1', [])); // a refresh
      await tester.pumpAndSettle();
      // Still confirming: the dialog is untouched.
      expect(inDialog(find.text('Delete this expense?')), findsOneWidget);
      return (pops, db, deletes);
    }

    testWidgets('the expense going away during confirmation, then Cancel: the sheet closes',
        (tester) async {
      final (pops, db, deletes) = await confirmWhileItGoes(tester);
      addTearDown(db.close);

      await tester.tap(inDialog(find.text('Cancel')));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('open'), findsOneWidget); // the caller is still there
      expect(pops.count, 2); // the dialog, then the sheet
      expect(deletes, isEmpty);
      await closeTree(tester);
    });

    testWidgets('the expense going away during confirmation, then Delete: nothing is sent, '
        'the sheet closes', (tester) async {
      final (pops, db, deletes) = await confirmWhileItGoes(tester);
      addTearDown(db.close);

      await tester.tap(inDialog(find.text('Delete')));
      await tester.pumpAndSettle();

      expect(deletes, isEmpty);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(pops.count, 2);
      await closeTree(tester);
    });

    testWidgets('the expense coming back before Cancel keeps the sheet open', (tester) async {
      final (pops, db, deletes) = await confirmWhileItGoes(tester);
      addTearDown(db.close);

      await tester.runAsync(() => db.replaceServerExpenses('g1', [dinner()]));
      await tester.pumpAndSettle();
      await tester.tap(inDialog(find.text('Cancel')));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(inSheet(find.text('Dinner')), findsOneWidget);
      expect(pops.count, 1); // just the dialog
      expect(deletes, isEmpty);
      await closeTree(tester);
    });

    testWidgets('the expense disappearing mid-dismissal pops nothing more', (tester) async {
      final (pops, db) = await openFromCaller(tester, offlineClient);
      addTearDown(db.close);

      await tester.tapAt(const Offset(20, 20));
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(() => db.replaceServerExpenses('g1', []));
      await tester.pumpAndSettle();

      expect(pops.count, 1);
      expect(find.text('open'), findsOneWidget);
      await closeTree(tester);
    });
  });
}

class _PopCounter extends NavigatorObserver {
  int count = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => count++;
}
