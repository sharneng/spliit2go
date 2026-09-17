import 'package:flutter/material.dart';

import '../models/currency.dart';

/// Opens Spliit's currency picker as a searchable modal bottom sheet --
/// shared between the group settings screen's "Main currency" field and
/// the expense screen's "paid in a different currency" field (issue
/// #23), the way the web app shares one `<CurrencySelector>` between its
/// own group-form.tsx and expense-form.tsx.
///
/// [currencies] is the full choice list. Pass
/// `[Currency.custom, ...supportedCurrencies]` to offer "Custom" (only
/// meaningful for a group's own main currency -- see
/// group_settings_screen.dart) or just `supportedCurrencies` to omit it,
/// which is what the expense screen's original-currency field does: a
/// foreign-currency expense needs a real ISO code to convert against, so
/// there's nothing a "Custom" entry could mean there (mirrors
/// `defaultCurrencyList(locale, '')` in the web app's expense-form.tsx,
/// where the empty customChoice means "no Custom option").
///
/// Returns the picked [Currency], or null if the sheet was dismissed
/// without a selection.
Future<Currency?> pickCurrency(
  BuildContext context, {
  required List<Currency> currencies,
  String? selectedCode,
}) {
  return showModalBottomSheet<Currency>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _CurrencyPicker(currencies: currencies, selectedCode: selectedCode),
  );
}

class _CurrencyPicker extends StatefulWidget {
  final List<Currency> currencies;
  final String? selectedCode;

  const _CurrencyPicker({required this.currencies, required this.selectedCode});

  @override
  State<_CurrencyPicker> createState() => _CurrencyPickerState();
}

class _CurrencyPickerState extends State<_CurrencyPicker> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _matches(Currency c) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return c.name.toLowerCase().contains(q) ||
        c.code.toLowerCase().contains(q) ||
        c.symbol.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    // Custom is pinned above any section header (matches the screenshot
    // on issue #23); "Most common" is the web app's hard-coded
    // USD/EUR/JPY/GBP/CNY; everything else is "Other currencies", kept
    // in [supportedCurrencies]' declared order rather than resorted
    // alphabetically, same as the web app.
    final custom = widget.currencies.where((c) => c.code.isEmpty && _matches(c)).toList();
    final common = widget.currencies.where((c) => c.isCommon && _matches(c)).toList();
    final other =
        widget.currencies.where((c) => c.code.isNotEmpty && !c.isCommon && _matches(c)).toList();
    final empty = custom.isEmpty && common.isEmpty && other.isEmpty;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search currency...',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              Expanded(
                child: empty
                    ? const Center(child: Text('No currency found'))
                    : ListView(
                        children: [
                          for (final c in custom) _tile(context, c),
                          if (common.isNotEmpty) _header(context, 'Most common'),
                          for (final c in common) _tile(context, c),
                          if (other.isNotEmpty) _header(context, 'Other currencies'),
                          for (final c in other) _tile(context, c),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );

  Widget _tile(BuildContext context, Currency c) => ListTile(
        leading: SizedBox(
          width: 28,
          child: Text(
            c.code.isEmpty ? '＋' : c.flagEmoji,
            style: const TextStyle(fontSize: 20),
            textAlign: TextAlign.center,
          ),
        ),
        title: Text(c.code.isEmpty ? c.name : '${c.name} (${c.code})'),
        selected: c.code == (widget.selectedCode ?? ''),
        onTap: () => Navigator.of(context).pop(c),
      );
}
