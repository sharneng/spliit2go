import 'package:flutter/widgets.dart' show Locale;
import 'package:intl/intl.dart';

/// Formats [amount] -- in the currency's smallest unit, 10^[decimalDigits]
/// to one -- with [currencySymbol] for [locale], e.g.
/// `formatMoney(1250, '\$', decimalDigits: 2, locale: en)` == `'\$12.50'`,
/// `formatMoney(-1250, '€', decimalDigits: 2, locale: fr)` == `'-12,50 €'`,
/// `formatMoney(1000, '¥', decimalDigits: 0, locale: en)` == `'¥1,000'`.
///
/// The single shared money-formatting helper for the app (issue #50) --
/// replaces the scattered hand-rolled `'\$${(cents / 100)...}'`
/// concatenations that used to live in group_screen.dart,
/// balances_screen.dart, stats_screen.dart and expense_screen.dart, every
/// one of which hardcoded the `$` symbol regardless of the group's actual
/// currency. Every call site should go through this instead of building
/// its own string, so the sign, rounding and locale behavior stay
/// identical everywhere.
///
/// Locale-aware since issue #51: [NumberFormat.currency] supplies the
/// locale's digit grouping, decimal separator, and where the symbol goes
/// and how it's spaced (`\$12.50` in en-US, `12,50 €` in fr, `¥12.50` in
/// zh). It's handed [currencySymbol] as `symbol:` -- never `name:`, the
/// ISO-code parameter -- so the symbol shown is still exactly the literal
/// `Group.currency` the group's owner typed, never one `NumberFormat`
/// derived from a currency code (issue #37's decision). Only the
/// placement and separators come from the locale.
///
/// [locale] is deliberately required, with no default: the caller must
/// pass the *resolved app locale* -- `Localizations.localeOf(context)` --
/// which can differ from the device locale once the user has picked a
/// language override. A call site that's forgotten is then a compile
/// error, rather than a silently stale-locale display after a live
/// language switch.
///
/// [decimalDigits] is required for the same reason (#251): Spliit stores
/// each currency in its own smallest unit, so yen have none and `amount`
/// means nothing without it. Pass `Group.decimalDigits`, or
/// `Currency.decimalDigits` for an expense's original currency. A caller
/// holding a decimal amount converts first with [toMinorUnits].
///
/// No `absolute` flag: every real caller in the app either wants the true
/// signed value (a net balance, where negative means "you owe") or is
/// already guaranteed non-negative before it gets here (settlement
/// amounts, an already-.abs()'d unallocated magnitude) -- there's no
/// caller that actually needs to silently discard a sign, and dropping
/// the flag removes that misuse from the API surface entirely rather than
/// leaving it available to be passed by accident.
String formatMoney(int amount, String currencySymbol,
    {required int decimalDigits, required Locale locale}) {
  final format = NumberFormat.currency(
    locale: locale.toString(),
    symbol: currencySymbol,
    decimalDigits: decimalDigits,
  );
  return format.format(fromMinorUnits(amount, decimalDigits));
}

/// A decimal [amount] (as typed) in the currency's smallest unit, rounded
/// -- spliit-web's `amountAsMinorUnits`: 12.5 with 2 digits is 1250, 1000
/// with 0 is 1000.
int toMinorUnits(double amount, int decimalDigits) =>
    (amount * _unitsPerMajor(decimalDigits)).round();

/// [amount] in minor units as a decimal -- spliit-web's `amountAsDecimal`.
double fromMinorUnits(int amount, int decimalDigits) =>
    amount / _unitsPerMajor(decimalDigits);

/// [amount] in minor units as text for an amount field: '12.50', or
/// '1000' for yen -- spliit-web's `formatAmountAsDecimal`.
String minorUnitsText(int amount, int decimalDigits) =>
    fromMinorUnits(amount, decimalDigits).toStringAsFixed(decimalDigits);

/// The rate from an expense's paid-in currency to its group's, from the
/// two stored amounts: groupAmount = originalAmount × rate, in major units
/// (Spliit's convention, src/lib/currency-conversion.ts upstream). So
/// `amount == round(originalAmount × rate × 10^decimalDigits /
/// 10^originalDecimalDigits)` -- ¥1,000 paid as €6.10 is 0.0061, not 0.61.
double conversionRateFor({
  required int amount,
  required int decimalDigits,
  required int originalAmount,
  required int originalDecimalDigits,
}) =>
    fromMinorUnits(amount, decimalDigits) / fromMinorUnits(originalAmount, originalDecimalDigits);

int _unitsPerMajor(int decimalDigits) {
  var units = 1;
  for (var i = 0; i < decimalDigits; i++) {
    units *= 10;
  }
  return units;
}
