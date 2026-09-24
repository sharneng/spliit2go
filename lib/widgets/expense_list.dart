import 'package:flutter/material.dart';

import '../l10n/context_l10n.dart';
import '../models/category.dart';
import '../models/expense.dart';
import '../services/expense_date_group.dart';
import '../utils/date_format.dart';
import '../utils/money.dart';
import 'category_icon.dart';
import 'section_heading.dart';

/// Expenses under date-section headings (issue #88), built lazily. Shared
/// by the Expenses tab and search (issue #39), so a search result looks
/// and sits exactly as it does in the full list.
class ExpenseDateList extends StatelessWidget {
  const ExpenseDateList({
    super.key,
    required this.expenses,
    required this.currency,
    required this.categoryFor,
    required this.onTap,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
  });

  /// Newest first, as the db returns them.
  final List<Expense> expenses;
  final String currency;
  final Category Function(int id) categoryFor;
  final void Function(Expense) onTap;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  @override
  Widget build(BuildContext context) {
    // Each row is an ExpenseDateGroup header or an Expense.
    final rows = <Object>[
      for (final (group, expenses) in groupExpensesByDate(
        expenses,
        today: DateTime.now(),
        firstWeekday: firstWeekdayFor(View.of(context).platformDispatcher.locale),
      )) ...[group, ...expenses],
    ];
    return ListView.builder(
      keyboardDismissBehavior: keyboardDismissBehavior,
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final row = rows[i];
        if (row is ExpenseDateGroup) return _sectionHeader(context, row);
        final e = row as Expense;
        return ExpenseTile(
          expense: e,
          category: categoryFor(e.category),
          currency: currency,
          onTap: () => onTap(e),
        );
      },
    );
  }

  Widget _sectionHeader(BuildContext context, ExpenseDateGroup group) {
    final l10n = context.l10n;
    return SectionHeading(switch (group) {
      ExpenseDateGroup.upcoming => l10n.dateSectionUpcoming,
      ExpenseDateGroup.thisWeek => l10n.dateSectionThisWeek,
      ExpenseDateGroup.earlierThisMonth => l10n.dateSectionEarlierThisMonth,
      ExpenseDateGroup.lastMonth => l10n.dateSectionLastMonth,
      ExpenseDateGroup.earlierThisYear => l10n.dateSectionEarlierThisYear,
      ExpenseDateGroup.lastYear => l10n.dateSectionLastYear,
      ExpenseDateGroup.older => l10n.dateSectionOlder,
    });
  }
}

/// One expense row: category icon, title, date, amount, and a pending or
/// failed badge.
class ExpenseTile extends StatelessWidget {
  const ExpenseTile({
    super.key,
    required this.expense,
    required this.category,
    required this.currency,
    required this.onTap,
  });

  final Expense expense;
  final Category category;
  final String currency;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = expense;
    return ListTile(
      leading: CategoryIconGlyph(category: category),
      title: Text(e.title),
      // e.date is already a date-only value (year/month/day of the
      // calendar day the expense happened on, not a real instant --
      // see lib/services/date_only.dart) -- no .toLocal() here,
      // that would perform a real timezone conversion on a value
      // that was never one, and roll the date back a day west of
      // UTC. See decisions/date-handling.md.
      subtitle: Text(formatDate(e.date, locale: context.appLocale)),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(formatMoney(e.amountCents, currency, locale: context.appLocale)),
          if (e.syncFailed)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline,
                    size: 13, color: Theme.of(context).colorScheme.error),
                const SizedBox(width: 2),
                Text(context.l10n.groupScreenSyncFailed,
                    style: TextStyle(
                        fontSize: 11, color: Theme.of(context).colorScheme.error)),
              ],
            )
          else if (e.pending)
            Text(context.l10n.groupScreenSyncing, style: const TextStyle(fontSize: 11)),
        ],
      ),
      // Every row opens its details (issue #90), pending and failed
      // ones included; the sheet decides what each state can do.
      onTap: onTap,
    );
  }
}
