import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/services/receipt_scanner.dart';
import 'package:spliit2go/services/receipt_text.dart';

/// Answers prepare with [installed] in turn (the last repeats).
class _Scanner implements ReceiptScanner {
  _Scanner(this.installed);
  final List<bool> installed;
  var prepared = 0;

  @override
  bool isSupported = true;

  @override
  Future<bool> prepare() async => installed[prepared++ < installed.length ? prepared - 1 : installed.length - 1];

  @override
  Future<Uint8List?> scanDocument() => throw UnimplementedError();

  @override
  Future<List<ReceiptTextBlock>> recognizeText(Uint8List jpeg) => throw UnimplementedError();
}

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

  group('warming up', () {
    late StreamController<List<ConnectivityResult>> network;
    setUp(() => network = StreamController());
    // Not awaited: with no listener (the iPhone), close never completes.
    tearDown(() => unawaited(network.close()));

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('at launch, and whenever a connection comes back', () async {
      final scanner = _Scanner([false]);
      ReceiptScannerWarmup(scanner, connectivityChanges: network.stream).start();
      await settle();
      expect(scanner.prepared, 1);

      network.add([ConnectivityResult.none]);
      await settle();
      expect(scanner.prepared, 1);

      network.add([ConnectivityResult.wifi]);
      await settle();
      expect(scanner.prepared, 2);
    });

    test('stops listening once the scanner is installed', () async {
      final scanner = _Scanner([false, true]);
      final warmup = ReceiptScannerWarmup(scanner, connectivityChanges: network.stream)..start();
      await settle();
      expect(warmup.listening, isTrue);

      network.add([ConnectivityResult.mobile]);
      await settle();
      expect((scanner.prepared, warmup.listening), (2, false));

      network.add([ConnectivityResult.wifi]);
      await settle();
      expect(scanner.prepared, 2);
    });

    test('already installed at launch: nothing more', () async {
      final scanner = _Scanner([true]);
      final warmup = ReceiptScannerWarmup(scanner, connectivityChanges: network.stream)..start();
      await settle();
      expect((scanner.prepared, warmup.listening), (1, false));
    });

    test('not on the iPhone (#126): no check, no listening', () async {
      final scanner = _Scanner([false])..isSupported = false;
      final warmup = ReceiptScannerWarmup(scanner, connectivityChanges: network.stream)..start();
      await settle();
      expect((scanner.prepared, warmup.listening, network.hasListener), (0, false, false));
    });
  });
}
