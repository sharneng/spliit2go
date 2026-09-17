import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/db/app_database.dart';
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
}
