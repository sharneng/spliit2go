/// Our own DTO for an expense, decoupled from Spliit's tRPC/Prisma shape.
///
/// [SpliitClient] is responsible for mapping the raw tRPC response into
/// this type. If Spliit's server schema changes, only that mapping needs
/// to change -- not this model or anything that depends on it.
class Expense {
  final String id;
  final String groupId;
  final String title;
  /// Amount in the group's smallest currency unit (e.g. cents), matching
  /// how Spliit itself stores amounts -- avoids floating point drift.
  final int amountCents;
  final String paidBy;
  final DateTime date;
  final DateTime? createdAt;

  /// True if this expense was created locally while offline and hasn't
  /// been confirmed by the server yet. Never true for anything read back
  /// from the API.
  final bool pending;

  const Expense({
    required this.id,
    required this.groupId,
    required this.title,
    required this.amountCents,
    required this.paidBy,
    required this.date,
    this.createdAt,
    this.pending = false,
  });
}
