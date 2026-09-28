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
  /// to have it. Best effort, and never throws: a scan without it falls
  /// back to the camera and library, and asks for it again.
  Future<void> prepare();

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

  /// Called at launch (main.dart) and when a new expense's form opens,
  /// so there's time for the download before the first scan. Offline,
  /// nothing is asked: the next call, with a connection, asks.
  @override
  Future<void> prepare() async {
    if (!isSupported) return;
    try {
      final network = await (connectivity ?? Connectivity().checkConnectivity)();
      if (network.every((r) => r == ConnectivityResult.none)) return;
      await _channel.invokeMethod<bool>('prepareScanner');
    } catch (_) {
      // Best effort (see ReceiptScanner.prepare): the scan falls back
      // without it, and the bridge reports its own failures as false.
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
