import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:spliit2go/screens/expense_form/currency_card.dart';
import 'package:spliit2go/screens/expense_screen.dart';
import 'package:spliit2go/services/receipt_cache.dart';
import 'package:spliit2go/services/receipt_photo.dart';
import 'package:spliit2go/sync/outbox.dart';

import '../support/error_log.dart';

/// Hands back [photo] (null: the user cancelled), or throws [error].
class _FakePicker implements ReceiptPhotoPicker {
  Uint8List? photo = Uint8List.fromList([1, 2, 3]);
  Object? error;
  final sources = <ReceiptSource>[];

  @override
  Future<Uint8List?> pick(ReceiptSource source) async {
    sources.add(source);
    if (error case final error?) throw error;
    return photo;
  }
}

/// No file system in widget tests: stores are recorded, loads fail.
class _FakeReceipts extends ReceiptCache {
  _FakeReceipts(super.db);
  final stored = <String>[];
  final kinds = <ReceiptFileKind>[];

  /// Photos kept for later (#124), as their file names.
  final pending = <String>[];

  @override
  Future<File> store(String url,
      {required String groupId,
      required List<int> bytes,
      ReceiptFileKind kind = ReceiptFileKind.viewing}) async {
    stored.add(url);
    kinds.add(kind);
    return File('/receipts/stored');
  }

  @override
  Future<void> storePending(
      List<List<int>> photos, Future<void> Function(List<String> fileNames) register) async {
    final names = [for (var i = 0; i < photos.length; i++) 'pending-${pending.length + i}.img'];
    await register(names);
    pending.addAll(names);
  }

  @override
  Future<File> load(String url, {required String groupId}) async => File('/receipts/x');
}

// Issue #123: attaching receipts in the expense form.
void main() {
  const banff = Group(
    id: 'g1',
    name: 'Banff Trip',
    currency: '\$',
    participants: [Participant(id: 'alex', name: 'Alex'), Participant(id: 'bea', name: 'Bea')],
  );

  Future<PreparedReceipt> prepare(Uint8List bytes) async {
    if (bytes.first == 0) throw UnreadableReceiptPhotoException();
    return PreparedReceipt(bytes, 600, 900);
  }

  /// A server whose upload route answers [signs] in turn (the last repeats).
  ({SpliitClient client, List<http.Request> requests}) server(
      {List<Future<http.Response> Function()>? signs}) {
    final requests = <http.Request>[];
    var signCount = 0;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        requests.add(req);
        final path = req.url.path;
        if (path == '/api/s3-upload') {
          final all = signs ?? [];
          final i = signCount++;
          if (all.isNotEmpty) {
            final r = await all[i < all.length ? i : all.length - 1]();
            if (r.statusCode != 200) return r;
          }
          return http.Response(
              jsonEncode({
                'key': 'document-$i.jpg',
                'bucket': 'spliit',
                'region': 'us-east-1',
                'url': 'https://spliit.s3.amazonaws.com/document-$i.jpg?sig',
              }),
              200);
        }
        if (req.method == 'PUT') return http.Response('', 200);
        if (path.endsWith('groups.expenses.update')) {
          return http.Response('[{"result":{"data":{"json":{"expenseId":"e1"}}}}]', 200);
        }
        throw http.ClientException('offline'); // categories: not needed here
      }),
    );
    return (client: client, requests: requests);
  }

  Future<http.Response> signFails() async => http.Response('', 500);
  Future<http.Response> offline() async => throw http.ClientException('offline');

  /// Opens the form from a stub home, so leaving it can be seen.
  Future<List<bool?>> openForm(WidgetTester tester, AppDatabase db, SpliitClient client,
      _FakePicker picker,
      {Expense? existing, Future<bool> Function()? openSettings}) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => db.cacheGroup(banff));
    ReceiptCache.use(_FakeReceipts(db));
    final popped = <bool?>[];
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => popped.add(await Navigator.of(context).push<bool>(
              MaterialPageRoute(
                builder: (_) => ExpenseScreen(
                  client: client,
                  db: db,
                  outbox: Outbox(db, client, groupId: 'g1'),
                  group: banff,
                  existingExpense: existing,
                  receiptPicker: picker,
                  prepareReceipt: prepare,
                  openSettings: openSettings,
                ),
              ),
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return popped;
  }

  Future<void> addReceipt(WidgetTester tester, {String from = 'Choose from library'}) async {
    await tester.tap(find.text('Add receipt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(from));
    await tester.pumpAndSettle();
  }

  Future<void> fillAndSave(WidgetTester tester, {bool fill = true}) async {
    if (fill) {
      await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Coffee');
      await tester.enterText(find.byKey(CurrencyCard.amountFieldKey), '18.60');
    }
    final save = find.byTooltip('Save');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
  }

  Future<void> closeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('a photo is uploaded as it\'s added, and a new expense saves with it', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final s = server();
    final picker = _FakePicker();
    final popped = await openForm(tester, db, s.client, picker);

    await addReceipt(tester, from: 'Take photo');
    expect(picker.sources, [ReceiptSource.camera]);
    expect(s.requests.where((r) => r.method == 'PUT'), hasLength(1));
    expect(find.text('Not uploaded'), findsNothing);
    expect((ReceiptCache.of(db) as _FakeReceipts).stored,
        ['https://spliit.s3.us-east-1.amazonaws.com/document-0.jpg']);

    await fillAndSave(tester);

    expect(popped, [true]);
    final row = (await tester.runAsync(() => db.pendingExpensesForGroup('g1')))!.single;
    final saved = db.rowToExpense(row);
    expect(saved.documentCount, 1);
    final doc = saved.documents.single;
    expect((doc.url, doc.width, doc.height),
        ('https://spliit.s3.us-east-1.amazonaws.com/document-0.jpg', 600, 900));
    expect(doc.id, hasLength(21));
    await closeTree(tester);
  });

  testWidgets('a failed upload stays, "Not uploaded", and can be retried (#119)', (tester) async {
    expectUnexpectedError<SpliitApiException>('Uploading a receipt');
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final s = server(signs: [signFails, () async => http.Response('', 200)]);
    final popped = await openForm(tester, db, s.client, _FakePicker());

    await addReceipt(tester);
    expect(find.text('Not uploaded'), findsOneWidget);
    // Possibly an instance without storage, but never assumed: details.
    expect(find.textContaining('This server may not store receipts'), findsOneWidget);
    expect(find.text('Tap for details'), findsOneWidget);

    // ↻, since a tap opens it (#148).
    await tester.tap(find.byTooltip('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Not uploaded'), findsNothing);
    expect(find.byTooltip('Retry'), findsNothing);

    await fillAndSave(tester);
    expect(popped, [true]);
    final row = (await tester.runAsync(() => db.pendingExpensesForGroup('g1')))!.single;
    expect(db.rowToExpense(row).documents, hasLength(1));
    await closeTree(tester);
  });

  // #124: a photo that didn't upload used to block Save.
  testWidgets('a photo that didn\'t upload doesn\'t hold Save back: it\'s kept with the new expense',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final popped = await openForm(tester, db, server(signs: [offline]).client, _FakePicker());

    await addReceipt(tester);
    expect(find.text('Not uploaded'), findsOneWidget);
    expect(find.textContaining('You can still save'), findsOneWidget);
    await fillAndSave(tester);

    expect(popped, [true]);
    final row = (await tester.runAsync(() => db.pendingExpensesForGroup('g1')))!.single;
    expect(db.rowToExpense(row).documents, isEmpty);
    final kept = (await tester.runAsync(() => db.attachmentsFor(row.id)))!.single;
    expect((kept.state, kept.width, kept.height), (AttachmentState.local, 600, 900));
    expect((ReceiptCache.of(db) as _FakeReceipts).pending, [kept.fileName]);
    await closeTree(tester);
  });

  testWidgets('editing: a photo that didn\'t upload holds Save until it\'s uploaded or removed',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final s = server(signs: [offline]);
    final popped = await openForm(tester, db, s.client, _FakePicker(),
        existing: Expense(
          id: 'e1',
          groupId: 'g1',
          title: 'Coffee',
          amountCents: 1860,
          paidBy: 'bea',
          paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
          date: DateTime(2026, 9, 23),
        ));

    await addReceipt(tester);
    // Edits are online-only: nothing is kept for later.
    expect(find.textContaining('You can still save'), findsNothing);
    expect(find.textContaining("couldn't reach the server. Tap ↻ on it to try again"), findsOneWidget);
    await fillAndSave(tester, fill: false);

    expect(popped, isEmpty);
    expect(find.text("Wait for receipts to upload, or remove the ones that weren't."), findsOneWidget);
    expect(s.requests.where((r) => r.url.path.endsWith('groups.expenses.update')), isEmpty);

    await tester.tap(find.byTooltip('Remove receipt'));
    await tester.pumpAndSettle();
    await fillAndSave(tester, fill: false);
    expect(popped, [true]);
    await closeTree(tester);
  });

  // #148: receipts open full screen from the form too.
  testWidgets('tapping a receipt opens them all full screen, at that one', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await openForm(tester, db, server().client, _FakePicker(),
        existing: Expense(
          id: 'e1',
          groupId: 'g1',
          title: 'Coffee',
          amountCents: 1860,
          paidBy: 'bea',
          paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
          date: DateTime(2026, 9, 23),
          documents: const [ExpenseDocument(id: 'd1', url: 'https://bucket.test/old.jpg', width: 600, height: 900)],
          documentCount: 1,
        ));
    await addReceipt(tester);
    Finder tile(String key) => find.byKey(key.startsWith('http') ? ValueKey(key) : ObjectKey(key));

    // The photo just added, from memory.
    await tester.tap(find.descendant(of: find.byType(Wrap), matching: find.byType(Image)).last);
    await tester.pumpAndSettle();
    expect(find.text('Receipt 2 of 2'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage), findsWidgets);
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();

    // The expense's own receipt.
    await tester.tap(tile('https://bucket.test/old.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('Receipt 1 of 2'), findsOneWidget);
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    await closeTree(tester);
  });

  testWidgets('a photo that didn\'t upload opens too, offline; ↻ retries it', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final s = server(signs: [offline, () async => http.Response('', 200)]);
    await openForm(tester, db, s.client, _FakePicker());
    await addReceipt(tester);
    int signs() => s.requests.where((r) => r.url.path == '/api/s3-upload').length;
    expect(find.text('Not uploaded'), findsOneWidget);
    expect(signs(), 1);

    await tester.tap(find.text('Not uploaded'));
    await tester.pumpAndSettle();
    expect(find.text('Receipt'), findsOneWidget);
    expect(signs(), 1);
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Not uploaded'), findsNothing);
    expect(signs(), 2);
    await closeTree(tester);
  });

  testWidgets('a photo this device uploaded is kept as a capture, not viewing cache', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await openForm(tester, db, server().client, _FakePicker());

    await addReceipt(tester);

    expect((ReceiptCache.of(db) as _FakeReceipts).kinds, [ReceiptFileKind.capture]);
    await closeTree(tester);
  });

  testWidgets('no connection: "couldn\'t reach the server", with no details', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await openForm(tester, db, server(signs: [offline]).client, _FakePicker());

    await addReceipt(tester);

    expect(find.textContaining("couldn't reach the server"), findsOneWidget);
    expect(find.text('Tap for details'), findsNothing);
    await closeTree(tester);
  });

  testWidgets('removing a photo that didn\'t upload lets the expense save without it',
      (tester) async {
    expectUnexpectedError<SpliitApiException>('Uploading a receipt');
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final popped = await openForm(tester, db, server(signs: [signFails]).client, _FakePicker());

    await addReceipt(tester);
    await tester.tap(find.byTooltip('Remove receipt'));
    await tester.pumpAndSettle();
    await fillAndSave(tester);

    expect(popped, [true]);
    final row = (await tester.runAsync(() => db.pendingExpensesForGroup('g1')))!.single;
    expect(db.rowToExpense(row).documents, isEmpty);
    await closeTree(tester);
  });

  testWidgets('leaving with a new photo asks first; Cancel stays, Discard leaves', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final popped = await openForm(tester, db, server().client, _FakePicker());
    await addReceipt(tester);

    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    expect(find.text("The receipts you added haven't been saved with this expense."), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(ExpenseScreen), findsOneWidget);

    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(ExpenseScreen), findsNothing);
    expect(popped, [null]);
    await closeTree(tester);
  });

  testWidgets('leaving without new photos doesn\'t ask', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await openForm(tester, db, server().client, _FakePicker());

    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(find.byType(ExpenseScreen), findsNothing);
    await closeTree(tester);
  });

  testWidgets('cancelling the picker adds nothing; an unreadable photo says so', (tester) async {
    expectUnexpectedError<UnreadableReceiptPhotoException>('Adding a receipt photo');
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final s = server();
    final picker = _FakePicker()..photo = null;
    await openForm(tester, db, s.client, picker);

    await addReceipt(tester);
    expect(s.requests.where((r) => r.url.path == '/api/s3-upload'), isEmpty);

    picker.photo = Uint8List.fromList([0]);
    await addReceipt(tester);
    expect(find.text("Couldn't add this photo."), findsOneWidget);
    expect(s.requests.where((r) => r.url.path == '/api/s3-upload'), isEmpty);
    await closeTree(tester);
  });

  // Refused when the phone asked, or turned off since: explained in a
  // dialog, with a way to Settings on the iPhone and a warning that it
  // restarts the app (#171), and not reported as an error.
  testWidgets('camera access off: it says so, and Settings opens the app\'s settings', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final s = server();
    final picker = _FakePicker()..error = const ReceiptAccessOff(ReceiptSource.camera);
    var opened = 0;
    await openForm(tester, db, s.client, picker, openSettings: () async {
      opened++;
      return true;
    });

    await addReceipt(tester, from: 'Take photo');

    expect(find.text('Camera access is off for Spliit2Go.'), findsOneWidget);
    expect(find.text("Couldn't add this photo."), findsNothing);
    expect(find.text('Details'), findsNothing);
    expect(find.textContaining('restarts Spliit2Go'), findsOneWidget);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.text('Camera access is off for Spliit2Go.'), findsNothing);
    expect(loggedUnexpectedErrors, isEmpty);
    expect(s.requests.where((r) => r.url.path == '/api/s3-upload'), isEmpty);
    await closeTree(tester);
  });

  testWidgets('photo access off, where there\'s no settings link: only the message', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final s = server();
    final picker = _FakePicker()..error = const ReceiptAccessOff(ReceiptSource.library);
    await openForm(tester, db, s.client, picker);

    await addReceipt(tester);

    expect(find.text('Photo access is off for Spliit2Go.'), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
    expect(find.textContaining('restarts Spliit2Go'), findsNothing);
    expect(loggedUnexpectedErrors, isEmpty);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Photo access is off for Spliit2Go.'), findsNothing);
    await closeTree(tester);
  });

  testWidgets('camera access off: Cancel closes the message, without Settings', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final s = server();
    final picker = _FakePicker()..error = const ReceiptAccessOff(ReceiptSource.camera);
    var opened = 0;
    await openForm(tester, db, s.client, picker, openSettings: () async {
      opened++;
      return true;
    });

    await addReceipt(tester, from: 'Take photo');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Camera access is off for Spliit2Go.'), findsNothing);
    expect(opened, 0);
    await closeTree(tester);
  });

  testWidgets('editing: removing one receipt and adding another sends the rest, ids kept',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final s = server();
    const d1 = ExpenseDocument(id: 'd1', url: 'https://b.test/1.jpg', width: 600, height: 900);
    const d2 = ExpenseDocument(id: 'd2', url: 'https://b.test/2.jpg', width: 900, height: 600);
    final existing = Expense(
      id: 'e1',
      groupId: 'g1',
      title: 'Coffee',
      amountCents: 1860,
      paidBy: 'bea',
      paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
      date: DateTime(2026, 9, 23),
      documents: const [d1, d2],
      documentCount: 2,
    );
    final popped = await openForm(tester, db, s.client, _FakePicker(), existing: existing);

    await tester.tap(find.byTooltip('Remove receipt').first);
    await tester.pumpAndSettle();
    await addReceipt(tester);
    await fillAndSave(tester, fill: false);

    expect(popped, [true]);
    final update = s.requests.lastWhere((r) => r.url.path.endsWith('groups.expenses.update'));
    final sent = (jsonDecode(update.body)['0']['json']['expenseFormValues']['documents'] as List)
        .cast<Map<String, dynamic>>();
    expect(sent.first, d2.toJson());
    expect(sent.last['url'], 'https://spliit.s3.us-east-1.amazonaws.com/document-0.jpg');
    expect(sent, hasLength(2));
    // Update keeps the ids sent, so they're stored as the server's.
    final stored = await tester.runAsync(() => db.watchExpenseDocuments('e1').first);
    expect(stored!.map((d) => d.id), [d2.id, sent.last['id']]);
    await closeTree(tester);
  });
}
