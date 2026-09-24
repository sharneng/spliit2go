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

  test('flush() syncs a pending expense and clears its pending flag', () async {
    await db.insertPending(pendingExpense('local-1'));

    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient(
        (req) async => http.Response('[{"result":{"data":{"json":{}}}}]', 200),
      ),
    );
    final outbox = Outbox(db, client, groupId: 'g1');

    final synced = await outbox.flush();

    expect(synced, 1);
    expect(await db.pendingExpenses(), isEmpty);
  });

  // Issue #43: the pending row used to be deleted outright the moment
  // createExpense() succeeded, relying on the caller's own follow-up
  // fetchExpenses() to bring it back as a normal synced row -- so a
  // network drop between those two calls left a genuinely-synced
  // expense absent from the local cache (and so missing from the list
  // and balance math) until whatever refresh *next* happened to
  // succeed. It should instead be updated in place and never actually
  // disappear.
  test('flush() updates a synced row to the server-assigned id in place, never deleting it',
      () async {
    await db.insertPending(pendingExpense('local-1'));

    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient(
        (req) async =>
            http.Response('[{"result":{"data":{"json":{"expenseId":"server-1"}}}}]', 200),
      ),
    );
    final outbox = Outbox(db, client, groupId: 'g1');

    final synced = await outbox.flush();

    expect(synced, 1);
    // Not gone -- present under its new, server-assigned id, and no
    // longer pending.
    final rows = await db.expensesForGroup('g1');
    expect(rows, hasLength(1));
    expect(rows.single.id, 'server-1');
    expect(rows.single.pending, isFalse);
  });

  // The server's create response doesn't always carry a parseable
  // expenseId (see SpliitClient.createExpense's own doc comment) --
  // markSynced falls back to keeping the row under its original local
  // id in that case, same outcome a normal successful refresh would
  // eventually produce, just without ever going missing in between.
  test('flush() keeps the local id when the server response has no expenseId, but still '
      'clears pending', () async {
    await db.insertPending(pendingExpense('local-1'));

    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient(
        (req) async => http.Response('[{"result":{"data":{"json":{}}}}]', 200),
      ),
    );
    final outbox = Outbox(db, client, groupId: 'g1');

    final synced = await outbox.flush();

    expect(synced, 1);
    final rows = await db.expensesForGroup('g1');
    expect(rows, hasLength(1));
    expect(rows.single.id, 'local-1');
    expect(rows.single.pending, isFalse);
  });

  test('flush() leaves a row pending when the server call fails', () async {
    await db.insertPending(pendingExpense('local-1'));

    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => http.Response('server error', 500)),
    );
    final outbox = Outbox(db, client, groupId: 'g1');

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
    final outbox = Outbox(db, client, groupId: 'g1');

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
    final outbox = Outbox(db, client, groupId: 'g1');

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

  // Issue #42 (constructor-bound groupId per issue #52): flush() must
  // not replay another group's pending rows against this group's client
  // -- each Outbox is constructed per-group, fixed to that one group's
  // own server (see decisions/multi-group-design.md), so a pending row
  // from a group on a different server would otherwise get POSTed to
  // the wrong server entirely.
  test("flush() only syncs its own group's pending rows, leaving others' untouched",
      () async {
    await db.insertPending(pendingExpense('g1-local'));
    await db.insertPending(Expense(
      id: 'g2-local',
      groupId: 'g2',
      title: 'Souvenir',
      amountCents: 1200,
      paidBy: 'p2',
      paidFor: const [ExpenseShare(participantId: 'p2', shares: 1)],
      date: DateTime.utc(2026, 9, 16),
      pending: true,
    ));

    http.Request? captured;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        captured = req;
        return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
      }),
    );
    final outbox = Outbox(db, client, groupId: 'g1');

    final synced = await outbox.flush();

    expect(synced, 1);
    // Only g1's row was ever sent to this (g1-scoped) client.
    expect(captured, isNotNull);
    final sent = jsonDecode(captured!.body) as Map<String, dynamic>;
    expect((sent['0'] as Map<String, dynamic>)['json']['groupId'], 'g1');
    // g2's row is untouched -- still pending, never replayed here.
    final stillPending = await db.pendingExpenses();
    expect(stillPending, hasLength(1));
    expect(stillPending.single.id, 'g2-local');
  });

  group('retry limit and failure state (issue #44)', () {
    test('flush() marks a row syncFailed immediately on a 4xx response, without waiting for '
        'maxRetries', () async {
      await db.insertPending(pendingExpense('local-1'));

      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response('bad request', 400)),
      );
      final outbox = Outbox(db, client, groupId: 'g1');

      final synced = await outbox.flush();

      expect(synced, 0);
      final rows = await db.expensesForGroup('g1');
      expect(rows.single.pending, isTrue); // still hasn't synced
      expect(rows.single.syncFailed, isTrue); // but given up retrying it automatically
      expect(rows.single.retryCount, 1);
      expect(rows.single.lastError, contains('400'));
    });

    test('flush() leaves a row pending and retriable after a single non-4xx failure', () async {
      await db.insertPending(pendingExpense('local-1'));

      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response('server error', 500)),
      );
      final outbox = Outbox(db, client, groupId: 'g1');

      await outbox.flush();

      final rows = await db.expensesForGroup('g1');
      expect(rows.single.syncFailed, isFalse);
      expect(rows.single.retryCount, 1);
      // Still picked up by the next flush -- not excluded like a
      // syncFailed row would be.
      expect(await db.pendingExpensesForGroup('g1'), hasLength(1));
    });

    test('flush() marks a row syncFailed once it hits maxRetries non-4xx failures', () async {
      await db.insertPending(pendingExpense('local-1'));

      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response('server error', 500)),
      );
      final outbox = Outbox(db, client, groupId: 'g1');

      for (var i = 0; i < Outbox.maxRetries; i++) {
        await outbox.flush();
      }

      final rows = await db.expensesForGroup('g1');
      expect(rows.single.retryCount, Outbox.maxRetries);
      expect(rows.single.syncFailed, isTrue);
      // No longer offered to the next flush automatically.
      expect(await db.pendingExpensesForGroup('g1'), isEmpty);
    });

    test("flush() doesn't retry a syncFailed row automatically, even if the server would now "
        'accept it', () async {
      await db.insertPending(pendingExpense('local-1'));
      await db.recordSyncFailure(
        id: 'local-1',
        error: 'bad request',
        retryCount: 1,
        failed: true,
      );

      var requested = false;
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          requested = true;
          return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
        }),
      );
      final outbox = Outbox(db, client, groupId: 'g1');

      final synced = await outbox.flush();

      expect(synced, 0);
      expect(requested, isFalse);
      final rows = await db.expensesForGroup('g1');
      expect(rows.single.syncFailed, isTrue);
    });

    test('retrySyncFailure re-queues a failed row so the next flush picks it up', () async {
      await db.insertPending(pendingExpense('local-1'));
      await db.recordSyncFailure(
        id: 'local-1',
        error: 'bad request',
        retryCount: 1,
        failed: true,
      );

      await db.retrySyncFailure('local-1');

      final row = (await db.expensesForGroup('g1')).single;
      expect(row.syncFailed, isFalse);
      expect(row.retryCount, 0);

      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient(
          (req) async => http.Response('[{"result":{"data":{"json":{}}}}]', 200),
        ),
      );
      final outbox = Outbox(db, client, groupId: 'g1');
      final synced = await outbox.flush();

      expect(synced, 1);
    });

    test('deleteFailedExpense removes a failed row outright', () async {
      await db.insertPending(pendingExpense('local-1'));
      await db.recordSyncFailure(
        id: 'local-1',
        error: 'bad request',
        retryCount: 1,
        failed: true,
      );

      await db.deleteFailedExpense('local-1');

      expect(await db.expensesForGroup('g1'), isEmpty);
    });
  });

  // Issue #92: a queued expense is credited to whoever was the active
  // user when it was added, not whoever is active when it finally syncs.
  group('activity attribution', () {
    Future<Map<String, dynamic>> flushAndCapture() async {
      http.Request? captured;
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
        }),
      );
      await Outbox(db, client, groupId: 'g1').flush();
      return (jsonDecode(captured!.body) as Map<String, dynamic>)['0']['json']
          as Map<String, dynamic>;
    }

    test('flush() credits the participant captured when the expense was added',
        () async {
      await db.insertPending(pendingExpense('local-1'), addedByParticipantId: 'p2');
      expect((await flushAndCapture())['participantId'], 'p2');
    });

    test('flush() sends None for a row with nobody captured', () async {
      await db.insertPending(pendingExpense('local-1'));
      expect((await flushAndCapture())['participantId'], 'None');
    });
  });
}
