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
  });
}
