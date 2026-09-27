import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/models/group_organization.dart';
import 'package:spliit2go/services/receipt_cache.dart';
import 'package:spliit2go/services/receipt_downloader.dart';
import 'package:spliit2go/services/settings_service.dart';

import '../support/error_log.dart';

// Issue #127: a favorite group's receipts, downloaded ahead for offline.
void main() {
  late AppDatabase db;
  late Directory dir;
  late ReceiptCache cache;
  late List<ConnectivityResult> network;
  late StreamController<List<ConnectivityResult>> changes;
  late Map<String, int> bucketStatus;
  late List<String> downloads;
  late List<String> reads;

  /// Expenses whose read the server answers with a 500.
  late Set<String> failingReads;
  Completer<void>? holdDownload;

  const wifi = [ConnectivityResult.wifi];
  const mobile = [ConnectivityResult.mobile];

  /// The server: e1 has two receipts, e2 one.
  late Map<String, List<String>> documents;
  final initialDocuments = {
    'e1': ['https://bucket.test/1.jpg', 'https://bucket.test/2.jpg'],
    'e2': ['https://bucket.test/3.jpg'],
  };

  late SpliitClient server;

  /// The server's activity log, newest first: `(id, type, expenseId)`.
  late List<(String, String, String?)> activities;
  late int activityReads;

  http.Response trpc(Object data) => http.Response(
      jsonEncode([
        {
          'result': {
            'data': {'json': data},
          },
        },
      ]),
      200);

  SpliitClient newServer() => SpliitClient(
    baseUrl: 'https://spliit.test',
    httpClient: MockClient((req) async {
      final input = jsonDecode(req.url.queryParameters['input']!)['0']['json'] as Map;
      if (req.url.path.endsWith('groups.activities.list')) {
        activityReads++;
        final cursor = input['cursor'] as int, limit = input['limit'] as int;
        final page = activities.skip(cursor).take(limit).toList();
        return trpc({
          'activities': [
            for (final (i, (id, type, expenseId)) in page.indexed)
              {
                'id': id,
                // A minute apart, fixed per entry: counted from the oldest.
                'time': DateTime.utc(2026, 9, 27, 12)
                    .add(Duration(minutes: activities.length - 1 - (cursor + i)))
                    .toIso8601String(),
                'activityType': type,
                'expenseId': expenseId,
                'expense': expenseId == null ? null : {'id': expenseId},
              },
          ],
          'hasMore': cursor + limit < activities.length,
          'nextCursor': cursor + limit,
        });
      }
      final id = input['expenseId'] as String;
      reads.add(id);
      if (failingReads.contains(id)) return http.Response('boom', 500);
      return http.Response(
          jsonEncode([
            {
              'result': {
                'data': {
                  'json': {
                    'expense': {
                      'id': id,
                      'title': 'Coffee',
                      'amount': 500,
                      'paidBy': {'id': 'p1'},
                      'paidFor': [],
                      'expenseDate': '2026-09-27T00:00:00.000Z',
                      'documents': [
                        for (final (i, url) in documents[id]!.indexed)
                          {'id': '$id-d$i', 'url': url, 'width': 600, 'height': 900},
                      ],
                    },
                  },
                },
              },
            },
          ]),
          200);
    }),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    documents = {for (final e in initialDocuments.entries) e.key: [...e.value]};
    db = AppDatabase(NativeDatabase.memory());
    dir = await Directory.systemTemp.createTemp('favorite-receipts-');
    cache = ReceiptCache(db, directory: () async => dir, limit: 1000);
    ReceiptCache.use(cache);
    network = wifi;
    changes = StreamController.broadcast();
    bucketStatus = {};
    downloads = [];
    reads = [];
    holdDownload = null;
    activities = [('a2', 'UPDATE_EXPENSE', 'e1'), ('a1', 'CREATE_EXPENSE', 'e1')];
    activityReads = 0;
    failingReads = {};
    server = newServer();
    await db.cacheGroup(const Group(id: 'g1', name: 'Banff Trip', currency: '\$', participants: []));
    await db.setGroupOrganization('g1', GroupOrganization.favorite);
    await db.replaceServerExpenses('g1', [
      for (final MapEntry(key: id, value: urls) in documents.entries)
        Expense(
            id: id,
            groupId: 'g1',
            title: 'Coffee',
            amountCents: 500,
            paidBy: 'p1',
            paidFor: const [],
            date: DateTime(2026, 9, 27),
            documentCount: urls.length),
    ]);
  });
  tearDown(() async {
    await changes.close();
    await db.close();
    await dir.delete(recursive: true);
  });

  ReceiptDownloader downloader() => ReceiptDownloader(
        db,
        cache: cache,
        connectivity: () async => network,
        connectivityChanges: changes.stream,
        httpClient: () => MockClient((req) async {
          final url = req.url.toString();
          downloads.add(url);
          if (holdDownload case final hold?) await hold.future;
          return http.Response.bytes(List.filled(100, 1), bucketStatus[url] ?? 200);
        }),
      );

  /// [d]'s status for g1, worked out now.
  Future<ReceiptDownloadStatus> statusOf(ReceiptDownloader d) async {
    final status = d.status('g1');
    await d.refreshStatus('g1');
    return status.value;
  }

  Future<Map<String, ReceiptFileKind>> stored() async =>
      {for (final f in await db.allReceiptFiles()) f.url: f.kind};

  test('a favorite group on Wi-Fi: every receipt is read, downloaded and kept', () async {
    final d = downloader();

    await d.run('g1', server);

    expect(reads, ['e1', 'e2']);
    expect(await stored(), {for (final u in documents.values.expand((u) => u)) u: ReceiptFileKind.favorite});
    final status = await statusOf(d);
    expect((status.shown, status.running, status.total, status.available, status.complete),
        (true, false, 3, 3, true));
    expect(status.problem, isNull);
  });

  test('nothing downloads for a group that isn\'t a favorite', () async {
    await db.setGroupOrganization('g1', GroupOrganization.active);
    final d = downloader();

    await d.run('g1', server);

    expect(reads, isEmpty);
    expect(downloads, isEmpty);
    expect((await statusOf(d)).shown, isFalse);
  });

  test('Wi-Fi only, on mobile data: nothing downloads, and it waits for Wi-Fi without an error',
      () async {
    network = mobile;
    final d = downloader();

    await d.run('g1', server);

    expect(reads, isEmpty);
    expect(downloads, isEmpty);
    final status = await statusOf(d);
    expect((status.problem, status.isError), (ReceiptDownloadProblem.waitingForWifi, false));
  });

  test('"Always" downloads on mobile data too; Off downloads nothing', () async {
    network = mobile;
    await SettingsService().setReceiptDownloadMode(ReceiptDownloadMode.always);
    await downloader().run('g1', server);
    expect(downloads, hasLength(3));

    await SettingsService().setReceiptDownloadMode(ReceiptDownloadMode.off);
    downloads.clear();
    await cache.clear();
    final d = downloader();
    await d.run('g1', server);
    expect(downloads, isEmpty);
    expect((await statusOf(d)).shown, isFalse);
  });

  test('losing Wi-Fi cancels the transfer in flight; the rest wait, then resume', () async {
    final d = downloader();
    holdDownload = Completer();

    final running = d.run('g1', server);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(downloads, hasLength(1));
    changes.add(mobile);
    // A real client's close aborts the transfer; MockClient's doesn't.
    holdDownload!.complete();
    await running;

    expect(await stored(), isEmpty);
    expect((await statusOf(d)).problem, ReceiptDownloadProblem.waitingForWifi);

    holdDownload = null;
    changes.add(wifi);
    await d.run('g1', server);
    expect((await statusOf(d)).complete, isTrue);
    expect((await statusOf(d)).problem, isNull);
  });

  // Found on the iOS simulator: listening reports "none" at once, which
  // stopped the run with "Couldn't reach the server".
  test('a "none" report mid-run doesn\'t stop it; going offline fails the transfer instead',
      () async {
    final d = downloader();
    holdDownload = Completer();
    final running = d.run('g1', server);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    changes.add([ConnectivityResult.none]);
    holdDownload!.complete();
    await running;

    final status = await statusOf(d);
    expect((status.complete, status.problem), (true, null));
  });

  test('a receipt that fails is reported, the rest download, and Retry finishes it', () async {
    expectUnexpectedError<ReceiptDownloadException>('Downloading receipt https://bucket.test/2.jpg');
    bucketStatus['https://bucket.test/2.jpg'] = 403;
    final d = downloader();

    await d.run('g1', server);

    var status = await statusOf(d);
    expect((status.total, status.available, status.isError), (3, 2, true));
    expect(status.problem, ReceiptDownloadProblem.failed);
    expect(status.diagnostics, contains('HTTP 403'));

    bucketStatus.clear();
    await d.run('g1', server);
    status = await statusOf(d);
    expect((status.complete, status.problem), (true, null));
  });

  test('offline: it stops, says so, and logs nothing', () async {
    final d = ReceiptDownloader(db,
        cache: cache,
        connectivity: () async => wifi,
        connectivityChanges: changes.stream,
        httpClient: () => MockClient((_) async => throw http.ClientException('offline')));
    await db.cacheExpenseDocuments('g1', 'e1', [
      for (final (i, u) in documents['e1']!.indexed) ExpenseDocument(id: 'd$i', url: u, width: 1, height: 1),
    ]);

    await d.run('g1', SpliitClient(
        baseUrl: 'https://spliit.test',
        httpClient: MockClient((_) async => throw http.ClientException('offline'))));

    expect((await statusOf(d)).problem, ReceiptDownloadProblem.offline);
    expect(loggedUnexpectedErrors, isEmpty);
  });

  test('at the storage limit: viewing cache goes first, then it pauses; waiting photos stay',
      () async {
    await cache.store('https://bucket.test/old.jpg', groupId: 'g2', bytes: List.filled(300, 1));
    await db.insertPending(
        Expense(
            id: 'local-1',
            groupId: 'g1',
            title: 'Coffee',
            amountCents: 500,
            paidBy: 'p1',
            paidFor: const [],
            date: DateTime(2026, 9, 27),
            pending: true),
        attachments: [
          ReceiptAttachmentsCompanion.insert(
              id: 'a1',
              groupId: 'g1',
              expenseId: 'local-1',
              fileName: 'a1.img',
              bytes: 850,
              width: 1,
              height: 1,
              state: AttachmentState.local,
              createdAt: DateTime(2026, 9, 27)),
        ]);
    final d = downloader();

    await d.run('g1', server);

    // 850 waiting + 100 downloaded fits 1000 only once the 300 of viewing
    // cache is gone; the next 100 doesn't.
    expect(await stored(), {'https://bucket.test/1.jpg': ReceiptFileKind.favorite});
    final status = await statusOf(d);
    expect((status.problem, status.isError), (ReceiptDownloadProblem.noSpace, true));
    expect(await db.attachmentFileNames(), {'a1.img'});
  });

  test('a receipt opened earlier is kept, not downloaded again', () async {
    await cache.store('https://bucket.test/1.jpg', groupId: 'g1', bytes: List.filled(100, 1));

    await downloader().run('g1', server);

    expect(downloads, isNot(contains('https://bucket.test/1.jpg')));
    expect((await stored())['https://bucket.test/1.jpg'], ReceiptFileKind.favorite);
  });

  test('unfavoriting cancels, and its downloads become viewing cache', () async {
    final d = downloader();
    await d.run('g1', server);

    await db.setGroupOrganization('g1', GroupOrganization.active);
    await d.unfavorited('g1');

    expect((await stored()).values.toSet(), {ReceiptFileKind.viewing});
    expect((await statusOf(d)).shown, isFalse);
  });

  test('unfavoriting mid-run stops the transfer in flight', () async {
    final d = downloader();
    holdDownload = Completer();
    final running = d.run('g1', server);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await db.setGroupOrganization('g1', GroupOrganization.active);
    await d.unfavorited('g1');
    holdDownload!.complete();
    await running;

    expect(downloads, hasLength(1));
    expect(await stored(), isEmpty);
  });

  test('removing the group cancels its run', () async {
    final d = downloader();
    holdDownload = Completer();
    final running = d.run('g1', server);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    d.removed('g1');
    await db.leaveGroup('g1');
    holdDownload!.complete();
    await running;

    expect(await stored(), isEmpty);
  });

  test('after Clear, nothing downloads again until the next run', () async {
    final d = downloader();
    await d.run('g1', server);
    downloads.clear();

    d.cancelAll();
    await cache.clear();
    await d.refreshAll();

    expect(downloads, isEmpty);
    expect((await statusOf(d)).available, 0);
    await d.run('g1', server);
    expect(downloads, hasLength(3));
  });

  test('the status survives a restart: a new downloader reads the last problem', () async {
    network = mobile;
    await downloader().run('g1', server);

    final later = downloader();
    expect((await statusOf(later)).problem, ReceiptDownloadProblem.waitingForWifi);
  });

  test('runs for one group are joined, not doubled', () async {
    final d = downloader();
    holdDownload = Completer();
    final first = d.run('g1', server);
    final second = d.run('g1', server);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    holdDownload!.complete();
    await Future.wait([first, second]);

    expect(downloads, hasLength(3));
    expect(reads, ['e1', 'e2']);
  });

  // #127 (Kenneth): Spliit has no updatedAt on expenses, so edits are
  // found through the activity log.
  group('changes since the last check', () {
    /// The server's refresh: the list, with each expense's count now.
    Future<void> refresh() => db.replaceServerExpenses('g1', [
          for (final MapEntry(key: id, value: urls) in documents.entries)
            Expense(
                id: id,
                groupId: 'g1',
                title: 'Coffee',
                amountCents: 500,
                paidBy: 'p1',
                paidFor: const [],
                date: DateTime(2026, 9, 27),
                documentCount: urls.length),
        ]);

    /// An edit made on the web: logged, newest first.
    void edited(String activityId, String expenseId) =>
        activities.insert(0, (activityId, 'UPDATE_EXPENSE', expenseId));

    test('a receipt swapped on the web, count unchanged, is found and downloaded', () async {
      final d = downloader();
      await d.run('g1', server);
      (reads, downloads) = (<String>[], <String>[]);

      documents['e1']![1] = 'https://bucket.test/swapped.jpg';
      edited('a3', 'e1');
      await refresh();
      await d.run('g1', server);

      expect(reads, ['e1']);
      expect(downloads, ['https://bucket.test/swapped.jpg']);
      expect(await stored(), {
        'https://bucket.test/1.jpg': ReceiptFileKind.favorite,
        'https://bucket.test/swapped.jpg': ReceiptFileKind.favorite,
        'https://bucket.test/3.jpg': ReceiptFileKind.favorite,
      });
      expect((await statusOf(d)).complete, isTrue);
    });

    test('nothing edited since: one look at the log, no expense read again', () async {
      final d = downloader();
      await d.run('g1', server);
      (reads, activityReads) = (<String>[], 0);

      await d.run('g1', server);

      expect(reads, isEmpty);
      expect(activityReads, 1);
    });

    test('the first check reads every list once, even ones already known', () async {
      await db.cacheExpenseDocuments('g1', 'e1', [
        for (final (i, u) in documents['e1']!.indexed) ExpenseDocument(id: 'e1-d$i', url: u, width: 1, height: 1),
      ]);
      final d = downloader();

      await d.run('g1', server);

      expect(reads, ['e1', 'e2']);
    });

    test('a run that fails partway checks the same range again next time', () async {
      expectUnexpectedError<SpliitApiException>('Reading receipts of expense e2');
      final d = downloader();
      await d.run('g1', server);
      reads = [];

      edited('a3', 'e1');
      edited('a4', 'e2');
      failingReads.add('e2');
      await d.run('g1', server);
      expect(reads, unorderedEquals(['e1', 'e2']));
      expect((await statusOf(d)).problem, ReceiptDownloadProblem.failed);

      failingReads.clear();
      reads = [];
      await d.run('g1', server);
      expect(reads, unorderedEquals(['e1', 'e2']));
      expect((await statusOf(d)).problem, isNull);
    });

    test('too many changes to page through: every list is read again', () async {
      final d = downloader();
      await d.run('g1', server);
      reads = [];

      for (var i = 0; i < ReceiptDownloader.activityPages * 50 + 1; i++) {
        activities.insert(0, ('x$i', 'UPDATE_GROUP', null));
      }
      await d.run('g1', server);

      expect(reads, ['e1', 'e2']);
      expect(activityReads, 1 + ReceiptDownloader.activityPages);
    });

    test('a receipt added to an expense downloads alone: the others stay', () async {
      final d = downloader();
      await d.run('g1', server);
      downloads = [];

      documents['e1']!.add('https://bucket.test/added.jpg');
      edited('a3', 'e1');
      await refresh();
      await d.run('g1', server);

      expect(downloads, ['https://bucket.test/added.jpg']);
      expect((await statusOf(d)).available, 4);
    });

    test('an expense left with no receipts loses its list and files', () async {
      final d = downloader();
      await d.run('g1', server);

      documents['e2'] = [];
      edited('a3', 'e2');
      await refresh();

      expect((await stored()).keys, isNot(contains('https://bucket.test/3.jpg')));
    });
  });
}
