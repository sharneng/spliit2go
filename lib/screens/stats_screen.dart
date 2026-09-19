import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/context_l10n.dart';
import '../models/category.dart';
import '../models/group.dart';
import '../services/stats_calculator.dart';
import '../sync/outbox.dart';

/// A first pass at the web app's Stats tab (issue #27, split from #6
/// alongside Activity -- see issue #26): summary totals, group/
/// participant/category spending, computed entirely from the local
/// expense cache the same way Balances is (see stats_calculator.dart's
/// doc comment). Works offline and reflects any pending unsynced
/// expenses immediately.
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
  bool _loading = true;
  SpendingSummary _summary = const SpendingSummary(expenseCount: 0, totalCents: 0, averageCents: 0);
  int _groupTotalCents = 0;
  int? _yourPaidCents;
  int? _yourShareCents;
  List<ParticipantSpending> _participants = const [];
  List<CategorySpending> _categories = const [];
  Map<int, Category> _categoryNames = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await widget.db.expensesForGroup(widget.group.id);
    final expenses = rows.map(widget.db.rowToExpense).toList();

    final summary = computeSpendingSummary(expenses);
    final groupTotal = totalGroupSpendingCents(expenses);
    final yourPaid = activeUserPaidCents(widget.activeUserId, expenses);
    final yourShare = activeUserShareCents(widget.activeUserId, expenses);
    final participants = computeParticipantSpending(widget.group.participants, expenses);
    final categories = computeCategorySpending(expenses);

    if (!mounted) return;
    setState(() {
      _summary = summary;
      _groupTotalCents = groupTotal;
      _yourPaidCents = yourPaid;
      _yourShareCents = yourShare;
      _participants = participants;
      _categories = categories;
      _loading = false;
    });

    // Best-effort only -- see class doc comment. Never blocks the totals
    // above, which don't need category names to be correct.
    try {
      final cats = await widget.client.fetchCategories();
      if (!mounted) return;
      setState(() => _categoryNames = {for (final c in cats) c.id: c});
    } catch (_) {
      // Offline or unreachable -- category totals still show, just
      // labeled by id via _categoryLabel's fallback.
    }
  }

  String _money(int cents) {
    final symbol = widget.group.currency;
    final sign = cents < 0 ? '-' : '';
    return '$sign$symbol${(cents.abs() / 100).toStringAsFixed(2)}';
  }

  String _categoryLabel(int categoryId) {
    final known = _categoryNames[categoryId];
    if (known != null) return known.name;
    return categoryId == 0 ? 'General' : 'Category $categoryId';
  }

  String _formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _activeSpan() {
    final first = _summary.firstDate;
    final last = _summary.lastDate;
    if (first == null || last == null) return '—';
    if (first == last) return _formatDate(first);
    return '${_formatDate(first)} – ${_formatDate(last)}';
  }

  @override
  Widget build(BuildContext context) {
    final body = _loading ? const Center(child: CircularProgressIndicator()) : _body();
    if (widget.embedded) return body;
    return Scaffold(appBar: AppBar(title: Text(context.l10n.statsTitle)), body: body);
  }

  Widget _body() {
    if (_summary.expenseCount == 0) {
      return Center(child: Text(context.l10n.commonNoExpensesYet));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionTitle(context, context.l10n.statsSectionSummary),
        _summaryCard(context),
        const SizedBox(height: 20),
        _sectionTitle(context, context.l10n.statsSectionTotals),
        _totalsCard(context),
        const SizedBox(height: 20),
        _sectionTitle(context, context.l10n.statsSectionByParticipant),
        for (final p in _participants) _participantTile(context, p),
        const SizedBox(height: 20),
        _sectionTitle(context, context.l10n.statsSectionByCategory),
        for (final c in _categories) _categoryTile(context, c),
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _summaryCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _metricRow(context.l10n.statsMetricExpenses, '${_summary.expenseCount}'),
            _metricRow(context.l10n.statsMetricAverageExpense, _money(_summary.averageCents)),
            _metricRow(
              context.l10n.statsMetricLargestExpense,
              _summary.largestCents == null
                  ? '—'
                  : '${_money(_summary.largestCents!)} (${_summary.largestTitle})',
            ),
            _metricRow(context.l10n.statsMetricActiveSpan, _activeSpan()),
          ],
        ),
      ),
    );
  }

  Widget _totalsCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _metricRow(context.l10n.statsMetricGroupSpending, _money(_groupTotalCents)),
            if (_yourPaidCents != null)
              _metricRow(context.l10n.statsMetricYouPaid, _money(_yourPaidCents!)),
            if (_yourShareCents != null)
              _metricRow(context.l10n.statsMetricYourShare, _money(_yourShareCents!)),
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
