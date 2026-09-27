import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../models/group_organization.dart';
import 'error_reporting.dart';
import 'receipt_cache.dart';
import 'settings_service.dart';

/// Why downloading a favorite group's receipts ahead stopped short (#127).
enum ReceiptDownloadProblem {
  /// The server or the bucket couldn't be reached.
  offline,

  /// "Wi-Fi only", and the phone isn't on Wi-Fi: nothing is downloaded
  /// over mobile data. Not an error.
  waitingForWifi,

  /// The receipt storage limit is reached by receipts that can't be
  /// evicted.
  noSpace,

  /// Something unexpected (#119): logged, with details.
  failed,
}

/// A favorite group's receipts on this device, for its 📎 (#127).
@immutable
class ReceiptDownloadStatus {
  const ReceiptDownloadStatus({
    this.shown = false,
    this.running = false,
    this.total = 0,
    this.available = 0,
    this.problem,
    this.diagnostics,
  });

  /// A favorite group, downloads on, and receipts to have.
  final bool shown;
  final bool running;

  /// Receipts the group has, and how many of them are on this device.
  final int total;
  final int available;

  /// Why the last download stopped short; null when it didn't.
  final ReceiptDownloadProblem? problem;
  final String? diagnostics;

  bool get complete => available >= total;

  /// Red: something went wrong, beyond waiting for Wi-Fi.
  bool get isError =>
      !running && !complete && problem != null && problem != ReceiptDownloadProblem.waitingForWifi;
}

/// Downloads favorite groups' receipts ahead, so they can be viewed
/// offline without having been opened (#127). Favorites only: they mark
/// the groups a traveller needs (Kenneth).
///
/// A run, per group:
/// 1. reads the expenses whose documents aren't known yet (the list only
///    counts them);
/// 2. keeps receipts already stored (opened earlier) as favorite
///    downloads;
/// 3. downloads the rest, one at a time, as favorite downloads, while
///    they fit under the storage limit after evicting viewing cache.
///
/// It runs after a favorite group refreshes, when a group is made a
/// favorite, and on Retry; never right after Clear. Under "Wi-Fi only"
/// nothing goes over mobile data: losing Wi-Fi cancels the transfer in
/// flight. Unfavoriting, removing the group, turning downloads off and
/// Clear cancel too.
class ReceiptDownloader {
  ReceiptDownloader(
    this.db, {
    ReceiptCache? cache,
    SettingsService? settings,
    Future<List<ConnectivityResult>> Function()? connectivity,
    Stream<List<ConnectivityResult>>? connectivityChanges,
    http.Client Function()? httpClient,
  })  : _cache = cache,
        _settings = settings ?? SettingsService(),
        _connectivity = connectivity ?? (() => Connectivity().checkConnectivity()),
        _connectivityChanges = connectivityChanges,
        _newHttpClient = httpClient ?? http.Client.new;

  final AppDatabase db;
  final ReceiptCache? _cache;
  final SettingsService _settings;
  final Future<List<ConnectivityResult>> Function() _connectivity;
  final Stream<List<ConnectivityResult>>? _connectivityChanges;
  final http.Client Function() _newHttpClient;

  ReceiptCache get _receipts => _cache ?? ReceiptCache.of(db);

  static final _byDb = Expando<ReceiptDownloader>('ReceiptDownloader');

  /// The downloader for [db], shared by every screen using it.
  static ReceiptDownloader of(AppDatabase db) => _byDb[db] ??= ReceiptDownloader(db);

  @visibleForTesting
  static void use(ReceiptDownloader downloader) => _byDb[downloader.db] = downloader;

  final _statuses = <String, ValueNotifier<ReceiptDownloadStatus>>{};
  final _runs = <String, _Run>{};

  /// The last unexpected failure's details, per group, for its status.
  /// In memory only: after a restart the 📎 stays red, with Retry.
  final _diagnostics = <String, String?>{};

  /// [groupId]'s status, live. Worked out from the database, so it
  /// survives a restart.
  ValueListenable<ReceiptDownloadStatus> status(String groupId) {
    final existing = _statuses[groupId];
    if (existing != null) return existing;
    final created = _statuses[groupId] = ValueNotifier(const ReceiptDownloadStatus());
    unawaited(refreshStatus(groupId));
    return created;
  }

  /// Works [groupId]'s status out again: after a refresh, a setting
  /// change, Clear.
  Future<void> refreshStatus(String groupId) async {
    try {
      final row = await db.groupRow(groupId);
      final mode = await _settings.receiptDownloadMode();
      final counts = await db.receiptAvailability(groupId);
      final running = _runs.containsKey(groupId);
      final problem = ReceiptDownloadProblem.values.asNameMap()[row?.receiptDownloadProblem];
      _statuses[groupId]?.value = ReceiptDownloadStatus(
        shown: row?.organization == GroupOrganization.favorite &&
            mode != ReceiptDownloadMode.off &&
            (counts.total > 0 || running),
        running: running,
        total: counts.total,
        available: counts.available,
        problem: problem,
        diagnostics: problem == ReceiptDownloadProblem.failed ? _diagnostics[groupId] : null,
      );
    } catch (e, st) {
      ErrorReporter.instance.report(e, st, operation: 'Checking receipts offline for $groupId');
    }
  }

  /// Every group's status again (the setting changed, Clear).
  Future<void> refreshAll() async {
    for (final groupId in _statuses.keys.toList()) {
      await refreshStatus(groupId);
    }
  }

  bool _allowed(ReceiptDownloadMode mode, List<ConnectivityResult> network) => switch (mode) {
        ReceiptDownloadMode.off => false,
        ReceiptDownloadMode.wifiOnly =>
          network.contains(ConnectivityResult.wifi) || network.contains(ConnectivityResult.ethernet),
        ReceiptDownloadMode.always => network.any((r) => r != ConnectivityResult.none),
      };

  /// Downloads [groupId]'s receipts that aren't on this device, from
  /// [client]'s server, if it's a favorite and the setting and network
  /// allow. Returns when the run ends; a run already going is joined.
  Future<void> run(String groupId, SpliitClient client) async {
    if (_runs[groupId] case final running?) return running.done.future;
    final row = await db.groupRow(groupId);
    final mode = await _settings.receiptDownloadMode();
    if (row?.organization != GroupOrganization.favorite || mode == ReceiptDownloadMode.off) {
      return refreshStatus(groupId);
    }
    final List<ConnectivityResult> network;
    try {
      network = await _connectivity();
    } catch (e, st) {
      // No plugin (widget tests): unknown, so nothing is downloaded.
      if (!isMissingPlugin(e)) {
        ErrorReporter.instance.report(e, st, operation: 'Checking connectivity');
      }
      return;
    }
    if (!_allowed(mode, network)) {
      final offline = network.every((r) => r == ConnectivityResult.none);
      await _finish(groupId,
          offline ? ReceiptDownloadProblem.offline : ReceiptDownloadProblem.waitingForWifi);
      return;
    }
    if (_runs.containsKey(groupId)) return _runs[groupId]!.done.future;

    final run = _runs[groupId] = _Run(_newHttpClient());
    // Only moving onto mobile data under "Wi-Fi only" cancels: going
    // offline fails the transfer by itself, and iOS reports "none" when
    // this starts listening on the simulator, which mustn't stop a run.
    final watch = (_connectivityChanges ?? _platformChanges())?.listen((network) {
      final onMobileData = network.any((r) => r != ConnectivityResult.none);
      if (mode == ReceiptDownloadMode.wifiOnly && onMobileData && !_allowed(mode, network)) {
        run.cancel(ReceiptDownloadProblem.waitingForWifi);
      }
    });
    await refreshStatus(groupId);
    ReceiptDownloadProblem? problem;
    String? diagnostics;
    try {
      (problem, diagnostics) = await _download(groupId, client, run);
    } catch (e, st) {
      if (run.cancelled) {
        problem = run.reason;
      } else {
        final error = ErrorReporter.instance.report(e, st, operation: 'Downloading receipts of $groupId');
        problem = error.kind == ErrorKind.connection
            ? ReceiptDownloadProblem.offline
            : ReceiptDownloadProblem.failed;
        diagnostics = error.diagnostics;
      }
    } finally {
      await watch?.cancel();
      run.client.close();
      _runs.remove(groupId);
      run.done.complete();
    }
    if (run.removed) return;
    await _finish(groupId, run.cancelled ? run.reason : problem, diagnostics: diagnostics);
  }

  Stream<List<ConnectivityResult>>? _platformChanges() {
    try {
      return Connectivity().onConnectivityChanged;
    } catch (e) {
      if (!isMissingPlugin(e)) rethrow;
      return null;
    }
  }

  Future<void> _finish(String groupId, ReceiptDownloadProblem? problem, {String? diagnostics}) async {
    _diagnostics[groupId] = diagnostics;
    await db.setReceiptDownloadProblem(groupId, problem?.name);
    await refreshStatus(groupId);
  }

  /// One run's work. Throws on a connection failure (which stops it);
  /// an unexpected failure on one receipt is reported and the rest go on.
  Future<(ReceiptDownloadProblem?, String?)> _download(
      String groupId, SpliitClient client, _Run run) async {
    ReportedError? failure;
    for (final expenseId in await db.expensesWithUnreadDocuments(groupId)) {
      if (run.cancelled) return (run.reason, null);
      try {
        final fresh = await client.fetchExpense(groupId: groupId, expenseId: expenseId);
        await db.cacheExpenseDocuments(groupId, expenseId, fresh.documents);
      } catch (e, st) {
        // Deleted meanwhile: the next refresh drops it.
        if (e is SpliitApiException && e.isNotFound) continue;
        if (classifyError(e) == ErrorKind.connection) rethrow;
        failure ??= ErrorReporter.instance
            .report(e, st, operation: 'Reading receipts of expense $expenseId');
      }
    }
    // Opened earlier: already here, so kept rather than downloaded again.
    await db.keepGroupReceipts(groupId);
    await refreshStatus(groupId);
    for (final url in await db.receiptUrlsNotStored(groupId)) {
      if (run.cancelled) return (run.reason, null);
      try {
        final res = await run.client.get(Uri.parse(url)).timeout(const Duration(seconds: 60));
        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw ReceiptDownloadException(res.statusCode, url);
        }
        if (run.cancelled) return (run.reason, null);
        if (!await _receipts.makeRoom(res.bodyBytes.length)) return (ReceiptDownloadProblem.noSpace, null);
        await _receipts.store(url,
            groupId: groupId, bytes: res.bodyBytes, kind: ReceiptFileKind.favorite);
        await refreshStatus(groupId);
      } catch (e, st) {
        if (run.cancelled || classifyError(e) == ErrorKind.connection) rethrow;
        failure ??= ErrorReporter.instance.report(e, st, operation: 'Downloading receipt $url');
      }
    }
    return failure == null ? (null, null) : (ReceiptDownloadProblem.failed, failure.diagnostics);
  }

  /// Stops [groupId]'s run, closing the transfer in flight.
  void cancel(String groupId, [ReceiptDownloadProblem? reason]) => _runs[groupId]?.cancel(reason);

  /// Downloads turned off, or Clear: every run stops.
  void cancelAll() {
    for (final run in _runs.values) {
      run.cancel(null);
    }
  }

  /// [groupId] is no longer a favorite: its run stops, and its downloads
  /// become viewing cache, evicted like any other.
  Future<void> unfavorited(String groupId) async {
    cancel(groupId);
    await db.releaseGroupReceipts(groupId);
    await db.setReceiptDownloadProblem(groupId, null);
    await _receipts.makeRoom(0);
    await refreshStatus(groupId);
  }

  /// [groupId] was removed from this device (its files go with its rows).
  void removed(String groupId) {
    _runs[groupId]
      ?..removed = true
      ..cancel(null);
    _statuses.remove(groupId)?.dispose();
  }
}

class _Run {
  _Run(this.client);
  final http.Client client;
  final done = Completer<void>();
  bool cancelled = false;
  bool removed = false;
  ReceiptDownloadProblem? reason;

  void cancel(ReceiptDownloadProblem? why) {
    if (cancelled) return;
    cancelled = true;
    reason = why;
    // Aborts the transfer in flight: nothing more over mobile data.
    client.close();
  }
}
