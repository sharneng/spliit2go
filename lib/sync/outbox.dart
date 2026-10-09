import 'package:drift/drift.dart' show Value;

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../models/expense.dart';
import '../services/error_reporting.dart';
import '../services/receipt_cache.dart';

/// The entire sync engine. Because the app only supports offline *view*
/// and *add* (never offline edit), there's no conflict resolution to do --
/// see decisions/mobile-platform.md. This just replays queued creates
/// against the server when asked to (call [flush] whenever connectivity
/// changes to online, e.g. from a connectivity_plus listener, and once at
/// app start).
class Outbox {
  final AppDatabase _db;
  final SpliitClient _api;

  /// The single group this instance is scoped to -- see [flush]'s own
  /// doc comment for why. Bound once at construction (issue #52) rather
  /// than accepted as a [flush] parameter: this [Outbox] is already
  /// built fresh per-group at every real call site (main.dart,
  /// group_list_screen.dart), with [_api] itself fixed to that group's
  /// server, so a groupId parameter on [flush] could never legitimately
  /// differ from this one -- it just left the invariant unenforced,
  /// where a mismatched value would have silently replayed one group's
  /// pending rows against another group's server. Making it a required
  /// constructor field turns "forgot to update a call site" into a
  /// compile error instead of a latent runtime bug.
  final String groupId;

  /// After this many failed attempts, [flush] gives up retrying a row
  /// automatically and marks it [Expenses.syncFailed] regardless of the
  /// error (issue #44) -- otherwise a persistently-unreachable server,
  /// or any other repeatedly-failing-but-not-obviously-permanent error,
  /// would retry the same row forever on every flush. A 4xx response
  /// gives up immediately instead, on the first attempt -- see [flush]'s
  /// own body for why that's treated differently.
  static const maxRetries = 5;

  Outbox(this._db, this._api, {required this.groupId});

  /// The last flush queued per database and group (#141). Outboxes are
  /// built per call site, so the queue can't live on one instance: two
  /// overlapping flushes would both read the same pending expense and
  /// create it twice.
  static final _queues = Expando<Map<String, Future<void>>>('Outbox');

  /// Attempts to sync every pending, not-yet-failed expense belonging
  /// to [groupId] (see the field's own doc comment). Each row is synced
  /// independently -- one failure (still offline, server rejected it,
  /// etc.) doesn't block the rest.
  /// A failure that looks transient is simply left pending to retry on
  /// the next flush; one that looks permanent (or that's failed too
  /// many times already) is marked [Expenses.syncFailed] instead and
  /// stops being picked up here automatically until a person retries it
  /// (issue #44 -- see [maxRetries] and this method's own body).
  ///
  /// Scoped to a single group (issue #42) because this [Outbox] is
  /// itself constructed per-group, with [_api] fixed to that group's
  /// own server (see decisions/multi-group-design.md) -- flushing every
  /// pending row regardless of group used to mean a pending expense
  /// from a group on a *different* server got replayed against this
  /// one, silently corrupting it.
  ///
  /// Returns the number of rows successfully synced.
  ///
  /// Flushes of one group run one after another (#141): one asked for
  /// while another runs starts when it ends, so work queued meanwhile
  /// isn't missed.
  Future<int> flush() {
    final queue = _queues[_db] ??= {};
    final run = (queue[groupId] ?? Future.value()).then((_) => _flush());
    queue[groupId] = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<int> _flush() async {
    final pendingRows = await _db.pendingExpensesForGroup(groupId);
    var synced = 0;
    for (final row in pendingRows) {
      final local = _db.rowToExpense(row);
      // Whether a failure came from uploading its receipts (#124).
      var uploading = true;
      try {
        // A new expense syncs together with its receipts (#124, as
        // revised with Kenneth and Ezra): its photos go up first, and
        // it's created only once they all have, with all of them.
        final photos = [
          for (final a in await _db.attachmentsFor(row.id)) await _upload(a),
        ];
        uploading = false;
        final serverId = await _api.createExpense(
          groupId: local.groupId,
          title: local.title,
          amountCents: local.amountCents,
          paidBy: local.paidBy,
          paidFor: local.paidFor,
          splitMode: local.splitMode,
          category: local.category,
          notes: local.notes,
          date: local.date,
          isSettlement: local.isSettlement,
          recurrenceRule: local.recurrenceRule,
          originalAmountCents: local.originalAmountCents,
          originalCurrency: local.originalCurrency,
          conversionRate: local.conversionRate,
          // Whoever was the active user when this was added, not now
          // (issue #92) -- see Expenses.addedByParticipantId.
          participantId: row.addedByParticipantId,
          // Uploaded when they were attached (#123).
          // Uploaded in the form (#123), and just now (#124).
          documents: [...local.documents, ...photos],
        );
        // Updates the row in place rather than deleting it (issue #43)
        // -- deleting here and relying on the caller's follow-up
        // fetchExpenses() to bring the row back meant a network drop
        // between the two calls left the just-synced expense absent
        // from the local cache (and so missing from the list and
        // balance math) until the next successful refresh, whenever
        // that happened to be.
        await _db.markSynced(localId: row.id, serverId: serverId);
        synced++;
      } catch (e, st) {
        // Logged unless it's a connection problem (#119 review): a
        // rejected or malformed sync is worth a trace.
        ErrorReporter.instance.report(e, st, operation: 'Syncing expense ${row.id}');
        // Left pending either way -- the row still hasn't synced. But
        // whether it's retried automatically on the *next* flush
        // depends on what went wrong (issue #44):
        //
        // - A 4xx [SpliitApiException] means the server is actively
        //   rejecting this specific request (bad data, a participant
        //   that no longer exists, ...) -- retrying the exact same
        //   payload unchanged would never succeed, so give up on the
        //   first failure rather than pointlessly hammering the server
        //   with the same rejected request on every future flush.
        // - Anything else (still offline, a 5xx, a transient network
        //   error) is presumed retriable, but only up to [maxRetries]
        //   attempts -- past that, something's persistently wrong and
        //   it needs a person's attention rather than silently retrying
        //   forever in the background.
        //
        // Either way the row is marked syncFailed and stops being
        // picked up by pendingExpensesForGroup; the UI offers a
        // retry/delete affordance instead (see GroupScreen's expense
        // list).
        final isClientError = e is SpliitApiException && e.statusCode >= 400 && e.statusCode < 500;
        // A receipt the server didn't take, for any reason but the
        // connection, won't go up by itself either (#124). The expense's
        // details offer Retry, Sync without receipts, or Discard.
        final receiptRefused = uploading && classifyError(e) != ErrorKind.connection;
        final retryCount = row.retryCount + 1;
        await _db.recordSyncFailure(
          id: row.id,
          error: e.toString(),
          retryCount: retryCount,
          failed: isClientError || receiptRefused || retryCount >= maxRetries,
        );
      }
    }
    return synced;
  }

  /// Gets a photo into the bucket (#124) and returns it as the document
  /// the create sends; throws what the upload threw.
  ///
  /// The public URL is recorded before the transfer: if the app stops
  /// mid-upload, the next flush asks the bucket whether the object
  /// arrived, and signs and uploads again if not. That can leave an
  /// orphan object in the bucket, which is accepted; exactly-once uploads
  /// aren't promised.
  Future<ExpenseDocument> _upload(ReceiptAttachmentRow a) async {
    var url = a.url;
    final arrived = switch (a.state) {
      AttachmentState.uploaded => true,
      AttachmentState.uploading => url != null && await _api.receiptExists(url),
      AttachmentState.local => false,
    };
    if (!arrived) {
      final bytes = await (await ReceiptCache.of(_db).fileNamed(a.fileName)).readAsBytes();
      final target = await _api.signReceiptUpload();
      url = target.publicUrl;
      await _db.updateAttachment(a.id,
          ReceiptAttachmentsCompanion(state: const Value(AttachmentState.uploading), url: Value(url)));
      await _api.putReceipt(target, bytes);
      await _db.updateAttachment(
          a.id, const ReceiptAttachmentsCompanion(state: Value(AttachmentState.uploaded)));
    }
    return ExpenseDocument(id: a.id, url: url!, width: a.width, height: a.height);
  }
}
