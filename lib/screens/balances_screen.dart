import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../models/balance.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../services/balance_calculator.dart';
import '../sync/outbox.dart';

/// Who-owes-whom for the group, plus one-tap "mark as paid" for the
/// suggested settlements -- mirrors the web app's Balances tab.
///
/// Balances are computed entirely from the local cache (see
/// balance_calculator.dart), so this works offline and already reflects
/// any not-yet-synced pending expenses. Marking a settlement as paid
/// writes a pending reimbursement expense locally first, same as adding
/// any other expense (see AddExpenseScreen) -- it queues for the outbox
/// if there's no connectivity right now, rather than requiring one.
class BalancesScreen extends StatefulWidget {
  final SpliitClient client;
  final AppDatabase db;
  final Outbox outbox;
  final Group group;

  const BalancesScreen({
    super.key,
    required this.client,
    required this.db,
    required this.outbox,
    required this.group,
  });

  @override
  State<BalancesScreen> createState() => _BalancesScreenState();
}

class _BalancesScreenState extends State<BalancesScreen> {
  List<Balance> _balances = [];
  List<Settlement> _settlements = [];
  bool _loading = true;
  String? _settlingKey;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await widget.db.expensesForGroup(widget.group.id);
    final expenses = rows.map(widget.db.rowToExpense).toList();
    final balances = computeBalances(widget.group.participants, expenses);
    if (!mounted) return;
    setState(() {
      _balances = balances;
      _settlements = suggestSettlements(balances);
      _loading = false;
    });
  }

  String _name(String participantId) {
    for (final p in widget.group.participants) {
      if (p.id == participantId) return p.name;
    }
    return participantId;
  }

  String _money(int cents) => '\$${(cents.abs() / 100).toStringAsFixed(2)}';

  Future<void> _markAsPaid(Settlement s) async {
    final key = '${s.fromId}->${s.toId}';
    setState(() => _settlingKey = key);
    final expense = Expense(
      id: const Uuid().v4(),
      groupId: widget.group.id,
      title: 'Reimbursement',
      amountCents: s.amountCents,
      paidBy: s.fromId,
      paidFor: [ExpenseShare(participantId: s.toId, shares: 1)],
      splitMode: SplitMode.evenly,
      date: DateTime.now(),
      isReimbursement: true,
      pending: true,
    );
    await widget.db.insertPending(expense);
    // Best-effort immediate sync, same pattern as adding a regular
    // expense -- if we're offline this just leaves it pending, which is
    // fine since the local balance recompute below still counts pending
    // rows. But note what Outbox.flush() does on *success*: it deletes
    // the local pending row outright and relies on the caller doing a
    // live re-fetch afterward to bring it back as a normal synced row
    // (see outbox.dart) -- GroupScreen does this via _syncThenRefresh,
    // and this screen needs the same follow-up, or a successfully-synced
    // settlement would vanish from the balance math entirely instead of
    // clearing the debt it was meant to clear.
    final synced = await widget.outbox.flush();
    if (synced > 0) {
      try {
        final fresh = await widget.client.fetchExpenses(widget.group.id);
        await widget.db.replaceServerExpenses(widget.group.id, fresh);
      } catch (_) {
        // Synced but the follow-up refresh failed -- rare (would need
        // the server to accept the write yet the very next request to
        // fail), and nothing to do about it here; the next visit to
        // GroupScreen's own refresh will reconcile it.
      }
    }
    if (!mounted) return;
    setState(() => _settlingKey = null);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Balances')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      'This is the amount each participant paid or was paid for.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                  for (final b in _balances)
                    ListTile(
                      title: Text(_name(b.participantId)),
                      trailing: Text(
                        '${b.netCents < 0 ? '-' : ''}${_money(b.netCents)}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: b.netCents < 0
                              ? Theme.of(context).colorScheme.error
                              : Colors.green.shade700,
                        ),
                      ),
                    ),
                  if (_settlements.isNotEmpty) ...[
                    const Divider(),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text('Suggested reimbursements',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    for (final s in _settlements)
                      ListTile(
                        title: Text('${_name(s.fromId)} owes ${_name(s.toId)}'),
                        trailing: _settlingKey == '${s.fromId}->${s.toId}'
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : TextButton(
                                onPressed: () => _markAsPaid(s),
                                child: Text('Mark as paid  ${_money(s.amountCents)}'),
                              ),
                      ),
                  ],
                  if (_balances.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: Text('No expenses yet.')),
                    ),
                ],
              ),
            ),
    );
  }
}
