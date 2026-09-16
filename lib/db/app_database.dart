import 'dart:convert';
import 'package:drift/drift.dart';

import '../models/expense.dart';
import '../models/group.dart';

part 'app_database.g.dart';

/// Last-synced snapshot of a group's expenses, plus any created locally
/// while offline. [pending] is the whole sync model: true means "not yet
/// confirmed by the server," and the outbox (lib/sync/outbox.dart) is
/// responsible for POSTing pending rows and flipping the flag once the
/// server confirms. There's no other state and no merge logic -- reads
/// simply overwrite non-pending rows on each successful fetch.
///
/// [paidForJson] stores the List<ExpenseShare> as JSON text -- drift has
/// no native list-of-objects column type, and this data is only ever
/// read back to replay a create or render one expense's split, never
/// queried on, so a plain JSON blob is simpler than a join table.
///
/// Named explicitly via @DataClassName because drift's default row-class
/// name for a table called "Expenses" is "Expense" -- which would collide
/// with our own Expense DTO (models/expense.dart) imported in this file.
@DataClassName('ExpenseRow')
class Expenses extends Table {
  TextColumn get id => text()();
  TextColumn get groupId => text()();
  TextColumn get title => text()();
  IntColumn get amountCents => integer()();
  TextColumn get paidBy => text()();
  TextColumn get paidForJson => text()();
  TextColumn get splitMode => text().withDefault(const Constant('EVENLY'))();
  IntColumn get category => integer().withDefault(const Constant(0))();
  TextColumn get notes => text().withDefault(const Constant(''))();
  DateTimeColumn get date => dateTime()();
  BoolColumn get isReimbursement => boolean().withDefault(const Constant(false))();
  BoolColumn get pending => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Last-synced group info, including participants -- needed offline for
/// more than just display: the add-expense form needs the participant
/// list to build an even split without a network round-trip. This table
/// existed unused since the first scaffold; the bug that exposed the gap
/// (add button staying disabled on a cold, offline start, because
/// GroupScreen only ever got `_group` from a live fetchGroup() call that
/// throws when offline) is what prompted actually wiring it up.
///
/// [participantsJson] is a JSON blob for the same reason paidForJson is
/// on Expenses: drift has no native list-of-objects column, and this is
/// only ever read back whole, never queried into.
@DataClassName('GroupRow')
class Groups extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get currency => text()();
  TextColumn get participantsJson => text().withDefault(const Constant('[]'))();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Expenses, Groups])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // Groups table gained participantsJson (see class doc) --
            // needed to cache the group offline, not just expenses.
            await m.addColumn(groups, groups.participantsJson);
          }
        },
      );

  Future<List<ExpenseRow>> expensesForGroup(String groupId) {
    return (select(expenses)
          ..where((e) => e.groupId.equals(groupId))
          ..orderBy([(e) => OrderingTerm.desc(e.date)]))
        .get();
  }

  Future<List<ExpenseRow>> pendingExpenses() {
    return (select(expenses)..where((e) => e.pending.equals(true))).get();
  }

  /// Overwrites the cached (non-pending) rows for a group with a fresh
  /// fetch from the server. Pending rows are left untouched -- they're
  /// only cleared by the outbox once the server confirms them.
  Future<void> replaceServerExpenses(String groupId, List<Expense> fresh) async {
    await transaction(() async {
      await (delete(expenses)
            ..where((e) => e.groupId.equals(groupId) & e.pending.equals(false)))
          .go();
      await batch((b) => b.insertAll(expenses, fresh.map(toCompanion).toList()));
    });
  }

  /// Inserts a locally-created expense as pending, to be replayed by the
  /// outbox. [localId] should be a locally-generated unique id (a uuid) --
  /// it's replaced with the server's real id once synced.
  Future<void> insertPending(Expense e) {
    return into(expenses).insert(toCompanion(e));
  }

  ExpensesCompanion toCompanion(Expense e) => ExpensesCompanion.insert(
        id: e.id,
        groupId: e.groupId,
        title: e.title,
        amountCents: e.amountCents,
        paidBy: e.paidBy,
        paidForJson: jsonEncode(e.paidFor.map((s) => s.toJson()).toList()),
        splitMode: Value(e.splitMode.wireValue),
        category: Value(e.category),
        notes: Value(e.notes),
        date: e.date,
        isReimbursement: Value(e.isReimbursement),
        pending: Value(e.pending),
      );

  /// Overwrites the cached group info (name, currency, participants).
  /// Called after every successful fetchGroup(), same pattern as
  /// replaceServerExpenses -- no merge logic, just last-fetch-wins.
  Future<void> cacheGroup(Group g) {
    return into(groups).insertOnConflictUpdate(GroupsCompanion.insert(
      id: g.id,
      name: g.name,
      currency: g.currency,
      participantsJson: Value(jsonEncode(g.participants.map((p) => p.toJson()).toList())),
    ));
  }

  /// The last-cached group, or null if we've never successfully fetched
  /// it (e.g. first-ever launch happens to be offline).
  Future<Group?> cachedGroup(String groupId) async {
    final row = await (select(groups)..where((g) => g.id.equals(groupId)))
        .getSingleOrNull();
    if (row == null) return null;
    return Group(
      id: row.id,
      name: row.name,
      currency: row.currency,
      participants: (jsonDecode(row.participantsJson) as List)
          .map((p) => Participant.fromJson(p as Map<String, dynamic>))
          .toList(),
    );
  }

  Expense rowToExpense(ExpenseRow row) => Expense(
        id: row.id,
        groupId: row.groupId,
        title: row.title,
        amountCents: row.amountCents,
        paidBy: row.paidBy,
        paidFor: (jsonDecode(row.paidForJson) as List)
            .map((s) => ExpenseShare.fromJson(s as Map<String, dynamic>))
            .toList(),
        splitMode: SplitModeWire.fromWire(row.splitMode),
        category: row.category,
        notes: row.notes,
        date: row.date,
        isReimbursement: row.isReimbursement,
        pending: row.pending,
      );
}
