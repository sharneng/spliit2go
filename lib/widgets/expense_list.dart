import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../l10n/context_l10n.dart';
import '../l10n/category_names.dart';
import '../models/category.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../services/expense_shares.dart';
import '../services/expense_date_group.dart';
import '../utils/date_format.dart';
import '../theme.dart';
import '../utils/money.dart';
import '../utils/spoken.dart';
import 'caption_icon.dart';
import 'money.dart';
import 'category_icon.dart';
import 'grouped_section.dart';
import 'bottom_inset.dart';

/// Expenses in date sections (issue #88), each a grouped card under its
/// caption (#185), built lazily. Shared by the Expenses tab and search
/// (issue #39), so a search result looks and sits exactly as it does in
/// the full list.
class ExpenseDateList extends StatelessWidget {
  const ExpenseDateList({
    super.key,
    required this.expenses,
    required this.currency,
    required this.categoryFor,
    required this.onTap,
    this.participants = const [],
    this.activeUserId,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
    this.bottomPadding = 0,
  });

  /// Newest first, as the db returns them.
  final List<Expense> expenses;
  final String currency;
  final Category Function(int id) categoryFor;
  final void Function(Expense) onTap;

  /// Who paid each expense, by name (#207).
  final List<Participant> participants;

  /// This device's participant: "You" as payer, and what you lent or owe.
  final String? activeUserId;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  /// Room under the last card, so a floating button doesn't cover its
  /// amount.
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    // Each row is an ExpenseDateGroup caption or an expense, with where
    // it sits in its section's card.
    final rows = <Object>[
      for (final (group, expenses) in groupExpensesByDate(
        expenses,
        today: DateTime.now(),
        firstWeekday: firstWeekdayFor(View.of(context).platformDispatcher.locale),
      )) ...[
        group,
        for (var i = 0; i < expenses.length; i++)
          (expenses[i], i == 0, i == expenses.length - 1),
      ],
    ];
    final names = {for (final p in participants) p.id: p.name};
    final colors = participantColors(participants, activeUserId);
    return GroupedScrollClip(
        child: ListView.builder(
      keyboardDismissBehavior: keyboardDismissBehavior,
      padding: withBottomInset(context, EdgeInsets.only(top: 16, bottom: bottomPadding)),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final row = rows[i];
        if (row is ExpenseDateGroup) return _sectionHeader(context, row);
        final (e, first, last) = row as (Expense, bool, bool);
        return GroupedItem(
          first: first,
          last: last,
          // Past the category icon, under the title.
          dividerIndent: 66,
          child: ExpenseTile(
            expense: e,
            category: categoryFor(e.category),
            currency: currency,
            payer: names[e.paidBy],
            payerColor: colors[e.paidBy],
            activeUserId: activeUserId,
            onTap: () => onTap(e),
          ),
        );
      },
    ));
  }

  Widget _sectionHeader(BuildContext context, ExpenseDateGroup group) {
    final l10n = context.l10n;
    return GroupedCaption(switch (group) {
      ExpenseDateGroup.upcoming => l10n.dateSectionUpcoming,
      ExpenseDateGroup.thisWeek => l10n.dateSectionThisWeek,
      ExpenseDateGroup.earlierThisMonth => l10n.dateSectionEarlierThisMonth,
      ExpenseDateGroup.lastMonth => l10n.dateSectionLastMonth,
      ExpenseDateGroup.earlierThisYear => l10n.dateSectionEarlierThisYear,
      ExpenseDateGroup.lastYear => l10n.dateSectionLastYear,
      ExpenseDateGroup.older => l10n.dateSectionOlder,
    }, margin: GroupedCaption.listMargin);
  }
}

/// Each participant's color in a group (#207), fixed rather than hashed
/// so no two share one while there are colors left: you are always
/// emerald, the app's own accent, and the others take the rest of
/// [monogramPalette] by name, starting over past seven. By name, not
/// the group's order: the server returns participants in no fixed
/// order, which would recolor people between refreshes.
Map<String, Color> participantColors(List<Participant> participants, String? activeUserId) {
  final others = monogramPalette.sublist(1);
  final byName = [...participants]
    ..sort((a, b) {
      final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return name != 0 ? name : a.id.compareTo(b.id);
    });
  var next = 0;
  return {
    for (final p in byName)
      p.id: p.id == activeUserId ? monogramPalette[0] : others[next++ % others.length],
  };
}

/// One expense row in two lines, like a group's in the group list
/// (#207): the bold title and its repeat, receipt and notes marks, then
/// the amount; under them the date, what you lent or owe, and who paid,
/// or the sync state while it's pending.
class ExpenseTile extends StatelessWidget {
  const ExpenseTile({
    super.key,
    required this.expense,
    required this.category,
    required this.currency,
    required this.onTap,
    this.payer,
    this.payerColor,
    this.activeUserId,
  });

  final Expense expense;
  final Category category;
  final String currency;
  final VoidCallback onTap;

  /// The payer's name; null when the group doesn't know them.
  final String? payer;

  /// The payer's dot (see [participantColors]); none when null.
  final Color? payerColor;
  final String? activeUserId;

  @override
  Widget build(BuildContext context) {
    final e = expense;
    final l10n = context.l10n;
    final locale = context.appLocale;
    final mark = Theme.of(context).colorScheme.onSurfaceVariant;
    final amount = formatMoney(e.amountCents, currency, locale: locale);
    // e.date is already a date-only value (year/month/day of the
    // calendar day the expense happened on, not a real instant -- see
    // lib/services/date_only.dart) -- no .toLocal() here, that would
    // perform a real timezone conversion on a value that was never one,
    // and roll the date back a day west of UTC. See
    // decisions/date-handling.md.
    final date = formatDate(e.date, locale: locale);
    // Read out spelled out, shown padded so the column lines up.
    final shortDate = formatShortDate(e.date, locale: locale);
    final yours = _yourPart();
    final yoursText = yours == null ? null : formatMoney(yours.cents, currency, locale: locale);
    final paidByYou = activeUserId != null && e.paidBy == activeUserId;
    final recurring = e.recurrenceRule != RecurrenceRule.none;
    final receipts = e.documentCount > 0 || e.documents.isNotEmpty;
    final notes = e.notes.trim().isNotEmpty;
    // The whole row read as one label (#207): the title first, since a
    // screen reader user moving down the list tells rows apart by it, then
    // a sentence of who paid what, when and for which category (the icon's
    // meaning), what you lent or owe, the sync state, and the marks. Each
    // its own sentence, so the reader pauses between them.
    final categoryName = localizedCategoryName(context, category);
    final paid = switch ((paidByYou, payer, e.isReimbursement)) {
      (true, _, false) => l10n.expenseRowSpokenYouPaid(amount, date, categoryName),
      (true, _, true) => l10n.expenseRowSpokenYouPaidBack(amount, date, categoryName),
      (false, final String name, false) => l10n.expenseRowSpokenPaid(name, amount, date, categoryName),
      (false, final String name, true) =>
        l10n.expenseRowSpokenPaidBack(name, amount, date, categoryName),
      (false, null, _) => l10n.expenseRowSpokenNoPayer(amount, date, categoryName),
    };
    final label = spokenSentences([
      e.title,
      paid,
      if (yours != null)
        yours.lent ? l10n.expenseRowYouLent(yoursText!) : l10n.expenseRowYouOwe(yoursText!),
      if (e.syncFailed) l10n.groupScreenSyncFailed else if (e.pending) l10n.groupScreenSyncing,
      if (recurring) l10n.expenseRowRecurring,
      if (receipts) l10n.expenseRowHasReceipts,
      if (notes) l10n.expenseRowHasNotes,
    ], l10n.spokenSentenceEnd);
    return ListTile(
      leading: CategoryIconGlyph(category: category),
      title: Semantics(
        label: label,
        excludeSemantics: true,
        child: LayoutBuilder(builder: (context, constraints) {
          final marks = [
            if (recurring) LucideIcons.repeat,
            if (receipts) LucideIcons.paperclip,
            if (notes) LucideIcons.notebookPen,
          ];
          // The marks go when they and the amount leave no room for a few
          // letters of the title (a narrow phone, a large text size, #208);
          // they're read out and shown in the details all the same. Past
          // that, the amount shrinks rather than overflow.
          final titleStyle = DefaultTextStyle.of(context).style.merge(_titleStyle);
          final fits = _textWidth(context, 'Mmm…', titleStyle) +
                  marks.length * (4 + _Mark.sizeOf(context)) +
                  8 +
                  _textWidth(context, amount,
                      Money.styleOf(context, isReimbursement: e.isReimbursement)) <=
              constraints.maxWidth;
          return Row(children: [
            // A large text size leaves room for only a few letters a line,
            // so the title gets two, unless a word of it wouldn't fit a
            // line and would be broken in the middle.
            Expanded(
                child: LayoutBuilder(
                    builder: (context, title) => Text(e.title,
                    maxLines: MediaQuery.textScalerOf(context).scale(10) > 13 &&
                            e.title.split(' ').every((word) =>
                                _textWidth(context, word, titleStyle) <= title.maxWidth)
                        ? 2
                        : 1,
                    overflow: TextOverflow.ellipsis,
                    style: _titleStyle))),
            if (fits)
              for (final icon in marks) _Mark(icon, mark),
            const SizedBox(width: 8),
            Flexible(
                flex: 0,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: constraints.maxWidth - 8),
                  child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerEnd,
                      child: Money(amount, isReimbursement: e.isReimbursement)),
                )),
          ]);
        }),
      ),
      subtitle: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: LayoutBuilder(
              builder: (context, constraints) =>
                  _subtitle(context, constraints.maxWidth, shortDate, yours, yoursText, paidByYou)),
        ),
      ),
      // Every row opens its details (issue #90), pending and failed
      // ones included; the sheet decides what each state can do.
      onTap: onTap,
    );
  }

  static const _titleStyle = TextStyle(fontWeight: FontWeight.w600);

  /// How wide [text] lays out in [style] at the current text size.
  static double _textWidth(BuildContext context, String text, TextStyle? style) =>
      (TextPainter(
              text: TextSpan(text: text, style: style),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
              maxLines: 1)
            ..layout())
          .width;

  /// The date, what you lent or owe, and who paid (#207). The date and
  /// your part are measured first and the payer gets what's left, cut
  /// short; when that leaves no room for even a few letters of the payer
  /// (a narrow phone, a large text size), the date gets a line of its own
  /// and your part and the payer share the next (Ezra, #208).
  Widget _subtitle(BuildContext context, double maxWidth, String shortDate,
      ({int cents, bool lent})? yours, String? yoursText, bool paidByYou) {
    final scaler = MediaQuery.textScalerOf(context);
    final textStyle = DefaultTextStyle.of(context).style;
    final iconWidth = scaler.scale(textStyle.fontSize ?? 14) * 1.15;
    double widthOf(String text, TextStyle? style) =>
        _textWidth(context, text, textStyle.merge(style));

    // Tabular figures, so every date of a locale has one width and what
    // follows lines up.
    const dateStyle = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);
    final dateWidth = iconWidth + 4 + widthOf(shortDate, dateStyle);
    final yoursWidth = yours == null
        ? 0.0
        : 12 +
            iconWidth +
            2 +
            widthOf(yoursText!,
                Money.styleOf(context, size: MoneySize.support, sign: MoneySign.positive));
    // A few letters of a name and its dot.
    final payerMinWidth = 8 + widthOf('Mmm…', null) + 12;
    final oneLine = dateWidth + yoursWidth + payerMinWidth <= maxWidth;

    final date = Row(mainAxisSize: MainAxisSize.min, children: [
      const CaptionIcon(LucideIcons.calendar),
      const SizedBox(width: 4),
      Flexible(
          child: Text(shortDate, maxLines: 1, overflow: TextOverflow.ellipsis, style: dateStyle)),
    ]);
    final payer = Align(
        alignment: AlignmentDirectional.centerEnd, child: _status(context, paidByYou));
    final yoursAmount = yours == null ? null : _yourAmount(context, yours.lent, yoursText!);
    if (oneLine) {
      return Row(children: [
        date,
        if (yoursAmount != null) ...[const SizedBox(width: 12), yoursAmount],
        const SizedBox(width: 8),
        Expanded(child: payer),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      date,
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(children: [
          if (yoursAmount != null) ...[Flexible(child: yoursAmount), const SizedBox(width: 8)],
          Expanded(child: payer),
        ]),
      ),
    ]);
  }

  /// What you lent (paid, less your share) or owe (your share of what
  /// someone else paid); null when you're not in it, or for a
  /// reimbursement, whose amount already says it.
  ({int cents, bool lent})? _yourPart() {
    final e = expense;
    final me = activeUserId;
    if (me == null || e.isReimbursement) return null;
    final share = expenseShareCents(e)[me] ?? 0;
    final cents = e.paidBy == me ? e.amountCents - share : share;
    return cents > 0 ? (cents: cents, lent: e.paidBy == me) : null;
  }

  /// [_yourPart] as Balances colors it, with an arrow out or in.
  Widget _yourAmount(BuildContext context, bool lent, String amount) {
    final colors = SpliitColors.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      CaptionIcon(lent ? LucideIcons.arrowUpRight : LucideIcons.arrowDownLeft,
          color: lent ? colors.moneyPositive : colors.moneyNegative),
      const SizedBox(width: 2),
      // Shrunk rather than wrapped when there's no room (#208).
      Flexible(
          child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Money(amount,
                  size: MoneySize.support,
                  sign: lent ? MoneySign.positive : MoneySign.negative))),
    ]);
  }

  /// Who paid, under the amount; the sync state instead while the
  /// expense isn't on the server yet.
  Widget? _status(BuildContext context, bool paidByYou) {
    final e = expense;
    final l10n = context.l10n;
    if (e.syncFailed) {
      final error = Theme.of(context).colorScheme.error;
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.error_outline, size: 13, color: error),
        const SizedBox(width: 2),
        Flexible(
            child: Text(l10n.groupScreenSyncFailed,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: error))),
      ]);
    }
    if (e.pending) {
      return Text(l10n.groupScreenSyncing,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11));
    }
    final name = paidByYou ? l10n.expenseRowPaidByYou : payer;
    if (name == null) return null;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      // At the edge, so the dots line up whatever the name's length.
      if (payerColor != null) ...[
        const SizedBox(width: 4),
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: payerColor, shape: BoxShape.circle),
        ),
      ],
    ]);
  }
}

/// A small mark after the title: the expense repeats, has receipts, or
/// has notes. Read out with the row's label.
class _Mark extends StatelessWidget {
  const _Mark(this.icon, this.color);

  final IconData icon;
  final Color color;

  static double sizeOf(BuildContext context) => MediaQuery.textScalerOf(context).scale(14);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsetsDirectional.only(start: 4),
        child: Icon(icon, size: sizeOf(context), color: color),
      );
}
