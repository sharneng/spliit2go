/// Who-owes-whom for a single participant in a group, as last computed
/// from the cached expense list (including any still-pending, not-yet-
/// synced local expenses -- see lib/services/balance_calculator.dart).
class Balance {
  final String participantId;
  final int netCents; // positive = owed to them, negative = they owe

  const Balance({required this.participantId, required this.netCents});
}

/// One suggested transfer to bring [fromId] and [toId] closer to even --
/// see [suggestSettlements] in lib/services/balance_calculator.dart.
/// Mirrors Spliit's own "suggested reimbursements": mark one as paid by
/// creating a reimbursement expense with `paidBy: fromId`,
/// `paidFor: [ExpenseShare(participantId: toId, shares: 1)]` -- verified
/// against the web app's own "Mark as paid" link, which pre-fills the
/// create-expense form the same way (`?reimbursement=yes&from=...&to=...`).
class Settlement {
  final String fromId;
  final String toId;
  final int amountCents;

  const Settlement({required this.fromId, required this.toId, required this.amountCents});
}
