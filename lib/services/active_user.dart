import '../models/group.dart';

/// Picks who "Paid by" should default to when opening add-expense: the
/// device's saved active-user preference (see SettingsService), if it's
/// still a real participant in *this* group -- falling back to the first
/// participant otherwise (a stale preference from a different group, or
/// none set yet, shouldn't block adding an expense).
///
/// Pulled out as a pure function, rather than inline in AddExpenseScreen,
/// specifically so it's testable without touching SharedPreferences at
/// all -- AddExpenseScreen takes the resolved id as a constructor param
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
