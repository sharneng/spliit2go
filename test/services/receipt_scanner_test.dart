import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/services/receipt_scanner.dart';
import 'package:spliit2go/services/receipt_text.dart';

/// Answers prepare with [installed] in turn (the last repeats).
class _Scanner implements ReceiptScanner {
  _Scanner(this.installed);
  final List<bool> installed;
  var prepared = 0;

  /// The downloadable models on the phone.
  final models = <ReceiptScript>{};

  /// Downloads asked for; each fails while [offline].
  final downloads = <ReceiptScript>[];
  bool offline = false;

  @override
  bool isSupported = true;

  @override
  bool scannerImportsPhotos = true;

  @override
  Future<bool> prepare() async => installed[prepared++ < installed.length ? prepared - 1 : installed.length - 1];

  @override
  Future<Uint8List?> scanDocument() => throw UnimplementedError();

  @override
  Future<List<ReceiptTextBlock>> recognizeText(Uint8List jpeg, {ReceiptScript script = ReceiptScript.latin}) =>
      throw UnimplementedError();

  @override
  Future<Set<ReceiptScript>> installedScripts() async => {ReceiptScript.latin, ...models};

  @override
  Future<void> installScript(ReceiptScript script) async {
    downloads.add(script);
    if (offline) throw ReceiptTextModelDownloadFailed(script, offline: true);
    models.add(script);
  }

  @override
  Future<void> removeScript(ReceiptScript script) async => models.remove(script);
}

// Issue #125: the Document Scanner is downloaded ahead of the first scan,
// only while online (Kenneth).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.sharneng.spliit2go/receipt_scan');
  late List<String> calls;
  late List<Object?> arguments;
  Object? failWith;
  Object? answer;

  /// Answers by method, over [answer].
  late Map<String, Object?> answers;

  setUp(() {
    calls = [];
    arguments = [];
    failWith = null;
    answer = false;
    answers = {};
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      arguments.add(call.arguments);
      if (failWith case final e? when !answers.containsKey(call.method)) throw e;
      return answers.containsKey(call.method) ? answers[call.method] : answer;
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

  // Issue #155: VisionKit and Vision are part of iOS.
  group('on the iPhone', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      SharedPreferences.setMockInitialValues({});
    });

    test('it scans, and the scanner is ready at once, offline too, asking nothing', () async {
      final iPhone = scanner([ConnectivityResult.none]);
      expect((iPhone.isSupported, await iPhone.prepare()), (true, true));
      expect(calls, isEmpty);
    });

    test('every language is built in: nothing to download or remove', () async {
      final iPhone = scanner([ConnectivityResult.none]);
      expect(ReceiptScript.values.where((s) => s.downloadable), isEmpty);
      expect(await iPhone.installedScripts(), ReceiptScript.values.toSet());
      await iPhone.installScript(ReceiptScript.japanese);
      await iPhone.removeScript(ReceiptScript.chinese);
      expect(calls, isEmpty);
      expect(await iPhone.installedScripts(), ReceiptScript.values.toSet());
    });

    test('scanning and reading go through the same channel as Android', () async {
      answers = {
        'scanDocument': Uint8List.fromList([1, 2]),
        'recognizeText': {
          'width': 100,
          'height': 200,
          'lines': [
            {'text': '合計', 'left': 10, 'top': 20, 'right': 40, 'bottom': 30, 'corners': [10, 20, 40, 20, 40, 30, 10, 30]},
          ],
        },
      };
      final iPhone = scanner([]);
      expect(await iPhone.scanDocument(), [1, 2]);
      final blocks = await iPhone.recognizeText(Uint8List(1), script: ReceiptScript.japanese);
      expect(calls, ['scanDocument', 'recognizeText']);
      expect((arguments.last as Map)['script'], 'japanese');
      expect(blocks.single.text, '合計');
    });

    test('no document camera (the simulator): the camera and library instead', () async {
      answers = {};
      failWith = PlatformException(code: 'unavailable');
      await expectLater(scanner([]).scanDocument(), throwsA(isA<ReceiptScannerUnavailable>()));
    });
  });

  // Issue #153: receipt languages. Play services is asked every time.
  group('receipt languages', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('what\'s installed is what Play services says, and Latin always', () async {
      answer = {'chinese': true, 'japanese': false};
      expect(await scanner([ConnectivityResult.wifi]).installedScripts(), {ReceiptScript.latin, ReceiptScript.chinese});
      expect(calls, ['textModels']);
    });

    test('a download asks for that model', () async {
      answers = {'textModels': <String, bool>{}, 'installTextModel': true};
      await scanner([ConnectivityResult.wifi]).installScript(ReceiptScript.japanese);
      expect(calls, ['textModels', 'installTextModel']);
      expect(arguments.last, {'script': 'japanese'});
    });

    test('offline, a download fails at once, asking Play services only what it has', () async {
      answer = <String, bool>{};
      await expectLater(scanner([ConnectivityResult.none]).installScript(ReceiptScript.chinese),
          throwsA(isA<ReceiptTextModelDownloadFailed>().having((e) => e.offline, 'offline', isTrue)));
      expect(calls, ['textModels']);
    });

    test('Play services failing it is a failed download', () async {
      answers = {'textModels': <String, bool>{}};
      failWith = PlatformException(code: 'install-failed', message: 'state 5');
      await expectLater(scanner([ConnectivityResult.wifi]).installScript(ReceiptScript.chinese),
          throwsA(isA<ReceiptTextModelDownloadFailed>().having((e) => e.offline, 'offline', isFalse)));
    });

    test('Latin is built in: nothing to download or remove', () async {
      await scanner([ConnectivityResult.wifi]).installScript(ReceiptScript.latin);
      await scanner([ConnectivityResult.wifi]).removeScript(ReceiptScript.latin);
      expect(calls, isEmpty);
    });

    test('removing tells Play services', () async {
      answer = null;
      await scanner([ConnectivityResult.wifi]).removeScript(ReceiptScript.chinese);
      expect(calls, ['removeTextModel']);
      expect(arguments, [{'script': 'chinese'}]);
    });

    // Seen on the emulator: Play services frees a released model later, and
    // says it's installed until then.
    test('removed stays removed while Play services still has it, until downloaded again', () async {
      final phone = scanner([ConnectivityResult.wifi]);
      answer = null;
      await phone.removeScript(ReceiptScript.chinese);
      answer = {'chinese': true, 'japanese': true};
      expect(await phone.installedScripts(), {ReceiptScript.latin, ReceiptScript.japanese});
      calls.clear();

      // Still there: shown again, with no install asked of Play services,
      // offline too.
      final offline = PlatformReceiptScanner(connectivity: () async => [ConnectivityResult.none]);
      await offline.installScript(ReceiptScript.chinese);
      expect(calls.where((c) => c == 'installTextModel'), isEmpty);
      expect(await phone.installedScripts(), ReceiptScript.values.toSet());
    });

    test('reading asks for the picked language; without its model, it says so', () async {
      answer = {'width': 100, 'height': 100, 'lines': <Object>[]};
      await scanner([]).recognizeText(Uint8List(1), script: ReceiptScript.japanese);
      expect((arguments.single as Map)['script'], 'japanese');

      failWith = PlatformException(code: 'model-missing');
      await expectLater(scanner([]).recognizeText(Uint8List(1), script: ReceiptScript.chinese),
          throwsA(isA<ReceiptTextModelMissing>().having((e) => e.script, 'script', ReceiptScript.chinese)));
    });

    test('the phone\'s language: Chinese and Japanese are downloaded, Latin ones need nothing', () {
      expect([for (final l in ['zh', 'ja', 'en', 'fr', 'ko']) ReceiptScript.forLanguage(l)],
          [ReceiptScript.chinese, ReceiptScript.japanese, null, null, null]);
    });
  });

  group('warming up', () {
    late StreamController<List<ConnectivityResult>> network;
    setUp(() {
      network = StreamController();
      SharedPreferences.setMockInitialValues({});
    });
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

    group('the phone\'s language (#153)', () {
      test('its model is downloaded once, with the scanner', () async {
        final scanner = _Scanner([true]);
        final warmup =
            ReceiptScannerWarmup(scanner, connectivityChanges: network.stream, phoneScript: ReceiptScript.japanese)
              ..start();
        await settle();
        expect(scanner.downloads, [ReceiptScript.japanese]);
        expect(scanner.models, {ReceiptScript.japanese});
        expect(warmup.listening, isFalse);
      });

      test('offline at launch: downloaded when a connection comes, and listening until then', () async {
        final scanner = _Scanner([true])..offline = true;
        final warmup =
            ReceiptScannerWarmup(scanner, connectivityChanges: network.stream, phoneScript: ReceiptScript.chinese)
              ..start();
        await settle();
        expect(scanner.models, isEmpty);
        expect(warmup.listening, isTrue);

        scanner.offline = false;
        network.add([ConnectivityResult.wifi]);
        await settle();
        expect(scanner.models, {ReceiptScript.chinese});
        expect(warmup.listening, isFalse);
      });

      test('once only: removed afterwards, it isn\'t downloaded again', () async {
        final scanner = _Scanner([true]);
        ReceiptScannerWarmup(scanner, connectivityChanges: network.stream, phoneScript: ReceiptScript.chinese).start();
        await settle();
        await scanner.removeScript(ReceiptScript.chinese);

        // The next launch.
        ReceiptScannerWarmup(scanner, connectivityChanges: StreamController<List<ConnectivityResult>>().stream,
                phoneScript: ReceiptScript.chinese)
            .start();
        await settle();
        expect(scanner.downloads, [ReceiptScript.chinese]);
        expect(scanner.models, isEmpty);
      });

      test('already there (another app asked for it): nothing to download', () async {
        final scanner = _Scanner([true])..models.add(ReceiptScript.chinese);
        final warmup =
            ReceiptScannerWarmup(scanner, connectivityChanges: network.stream, phoneScript: ReceiptScript.chinese)
              ..start();
        await settle();
        expect(scanner.downloads, isEmpty);
        expect(warmup.listening, isFalse);
      });

      test('a Latin phone downloads nothing', () async {
        final scanner = _Scanner([true]);
        ReceiptScannerWarmup(scanner, connectivityChanges: network.stream).start();
        await settle();
        expect(scanner.downloads, isEmpty);
      });
    });

    test('on the iPhone (#155): ready at once, nothing to download, no listening', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final warmup = ReceiptScannerWarmup(PlatformReceiptScanner(connectivity: () async => [ConnectivityResult.none]),
          connectivityChanges: network.stream, phoneScript: ReceiptScript.japanese)
        ..start();
      await settle();
      expect(calls, isEmpty);
      expect(warmup.listening, isFalse);
    });

    test('where scanning isn\'t supported: no check, no listening', () async {
      final scanner = _Scanner([false])..isSupported = false;
      final warmup = ReceiptScannerWarmup(scanner, connectivityChanges: network.stream)..start();
      await settle();
      expect((scanner.prepared, warmup.listening, network.hasListener), (0, false, false));
    });
  });
}
