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

/// How often this expense recurs, mirrored from Spliit's `RecurrenceRule`
/// Prisma enum -- no special client-side logic beyond passing the value
/// through, the server owns the actual recurrence scheduling.
enum RecurrenceRule { none, daily, weekly, monthly }

extension RecurrenceRuleWire on RecurrenceRule {
  String get wireValue => switch (this) {
        RecurrenceRule.none => 'NONE',
        RecurrenceRule.daily => 'DAILY',
        RecurrenceRule.weekly => 'WEEKLY',
        RecurrenceRule.monthly => 'MONTHLY',
      };

  static RecurrenceRule fromWire(String value) => switch (value) {
        'DAILY' => RecurrenceRule.daily,
        'WEEKLY' => RecurrenceRule.weekly,
        'MONTHLY' => RecurrenceRule.monthly,
        _ => RecurrenceRule.none,
      };
}

/// Reads a participant reference that the server sends as a bare id
/// string when *we* write it, but appears to send back as an expanded
/// `{id, name, ...}` object on read endpoints (presumably so the webapp
/// doesn't need a separate lookup to show names). Handles either shape
/// rather than assuming one, since this is exactly the kind of upstream
/// detail we deliberately don't want this client tightly bound to.
///
/// Also tolerates the id itself (bare, or nested in the object) coming
/// back as a number rather than a string -- see
/// github.com/sharneng/spliit2go/issues/14, where a bare `as String`
/// cast on a server-sent id threw and crashed the whole group screen.
String extractParticipantId(dynamic value) {
  if (value is Map) return _idToString(value['id']);
  return _idToString(value);
}

String _idToString(dynamic id) => id is String ? id : id.toString();

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

  /// Tolerates three different shapes for who a share belongs to,
  /// because Spliit's own server doesn't send one consistent shape
  /// (issue #35): `groups.expenses.list` (fetchExpenses) selects a
  /// nested `participant: {id, name}` object; the create/update form
  /// payload (and this class's own [toJson]) uses a bare `participant`
  /// id string; but `groups.expenses.get` (fetchExpense, singular --
  /// the one edit mode uses) does a plain Prisma `include: { paidFor:
  /// true }` with no field selection, which returns the *raw join-table
  /// row* instead: `{participantId: "...", shares: n}`, no `participant`
  /// key at all (confirmed against spliit-web's src/lib/api.ts
  /// `getExpense`/`getGroupExpenses`). Before this fix, parsing that
  /// third shape via [extractParticipantId]`(json['participant'])` fed
  /// `null` in and got back the *string* `"null"` (`null.toString()`
  /// doesn't throw) -- which then matched no real participant, so every
  /// "Paid for" checkbox in edit mode came up unchecked regardless of
  /// the expense's actual split.
  factory ExpenseShare.fromJson(Map<String, dynamic> json) => ExpenseShare(
        participantId: extractParticipantId(json['participant'] ?? json['participantId']),
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
  final RecurrenceRule recurrenceRule;

  /// Set together to record that this expense was entered in a currency
  /// other than the group's ("Paid in" on the webapp/iOS). [amountCents]
  /// above is always in the *group's* currency -- these three describe
  /// the original entry, mirroring Spliit's own `Expense.originalCurrency`
  /// / `originalAmount` columns. `conversionRate` follows Spliit's
  /// convention: `amountCents = originalAmountCents * conversionRate`
  /// (see src/lib/currency-conversion.ts upstream). All null together
  /// when the expense was simply entered in the group's own currency.
  final int? originalAmountCents;
  final String? originalCurrency;
  final double? conversionRate;

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
    this.recurrenceRule = RecurrenceRule.none,
    this.originalAmountCents,
    this.originalCurrency,
    this.conversionRate,
    this.pending = false,
  });
}
