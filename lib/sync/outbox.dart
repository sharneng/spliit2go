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
  /// Receipt photos that aren't uploaded yet (#124) are uploaded first: a
  /// pending expense is created with the ones that made it, and the rest
  /// stay attached to it, pending, once it's synced. The expense is never
  /// held back by a photo. Then photos pending on synced expenses are
  /// added to them (see [_attachToSynced]).
  Future<int> flush() async {
    final pendingRows = await _db.pendingExpensesForGroup(groupId);
    final attachments = await _db.attachmentsToSync(groupId);
    var synced = 0;
    for (final row in pendingRows) {
      final local = _db.rowToExpense(row);
      final uploaded = await _uploadAll([
        for (final a in attachments)
          if (a.expenseId == row.id) a,
      ]);
      try {
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
          isReimbursement: local.isReimbursement,
          recurrenceRule: local.recurrenceRule,
          originalAmountCents: local.originalAmountCents,
          originalCurrency: local.originalCurrency,
          conversionRate: local.conversionRate,
          // Whoever was the active user when this was added, not now
          // (issue #92) -- see Expenses.addedByParticipantId.
          participantId: row.addedByParticipantId,
          // Uploaded in the form (#123), and since (#124).
          documents: [...local.documents, for (final a in uploaded) _documentOf(a)],
        );
        // Updates the row in place rather than deleting it (issue #43)
        // -- deleting here and relying on the caller's follow-up
        // fetchExpenses() to bring the row back meant a network drop
        // between the two calls left the just-synced expense absent
        // from the local cache (and so missing from the list and
        // balance math) until the next successful refresh, whenever
        // that happened to be.
        await _db.markSynced(
            localId: row.id, serverId: serverId, attached: [for (final a in uploaded) a.id]);
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
        final retryCount = row.retryCount + 1;
        await _db.recordSyncFailure(
          id: row.id,
          error: e.toString(),
          retryCount: retryCount,
          failed: isClientError || retryCount >= maxRetries,
        );
      }
    }
    await _attachToSynced();
    return synced;
  }

  ExpenseDocument _documentOf(ReceiptAttachmentRow a) =>
      ExpenseDocument(id: a.id, url: a.url!, width: a.width, height: a.height);

  /// Uploads [rows] one by one, and returns the ones now in the bucket.
  Future<List<ReceiptAttachmentRow>> _uploadAll(List<ReceiptAttachmentRow> rows) async => [
        for (final a in rows)
          if (await _upload(a) case final done?) done,
      ];

  /// Gets [a] into the bucket, or returns null.
  ///
  /// The public URL is recorded before the transfer (#124): if the app
  /// stops mid-upload, the next flush asks the bucket whether the object
  /// arrived, and signs and uploads again if not. That can leave an
  /// orphan object in the bucket, which is accepted; exactly-once uploads
  /// aren't promised.
  ///
  /// A connection failure leaves it for the next flush. Anything else is
  /// unexpected (#119): logged, and [AttachmentState.failed] until Retry.
  Future<ReceiptAttachmentRow?> _upload(ReceiptAttachmentRow a) async {
    try {
      if (a.state == AttachmentState.uploaded) return a;
      if (a.state == AttachmentState.uploading && a.url != null && await _api.receiptExists(a.url!)) {
        return await _uploaded(a, a.url!);
      }
      final bytes = await (await ReceiptCache.of(_db).fileNamed(a.fileName)).readAsBytes();
      final target = await _api.signReceiptUpload();
      await _db.updateAttachment(
          a.id,
          ReceiptAttachmentsCompanion(
              state: const Value(AttachmentState.uploading), url: Value(target.publicUrl)));
      await _api.putReceipt(target, bytes);
      return await _uploaded(a, target.publicUrl);
    } catch (e, st) {
      await _failed([a], e, st, operation: 'Uploading receipt ${a.id}');
      return null;
    }
  }

  Future<ReceiptAttachmentRow> _uploaded(ReceiptAttachmentRow a, String url) async {
    await _db.updateAttachment(a.id,
        ReceiptAttachmentsCompanion(state: const Value(AttachmentState.uploaded), url: Value(url)));
    return a.copyWith(state: AttachmentState.uploaded, url: Value(url));
  }

  /// Reports a failure for [rows]; an unexpected one marks them failed.
  Future<void> _failed(List<ReceiptAttachmentRow> rows, Object e, StackTrace st,
      {required String operation}) async {
    final error = ErrorReporter.instance.report(e, st, operation: operation);
    if (error.kind == ErrorKind.connection) return;
    for (final a in rows) {
      await _db.updateAttachment(
          a.id,
          ReceiptAttachmentsCompanion(
              state: const Value(AttachmentState.failed), lastError: Value(error.diagnostics)));
    }
  }

  /// Adds photos pending on synced expenses to them (#124): a photo that
  /// didn't upload when its expense was created or edited, or one added
  /// to it later. Per expense: read it, add the photos missing from its
  /// documents, update.
  ///
  /// The read gives the documents' server ids, which the update sends
  /// back: update keeps the ids it's sent and deletes the rest (#128). A
  /// new document goes under its attachment id, which update keeps too,
  /// so an update repeated after a lost response adds nothing twice: the
  /// read shows it's there. This doesn't solve the lost-response problem
  /// for creating the expense itself.
  Future<void> _attachToSynced() async {
    final pendingIds = {for (final r in await _db.pendingExpensesForGroup(groupId)) r.id};
    final byExpense = <String, List<ReceiptAttachmentRow>>{};
    for (final a in await _db.attachmentsToSync(groupId)) {
      if (!pendingIds.contains(a.expenseId)) (byExpense[a.expenseId] ??= []).add(a);
    }
    for (final MapEntry(key: expenseId, value: rows) in byExpense.entries) {
      final uploaded = await _uploadAll(rows);
      if (uploaded.isEmpty) continue;
      try {
        final Expense current;
        try {
          current = await _api.fetchExpense(groupId: groupId, expenseId: expenseId);
        } on SpliitApiException catch (e) {
          if (!e.isNotFound) rethrow;
          // Deleted on the server: there's nothing to add them to, and
          // nowhere left to show them.
          for (final a in uploaded) {
            await _db.removeAttachment(a.id);
          }
          continue;
        }
        final have = {for (final d in current.documents) d.url};
        final documents = [
          ...current.documents,
          for (final a in uploaded)
            if (!have.contains(a.url)) _documentOf(a),
        ];
        if (documents.length > current.documents.length) {
          await _api.updateExpense(
            groupId: groupId,
            expenseId: expenseId,
            title: current.title,
            amountCents: current.amountCents,
            paidBy: current.paidBy,
            paidFor: current.paidFor,
            documents: documents,
            splitMode: current.splitMode,
            category: current.category,
            notes: current.notes,
            date: current.date,
            isReimbursement: current.isReimbursement,
            recurrenceRule: current.recurrenceRule,
            originalAmountCents: current.originalAmountCents,
            originalCurrency: current.originalCurrency,
            conversionRate: current.conversionRate,
          );
          // A refresh fetched before this mustn't write the old copy
          // back (issue #90).
          _db.markExpensesChanged(groupId);
        }
        await _db.attachmentsAttached(
            groupId: groupId,
            expenseId: expenseId,
            documents: documents,
            attached: [for (final a in uploaded) a.id]);
      } catch (e, st) {
        await _failed(uploaded, e, st, operation: 'Adding receipts to expense $expenseId');
      }
    }
  }
}
