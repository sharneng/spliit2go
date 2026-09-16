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
}
