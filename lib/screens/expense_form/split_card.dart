import 'package:flutter/material.dart';

import '../../l10n/context_l10n.dart';
import '../../models/expense.dart';
import '../../models/group.dart';
import '../../utils/money.dart';
import '../../widgets/expense_list.dart' show participantColors;
import '../../widgets/group_monogram.dart';
import '../../widgets/grouped_section.dart';
import '../../widgets/money.dart';
import '../../widgets/participant_sheet.dart';
import 'expense_form_model.dart';

/// "Paid for" (#260): the split mode, then each participant by their
/// monogram, dimmed when they aren't included. In Evenly a tap includes or
/// leaves them out, with Select all / none; in Shares, Percent and Amount
/// each has a value, and an empty or 0 one isn't included. Under the card,
/// the remainder, or once a save was tried, what's wrong.
class SplitCard extends StatelessWidget {
  const SplitCard({
    super.key,
    required this.model,
    required this.showErrors,
    this.footerKey,
  });

  final ExpenseFormModel model;

  /// A save was tried: a split that can't be saved says why, in red,
  /// rather than how much is left (issue #29 section 6).
  final bool showErrors;

  /// On the footer, for a refused save to scroll to.
  final Key? footerKey;

  /// From this text size on, a value goes under the name rather than
  /// beside it, which would squeeze the name to a word a line (#266
  /// review), as spliit-ios does at accessibility sizes.
  static const double _stackingTextScale = 1.3;

  ExpenseFormModel get _m => model;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final evenly = _m.splitMode == SplitMode.evenly;
    final colors = participantColors(_m.group.participants, _m.activeUserId);
    final preview = _m.livePreviewAmounts();
    final error = showErrors ? _error(context) : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(GroupedSection.inset, 0, GroupedSection.inset, GroupedSection.spacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GroupedSection(
            caption: l10n.expensePaidForHeading,
            // Always offers the opposite of the current state (issue #29
            // section 2); only an even split selects anyone.
            captionTrailing: evenly
                ? TextButton(
                    onPressed: _m.toggleSelectAll,
                    child: Text(_m.allIncluded ? l10n.expenseSelectNone : l10n.expenseSelectAll),
                  )
                : null,
            margin: EdgeInsets.zero,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: _modes(context),
              ),
              // The people's lines start at their names; the card's own,
              // around them, at its edge.
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final (i, p) in _m.group.participants.indexed) ...[
                  if (i > 0) const GroupedDivider(indent: ChoiceRow.monogramIndent),
                  _row(context, p, colors[p.id]!, preview?[p.id]),
                ],
              ]),
              // A settlement is a one-off, not the group's usual split
              // (issue #29 section 7).
              if (!_m.isSettlement)
                GroupedRow(
                  title: Text(l10n.expenseSaveDefaultSplit),
                  trailing: Switch.adaptive(
                    value: _m.saveDefaultSplit,
                    onChanged: (v) => _m.saveDefaultSplit = v,
                  ),
                  onTap: () => _m.saveDefaultSplit = !_m.saveDefaultSplit,
                ),
            ],
          ),
          Padding(
            key: footerKey,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              error ?? _hint(context),
              style: theme.textTheme.bodySmall?.copyWith(
                  color: error != null ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modes(BuildContext context) {
    final l10n = context.l10n;
    return SegmentedButton<SplitMode>(
      segments: [
        ButtonSegment(value: SplitMode.evenly, label: Text(l10n.expenseSplitEvenly)),
        ButtonSegment(value: SplitMode.byShares, label: Text(l10n.expenseSplitShares)),
        ButtonSegment(value: SplitMode.byPercentage, label: Text(l10n.expenseSplitPercent)),
        ButtonSegment(value: SplitMode.byAmount, label: Text(l10n.expenseSplitAmount)),
      ],
      selected: {_m.splitMode},
      // The selected segment is already highlighted -- with 4 segments
      // crammed into the row, the extra check icon pushed a label like
      // "Percent" onto 3 lines (issue #32).
      showSelectedIcon: false,
      onSelectionChanged: (selection) {
        // A focused value field that this removes or refills would hand
        // its focus back up the form, which then scrolls to it (issue
        // #36): unfocus first.
        FocusScope.of(context).unfocus();
        _m.splitMode = selection.first;
      },
    );
  }

  /// A person: dimmed when not included, and beside the name (or under
  /// it, in large text) their value with what it comes to under that.
  /// In Evenly the row is a checkbox: a tap includes or leaves them out,
  /// and it says checked or not to a screen reader.
  Widget _row(BuildContext context, Participant p, Color color, int? preview) {
    final theme = Theme.of(context);
    final evenly = _m.splitMode == SplitMode.evenly;
    final included = _m.isIncluded(p.id);
    final value = evenly
        ? (preview == null ? null : _amount(context, preview))
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SizedBox(width: 96, child: _valueField(context, p)),
              // Amount's value is the amount itself.
              if (preview != null && _m.splitMode != SplitMode.byAmount)
                Padding(padding: const EdgeInsets.only(top: 2, right: 10), child: _amount(context, preview)),
            ],
          );
    final stacks = !evenly && MediaQuery.textScalerOf(context).scale(10) / 10 >= _stackingTextScale;
    final name = Text(participantName(context, p, _m.activeUserId),
        style: theme.textTheme.bodyLarge
            ?.copyWith(color: included ? null : theme.colorScheme.onSurface.withValues(alpha: 0.4)));
    final monogram = Opacity(opacity: included ? 1 : 0.4, child: Monogram(name: p.name, color: color, radius: 12));
    // Not a ListTile, which caps what's beside the name at one line's
    // height: here the amount goes under the value.
    final row = InkWell(
      onTap: evenly ? () => _m.setIncluded(p.id, !included) : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: GroupedRow.oneLineMinHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: stacks
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [monogram, const SizedBox(width: 16), Expanded(child: name)]),
                  const SizedBox(height: 6),
                  Padding(padding: const EdgeInsetsDirectional.only(start: 40), child: value),
                ])
              : Row(children: [
                  monogram,
                  const SizedBox(width: 16),
                  Expanded(child: name),
                  if (value != null) ...[const SizedBox(width: 12), value],
                ]),
        ),
      ),
    );
    return evenly ? Semantics(checked: included, child: row) : row;
  }

  Widget _valueField(BuildContext context, Participant p) {
    final colors = Theme.of(context).colorScheme;
    final shape = OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none);
    return TextFormField(
      controller: _m.splitControllers[p.id],
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textAlign: TextAlign.right,
      // A box on the card, so it reads as a field: the page's color.
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: GroupedSection.backgroundColor(context),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: shape,
        enabledBorder: shape,
        focusedBorder: shape.copyWith(borderSide: BorderSide(color: colors.primary, width: 1.5)),
        prefixText: _m.splitMode == SplitMode.byAmount ? _m.group.currency : null,
        suffixText: _m.splitMode == SplitMode.byPercentage ? '%' : null,
      ),
    );
  }

  Widget _amount(BuildContext context, int amount) => Money(
      formatMoney(amount, _m.group.currency, decimalDigits: _m.digits, locale: context.appLocale),
      size: MoneySize.support);

  /// What's wrong with the split, in words, if anything.
  String? _error(BuildContext context) {
    final l10n = context.l10n;
    return switch (_m.splitProblem()) {
      null => null,
      NoOneIncluded() => l10n.expenseSelectAtLeastOne,
      InvalidValue(:final participant) => switch (_m.splitMode) {
          SplitMode.byShares => l10n.expenseEnterShares(participant.name),
          SplitMode.byPercentage => l10n.expenseEnterPercentage(participant.name),
          _ => l10n.expenseEnterAmount(participant.name),
        },
      PercentagesDontAddUp(:final totalBasisPoints) =>
        l10n.expensePercentageMismatch(trimTrailingZeros(totalBasisPoints / 100)),
      AmountsDontAddUp(:final difference) => l10n.expenseAmountMismatch(formatMoney(
          difference.abs(), _m.group.currency,
          decimalDigits: _m.digits, locale: context.appLocale)),
    };
  }

  /// A running "still to allocate"/"over" for Percent and Amount, or the
  /// mode's explanation (issue #29 section 6).
  String _hint(BuildContext context) {
    final l10n = context.l10n;
    final unallocated = _m.unallocated();
    if (unallocated != null && unallocated != 0) {
      final over = unallocated < 0;
      final magnitude = unallocated.abs();
      if (_m.splitMode == SplitMode.byPercentage) {
        final formatted = trimTrailingZeros(magnitude);
        return over ? l10n.expensePercentOver(formatted) : l10n.expensePercentRemaining(formatted);
      }
      final formattedAmount = formatMoney(toMinorUnits(magnitude, _m.digits), _m.group.currency,
          decimalDigits: _m.digits, locale: context.appLocale);
      return over ? l10n.expenseAmountOver(formattedAmount) : l10n.expenseAmountRemaining(formattedAmount);
    }
    return switch (_m.splitMode) {
      SplitMode.evenly => l10n.expenseHintEvenly,
      SplitMode.byShares => l10n.expenseHintShares,
      SplitMode.byPercentage => l10n.expenseHintPercentage,
      SplitMode.byAmount => l10n.expenseHintAmount,
    };
  }
}
