import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/category_names.dart';
import '../l10n/context_l10n.dart';
import '../models/category.dart';
import '../models/group.dart';
import '../services/category_store.dart';
import '../services/stats_calculator.dart';
import '../sync/outbox.dart';
import '../utils/money.dart';
import '../widgets/category_icon.dart';
import '../widgets/group_monogram.dart';
import '../widgets/grouped_section.dart';
import '../widgets/label_and_value.dart';
import '../widgets/money.dart';
import '../widgets/empty_state.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../theme.dart';
import '../widgets/bottom_inset.dart';
import '../widgets/participant_colors.dart';
import '../widgets/text_scaled.dart';

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

  /// Who "you" are, for the people's colors (#306).
  final String? activeUserId;

  const StatsScreen({
    super.key,
    required this.client,
    required this.db,
    required this.outbox,
    required this.group,
    this.embedded = false,
    this.activeUserId,
  });

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  late final Stream<List<ExpenseRow>> _expensesStream;
  Map<int, Category> _categoryNames = {for (final c in spliitSeedCategories) c.id: c};
  StreamSubscription<List<Category>>? _categoriesSub;

  @override
  void initState() {
    super.initState();
    _expensesStream = widget.db.watchExpensesForGroup(widget.group.id);
    // Best-effort only -- see class doc comment. Never blocks the
    // totals, which don't need category names to be correct. Offline,
    // the names are the ones last read, or Spliit's seeded ones (#132).
    final categories = CategoryStore.of(widget.db);
    _categoriesSub = categories.watch(widget.client).listen((cats) {
      if (mounted) setState(() => _categoryNames = {for (final c in cats) c.id: c});
    });
    categories.refresh(widget.client);
  }

  @override
  void dispose() {
    _categoriesSub?.cancel();
    super.dispose();
  }

  // Delegates to the app-wide formatMoney helper (issue #50) -- kept as
  // a thin wrapper (rather than replacing every call site below) purely
  // to avoid a churny diff; it's still the same shared formatting logic
  // everywhere.
  String _money(int cents) =>
      formatMoney(cents, widget.group.currency,
          decimalDigits: widget.group.decimalDigits, locale: context.appLocale);

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
          final noSpending = expenses.every((e) => e.isSettlement);
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
      return EmptyState(icon: LucideIcons.chartColumn, title: context.l10n.commonNoExpensesYet);
    }
    final theme = Theme.of(context);
    return GroupedScrollClip(
        child: ListView(
      padding: withBottomInset(context, const EdgeInsets.only(top: 16)),
      children: [
        // One figure, like spliit-ios's StatsView "The group" section
        // (issue #103): the group's total, unsigned, under a label that
        // says which way it goes. Negative only if refunds outweigh
        // spending, which spliit-ios calls earnings.
        GroupedSection(
          caption: context.l10n.statsSectionGroup,
          footer: context.l10n.statsGroupFooter,
          children: [
            Padding(
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
                  Money(_money(groupTotalCents.abs()), size: MoneySize.hero),
                ],
              ),
            ),
          ],
        ),
        // A monogram or category icon before each name, as Paid for's
        // (#306); every amount under its name or none, as there.
        LayoutBuilder(builder: (context, constraints) {
          final colors = participantColors(widget.group.participants, widget.activeUserId);
          final under = _valuesGoUnder(context, constraints, [for (final p in participants) p.paidCents]);
          return GroupedSection(
            caption: context.l10n.statsSectionByParticipant,
            dividerIndent: 56,
            children: [for (final p in participants) _participantTile(context, p, colors, under)],
          );
        }),
        LayoutBuilder(builder: (context, constraints) {
          // Category names are short and known, so the amounts go under
          // only when a row's own name and amount don't fit, not by Paid
          // for's half-the-row rule, nor the longest name against the
          // largest amount (Kenneth, #306): one large total put them all
          // under. Still all or none.
          final label = Theme.of(context).textTheme.bodyLarge;
          final room = constraints.maxWidth - 4 * GroupedSection.inset - context.textScaled(24) - 16 - 16;
          final under = categories.any((c) =>
              measuredTextWidth(context, _categoryLabel(c.categoryId), label) +
                  measuredTextWidth(context, _money(c.totalCents), Money.styleOf(context)) >
              room);
          return GroupedSection(
            caption: context.l10n.statsSectionByCategory,
            dividerIndent: 56,
            children: [for (final c in categories) _categoryTile(context, c, under)],
          );
        }),
      ],
    ));
  }

  // Rows are a label and an amount that share a line when they fit and
  // stack when they don't, not ListTile.trailing: a trailing amount has
  // no width limit, and in French at large text it took the whole tile
  // (#103).
  bool _valuesGoUnder(BuildContext context, BoxConstraints constraints, List<int> cents) => valuesGoUnder(
      row: constraints.maxWidth - 4 * GroupedSection.inset,
      label: context.textScaled(24) + 16,
      widest: 16 +
          [for (final c in cents) measuredTextWidth(context, _money(c), Money.styleOf(context))]
              .fold(0.0, math.max));

  Widget _participantTile(BuildContext context, ParticipantSpending p, Map<String, Color> colors, bool under) {
    final small = Theme.of(context).textTheme.bodySmall;
    return GroupedRow(
      title: MonogramLabel(
          monogram: Monogram(
              name: p.name, color: colors[p.participantId] ?? monogramPalette.first, radius: 12),
          name: Text(p.name)),
      value: Money(_money(p.paidCents)),
      valueUnder: under,
      // Under the name, past the monogram.
      subtitle: Padding(
        padding: EdgeInsetsDirectional.only(start: context.textScaled(24) + 16),
        child: _pair(Text(context.l10n.statsParticipantPaidCount(p.paidCount)),
            Text(context.l10n.statsParticipantShare(_money(p.shareCents)), style: small)),
      ),
    );
  }

  Widget _categoryTile(BuildContext context, CategorySpending c, bool under) {
    return GroupedRow(
      // The expense rows' icon, at a monogram's size.
      title: MonogramLabel(
          monogram: CategoryIconGlyph(category: _categoryNames[c.categoryId], size: 24),
          name: Text(_categoryLabel(c.categoryId))),
      value: Money(_money(c.totalCents)),
      valueUnder: under,
    );
  }

  Widget _pair(Widget label, Widget amount) => Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        children: [label, amount],
      );
}
