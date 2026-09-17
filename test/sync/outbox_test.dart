import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/sync/outbox.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Expense pendingExpense(String id) => Expense(
        id: id,
        groupId: 'g1',
        title: 'Coffee',
        amountCents: 500,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        date: DateTime.utc(2026, 9, 16),
        pending: true,
      );

  // Regression test for the whereSamePrimaryKey bug: the original delete
  // used a method that only exists on drift's update statements, not
  // delete statements, so this never even compiled, let alone actually
  // cleared a synced expense's pending flag.
  test('flush() syncs a pending expense and removes it from the local db', () async {
    await db.insertPending(pendingExpense('local-1'));

    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient(
        (req) async => http.Response('[{"result":{"data":{"json":{}}}}]', 200),
      ),
    );
    final outbox = Outbox(db, client);

    final synced = await outbox.flush();

    expect(synced, 1);
    expect(await db.pendingExpenses(), isEmpty);
  });

  test('flush() leaves a row pending when the server call fails', () async {
    await db.insertPending(pendingExpense('local-1'));

    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => http.Response('server error', 500)),
    );
    final outbox = Outbox(db, client);

    final synced = await outbox.flush();

    expect(synced, 0);
    expect(await db.pendingExpenses(), hasLength(1));
  });

  test('flush() syncs each pending row independently', () async {
    await db.insertPending(pendingExpense('ok-1'));
    await db.insertPending(pendingExpense('ok-2'));

    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient(
        (req) async => http.Response('[{"result":{"data":{"json":{}}}}]', 200),
      ),
    );
    final outbox = Outbox(db, client);

    final synced = await outbox.flush();

    expect(synced, 2);
    expect(await db.pendingExpenses(), isEmpty);
  });

  // Issue #16: the new Expense fields (recurrenceRule, originalAmountCents/
  // originalCurrency/conversionRate) must actually reach the server on
  // replay, not just round-trip through the local db -- a bug here would
  // silently drop them the moment an add happened offline.
  test('flush() passes recurrenceRule and original-currency fields through to createExpense',
      () async {
    final pending = Expense(
      id: 'local-1',
      groupId: 'g1',
      title: 'Hotel',
      amountCents: 10000,
      paidBy: 'p1',
      paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
      date: DateTime.utc(2026, 9, 16),
      recurrenceRule: RecurrenceRule.monthly,
      originalAmountCents: 9000,
      originalCurrency: 'EUR',
      conversionRate: 1.111,
      pending: true,
    );
    await db.insertPending(pending);

    http.Request? captured;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
      }),
    );
    final outbox = Outbox(db, client);

    await outbox.flush();

    expect(captured, isNotNull);
    final sent = jsonDecode(captured!.body) as Map<String, dynamic>;
    final formValues =
        (sent['0'] as Map<String, dynamic>)['json']['expenseFormValues'] as Map<String, dynamic>;
    expect(formValues['recurrenceRule'], 'MONTHLY');
    expect(formValues['originalAmount'], 9000);
    expect(formValues['originalCurrency'], 'EUR');
    expect(formValues['conversionRate'], 1.111);
  });
}
