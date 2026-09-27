import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/services/error_reporting.dart';
import 'package:spliit2go/services/receipt_cache.dart';

// Issue #123: receipt images on this device and the storage policy.
void main() {
  late AppDatabase db;
  late Directory dir;
  late List<Uri> requests;
  var now = DateTime(2026, 9, 27, 12);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dir = await Directory.systemTemp.createTemp('receipts-');
    requests = [];
    now = DateTime(2026, 9, 27, 12);
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  /// A bucket serving [size] bytes for every image, or [status].
  ReceiptCache cache({int size = 100, int status = 200, int cap = 1000, Object? throws}) =>
      ReceiptCache(
        db,
        directory: () async => dir,
        viewingCap: cap,
        clock: () => now = now.add(const Duration(minutes: 1)),
        httpClient: MockClient((req) async {
          requests.add(req.url);
          if (throws != null) throw throws;
          return http.Response.bytes(List.filled(size, 7), status);
        }),
      );

  String url(String name) => 'https://bucket.test/document-$name.jpg';

  Future<List<String>> filesOnDisk() async =>
      [await for (final f in dir.list()) f.path.split('/').last]..sort();

  test('downloads a receipt once, then serves it from this device', () async {
    final receipts = cache();

    final first = await receipts.load(url('a'), groupId: 'g1');
    final second = await receipts.load(url('a'), groupId: 'g1');

    expect(requests, hasLength(1));
    expect(second.path, first.path);
    expect(await first.readAsBytes(), hasLength(100));
    final row = (await db.receiptFile(url('a')))!;
    expect((row.groupId, row.bytes, row.kind), ('g1', 100, ReceiptFileKind.viewing));
    expect(await receipts.cachedFile(url('b')), isNull);
  });

  test('two loads of one receipt at once share a download', () async {
    final receipts = cache();
    await Future.wait([
      receipts.load(url('a'), groupId: 'g1'),
      receipts.load(url('a'), groupId: 'g1'),
    ]);
    expect(requests, hasLength(1));
  });

  test('a refused download is unexpected; no connection is a connection problem (#119)', () async {
    await expectLater(cache(status: 403).load(url('a'), groupId: 'g1'),
        throwsA(isA<ReceiptDownloadException>()
            .having((e) => classifyError(e), 'kind', ErrorKind.unexpected)));
    await expectLater(
        cache(throws: http.ClientException('offline')).load(url('a'), groupId: 'g1'),
        throwsA(isA<http.ClientException>()
            .having((e) => classifyError(e), 'kind', ErrorKind.connection)));
    // Nothing half-stored.
    expect(await db.allReceiptFiles(), isEmpty);
    expect(await filesOnDisk(), isEmpty);
  });

  test('the viewing cache stays under its cap, least recently used out first', () async {
    final receipts = cache(size: 400, cap: 1000);
    await receipts.load(url('a'), groupId: 'g1');
    await receipts.load(url('b'), groupId: 'g1');
    await receipts.load(url('a'), groupId: 'g1'); // now b is the least recently used
    await receipts.load(url('c'), groupId: 'g1');

    expect({for (final f in await db.allReceiptFiles()) f.url}, {url('a'), url('c')});
    expect(await filesOnDisk(), hasLength(2));
    expect(await receipts.usage(), 800);
  });

  test('a receipt bigger than the whole cap is still kept while it\'s the one being viewed', () async {
    final receipts = cache(size: 2000, cap: 1000);
    final file = await receipts.load(url('big'), groupId: 'g1');
    expect(await file.exists(), isTrue);
    expect(await db.receiptFile(url('big')), isNotNull);
  });

  test('sweep deletes files nothing refers to, including partial downloads', () async {
    final receipts = cache();
    await receipts.load(url('kept'), groupId: 'g1');
    await receipts.load(url('dropped'), groupId: 'g1');
    await File('${dir.path}/stray.img.part').writeAsString('x');
    // The database stops referring to one (a refresh, a delete, leaving).
    await db.deleteReceiptFiles([url('dropped')]);

    await receipts.sweep();

    expect(await filesOnDisk(), [(await db.receiptFile(url('kept')))!.fileName]);
  });

  test('a file removed outside the app is forgotten and downloaded again', () async {
    final receipts = cache();
    final file = await receipts.load(url('a'), groupId: 'g1');
    await file.delete();

    expect(await receipts.cachedFile(url('a')), isNull);
    expect(await db.receiptFile(url('a')), isNull);
    await receipts.load(url('a'), groupId: 'g1');
    expect(requests, hasLength(2));
  });

  test('clear removes every stored receipt', () async {
    final receipts = cache();
    await receipts.load(url('a'), groupId: 'g1');
    await receipts.load(url('b'), groupId: 'g2');

    await receipts.clear();

    expect(await db.allReceiptFiles(), isEmpty);
    expect(await filesOnDisk(), isEmpty);
    expect(await receipts.usage(), 0);
  });

  test('a refresh that drops an expense lets sweep delete its receipt', () async {
    final receipts = cache();
    final e = Expense(
        id: 'e1',
        groupId: 'g1',
        title: 'Coffee',
        amountCents: 1860,
        paidBy: 'p1',
        paidFor: const [],
        date: DateTime(2026, 9, 23),
        documentCount: 1);
    await db.replaceServerExpenses('g1', [e]);
    await db.cacheExpenseDocuments(
        'g1', 'e1', [ExpenseDocument(id: 'd1', url: url('a'), width: 600, height: 900)]);
    await receipts.load(url('a'), groupId: 'g1');

    await db.replaceServerExpenses('g1', []);
    await receipts.sweep();

    expect(await filesOnDisk(), isEmpty);
  });

  // #131 review (Ezra): a photo uploaded for an expense still pending is
  // referenced by that expense, through its sync, until it's read again.
  test('an unsynced expense\'s uploaded receipt survives refreshes and the sync', () async {
    final receipts = cache();
    const doc = ExpenseDocument(id: 'local-doc', url: 'https://bucket.test/document-new.jpg', width: 600, height: 900);
    await receipts.store(doc.url, groupId: 'g1', bytes: List.filled(10, 1));
    await db.insertPending(Expense(
        id: 'local-1',
        groupId: 'g1',
        title: 'Coffee',
        amountCents: 1860,
        paidBy: 'p1',
        paidFor: const [],
        date: DateTime(2026, 9, 27),
        pending: true,
        documents: const [doc],
        documentCount: 1));

    // A refresh while it's pending (the server doesn't have it yet).
    await db.replaceServerExpenses('g1', []);
    await receipts.sweep();
    expect(await receipts.cachedFile(doc.url), isNotNull);

    // It syncs, then a refresh lists it with its one document.
    await db.markSynced(localId: 'local-1', serverId: 'server-1');
    expect((await db.watchExpenseDocuments('server-1').first).single.url, doc.url);
    await db.replaceServerExpenses('g1', [
      Expense(
          id: 'server-1',
          groupId: 'g1',
          title: 'Coffee',
          amountCents: 1860,
          paidBy: 'p1',
          paidFor: const [],
          date: DateTime(2026, 9, 27),
          documentCount: 1),
    ]);
    await receipts.sweep();
    expect(await receipts.cachedFile(doc.url), isNotNull);
  });

  // #130 review (Ezra): a sweep while a download is being stored must not
  // delete the file that load then returns.
  test('a sweep during a download waits, and never deletes the file being stored', () async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    final paused = _PausingDb(entered, gate.future);
    addTearDown(paused.close);
    final receipts = ReceiptCache(paused,
        directory: () async => dir,
        httpClient: MockClient((_) async => http.Response.bytes(List.filled(10, 1), 200)));

    final loading = receipts.load(url('a'), groupId: 'g1');
    await entered.future; // renamed, about to register its row
    final sweeping = receipts.sweep();
    // Give the sweep every chance to run before the row is registered.
    await Future.any([sweeping, Future<void>.delayed(const Duration(milliseconds: 200))]);
    gate.complete();
    final file = await loading;
    await sweeping;

    expect(await file.exists(), isTrue);
    expect(await paused.receiptFile(url('a')), isNotNull);
  });
}

/// Pauses the first file registration until [gate], saying when it got
/// there through [entered].
class _PausingDb extends AppDatabase {
  _PausingDb(this.entered, this.gate) : super(NativeDatabase.memory());
  final Completer<void> entered;
  final Future<void> gate;

  @override
  Future<void> saveReceiptFile(ReceiptFilesCompanion row) async {
    if (!entered.isCompleted) {
      entered.complete();
      await gate;
    }
    return super.saveReceiptFile(row);
  }
}
