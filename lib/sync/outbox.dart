import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../services/error_reporting.dart';

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
  Future<int> flush() async {
    final pendingRows = await _db.pendingExpensesForGroup(groupId);
    var synced = 0;
    for (final row in pendingRows) {
      final local = _db.rowToExpense(row);
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
        final retryCount = row.retryCount + 1;
        await _db.recordSyncFailure(
          id: row.id,
          error: e.toString(),
          retryCount: retryCount,
          failed: isClientError || retryCount >= maxRetries,
        );
      }
    }
    return synced;
  }
}
