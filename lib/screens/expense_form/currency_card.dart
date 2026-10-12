import 'package:flutter/material.dart';

import '../../widgets/flag_glyph.dart';
import '../../l10n/context_l10n.dart';
import '../../l10n/currency_names.dart';
import '../../models/currency.dart';
import '../../utils/date_format.dart';
import '../../widgets/grouped_section.dart';
import 'expense_form_model.dart';
import 'form_text.dart';
import 'inline_number_field.dart';
import 'rate_lookup.dart';
import '../../widgets/text_scaled.dart';

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
    required this.rates,
    required this.onPickPaidIn,
    this.amountHint,
    this.calculatedKey,
    this.showErrors = false,
  });

  final ExpenseFormModel model;

  /// The published rate, and the pair's order (#261).
  final RateLookup rates;

  final VoidCallback onPickPaidIn;

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
    final secondary = GroupedSection.footnoteStyle(context);
    final rateStatus = converting ? _rateStatus(context) : null;
    final footer = [
      if (amountHint case final hint?) Text(hint, style: secondary),
      // A settlement's says so on its To card.
      if (_m.convertedAmountInvalid && !_m.isSettlement)
        Text(l10n.expenseConvertedAmountInvalid,
            style: GroupedSection.footnoteStyle(context, color: theme.colorScheme.error)),
      if (rateStatus != null) Text(rateStatus, style: secondary),
    ];
    // A settlement in a group without a currency code has nothing here.
    if (_m.isSettlement && !_m.hasGroupCurrencyCode) return const SizedBox.shrink();
    final card = GroupedSection(
      margin: EdgeInsets.zero,
      footerContent: footer,
      children: [
        // Only an ISO code converts.
        if (_m.hasGroupCurrencyCode)
          GroupedRow(
            title: formLabel(context, l10n.expensePaidIn),
            // Its flag before it, as Category's icon (Kenneth); no chevron:
            // it opens a sheet, not a screen.
            value: Row(mainAxisSize: MainAxisSize.min, children: [
              if (_m.paidInCurrency.flagEmoji case final flag when flag.isNotEmpty) ...[
                FlagGlyph(flag),
                const SizedBox(width: 8),
              ],
              Flexible(child: Text(localizedCurrencyName(context, _m.paidInCurrency), style: formValueStyle(context))),
            ]),
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
            workedOutRow(context, l10n.expenseInCurrency(
                localizedCurrencyName(context, currencyByCode(_m.group.currencyCode), inSentence: true)),
                _m.amount, _m.group.currency, _m.digits, key: calculatedKey),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(GroupedSection.inset, 0, GroupedSection.inset, GroupedSection.spacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          card,
          // A link under the note, its text in line with the note's, and
          // only a line's height (Kenneth, 2026-10-10): a button's own
          // padding and 48pt pushed it in and the next card down. Its
          // target is 48pt all the same (#263), reaching up over the note
          // and down into the space under the card.
          if (converting && rates.canRefresh)
            Overhang(
              reach: _linkReach,
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 8),
                  child: TextButton(
                    onPressed: () => rates.lookUp(force: true),
                    style: compactTextButtonStyle(reach: _linkReach),
                    child: Text(l10n.expenseUsePublishedRate),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// A compact button's 24pt line, and this above and below: 48.
  static const _linkReach = 12.0;

  /// Where the rate in the field comes from, under it.
  String _rateStatus(BuildContext context) {
    final l10n = context.l10n;
    final own = _m.rateField.isSaved ? l10n.expenseRateSaved : l10n.expenseRateTyped;
    final found = rates.found;
    return switch (rates.state) {
      RateLookupState.found when found != null => () {
          final day = formatDate(found.publishedOn, locale: context.appLocale);
          final published = found.offline
              ? l10n.expenseRatePublishedOffline(_m.rateField.pair, _m.rateField.shownText(found.rate), day)
              : l10n.expenseRatePublished(_m.rateField.pair, _m.rateField.shownText(found.rate), day);
          // The footer is for reference (#261): it says when the field is
          // another rate, first (Kenneth, 2026-10-10).
          return _m.rateField.isOwn && !_m.rateField.shows(found.rate) ? '$own $published' : published;
        }(),
      _ when _m.rateField.isOwn => own,
      RateLookupState.noRate => l10n.expenseRateNone,
      RateLookupState.unavailable => l10n.expenseRateUnavailable,
      _ => l10n.expenseRateLoading,
    };
  }

  /// The amount, its currency symbol right before the digits (Kenneth,
  /// 2026-10-10): always there, rather than Material's prefix, which
  /// shows only once the field has the focus, and at its start edge, far
  /// from the right-aligned digits.
  Widget _amountRow(BuildContext context, TextEditingController controller, String symbol, int digits) {
    final l10n = context.l10n;
    // The row is the form's field (a refused save scrolls to it), and
    // says what's wrong under it, rather than under the text field, which
    // is only as wide as its digits.
    return FormField<void>(
      validator: (_) => _m.isPositiveAmount(controller.text, digits) ? null : l10n.expenseInvalidAmount,
      builder: (_) => ListenableBuilder(
        listenable: controller,
        // What's wrong is read with the field (#263).
        builder: (context, _) => MergeSemantics(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InlineNumberField(
            fieldKey: amountFieldKey,
            controller: controller,
            name: l10n.expenseAmountLabel,
            label: formLabel(context, l10n.expenseAmountLabel),
            prefix: '$symbol ',
          ),
          if (showErrors && !_m.isPositiveAmount(controller.text, digits))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(l10n.expenseInvalidAmount,
                  style: GroupedSection.footnoteStyle(context, color: Theme.of(context).colorScheme.error)),
            ),
        ])),
      ),
    );
  }

  /// The rate as one number: the pair, which swaps on a tap, and the field.
  Widget _rateRow(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    return formFieldRow(
      context,
      Tooltip(
        message: l10n.expenseSwapRate,
        child: InkWell(
          onTap: rates.swap,
          borderRadius: BorderRadius.circular(8),
          // The row's full height (#263).
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(_m.rateField.pair, style: TextStyle(color: colors.primary)),
              const SizedBox(width: 4),
              Icon(Icons.swap_horiz, size: context.textScaled(18), color: colors.primary),
            ]),
          ),
        ),
      ),
      _RateField(model: _m, fieldKey: rateFieldKey),
    );
  }

}

/// The rate's field, which owns its focus for [RetypeAssist].
class _RateField extends StatefulWidget {
  const _RateField({required this.model, required this.fieldKey});

  final ExpenseFormModel model;
  final Key fieldKey;

  @override
  State<_RateField> createState() => _RateFieldState();
}

class _RateFieldState extends State<_RateField> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final rate = widget.model.rateField;
    return RetypeAssist(
      focus: _focus,
      controller: rate.controller,
      onCleared: rate.typed,
      child: namedField(
        l10n.expenseFieldName(l10n.expenseExchangeRate, rate.pair),
        TextFormField(
          key: widget.fieldKey,
          controller: rate.controller,
          focusNode: _focus,
          textAlign: TextAlign.end,
          decoration: InputDecoration(hint: unreadHint(context, l10n.expenseExchangeRate)),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => rate.typed(),
          validator: (_) => widget.model.rate == null ? l10n.expenseInvalidRate : null,
        ),
      ),
    );
  }
}
