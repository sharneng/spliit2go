/// Our own DTO for an expense, decoupled from Spliit's tRPC/Prisma shape.
///
/// [SpliitClient] is responsible for mapping the raw tRPC response into
/// this type. Field set and semantics are verified against a working
/// Python client (see the splitwise2spliit project) that's already
/// exercised this API end-to-end for CSV import -- not guessed.
enum SplitMode { evenly, byShares, byPercentage, byAmount }

extension SplitModeWire on SplitMode {
  String get wireValue => switch (this) {
        SplitMode.evenly => 'EVENLY',
        SplitMode.byShares => 'BY_SHARES',
        SplitMode.byPercentage => 'BY_PERCENTAGE',
        SplitMode.byAmount => 'BY_AMOUNT',
      };

  static SplitMode fromWire(String value) => switch (value) {
        'BY_SHARES' => SplitMode.byShares,
        'BY_PERCENTAGE' => SplitMode.byPercentage,
        'BY_AMOUNT' => SplitMode.byAmount,
        _ => SplitMode.evenly,
      };
}

/// Reads a participant reference that the server sends as a bare id
/// string when *we* write it, but appears to send back as an expanded
/// `{id, name, ...}` object on read endpoints (presumably so the webapp
/// doesn't need a separate lookup to show names). Handles either shape
/// rather than assuming one, since this is exactly the kind of upstream
/// detail we deliberately don't want this client tightly bound to.
String extractParticipantId(dynamic value) {
  if (value is Map) return value['id'] as String;
  return value as String;
}

/// Same leniency for category, in case it's ever returned as an expanded
/// `{id, name}` object rather than a bare id the way fetchCategories'
/// categories.list response and the create-expense payload use.
int extractCategoryId(dynamic value) {
  if (value is Map) return (value['id'] as num).round();
  return (value as num).round();
}

/// One participant's share of an expense. For [SplitMode.evenly], [shares]
/// is just a nonzero weight (1 per person is the common case); for
/// [SplitMode.byAmount] it's the exact cents they owe.
class ExpenseShare {
  final String participantId;
  final int shares;
  const ExpenseShare({required this.participantId, required this.shares});

  Map<String, dynamic> toJson() => {'participant': participantId, 'shares': shares};

  factory ExpenseShare.fromJson(Map<String, dynamic> json) => ExpenseShare(
        participantId: extractParticipantId(json['participant']),
        shares: (json['shares'] as num).round(),
      );
}

class Expense {
  final String id;
  final String groupId;
  final String title;
  /// Amount in the group's smallest currency unit (cents), matching how
  /// Spliit itself stores amounts -- avoids floating point drift.
  final int amountCents;
  final String paidBy;
  final List<ExpenseShare> paidFor;
  final SplitMode splitMode;
  final int category;
  final String notes;
  final DateTime date;
  final bool isReimbursement;

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
    required this.paidFor,
    this.splitMode = SplitMode.evenly,
    this.category = 0,
    this.notes = '',
    required this.date,
    this.isReimbursement = false,
    this.pending = false,
  });
}
