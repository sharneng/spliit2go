import '../api/spliit_client.dart';
import '../db/app_database.dart';

/// The entire sync engine. Because the app only supports offline *view*
/// and *add* (never offline edit), there's no conflict resolution to do --
/// see decisions/mobile-platform.md. This just replays queued creates
/// against the server when asked to (call [flush] whenever connectivity
/// changes to online, e.g. from a connectivity_plus listener, and once at
/// app start).
class Outbox {
  final AppDatabase _db;
  final SpliitClient _api;

  Outbox(this._db, this._api);

  /// Attempts to sync every pending expense belonging to [groupId].
  /// Each row is synced independently -- one failure (still offline,
  /// server rejected it, etc.) doesn't block the rest, and the row is
  /// simply left pending to retry on the next flush.
  ///
  /// Scoped to a single group (issue #42) because this [Outbox] is
  /// itself constructed per-group, with [_api] fixed to that group's
  /// own server (see decisions/multi-group-design.md) -- flushing every
  /// pending row regardless of group used to mean a pending expense
  /// from a group on a *different* server got replayed against this
  /// one, silently corrupting it.
  ///
  /// Returns the number of rows successfully synced.
  Future<int> flush(String groupId) async {
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
      } catch (_) {
        // Left pending; next flush() (e.g. on the next connectivity
        // change) will retry it. TODO: cap retries / surface a
        // user-visible "couldn't sync" state after N failures.
      }
    }
    return synced;
  }
}
