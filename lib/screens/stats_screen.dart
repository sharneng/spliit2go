import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/category_names.dart';
import '../l10n/context_l10n.dart';
import '../models/category.dart';
import '../models/group.dart';
import '../services/stats_calculator.dart';
import '../sync/outbox.dart';
import '../utils/money.dart';

/// A first pass at the web app's Stats tab (issue #27, split from #6
/// alongside Activity -- see issue #26): the group's total spending
/// ("The group", issue #103), then spending by participant and by
/// category, computed entirely from a live
/// [AppDatabase.watchExpensesForGroup] stream (issue #47) the same way
/// Balances is (see stats_calculator.dart's doc comment). Works offline,
/// reflects any pending unsynced expenses immediately, and -- since it's
/// a stream rather than a one-shot load -- picks up any later change
/// (an expense added/edited/synced elsewhere) without needing its own
/// reload wiring.
///
/// Deliberately smaller than the web app's Stats tab: no charts (spending
/// over time, monthly breakdown), no recurring-spending projection, and
/// no date-range selector -- "all time" only. Those need their own
/// design pass; see the doc comment in stats_calculator.dart and
/// decisions/feature-backlog.md item 10.
///
/// Category *names* aren't cached locally (unlike expenses/group), so
/// this screen makes a best-effort live fetch for them on open and falls
/// back to "Category <id>" (or "General" for the default id 0) if that
/// fails -- e.g. offline. The totals themselves never depend on that
/// fetch succeeding.
class StatsScreen extends StatefulWidget {
  final SpliitClient client;
  final AppDatabase db;
  final Outbox outbox;
  final Group group;

  /// See BalancesScreen's own doc comment on its identical field --
  /// same reasoning (issue #38): true embeds just the content, with no
  /// Scaffold/AppBar of its own, for use as one of GroupScreen's tab
  /// bodies.
  final bool embedded;

  const StatsScreen({
    super.key,
    required this.client,
    required this.db,
    required this.outbox,
    required this.group,
    this.embedded = false,
  });

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  late final Stream<List<ExpenseRow>> _expensesStream;
  Map<int, Category> _categoryNames = const {};

  @override
  void initState() {
    super.initState();
    _expensesStream = widget.db.watchExpensesForGroup(widget.group.id);
    _loadCategoryNames();
  }

  // Best-effort only -- see class doc comment. Never blocks the totals,
  // which don't need category names to be correct.
  Future<void> _loadCategoryNames() async {
    try {
      final cats = await widget.client.fetchCategories();
      if (!mounted) return;
      setState(() => _categoryNames = {for (final c in cats) c.id: c});
    } catch (_) {
      // Offline or unreachable -- category totals still show, just
      // labeled by id via _categoryLabel's fallback.
    }
  }

  // Delegates to the app-wide formatMoney helper (issue #50) -- kept as
  // a thin wrapper (rather than replacing every call site below) purely
  // to avoid a churny diff; it's still the same shared formatting logic
  // everywhere.
  String _money(int cents) =>
      formatMoney(cents, widget.group.currency, locale: context.appLocale);

  // Translated at presentation time (issue #51); an id whose Category
  // hasn't been fetched falls back to the localized "General" (id 0) or
  // "Category {id}".
  String _categoryLabel(int categoryId) =>
      localizedCategoryLabel(context, categoryId, _categoryNames[categoryId]);

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
          final groupTotal = totalGroupSpendingCents(expenses);
          final participants = computeParticipantSpending(widget.group.participants, expenses);
          final categories = computeCategorySpending(expenses);
          // Settlements alone aren't spending: still the empty state.
          final noSpending = expenses.every((e) => e.isReimbursement);
          body = _body(context, noSpending, groupTotal, participants, categories);
        }
        if (widget.embedded) return body;
        return Scaffold(appBar: AppBar(title: Text(context.l10n.statsTitle)), body: body);
      },
    );
  }

  Widget _body(
    BuildContext context,
    bool noExpenses,
    int groupTotalCents,
    List<ParticipantSpending> participants,
    List<CategorySpending> categories,
  ) {
    if (noExpenses) {
      return Center(child: Text(context.l10n.commonNoExpensesYet));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionTitle(context, context.l10n.statsSectionGroup),
        _groupCard(context, groupTotalCents),
        const SizedBox(height: 20),
        _sectionTitle(context, context.l10n.statsSectionByParticipant),
        for (final p in participants) _participantTile(context, p),
        const SizedBox(height: 20),
        _sectionTitle(context, context.l10n.statsSectionByCategory),
        for (final c in categories) _categoryTile(context, c),
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  /// One figure, like spliit-ios's StatsView "The group" section (issue
  /// #103): the group's total, unsigned, under a label that says which
  /// way it goes. Negative only if refunds outweigh spending, which
  /// spliit-ios calls earnings. Replaces the old Summary and Totals cards.
  Widget _groupCard(BuildContext context, int groupTotalCents) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: SizedBox(
            width: double.infinity,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    groupTotalCents < 0
                        ? context.l10n.statsGroupTotalEarnings
                        : context.l10n.statsGroupTotalSpending,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _money(groupTotalCents.abs()),
                    style: theme.textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            context.l10n.statsGroupFooter,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  // Rows are a label and an amount that share a line when they fit and
  // stack when they don't, not ListTile.trailing: a trailing amount has
  // no width limit, and in French at large text it took the whole tile
  // (#103).
  Widget _participantTile(BuildContext context, ParticipantSpending p) {
    final small = Theme.of(context).textTheme.bodySmall;
    return ListTile(
      title: _pair(Text(p.name),
          Text(_money(p.paidCents), style: const TextStyle(fontWeight: FontWeight.w600))),
      subtitle: _pair(Text(context.l10n.statsParticipantPaidCount(p.paidCount)),
          Text(context.l10n.statsParticipantShare(_money(p.shareCents)), style: small)),
    );
  }

  Widget _categoryTile(BuildContext context, CategorySpending c) {
    return ListTile(
      title: _pair(Text(_categoryLabel(c.categoryId)),
          Text(_money(c.totalCents), style: const TextStyle(fontWeight: FontWeight.w600))),
    );
  }

  Widget _pair(Widget label, Widget amount) => Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        children: [label, amount],
      );
}
