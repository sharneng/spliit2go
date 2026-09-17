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
  TextColumn get recurrenceRule => text().withDefault(const Constant('NONE'))();

  /// Set together only when the expense was entered in a currency other
  /// than the group's ("Paid in") -- see the field docs on models/expense
  /// Expense for the exact semantics. All null for a plain expense
  /// entered directly in the group's currency.
  IntColumn get originalAmountCents => integer().nullable()();
  TextColumn get originalCurrency => text().nullable()();
  RealColumn get conversionRate => real().nullable()();

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

  /// Which server this group lives on -- multi-group support (backlog
  /// #4, see decisions/multi-group-design.md) means server URL is
  /// per-group, not the single app-wide value it used to be. Empty for
  /// a row that predates multi-group support and hasn't been through
  /// the one-time startup migration in main.dart yet (that migration
  /// needs the old single global SettingsService value, not just a
  /// column default, so it can't be a plain drift migration).
  TextColumn get serverUrl => text().withDefault(const Constant(''))();

  /// This device's chosen "who am I" for this specific group -- see
  /// resolveActiveParticipant in lib/services/active_user.dart. Null
  /// until it's been auto-matched against the device's default name or
  /// explicitly picked.
  TextColumn get activeParticipantId => text().nullable()();

  /// When this group was last opened on this device. Drives both
  /// "launch straight into the last group" and the group list's
  /// ordering (decisions/multi-group-design.md, decision 3). Null only
  /// for a legacy pre-multi-group row before the startup migration.
  DateTimeColumn get lastOpenedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Expenses, Groups])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // Groups table gained participantsJson (see class doc) --
            // needed to cache the group offline, not just expenses.
            await m.addColumn(groups, groups.participantsJson);
          }
          if (from < 3) {
            // Multi-group support -- see class doc on each column.
            await m.addColumn(groups, groups.serverUrl);
            await m.addColumn(groups, groups.activeParticipantId);
            await m.addColumn(groups, groups.lastOpenedAt);
          }
          if (from < 4) {
            // Complete-add-expense-screen fields (issue #16) -- see class
            // doc on each column.
            await m.addColumn(expenses, expenses.recurrenceRule);
            await m.addColumn(expenses, expenses.originalAmountCents);
            await m.addColumn(expenses, expenses.originalCurrency);
            await m.addColumn(expenses, expenses.conversionRate);
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
        recurrenceRule: Value(e.recurrenceRule.wireValue),
        originalAmountCents: Value(e.originalAmountCents),
        originalCurrency: Value(e.originalCurrency),
        conversionRate: Value(e.conversionRate),
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

  /// The raw cached row for a group, including the multi-group columns
  /// ([GroupRow.serverUrl], [GroupRow.activeParticipantId],
  /// [GroupRow.lastOpenedAt]) that [cachedGroup] doesn't expose since it
  /// only ever returns the [Group] model. Null if this group has never
  /// been cached.
  Future<GroupRow?> groupRow(String groupId) {
    return (select(groups)..where((g) => g.id.equals(groupId))).getSingleOrNull();
  }

  /// Every group this device has joined, most-recently-opened first --
  /// backs the group list screen and (via [mostRecentlyOpenedGroup]) the
  /// launch-straight-into-the-last-group fast path. Filtered to rows
  /// with a [GroupRow.lastOpenedAt] because that's set exactly when
  /// [recordGroupOpened] runs, i.e. exactly when a group is actually
  /// "joined" in the multi-group sense -- excludes a stray legacy row
  /// that predates multi-group support and hasn't been through the
  /// startup migration yet.
  Future<List<GroupRow>> allJoinedGroups() {
    return (select(groups)
          ..where((g) => g.lastOpenedAt.isNotNull())
          ..orderBy([(g) => OrderingTerm.desc(g.lastOpenedAt)]))
        .get();
  }

  /// The single most-recently-opened group, or null if none has ever
  /// been opened (fresh install, or every group has been left) -- what
  /// main.dart's launch-straight-in fast path reads.
  Future<GroupRow?> mostRecentlyOpenedGroup() {
    return (select(groups)
          ..where((g) => g.lastOpenedAt.isNotNull())
          ..orderBy([(g) => OrderingTerm.desc(g.lastOpenedAt)])
          ..limit(1))
        .getSingleOrNull();
  }

  /// Marks [groupId] as opened on [serverUrl] just now -- call after
  /// every successful join and every time an already-joined group is
  /// opened from the list, online or offline. Deliberately a plain
  /// `update()` (touching only these two columns) rather than
  /// [cacheGroup]'s insertOnConflictUpdate: this has to be safe to call
  /// even when there's no live [Group] to cache yet (right before the
  /// join flow's first fetchGroup) or when offline (opening a cached
  /// group with no live data to refresh), and must never clobber a
  /// cached name/currency/participants that this call knows nothing
  /// about. The row must already exist -- callers create it with
  /// [cacheGroup] first if it might not (see the join flow).
  /// [at] defaults to now; overridable so callers (tests, mainly) can
  /// pass explicit, distinct timestamps -- drift's default DateTime
  /// storage is second-granularity, so two real `DateTime.now()` calls
  /// made back-to-back in the same test can tie, which is exactly the
  /// kind of flakiness this parameter exists to avoid without changing
  /// how it's actually called in the app itself.
  Future<void> recordGroupOpened(String groupId, {required String serverUrl, DateTime? at}) {
    return (update(groups)..where((g) => g.id.equals(groupId))).write(
      GroupsCompanion(serverUrl: Value(serverUrl), lastOpenedAt: Value(at ?? DateTime.now())),
    );
  }

  /// Sets (or, with null, clears) this device's chosen active
  /// participant for [groupId] -- see resolveActiveParticipant in
  /// lib/services/active_user.dart for how this gets populated and read
  /// back.
  Future<void> setActiveParticipant(String groupId, String? participantId) {
    return (update(groups)..where((g) => g.id.equals(groupId)))
        .write(GroupsCompanion(activeParticipantId: Value(participantId)));
  }

  /// Removes a group and all its cached expenses from this device --
  /// local only, never touches the server (there's no "leave group" API
  /// call; this just forgets it locally). Transactional so a group's
  /// expenses can never outlive its Groups row, or vice versa, if this
  /// is interrupted partway.
  Future<void> leaveGroup(String groupId) {
    return transaction(() async {
      await (delete(expenses)..where((e) => e.groupId.equals(groupId))).go();
      await (delete(groups)..where((g) => g.id.equals(groupId))).go();
    });
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
        recurrenceRule: RecurrenceRuleWire.fromWire(row.recurrenceRule),
        originalAmountCents: row.originalAmountCents,
        originalCurrency: row.originalCurrency,
        conversionRate: row.conversionRate,
        pending: row.pending,
      );
}
