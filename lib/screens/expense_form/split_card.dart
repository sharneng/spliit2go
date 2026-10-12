import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/context_l10n.dart';
import '../../l10n/currency_names.dart';
import '../../models/currency.dart';
import '../../models/expense.dart';
import '../../models/group.dart';
import '../../utils/money.dart';
import '../../widgets/participant_colors.dart';
import '../../widgets/group_monogram.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/grouped_section.dart';
import '../../widgets/label_and_value.dart';
import '../../widgets/money.dart';
import '../../widgets/participant_sheet.dart';
import '../../widgets/segmented_pill.dart';
import '../../widgets/text_scaled.dart';
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
    final error = showErrors ? problem(context, _m) : _convertedError(context, _m);
    final settlement = _m.isSettlement;
    final message = Text(
      error ?? _hint(context) ?? '',
      style: GroupedSection.footnoteStyle(context, color: error != null ? theme.colorScheme.error : null),
    );
    final hasMessage = error != null || _hint(context) != null;
    // "Paid for" (a settlement's "To") as a row's label, as "Paid by"'s
    // above it; an even split's Select none/all at its end.
    // At a row's text size, as GroupedRow gives "Paid by"'s.
    final headingLabel = DefaultTextStyle.merge(
      style: theme.textTheme.bodyLarge,
      child: formLabel(context, settlement ? l10n.expenseToHeading : l10n.expensePaidForHeading),
    );
    final heading = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: GroupedRow.oneLineMinHeight),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
        // Vertically centered when it's the label alone.
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: evenly
              ? LabelAndValue(
                  label: headingLabel,
                  // Always offers the opposite of the current state (issue
                  // #29 section 2); only an even split selects anyone.
                  value: TextButton(
                    onPressed: _m.toggleSelectAll,
                    // As tall as the heading's row.
                    style: compactTextButtonStyle(minHeight: kMinInteractiveDimension),
                    child: Text(_m.allIncluded ? l10n.expenseSelectNone : l10n.expenseSelectAll),
                  ),
                  runGap: 0,
                )
              : headingLabel,
        ),
      ),
    );
    final people = LayoutBuilder(builder: (context, constraints) {
      final under = _valuesUnder(context, constraints.maxWidth, preview);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // The people's lines start at their names; the card's own, around
      // them, at its edge.
      for (final (i, p) in _toList.indexed) ...[
        if (i > 0) const GroupedDivider(indent: ChoiceRow.monogramIndent),
        _row(context, p, colors[p.id]!, preview?[p.id], under: under),
      ],
      // An expense's split says how much is left right under the people,
      // above "Save as default split" (Kenneth, 2026-10-10).
      if (!settlement && hasMessage)
        Padding(key: footerKey, padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: message),
    ]);
    });
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
            _modes(context),
          ]),
        people,
        if (settlement) ..._totals(context),
        // A settlement is a one-off, not the group's usual split
        // (issue #29 section 7).
        if (!settlement)
          // One element: "Save as default split, switch, off".
          MergeSemantics(child: GroupedRow(
            title: Text(l10n.expenseSaveDefaultSplit),
            // Under it at large text, as a row's value (Kenneth, #294).
            value: Switch.adaptive(
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
  ///
  /// A menu row instead, as Repeat's, when a mode's name doesn't fit its
  /// segment (#263): at large text sizes, on a narrow screen, in a longer
  /// language.
  Widget _modes(BuildContext context) {
    void choose(SplitMode mode) {
      // A focused value field that this removes or refills would hand
      // its focus back up the form, which then scrolls to it (issue
      // #36): unfocus first.
      FocusScope.of(context).unfocus();
      _m.splitMode = mode;
    }

    final pill = SegmentedPill<SplitMode>(
      segments: {for (final mode in SplitMode.values) mode: _modeName(context, mode)},
      selected: _m.splitMode,
      // The pill is 35pt; its segments' targets 48 (#263), into the card's
      // space under it and a point above.
      tapPadding: const EdgeInsets.only(top: 1, bottom: 12),
      onChanged: choose,
    );
    const inset = EdgeInsets.symmetric(horizontal: 12);
    return LayoutBuilder(
      builder: (context, constraints) => pill.fits(context, constraints.maxWidth - inset.horizontal)
          ? Padding(padding: inset, child: pill)
          // To a screen reader a button, "Split, Evenly", as Repeat's.
          : MenuRow(
              key: modeMenuKey,
              title: formLabel(context, context.l10n.expenseSplitLabel),
              value: Text(_modeName(context, _m.splitMode), style: formValueStyle(context)),
              onOpened: () => FocusScope.of(context).unfocus(),
              items: [
                for (final mode in SplitMode.values)
                  AppMenuItem(label: _modeName(context, mode), checked: mode == _m.splitMode, onSelected: () => choose(mode)),
              ],
            ),
    );
  }

  /// The split mode's menu, where the pill doesn't fit.
  static const modeMenuKey = Key('split-mode-menu');



  /// A person: dimmed when not included, and beside the name (or under
  /// it, in large text) their value with what it comes to under that.
  /// In Evenly the row is a checkbox: a tap includes or leaves them out,
  /// and it says checked or not to a screen reader.
  /// Whether every row's value goes under its name (Kenneth, #294): when
  /// the widest would leave the names less than half the row. One answer
  /// for all of them, so they don't go under one by one as names grow.
  bool _valuesUnder(BuildContext context, double width, Map<String, int>? preview) {
    final evenly = _m.splitMode == SplitMode.evenly;
    final amounts = [
      if (preview != null && _m.splitMode != SplitMode.byAmount)
        for (final amount in preview.values)
          formatMoney(amount, _m.group.currency, decimalDigits: _m.digits, locale: context.appLocale),
    ];
    // What each field shows: its prefix or suffix, and what's typed or "0".
    final typed = [
      if (!evenly)
        for (final p in _toList)
          [
            if (_m.splitMode == SplitMode.byAmount) '${_m.splitSymbol} ',
            switch (_m.splitControllers[p.id]?.text) { final text? when text.isNotEmpty => text, _ => '0' },
            if (_m.splitMode == SplitMode.byPercentage) '%',
          ].join(),
    ];
    final amountStyle = Money.styleOf(context, size: MoneySize.support);
    final fieldStyle = DefaultTextStyle.of(context).style.merge(formValueStyle(context));
    final widest = [
      0.0,
      for (final amount in amounts) measuredTextWidth(context, amount, amountStyle),
      for (final text in typed) measuredTextWidth(context, text, fieldStyle),
    ].reduce(math.max);
    final check = evenly ? 12 + context.textScaled(24) : 0;
    return valuesGoUnder(row: width - 2 * 16, label: context.textScaled(24) + 16, widest: 12 + widest + check);
  }

  Widget _row(BuildContext context, Participant p, Color color, int? preview, {required bool under}) {
    final theme = Theme.of(context);
    final evenly = _m.splitMode == SplitMode.evenly;
    final included = _m.isIncluded(p.id);
    final name = Text(participantName(context, p, _m.activeUserId),
        style: theme.textTheme.bodyLarge
            ?.copyWith(color: included ? null : theme.colorScheme.onSurface.withValues(alpha: 0.4)));
    final monogram = Opacity(opacity: included ? 1 : 0.4, child: Monogram(name: p.name, color: color, radius: 12));
    // Not a ListTile, which caps what's beside the name at one line's
    // height: here the amount goes under the value. The value goes under
    // the name when the two don't fit on a line, which would squeeze the
    // name to a word a line (#266 review), as spliit-ios does at
    // accessibility sizes. Every row's goes under, or none (#294).
    Widget layout(Widget name, Widget value) => ConstrainedBox(
          constraints: const BoxConstraints(minHeight: GroupedRow.oneLineMinHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: LabelAndValue(
              label: MonogramLabel(monogram: monogram, name: name, nameStyle: theme.textTheme.bodyLarge),
              value: value,
              gap: 12,
              runGap: 6,
              under: under,
            ),
          ),
        );
    if (evenly) {
      // Who's in is checked, as in the Paid by sheet, not only shown by the
      // dimming (Kenneth, 2026-10-11): a mark doesn't rely on seeing the
      // contrast. Out, the check's space stays, so the amounts line up. It
      // goes with the amount, beside the name or under it (Kenneth).
      final value = Row(mainAxisSize: MainAxisSize.min, children: [
        if (preview != null) ...[_amount(context, preview), const SizedBox(width: 12)],
        Visibility.maintain(visible: included, child: Icon(Icons.check, color: theme.colorScheme.primary)),
      ]);
      return Semantics(
          checked: included, child: InkWell(onTap: () => _m.setIncluded(p.id, !included), child: layout(name, value)));
    }
    // The whole row is the value's: a tap anywhere types it, and it's one
    // element to a screen reader, "Bea, Percent", its value, and what that
    // comes to (#263).
    return InlineNumberField(
      fieldKey: valueKey(p.id),
      controller: _m.splitControllers[p.id]!,
      name: context.l10n.expenseFieldName(p.name, _modeName(context, _m.splitMode)),
      prefix: _m.splitMode == SplitMode.byAmount ? '${_m.splitSymbol} ' : null,
      suffix: _m.splitMode == SplitMode.byPercentage ? '%' : null,
      contentPadding: EdgeInsets.zero,
      row: (context, field) => layout(
        ExcludeSemantics(child: name),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // As wide as its characters at the text size (Kenneth, #294).
            field,
            // Amount's value is the amount itself.
            if (preview != null && _m.splitMode != SplitMode.byAmount)
              Padding(padding: const EdgeInsets.only(top: 2), child: _amount(context, preview)),
          ],
        ),
      ),
    );
  }

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

  /// What a refused save says is wrong here (#263): the split, or a
  /// settlement's amount that converts to nothing.
  static String? problem(BuildContext context, ExpenseFormModel model) =>
      _splitError(context, model) ?? _convertedError(context, model);

  static String? _convertedError(BuildContext context, ExpenseFormModel m) =>
      m.isSettlement && m.convertedAmountInvalid ? context.l10n.expenseConvertedAmountInvalid : null;

  /// What's wrong with the split, in words, if anything.
  static String? _splitError(BuildContext context, ExpenseFormModel m) {
    final l10n = context.l10n;
    return switch (m.splitProblem()) {
      null => null,
      NoOneIncluded() when m.isSettlement => l10n.expenseSettlementNoRecipient,
      NoOneIncluded() => l10n.expenseSelectAtLeastOne,
      InvalidValue(:final participant) => switch (m.splitMode) {
          SplitMode.byShares => l10n.expenseEnterShares(participant.name),
          SplitMode.byPercentage => l10n.expenseEnterPercentage(participant.name),
          _ => l10n.expenseEnterAmount(participant.name),
        },
      // Short or over, not just "off by" (Kenneth, 2026-10-10).
      PercentagesDontAddUp(:final totalBasisPoints) => () {
          final by = m.shareText((10000 - totalBasisPoints).abs() / 100);
          return totalBasisPoints < 10000 ? l10n.expensePercentageShort(by) : l10n.expensePercentageOverBy(by);
        }(),
      AmountsDontAddUp(:final difference) => () {
          final by = formatMoney(difference.abs(), m.splitSymbol,
              decimalDigits: m.splitDigits, locale: context.appLocale);
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
