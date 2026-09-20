import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/l10n/category_names.dart';
import 'package:spliit2go/models/category.dart';

import '../fixtures/category_seed_ids.dart';

void main() {
  const fr = Locale('fr');
  const zh = Locale('zh');
  const en = Locale('en');

  const groceries = Category(id: 9, name: 'Groceries', grouping: 'Food and Drink');
  const electronics = Category(id: 12, name: 'Electronics', grouping: 'Home');
  const donation = Category(id: 43, name: 'Donation', grouping: 'Life');

  group('categoryNameForLocale', () {
    test('translates by id', () {
      expect(categoryNameForLocale(fr, groceries), 'Épicerie');
      expect(categoryNameForLocale(zh, groceries), '杂货');
      expect(categoryNameForLocale(fr, donation), 'Don');
      expect(categoryNameForLocale(zh, donation), '捐赠');
    });

    test('corrects the two spliit-web zh-CN mistranslations', () {
      expect(categoryNameForLocale(zh, electronics), '电子产品');
      expect(categoryNameForLocale(zh, groceries), isNot('便利店'));
    });

    test('English returns the server name unchanged', () {
      expect(categoryNameForLocale(en, groceries), 'Groceries');
    });

    test('a locale with no category map falls back to the English name', () {
      expect(categoryNameForLocale(const Locale('de'), groceries), 'Groceries');
    });

    test('an id missing from the map falls back to the English name', () {
      const custom = Category(id: 999, name: 'Coffee runs', grouping: 'Food and Drink');
      expect(categoryNameForLocale(fr, custom), 'Coffee runs');
      expect(categoryNameForLocale(zh, custom), 'Coffee runs');
    });

    test('translating never mutates the model (icon lookup keys on it)', () {
      categoryNameForLocale(fr, groceries);
      expect(groceries.name, 'Groceries');
      expect(groceries.grouping, 'Food and Drink');
    });

    test('every seed id has a name in every shipped non-English locale', () {
      expect(categorySeedIds, isNotEmpty);
      expect(categorySeedIds.toSet(), hasLength(categorySeedIds.length));
      for (final locale in AppLocalizations.supportedLocales) {
        if (locale.languageCode == 'en') continue;
        for (final id in categorySeedIds) {
          // A sentinel distinguishes an actual map entry from the English
          // fallback, even when a translation matches the real English name.
          final fallback = '__untranslated_$id';
          final category = Category(id: id, name: fallback, grouping: 'G');
          final translated = categoryNameForLocale(locale, category);
          expect(translated, isNot(fallback), reason: '$locale id $id');
          expect(translated.trim(), isNotEmpty, reason: '$locale id $id');
        }
      }
    });
  });

  group('categoryGroupingForLocale', () {
    test('translates known groupings, including the Other fallback', () {
      expect(categoryGroupingForLocale(fr, 'Food and Drink'), 'Nourriture et boissons');
      expect(categoryGroupingForLocale(zh, 'Transportation'), '交通');
      expect(categoryGroupingForLocale(fr, 'Other'), 'Autres');
    });

    test('unknown groupings and English pass through', () {
      expect(categoryGroupingForLocale(fr, 'Something New'), 'Something New');
      expect(categoryGroupingForLocale(en, 'Home'), 'Home');
    });
  });

  group('categoryMatchesQuery', () {
    test('matches the translated name', () {
      expect(categoryMatchesQuery(fr, groceries, 'épic'), isTrue);
      expect(categoryMatchesQuery(zh, groceries, '杂货'), isTrue);
    });

    test('still matches the English name in another language', () {
      expect(categoryMatchesQuery(fr, groceries, 'grocer'), isTrue);
    });

    test('does not match an unrelated query', () {
      expect(categoryMatchesQuery(fr, groceries, 'essence'), isFalse);
    });
  });

  group('localizedCategoryLabel', () {
    Future<String> labelFor(
        WidgetTester tester, Locale locale, int id, Category? known) async {
      late String label;
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(builder: (context) {
          label = localizedCategoryLabel(context, id, known);
          return const SizedBox.shrink();
        }),
      ));
      await tester.pumpAndSettle();
      return label;
    }

    testWidgets('a fetched category is translated', (tester) async {
      expect(await labelFor(tester, fr, 9, groceries), 'Épicerie');
    });

    testWidgets('unfetched id 0 is the localized General', (tester) async {
      expect(await labelFor(tester, en, 0, null), 'General');
      expect(await labelFor(tester, fr, 0, null), 'Général');
      expect(await labelFor(tester, zh, 0, null), '一般');
    });

    testWidgets('an unfetched other id is a localized "Category N"',
        (tester) async {
      expect(await labelFor(tester, en, 9, null), 'Category 9');
      expect(await labelFor(tester, fr, 9, null), 'Catégorie 9');
      expect(await labelFor(tester, zh, 9, null), '类别 9');
    });
  });
}
