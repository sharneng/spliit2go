import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/expense_screen.dart';
import 'package:spliit2go/services/receipt_cache.dart';
import 'package:spliit2go/services/receipt_photo.dart';
import 'package:spliit2go/services/receipt_scanner.dart';
import 'package:spliit2go/services/receipt_text.dart';
import 'package:spliit2go/sync/outbox.dart';
import 'package:spliit2go/utils/date_format.dart';

import '../support/error_log.dart';

/// The Document Scanner and text recognition, without the platform.
class _FakeScanner implements ReceiptScanner {
  @override
  bool isSupported = true;

  /// Throws [ReceiptScannerUnavailable] from scanDocument.
  bool unavailable = false;
  Uint8List? page = Uint8List.fromList([7, 7, 7]);

  /// The receipt's text, one line per row.
  List<String> text = [];
  Object? error;

  /// Holds recognition until completed.
  Completer<void>? hold;
  final read = <Uint8List>[];
  var prepared = 0;

  @override
  Future<void> prepare() async => prepared++;

  @override
  Future<Uint8List?> scanDocument() async {
    if (unavailable) throw const ReceiptScannerUnavailable('not downloaded');
    return page;
  }

  @override
  Future<List<ReceiptTextBlock>> recognizeText(Uint8List jpeg) async {
    read.add(jpeg);
    await hold?.future;
    if (error case final error?) throw error;
    return [
      for (final (i, line) in text.indexed)
        ReceiptTextBlock(text: line, minX: 0.05, midY: 0.05 + i * 0.05, height: 0.03),
    ];
  }
}

class _FakePicker implements ReceiptPhotoPicker {
  final sources = <ReceiptSource>[];

  @override
  Future<Uint8List?> pick(ReceiptSource source) async {
    sources.add(source);
    return Uint8List.fromList([5, 5, 5]);
  }
}

/// No file system in widget tests.
class _FakeReceipts extends ReceiptCache {
  _FakeReceipts(super.db);

  @override
  Future<File> store(String url,
          {required String groupId, required List<int> bytes, ReceiptFileKind kind = ReceiptFileKind.viewing}) async =>
      File('/receipts/stored');

  @override
  Future<File> load(String url, {required String groupId}) async => File('/receipts/x');
}

// Issue #125: Scan receipt fills in the new expense form, and only what
// the user hasn't.
void main() {
  const paris = Group(
    id: 'g1',
    name: 'Paris',
    currency: '€',
    currencyCode: 'EUR',
    participants: [Participant(id: 'alex', name: 'Alex'), Participant(id: 'bea', name: 'Bea')],
  );

  final yesterday = DateTime.now().subtract(const Duration(days: 1));
  final printedDate = '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-'
      '${yesterday.day.toString().padLeft(2, '0')}';
  final receipt = [
    'CAFÉ DU COIN',
    '12 rue de la Paix',
    '$printedDate  13:42',
    'Café   3,50',
    'Sandwich   12,45',
    'TOTAL   15,95',
  ];

  late List<http.Request> uploads;
  SpliitClient server() {
    uploads = [];
    return SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        if (req.url.path == '/api/s3-upload') {
          return http.Response(
              jsonEncode({
                'key': 'document-${uploads.length}.jpg',
                'bucket': 'spliit',
                'region': 'us-east-1',
                'url': 'https://spliit.s3.amazonaws.com/document.jpg?sig',
              }),
              200);
        }
        if (req.method == 'PUT') {
          uploads.add(req);
          return http.Response('', 200);
        }
        throw http.ClientException('offline'); // categories: the seeded list
      }),
    );
  }

  Future<void> openForm(WidgetTester tester, AppDatabase db, _FakeScanner scanner,
      {_FakePicker? picker, Expense? existing}) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => db.cacheGroup(paris));
    ReceiptCache.use(_FakeReceipts(db));
    final client = server();
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ExpenseScreen(
        client: client,
        db: db,
        outbox: Outbox(db, client, groupId: 'g1'),
        group: paris,
        existingExpense: existing,
        receiptPicker: picker ?? _FakePicker(),
        prepareReceipt: (bytes) async => PreparedReceipt(bytes, 600, 900),
        receiptScanner: scanner,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> scan(WidgetTester tester) async {
    await tester.tap(find.text('Scan receipt'));
    await tester.pumpAndSettle();
  }

  String field(WidgetTester tester, String label) =>
      tester.widget<TextFormField>(find.widgetWithText(TextFormField, label)).controller!.text;

  Future<void> closeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  AppDatabase newDb() {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  testWidgets('a scan fills in the empty form, and the photo is kept with the expense', (tester) async {
    final db = newDb();
    final scanner = _FakeScanner()..text = receipt;
    await openForm(tester, db, scanner);
    expect(find.textContaining('Fills in what it can read'), findsOneWidget);

    await scan(tester);

    expect(scanner.read, [Uint8List.fromList([7, 7, 7])]);
    expect(field(tester, 'Title'), 'Café Du Coin');
    expect(field(tester, 'Amount'), '15.95');
    expect(find.text(formatDate(DateTime(yesterday.year, yesterday.month, yesterday.day), locale: const Locale('en'))),
        findsOneWidget);
    expect(find.text('Dining Out'), findsOneWidget);
    expect(find.text('Filled in from the receipt. Check it before saving.'), findsOneWidget);
    expect(find.textContaining('Receipt:'), findsNothing);
    // The photo went up like any other receipt.
    expect(uploads, hasLength(1));
    await closeTree(tester);
  });

  testWidgets('a scan finishing after the user typed leaves what they typed', (tester) async {
    final db = newDb();
    final scanner = _FakeScanner()
      ..text = receipt
      ..hold = Completer();
    await openForm(tester, db, scanner);

    // Not settled: the button spins while the receipt is read.
    await tester.tap(find.text('Scan receipt'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Reading the receipt…'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Lunch');
    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '20');
    scanner.hold!.complete();
    await tester.pumpAndSettle();

    expect(field(tester, 'Title'), 'Lunch');
    expect(field(tester, 'Amount'), '20');
    expect(find.text('Receipt: Café Du Coin'), findsOneWidget);
    expect(find.text('Receipt: 15,95'), findsOneWidget);
    // The fields the user didn't touch are still filled in.
    expect(find.text('Dining Out'), findsOneWidget);
    expect(find.text('Filled in from the receipt. Check it before saving.'), findsOneWidget);
    await closeTree(tester);
  });

  testWidgets('a date and category the user picked are left alone', (tester) async {
    final db = newDb();
    final scanner = _FakeScanner()..text = receipt;
    await openForm(tester, db, scanner);

    await tester.tap(find.text('General'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Groceries'));
    await tester.pumpAndSettle();
    await scan(tester);

    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('Receipt: Dining Out'), findsOneWidget);
    await closeTree(tester);
  });

  testWidgets('a total in another currency is shown, not put in the amount', (tester) async {
    final db = newDb();
    final scanner = _FakeScanner()..text = ['THE CORNER PUB', 'Amount Due   \$19.62'];
    await openForm(tester, db, scanner);

    await scan(tester);

    expect(field(tester, 'Title'), 'The Corner Pub');
    expect(field(tester, 'Amount'), isEmpty);
    expect(find.text('Receipt: \$ 19.62'), findsOneWidget);
    await closeTree(tester);
  });

  testWidgets('a date that reads two ways is shown, not set', (tester) async {
    final db = newDb();
    // 1 February or 2 January: both within the last two years.
    final year = DateTime.now().year - 1;
    final printed = '01/02/$year';
    final scanner = _FakeScanner()..text = ['CHEZ NOUS', printed, 'TOTAL 8,00'];
    await openForm(tester, db, scanner);
    final before = tester.widget<InputDecorator>(find.widgetWithText(InputDecorator, 'Date'));

    await scan(tester);

    expect(find.text('Receipt: $printed'), findsOneWidget);
    expect(tester.widget<InputDecorator>(find.widgetWithText(InputDecorator, 'Date')).child.toString(),
        before.child.toString());
    await closeTree(tester);
  });

  testWidgets('a photo with nothing readable says so, and is kept', (tester) async {
    final db = newDb();
    await openForm(tester, db, _FakeScanner());

    await scan(tester);

    expect(find.text('Nothing on that photo could be read. The photo is kept.'), findsOneWidget);
    expect(uploads, hasLength(1));
    await closeTree(tester);
  });

  testWidgets('without the Document Scanner, the camera or library is used (#125)', (tester) async {
    final db = newDb();
    final picker = _FakePicker();
    final scanner = _FakeScanner()
      ..unavailable = true
      ..text = receipt;
    await openForm(tester, db, scanner, picker: picker);

    await scan(tester);
    await tester.tap(find.text('Take photo'));
    await tester.pumpAndSettle();

    expect(picker.sources, [ReceiptSource.camera]);
    expect(scanner.read, [Uint8List.fromList([5, 5, 5])]);
    expect(field(tester, 'Title'), 'Café Du Coin');
    await closeTree(tester);
  });

  testWidgets('cancelling the scanner changes nothing', (tester) async {
    final db = newDb();
    final scanner = _FakeScanner()..page = null;
    await openForm(tester, db, scanner);

    await scan(tester);

    expect(scanner.read, isEmpty);
    expect(uploads, isEmpty);
    expect(find.textContaining('Fills in what it can read'), findsOneWidget);
    await closeTree(tester);
  });

  testWidgets('recognition failing is reported, and the photo is kept', (tester) async {
    expectUnexpectedError<PlatformException>('Reading a receipt');
    final db = newDb();
    final scanner = _FakeScanner()..error = PlatformException(code: 'recognize', message: 'model missing');
    await openForm(tester, db, scanner);

    await scan(tester);

    expect(find.text("Couldn't read the receipt. The photo is kept."), findsOneWidget);
    expect(uploads, hasLength(1));
    await closeTree(tester);
  });

  testWidgets('opening the form has the scanner downloaded ahead of the first scan', (tester) async {
    final db = newDb();
    final scanner = _FakeScanner();
    await openForm(tester, db, scanner);
    expect(scanner.prepared, 1);
    await closeTree(tester);
  });

  testWidgets('not offered when editing, or where receipts aren\'t read', (tester) async {
    final db = newDb();
    final unsupported = _FakeScanner()..isSupported = false;
    await openForm(tester, db, unsupported);
    expect(find.text('Scan receipt'), findsNothing);
    expect(unsupported.prepared, 0);
    await closeTree(tester);

    final existing = Expense(
      id: 'e1',
      groupId: 'g1',
      title: 'Lunch',
      amountCents: 1000,
      paidBy: 'alex',
      paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
      date: DateTime(2026, 9, 1),
    );
    await openForm(tester, db, _FakeScanner(), existing: existing);
    expect(find.text('Scan receipt'), findsNothing);
    await closeTree(tester);
  });
}
