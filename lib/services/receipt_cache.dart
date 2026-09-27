import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import 'error_reporting.dart';

/// A receipt's server answered, but not with the image (#123): a bucket
/// refusing the request, say. Unexpected under the #119 policy, unlike a
/// connection failure, which just means "available when online".
class ReceiptDownloadException implements Exception {
  final int statusCode;
  final String url;
  ReceiptDownloadException(this.statusCode, this.url);

  @override
  String toString() => 'ReceiptDownloadException: HTTP $statusCode for $url';
}

/// Receipt images on this device (#123): downloads them, keeps them in
/// the receipts directory, and enforces the storage policy (the table in
/// #123) together with [AppDatabase], which records every stored file in
/// `ReceiptFiles`.
///
/// - Keyed by document URL, which never changes, so nothing goes stale.
/// - Opened receipts are the viewing cache: capped at [viewingCap] bytes,
///   evicting the least recently used first.
/// - A file nothing refers to any more (its expense, document or group
///   was removed; the database drops the row) is deleted by [sweep].
class ReceiptCache {
  ReceiptCache(
    this.db, {
    Future<Directory> Function()? directory,
    http.Client? httpClient,
    this.viewingCap = 200 * 1024 * 1024,
    DateTime Function()? clock,
  })  : _directory = directory ?? _defaultDirectory,
        _http = httpClient ?? http.Client(),
        _now = clock ?? DateTime.now;

  final AppDatabase db;
  final Future<Directory> Function() _directory;
  final http.Client _http;
  final DateTime Function() _now;

  /// The viewing cache's size limit, in bytes.
  final int viewingCap;

  static final _byDb = Expando<ReceiptCache>('ReceiptCache');

  /// The cache for [db], shared by every screen using it.
  static ReceiptCache of(AppDatabase db) => _byDb[db] ??= ReceiptCache(db);

  /// Makes [cache] the one [of] returns for its database (a temporary
  /// directory and a fake server, in tests).
  @visibleForTesting
  static void use(ReceiptCache cache) => _byDb[cache.db] = cache;

  static Future<Directory> _defaultDirectory() async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'receipts'));

  Directory? _dir;
  Future<Directory> _receiptsDir() async {
    final dir = _dir ??= await _directory();
    await dir.create(recursive: true);
    return dir;
  }

  /// Downloads in flight, so two widgets asking for one receipt share it.
  final _inFlight = <String, Future<File>>{};

  /// Storing a file (write, rename, register) and [sweep] run one at a
  /// time (#130 review): a sweep between a store's rename and its row
  /// being committed would delete the file it returns, and one during a
  /// write would delete the partial file.
  Future<void> _tail = Future.value();
  Future<T> _exclusive<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// The stored file for [url], or null when it isn't on this device.
  Future<File?> cachedFile(String url) async {
    final row = await db.receiptFile(url);
    if (row == null) return null;
    final file = File(p.join((await _receiptsDir()).path, row.fileName));
    if (!await file.exists()) {
      // Removed outside the app (the OS clearing storage): forget it.
      await db.deleteReceiptFiles([url]);
      return null;
    }
    await db.touchReceiptFile(url, _now());
    return file;
  }

  /// The image for [url]: the stored file if there is one, else downloaded
  /// and stored as viewing cache for [groupId]. Throws what the download
  /// threw: a connection failure, or [ReceiptDownloadException].
  Future<File> load(String url, {required String groupId}) async {
    final cached = await cachedFile(url);
    if (cached != null) return cached;
    // A block body: returning the removed Future from whenComplete would
    // make it wait for itself.
    return _inFlight[url] ??= _download(url, groupId).whenComplete(() {
      _inFlight.remove(url);
    });
  }

  Future<File> _download(String url, String groupId) async {
    final res = await _http.get(Uri.parse(url)).timeout(const Duration(seconds: 60));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ReceiptDownloadException(res.statusCode, url);
    }
    return _exclusive(() => _store(url, groupId, res.bodyBytes));
  }

  /// Writes [bytes] as the image for [url] and registers it. Runs under
  /// [_exclusive], so [sweep] never sees it half done.
  Future<File> _store(String url, String groupId, List<int> bytes) async {
    final dir = await _receiptsDir();
    final fileName = '${const Uuid().v4()}.img';
    // Written under a temporary name and renamed, so a partial file is
    // never mistaken for a stored receipt.
    final partial = File(p.join(dir.path, '$fileName.part'));
    await partial.writeAsBytes(bytes, flush: true);
    final file = await partial.rename(p.join(dir.path, fileName));
    await db.saveReceiptFile(ReceiptFilesCompanion.insert(
      url: url,
      groupId: groupId,
      fileName: fileName,
      bytes: bytes.length,
      kind: ReceiptFileKind.viewing,
      lastUsedAt: _now(),
    ));
    await _evict(keep: url);
    return file;
  }

  /// Brings the viewing cache under [viewingCap], least recently used
  /// first, never evicting [keep] (the receipt just stored).
  Future<void> _evict({required String keep}) async {
    final viewing = (await db.allReceiptFiles()).where((f) => f.kind == ReceiptFileKind.viewing);
    var total = viewing.fold<int>(0, (sum, f) => sum + f.bytes);
    final evicted = <ReceiptFileRow>[];
    for (final f in viewing) {
      if (total <= viewingCap) break;
      if (f.url == keep) continue;
      evicted.add(f);
      total -= f.bytes;
    }
    if (evicted.isEmpty) return;
    await db.deleteReceiptFiles(evicted.map((f) => f.url));
    await _deleteFiles(evicted.map((f) => f.fileName));
  }

  /// Bytes stored on this device for receipts.
  Future<int> usage() async =>
      (await db.allReceiptFiles()).fold<int>(0, (sum, f) => sum + f.bytes);

  /// Removes every stored receipt. They're downloaded again when opened.
  Future<void> clear() async {
    final rows = await db.allReceiptFiles();
    await db.deleteReceiptFiles(rows.map((f) => f.url));
    await sweep();
  }

  /// Deletes files no stored receipt refers to: left behind when the
  /// database dropped their rows (a refresh, a delete, leaving a group,
  /// eviction), or a partial download. Safe to call any time; run at
  /// startup and after those changes.
  Future<void> sweep() => _exclusive(_sweep);

  Future<void> _sweep() async {
    try {
      final dir = await _receiptsDir();
      final known = {for (final f in await db.allReceiptFiles()) f.fileName};
      await for (final entity in dir.list()) {
        if (entity is File && !known.contains(p.basename(entity.path))) {
          await entity.delete();
        }
      }
    } catch (e, st) {
      // No path_provider in widget tests is expected; anything else is
      // reported, and the files wait for the next sweep.
      if (!isMissingPlugin(e)) {
        ErrorReporter.instance.report(e, st, operation: 'Cleaning up stored receipts');
      }
    }
  }

  Future<void> _deleteFiles(Iterable<String> fileNames) async {
    final dir = await _receiptsDir();
    for (final name in fileNames) {
      final file = File(p.join(dir.path, name));
      if (await file.exists()) await file.delete();
    }
  }

  @visibleForTesting
  Future<Directory> get directoryForTesting => _receiptsDir();
}
