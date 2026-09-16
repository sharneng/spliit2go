import 'package:drift/drift.dart';

part 'app_database.g.dart';

/// Last-synced snapshot of a group's expenses, plus any created locally
/// while offline. [pending] is the whole sync model: true means "not yet
/// confirmed by the server," and the outbox (lib/sync/outbox.dart) is
/// responsible for POSTing pending rows and flipping the flag once the
/// server confirms. There's no other state and no merge logic -- reads
/// simply overwrite non-pending rows on each successful fetch.
class Expenses extends Table {
  TextColumn get id => text()();
  TextColumn get groupId => text()();
  TextColumn get title => text()();
  IntColumn get amountCents => integer()();
  TextColumn get paidBy => text()();
  DateTimeColumn get date => dateTime()();
  BoolColumn get pending => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class Groups extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get currency => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Expenses, Groups])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  Future<List<Expense>> expensesForGroup(String groupId) {
    return (select(expenses)..where((e) => e.groupId.equals(groupId))).get();
  }

  Future<List<Expense>> pendingExpenses() {
    return (select(expenses)..where((e) => e.pending.equals(true))).get();
  }

  /// Overwrites the cached (non-pending) rows for a group with a fresh
  /// fetch from the server. Pending rows are left untouched -- they're
  /// only cleared by the outbox once the server confirms them.
  Future<void> replaceServerExpenses(
    String groupId,
    List<ExpensesCompanion> fresh,
  ) async {
    await transaction(() async {
      await (delete(expenses)
            ..where((e) => e.groupId.equals(groupId) & e.pending.equals(false)))
          .go();
      await batch((b) => b.insertAll(expenses, fresh));
    });
  }
}
