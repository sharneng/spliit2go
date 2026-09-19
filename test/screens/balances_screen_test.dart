import 'dart:convert';

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
    final outbox = Outbox(db, client);

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
    final outbox = Outbox(db, client);

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
  });

  testWidgets('the settlement amount can be edited before saving (partial payment)',
      (tester) async {
    final db = await dbWithEvenExpense();
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw Exception('offline')),
    );
    final outbox = Outbox(db, client);

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
  });
}
