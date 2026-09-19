import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/default_split.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('group cache', () {
    test('cacheGroup then cachedGroup round-trips name, currency, participants', () async {
      const group = Group(
        id: 'g1',
        name: 'Banff Trip',
        currency: '\$',
        participants: [
          Participant(id: 'p1', name: 'Ken'),
          Participant(id: 'p2', name: 'Jenny'),
        ],
      );

      await db.cacheGroup(group);
      final cached = await db.cachedGroup('g1');

      expect(cached, isNotNull);
      expect(cached!.name, 'Banff Trip');
      expect(cached.currency, '\$');
      expect(cached.participants.map((p) => p.name), containsAll(['Ken', 'Jenny']));
    });

    test('cacheGroup then cachedGroup round-trips information and currencyCode (issue #23)',
        () async {
      const group = Group(
        id: 'g1',
        name: 'Banff Trip',
        information: 'Split hotel evenly, flights separately.',
        currency: '\$',
        currencyCode: 'USD',
        participants: [Participant(id: 'p1', name: 'Ken')],
      );

      await db.cacheGroup(group);
      final cached = await db.cachedGroup('g1');

      expect(cached!.information, 'Split hotel evenly, flights separately.');
      expect(cached.currencyCode, 'USD');
    });

    test('information and currencyCode are null when never set (custom currency, no notes)',
        () async {
      const group = Group(id: 'g1', name: 'Banff Trip', currency: '\$', participants: []);

      await db.cacheGroup(group);
      final cached = await db.cachedGroup('g1');

      expect(cached!.information, isNull);
      expect(cached.currencyCode, isNull);
    });

    // Regression test: this is exactly the state a cold, offline first
    // launch was in before Groups was actually wired up on 2026-09-16 --
    // fetchGroup() throws offline, and nothing else ever populated the
    // cache, so the add button stayed permanently disabled with no way
    // to recover.
    test('cachedGroup returns null when nothing has been cached yet', () async {
      final cached = await db.cachedGroup('nonexistent');
      expect(cached, isNull);
    });

    test('cacheGroup overwrites a previous cache for the same group id', () async {
      const original = Group(id: 'g1', name: 'Old Name', currency: '\$', participants: []);
      const updated = Group(
        id: 'g1',
        name: 'New Name',
        currency: '€',
        participants: [Participant(id: 'p1', name: 'Ken')],
      );

      await db.cacheGroup(original);
      await db.cacheGroup(updated);
      final cached = await db.cachedGroup('g1');

      expect(cached!.name, 'New Name');
      expect(cached.currency, '€');
      expect(cached.participants, hasLength(1));
    });
  });

  group('expense cache', () {
    Expense expense({required String id, bool pending = false}) => Expense(
          id: id,
          groupId: 'g1',
          title: 'Coffee',
          amountCents: 500,
          paidBy: 'p1',
          paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
          date: DateTime.utc(2026, 9, 16),
          pending: pending,
        );

    test('insertPending then pendingExpenses returns it', () async {
      await db.insertPending(expense(id: 'e1', pending: true));
      final pending = await db.pendingExpenses();
      expect(pending, hasLength(1));
      expect(pending.first.id, 'e1');
    });

    test('replaceServerExpenses overwrites non-pending rows but keeps pending ones', () async {
      await db.insertPending(expense(id: 'local-1', pending: true));
      await db.replaceServerExpenses('g1', [expense(id: 'server-1')]);

      final all = await db.expensesForGroup('g1');
      final ids = all.map((r) => r.id).toSet();

      // The pending row must survive a server refresh -- it hasn't
      // synced yet, so overwriting it here would silently drop a
      // not-yet-saved expense the user is still waiting on.
      expect(ids, containsAll(['local-1', 'server-1']));
    });

    test('a second replaceServerExpenses drops stale server rows not in the new fetch', () async {
      await db.replaceServerExpenses('g1', [expense(id: 'server-1')]);
      await db.replaceServerExpenses('g1', [expense(id: 'server-2')]);

      final all = await db.expensesForGroup('g1');
      expect(all.map((r) => r.id), ['server-2']);
    });

    // Issue #16: the new columns (recurrenceRule, originalAmountCents,
    // originalCurrency, conversionRate) round-trip through toCompanion/
    // rowToExpense just like every pre-existing field.
    test('round-trips recurrenceRule and original-currency fields', () async {
      final e = Expense(
        id: 'e1',
        groupId: 'g1',
        title: 'Hotel',
        amountCents: 10000,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        date: DateTime.utc(2026, 9, 16),
        recurrenceRule: RecurrenceRule.monthly,
        originalAmountCents: 9000,
        originalCurrency: 'EUR',
        conversionRate: 1.111,
        pending: true,
      );

      await db.insertPending(e);
      final row = (await db.pendingExpenses()).single;
      final roundTripped = db.rowToExpense(row);

      expect(roundTripped.recurrenceRule, RecurrenceRule.monthly);
      expect(roundTripped.originalAmountCents, 9000);
      expect(roundTripped.originalCurrency, 'EUR');
      expect(roundTripped.conversionRate, 1.111);
    });

    test('defaults recurrenceRule to none and original-currency fields to null', () async {
      await db.insertPending(expense(id: 'e1', pending: true));
      final row = (await db.pendingExpenses()).single;
      final roundTripped = db.rowToExpense(row);

      expect(roundTripped.recurrenceRule, RecurrenceRule.none);
      expect(roundTripped.originalAmountCents, isNull);
      expect(roundTripped.originalCurrency, isNull);
      expect(roundTripped.conversionRate, isNull);
    });
  });

  group('markSynced (issue #43)', () {
    Expense expense({required String id, required bool pending}) => Expense(
          id: id,
          groupId: 'g1',
          title: 'Coffee',
          amountCents: 500,
          paidBy: 'p1',
          paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
          date: DateTime.utc(2026, 9, 16),
          pending: pending,
        );

    test('switches the row to the server id and clears pending, in place', () async {
      await db.insertPending(expense(id: 'local-1', pending: true));

      await db.markSynced(localId: 'local-1', serverId: 'server-1');

      final rows = await db.expensesForGroup('g1');
      expect(rows, hasLength(1));
      expect(rows.single.id, 'server-1');
      expect(rows.single.pending, isFalse);
    });

    test('keeps the local id when serverId is empty, still clears pending', () async {
      await db.insertPending(expense(id: 'local-1', pending: true));

      await db.markSynced(localId: 'local-1', serverId: '');

      final rows = await db.expensesForGroup('g1');
      expect(rows, hasLength(1));
      expect(rows.single.id, 'local-1');
      expect(rows.single.pending, isFalse);
    });

    test('also clears a prior failure (retryCount/lastError/syncFailed), not just pending',
        () async {
      await db.insertPending(expense(id: 'local-1', pending: true));
      await db.recordSyncFailure(
        id: 'local-1',
        error: 'server error',
        retryCount: 3,
        failed: true,
      );

      await db.markSynced(localId: 'local-1', serverId: 'server-1');

      final row = (await db.expensesForGroup('g1')).single;
      expect(row.syncFailed, isFalse);
      expect(row.retryCount, 0);
      expect(row.lastError, isNull);
    });
  });

  group('sync failure state (issue #44)', () {
    Expense expense({required String id}) => Expense(
          id: id,
          groupId: 'g1',
          title: 'Coffee',
          amountCents: 500,
          paidBy: 'p1',
          paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
          date: DateTime.utc(2026, 9, 16),
          pending: true,
        );

    test('recordSyncFailure bumps retryCount, remembers the error, stays pending', () async {
      await db.insertPending(expense(id: 'local-1'));

      await db.recordSyncFailure(
        id: 'local-1',
        error: 'SpliitApiException(500): server error',
        retryCount: 1,
        failed: false,
      );

      final row = (await db.expensesForGroup('g1')).single;
      expect(row.pending, isTrue);
      expect(row.retryCount, 1);
      expect(row.lastError, 'SpliitApiException(500): server error');
      expect(row.syncFailed, isFalse);
    });

    test('recordSyncFailure(failed: true) marks the row syncFailed and excludes it from '
        'pendingExpensesForGroup', () async {
      await db.insertPending(expense(id: 'local-1'));

      await db.recordSyncFailure(
        id: 'local-1',
        error: 'SpliitApiException(400): bad request',
        retryCount: 1,
        failed: true,
      );

      expect(await db.pendingExpensesForGroup('g1'), isEmpty);
      // Still there, still pending -- just not auto-retried.
      final row = (await db.expensesForGroup('g1')).single;
      expect(row.pending, isTrue);
      expect(row.syncFailed, isTrue);
    });

    test('retrySyncFailure clears syncFailed and resets retryCount, keeping lastError', () async {
      await db.insertPending(expense(id: 'local-1'));
      await db.recordSyncFailure(
        id: 'local-1',
        error: 'SpliitApiException(400): bad request',
        retryCount: 2,
        failed: true,
      );

      await db.retrySyncFailure('local-1');

      final row = (await db.expensesForGroup('g1')).single;
      expect(row.syncFailed, isFalse);
      expect(row.retryCount, 0);
      // lastError is deliberately left as-is -- still useful context
      // until the next attempt overwrites or clears it.
      expect(row.lastError, 'SpliitApiException(400): bad request');
      expect(await db.pendingExpensesForGroup('g1'), hasLength(1));
    });

    test('deleteFailedExpense removes the row entirely', () async {
      await db.insertPending(expense(id: 'local-1'));
      await db.recordSyncFailure(
        id: 'local-1',
        error: 'SpliitApiException(400): bad request',
        retryCount: 1,
        failed: true,
      );

      await db.deleteFailedExpense('local-1');

      expect(await db.expensesForGroup('g1'), isEmpty);
    });
  });

  group('multi-group support', () {
    const groupA = Group(id: 'gA', name: 'Banff Trip', currency: '\$', participants: []);
    const groupB = Group(id: 'gB', name: 'Tokyo Trip', currency: '¥', participants: []);

    test('recordGroupOpened sets serverUrl and lastOpenedAt without touching cached fields', () async {
      await db.cacheGroup(groupA);
      await db.recordGroupOpened('gA', serverUrl: 'https://spliit.app');

      final row = await db.groupRow('gA');
      expect(row!.serverUrl, 'https://spliit.app');
      expect(row.lastOpenedAt, isNotNull);
      expect(row.name, 'Banff Trip'); // untouched
    });

    test('allJoinedGroups excludes a cached-but-never-opened row', () async {
      await db.cacheGroup(groupA); // cached, but recordGroupOpened never called
      await db.cacheGroup(groupB);
      await db.recordGroupOpened('gB', serverUrl: 'https://spliit.app');

      final joined = await db.allJoinedGroups();
      expect(joined.map((r) => r.id), ['gB']);
    });

    // recordGroupOpened's `at` param sidesteps drift's second-granularity
    // DateTime storage -- two real DateTime.now() calls made back-to-back
    // in a test can otherwise tie and make ordering flaky. See its doc.
    final t1 = DateTime.utc(2026, 9, 16, 10, 0, 0);
    final t2 = DateTime.utc(2026, 9, 16, 10, 0, 1);
    final t3 = DateTime.utc(2026, 9, 16, 10, 0, 2);

    test('allJoinedGroups orders most-recently-opened first', () async {
      await db.cacheGroup(groupA);
      await db.cacheGroup(groupB);
      await db.recordGroupOpened('gA', serverUrl: 'https://spliit.app', at: t1);
      await db.recordGroupOpened('gB', serverUrl: 'https://spliit.app', at: t2);
      // Re-opening gA should move it back to the front.
      await db.recordGroupOpened('gA', serverUrl: 'https://spliit.app', at: t3);

      final joined = await db.allJoinedGroups();
      expect(joined.map((r) => r.id), ['gA', 'gB']);
    });

    test('mostRecentlyOpenedGroup returns null when nothing has ever been opened', () async {
      expect(await db.mostRecentlyOpenedGroup(), isNull);
    });

    test('mostRecentlyOpenedGroup returns the last-opened row', () async {
      await db.cacheGroup(groupA);
      await db.cacheGroup(groupB);
      await db.recordGroupOpened('gA', serverUrl: 'https://spliit.app', at: t1);
      await db.recordGroupOpened('gB', serverUrl: 'https://spliit.app', at: t2);

      expect((await db.mostRecentlyOpenedGroup())!.id, 'gB');
    });

    test('setActiveParticipant then groupRow round-trips it, including clearing with null', () async {
      await db.cacheGroup(groupA);
      await db.setActiveParticipant('gA', 'p1');
      expect((await db.groupRow('gA'))!.activeParticipantId, 'p1');

      await db.setActiveParticipant('gA', null);
      expect((await db.groupRow('gA'))!.activeParticipantId, isNull);
    });

    test('leaveGroup removes the group and its expenses', () async {
      await db.cacheGroup(groupA);
      await db.recordGroupOpened('gA', serverUrl: 'https://spliit.app');
      await db.insertPending(Expense(
        id: 'e1',
        groupId: 'gA',
        title: 'Coffee',
        amountCents: 500,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        date: DateTime.utc(2026, 9, 16),
        pending: true,
      ));

      await db.leaveGroup('gA');

      expect(await db.groupRow('gA'), isNull);
      expect(await db.expensesForGroup('gA'), isEmpty);
    });

    test('leaveGroup only removes the named group, not others', () async {
      await db.cacheGroup(groupA);
      await db.cacheGroup(groupB);
      await db.recordGroupOpened('gA', serverUrl: 'https://spliit.app');
      await db.recordGroupOpened('gB', serverUrl: 'https://spliit.app');

      await db.leaveGroup('gA');

      expect(await db.groupRow('gA'), isNull);
      expect(await db.groupRow('gB'), isNotNull);
    });
  });

  group('remembered default split (issue #29)', () {
    const group = Group(
      id: 'g1',
      name: 'Banff Trip',
      currency: '\$',
      participants: [Participant(id: 'p1', name: 'Ken'), Participant(id: 'p2', name: 'Jenny')],
    );

    test('defaultSplitFor is null when nothing has ever been remembered', () async {
      await db.cacheGroup(group);
      expect(await db.defaultSplitFor('g1'), isNull);
    });

    test('setDefaultSplit then defaultSplitFor round-trips mode and shares', () async {
      await db.cacheGroup(group);
      await db.setDefaultSplit(
        'g1',
        const DefaultSplit(splitMode: SplitMode.byShares, shares: {'p1': 2, 'p2': 1}),
      );

      final split = await db.defaultSplitFor('g1');

      expect(split, isNotNull);
      expect(split!.splitMode, SplitMode.byShares);
      expect(split.shares, {'p1': 2, 'p2': 1});
    });

    test('setDefaultSplit with null shares round-trips as evenly-covers-everyone', () async {
      await db.cacheGroup(group);
      await db.setDefaultSplit('g1', const DefaultSplit(splitMode: SplitMode.evenly));

      final split = await db.defaultSplitFor('g1');

      expect(split!.splitMode, SplitMode.evenly);
      expect(split.shares, isNull);
    });

    test('setDefaultSplit(null) clears a previously remembered split', () async {
      await db.cacheGroup(group);
      await db.setDefaultSplit(
        'g1',
        const DefaultSplit(splitMode: SplitMode.byPercentage, shares: {'p1': 5000, 'p2': 5000}),
      );

      await db.setDefaultSplit('g1', null);

      expect(await db.defaultSplitFor('g1'), isNull);
    });

    test('a remembered split is per-group', () async {
      const groupB = Group(id: 'g2', name: 'Cabin', currency: '\$', participants: []);
      await db.cacheGroup(group);
      await db.cacheGroup(groupB);

      await db.setDefaultSplit('g1', const DefaultSplit(splitMode: SplitMode.byShares, shares: {
        'p1': 3,
      }));

      expect((await db.defaultSplitFor('g1'))!.splitMode, SplitMode.byShares);
      expect(await db.defaultSplitFor('g2'), isNull);
    });
  });
}
