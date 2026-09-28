import 'dart:async';
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

/// A Spliit instance and its bucket, with create's document rule from
/// src/lib/api.ts (cc796210): documents get new ids. There's no read or
/// update: a new expense syncs with its receipts, so the outbox never
/// needs them (#124).
class _Spliit {
  final bucket = <String, List<int>>{};
  final expenses = <String, List<Map<String, Object?>>>{};
  final calls = <String>[];
  var _next = 0;

  /// Makes the named step fail: with `offline`, or an HTTP status.
  final failing = <String, Object>{};

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
        default:
          throw StateError('unhandled $step');
      }
    }),
  );

  int count(String step) => calls.where((c) => c == step).length;
}

/// Holds a sweep right after it reads the stored receipts, once [hold]
/// is set: the point where a sync could promote a photo unseen.
class _GatedDb extends AppDatabase {
  _GatedDb() : super(NativeDatabase.memory());

  Completer<void>? hold;
  final reached = Completer<void>();

  @override
  Future<List<ReceiptFileRow>> allReceiptFiles() async {
    final rows = await super.allReceiptFiles();
    if (hold case final hold?) {
      if (!reached.isCompleted) reached.complete();
      await hold.future;
    }
    return rows;
  }
}

// Issue #124: receipt photos that aren't uploaded yet are kept on the
// device and reach their expense later; the expense never waits for them.
void main() {
  late _GatedDb db;
  late Directory dir;
  late ReceiptCache cache;
  late _Spliit spliit;
  var photos = 0;

  setUp(() async {
    db = _GatedDb();
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

  /// A pending expense [id] with photos in [states] (with their URLs), as
  /// the form's Save stores them: files and rows in one step.
  Future<List<String>> pendingWith(String id,
      [List<(AttachmentState, String?)> states = const [(AttachmentState.local, null)]]) async {
    final ids = [for (final _ in states) 'att-${++photos}'];
    await cache.storePending(
        [for (final (i, _) in states.indexed) List.filled(10, i + 1)],
        (fileNames) => db.insertPending(expense(id), attachments: [
              for (final (i, (state, url)) in states.indexed)
                ReceiptAttachmentsCompanion.insert(
                  id: ids[i],
                  groupId: 'g1',
                  expenseId: id,
                  fileName: fileNames[i],
                  bytes: 10,
                  width: 600,
                  height: 900,
                  state: state,
                  url: Value(url),
                  createdAt: DateTime(2026, 9, 27, 12, i),
                ),
            ]));
    return ids;
  }

  Future<List<ReceiptAttachmentRow>> attachments(String expenseId) => db.attachmentsFor(expenseId);

  Future<ExpenseRow> onlyRow() async => (await db.expensesForGroup('g1')).single;

  test('the photos go up first, and the expense is created with them; they become captures',
      () async {
    await pendingWith('local-1', [(AttachmentState.local, null), (AttachmentState.local, null)]);

    await flush();

    final row = await onlyRow();
    expect(row.pending, isFalse);
    expect(spliit.expenses[row.id], hasLength(2));
    expect(row.documentCount, 2);
    expect(await attachments('local-1'), isEmpty);
    for (final d in spliit.expenses[row.id]!) {
      expect((await db.receiptFile(d['url'] as String))!.kind, ReceiptFileKind.capture);
    }
    expect(await dir.list().length, 2);
  });

  test('offline, the expense and its photos wait together, and nothing is logged', () async {
    await pendingWith('local-1');
    spliit.failing['sign'] = 'offline';

    await flush();

    expect(spliit.count('create'), 0);
    expect((await onlyRow()).pending, isTrue);
    expect((await attachments('local-1')).single.state, AttachmentState.local);
    expect(loggedUnexpectedErrors, isEmpty);

    spliit.failing.clear();
    await flush();

    expect(spliit.expenses[(await onlyRow()).id], hasLength(1));
  });

  test('upload succeeds, then the create fails: the retry reuses the upload', () async {
    expectUnexpectedError<SpliitApiException>('Syncing expense local-1');
    await pendingWith('local-1');
    spliit.failing['create'] = 500;

    await flush();
    expect((await attachments('local-1')).single.state, AttachmentState.uploaded);

    spliit.failing.clear();
    await flush();

    expect(spliit.count('put'), 1);
    expect(spliit.expenses[(await onlyRow()).id], hasLength(1));
  });

  test('several photos, the connection drops mid-way: the expense waits, and nothing goes up twice',
      () async {
    await pendingWith('local-1', [(AttachmentState.local, null), (AttachmentState.local, null)]);
    spliit.dropPut = 2; // the connection drops during the second transfer

    await flush();

    expect(spliit.count('create'), 0);
    expect([for (final a in await attachments('local-1')) a.state],
        [AttachmentState.uploaded, AttachmentState.uploading]);

    spliit.dropPut = null;
    await flush();

    // The first isn't sent again; the second is.
    expect(spliit.count('put'), 3);
    expect({for (final d in spliit.expenses[(await onlyRow()).id]!) d['url']}, hasLength(2));
  });

  // #138 review (Ezra): a rejected create deleted the photos.
  test('a rejected create keeps the photos with the failed expense', () async {
    expectUnexpectedError<SpliitApiException>('Syncing expense local-1');
    await pendingWith('local-1');
    spliit.failing['create'] = 400;

    await flush();

    expect((await onlyRow()).syncFailed, isTrue);
    expect(await attachments('local-1'), hasLength(1));
    await cache.sweep();
    expect(await dir.list().length, 1);
  });

  test('an interrupted upload whose object arrived isn\'t sent again', () async {
    await pendingWith('local-1',
        [(AttachmentState.uploading, 'https://bucket.test/b/document-early.jpg')]);
    spliit.bucket['https://bucket.test/b/document-early.jpg'] = [1];

    await flush();

    expect((spliit.count('sign'), spliit.count('put')), (0, 0));
    expect(spliit.expenses[(await onlyRow()).id]!.single['url'],
        'https://bucket.test/b/document-early.jpg');
  });

  test('an interrupted upload whose object never arrived is signed and sent again', () async {
    await pendingWith('local-1', [(AttachmentState.uploading, 'https://bucket.test/b/document-lost.jpg')]);

    await flush();

    expect((spliit.count('head'), spliit.count('sign')), (1, 1));
    final url = spliit.expenses[(await onlyRow()).id]!.single['url'];
    expect(url, isNot('https://bucket.test/b/document-lost.jpg'));
    expect(spliit.bucket, contains(url));
  });

  test('a photo the server refuses marks the expense failed, keeps the photo, and waits for Retry',
      () async {
    expectUnexpectedError<SpliitApiException>('Syncing expense local-1');
    await pendingWith('local-1');
    spliit.failing['sign'] = 500;

    await flush();
    spliit.failing.clear();
    await flush();

    final row = await onlyRow();
    expect((row.pending, row.syncFailed), (true, true));
    expect(row.lastError, contains('SpliitApiException(500)'));
    expect(await attachments('local-1'), hasLength(1));
    expect(spliit.count('sign'), 1);

    await db.retrySyncFailure('local-1');
    await flush();

    expect(spliit.expenses[(await onlyRow()).id], hasLength(1));
  });

  test('Sync without receipts drops the photos, then the expense syncs without them', () async {
    expectUnexpectedError<SpliitApiException>('Syncing expense local-1');
    await pendingWith('local-1');
    spliit.failing['sign'] = 500;
    await flush();

    await db.retrySyncFailure('local-1', withoutReceipts: true);
    await flush();
    await cache.sweep();

    expect(spliit.expenses[(await onlyRow()).id], isEmpty);
    expect(await attachments('local-1'), isEmpty);
    expect(await dir.list().length, 0);
  });

  test('discarding a failed expense removes its photos; Clear and sweeps never do', () async {
    await pendingWith('local-1');
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

  // #138 review (Ezra): the sweep read the stored receipts, the sync made
  // the photo a capture, then the sweep read the pending photos: the photo
  // was in neither, and its file was deleted.
  test('a sweep during the sync keeps the photo that becomes a capture', () async {
    await pendingWith('local-1');
    db.hold = Completer();
    final sweeping = cache.sweep();
    await Future.any([db.reached.future, sweeping]);

    await flush();
    db.hold!.complete();
    await sweeping;

    final url = spliit.expenses[(await onlyRow()).id]!.single['url'] as String;
    final capture = (await db.receiptFile(url))!;
    expect(capture.kind, ReceiptFileKind.capture);
    expect(await (await cache.fileNamed(capture.fileName)).exists(), isTrue);
  });
}
