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
  const PlatformReceiptScanner();

  static const _channel = MethodChannel('com.sharneng.spliit2go/receipt_scan');

  @override
  bool get isSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

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
