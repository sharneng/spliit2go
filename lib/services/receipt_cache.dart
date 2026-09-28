import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import 'settings_service.dart' show defaultReceiptStorageLimitMb;
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
/// - Everything stored counts toward one limit, [limit] bytes (#127;
///   App settings, 500 MB by default): opened receipts (the viewing
///   cache), favorite groups' downloads, this device's photos, and photos
///   not uploaded yet. Only the viewing cache is evicted to stay under
///   it, least recently used first.
/// - A file nothing refers to any more (its expense, document or group
///   was removed; the database drops the row) is deleted by [sweep].
class ReceiptCache {
  ReceiptCache(
    this.db, {
    Future<Directory> Function()? directory,
    http.Client? httpClient,
    this.limit = defaultReceiptStorageLimitMb * 1024 * 1024,
    DateTime Function()? clock,
  })  : _directory = directory ?? _defaultDirectory,
        _http = httpClient ?? http.Client(),
        _now = clock ?? DateTime.now;

  final AppDatabase db;
  final Future<Directory> Function() _directory;
  final http.Client _http;
  final DateTime Function() _now;

  /// The most space stored receipts may take, in bytes: the App settings
  /// limit, set at startup and when it changes.
  int limit;

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
    return store(url, groupId: groupId, bytes: res.bodyBytes);
  }

  /// Stores [bytes] as the image for [url]: a download (viewing cache,
  /// like any opened receipt), or a photo this device just uploaded, so it
  /// shows without being downloaded back ([ReceiptFileKind.capture], #124).
  Future<File> store(String url,
          {required String groupId,
          required List<int> bytes,
          ReceiptFileKind kind = ReceiptFileKind.viewing}) =>
      _exclusive(() async {
        final (file, fileName) = await _write(bytes);
        await db.saveReceiptFile(ReceiptFilesCompanion.insert(
          url: url,
          groupId: groupId,
          fileName: fileName,
          bytes: bytes.length,
          kind: kind,
          lastUsedAt: _now(),
        ));
        await _evict(keep: url);
        return file;
      });

  /// Stores [bytes] for [url] only if they fit under [limit] once viewing
  /// cache is evicted, and returns the file, or null when they don't
  /// (#127). The check, the eviction, the write and the registration are
  /// one step under the cache's lock, so two favorite groups downloading
  /// at once can't both pass the check and overrun the limit together
  /// (#144 review). The transfer itself happens before, outside the lock.
  Future<File?> storeIfRoom(String url,
          {required String groupId, required List<int> bytes, required ReceiptFileKind kind}) =>
      _exclusive(() async {
        if (!await _evictFor(bytes.length)) return null;
        final (file, fileName) = await _write(bytes);
        await db.saveReceiptFile(ReceiptFilesCompanion.insert(
          url: url,
          groupId: groupId,
          fileName: fileName,
          bytes: bytes.length,
          kind: kind,
          lastUsedAt: _now(),
        ));
        return file;
      });

  /// Writes photos that aren't uploaded yet (#124), then has [register]
  /// record them, with their file names, in the same step: the
  /// attachments' rows, and a new expense's own. Until [register]
  /// completes, [sweep] waits, so a new file can't be taken for a stray
  /// one; if it throws, the files are strays, and the next sweep deletes
  /// them.
  Future<void> storePending(
          List<List<int>> photos, Future<void> Function(List<String> fileNames) register) =>
      _exclusive(() async {
        final fileNames = [for (final bytes in photos) (await _write(bytes)).$2];
        await register(fileNames);
      });

  /// A stored file by name: a pending photo's (#124).
  Future<File> fileNamed(String fileName) async =>
      File(p.join((await _receiptsDir()).path, fileName));

  /// Writes [bytes] under a new name. Written under a temporary name and
  /// renamed, so a partial file is never mistaken for a stored receipt.
  /// Only under [_exclusive], so [sweep] never sees it half done.
  Future<(File, String)> _write(List<int> bytes) async {
    final dir = await _receiptsDir();
    final fileName = '${const Uuid().v4()}.img';
    final partial = File(p.join(dir.path, '$fileName.part'));
    await partial.writeAsBytes(bytes, flush: true);
    return (await partial.rename(p.join(dir.path, fileName)), fileName);
  }

  /// Brings everything stored under [limit] by evicting viewing cache,
  /// least recently used first, never [keep] (the receipt just stored).
  Future<void> _evict({required String keep}) => _evictFor(0, keep: keep);

  /// Evicts viewing cache until [bytes] more fit under [limit], and
  /// returns whether they do (#127): favorite downloads pause when only
  /// receipts that can't be evicted are left.
  Future<bool> makeRoom(int bytes) => _exclusive(() => _evictFor(bytes));

  Future<bool> _evictFor(int bytes, {String? keep}) async {
    final files = await db.allReceiptFiles();
    var total = files.fold<int>(0, (sum, f) => sum + f.bytes) + await db.attachmentBytes() + bytes;
    final evicted = <ReceiptFileRow>[];
    for (final f in files) {
      if (total <= limit) break;
      if (f.kind != ReceiptFileKind.viewing || f.url == keep) continue;
      evicted.add(f);
      total -= f.bytes;
    }
    if (evicted.isNotEmpty) {
      await db.deleteReceiptFiles(evicted.map((f) => f.url));
      await _deleteFiles(evicted.map((f) => f.fileName));
    }
    return total <= limit;
  }

  /// Bytes stored on this device for receipts.
  Future<int> usage() async =>
      (await db.allReceiptFiles()).fold<int>(0, (sum, f) => sum + f.bytes);

  /// Removes every stored receipt. They're downloaded again when opened.
  /// Photos not uploaded yet aren't stored receipts, and stay (#124).
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
      // Stored receipts, and photos not on their expense yet (#124),
      // which are never swept.
      final known = await db.keptReceiptFileNames();
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
