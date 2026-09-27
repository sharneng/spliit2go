import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/category.dart';
import 'package:spliit2go/services/category_store.dart';

import '../fixtures/category_seed_ids.dart';
import '../support/error_log.dart';

// Issue #132: categories are kept per server, and work offline.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  String categoriesResponse(List<Map<String, Object>> categories) => jsonEncode([
        {
          'result': {
            'data': {
              'json': {'categories': categories},
            },
          },
        },
      ]);

  const serverList = [
    {'id': 0, 'grouping': 'Uncategorized', 'name': 'General'},
    {'id': 9, 'grouping': 'Food and Drink', 'name': 'Groceries'},
    {'id': 44, 'grouping': 'Life', 'name': 'Hobbies'}, // one only this instance has
  ];

  /// A server answering categories.list with [answer], counting the reads.
  ({SpliitClient client, List<int> reads}) server(Future<http.Response> Function() answer,
      {String baseUrl = 'https://spliit.test'}) {
    final reads = [0];
    return (
      client: SpliitClient(
          baseUrl: baseUrl,
          httpClient: MockClient((req) async {
            expect(req.url.path, endsWith('categories.list'));
            reads[0]++;
            return answer();
          })),
      reads: reads,
    );
  }

  Future<http.Response> ok() async => http.Response(categoriesResponse(serverList), 200);
  Future<http.Response> offline() async => throw http.ClientException('offline');

  List<int> ids(List<Category> cs) => [for (final c in cs) c.id];

  test('before a server\'s list is read, it\'s Spliit\'s seeded one', () async {
    final s = server(offline);
    final store = CategoryStore(db);

    expect(ids(await store.watch(s.client).first), categorySeedIds);
  });

  test('the seeded list matches Spliit\'s migrations', () {
    expect(ids(spliitSeedCategories), categorySeedIds);
    final groceries = spliitSeedCategories.firstWhere((c) => c.id == 9);
    expect((groceries.grouping, groceries.name), ('Food and Drink', 'Groceries'));
  });

  test('a read list is kept, in the server\'s order, and shown from then on', () async {
    final s = server(ok);
    final store = CategoryStore(db);

    await store.refresh(s.client);

    expect(ids(await store.watch(s.client).first), [0, 9, 44]);
    // Another run, offline: still the server's list.
    final later = CategoryStore(db);
    await later.refresh(server(offline).client);
    expect(ids(await later.watch(s.client).first), [0, 9, 44]);
  });

  test('offline, a read keeps what is there and logs nothing (#119)', () async {
    final store = CategoryStore(db);
    await store.refresh(server(ok).client);

    await store.refresh(server(offline).client, force: true);

    expect(ids(await store.watch(server(offline).client).first), [0, 9, 44]);
    expect(loggedUnexpectedErrors, isEmpty);
  });

  test('an unexpected answer is logged, and what is there is kept', () async {
    expectUnexpectedError<SpliitApiException>('Loading categories');
    final store = CategoryStore(db);
    await store.refresh(server(ok).client);

    await store.refresh(server(() async => http.Response('boom', 500)).client, force: true);

    expect(ids(await store.watch(server(offline).client).first), [0, 9, 44]);
  });

  test('an empty list isn\'t kept', () async {
    final s = server(() async => http.Response(categoriesResponse([]), 200));
    final store = CategoryStore(db);

    await store.refresh(s.client);

    expect(ids(await store.watch(s.client).first), categorySeedIds);
  });

  test('read once per run; a failed read is tried again; force reads again', () async {
    var answer = offline;
    final s = server(() => answer());
    final store = CategoryStore(db);

    await store.refresh(s.client);
    answer = ok;
    await store.refresh(s.client);
    await store.refresh(s.client);
    expect(s.reads.single, 2);

    await store.refresh(s.client, force: true);
    expect(s.reads.single, 3);
  });

  test('reads at once share one request', () async {
    final gate = Completer<void>();
    final s = server(() async {
      await gate.future;
      return ok();
    });
    final store = CategoryStore(db);

    final both = Future.wait([store.refresh(s.client), store.refresh(s.client)]);
    gate.complete();
    await both;

    expect(s.reads.single, 1);
  });

  test('each server has its own list', () async {
    final a = server(ok, baseUrl: 'https://a.test');
    final b = server(offline, baseUrl: 'https://b.test');
    final store = CategoryStore(db);

    await store.refresh(a.client);
    await store.refresh(b.client);

    expect(ids(await store.watch(a.client).first), [0, 9, 44]);
    expect(ids(await store.watch(b.client).first), categorySeedIds);
  });
}
