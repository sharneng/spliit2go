import '../models/group.dart';

/// Picks who "Paid by" should default to when opening add-expense: the
/// device's saved active-user preference (see SettingsService), if it's
/// still a real participant in *this* group -- falling back to the first
/// participant otherwise (a stale preference from a different group, or
/// none set yet, shouldn't block adding an expense).
///
/// Pulled out as a pure function, rather than inline in ExpenseScreen,
/// specifically so it's testable without touching SharedPreferences at
/// all -- ExpenseScreen takes the resolved id as a constructor param
/// instead of loading the preference itself.
String? resolveDefaultPaidBy({
  required String? activeUserId,
  required List<Participant> participants,
}) {
  if (activeUserId != null && participants.any((p) => p.id == activeUserId)) {
    return activeUserId;
  }
  return participants.isEmpty ? null : participants.first.id;
}


/// The outcome of [resolveActiveParticipant] -- see decisions/multi-
/// group-design.md, decision 2. A sealed hierarchy rather than a bare
/// nullable id because "nothing to do" (already resolved), "resolved
/// just now, go persist it" (auto-matched), and "can't resolve it here,
/// go ask" (needs a prompt) are genuinely different things callers must
/// act on differently -- collapsing them back into a single nullable
/// value would just push that same three-way decision into every call
/// site instead of this one function.
sealed class ActiveParticipantResolution {
  const ActiveParticipantResolution();
}

/// This group already has a stored, still-valid active participant.
/// Nothing to persist.
class ActiveParticipantAlreadySet extends ActiveParticipantResolution {
  final String participantId;
  const ActiveParticipantAlreadySet(this.participantId);
}

/// No stored choice for this group (or a stale one -- someone who's no
/// longer a participant), but exactly one participant's name matches
/// the device's default name. Callers should persist this via
/// AppDatabase.setActiveParticipant and use it immediately, without
/// prompting.
class ActiveParticipantAutoMatched extends ActiveParticipantResolution {
  final String participantId;
  const ActiveParticipantAutoMatched(this.participantId);
}

/// No stored choice and no unambiguous name match (no default name set
/// yet, no participant matches it, or more than one does). Callers
/// should prompt -- the existing "Active user" picker dialog, scoped to
/// this group -- and persist whatever's picked.
class ActiveParticipantNeedsPrompt extends ActiveParticipantResolution {
  const ActiveParticipantNeedsPrompt();
}

/// Decides how to resolve a group's active participant from what's
/// already stored, without touching AppDatabase or SharedPreferences
/// itself -- same reasoning as [resolveDefaultPaidBy]: callers do the
/// actual reads/writes, this just makes the decision testably.
///
/// A name match is case-insensitive exact match, deliberately simple --
/// this is a convenience to skip a prompt, not an identity system, and
/// an ambiguous or partial match falling through to
/// [ActiveParticipantNeedsPrompt] (rather than guessing) is the safe
/// failure mode: worst case is one extra prompt, never defaulting
/// "Paid by" to the wrong person.
ActiveParticipantResolution resolveActiveParticipant({
  required String? storedActiveParticipantId,
  required String? defaultActiveUserName,
  required List<Participant> participants,
}) {
  if (storedActiveParticipantId != null &&
      participants.any((p) => p.id == storedActiveParticipantId)) {
    return ActiveParticipantAlreadySet(storedActiveParticipantId);
  }
  if (defaultActiveUserName != null) {
    final matches = participants
        .where((p) => p.name.toLowerCase() == defaultActiveUserName.toLowerCase())
        .toList();
    if (matches.length == 1) {
      return ActiveParticipantAutoMatched(matches.single.id);
    }
  }
  return const ActiveParticipantNeedsPrompt();
}
