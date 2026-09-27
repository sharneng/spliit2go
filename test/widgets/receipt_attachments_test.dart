import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/services/receipt_cache.dart';
import 'package:spliit2go/services/receipt_photo.dart';
import 'package:spliit2go/widgets/receipt_attachments.dart';

import '../support/error_log.dart';

// #131 review (Ezra): discarding the form stops anything not yet started.
void main() {
  test('a photo still being prepared when the form is discarded is never uploaded', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    var signs = 0;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        if (req.url.path == '/api/s3-upload') signs++;
        return http.Response('', 500);
      }),
    );
    final prepared = Completer<PreparedReceipt>();
    final controller = ReceiptAttachmentsController(
      client: client,
      cache: ReceiptCache(db),
      groupId: 'g1',
      prepare: (_) => prepared.future,
    );

    final adding = controller.add(Uint8List.fromList([1]));
    controller.dispose(); // Discard confirmed while preparing.
    prepared.complete(PreparedReceipt(Uint8List.fromList([1]), 600, 900));
    await adding;

    expect(signs, 0);
    expect(controller.added, isEmpty);
  });

  test('a retry after the form is discarded doesn\'t upload either', () async {
    expectUnexpectedError<SpliitApiException>('Uploading a receipt');
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    var signs = 0;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        if (req.url.path == '/api/s3-upload') signs++;
        return http.Response('', 500);
      }),
    );
    final controller = ReceiptAttachmentsController(
      client: client,
      cache: ReceiptCache(db),
      groupId: 'g1',
      prepare: (bytes) async => PreparedReceipt(bytes, 600, 900),
    );
    await controller.add(Uint8List.fromList([1]));
    expect((signs, controller.added.single.state), (1, ReceiptUpload.failed));

    controller.dispose();
    await controller.retry(controller.added.single);

    expect(signs, 1);
  });
}
