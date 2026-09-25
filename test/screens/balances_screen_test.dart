import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/main.dart' show spliit2goAppBuilder;
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/balances_screen.dart';
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

  Future<AppDatabase> dbWithEvenExpense() async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.replaceServerExpenses('g1', [
      Expense(
        id: 'e1',
        groupId: 'g1',
        title: 'Groceries',
        amountCents: 9000,
        paidBy: 'alex',
        paidFor: const [
          ExpenseShare(participantId: 'alex', shares: 1),
          ExpenseShare(participantId: 'bea', shares: 1),
          ExpenseShare(participantId: 'cid', shares: 1),
        ],
        date: DateTime.utc(2026, 9, 16),
      ),
    ]);
    return db;
  }

  testWidgets('shows each participant\'s balance and a suggested settlement', (tester) async {
    final db = await dbWithEvenExpense();
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => http.Response('offline', 500)),
    );
    final outbox = Outbox(db, client, groupId: 'g1');

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BalancesScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Alex'), findsOneWidget);
    expect(find.text('\$60.00'), findsOneWidget);
    expect(find.text('Bea owes Alex'), findsOneWidget);
    expect(find.text('Cid owes Alex'), findsOneWidget);
    expect(find.textContaining('Mark as paid'), findsNWidgets(2));
    // Drift's watch() stream (issue #47) schedules an internal
    // debounce/reconnect Timer when a subscriber cancels, which
    // happens when this widget is disposed. flutter_test's automatic
    // end-of-test teardown doesn't give that Timer a chance to fire
    // before its "no pending timers" invariant check, so we force
    // disposal ourselves here and pump once more to drain it.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('marking a settlement as paid clears it once synced', (tester) async {
    final db = await dbWithEvenExpense();
    addTearDown(db.close);
    // Outbox.flush() deletes a synced pending row outright and expects
    // the caller to re-fetch afterward to bring it back as confirmed --
    // see the comment in balances_screen.dart's _markAsPaid. So this
    // mock has to behave like a real server would after the settlement:
    // the create succeeds, and the *next* expenses.list already
    // includes it (the original groceries expense plus Bea's payment
    // to Alex), or the balance math would have nothing to recompute
    // from and the test would just be asserting a no-op.
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        if (req.url.toString().contains('groups.expenses.list')) {
          return http.Response(
            jsonEncode([
              {
                'result': {
                  'data': {
                    'json': {
                      'expenses': [
                        {
                          'id': 'e1',
                          'title': 'Groceries',
                          'amount': 9000,
                          'paidBy': 'alex',
                          'paidFor': [
                            {'participant': 'alex', 'shares': 1},
                            {'participant': 'bea', 'shares': 1},
                            {'participant': 'cid', 'shares': 1},
                          ],
                          'expenseDate': '2026-09-16T00:00:00.000Z',
                        },
                        {
                          'id': 'settle-1',
                          'title': 'Reimbursement',
                          'amount': 3000,
                          'paidBy': 'bea',
                          'paidFor': [
                            {'participant': 'alex', 'shares': 1},
                          ],
                          'isReimbursement': true,
                          'expenseDate': '2026-09-16T00:00:00.000Z',
                        },
                      ],
                      'hasMore': false,
                    },
                  },
                },
              },
            ]),
            200,
          );
        }
        // groups.expenses.create
        return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
      }),
    );
    final outbox = Outbox(db, client, groupId: 'g1');

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BalancesScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    // "Mark as paid" opens ExpenseScreen pre-filled with the
    // settlement (issue #22) rather than recording it directly.
    await tester.tap(find.textContaining('Mark as paid').first);
    await tester.pumpAndSettle();

    expect(find.text('Add expense'), findsOneWidget);
    expect(find.text('Bea paid Alex'), findsOneWidget);
    expect(find.text('30.00'), findsOneWidget);
    final reimbursementTile = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, 'This is a reimbursement'));
    expect(reimbursementTile.value, isTrue);

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    // Back on the balances screen -- Bea<->Alex is now settled (synced
    // and removed from the pending outbox), so only Cid should still owe
    // Alex.
    expect(find.text('Bea owes Alex'), findsNothing);
    expect(find.text('Cid owes Alex'), findsOneWidget);
    // See the first test above for why. (issue #47)
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('the settlement amount can be edited before saving (partial payment)',
      (tester) async {
    final db = await dbWithEvenExpense();
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw Exception('offline')),
    );
    final outbox = Outbox(db, client, groupId: 'g1');

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BalancesScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Mark as paid').first);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, '30.00'), '10.00');
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    // A partial $10 payment leaves $20 of the original $30 still owed --
    // Bea should still show up as owing Alex, just a smaller amount.
    expect(find.textContaining('owes Alex'), findsWidgets);
    // See the first test above for why. (issue #47)
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  // Issue #99: a "You" section above everyone's balances, like spliit-ios.
  // (No group() wrapper: the `group` fixture above hides it.)
  const hint = 'Pick yourself once and this group is read from where you '
      'stand: your own balance first, and your name already filled in on a new expense.';

  Future<void> pumpBalances(WidgetTester tester, AppDatabase db,
      {String? activeUserId, VoidCallback? onPickActiveUser}) async {
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => http.Response('offline', 500)),
    );
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BalancesScreen(
        client: client,
        db: db,
        outbox: Outbox(db, client, groupId: 'g1'),
        group: group,
        activeUserId: activeUserId,
        onPickActiveUser: onPickActiveUser,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Text amountText(WidgetTester tester, String amount) => tester
      .widgetList<Text>(find.text(amount))
      .firstWhere((t) => t.style?.fontWeight == FontWeight.bold);

  testWidgets('with nobody picked: "You · Nobody" and why to pick, no amount',
      (tester) async {
    final db = await dbWithEvenExpense();
    addTearDown(db.close);
    await pumpBalances(tester, db);

    expect(find.widgetWithText(ListTile, 'You'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Nobody'), findsOneWidget);
    expect(find.text(hint), findsOneWidget);
    expect(find.text('You are owed'), findsNothing);
    expect(find.text('You owe'), findsNothing);
    expect(find.textContaining('(you)'), findsNothing);
    await teardown(tester);
  });

  testWidgets('owed: says so, the amount unsigned in green, and marks your row',
      (tester) async {
    final db = await dbWithEvenExpense();
    addTearDown(db.close);
    await pumpBalances(tester, db, activeUserId: 'alex');

    expect(find.text('You are owed'), findsOneWidget);
    // Alex's own row shows $60.00 too; the You amount is the bold headline.
    expect(amountText(tester, '\$60.00').style!.color, Colors.green.shade700);
    expect(find.widgetWithText(ListTile, 'Alex'), findsOneWidget); // the You row
    expect(find.text('Alex (you)'), findsOneWidget);
    expect(find.text(hint), findsNothing);
    await teardown(tester);
  });

  testWidgets('owing: says so, the amount unsigned in the error color', (tester) async {
    final db = await dbWithEvenExpense();
    addTearDown(db.close);
    await pumpBalances(tester, db, activeUserId: 'bea');

    expect(find.text('You owe'), findsOneWidget);
    // Bea's row says -$30.00; the You headline drops the sign.
    final headline = find.byWidgetPredicate((w) =>
        w is Text && w.data == '\$30.00' && w.style?.fontWeight == FontWeight.bold);
    expect(headline, findsOneWidget);
    expect(tester.widget<Text>(headline).style!.color,
        Theme.of(tester.element(headline)).colorScheme.error);
    expect(find.text('Bea (you)'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('settled up when your balance is zero', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await pumpBalances(tester, db, activeUserId: 'cid');

    expect(find.text('You’re settled up'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('an active user no longer in the group reads as Nobody', (tester) async {
    final db = await dbWithEvenExpense();
    addTearDown(db.close);
    await pumpBalances(tester, db, activeUserId: 'gone');

    expect(find.widgetWithText(ListTile, 'Nobody'), findsOneWidget);
    expect(find.text(hint), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('tapping the You row opens the picker', (tester) async {
    final db = await dbWithEvenExpense();
    addTearDown(db.close);
    var picks = 0;
    await pumpBalances(tester, db, activeUserId: 'alex', onPickActiveUser: () => picks++);

    await tester.tap(find.widgetWithText(ListTile, 'You'));
    await tester.pump();

    expect(picks, 1);
    await teardown(tester);
  });

  // #101 review: a long name at large text on a narrow phone took the
  // whole You row ("Trailing widget consumes the entire tile width").
  for (final (label, locale) in [('English', const Locale('en')), ('French', const Locale('fr'))]) {
    testWidgets('$label: a long name at double text size on a narrow phone keeps the You row readable (#101 review)',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      const longName = 'Alexandra Catherine Montgomery';
      const longGroup = Group(
        id: 'g1',
        name: 'Banff Trip',
        currency: '\$',
        participants: [Participant(id: 'alex', name: longName)],
      );
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response('offline', 500)),
      );
      var picks = 0;
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: spliit2goAppBuilder,
        home: BalancesScreen(
          client: client,
          db: db,
          outbox: Outbox(db, client, groupId: 'g1'),
          group: longGroup,
          activeUserId: 'alex',
          onPickActiveUser: () => picks++,
        ),
      ));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final you = locale.languageCode == 'fr' ? 'Vous' : 'You';
      final label = find.text(you);
      final name = find.text(longName);
      expect(label, findsOneWidget);
      expect(name, findsOneWidget);
      // Both get real room, side by side or stacked, inside the card.
      final card = tester.getRect(find.byType(Card));
      for (final f in [label, name]) {
        final r = tester.getRect(f);
        expect(r.width, greaterThan(40));
        expect(r.left, greaterThanOrEqualTo(card.left));
        expect(r.right, lessThanOrEqualTo(card.right));
      }
      expect(tester.getRect(label).overlaps(tester.getRect(name)), isFalse);

      await tester.tap(label);
      await tester.pump();
      expect(picks, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  }
}
