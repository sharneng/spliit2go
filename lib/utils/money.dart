import 'package:flutter/widgets.dart' show Locale;
import 'package:intl/intl.dart';

/// Formats [cents] (always integer cents) with [currencySymbol] for
/// [locale], e.g. `formatMoney(1250, '\$', locale: en)` == `'\$12.50'`,
/// `formatMoney(-1250, '€', locale: fr)` == `'-12,50 €'`.
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
/// [cents] must already be integer cents -- a caller holding a
/// dollar-amount double (e.g. from a byAmount split's unallocated
/// remainder) converts first: `formatMoney((dollars * 100).round(),
/// symbol, locale: locale)`.
///
/// No `absolute` flag: every real caller in the app either wants the true
/// signed value (a net balance, where negative means "you owe") or is
/// already guaranteed non-negative before it gets here (settlement
/// amounts, an already-.abs()'d unallocated magnitude) -- there's no
/// caller that actually needs to silently discard a sign, and dropping
/// the flag removes that misuse from the API surface entirely rather than
/// leaving it available to be passed by accident.
String formatMoney(int cents, String currencySymbol, {required Locale locale}) {
  final format = NumberFormat.currency(
    locale: locale.toString(),
    symbol: currencySymbol,
    decimalDigits: 2,
  );
  return format.format(cents / 100);
}
