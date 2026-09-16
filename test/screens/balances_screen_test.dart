import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
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
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient(
        (req) async => http.Response('[{"result":{"data":{"json":{}}}}]', 200),
      ),
    );
    final outbox = Outbox(db, client);

    await tester.pumpWidget(MaterialApp(
      home: BalancesScreen(client: client, db: db, outbox: outbox, group: group),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Mark as paid').first);
    await tester.pumpAndSettle();

    // Bea<->Alex is now settled (synced and removed from the pending
    // outbox), so only Cid should still owe Alex.
    expect(find.text('Bea owes Alex'), findsNothing);
    expect(find.text('Cid owes Alex'), findsOneWidget);
  });
}
