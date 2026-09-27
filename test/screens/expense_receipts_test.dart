import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:spliit2go/screens/expense_details_sheet.dart';
import 'package:spliit2go/services/receipt_cache.dart';
import 'package:spliit2go/sync/outbox.dart';

/// Serves every receipt as a file path, or fails with [error], without
/// touching the file system (widget tests run in a fake-async zone).
class _FakeReceipts extends ReceiptCache {
  _FakeReceipts(super.db);

  final loaded = <String>[];
  Object? error;

  @override
  Future<File> load(String url, {required String groupId}) async {
    if (error case final error?) throw error;
    loaded.add(url);
    return File('/receipts/${url.split('/').last}');
  }
}

// Issue #123: an expense's receipts in its details sheet, and a viewer.
void main() {
  const banff = Group(
    id: 'g1',
    name: 'Banff Trip',
    currency: '\$',
    participants: [Participant(id: 'alex', name: 'Alex'), Participant(id: 'bea', name: 'Bea')],
  );

  Expense coffee({int documents = 2}) => Expense(
        id: 'e1',
        groupId: 'g1',
        title: 'Coffee',
        amountCents: 1860,
        paidBy: 'bea',
        paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
        date: DateTime(2026, 9, 23),
        documentCount: documents,
      );

  const receipts = [
    {'id': 'd1', 'url': 'https://bucket.test/document-1.jpg', 'width': 600, 'height': 900},
    {'id': 'd2', 'url': 'https://bucket.test/document-2.jpg', 'width': 900, 'height': 600},
  ];
  List<ExpenseDocument> docs() => [for (final d in receipts) ExpenseDocument.fromJson(d)];

  String expenseResponse() => jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'expense': {
                  'id': 'e1',
                  'title': 'Coffee',
                  'amount': 1860,
                  'paidBy': {'id': 'bea'},
                  'paidFor': [
                    {'participantId': 'alex', 'shares': 1},
                  ],
                  'expenseDate': '2026-09-23T00:00:00.000Z',
                  'documents': receipts,
                },
              },
            },
          },
        },
      ]);

  /// A server answering groups.expenses.get with [answers] in turn (the
  /// last one repeats), counting the reads.
  ({SpliitClient client, List<int> gets}) server(List<Future<http.Response> Function()> answers) {
    final gets = <int>[0];
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        if (!req.url.path.endsWith('groups.expenses.get')) return http.Response('no', 500);
        final i = gets[0]++;
        return answers[i < answers.length ? i : answers.length - 1]();
      }),
    );
    return (client: client, gets: gets);
  }

  Future<http.Response> ok() async => http.Response(expenseResponse(), 200);

  Future<(AppDatabase, _FakeReceipts)> setUpDb({int documents = 2}) async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.replaceServerExpenses('g1', [coffee(documents: documents)]);
    final fake = _FakeReceipts(db);
    ReceiptCache.use(fake);
    return (db, fake);
  }

  Future<void> openSheet(WidgetTester tester, AppDatabase db, SpliitClient client,
      {Stream<bool> connectivity = const Stream.empty()}) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showExpenseDetails(context,
                  expenseId: 'e1',
                  group: banff,
                  db: db,
                  client: client,
                  outbox: Outbox(db, client, groupId: 'g1'),
                  connectivity: connectivity),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> closeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Finder receiptImages() => find.byWidgetPredicate((w) => w is Image && w.image is FileImage);

  testWidgets('an expense with no receipts has no Receipts section', (tester) async {
    final (db, _) = await setUpDb(documents: 0);
    addTearDown(db.close);
    final s = server([ok]);
    await openSheet(tester, db, s.client);

    expect(find.text('Receipts'), findsNothing);
    expect(s.gets.single, 0);
    await closeTree(tester);
  });

  testWidgets('receipts the list only counted are read once, stored, and shown', (tester) async {
    final (db, fake) = await setUpDb();
    addTearDown(db.close);
    final s = server([ok]);
    await openSheet(tester, db, s.client);

    expect(find.text('Receipts'), findsOneWidget);
    expect(s.gets.single, 1);
    expect(receiptImages(), findsNWidgets(2));
    expect(fake.loaded, [receipts[0]['url'], receipts[1]['url']]);
    final stored = await tester.runAsync(() => db.watchExpenseDocuments('e1').first);
    expect(stored!.map((d) => d.id), ['d1', 'd2']);

    // Opening it again shows the stored ones, and checks them again.
    await closeTree(tester);
    await openSheet(tester, db, s.client);
    expect(s.gets.single, 2);
    expect(receiptImages(), findsNWidgets(2));
    await closeTree(tester);
  });

  // #130 review (Ezra): a same-count swap on the web must show.
  testWidgets('stored receipts are checked online: one swapped on the web shows, '
      'and the old one\'s file goes', (tester) async {
    final (db, fake) = await setUpDb();
    addTearDown(db.close);
    await tester.runAsync(() async {
      await db.cacheExpenseDocuments('g1', 'e1', docs());
      await db.saveReceiptFile(ReceiptFilesCompanion.insert(
          url: receipts[0]['url'] as String,
          groupId: 'g1',
          fileName: 'old.img',
          bytes: 1,
          kind: ReceiptFileKind.viewing,
          lastUsedAt: DateTime(2026, 9, 27)));
    });
    final swapped = jsonEncode([
      {
        'result': {
          'data': {
            'json': {
              'expense': {
                'id': 'e1',
                'title': 'Coffee',
                'amount': 1860,
                'paidBy': {'id': 'bea'},
                'paidFor': [
                  {'participantId': 'alex', 'shares': 1},
                ],
                'expenseDate': '2026-09-23T00:00:00.000Z',
                'documents': [
                  {'id': 'd3', 'url': 'https://bucket.test/replacement.jpg', 'width': 600, 'height': 900},
                  receipts[1],
                ],
              },
            },
          },
        },
      },
    ]);
    final s = server([() async => http.Response(swapped, 200)]);
    await openSheet(tester, db, s.client);

    expect(s.gets.single, 1);
    expect(fake.loaded, contains('https://bucket.test/replacement.jpg'));
    final stored = await tester.runAsync(() => db.watchExpenseDocuments('e1').first);
    expect(stored!.map((d) => d.id), ['d3', 'd2']);
    expect(await tester.runAsync(() => db.receiptFile(receipts[0]['url'] as String)), isNull);
    await closeTree(tester);
  });

  testWidgets('offline, receipts not read yet are placeholders "available when online", '
      'and load once back online', (tester) async {
    final (db, _) = await setUpDb();
    addTearDown(db.close);
    // Offline from the start: buffered until the sheet listens.
    final online = StreamController<bool>()..add(false);
    addTearDown(online.close);
    final s = server([ok]);
    await openSheet(tester, db, s.client, connectivity: online.stream);

    expect(s.gets.single, 0);
    expect(find.byIcon(Icons.cloud_off_outlined), findsNWidgets(2));
    expect(find.text('Available when online'), findsOneWidget);

    online.add(true);
    await tester.pumpAndSettle();
    expect(s.gets.single, 1);
    expect(receiptImages(), findsNWidgets(2));
    expect(find.text('Available when online'), findsNothing);
    await closeTree(tester);
  });

  testWidgets('a connection failure reading them is "available when online", '
      'and they\'re read again once back online (#119)', (tester) async {
    final (db, _) = await setUpDb();
    addTearDown(db.close);
    final online = StreamController<bool>.broadcast();
    addTearDown(online.close);
    final s = server([() async => throw http.ClientException('offline'), ok]);
    await openSheet(tester, db, s.client, connectivity: online.stream);

    expect(s.gets.single, 1);
    expect(find.text('Available when online'), findsOneWidget);
    expect(find.text('Tap for details'), findsNothing);

    online.add(true);
    await tester.pumpAndSettle();
    expect(s.gets.single, 2);
    expect(receiptImages(), findsNWidgets(2));
    await closeTree(tester);
  });

  testWidgets('an unexpected failure reading them says so, with details (#119)', (tester) async {
    final (db, _) = await setUpDb();
    addTearDown(db.close);
    final s = server([() async => http.Response('boom', 500)]);
    await openSheet(tester, db, s.client);

    expect(find.text("Couldn't load this receipt."), findsOneWidget);
    expect(find.text('Tap for details'), findsOneWidget);
    await closeTree(tester);
  });

  testWidgets('a receipt that can\'t be downloaded offline waits, and loads back online',
      (tester) async {
    final (db, fake) = await setUpDb();
    addTearDown(db.close);
    await tester.runAsync(() => db.cacheExpenseDocuments('g1', 'e1', docs()));
    fake.error = http.ClientException('offline');
    final online = StreamController<bool>.broadcast();
    addTearDown(online.close);
    final s = server([ok]);
    await openSheet(tester, db, s.client, connectivity: online.stream);

    expect(find.byIcon(Icons.cloud_off_outlined), findsNWidgets(2));
    expect(find.text('Available when online'), findsOneWidget);

    fake.error = null;
    online.add(true);
    await tester.pumpAndSettle();
    expect(receiptImages(), findsNWidgets(2));
    expect(find.text('Available when online'), findsNothing);
    await closeTree(tester);
  });

  testWidgets('tapping a receipt opens it full screen', (tester) async {
    final (db, _) = await setUpDb();
    addTearDown(db.close);
    await tester.runAsync(() => db.cacheExpenseDocuments('g1', 'e1', docs()));
    await openSheet(tester, db, server([ok]).client);

    await tester.tap(receiptImages().at(1));
    await tester.pumpAndSettle();

    expect(find.text('Receipt 2 of 2'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await closeTree(tester);
  });

  testWidgets('an expense added here and not synced yet shows its receipts, without the server',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    ReceiptCache.use(_FakeReceipts(db));
    await tester.runAsync(() => db.insertPending(Expense(
          id: 'e1',
          groupId: 'g1',
          title: 'Coffee',
          amountCents: 1860,
          paidBy: 'bea',
          paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
          date: DateTime(2026, 9, 23),
          pending: true,
          documents: docs(),
          documentCount: 2,
        )));
    final s = server([ok]);
    await openSheet(tester, db, s.client);

    expect(s.gets.single, 0);
    expect(receiptImages(), findsNWidgets(2));
    await closeTree(tester);
  });
}
