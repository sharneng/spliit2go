import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/models/default_split.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';

void main() {
  const alice = Participant(id: 'alice', name: 'Alice');
  const bob = Participant(id: 'bob', name: 'Bob');
  const carol = Participant(id: 'carol', name: 'Carol');
  const all3 = [alice, bob, carol];

  group('DefaultSplit.remembering', () {
    test('evenly covering everyone remembers no shares', () {
      final split = DefaultSplit.remembering(
        splitMode: SplitMode.evenly,
        paidFor: const [
          ExpenseShare(participantId: 'alice', shares: 1),
          ExpenseShare(participantId: 'bob', shares: 1),
          ExpenseShare(participantId: 'carol', shares: 1),
        ],
        allParticipants: all3,
      );
      expect(split.splitMode, SplitMode.evenly);
      expect(split.shares, isNull);
    });

    test('evenly excluding someone keeps the membership', () {
      final split = DefaultSplit.remembering(
        splitMode: SplitMode.evenly,
        paidFor: const [
          ExpenseShare(participantId: 'alice', shares: 1),
          ExpenseShare(participantId: 'bob', shares: 1),
        ],
        allParticipants: all3,
      );
      expect(split.splitMode, SplitMode.evenly);
      expect(split.shares, {'alice': 1, 'bob': 1});
    });

    test('by shares keeps the exact per-participant values', () {
      final split = DefaultSplit.remembering(
        splitMode: SplitMode.byShares,
        paidFor: const [
          ExpenseShare(participantId: 'alice', shares: 2),
          ExpenseShare(participantId: 'bob', shares: 1),
          ExpenseShare(participantId: 'carol', shares: 1),
        ],
        allParticipants: all3,
      );
      expect(split.splitMode, SplitMode.byShares);
      expect(split.shares, {'alice': 2, 'bob': 1, 'carol': 1});
    });

    test('by percentage keeps the exact per-participant values', () {
      final split = DefaultSplit.remembering(
        splitMode: SplitMode.byPercentage,
        paidFor: const [
          ExpenseShare(participantId: 'alice', shares: 5000),
          ExpenseShare(participantId: 'bob', shares: 5000),
        ],
        allParticipants: all3,
      );
      expect(split.splitMode, SplitMode.byPercentage);
      expect(split.shares, {'alice': 5000, 'bob': 5000});
    });

    test('by amount never remembers shares, even covering everyone', () {
      final split = DefaultSplit.remembering(
        splitMode: SplitMode.byAmount,
        paidFor: const [
          ExpenseShare(participantId: 'alice', shares: 1000),
          ExpenseShare(participantId: 'bob', shares: 500),
          ExpenseShare(participantId: 'carol', shares: 500),
        ],
        allParticipants: all3,
      );
      expect(split.splitMode, SplitMode.byAmount);
      expect(split.shares, isNull);
    });
  });

  group('DefaultSplit.appliesTo', () {
    test('null shares always applies', () {
      const split = DefaultSplit(splitMode: SplitMode.evenly);
      expect(split.appliesTo(all3), isTrue);
      expect(split.appliesTo(const [alice]), isTrue);
      expect(split.appliesTo(const []), isTrue);
    });

    test('applies when every named participant is still present', () {
      const split = DefaultSplit(
        splitMode: SplitMode.byShares,
        shares: {'alice': 2, 'bob': 1},
      );
      expect(split.appliesTo(all3), isTrue);
    });

    test('goes stale once a named participant is gone', () {
      const split = DefaultSplit(
        splitMode: SplitMode.byShares,
        shares: {'alice': 2, 'bob': 1},
      );
      expect(split.appliesTo(const [alice, carol]), isFalse);
    });
  });
}
