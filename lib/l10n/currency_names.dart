import 'package:flutter/widgets.dart';

import '../models/currency.dart';
import 'context_l10n.dart';

// Currency-name translation (#278).
//
// Keyed by ISO code. The names are spliit-web's own, from
// `src/lib/currency-data.json` @ b73d551 (`fr-FR` and `zh-CN`), which its
// `generateCurrencyData.ts` builds from the `currency-list` package's CLDR
// data -- so a group's currency reads the same here as on spliit.app.
// `Currency.name` stays the English `en-US` name: it's what search falls
// back to, and a language with no map here shows it.
//
// CLDR's French names are lower case, as French writes them inside a
// sentence ("En euro"); standing alone, as a list row or a field's value,
// the first letter is raised ("Dollar des États-Unis").

// ---------------------------------------------------------------------
// Data: language code -> ISO code -> translated name.
// ---------------------------------------------------------------------
const Map<String, Map<String, String>> _currencyNames = {
  'fr': {
    'USD': 'dollar des États-Unis',
    'EUR': 'euro',
    'JPY': 'yen japonais',
    'BGN': 'lev bulgare',
    'CZK': 'couronne tchèque',
    'DKK': 'couronne danoise',
    'GBP': 'livre sterling',
    'HUF': 'forint hongrois',
    'PLN': 'zloty polonais',
    'RON': 'leu roumain',
    'SEK': 'couronne suédoise',
    'CHF': 'franc suisse',
    'ISK': 'couronne islandaise',
    'NOK': 'couronne norvégienne',
    'TRY': 'livre turque',
    'AUD': 'dollar australien',
    'BRL': 'réal brésilien',
    'CAD': 'dollar canadien',
    'CNY': 'yuan renminbi chinois',
    'HKD': 'dollar de Hong Kong',
    'IDR': 'roupie indonésienne',
    'ILS': 'nouveau shekel israélien',
    'INR': 'roupie indienne',
    'KRW': 'won sud-coréen',
    'MKD': 'denar macédonien',
    'MXN': 'peso mexicain',
    'MYR': 'ringgit malais',
    'NZD': 'dollar néo-zélandais',
    'PHP': 'peso philippin',
    'SGD': 'dollar de Singapour',
    'THB': 'baht thaïlandais',
    'VND': 'dông vietnamien',
    'ZAR': 'rand sud-africain',
    'COP': 'peso colombien',
  },
  'zh': {
    'USD': '美元',
    'EUR': '欧元',
    'JPY': '日元',
    'BGN': '保加利亚列弗',
    'CZK': '捷克克朗',
    'DKK': '丹麦克朗',
    'GBP': '英镑',
    'HUF': '匈牙利福林',
    'PLN': '波兰兹罗提',
    'RON': '罗马尼亚列伊',
    'SEK': '瑞典克朗',
    'CHF': '瑞士法郎',
    'ISK': '冰岛克朗',
    'NOK': '挪威克朗',
    'TRY': '土耳其里拉',
    'AUD': '澳大利亚元',
    'BRL': '巴西雷亚尔',
    'CAD': '加拿大元',
    'CNY': '人民币',
    'HKD': '港元',
    'IDR': '印度尼西亚盾',
    'ILS': '以色列新谢克尔',
    'INR': '印度卢比',
    'KRW': '韩元',
    'MKD': '马其顿第纳尔',
    'MXN': '墨西哥比索',
    'MYR': '马来西亚林吉特',
    'NZD': '新西兰元',
    'PHP': '菲律宾比索',
    'SGD': '新加坡元',
    'THB': '泰铢',
    'VND': '越南盾',
    'ZAR': '南非兰特',
    'COP': '哥伦比亚比索',
  },
};

// ---------------------------------------------------------------------
// Presentation helpers.
// ---------------------------------------------------------------------

/// [currency]'s name for [locale]: the translation, or its English name.
/// [Currency.custom] has no name here; see [localizedCurrencyName].
/// [inSentence] keeps a French name lower case, for the middle of a
/// sentence.
String currencyNameForLocale(Locale locale, Currency currency, {bool inSentence = false}) {
  final name = _currencyNames[locale.languageCode]?[currency.code];
  if (name == null) return currency.name;
  return inSentence || name.isEmpty ? name : name[0].toUpperCase() + name.substring(1);
}

/// [currency]'s name in the app's language, or "Custom" translated for
/// [Currency.custom].
String localizedCurrencyName(BuildContext context, Currency currency, {bool inSentence = false}) =>
    currency.code.isEmpty
        ? context.l10n.currencyCustom
        : currencyNameForLocale(Localizations.localeOf(context), currency, inSentence: inSentence);

/// [localizedCurrencyName] with the code after it, e.g. "人民币 (CNY)", as
/// the picker's rows and the group's currency field show it.
String localizedCurrencyLabel(BuildContext context, Currency currency) {
  final name = localizedCurrencyName(context, currency);
  return currency.code.isEmpty ? name : '$name (${currency.code})';
}

/// Whether [currency] matches the picker's search [query] (already
/// lower-cased): its translated name, its English name too (so English
/// search terms keep working after switching language), its code or its
/// symbol.
bool currencyMatchesQuery(Locale locale, Currency currency, String query) =>
    currencyNameForLocale(locale, currency).toLowerCase().contains(query) ||
    currency.name.toLowerCase().contains(query) ||
    currency.code.toLowerCase().contains(query) ||
    currency.symbol.toLowerCase().contains(query);
