import 'dart:ui' show Locale;

/// One of Spliit's supported currencies, or the "Custom" pseudo-entry
/// ([Currency.custom], empty [code]) a group can use instead of a real
/// ISO currency -- mirrors the web app's fixed `supportedCurrencyCodes`
/// list and `currency-data.json` (src/lib/currency.ts in
/// spliit-app/spliit), trimmed to the `en-US` names/symbols since this
/// app has no locale support of its own.
///
/// Deliberately *not* the full ISO-4217 list: the web app's own currency
/// widget only ever offers these 34 codes -- issue #23's currency widget
/// mirrors that rather than listing currencies Spliit itself doesn't
/// recognize.
class Currency {
  final String code;
  final String name;
  final String symbol;

  const Currency({required this.code, required this.name, required this.symbol});

  /// A group (or an expense's "paid in a different currency") that isn't
  /// one of the 34 known codes -- just a free-typed symbol, no exchange
  /// rate available. Matches a null/empty `currencyCode` from the server.
  static const custom = Currency(code: '', name: 'Custom', symbol: '');

  /// The web app's currency-selector.tsx hard-codes these 5 as the
  /// "Most common" bucket; everything else (other than [custom]) falls
  /// into "Other currencies".
  static const _commonCodes = {'USD', 'EUR', 'JPY', 'GBP', 'CNY'};
  bool get isCommon => _commonCodes.contains(code);

  /// A flag emoji built from this currency's first two letters (e.g.
  /// 'USD' -> US -> the US flag), the same heuristic the web app's
  /// currency-selector.tsx uses to pick a flag image (`code.slice(0,
  /// 2)` against flagcdn.com) -- computed locally instead of fetched, so
  /// the picker works offline like the rest of this app. Empty for
  /// [custom], which has no country to represent.
  String get flagEmoji {
    if (code.length < 2) return '';
    const base = 0x1F1E6; // Regional Indicator Symbol Letter A
    final a = code.codeUnitAt(0) - 'A'.codeUnitAt(0);
    final b = code.codeUnitAt(1) - 'A'.codeUnitAt(0);
    if (a < 0 || a > 25 || b < 0 || b > 25) return '';
    return String.fromCharCode(base + a) + String.fromCharCode(base + b);
  }

  @override
  String toString() => code.isEmpty ? name : '$name ($code)';
}

/// The 34 currencies Spliit supports, in the same order the web app
/// declares `supportedCurrencyCodes` (not alphabetical) -- names/symbols
/// are the `en-US` entries from currency-data.json.
const List<Currency> supportedCurrencies = [
  Currency(code: 'USD', name: 'US Dollar', symbol: '\$'),
  Currency(code: 'EUR', name: 'Euro', symbol: '€'),
  Currency(code: 'JPY', name: 'Japanese Yen', symbol: '¥'),
  Currency(code: 'BGN', name: 'Bulgarian Lev', symbol: 'BGN'),
  Currency(code: 'CZK', name: 'Czech Koruna', symbol: 'Kč'),
  Currency(code: 'DKK', name: 'Danish Krone', symbol: 'Dkr'),
  Currency(code: 'GBP', name: 'British Pound', symbol: '£'),
  Currency(code: 'HUF', name: 'Hungarian Forint', symbol: 'Ft'),
  Currency(code: 'PLN', name: 'Polish Zloty', symbol: 'zł'),
  Currency(code: 'RON', name: 'Romanian Leu', symbol: 'RON'),
  Currency(code: 'SEK', name: 'Swedish Krona', symbol: 'Skr'),
  Currency(code: 'CHF', name: 'Swiss Franc', symbol: 'CHF'),
  Currency(code: 'ISK', name: 'Icelandic Króna', symbol: 'Ikr'),
  Currency(code: 'NOK', name: 'Norwegian Krone', symbol: 'Nkr'),
  Currency(code: 'TRY', name: 'Turkish Lira', symbol: 'TL'),
  Currency(code: 'AUD', name: 'Australian Dollar', symbol: 'AU\$'),
  Currency(code: 'BRL', name: 'Brazilian Real', symbol: 'R\$'),
  Currency(code: 'CAD', name: 'Canadian Dollar', symbol: 'CA\$'),
  Currency(code: 'CNY', name: 'Chinese Yuan', symbol: 'CN¥'),
  Currency(code: 'HKD', name: 'Hong Kong Dollar', symbol: 'HK\$'),
  Currency(code: 'IDR', name: 'Indonesian Rupiah', symbol: 'Rp'),
  Currency(code: 'ILS', name: 'Israeli New Shekel', symbol: '₪'),
  Currency(code: 'INR', name: 'Indian Rupee', symbol: 'Rs'),
  Currency(code: 'KRW', name: 'South Korean Won', symbol: '₩'),
  Currency(code: 'MKD', name: 'Macedonian Denar', symbol: 'MKD'),
  Currency(code: 'MXN', name: 'Mexican Peso', symbol: 'MX\$'),
  Currency(code: 'MYR', name: 'Malaysian Ringgit', symbol: 'RM'),
  Currency(code: 'NZD', name: 'New Zealand Dollar', symbol: 'NZ\$'),
  Currency(code: 'PHP', name: 'Philippine Peso', symbol: '₱'),
  Currency(code: 'SGD', name: 'Singapore Dollar', symbol: 'S\$'),
  Currency(code: 'THB', name: 'Thai Baht', symbol: '฿'),
  Currency(code: 'VND', name: 'Vietnamese Dong', symbol: '₫'),
  Currency(code: 'ZAR', name: 'South African Rand', symbol: 'R'),
  Currency(code: 'COP', name: 'Colombian Peso', symbol: 'CO\$'),
];

/// Looks up a currency by its ISO code (case-sensitive, matching the
/// wire format). Falls back to [Currency.custom] for null, empty, or an
/// unrecognized code -- same fallback the web app's own `getCurrency()`
/// uses.
Currency currencyByCode(String? code) {
  if (code == null || code.isEmpty) return Currency.custom;
  for (final c in supportedCurrencies) {
    if (c.code == code) return c;
  }
  return Currency.custom;
}

/// The currency a new group starts in (issue #115): the one the phone's
/// region uses, like spliit-ios's `GroupFormDraft(newGroupIn:)`, when
/// Spliit supports it; otherwise US dollars, spliit-web's default.
///
/// Decided by the region alone, so English on a Japanese phone gets yen.
/// Every supported code but EUR starts with its country's ISO code (USD,
/// JPY, CHF, ...); the euro's countries are listed, including Bulgaria
/// (euro since 2026-01-01, so not BGN), and Liechtenstein uses francs.
Currency defaultCurrencyFor(Locale locale) {
  final region = locale.countryCode?.toUpperCase();
  if (region == null || region.isEmpty) return currencyByCode('USD');
  if (_euroRegions.contains(region)) return currencyByCode('EUR');
  if (region == 'LI') return currencyByCode('CHF');
  for (final c in supportedCurrencies) {
    if (c.code != 'EUR' && c.code.startsWith(region)) return c;
  }
  return currencyByCode('USD');
}

const _euroRegions = {
  'AT', 'BE', 'BG', 'CY', 'DE', 'EE', 'ES', 'FI', 'FR', 'GR', 'HR', 'IE',
  'IT', 'LT', 'LU', 'LV', 'MT', 'NL', 'PT', 'SI', 'SK',
  // Outside the EU.
  'AD', 'MC', 'SM', 'VA', 'ME', 'XK',
};
