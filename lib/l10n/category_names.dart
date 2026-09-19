import 'package:flutter/widgets.dart';

import '../models/category.dart';
import 'context_l10n.dart';

// Category-name translation (issue #51, item 3).
//
// Keyed by `Category.id` -- the stable int from Spliit's seed data
// (prisma migrations `20240108194443_add_categories` and
// `20250308000000_add_category_donation`) -- so it doesn't depend on the
// English `Category.name` string, which the server may return with slightly
// different spelling. Translations are sourced from spliit-web's own
// `messages/fr-FR.json` and `messages/zh-CN.json` (`Categories`
// namespace), so the app and the web client use the same wording, with two
// corrections in the Chinese list: spliit-web's zh-CN file renders
// "Electronics" (id 12) as 电费 (an electricity bill, which is what
// "Electricity" is already called) and "Groceries" (id 9) as 便利店
// (convenience store); this file uses 电子产品 and 杂货 instead.
//
// Translation happens ONLY at presentation/search time (see the helpers
// below). `Category.name` / `Category.grouping` on the model stay the
// server's English strings, because `category_icon.dart` looks its icon up
// by the literal English `'<grouping>/<name>'` -- translating the model
// fields in place would silently turn every category icon into the
// fallback banknote.
//
// A locale or an id with no entry here (a category the server added later,
// a self-hosted instance's custom category, a locale that ships without a
// category map) falls back to the server's English name -- never fails.

// ---------------------------------------------------------------------
// Data: language code -> category id -> translated name.
// ---------------------------------------------------------------------
const Map<String, Map<int, String>> _categoryNames = {
  'fr': {
    0: 'Général',  // Uncategorized/General
    1: 'Paiement',  // Uncategorized/Payment
    2: 'Divertissement',  // Entertainment/Entertainment
    3: 'Jeux',  // Entertainment/Games
    4: 'Films',  // Entertainment/Movies
    5: 'Musique',  // Entertainment/Music
    6: 'Sport',  // Entertainment/Sports
    7: 'Nourriture et boissons',  // Food and Drink/Food and Drink
    8: 'Repas au restaurant',  // Food and Drink/Dining Out
    9: 'Épicerie',  // Food and Drink/Groceries
    10: 'Alcool',  // Food and Drink/Liquor
    11: 'Maison',  // Home/Home
    12: 'Électronique',  // Home/Electronics
    13: 'Mobilier',  // Home/Furniture
    14: 'Fournitures ménagères',  // Home/Household Supplies
    15: 'Entretien',  // Home/Maintenance
    16: 'Hypothèque',  // Home/Mortgage
    17: 'Animaux',  // Home/Pets
    18: 'Loyer',  // Home/Rent
    19: 'Services',  // Home/Services
    20: 'Garde d\'enfants',  // Life/Childcare
    21: 'Vêtements',  // Life/Clothing
    22: 'Éducation',  // Life/Education
    23: 'Cadeaux',  // Life/Gifts
    24: 'Assurance',  // Life/Insurance
    25: 'Dépenses médicales',  // Life/Medical Expenses
    26: 'Impôts',  // Life/Taxes
    27: 'Transport',  // Transportation/Transportation
    28: 'Bicyclette',  // Transportation/Bicycle
    29: 'Bus/Train',  // Transportation/Bus/Train
    30: 'Voiture',  // Transportation/Car
    31: 'Essence/Carburant',  // Transportation/Gas/Fuel
    32: 'Hôtel',  // Transportation/Hotel
    33: 'Parking',  // Transportation/Parking
    34: 'Avion',  // Transportation/Plane
    35: 'Taxi',  // Transportation/Taxi
    36: 'Services publics',  // Utilities/Utilities
    37: 'Nettoyage',  // Utilities/Cleaning
    38: 'Électricité',  // Utilities/Electricity
    39: 'Chauffage/Gaz',  // Utilities/Heat/Gas
    40: 'Poubelle',  // Utilities/Trash
    41: 'TV/Téléphone/Internet',  // Utilities/TV/Phone/Internet
    42: 'Eau',  // Utilities/Water
    43: 'Don',  // Life/Donation
  },
  'zh': {
    0: '一般',  // Uncategorized/General
    1: '支付',  // Uncategorized/Payment
    2: '娱乐',  // Entertainment/Entertainment
    3: '游戏',  // Entertainment/Games
    4: '电影',  // Entertainment/Movies
    5: '音乐',  // Entertainment/Music
    6: '运动',  // Entertainment/Sports
    7: '饮食',  // Food and Drink/Food and Drink
    8: '下馆子',  // Food and Drink/Dining Out
    9: '杂货',  // Food and Drink/Groceries
    10: '酒水',  // Food and Drink/Liquor
    11: '居家',  // Home/Home
    12: '电子产品',  // Home/Electronics
    13: '家具',  // Home/Furniture
    14: '家庭日用品',  // Home/Household Supplies
    15: '维护',  // Home/Maintenance
    16: '贷款',  // Home/Mortgage
    17: '宠物',  // Home/Pets
    18: '租金',  // Home/Rent
    19: '服务',  // Home/Services
    20: '儿童保育',  // Life/Childcare
    21: '衣物',  // Life/Clothing
    22: '教育',  // Life/Education
    23: '礼物',  // Life/Gifts
    24: '保险',  // Life/Insurance
    25: '医疗支出',  // Life/Medical Expenses
    26: '税',  // Life/Taxes
    27: '交通',  // Transportation/Transportation
    28: '自行车',  // Transportation/Bicycle
    29: '巴士/列车',  // Transportation/Bus/Train
    30: '汽车',  // Transportation/Car
    31: '燃料',  // Transportation/Gas/Fuel
    32: '旅馆',  // Transportation/Hotel
    33: '停车',  // Transportation/Parking
    34: '飞机',  // Transportation/Plane
    35: '出租车',  // Transportation/Taxi
    36: '日常账单',  // Utilities/Utilities
    37: '清洁费',  // Utilities/Cleaning
    38: '电费',  // Utilities/Electricity
    39: '暖气/瓦斯',  // Utilities/Heat/Gas
    40: '垃圾',  // Utilities/Trash
    41: '电视/手机/互联网',  // Utilities/TV/Phone/Internet
    42: '水',  // Utilities/Water
    43: '捐赠',  // Life/Donation
  },
};

const Map<String, Map<String, String>> _groupingNames = {
  'fr': {
    'Uncategorized': 'Non classé',
    'Entertainment': 'Divertissement',
    'Food and Drink': 'Nourriture et boissons',
    'Home': 'Maison',
    'Life': 'Vie',
    'Transportation': 'Transport',
    'Utilities': 'Services publics',
    'Other': 'Autres',
  },
  'zh': {
    'Uncategorized': '未分类',
    'Entertainment': '娱乐',
    'Food and Drink': '饮食',
    'Home': '居家',
    'Life': '生活',
    'Transportation': '交通',
    'Utilities': '日常账单',
    'Other': '其他',
  },
};

// ---------------------------------------------------------------------
// Presentation helpers.
// ---------------------------------------------------------------------

/// [category]'s display name for [locale], or its English server name when
/// [locale]'s language has no translation for that id.
String categoryNameForLocale(Locale locale, Category category) =>
    _categoryNames[locale.languageCode]?[category.id] ?? category.name;

/// [grouping]'s (section heading) display name for [locale], or the English
/// grouping string itself when there's no translation.
String categoryGroupingForLocale(Locale locale, String grouping) =>
    _groupingNames[locale.languageCode]?[grouping] ?? grouping;

/// [categoryNameForLocale] for the app's resolved locale.
String localizedCategoryName(BuildContext context, Category category) =>
    categoryNameForLocale(Localizations.localeOf(context), category);

/// [categoryGroupingForLocale] for the app's resolved locale.
String localizedCategoryGrouping(BuildContext context, String grouping) =>
    categoryGroupingForLocale(Localizations.localeOf(context), grouping);

/// A label for category [id] when the full [Category] may not have been
/// fetched (offline, or a slow first load): [known]'s translated name if
/// it was, the translated "General" for the default id 0, and otherwise a
/// localized "Category {id}".
String localizedCategoryLabel(BuildContext context, int id, Category? known) {
  if (known != null) return localizedCategoryName(context, known);
  if (id == 0) {
    return localizedCategoryName(
        context,
        const Category(id: 0, name: 'General', grouping: 'Uncategorized'));
  }
  return context.l10n.categoryFallbackName(id);
}

/// Whether [category] matches the picker's search [query] (already trimmed
/// and lower-cased). Matches the translated name a French/Chinese user
/// would type, and the English server name too, so English search terms
/// keep working after switching language.
bool categoryMatchesQuery(Locale locale, Category category, String query) =>
    categoryNameForLocale(locale, category).toLowerCase().contains(query) ||
    category.name.toLowerCase().contains(query);
