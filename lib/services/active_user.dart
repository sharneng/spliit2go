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

/// Never asked for this group, and no unambiguous name match (no default
/// name set yet, no participant matches it, or more than one does).
/// Callers should ask once and persist the answer -- a participant's id,
/// or [nobodyParticipantId] for "Nobody" or a dismissed prompt.
class ActiveParticipantNeedsPrompt extends ActiveParticipantResolution {
  const ActiveParticipantNeedsPrompt();
}

/// Already asked, and there's no active participant: "Nobody" was chosen,
/// or the chosen participant has left the group and the default name
/// matches no one. Don't ask again (issue #85).
class ActiveParticipantNobody extends ActiveParticipantResolution {
  const ActiveParticipantNobody();
}

/// Stored as a group's active participant for "Nobody", so it differs
/// from null ("never asked") without a schema change (issue #85). Spliit
/// ids are nanoids, which never contain '#'.
const nobodyParticipantId = '#nobody';

/// Decides how to resolve a group's active participant from what's
/// already stored, without touching AppDatabase or SharedPreferences
/// itself -- same reasoning as [resolveDefaultPaidBy]: callers do the
/// actual reads/writes, this just makes the decision testably.
///
/// A name match is case-insensitive exact match, deliberately simple --
/// this is a convenience to skip a prompt, not an identity system, and
/// treating an ambiguous or partial match as no match (rather than
/// guessing) is the safe failure mode: worst case is one prompt, never
/// defaulting "Paid by" to the wrong person.
ActiveParticipantResolution resolveActiveParticipant({
  required String? storedActiveParticipantId,
  required String? defaultActiveUserName,
  required List<Participant> participants,
}) {
  if (storedActiveParticipantId == nobodyParticipantId) {
    return const ActiveParticipantNobody();
  }
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
  return storedActiveParticipantId == null
      ? const ActiveParticipantNeedsPrompt()
      : const ActiveParticipantNobody();
}

/// Who to credit in Spliit's activity log for a change made on this
/// device (issue #92): the group's stored active participant, if they're
/// still in the group. Null otherwise -- never asked, "Nobody"
/// ([nobodyParticipantId], which must never reach the server), or someone
/// who has since left -- and the client then sends Spliit's own `'None'`.
///
/// Deliberately the stored choice only, not [resolveActiveParticipant]'s
/// name auto-match: GroupScreen persists an auto-match as soon as it
/// makes one, so by the time anyone saves an expense the stored value is
/// already the answer, and crediting a guess that was never saved would
/// disagree with the rest of the UI.
String? activityParticipantId({
  required String? storedActiveParticipantId,
  required List<Participant> participants,
}) {
  if (storedActiveParticipantId == null) return null;
  return participants.any((p) => p.id == storedActiveParticipantId)
      ? storedActiveParticipantId
      : null;
}
