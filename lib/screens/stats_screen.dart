import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/category_names.dart';
import '../l10n/context_l10n.dart';
import '../models/category.dart';
import '../models/group.dart';
import '../services/date_span_calculator.dart';
import '../services/stats_calculator.dart';
import '../sync/outbox.dart';
import '../utils/date_format.dart';
import '../utils/money.dart';

/// A first pass at the web app's Stats tab (issue #27, split from #6
/// alongside Activity -- see issue #26): summary totals, group/
/// participant/category spending, computed entirely from a live
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
  final String? activeUserId;

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
    required this.activeUserId,
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

  // Delegates to the shared formatDate/formatDateSpan helpers (issue
  // #55), which also back GroupSettingsScreen's and GroupListScreen's
  // own date-span display -- this screen's "active span" is a
  // spending-only span (firstDate/lastDate already exclude
  // reimbursements, see SpendingSummary's own doc comment), so it's
  // wrapped in its own DateSpan here rather than sharing
  // computeDateSpan's all-expenses-including-reimbursements semantics.
  String _activeSpan(SpendingSummary summary) {
    final first = summary.firstDate;
    final last = summary.lastDate;
    final locale = context.appLocale;
    if (first == null || last == null) return formatDateSpan(null, locale: locale);
    return formatDateSpan(DateSpan(first: first, last: last), locale: locale);
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
          final summary = computeSpendingSummary(expenses);
          final groupTotal = totalGroupSpendingCents(expenses);
          final yourPaid = activeUserPaidCents(widget.activeUserId, expenses);
          final yourShare = activeUserShareCents(widget.activeUserId, expenses);
          final participants = computeParticipantSpending(widget.group.participants, expenses);
          final categories = computeCategorySpending(expenses);
          body = _body(context, summary, groupTotal, yourPaid, yourShare, participants, categories);
        }
        if (widget.embedded) return body;
        return Scaffold(appBar: AppBar(title: Text(context.l10n.statsTitle)), body: body);
      },
    );
  }

  Widget _body(
    BuildContext context,
    SpendingSummary summary,
    int groupTotalCents,
    int? yourPaidCents,
    int? yourShareCents,
    List<ParticipantSpending> participants,
    List<CategorySpending> categories,
  ) {
    if (summary.expenseCount == 0) {
      return Center(child: Text(context.l10n.commonNoExpensesYet));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionTitle(context, context.l10n.statsSectionSummary),
        _summaryCard(context, summary),
        const SizedBox(height: 20),
        _sectionTitle(context, context.l10n.statsSectionTotals),
        _totalsCard(context, groupTotalCents, yourPaidCents, yourShareCents),
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

  Widget _summaryCard(BuildContext context, SpendingSummary summary) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _metricRow(context.l10n.statsMetricExpenses, '${summary.expenseCount}'),
            _metricRow(context.l10n.statsMetricAverageExpense, _money(summary.averageCents)),
            _metricRow(
              context.l10n.statsMetricLargestExpense,
              summary.largestCents == null
                  ? '—'
                  : '${_money(summary.largestCents!)} (${summary.largestTitle})',
            ),
            _metricRow(context.l10n.statsMetricActiveSpan, _activeSpan(summary)),
          ],
        ),
      ),
    );
  }

  Widget _totalsCard(
    BuildContext context,
    int groupTotalCents,
    int? yourPaidCents,
    int? yourShareCents,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _metricRow(context.l10n.statsMetricGroupSpending, _money(groupTotalCents)),
            if (yourPaidCents != null)
              _metricRow(context.l10n.statsMetricYouPaid, _money(yourPaidCents)),
            if (yourShareCents != null)
              _metricRow(context.l10n.statsMetricYourShare, _money(yourShareCents)),
            if (widget.activeUserId == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  context.l10n.statsPickActiveUserHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _metricRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      );

  Widget _participantTile(BuildContext context, ParticipantSpending p) {
    return ListTile(
      title: Text(p.name),
      subtitle: Text(context.l10n.statsParticipantPaidCount(p.paidCount)),
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(_money(p.paidCents), style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(context.l10n.statsParticipantShare(_money(p.shareCents)),
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _categoryTile(BuildContext context, CategorySpending c) {
    return ListTile(
      title: Text(_categoryLabel(c.categoryId)),
      trailing: Text(_money(c.totalCents), style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}
