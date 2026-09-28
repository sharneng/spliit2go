import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/services/receipt_scanner.dart';

// Issue #125: the Document Scanner is downloaded ahead of the first scan,
// only while online (Kenneth).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.sharneng.spliit2go/receipt_scan');
  late List<String> calls;
  Object? failWith;

  setUp(() {
    calls = [];
    failWith = null;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (failWith case final e?) throw e;
      return false;
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  PlatformReceiptScanner scanner(List<ConnectivityResult> network) =>
      PlatformReceiptScanner(connectivity: () async => network);

  test('online, it asks for the scanner', () async {
    await scanner([ConnectivityResult.mobile]).prepare();
    expect(calls, ['prepareScanner']);
  });

  test('offline, it asks nothing', () async {
    await scanner([ConnectivityResult.none]).prepare();
    expect(calls, isEmpty);
  });

  test('it never throws: a scan falls back without the scanner', () async {
    failWith = PlatformException(code: 'error');
    await scanner([ConnectivityResult.wifi]).prepare();
    expect(calls, ['prepareScanner']);
  });

  test('not on the iPhone (#126)', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await scanner([ConnectivityResult.wifi]).prepare();
    expect(calls, isEmpty);
  });
}
