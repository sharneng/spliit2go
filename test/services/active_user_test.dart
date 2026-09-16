import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/services/active_user.dart';

void main() {
  const alex = Participant(id: 'alex', name: 'Alex');
  const bea = Participant(id: 'bea', name: 'Bea');
  final participants = [alex, bea];

  test('uses the active user when they\'re a participant in this group', () {
    expect(
      resolveDefaultPaidBy(activeUserId: 'bea', participants: participants),
      'bea',
    );
  });

  test('falls back to the first participant when no active user is set', () {
    expect(
      resolveDefaultPaidBy(activeUserId: null, participants: participants),
      'alex',
    );
  });

  test('falls back to the first participant when the active user is stale '
      '(not a participant in this group)', () {
    expect(
      resolveDefaultPaidBy(activeUserId: 'someone-from-another-group', participants: participants),
      'alex',
    );
  });

  test('returns null when the group has no participants at all', () {
    expect(resolveDefaultPaidBy(activeUserId: 'bea', participants: const []), isNull);
  });

  group('resolveActiveParticipant', () {
    test('uses the group\'s already-stored active participant when still valid', () {
      final resolution = resolveActiveParticipant(
        storedActiveParticipantId: 'bea',
        defaultActiveUserName: 'Alex', // shouldn't matter -- stored wins
        participants: participants,
      );
      expect(resolution, isA<ActiveParticipantAlreadySet>());
      expect((resolution as ActiveParticipantAlreadySet).participantId, 'bea');
    });

    test('ignores a stale stored participant and falls through to matching', () {
      final resolution = resolveActiveParticipant(
        storedActiveParticipantId: 'someone-from-another-group',
        defaultActiveUserName: 'Alex',
        participants: participants,
      );
      expect(resolution, isA<ActiveParticipantAutoMatched>());
      expect((resolution as ActiveParticipantAutoMatched).participantId, 'alex');
    });

    test('auto-matches the device default name, case-insensitively', () {
      final resolution = resolveActiveParticipant(
        storedActiveParticipantId: null,
        defaultActiveUserName: 'bEa',
        participants: participants,
      );
      expect(resolution, isA<ActiveParticipantAutoMatched>());
      expect((resolution as ActiveParticipantAutoMatched).participantId, 'bea');
    });

    test('needs a prompt when no default name is set', () {
      final resolution = resolveActiveParticipant(
        storedActiveParticipantId: null,
        defaultActiveUserName: null,
        participants: participants,
      );
      expect(resolution, isA<ActiveParticipantNeedsPrompt>());
    });

    test('needs a prompt when the default name matches no one', () {
      final resolution = resolveActiveParticipant(
        storedActiveParticipantId: null,
        defaultActiveUserName: 'Cid',
        participants: participants,
      );
      expect(resolution, isA<ActiveParticipantNeedsPrompt>());
    });

    test('needs a prompt rather than guessing when the default name is ambiguous', () {
      const alexToo = Participant(id: 'alex2', name: 'Alex');
      final resolution = resolveActiveParticipant(
        storedActiveParticipantId: null,
        defaultActiveUserName: 'Alex',
        participants: [alex, alexToo, bea],
      );
      expect(resolution, isA<ActiveParticipantNeedsPrompt>());
    });
  });
}
