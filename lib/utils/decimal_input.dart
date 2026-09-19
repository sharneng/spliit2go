/// Parses a user-typed decimal amount (an expense amount, or a
/// shares/percentage/split-amount field), accepting either `,` or `.`
/// as the decimal separator regardless of the device's locale (issue
/// #37 phase 1).
///
/// These are narrow numeric-entry fields -- nobody hand-types a
/// thousands separator into an amount or split box -- so there's no
/// real ambiguity between "," as a decimal separator (most European
/// locales) and "," as a thousands separator to resolve: this is
/// deliberately *not* a full `NumberFormat(locale).parse()`, which
/// would need threading `Locale.of(context)` into validator functions
/// that don't take a `BuildContext` today (some run entirely outside
/// build methods). See spliit2go#37's comment thread for the full
/// reasoning -- a French or German user typing "12,50" previously hit
/// `double.tryParse("12,50") == null`, silently blocking expense
/// creation/editing with a spurious "Enter a valid amount".
///
/// Returns null for anything that still isn't a valid number once the
/// separator is normalized (same contract as [double.tryParse]).
double? parseFlexibleDecimal(String input) {
  return double.tryParse(input.trim().replaceAll(',', '.'));
}
