import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/services/receipt_cache.dart';
import 'package:spliit2go/sync/outbox.dart';

import '../support/error_log.dart';

/// A Spliit instance and its bucket, with the document rules of
/// src/lib/api.ts (cc796210): create gives documents new ids; update
/// keeps the ids it's sent and drops the rest.
class _Spliit {
  final bucket = <String, List<int>>{};
  final expenses = <String, List<Map<String, Object?>>>{};
  final calls = <String>[];
  var _next = 0;

  /// Makes the named step fail: with `offline`, or an HTTP status.
  final failing = <String, Object>{};

  /// Applies the next update, then loses its response.
  bool loseUpdateResponse = false;

  /// Drops transfers from this one on (1-based), as a lost connection
  /// would, until cleared.
  int? dropPut;

  String _id(String prefix) => '$prefix-${++_next}';

  http.Response _json(Object body) => http.Response(jsonEncode(body), 200);
  http.Response _trpc(Object data) => _json([
        {
          'result': {
            'data': {'json': data},
          },
        },
      ]);

  late final client = SpliitClient(
    baseUrl: 'https://spliit.test',
    httpClient: MockClient((req) async {
      final step = switch (req.url.path) {
        '/api/s3-upload' => 'sign',
        final p when p.startsWith('/put/') => 'put',
        final p when p.startsWith('/b/') => 'head',
        final p when p.endsWith('groups.expenses.create') => 'create',
        final p when p.endsWith('groups.expenses.get') => 'get',
        final p when p.endsWith('groups.expenses.update') => 'update',
        final p => throw StateError('unexpected request $p'),
      };
      calls.add(step);
      switch (failing[step]) {
        case 'offline':
          throw http.ClientException('offline');
        case final int status:
          return http.Response('', status);
      }
      switch (step) {
        case 'sign':
          final key = 'document-${_id('k')}.jpg';
          return _json(
              {'key': key, 'bucket': 'b', 'endpoint': 'https://bucket.test', 'url': 'https://bucket.test/put/$key'});
        case 'put':
          if (dropPut != null && count('put') >= dropPut!) throw http.ClientException('dropped');
          bucket['https://bucket.test/b/${req.url.pathSegments.last}'] = req.bodyBytes;
          return http.Response('', 200);
        case 'head':
          return http.Response('', bucket.containsKey(req.url.toString()) ? 200 : 403);
        case 'create':
          final values = jsonDecode(req.body)['0']['json']['expenseFormValues'] as Map;
          final id = _id('server');
          expenses[id] = [
            for (final d in values['documents'] as List) {...(d as Map).cast<String, Object?>(), 'id': _id('srv-doc')},
          ];
          return _trpc({'expenseId': id});
        case 'get':
          final input = jsonDecode(req.url.queryParameters['input']!)['0']['json'] as Map;
          final docs = expenses[input['expenseId']];
          if (docs == null) return http.Response('{"error":{"json":{"message":"NOT_FOUND"}}}', 404);
          return _trpc({
            'expense': {
              'id': input['expenseId'],
              'title': 'Coffee',
              'amount': 500,
              'paidBy': {'id': 'p1'},
              'paidFor': [
                {'participantId': 'p1', 'shares': 1},
              ],
              'expenseDate': '2026-09-27T00:00:00.000Z',
              'documents': docs,
            },
          });
        default: // update
          final json = jsonDecode(req.body)['0']['json'] as Map;
          expenses[json['expenseId'] as String] = [
            for (final d in (json['expenseFormValues'] as Map)['documents'] as List) (d as Map).cast(),
          ];
          if (loseUpdateResponse) {
            loseUpdateResponse = false;
            throw http.ClientException('connection reset');
          }
          return _trpc({'expenseId': json['expenseId']});
      }
    }),
  );

  int count(String step) => calls.where((c) => c == step).length;
}

// Issue #124: receipt photos that aren't uploaded yet are kept on the
// device and reach their expense later; the expense never waits for them.
void main() {
  late AppDatabase db;
  late Directory dir;
  late ReceiptCache cache;
  late _Spliit spliit;
  var photos = 0;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dir = await Directory.systemTemp.createTemp('attachments-');
    cache = ReceiptCache(db, directory: () async => dir);
    ReceiptCache.use(cache);
    spliit = _Spliit();
    photos = 0;
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  /// A fresh outbox each time, as after an app restart: all state is in
  /// the database.
  Future<void> flush() => Outbox(db, spliit.client, groupId: 'g1').flush();

  Expense expense(String id, {List<ExpenseDocument> documents = const []}) => Expense(
        id: id,
        groupId: 'g1',
        title: 'Coffee',
        amountCents: 500,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        date: DateTime.utc(2026, 9, 27),
        pending: true,
        documents: documents,
        documentCount: documents.length,
      );

  /// Stores a photo for [expenseId], as the form or the sheet does.
  Future<String> attach(String expenseId,
      {AttachmentState state = AttachmentState.local, String? url}) async {
    final id = 'att-${++photos}';
    await cache.storePending(
        [List.filled(10, photos)],
        (fileNames) => db.addAttachments([
              ReceiptAttachmentsCompanion.insert(
                id: id,
                groupId: 'g1',
                expenseId: expenseId,
                fileName: fileNames.single,
                bytes: 10,
                width: 600,
                height: 900,
                state: state,
                url: Value(url),
                createdAt: DateTime(2026, 9, 27, 12, photos),
              ),
            ]));
    return id;
  }

  Future<List<ReceiptAttachmentRow>> attachments(String expenseId) =>
      db.watchAttachments(expenseId).first;

  Future<String> syncedId() async => (await db.expensesForGroup('g1')).single.id;

  test('a photo that uploads is created with its expense, and becomes a capture', () async {
    await db.insertPending(expense('local-1'));
    await attach('local-1');

    await flush();

    final id = await syncedId();
    expect(spliit.expenses[id], hasLength(1));
    expect(await attachments(id), isEmpty);
    final url = spliit.expenses[id]!.single['url'] as String;
    expect((await db.receiptFile(url))!.kind, ReceiptFileKind.capture);
    expect(await cache.cachedFile(url), isNotNull);
  });

  test('a transient upload failure: the expense syncs, the photo stays and uploads on reconnect',
      () async {
    await db.insertPending(expense('local-1'));
    final att = await attach('local-1');
    spliit.failing['sign'] = 'offline';

    await flush();

    final id = await syncedId();
    expect(spliit.expenses[id], isEmpty);
    final waiting = (await attachments(id)).single;
    expect((waiting.id, waiting.state), (att, AttachmentState.local));

    spliit.failing.clear();
    await flush();

    expect(spliit.expenses[id]!.single['id'], att);
    expect(await attachments(id), isEmpty);
    expect((await db.watchExpenseDocuments(id).first).single.id, att);
    expect((await db.expensesForGroup('g1')).single.documentCount, 1);
    expect(loggedUnexpectedErrors, isEmpty);
  });

  test('upload succeeds, then the create fails: the retry reuses the upload', () async {
    expectUnexpectedError<SpliitApiException>('Syncing expense local-1');
    await db.insertPending(expense('local-1'));
    await attach('local-1');
    spliit.failing['create'] = 500;

    await flush();
    expect((await attachments('local-1')).single.state, AttachmentState.uploaded);

    spliit.failing.clear();
    await flush();

    expect(spliit.count('put'), 1);
    expect(spliit.expenses[await syncedId()], hasLength(1));
  });

  test('several photos, partial success: the rest attach later, nothing twice, server ids kept',
      () async {
    await db.insertPending(expense('local-1'));
    await attach('local-1');
    final second = await attach('local-1');
    spliit.dropPut = 2; // the connection drops during the second transfer

    await flush();

    final id = await syncedId();
    // Created with the first; create gave it the server's own id.
    final first = spliit.expenses[id]!.single;
    expect(first['id'], startsWith('srv-doc'));
    expect((await attachments(id)).single.id, second);

    spliit.dropPut = null;
    await flush();

    // The first kept its server id; the second went under its own.
    expect([for (final d in spliit.expenses[id]!) d['id']], [first['id'], second]);
    expect({for (final d in spliit.expenses[id]!) d['url']}, hasLength(2));
    expect(await attachments(id), isEmpty);
    expect(spliit.count('update'), 1);
  });

  test('an interrupted upload whose object arrived isn\'t sent again', () async {
    await db.insertPending(expense('local-1'));
    spliit.bucket['https://bucket.test/b/document-early.jpg'] = [1];
    await attach('local-1',
        state: AttachmentState.uploading, url: 'https://bucket.test/b/document-early.jpg');

    await flush();

    expect(spliit.count('sign'), 0);
    expect(spliit.count('put'), 0);
    expect(spliit.expenses[await syncedId()]!.single['url'], 'https://bucket.test/b/document-early.jpg');
  });

  test('an interrupted upload whose object never arrived is signed and sent again', () async {
    await db.insertPending(expense('local-1'));
    await attach('local-1',
        state: AttachmentState.uploading, url: 'https://bucket.test/b/document-lost.jpg');

    await flush();

    expect(spliit.count('head'), 1);
    expect(spliit.count('sign'), 1);
    final url = spliit.expenses[await syncedId()]!.single['url'];
    expect(url, isNot('https://bucket.test/b/document-lost.jpg'));
    expect(spliit.bucket, contains(url));
  });

  test('an unexpected failure is kept, not retried by itself, and Retry sends it', () async {
    expectUnexpectedError<SpliitApiException>('Uploading receipt att-1');
    await db.insertPending(expense('local-1'));
    await attach('local-1');
    spliit.failing['sign'] = 500;

    await flush();
    spliit.failing.clear();
    await flush();

    final id = await syncedId();
    final failed = (await attachments(id)).single;
    expect(failed.state, AttachmentState.failed);
    expect(failed.lastError, contains('Uploading receipt att-1 failed.'));
    expect(spliit.count('sign'), 1);

    await db.retryAttachment(failed.id);
    await flush();

    expect(await attachments(id), isEmpty);
    expect(spliit.expenses[id], hasLength(1));
  });

  test('a photo added to a synced expense keeps its other receipts', () async {
    spliit.expenses['server-9'] = [
      {'id': 'web-doc', 'url': 'https://bucket.test/b/web.jpg', 'width': 1, 'height': 1},
    ];
    await db.replaceServerExpenses('g1', [expense('server-9').copyWithSynced(documentCount: 1)]);
    final att = await attach('server-9');

    await flush();

    expect([for (final d in spliit.expenses['server-9']!) d['id']], ['web-doc', att]);
    expect([for (final d in await db.watchExpenseDocuments('server-9').first) d.id], ['web-doc', att]);
    expect((await db.expensesForGroup('g1')).single.documentCount, 2);
  });

  test('an update whose response was lost isn\'t repeated', () async {
    spliit.expenses['server-9'] = [];
    await db.replaceServerExpenses('g1', [expense('server-9').copyWithSynced()]);
    await attach('server-9');
    spliit.loseUpdateResponse = true;

    await flush();
    expect(await attachments('server-9'), hasLength(1));
    await flush();

    expect(spliit.count('update'), 1);
    expect(spliit.expenses['server-9'], hasLength(1));
    expect(await attachments('server-9'), isEmpty);
  });

  test('an expense deleted on the server drops its waiting photos', () async {
    await db.replaceServerExpenses('g1', [expense('server-gone').copyWithSynced()]);
    await attach('server-gone');

    await flush();

    expect(await attachments('server-gone'), isEmpty);
    expect(spliit.count('update'), 0);
  });

  test('discarding a pending expense removes its photos; Clear and sweeps never do', () async {
    await db.insertPending(expense('local-1'));
    await attach('local-1');
    Future<int> files() => dir.list().length;

    await cache.clear();
    await cache.sweep();
    expect(await files(), 1);

    await db.recordSyncFailure(id: 'local-1', error: 'x', retryCount: 1, failed: true);
    await db.deleteFailedExpense('local-1');
    await cache.sweep();
    expect(await attachments('local-1'), isEmpty);
    expect(await files(), 0);
  });

  test('offline, nothing changes and nothing is logged', () async {
    await db.insertPending(expense('local-1'));
    await attach('local-1');
    for (final step in ['sign', 'create']) {
      spliit.failing[step] = 'offline';
    }

    await flush();

    expect((await attachments('local-1')).single.state, AttachmentState.local);
    expect(loggedUnexpectedErrors, isEmpty);
  });
}

extension on Expense {
  /// This expense as a refresh lists it: synced, counted.
  Expense copyWithSynced({int documentCount = 0}) => Expense(
        id: id,
        groupId: groupId,
        title: title,
        amountCents: amountCents,
        paidBy: paidBy,
        paidFor: paidFor,
        date: date,
        documentCount: documentCount,
      );
}
