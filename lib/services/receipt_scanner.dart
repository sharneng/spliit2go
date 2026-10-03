import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'receipt_text.dart';
import 'settings_service.dart';

/// The Document Scanner can't run here: Google Play services is missing,
/// or hasn't downloaded the scanner yet (a fresh install that was never
/// online). Capture falls back to the camera and gallery (#125).
class ReceiptScannerUnavailable implements Exception {
  final String? message;
  const ReceiptScannerUnavailable([this.message]);

  @override
  String toString() => 'ReceiptScannerUnavailable: $message';
}

/// A receipt language (#153): one of ML Kit's text models, which read a
/// script rather than a language, and each also reads Latin text. On the
/// iPhone, the languages Vision reads for it (#155). Only
/// the scripts the parser understands are offered; Korean and Devanagari
/// can follow once it does.
enum ReceiptScript {
  /// English, French and the other Latin-script languages. Bundled with
  /// the app, so always there.
  latin,
  chinese,
  japanese;

  /// Downloaded by Google Play services when picked, not bundled. On the
  /// iPhone none is: Vision reads them all (#155).
  bool get downloadable => this != latin && defaultTargetPlatform == TargetPlatform.android;

  /// The script for a language code (the phone's), or null for one the
  /// app has no model for. Latin languages are null too: Latin needs no
  /// download.
  static ReceiptScript? forLanguage(String languageCode) => switch (languageCode) {
        'zh' => chinese,
        'ja' => japanese,
        _ => null,
      };
}

/// A downloadable text model isn't on the phone (#153): never downloaded,
/// removed, or cleared with Google Play services' data.
class ReceiptTextModelMissing implements Exception {
  final ReceiptScript script;
  const ReceiptTextModelMissing(this.script);

  @override
  String toString() => 'ReceiptTextModelMissing: ${script.name}';
}

/// Downloading a text model didn't work (#153).
class ReceiptTextModelDownloadFailed implements Exception {
  final ReceiptScript script;

  /// The phone was offline, so nothing was asked.
  final bool offline;
  final String? message;
  const ReceiptTextModelDownloadFailed(this.script, {this.offline = false, this.message});

  @override
  String toString() => 'ReceiptTextModelDownloadFailed: ${script.name}${offline ? ', offline' : ''}: $message';
}

/// Scanning a receipt on the phone (#125); a seam so widget tests don't
/// need the platform.
abstract interface class ReceiptScanner {
  /// Whether this platform reads receipts at all: Android and the
  /// iPhone (#155).
  bool get isSupported;

  /// Has Google Play services download the Document Scanner, when the
  /// phone is online and it isn't there yet, so the first scan is likely
  /// to have it; see [ReceiptScannerWarmup]. True once it's installed.
  /// Best effort, and never throws: a scan without it falls back to the
  /// camera and library, and asks for it again.
  Future<bool> prepare();

  /// Whether [scanDocument] can also import a photo from the library.
  /// Android's Document Scanner can; the iPhone's document camera can't,
  /// so there Scan receipt asks first: the camera or the library (#155).
  bool get scannerImportsPhotos;

  /// The document scanner (ML Kit's, or VisionKit's document camera on the
  /// iPhone): the page as JPEG, or null when the user cancelled. Throws
  /// [ReceiptScannerUnavailable] when it can't run.
  Future<Uint8List?> scanDocument();

  /// ML Kit text recognition, on the phone, in [script] (#153). Latin is
  /// bundled in the app, so it works offline from the first use; another
  /// script throws [ReceiptTextModelMissing] when its model isn't there.
  Future<List<ReceiptTextBlock>> recognizeText(Uint8List jpeg, {ReceiptScript script = ReceiptScript.latin});

  /// The scripts whose models are on the phone now, Latin always among
  /// them, less those the user removed. Asked of Google Play services every
  /// time: the models are shared with other apps, and outlive this one.
  Future<Set<ReceiptScript>> installedScripts();

  /// Downloads [script]'s model, completing once it's installed. Throws
  /// [ReceiptTextModelDownloadFailed], at once when offline.
  Future<void> installScript(ReceiptScript script);

  /// Tells Google Play services the app no longer needs [script]'s model.
  /// The space is freed later, and only if no other app uses it; until it
  /// is, Play services still reports it installed, so the app remembers
  /// the removal until [installScript] (which is then instant).
  Future<void> removeScript(ReceiptScript script);
}

/// The platform bridges, on one channel: Android's `ReceiptScanChannel.kt`
/// calls ML Kit directly rather than through the pub.dev plugins, which
/// would bring CocoaPods into the SwiftPM-only iOS build (#105); the
/// iPhone's `ReceiptScanChannel.swift` calls VisionKit and Vision (#155),
/// which are part of iOS, so nothing is downloaded there.
class PlatformReceiptScanner implements ReceiptScanner {
  const PlatformReceiptScanner({this.connectivity, this.settings});

  /// The network, for [prepare]; connectivity_plus by default.
  final Future<List<ConnectivityResult>> Function()? connectivity;

  /// Where removed receipt languages are remembered; [SettingsService]
  /// when null.
  final SettingsService? settings;

  SettingsService get _settings => settings ?? SettingsService();

  static const _channel = MethodChannel('com.sharneng.spliit2go/receipt_scan');

  @override
  bool get isSupported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  bool get _iPhone => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  bool get scannerImportsPhotos => !_iPhone;

  Future<bool> _online() async {
    final network = await (connectivity ?? Connectivity().checkConnectivity)();
    return network.any((r) => r != ConnectivityResult.none);
  }

  /// Offline, nothing is asked, and it's false: whether it's installed
  /// isn't known until the next call with a connection.
  @override
  Future<bool> prepare() async {
    if (!isSupported) return false;
    // The document camera is part of iOS.
    if (_iPhone) return true;
    try {
      if (!await _online()) return false;
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
  Future<Set<ReceiptScript>> installedScripts() async {
    // Vision reads them all.
    if (_iPhone) return ReceiptScript.values.toSet();
    final installed = await _channel.invokeMapMethod<String, bool>('textModels');
    final removed = await _settings.receiptScriptsRemoved();
    return {
      ReceiptScript.latin,
      for (final s in ReceiptScript.values)
        if (installed?[s.name] == true && !removed.contains(s.name)) s,
    };
  }

  @override
  Future<void> installScript(ReceiptScript script) async {
    if (!script.downloadable) return;
    // Removed, but not freed yet: nothing to download, and asking Play
    // services to install it again once restarted the app (seen once on
    // the emulator: "Module config changed, forcing restart"), losing the
    // open form.
    final present = await _channel.invokeMapMethod<String, bool>('textModels');
    if (present?[script.name] == true) return _settings.setReceiptScriptRemoved(script.name, false);
    if (!await _online()) throw ReceiptTextModelDownloadFailed(script, offline: true);
    try {
      await _channel.invokeMethod<bool>('installTextModel', {'script': script.name});
    } on PlatformException catch (e) {
      if (e.code == 'install-failed') throw ReceiptTextModelDownloadFailed(script, message: e.message);
      rethrow;
    }
    await _settings.setReceiptScriptRemoved(script.name, false);
  }

  @override
  Future<void> removeScript(ReceiptScript script) async {
    if (!script.downloadable) return;
    await _channel.invokeMethod<void>('removeTextModel', {'script': script.name});
    await _settings.setReceiptScriptRemoved(script.name, true);
  }

  @override
  Future<List<ReceiptTextBlock>> recognizeText(Uint8List jpeg, {ReceiptScript script = ReceiptScript.latin}) async {
    final Map<String, Object?>? result;
    try {
      result = await _channel.invokeMapMethod<String, Object?>('recognizeText', {'jpeg': jpeg, 'script': script.name});
    } on PlatformException catch (e) {
      if (e.code == 'model-missing') throw ReceiptTextModelMissing(script);
      rethrow;
    }
    final width = (result!['width'] as num).toDouble();
    final height = (result['height'] as num).toDouble();
    return receiptTextBlocks([
      for (final line in (result['lines'] as List).cast<Map<Object?, Object?>>())
        ReceiptOcrLine(
          line['text'] as String,
          left: (line['left'] as num).toDouble(),
          top: (line['top'] as num).toDouble(),
          right: (line['right'] as num).toDouble(),
          bottom: (line['bottom'] as num).toDouble(),
          corners: [for (final c in (line['corners'] as List?) ?? const []) (c as num).toDouble()],
        ),
    ], width: width, height: height);
  }
}

/// Gets the Document Scanner downloaded as soon as the phone is online
/// (#125, Kenneth), so the first scan usually has it: at launch, and again
/// whenever a connection comes back, wherever the user is in the app.
///
/// The same goes for the text model of the phone's language (#153), when
/// it's one that's downloaded (Chinese or Japanese): once, ever. After
/// that it's the user's to keep or remove in the receipt language picker,
/// and removing it doesn't bring it back.
///
/// Stops listening once both are done; until then each check is a quick
/// local question to Play services. A scan without the scanner still falls
/// back to the camera and library, and one without the model in Latin.
class ReceiptScannerWarmup {
  ReceiptScannerWarmup(
    this._scanner, {
    Stream<List<ConnectivityResult>>? connectivityChanges,
    this.phoneScript,
    SettingsService? settings,
  })  : _changes = connectivityChanges,
        _settings = settings ?? SettingsService();

  final ReceiptScanner _scanner;
  final Stream<List<ConnectivityResult>>? _changes;
  final SettingsService _settings;

  /// The phone's language's script, if it's a downloadable one.
  final ReceiptScript? phoneScript;

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _checking = false;
  bool _scannerReady = false;
  bool _modelDone = false;
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
      _scannerReady = _scannerReady || await _scanner.prepare();
      _modelDone = _modelDone || await _preparePhoneModel();
      if (_scannerReady && _modelDone) stop();
    } finally {
      _checking = false;
    }
  }

  /// True once there's nothing left to do: no model to fetch, fetched
  /// before, or installed now. Best effort, like [ReceiptScanner.prepare].
  Future<bool> _preparePhoneModel() async {
    final script = phoneScript;
    if (script == null || !script.downloadable) return true;
    try {
      if (await _settings.receiptScriptAutoDownloaded()) return true;
      if (!(await _scanner.installedScripts()).contains(script)) await _scanner.installScript(script);
      await _settings.setReceiptScriptAutoDownloaded();
      return true;
    } catch (_) {
      // Offline, or Play services failed: tried again with the next
      // connection. The user can also download it from the picker.
      return false;
    }
  }

  void stop() {
    _done = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
  }
}
