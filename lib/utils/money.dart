/// Formats [cents] (always integer cents) with [currencySymbol], e.g.
/// `formatMoney(1250, '\$')` == `'\$12.50'`, `formatMoney(-1250, '€')` ==
/// `'-€12.50'`.
///
/// The single shared money-formatting helper for the app (issue #50) --
/// replaces the scattered hand-rolled `'\$${(cents / 100)...}'`
/// concatenations that used to live in group_screen.dart,
/// balances_screen.dart, stats_screen.dart and expense_screen.dart, every
/// one of which hardcoded the `$` symbol regardless of the group's actual
/// currency. Every call site should go through this instead of building
/// its own string, both for the currency-symbol fix and so the sign
/// (below) and rounding behavior stay identical everywhere.
///
/// [cents] must already be integer cents -- a caller holding a
/// dollar-amount double (e.g. from a byAmount split's unallocated
/// remainder) converts first: `formatMoney((dollars * 100).round(),
/// symbol)`.
///
/// No `absolute` flag: every real caller in the app either wants the true
/// signed value (a net balance, where negative means "you owe") or is
/// already guaranteed non-negative before it gets here (settlement
/// amounts, an already-.abs()'d unallocated magnitude) -- there's no
/// caller that actually needs to silently discard a sign, and dropping
/// the flag removes that misuse from the API surface entirely rather than
/// leaving it available to be passed by accident.
String formatMoney(int cents, String currencySymbol) {
  final sign = cents < 0 ? '-' : '';
  final magnitude = cents.abs();
  return '$sign$currencySymbol${(magnitude / 100).toStringAsFixed(2)}';
}
