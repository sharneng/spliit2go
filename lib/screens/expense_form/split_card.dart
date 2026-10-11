import 'package:flutter/material.dart';

import '../../l10n/context_l10n.dart';
import '../../l10n/currency_names.dart';
import '../../models/currency.dart';
import '../../models/expense.dart';
import '../../models/group.dart';
import '../../utils/money.dart';
import '../../widgets/participant_colors.dart';
import '../../widgets/group_monogram.dart';
import '../../widgets/grouped_section.dart';
import '../../widgets/money.dart';
import '../../widgets/participant_sheet.dart';
import '../../widgets/segmented_pill.dart';
import 'expense_form_model.dart';
import 'form_text.dart';
import 'inline_number_field.dart';

/// "Paid for" (#260): the split mode, then each participant by their
/// monogram, dimmed when they aren't included. In Evenly a tap includes or
/// leaves them out, with Select all / none; in Shares, Percent and Amount
/// each has a value, and an empty or 0 one isn't included. Under the card,
/// the remainder, or once a save was tried, what's wrong.
///
/// A settlement's "To" (#262) is the Amount rows alone, in the paid-in
/// currency: no modes and no default split, then their Total and, when
/// converting, what that is in the group's currency. Under it, what was
/// paid as a sentence.
class SplitCard extends StatelessWidget {
  const SplitCard({
    super.key,
    required this.model,
    required this.showErrors,
    this.payer,
    this.footerKey,
  });

  final ExpenseFormModel model;

  /// "Paid by" (a settlement's "From"), the card's first row (Kenneth,
  /// 2026-10-10: a card of its own, one row, looked stranded).
  final Widget? payer;

  /// A save was tried: a split that can't be saved says why, in red,
  /// rather than how much is left (issue #29 section 6).
  final bool showErrors;

  /// On what the split says (how much is left, or what's wrong), for a
  /// refused save to scroll to.
  final Key? footerKey;

  /// From this text size on, a value goes under the name rather than
  /// beside it, which would squeeze the name to a word a line (#266
  /// review), as spliit-ios does at accessibility sizes.
  static const double _stackingTextScale = 1.3;

  ExpenseFormModel get _m => model;

  /// A person's value field: their shares, percent or amount.
  static Key valueKey(String participantId) => ValueKey('splitCard.value.$participantId');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final evenly = _m.splitMode == SplitMode.evenly;
    final colors = participantColors(_m.group.participants, _m.activeUserId);
    final preview = _m.livePreviewAmounts();
    // A settlement's amount is this card's: when it converts to nothing,
    // it says so here, where a refused save scrolls (#262 review).
    final error = (showErrors ? _error(context) : null) ??
        (_m.isSettlement && _m.convertedAmountInvalid ? l10n.expenseConvertedAmountInvalid : null);
    final settlement = _m.isSettlement;
    final message = Text(
      error ?? _hint(context) ?? '',
      style: GroupedSection.footnoteStyle(context, color: error != null ? theme.colorScheme.error : null),
    );
    final hasMessage = error != null || _hint(context) != null;
    // "Paid for" (a settlement's "To") as a row's label, as "Paid by"'s
    // above it; an even split's Select none/all at its end.
    final heading = SizedBox(
      height: GroupedRow.oneLineMinHeight,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
        child: Row(children: [
          // At a row's text size, as GroupedRow gives "Paid by"'s.
          Expanded(
            child: DefaultTextStyle.merge(
              style: theme.textTheme.bodyLarge,
              child: formLabel(context, settlement ? l10n.expenseToHeading : l10n.expensePaidForHeading),
            ),
          ),
          // Always offers the opposite of the current state (issue #29
          // section 2); only an even split selects anyone.
          if (evenly)
            TextButton(
              onPressed: _m.toggleSelectAll,
              style: compactTextButtonStyle(),
              child: Text(_m.allIncluded ? l10n.expenseSelectNone : l10n.expenseSelectAll),
            ),
        ]),
      ),
    );
    final people = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // The people's lines start at their names; the card's own, around
      // them, at its edge.
      for (final (i, p) in _toList.indexed) ...[
        if (i > 0) const GroupedDivider(indent: ChoiceRow.monogramIndent),
        _row(context, p, colors[p.id]!, preview?[p.id]),
      ],
      // An expense's split says how much is left right under the people,
      // above "Save as default split" (Kenneth, 2026-10-10).
      if (!settlement && hasMessage)
        Padding(key: footerKey, padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: message),
    ]);
    return GroupedSection(
      // A settlement's, only what's wrong, under it.
      footerKey: settlement ? footerKey : null,
      footerContent: [if (settlement && hasMessage) message],
      children: [
        if (payer case final payer?) payer,
        if (settlement)
          heading
        else
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            heading,
            Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: _modes(context)),
          ]),
        people,
        if (settlement) ..._totals(context),
        // A settlement is a one-off, not the group's usual split
        // (issue #29 section 7).
        if (!settlement)
          // One element: "Save as default split, switch, off".
          MergeSemantics(child: GroupedRow(
            title: Text(l10n.expenseSaveDefaultSplit),
            trailing: Switch.adaptive(
              value: _m.saveDefaultSplit,
              onChanged: (v) => _m.saveDefaultSplit = v,
            ),
            onTap: () => _m.saveDefaultSplit = !_m.saveDefaultSplit,
          )),
      ],
    );
  }

  static String _modeName(BuildContext context, SplitMode mode) {
    final l10n = context.l10n;
    return switch (mode) {
      SplitMode.evenly => l10n.expenseSplitEvenly,
      SplitMode.byShares => l10n.expenseSplitShares,
      SplitMode.byPercentage => l10n.expenseSplitPercent,
      SplitMode.byAmount => l10n.expenseSplitAmount,
    };
  }

  /// The split mode, as spliit-ios's (Kenneth, 2026-10-10), at the old
  /// control's height.
  Widget _modes(BuildContext context) {
    return SegmentedPill<SplitMode>(
      segments: {for (final mode in SplitMode.values) mode: _modeName(context, mode)},
      selected: _m.splitMode,
      onChanged: (mode) {
        // A focused value field that this removes or refills would hand
        // its focus back up the form, which then scrolls to it (issue
        // #36): unfocus first.
        FocusScope.of(context).unfocus();
        _m.splitMode = mode;
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
        // Who's in is checked, as in the Paid by sheet, not only shown by
        // the dimming (Kenneth, 2026-10-11): a mark doesn't rely on seeing
        // the contrast. Out, the check's space stays, so the amounts line
        // up.
        ? Row(mainAxisSize: MainAxisSize.min, children: [
            if (preview != null) ...[_amount(context, preview), const SizedBox(width: 12)],
            Visibility.maintain(
              visible: included,
              child: Icon(Icons.check, color: theme.colorScheme.primary),
            ),
          ])
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SizedBox(width: 96, child: _valueField(context, p)),
              // Amount's value is the amount itself.
              if (preview != null && _m.splitMode != SplitMode.byAmount)
                Padding(padding: const EdgeInsets.only(top: 2), child: _amount(context, preview)),
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
                  const SizedBox(width: 12),
                  value,
                ]),
        ),
      ),
    );
    return evenly ? Semantics(checked: included, child: row) : row;
  }

  /// A person's value, as the form's other fields (Kenneth, 2026-10-10):
  /// plain right-aligned text on the card rather than a box in the page's
  /// color, with its "%" or currency symbol right beside the digits, and
  /// the whole value's width a tap target.
  Widget _valueField(BuildContext context, Participant p) => InlineNumberField(
        fieldKey: valueKey(p.id),
        controller: _m.splitControllers[p.id]!,
        name: context.l10n.expenseFieldName(p.name, _modeName(context, _m.splitMode)),
        prefix: _m.splitMode == SplitMode.byAmount ? '${_m.splitSymbol} ' : null,
        suffix: _m.splitMode == SplitMode.byPercentage ? '%' : null,
        contentPadding: EdgeInsets.zero,
      );



  /// A settlement's Total, in the paid-in currency, and converted.
  List<Widget> _totals(BuildContext context) {
    final l10n = context.l10n;
    return [
      const GroupedDivider(),
      workedOutRow(context, l10n.expenseSettlementTotal, _m.settlementTotal, _m.splitSymbol, _m.splitDigits),
      if (_m.converting)
        workedOutRow(
            context,
            l10n.expenseInCurrency(
                localizedCurrencyName(context, currencyByCode(_m.group.currencyCode), inSentence: true)),
            _m.amount,
            _m.group.currency,
            _m.digits),
    ];
  }




  Widget _amount(BuildContext context, int amount) => Money(
      formatMoney(amount, _m.group.currency, decimalDigits: _m.digits, locale: context.appLocale),
      size: MoneySize.support);

  /// What's wrong with the split, in words, if anything.
  String? _error(BuildContext context) {
    final l10n = context.l10n;
    return switch (_m.splitProblem()) {
      null => null,
      NoOneIncluded() when _m.isSettlement => l10n.expenseSettlementNoRecipient,
      NoOneIncluded() => l10n.expenseSelectAtLeastOne,
      InvalidValue(:final participant) => switch (_m.splitMode) {
          SplitMode.byShares => l10n.expenseEnterShares(participant.name),
          SplitMode.byPercentage => l10n.expenseEnterPercentage(participant.name),
          _ => l10n.expenseEnterAmount(participant.name),
        },
      // Short or over, not just "off by" (Kenneth, 2026-10-10).
      PercentagesDontAddUp(:final totalBasisPoints) => () {
          final by = _m.shareText((10000 - totalBasisPoints).abs() / 100);
          return totalBasisPoints < 10000 ? l10n.expensePercentageShort(by) : l10n.expensePercentageOverBy(by);
        }(),
      AmountsDontAddUp(:final difference) => () {
          final by = formatMoney(difference.abs(), _m.splitSymbol,
              decimalDigits: _m.splitDigits, locale: context.appLocale);
          // The difference is the total less what's split.
          return difference > 0 ? l10n.expenseAmountShort(by) : l10n.expenseAmountOverBy(by);
        }(),
    };
  }

  /// Everyone, but a settlement's From isn't among its To (Kenneth,
  /// 2026-10-10), unless an older one saved them with an amount, which
  /// would otherwise count unseen.
  List<Participant> get _toList => [
        for (final p in _m.group.participants)
          if (!_m.isSettlement || p.id != _m.paidBy || (_m.typedValue(p) ?? 0) != 0) p,
      ];

  /// A running "still to allocate"/"over" for Percent and Amount, or the
  /// mode's explanation (issue #29 section 6). A settlement has
  /// none: "Enter what each person was paid" and "Ken paid Jenny $78.00"
  /// only said what the card shows (Kenneth, 2026-10-10). Under it, only
  /// what's wrong.
  String? _hint(BuildContext context) {
    final l10n = context.l10n;
    if (_m.isSettlement) return null;
    final unallocated = _m.unallocated();
    if (unallocated != null && unallocated != 0) {
      final over = unallocated < 0;
      final magnitude = unallocated.abs();
      if (_m.splitMode == SplitMode.byPercentage) {
        final formatted = _m.shareText(magnitude);
        return over ? l10n.expensePercentOver(formatted) : l10n.expensePercentRemaining(formatted);
      }
      final formattedAmount = formatMoney(toMinorUnits(magnitude, _m.splitDigits), _m.splitSymbol,
          decimalDigits: _m.splitDigits, locale: context.appLocale);
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
