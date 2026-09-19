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
        await _api.createExpense(
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
        // The server assigns its own id; rather than trying to learn and
        // reconcile it here, just drop the local pending row -- the next
        // fetchExpenses()-backed refresh (triggered right after a
        // successful flush) picks it back up as a normal synced row.
        await (_db.delete(_db.expenses)..where((tbl) => tbl.id.equals(row.id))).go();
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
