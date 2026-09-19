import 'dart:convert';
import 'package:drift/drift.dart';

import '../models/default_split.dart';
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

  /// How many times [Outbox.flush] has tried and failed to sync this
  /// row (issue #44). Reset to 0 whenever the row is (re)inserted as
  /// pending -- including an explicit user retry, which re-queues it
  /// the same way a fresh offline add does.
  IntColumn get retryCount => integer().withDefault(const Constant(0))();

  /// The most recent sync failure's message (typically a
  /// [SpliitApiException]'s `toString()`), or null if this row has
  /// never failed to sync. Kept even after [syncFailed] is cleared by a
  /// retry, so "what went wrong last time" survives until the next
  /// attempt actually overwrites it -- only cleared back to null once a
  /// sync attempt succeeds.
  TextColumn get lastError => text().nullable()();

  /// True once [Outbox.flush] has given up retrying this row on its
  /// own (issue #44) -- either a 4xx response (the server is rejecting
  /// the request itself, not just unreachable) or [retryCount] passing
  /// a small fixed limit. A failed row is left [pending] (it still
  /// hasn't synced) but is no longer picked up by ordinary flushes,
  /// exactly to stop what would otherwise be an infinite retry loop
  /// hammering the server with a request it's already rejected; the UI
  /// shows it as needing the user's attention (retry or delete) instead.
  BoolColumn get syncFailed => boolean().withDefault(const Constant(false))();

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

  /// Group information/notes (issue #23) -- null/empty for a group with
  /// none set.
  TextColumn get information => text().nullable()();

  /// ISO currency code backing [currency], or null for a custom
  /// currency with no real code -- see Group.currencyCode's doc comment.
  TextColumn get currencyCode => text().nullable()();

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

  /// This device's remembered "Paid for" split for this group (issue
  /// #29, decisions/paid-for-split-ux-spec.md) -- [DefaultSplit.splitMode]
  /// as its wire value. Null means nothing's been remembered yet.
  /// Deliberately a separate column from [defaultSplitSharesJson] rather
  /// than one combined blob: the mode alone is meaningful (and often the
  /// *only* thing worth keeping -- see [DefaultSplit.shares]'s doc
  /// comment) even when there's no share map to go with it, and this
  /// matches the flat-typed-column style the rest of this table already
  /// uses rather than introducing a JSON-blob-of-everything convention.
  TextColumn get defaultSplitMode => text().nullable()();

  /// The remembered split's [DefaultSplit.shares] -- a JSON-encoded
  /// `{participantId: shares}` map on the same wire scale
  /// [ExpenseShare.shares] uses, or null (see that field's doc comment
  /// for when and why). Same JSON-blob-for-a-map-we-never-query-into
  /// pattern as [participantsJson]/[paidForJson].
  TextColumn get defaultSplitSharesJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Expenses, Groups])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 7;

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
          if (from < 5) {
            // Complete-group-settings-screen fields (issue #23) -- see
            // class doc on each column.
            await m.addColumn(groups, groups.information);
            await m.addColumn(groups, groups.currencyCode);
          }
          if (from < 6) {
            // Remembered "Paid for" split (issue #29) -- see class doc
            // on each column.
            await m.addColumn(groups, groups.defaultSplitMode);
            await m.addColumn(groups, groups.defaultSplitSharesJson);
          }
          if (from < 7) {
            // Outbox retry limit / failure state (issue #44) -- see
            // class doc on each column.
            await m.addColumn(expenses, expenses.retryCount);
            await m.addColumn(expenses, expenses.lastError);
            await m.addColumn(expenses, expenses.syncFailed);
          }
        },
      );

  Future<List<ExpenseRow>> expensesForGroup(String groupId) {
    return (select(expenses)
          ..where((e) => e.groupId.equals(groupId))
          ..orderBy([(e) => OrderingTerm.desc(e.date)]))
        .get();
  }

  /// Same query as [expensesForGroup], as a live [Stream] instead of a
  /// one-shot [Future] (issue #47) -- emits the current rows immediately
  /// on subscribe, then again every time this group's Expenses rows
  /// change (a live refresh's [replaceServerExpenses], a locally-added
  /// [insertPending] row, [markSynced], [recordSyncFailure],
  /// [retrySyncFailure], [deleteFailedExpense]...). Lets callers
  /// (GroupScreen, BalancesScreen, StatsScreen) just subscribe once and
  /// stay current, instead of imperatively re-querying after every
  /// mutation.
  Stream<List<ExpenseRow>> watchExpensesForGroup(String groupId) {
    return (select(expenses)
          ..where((e) => e.groupId.equals(groupId))
          ..orderBy([(e) => OrderingTerm.desc(e.date)]))
        .watch();
  }

  Future<List<ExpenseRow>> pendingExpenses() {
    return (select(expenses)..where((e) => e.pending.equals(true))).get();
  }

  /// Same as [pendingExpenses], scoped to one group (issue #42) and
  /// excluding rows [Outbox] has already given up retrying (issue #44,
  /// see [Expenses.syncFailed]'s own doc comment). Every group has its
  /// own server (see decisions/multi-group-design.md), and [Outbox] is
  /// constructed per-group with a single [SpliitClient] fixed to that
  /// group's server -- so [Outbox.flush] must only ever replay a
  /// group's own pending rows against its own client. Flushing with the
  /// unscoped [pendingExpenses] would also pick up another group's
  /// still-pending rows (added offline, not yet synced) and replay them
  /// against the wrong server entirely. And a syncFailed row is
  /// deliberately excluded here too -- it's still pending (hasn't
  /// synced), but automatically retrying something the server has
  /// already rejected (or that's failed repeatedly for some other
  /// reason) on every flush would just hammer it forever; a
  /// syncFailed row only gets retried again via an explicit user action
  /// ([retrySyncFailure]).
  Future<List<ExpenseRow>> pendingExpensesForGroup(String groupId) {
    return (select(expenses)
          ..where((e) =>
              e.pending.equals(true) & e.groupId.equals(groupId) & e.syncFailed.equals(false)))
        .get();
  }

  /// Marks a pending row as synced in place (issue #43), instead of the
  /// outbox deleting it outright the moment [SpliitClient.createExpense]
  /// succeeds. Deleting-then-relying-on-the-caller's-next-fetchExpenses()
  /// meant a network drop between those two calls left a genuinely-
  /// synced expense absent from the local cache -- and so missing from
  /// both the expense list and balance math -- until whatever *next*
  /// refresh happened to succeed.
  ///
  /// Switches the row's primary key from [localId] (the client-generated
  /// id it was created under) to [serverId] and clears [Expenses.pending]
  /// -- an ordinary UPDATE, not a delete+reinsert, so the row is never
  /// briefly absent. [serverId] can be the same as [localId] when
  /// [SpliitClient.createExpense] couldn't parse an id out of the
  /// server's response (see that method's own doc comment on why it can
  /// return `''`); in that case this just clears [Expenses.pending] and
  /// leaves the row under its local id until the next full
  /// [replaceServerExpenses] reconciles it -- exactly the outcome a
  /// normal successful refresh already produces today, just without the
  /// in-between gap.
  Future<void> markSynced({required String localId, required String serverId}) {
    final newId = serverId.isNotEmpty ? serverId : localId;
    return (update(expenses)..where((e) => e.id.equals(localId))).write(
      ExpensesCompanion(
        id: Value(newId),
        pending: const Value(false),
        // A synced row can't also be a failed one -- clear whatever a
        // prior failed attempt (before a successful retry) left behind
        // (issue #44).
        retryCount: const Value(0),
        lastError: const Value(null),
        syncFailed: const Value(false),
      ),
    );
  }

  /// Records a failed sync attempt on a still-pending row (issue #44):
  /// bumps [Expenses.retryCount], remembers the error, and sets
  /// [Expenses.syncFailed] once [Outbox.flush] has decided to stop
  /// retrying it automatically -- see that method's own doc comment for
  /// exactly when ([failed] is computed there, not here). The row stays
  /// [Expenses.pending] regardless: syncFailed only stops *automatic*
  /// retries picked up by [pendingExpensesForGroup], it doesn't mean the
  /// expense is gone or somehow no longer needs to sync.
  Future<void> recordSyncFailure({
    required String id,
    required String error,
    required int retryCount,
    required bool failed,
  }) {
    return (update(expenses)..where((e) => e.id.equals(id))).write(
      ExpensesCompanion(
        retryCount: Value(retryCount),
        lastError: Value(error),
        syncFailed: Value(failed),
      ),
    );
  }

  /// Re-queues a failed row for automatic retry (issue #44) -- backs
  /// the "Retry" action on a sync-failed expense. Clears
  /// [Expenses.syncFailed] and resets [Expenses.retryCount] to 0, so
  /// the next [Outbox.flush] picks it back up (via
  /// [pendingExpensesForGroup]) with a full fresh set of attempts, the
  /// same as a brand new offline add. [Expenses.lastError] is
  /// deliberately left alone -- still useful context ("what went wrong
  /// last time") until the next attempt overwrites it (on another
  /// failure) or clears it (on success, via [markSynced]).
  Future<void> retrySyncFailure(String id) {
    return (update(expenses)..where((e) => e.id.equals(id))).write(
      const ExpensesCompanion(
        retryCount: Value(0),
        syncFailed: Value(false),
      ),
    );
  }

  /// Discards a sync-failed row outright (issue #44) -- backs the
  /// "Delete" action on a sync-failed expense. Only ever offered by the
  /// UI for a row that's still [Expenses.pending] (never reached the
  /// server), which is the only case this is safe for: deleting a row
  /// that already synced would just make it reappear on the next
  /// [replaceServerExpenses]-backed refresh, since the server still has
  /// it.
  Future<void> deleteFailedExpense(String id) {
    return (delete(expenses)..where((e) => e.id.equals(id))).go();
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
      information: Value(g.information),
      currencyCode: Value(g.currencyCode),
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
      information: row.information,
      currency: row.currency,
      currencyCode: row.currencyCode,
      participants: (jsonDecode(row.participantsJson) as List)
          .map((p) => Participant.fromJson(p as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Same data as [cachedGroup], as a live [Stream] instead of a
  /// one-shot [Future] (issue #47) -- emits the current cached group
  /// (or null) immediately on subscribe, then again every time this
  /// group's Groups row changes, e.g. [cacheGroup] after a live
  /// [SpliitClient.fetchGroup] refresh, or a settings-screen save.
  /// Lets GroupScreen subscribe once instead of separately loading from
  /// cache on start *and* adopting GroupSettingsScreen's popped result.
  Stream<Group?> watchCachedGroup(String groupId) {
    return (select(groups)..where((g) => g.id.equals(groupId)))
        .watchSingleOrNull()
        .map((row) {
      if (row == null) return null;
      return Group(
        id: row.id,
        name: row.name,
        information: row.information,
        currency: row.currency,
        currencyCode: row.currencyCode,
        participants: (jsonDecode(row.participantsJson) as List)
            .map((p) => Participant.fromJson(p as Map<String, dynamic>))
            .toList(),
      );
    });
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

  /// Sets (or, with null, clears) this device's remembered "Paid for"
  /// split for [groupId] (issue #29) -- see [DefaultSplit] and the
  /// [Groups.defaultSplitMode]/[Groups.defaultSplitSharesJson] column
  /// docs. Callers should only pass non-null after a save has actually
  /// succeeded -- a split remembered from a save the server rejected
  /// would go on prefilling expenses that never happened.
  Future<void> setDefaultSplit(String groupId, DefaultSplit? split) {
    return (update(groups)..where((g) => g.id.equals(groupId))).write(GroupsCompanion(
      defaultSplitMode: Value(split?.splitMode.wireValue),
      defaultSplitSharesJson:
          Value(split?.shares == null ? null : jsonEncode(split!.shares)),
    ));
  }

  /// This device's remembered "Paid for" split for [groupId], or null if
  /// nothing's been remembered (including: the group has never been
  /// cached at all). Doesn't check [DefaultSplit.appliesTo] against the
  /// group's current participants -- that's the caller's job, since only
  /// the caller has an up-to-date participant list to check against.
  Future<DefaultSplit?> defaultSplitFor(String groupId) async {
    final row = await groupRow(groupId);
    final mode = row?.defaultSplitMode;
    if (mode == null) return null;
    final sharesJson = row!.defaultSplitSharesJson;
    return DefaultSplit(
      splitMode: SplitModeWire.fromWire(mode),
      shares: sharesJson == null
          ? null
          : (jsonDecode(sharesJson) as Map<String, dynamic>)
              .map((k, v) => MapEntry(k, (v as num).round())),
    );
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
        syncFailed: row.syncFailed,
        lastError: row.lastError,
      );
}
