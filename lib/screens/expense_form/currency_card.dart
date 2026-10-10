import 'package:flutter/material.dart';

import '../../l10n/context_l10n.dart';
import '../../models/currency.dart';
import '../../utils/money.dart';
import '../../widgets/grouped_section.dart';
import '../../widgets/money.dart';
import '../../theme.dart';
import 'expense_form_model.dart';
import 'form_text.dart';

/// The currency and the amount (#261), in the order of a conversion: Paid
/// in, the amount typed in it, the rate as one number with the more
/// valuable currency first (EUR/JPY = 176.84; a tap on the pair swaps
/// it), and what that comes to in the group's currency, worked out. Where
/// the rate comes from goes under the card, with "Use the published rate".
/// A settlement's amount is on its To card (#262): here, only the currency
/// and the rate.
class CurrencyCard extends StatelessWidget {
  const CurrencyCard({
    super.key,
    required this.model,
    required this.onPickPaidIn,
    required this.onSwapRate,
    required this.rateStatus,
    required this.onUsePublishedRate,
    this.amountHint,
    this.calculatedKey,
    this.showErrors = false,
  });

  final ExpenseFormModel model;
  final VoidCallback onPickPaidIn;
  final VoidCallback onSwapRate;

  /// Where the rate comes from, or that it's being looked up.
  final String? rateStatus;

  /// Puts the published rate back; null when there's nothing to put back.
  final VoidCallback? onUsePublishedRate;

  /// What a scanned receipt said the amount was, if it was filled in.
  final String? amountHint;

  /// On the worked-out amount, for a refused save to scroll to.
  final Key? calculatedKey;

  /// Once a save has been tried: the amount's error, under its row.
  final bool showErrors;

  ExpenseFormModel get _m => model;

  /// The amount's field, whichever currency it's in, and the rate's.
  static const amountFieldKey = ValueKey('currencyCard.amount');
  static const rateFieldKey = ValueKey('currencyCard.rate');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final converting = _m.converting;
    final secondary = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final footer = [
      if (amountHint case final hint?) Text(hint, style: secondary),
      // A settlement's says so on its To card.
      if (_m.convertedAmountInvalid && !_m.isSettlement)
        Text(l10n.expenseConvertedAmountInvalid,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
      if (converting && rateStatus != null) Text(rateStatus!, style: secondary),
    ];
    // A settlement in a group without a currency code has nothing here.
    if (_m.isSettlement && !_m.hasGroupCurrencyCode) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(GroupedSection.inset, 0, GroupedSection.inset, GroupedSection.spacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GroupedSection(
            margin: EdgeInsets.zero,
            children: [
              // Only an ISO code converts.
              if (_m.hasGroupCurrencyCode)
                GroupedRow(
                  title: formLabel(context, l10n.expensePaidIn),
                  trailing: Text(_m.paidInCurrency.name, style: formValueStyle(context)),
                  navigates: true,
                  onTap: onPickPaidIn,
                ),
              // An expense's amount is what was paid, in the currency it
              // was paid in. A settlement's is its To amounts' sum (#262),
              // on the To card.
              if (!_m.isSettlement)
                if (converting)
                  _amountRow(context, _m.originalAmountController, _m.paidInSymbol, _m.originalDigits)
                else
                  _amountRow(context, _m.amountController, _m.group.currency, _m.digits),
              if (converting) ...[
                _rateRow(context),
                if (!_m.isSettlement)
                  _workedOut(context, l10n.expenseInCurrency(currencyByCode(_m.group.currencyCode).name),
                      _m.amount, _m.group.currency, _m.digits),
              ],
            ],
          ),
          if (footer.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 2, children: footer),
            ),
          if (converting && onUsePublishedRate != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(onPressed: onUsePublishedRate, child: Text(l10n.expenseUsePublishedRate)),
            ),
        ],
      ),
    );
  }

  /// A label, and the field it names at the row's end.
  Widget _fieldRow(BuildContext context, Widget label, Widget field) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: GroupedRow.oneLineMinHeight),
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 16, end: 16),
          child: Row(children: [
            DefaultTextStyle.merge(style: Theme.of(context).textTheme.bodyLarge, child: label),
            const SizedBox(width: 16),
            Expanded(child: field),
          ]),
        ),
      );

  /// The amount, its currency symbol right before the digits (Kenneth,
  /// 2026-10-10): always there, rather than Material's prefix, which
  /// shows only once the field has the focus, and at its start edge, far
  /// from the right-aligned digits. Grey with the "0" hint until typed.
  Widget _amountRow(BuildContext context, TextEditingController controller, String symbol, int digits) {
    final l10n = context.l10n;
    final focus = _m.amountFocus;
    // The row is the form's field (a refused save scrolls to it), and
    // says what's wrong under it, rather than under the text field, which
    // is only as wide as its digits.
    return FormField<void>(
      validator: (_) => _m.isPositiveAmount(controller.text, digits) ? null : l10n.expenseInvalidAmount,
      builder: (_) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _amountField(context, controller, symbol, digits, focus),
          if (showErrors && !_m.isPositiveAmount(controller.text, digits))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(l10n.expenseInvalidAmount,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
            ),
        ]),
      ),
    );
  }

  Widget _amountField(
      BuildContext context, TextEditingController controller, String symbol, int digits, FocusNode focus) {
    final l10n = context.l10n;
    return GestureDetector(
      // The whole row is the field's: its text is only as wide as typed.
      behavior: HitTestBehavior.opaque,
      onTap: focus.requestFocus,
      child: _fieldRow(
        context,
        formLabel(context, l10n.expenseAmountLabel),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text('$symbol ',
                style: controller.text.isEmpty
                    ? TextStyle(color: SpliitColors.of(context).secondaryContent)
                    : formValueStyle(context)),
            Flexible(
              child: IntrinsicWidth(
                child: TextFormField(
                  key: amountFieldKey,
                  controller: controller,
                  focusNode: focus,
                  textAlign: TextAlign.end,
                  decoration: const InputDecoration(hintText: '0', isDense: true),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The rate as one number: the pair, which swaps on a tap, and the field.
  Widget _rateRow(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    return _fieldRow(
      context,
      Tooltip(
        message: l10n.expenseSwapRate,
        child: InkWell(
          onTap: onSwapRate,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(_m.ratePair, style: TextStyle(color: colors.primary)),
              const SizedBox(width: 4),
              Icon(Icons.swap_horiz, size: 18, color: colors.primary),
            ]),
          ),
        ),
      ),
      TextFormField(
        key: rateFieldKey,
        controller: _m.rateController,
        textAlign: TextAlign.end,
        decoration: InputDecoration(hintText: l10n.expenseExchangeRate),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (_) => _m.rateTyped(),
        validator: (_) => _m.rate == null ? l10n.expenseInvalidRate : null,
      ),
    );
  }

  /// An amount the form works out rather than takes.
  Widget _workedOut(BuildContext context, String label, int? amount, String symbol, int digits) => KeyedSubtree(
        key: calculatedKey,
        child: GroupedRow(
          title: formLabel(context, label),
          trailing: amount == null
              ? Text('—', semanticsLabel: context.l10n.expenseAmountNotYetKnown, style: formValueStyle(context))
              : Money(formatMoney(amount, symbol, decimalDigits: digits, locale: context.appLocale)),
        ),
      );
}
