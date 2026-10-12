import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../models/activity.dart';
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

  /// The server has no activity log (too old), so nothing tells which
  /// expenses changed: notes and receipts can't be kept current for
  /// offline (#237). Nothing is read until Retry; the group's details
  /// are read when opened, as in any other group. The name is stored
  /// ([AppDatabase.noActivityLog]).
  noActivityLog,
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
    this.detailsUnknown = 0,
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

  /// Expenses whose notes and rate aren't on this device yet (#237).
  final int detailsUnknown;

  /// Every receipt is here, and the last check found nothing it
  /// couldn't read: safe to go offline. A check that stopped short
  /// (#144 review) can't vouch for the receipts it didn't read, such as
  /// one swapped on the web with the count unchanged, even when the
  /// counts add up; the problem is stored, so this survives a restart.
  /// Every expense's notes too (#237).
  bool get complete => available >= total && detailsUnknown == 0 && problem == null;

  /// All counted, but the last check stopped short: some may be out of
  /// date.
  bool get unverified => available >= total && problem != null;

  /// Red: something went wrong, beyond waiting for Wi-Fi.
  bool get isError =>
      !running && !complete && problem != null && problem != ReceiptDownloadProblem.waitingForWifi;
}

/// Downloads favorite groups' receipts ahead, so they can be viewed
/// offline without having been opened (#127). Favorites only: they mark
/// the groups a traveller needs (Kenneth).
///
/// Their expenses' notes and rate too (#237), which only reading an
/// expense in full gives: a refresh keeps them for a favorite, and the
/// activity log tells which changed.
///
/// A run, per group:
/// 1. reads the expenses whose details or documents aren't known yet (the
///    list only counts documents), over any network and whatever the
///    setting;
/// 2. keeps receipts already stored (opened earlier) as favorite
///    downloads;
/// 3. downloads the rest, one at a time, as favorite downloads, while
///    they fit under the storage limit after evicting viewing cache.
///
/// It runs after a favorite group refreshes, when a group is made a
/// favorite, and on Retry; never right after Clear. Under "Wi-Fi only" no
/// receipt goes over mobile data: losing Wi-Fi cancels the transfer in
/// flight. "Off" downloads no receipts. Unfavoriting, removing the group, turning downloads off and
/// Clear cancel too.
class ReceiptDownloader {
  ReceiptDownloader(
    this.db, {
    ReceiptCache? cache,
    SettingsService? settings,
    Future<List<ConnectivityResult>> Function()? connectivity,
    Stream<List<ConnectivityResult>>? connectivityChanges,
    http.Client Function()? httpClient,
    this.networkSettle = const Duration(seconds: 3),
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

  /// How long a "none" reading waits for the network to show up before
  /// it's believed (#164).
  final Duration networkSettle;

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
      final detailsUnknown = (await db.expensesWithUnknownDetails(groupId)).length;
      // Not while it's still checking the network.
      final running = _runs[groupId]?.downloading ?? false;
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
        detailsUnknown: detailsUnknown,
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
  ///
  /// [retry] is the 📎's Retry: a server found to have no activity log is
  /// tried again (#237); otherwise it stays stopped.
  Future<void> run(String groupId, SpliitClient client, {bool retry = false}) async {
    if (_runs[groupId] case final running?) return running.done.future;
    // Registered before anything is awaited, so Clear, turning downloads
    // off, unfavoriting and removing the group cancel it while it's still
    // checking the network too (#166 review).
    final run = _runs[groupId] = _Run(_newHttpClient());
    ({ReceiptDownloadProblem? problem, String? diagnostics})? result;
    try {
      result = await _runSteps(groupId, client, run, retry: retry);
    } finally {
      run.client.close();
      _runs.remove(groupId);
      run.done.complete();
    }
    if (run.removed) return;
    if (run.cancelled) return _finish(groupId, run.reason);
    if (result == null) return refreshStatus(groupId);
    await _finish(groupId, result.problem, diagnostics: result.diagnostics);
  }

  /// [run]'s work: what to store when it ends, or null for nothing (not a
  /// favorite, the network unknown). Overridden by a cancellation's
  /// reason.
  ///
  /// Two steps (#237): the expenses' details, over any network and
  /// whatever the setting, since they're small; then the receipt files,
  /// as the setting allows. A server without an activity log stops both,
  /// and stays stopped until Retry ([retry]).
  Future<({ReceiptDownloadProblem? problem, String? diagnostics})?> _runSteps(
      String groupId, SpliitClient client, _Run run, {required bool retry}) async {
    final row = await db.groupRow(groupId);
    if (row?.organization != GroupOrganization.favorite) return null;
    if (row?.receiptDownloadProblem == ReceiptDownloadProblem.noActivityLog.name) {
      if (!retry) return (problem: ReceiptDownloadProblem.noActivityLog, diagnostics: null);
      await db.setReceiptDownloadProblem(groupId, null);
    }
    final mode = await _settings.receiptDownloadMode();
    final List<ConnectivityResult> network;
    try {
      network = await _network(run);
    } catch (e, st) {
      // No plugin (widget tests): unknown, so nothing is read.
      if (!isMissingPlugin(e)) {
        ErrorReporter.instance.report(e, st, operation: 'Checking connectivity');
      }
      return null;
    }
    if (run.cancelled) return null;
    if (network.every((r) => r == ConnectivityResult.none)) {
      return (problem: ReceiptDownloadProblem.offline, diagnostics: null);
    }

    run.downloading = true;
    await refreshStatus(groupId);
    StreamSubscription<List<ConnectivityResult>>? watch;
    try {
      final details = await _readDetails(groupId, client, run);
      if (run.cancelled) return null;
      if (details.problem == ReceiptDownloadProblem.noActivityLog) {
        return (problem: details.problem, diagnostics: null);
      }
      final detailsProblem =
          details.failure == null ? null : (problem: ReceiptDownloadProblem.failed, diagnostics: details.failure!.diagnostics);
      if (mode == ReceiptDownloadMode.off) return detailsProblem;
      if (!_allowed(mode, network)) {
        return detailsProblem ?? (problem: ReceiptDownloadProblem.waitingForWifi, diagnostics: null);
      }
      // Only moving onto mobile data under "Wi-Fi only" cancels: going
      // offline fails the transfer by itself, and iOS reports "none" when
      // this starts listening on the simulator, which mustn't stop a run.
      watch = (_connectivityChanges ?? _platformChanges())?.listen((network) {
        final onMobileData = network.any((r) => r != ConnectivityResult.none);
        if (mode == ReceiptDownloadMode.wifiOnly && onMobileData && !_allowed(mode, network)) {
          run.cancel(ReceiptDownloadProblem.waitingForWifi);
        }
      });
      final (problem, diagnostics) = await _downloadFiles(groupId, run, details.failure);
      return (problem: problem, diagnostics: diagnostics);
    } catch (e, st) {
      if (run.cancelled) return null;
      final error = ErrorReporter.instance.report(e, st, operation: 'Downloading receipts of $groupId');
      return (
        problem: error.kind == ErrorKind.connection
            ? ReceiptDownloadProblem.offline
            : ReceiptDownloadProblem.failed,
        diagnostics: error.diagnostics,
      );
    } finally {
      await watch?.cancel();
    }
  }

  /// The network now. On iOS a check reads "none" until the system first
  /// reports the network, which comes just after the plugin starts
  /// watching, at launch and again after the last listener stops; taken
  /// at its word, that marked every favorite offline at launch (#164).
  /// So "none" is believed only if nothing better shows up within
  /// [networkSettle]. Cancelling [run] ends the wait.
  Future<List<ConnectivityResult>> _network(_Run run) async {
    final now = await _connectivity();
    bool connected(List<ConnectivityResult> n) => n.any((r) => r != ConnectivityResult.none);
    if (connected(now)) return now;
    final changes = _connectivityChanges ?? _platformChanges();
    if (changes == null) return now;
    final settled = Completer<List<ConnectivityResult>>();
    final watch = changes.listen((n) {
      if (connected(n) && !settled.isCompleted) settled.complete(n);
    }, onError: (Object _) {});
    void giveUp() {
      if (!settled.isCompleted) settled.complete(now);
    }
    final timer = Timer(networkSettle, giveUp);
    unawaited(run.whenCancelled.then((_) => giveUp()));
    try {
      return await settled.future;
    } finally {
      timer.cancel();
      await watch.cancel();
    }
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

  /// The first step: reads in full every expense whose details aren't
  /// known (#237), and every receipt list not known yet, then moves the
  /// activity-log check on. Throws on a connection failure (which stops
  /// the run); an unexpected failure on one expense is reported, returned,
  /// and the rest go on.
  Future<({ReceiptDownloadProblem? problem, ReportedError? failure})> _readDetails(
      String groupId, SpliitClient client, _Run run) async {
    final changes = await _forgetChanged(groupId, client);
    if (changes.problem != null) return (problem: changes.problem, failure: null);
    var failure = changes.failure;
    final toRead = {
      ...await db.expensesWithUnknownDetails(groupId),
      ...await db.expensesWithUnreadDocuments(groupId),
    };
    for (final expenseId in toRead) {
      if (run.cancelled) return (problem: null, failure: failure);
      try {
        final fresh = await client.fetchExpense(groupId: groupId, expenseId: expenseId);
        await db.cacheExpenseDetails(groupId, fresh);
      } catch (e, st) {
        // Deleted meanwhile: the next refresh drops it.
        if (e is SpliitApiException && e.isNotFound) continue;
        if (classifyError(e) == ErrorKind.connection) rethrow;
        failure ??= ErrorReporter.instance.report(e, st, operation: 'Reading expense $expenseId');
      }
    }
    // Everything read: the next run starts from here. Taken before the
    // reads, so an edit made meanwhile is seen next time, never skipped.
    if (changes.newest case final newest? when failure == null && !run.cancelled) {
      await db.setReceiptsChecked(groupId, activityId: newest.id, at: newest.time);
    }
    return (problem: null, failure: failure);
  }

  /// The second step: keeps the receipts opened earlier, and downloads
  /// the rest. Throws on a connection failure; an unexpected failure on
  /// one receipt is reported and the rest go on. [failure] is the first
  /// step's, if any.
  Future<(ReceiptDownloadProblem?, String?)> _downloadFiles(
      String groupId, _Run run, ReportedError? failure) async {
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
        // Room, eviction and storing in one step: another group can't
        // take the same room meanwhile (#144 review).
        final stored = await _receipts.storeIfRoom(url,
            groupId: groupId, bytes: res.bodyBytes, kind: ReceiptFileKind.favorite);
        if (stored == null) return (ReceiptDownloadProblem.noSpace, null);
        await refreshStatus(groupId);
      } catch (e, st) {
        if (run.cancelled || classifyError(e) == ErrorKind.connection) rethrow;
        failure ??= ErrorReporter.instance.report(e, st, operation: 'Downloading receipt $url');
      }
    }
    return failure == null ? (null, null) : (ReceiptDownloadProblem.failed, failure.diagnostics);
  }

  /// How many activity-log pages a run reads looking for where the last
  /// check stopped, before reading every expense again instead.
  @visibleForTesting
  static const activityPages = 5;
  static const _activityPageSize = 50;

  /// Marks the details of [groupId]'s expenses changed since the last
  /// complete check unknown, so they're read again, and returns the
  /// newest activity-log entry now (null for an empty log).
  ///
  /// Spliit has no `updatedAt` on expenses; its activity log records every
  /// edit made through its API (a receipt swapped on the web keeps the
  /// count, a note changes nothing the list shows). So a run reads the
  /// log back to the entry the last complete check saw. On the first
  /// check, or if that entry isn't within [activityPages] pages, every
  /// expense's details are forgotten. New expenses, recurring ones
  /// included (they make no activity), come from the list with theirs
  /// unknown.
  ///
  /// A server without the log ([ReceiptDownloadProblem.noActivityLog])
  /// can't tell what changed (#237). A log that can't be read for another
  /// unexpected reason is reported and returned: what changed since isn't
  /// read this time, and the check doesn't move on.
  Future<({Activity? newest, ReceiptDownloadProblem? problem, ReportedError? failure})> _forgetChanged(
      String groupId, SpliitClient client) async {
    final row = await db.groupRow(groupId);
    final checked = row?.receiptsCheckedActivityId;
    final checkedAt = row?.receiptsCheckedAt;
    final updated = <String>{};
    Activity? newest;
    var reachedCheck = false;
    try {
      var cursor = 0;
      for (var page = 0; page < activityPages && !reachedCheck; page++) {
        final result =
            await client.fetchActivities(groupId: groupId, cursor: cursor, limit: _activityPageSize);
        for (final a in result.activities) {
          newest ??= a;
          // The entry itself, or anything older if it's gone.
          if (a.id == checked || (checkedAt != null && a.time.isBefore(checkedAt))) {
            reachedCheck = true;
            break;
          }
          if (a.activityType == ActivityType.updateExpense && a.expenseId != null) {
            updated.add(a.expenseId!);
          }
        }
        if (!result.hasMore) {
          // The whole log is read: nothing older to miss.
          reachedCheck = true;
          break;
        }
        cursor = result.nextCursor;
      }
    } catch (e, st) {
      if (classifyError(e) == ErrorKind.connection) rethrow;
      if (e is SpliitApiException && e.isNotFound) {
        return (newest: null, problem: ReceiptDownloadProblem.noActivityLog, failure: null);
      }
      final failure = ErrorReporter.instance.report(e, st, operation: 'Reading the activity log of $groupId');
      return (newest: null, problem: null, failure: failure);
    }
    if (checked == null || !reachedCheck) {
      // The first check, or too much changed since: every expense.
      await db.forgetExpenseDetails(groupId);
    } else if (updated.isNotEmpty) {
      await db.forgetExpenseDetails(groupId, ids: updated);
    }
    return (newest: newest, problem: null, failure: null);
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
  final _cancelled = Completer<void>();
  bool cancelled = false;
  bool removed = false;

  /// Past checking the network: downloading.
  bool downloading = false;
  ReceiptDownloadProblem? reason;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel(ReceiptDownloadProblem? why) {
    if (cancelled) return;
    cancelled = true;
    reason = why;
    _cancelled.complete();
    // Aborts the transfer in flight: nothing more over mobile data.
    client.close();
  }
}
