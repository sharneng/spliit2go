import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'receipt_text.dart';

/// The Document Scanner can't run here: Google Play services is missing,
/// or hasn't downloaded the scanner yet (a fresh install that was never
/// online). Capture falls back to the camera and gallery (#125).
class ReceiptScannerUnavailable implements Exception {
  final String? message;
  const ReceiptScannerUnavailable([this.message]);

  @override
  String toString() => 'ReceiptScannerUnavailable: $message';
}

/// Scanning a receipt on the phone (#125); a seam so widget tests don't
/// need the platform.
abstract interface class ReceiptScanner {
  /// Whether this platform reads receipts at all. Android only: the
  /// iPhone is #126.
  bool get isSupported;

  /// Has Google Play services download the Document Scanner, when the
  /// phone is online and it isn't there yet, so the first scan is likely
  /// to have it; see [ReceiptScannerWarmup]. True once it's installed.
  /// Best effort, and never throws: a scan without it falls back to the
  /// camera and library, and asks for it again.
  Future<bool> prepare();

  /// ML Kit's Document Scanner: the page as JPEG, or null when the user
  /// cancelled. Throws [ReceiptScannerUnavailable] when it can't run.
  Future<Uint8List?> scanDocument();

  /// ML Kit text recognition, on the phone, with the Latin model bundled
  /// in the app, so it works offline from the first use.
  Future<List<ReceiptTextBlock>> recognizeText(Uint8List jpeg);
}

/// The Android bridge, `MainActivity.kt` / `ReceiptScanChannel.kt`: ML
/// Kit is called directly rather than through the pub.dev plugins, which
/// would bring CocoaPods into the SwiftPM-only iOS build (#105) for a
/// feature iOS doesn't have yet.
class PlatformReceiptScanner implements ReceiptScanner {
  const PlatformReceiptScanner({this.connectivity});

  /// The network, for [prepare]; connectivity_plus by default.
  final Future<List<ConnectivityResult>> Function()? connectivity;

  static const _channel = MethodChannel('com.sharneng.spliit2go/receipt_scan');

  @override
  bool get isSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Offline, nothing is asked, and it's false: whether it's installed
  /// isn't known until the next call with a connection.
  @override
  Future<bool> prepare() async {
    if (!isSupported) return false;
    try {
      final network = await (connectivity ?? Connectivity().checkConnectivity)();
      if (network.every((r) => r == ConnectivityResult.none)) return false;
      return await _channel.invokeMethod<bool>('prepareScanner') ?? false;
    } catch (_) {
      // Best effort (see ReceiptScanner.prepare): the scan falls back
      // without it, and the bridge reports its own failures as false.
      return false;
    }
  }

  @override
  Future<Uint8List?> scanDocument() async {
    try {
      return await _channel.invokeMethod<Uint8List>('scanDocument');
    } on PlatformException catch (e) {
      if (e.code == 'unavailable') throw ReceiptScannerUnavailable(e.message);
      rethrow;
    }
  }

  @override
  Future<List<ReceiptTextBlock>> recognizeText(Uint8List jpeg) async {
    final result = await _channel.invokeMapMethod<String, Object?>('recognizeText', {'jpeg': jpeg});
    final width = (result!['width'] as num).toDouble();
    final height = (result['height'] as num).toDouble();
    return [
      for (final line in (result['lines'] as List).cast<Map<Object?, Object?>>())
        ReceiptTextBlock(
          text: line['text'] as String,
          minX: (line['left'] as num) / width,
          midY: ((line['top'] as num) + (line['bottom'] as num)) / 2 / height,
          height: ((line['bottom'] as num) - (line['top'] as num)) / height,
        ),
    ];
  }
}

/// Gets the Document Scanner downloaded as soon as the phone is online
/// (#125, Kenneth), so the first scan usually has it: at launch, and again
/// whenever a connection comes back, wherever the user is in the app.
/// Stops listening once the scanner is installed; until then each check is
/// a quick local question to Play services. A scan without the scanner
/// still falls back to the camera and library.
class ReceiptScannerWarmup {
  ReceiptScannerWarmup(this._scanner, {Stream<List<ConnectivityResult>>? connectivityChanges})
      : _changes = connectivityChanges;

  final ReceiptScanner _scanner;
  final Stream<List<ConnectivityResult>>? _changes;
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _checking = false;
  bool _done = false;

  /// Whether it's still listening for a connection.
  @visibleForTesting
  bool get listening => _subscription != null;

  void start() {
    if (!_scanner.isSupported) return;
    _subscription = (_changes ?? Connectivity().onConnectivityChanged).listen((network) {
      if (network.any((r) => r != ConnectivityResult.none)) _check();
    });
    _check();
  }

  Future<void> _check() async {
    if (_checking || _done) return;
    _checking = true;
    try {
      if (await _scanner.prepare()) stop();
    } finally {
      _checking = false;
    }
  }

  void stop() {
    _done = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
  }
}
