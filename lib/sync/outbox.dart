import 'package:drift/drift.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';

/// The entire sync engine. Because the app only supports offline *view*
/// and *add* (never offline edit), there's no conflict resolution to do --
/// see decisions/mobile-platform.md. This just replays queued creates
/// against the server when asked to (call [flush] whenever connectivity
/// changes to online, e.g. from a connectivity_plus listener).
class Outbox {
  final AppDatabase _db;
  final SpliitClient _api;

  Outbox(this._db, this._api);

  /// Attempts to sync every pending expense. Each row is synced
  /// independently -- one failure (still offline, server rejected it,
  /// etc.) doesn't block the rest, and the row is simply left pending to
  /// retry on the next flush.
  Future<void> flush() async {
    final pending = await _db.pendingExpenses();
    for (final local in pending) {
      try {
        final created = await _api.createExpense(
          groupId: local.groupId,
          title: local.title,
          amountCents: local.amountCents,
          paidBy: local.paidBy,
          date: local.date,
        );
        await _db.transaction(() async {
          await (_db.delete(_db.expenses)..whereSamePrimaryKey(local)).go();
          await _db.into(_db.expenses).insert(
                ExpensesCompanion.insert(
                  id: created.id,
                  groupId: created.groupId,
                  title: created.title,
                  amountCents: created.amountCents,
                  paidBy: created.paidBy,
                  date: created.date,
                  pending: const Value(false),
                ),
              );
        });
      } catch (_) {
        // Left pending; next flush() (e.g. on the next connectivity
        // change) will retry it. TODO: cap retries / surface a
        // user-visible "couldn't sync" state after N failures.
      }
    }
  }
}
