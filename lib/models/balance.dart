/// Who-owes-whom for a single participant in a group, as last computed
/// from the server. Screens that show this while offline are responsible
/// for adjusting it against any still-[Expense.pending] local expenses --
/// see lib/sync/outbox.dart.
class Balance {
  final String participantId;
  final int netCents; // positive = owed to them, negative = they owe

  const Balance({required this.participantId, required this.netCents});
}
