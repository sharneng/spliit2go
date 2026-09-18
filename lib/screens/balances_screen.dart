import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../models/balance.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../services/balance_calculator.dart';
import '../sync/outbox.dart';
import 'expense_screen.dart';

/// Who-owes-whom for the group, plus one-tap "mark as paid" for the
/// suggested settlements -- mirrors the web app's Balances tab.
///
/// Balances are computed entirely from the local cache (see
/// balance_calculator.dart), so this works offline and already reflects
/// any not-yet-synced pending expenses. "Mark as paid" opens ExpenseScreen
/// pre-filled with the suggested settlement (amount, "this is a
/// reimbursement" checked, payer/payee, a "<payer> paid <payee>" title)
/// rather than recording it directly (issue #22) -- matching the web/iOS
/// apps' own settle-up flow, and letting the amount be edited down for a
/// partial payment. From there it's a completely normal add: a pending
/// expense written locally first, queued for the outbox if there's no
/// connectivity right now.
class BalancesScreen extends StatefulWidget {
  final SpliitClient client;
  final AppDatabase db;
  final Outbox outbox;
  final Group group;

  /// When true, renders just the balances content with no [Scaffold]/
  /// [AppBar] of its own -- for embedding as a tab body inside
  /// GroupScreen's own bottom-navigation Scaffold (issue #38), which
  /// supplies the persistent title bar all four tabs now share. `false`
  /// (the default) keeps this screen's original standalone
  /// pushed-full-screen behavior, still used by anything that hasn't
  /// been converted to a tab.
  final bool embedded;

  /// Notified after a settlement is recorded and this screen's own
  /// local reload finishes -- lets GroupScreen refresh its own
  /// (separately held) expense list, since a "mark as paid" settlement
  /// is a new expense that GroupScreen's Expenses tab wouldn't
  /// otherwise know about until its own next fetch. Only meaningful
  /// when [embedded]; a standalone pushed screen instead relies on
  /// GroupScreen reloading when the push returns.
  final VoidCallback? onExpenseChanged;

  const BalancesScreen({
    super.key,
    required this.client,
    required this.db,
    required this.outbox,
    required this.group,
    this.embedded = false,
    this.onExpenseChanged,
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

  /// Opens ExpenseScreen pre-filled with [s], rather than recording it
  /// directly, so the user can see/edit the amount (a partial payment)
  /// and everything else before it's actually saved -- see the class doc
  /// comment and issue #22.
  Future<void> _openSettleUp(Settlement s) async {
    final key = '${s.fromId}->${s.toId}';
    final draft = Expense(
      // Discarded -- ExpenseScreen's _saveNew always mints its own fresh
      // id on save, this is never read.
      id: '',
      groupId: widget.group.id,
      title: '${_name(s.fromId)} paid ${_name(s.toId)}',
      amountCents: s.amountCents,
      paidBy: s.fromId,
      paidFor: [ExpenseShare(participantId: s.toId, shares: 1)],
      splitMode: SplitMode.evenly,
      date: DateTime.now(),
      isReimbursement: true,
    );

    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ExpenseScreen(
          client: widget.client,
          db: widget.db,
          outbox: widget.outbox,
          group: widget.group,
          initialDraft: draft,
        ),
      ),
    );
    if (saved != true) return;

    setState(() => _settlingKey = key);
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
    widget.onExpenseChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final body = _loading
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
                                onPressed: () => _openSettleUp(s),
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
            );
    if (widget.embedded) return body;
    return Scaffold(appBar: AppBar(title: const Text('Balances')), body: body);
  }
}
