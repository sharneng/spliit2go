import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/context_l10n.dart';
import '../models/balance.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../services/balance_calculator.dart';
import '../sync/outbox.dart';
import '../utils/money.dart';
import '../widgets/section_heading.dart';
import 'expense_screen.dart';
import '../services/error_reporting.dart';

/// Who-owes-whom for the group, plus one-tap "mark as paid" for the
/// suggested settlements -- mirrors the web app's Balances tab.
///
/// Balances are computed entirely from the local cache, via a live
/// [AppDatabase.watchExpensesForGroup] stream (issue #47) rather than an
/// imperative reload, so this works offline, already reflects any
/// not-yet-synced pending expenses, and picks up any change -- a
/// settlement recorded here, an expense added/edited/synced elsewhere in
/// the app -- the moment it's written, with no reload wiring of its own
/// needed. "Mark as paid" opens ExpenseScreen pre-filled with the
/// suggested settlement (amount, "this is a reimbursement" checked,
/// payer/payee, a "<payer> paid <payee>" title) rather than recording it
/// directly (issue #22) -- matching the web/iOS apps' own settle-up
/// flow, and letting the amount be edited down for a partial payment.
/// From there it's a completely normal add: a pending expense written
/// locally first, queued for the outbox if there's no connectivity right
/// now.
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

  /// Who "you" are in this group, or null for Nobody / not picked yet --
  /// resolved by GroupScreen (see resolveActiveParticipant).
  final String? activeUserId;

  /// Opens the "Who are you?" picker from the You section (issue #99).
  /// Null hides the row's tap target (e.g. a standalone screen).
  final VoidCallback? onPickActiveUser;

  const BalancesScreen({
    super.key,
    required this.client,
    required this.db,
    required this.outbox,
    required this.group,
    this.embedded = false,
    this.activeUserId,
    this.onPickActiveUser,
  });

  @override
  State<BalancesScreen> createState() => _BalancesScreenState();
}

class _BalancesScreenState extends State<BalancesScreen> {
  late final Stream<List<ExpenseRow>> _expensesStream;
  String? _settlingKey;

  @override
  void initState() {
    super.initState();
    _expensesStream = widget.db.watchExpensesForGroup(widget.group.id);
  }

  String _name(String participantId) {
    for (final p in widget.group.participants) {
      if (p.id == participantId) return p.name;
    }
    return participantId;
  }

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
    // fine since the live balance recompute (via [_expensesStream])
    // still counts pending rows. But note what Outbox.flush() does on
    // *success*: it deletes the local pending row outright and relies on
    // the caller doing a live re-fetch afterward to bring it back as a
    // normal synced row (see outbox.dart) -- without the follow-up
    // fetchExpenses/replaceServerExpenses below, a successfully-synced
    // settlement would briefly vanish from the balance math (the pending
    // row gone, the synced one not yet cached) instead of just clearing
    // the debt it was meant to clear.
    final synced = await widget.outbox.flush();
    if (synced > 0) {
      try {
        final generation = widget.db.expensesGeneration(widget.group.id);
        final fresh = await widget.client.fetchExpenses(widget.group.id);
        await widget.db.replaceServerExpenses(widget.group.id, fresh,
            fetchedAtGeneration: generation);
      } catch (e, st) {
        // Synced but the follow-up refresh failed -- rare (would need
        // the server to accept the write yet the very next request to
        // fail), and nothing to do about it here; the next visit to
        // GroupScreen's own refresh will reconcile it. Logged if it's
        // anything but a connection problem (#119 review).
        ErrorReporter.instance
            .report(e, st, operation: 'Refreshing after settling up in ${widget.group.id}');
      }
    }
    if (!mounted) return;
    setState(() => _settlingKey = null);
    // No explicit reload and no onExpenseChanged callback to
    // GroupScreen needed (issue #47) -- every write above went through
    // AppDatabase, so [_expensesStream] here (and GroupScreen's own
    // watchExpensesForGroup subscription) already reflect it.
  }

  /// The active user's own position, above everyone's (issue #99), like
  /// spliit-ios's BalancesView "You" section: which way the money goes
  /// and how much, then a row saying who "you" are that opens the
  /// picker. Unpicked, only that row shows, with a line on why to pick.
  List<Widget> _youSection(BuildContext context, List<Balance> balances) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final you = widget.group.participants
        .where((p) => p.id == widget.activeUserId)
        .firstOrNull;
    final net = balances
            .where((b) => b.participantId == you?.id)
            .firstOrNull
            ?.netCents ??
        0;
    return [
      SectionHeading(l10n.balancesYouSection),
      Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (you != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      net > 0
                          ? l10n.balancesYouAreOwed
                          : net < 0
                              ? l10n.balancesYouOwe
                              : l10n.balancesYouSettled,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 4),
                    // Unsigned: the line above already says which way.
                    Text(
                      formatMoney(net.abs(), widget.group.currency,
                          locale: context.appLocale),
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: net > 0
                            ? Colors.green.shade700
                            : net < 0
                                ? theme.colorScheme.error
                                : null,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
            ],
            // One row in the title, not a trailing widget: a trailing
            // Text is unconstrained, and a long name at large text took
            // the whole tile (#101 review). Here the name gets what's
            // left beside the label and wraps.
            ListTile(
              title: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.balancesYouLabel,
                      style: TextStyle(color: theme.colorScheme.primary)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      you?.name ?? l10n.balancesYouNobody,
                      textAlign: TextAlign.end,
                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              onTap: widget.onPickActiveUser,
            ),
          ],
        ),
      ),
      if (you == null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            l10n.balancesYouHint,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      const SizedBox(height: 8),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ExpenseRow>>(
      stream: _expensesStream,
      builder: (context, snapshot) {
        final rows = snapshot.data;
        final Widget body;
        if (rows == null) {
          body = const Center(child: CircularProgressIndicator());
        } else {
          final expenses = rows.map(widget.db.rowToExpense).toList();
          final balances = computeBalances(widget.group.participants, expenses);
          final settlements = suggestSettlements(balances);
          body = RefreshIndicator(
            // The list is already always current (it's fed by a live db
            // stream) -- there's nothing to actually re-fetch here, but
            // the pull-to-refresh gesture is kept as a harmless no-op
            // rather than removing an affordance users expect on a
            // scrollable list (issue #47).
            onRefresh: () async {},
            child: ListView(
              children: [
                ..._youSection(context, balances),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    context.l10n.balancesExplainer,
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
                for (final b in balances)
                  ListTile(
                    title: Text(b.participantId == widget.activeUserId
                        ? context.l10n.expenseDetailsYou(_name(b.participantId))
                        : _name(b.participantId)),
                    trailing: Text(
                      formatMoney(b.netCents, widget.group.currency,
                          locale: context.appLocale),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: b.netCents < 0
                            ? Theme.of(context).colorScheme.error
                            : Colors.green.shade700,
                      ),
                    ),
                  ),
                if (settlements.isNotEmpty) ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(context.l10n.balancesSuggestedReimbursements,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  for (final s in settlements)
                    ListTile(
                      title: Text(context.l10n.balancesOwes(_name(s.fromId), _name(s.toId))),
                      trailing: _settlingKey == '${s.fromId}->${s.toId}'
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : TextButton(
                              onPressed: () => _openSettleUp(s),
                              child: Text(context.l10n
                                  .balancesMarkAsPaid(formatMoney(s.amountCents, widget.group.currency,
                                      locale: context.appLocale))),
                            ),
                     ),
                ],
                if (balances.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(child: Text(context.l10n.commonNoExpensesYet)),
                  ),
              ],
            ),
          );
        }
        if (widget.embedded) return body;
        return Scaffold(appBar: AppBar(title: Text(context.l10n.balancesTitle)), body: body);
      },
    );
  }
}
