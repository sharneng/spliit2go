/// One entry in a group's server-side audit log -- what changed, when,
/// and (if it's still known) who did it. Mirrors Spliit's `Activity`
/// Prisma model and the `groups.activities.list` tRPC response (see
/// SpliitClient.fetchActivities) -- issue #26.
enum ActivityType {
  updateGroup,
  createExpense,
  updateExpense,
  deleteExpense;

  /// The server's wire values are its Prisma enum names verbatim
  /// (`UPDATE_GROUP`, etc.), not camelCase.
  static ActivityType fromWire(String value) {
    switch (value) {
      case 'UPDATE_GROUP':
        return ActivityType.updateGroup;
      case 'CREATE_EXPENSE':
        return ActivityType.createExpense;
      case 'UPDATE_EXPENSE':
        return ActivityType.updateExpense;
      case 'DELETE_EXPENSE':
        return ActivityType.deleteExpense;
      default:
        // The server may grow new activity types before this app's
        // next release -- fall back to something displayable (a plain
        // "changed" line, see activity_screen.dart) rather than
        // throwing and losing the whole list over one unrecognized
        // entry.
        return ActivityType.updateGroup;
    }
  }
}

class Activity {
  final String id;
  final DateTime time;
  final ActivityType activityType;
  final String? participantId;
  final String? expenseId;

  /// The expense's title at the time of this activity -- the server
  /// stores it as a free-text snapshot (`Activity.data`), not a live
  /// reference, so it still reads correctly for a since-deleted expense.
  final String? data;

  /// Whether [expenseId] still points at an expense that exists --
  /// false for a deleted expense (or any create/update whose expense
  /// was later deleted). Only ever true when [expenseId] is set.
  /// Mirrors the web app's `activity.expense !== undefined` check,
  /// which gates whether the activity list item is tappable.
  final bool expenseExists;

  const Activity({
    required this.id,
    required this.time,
    required this.activityType,
    this.participantId,
    this.expenseId,
    this.data,
    required this.expenseExists,
  });
}
