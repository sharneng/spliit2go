import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/l10n/currency_names.dart';
import 'package:spliit2go/models/currency.dart';
import 'package:spliit2go/widgets/currency_picker.dart';

// #278: currency names follow the app's language.
void main() {
  const zh = Locale('zh');
  const fr = Locale('fr');
  final cny = currencyByCode('CNY');
  final usd = currencyByCode('USD');

  test('every supported currency has a French and a Chinese name', () {
    for (final c in supportedCurrencies) {
      expect(currencyNameForLocale(zh, c), isNot(c.name), reason: c.code);
      // In a sentence, as "Euro" capitalised is the English name.
      expect(currencyNameForLocale(fr, c, inSentence: true), isNot(c.name), reason: c.code);
    }
  });

  test('Chinese Yuan is 人民币 in Chinese, and English stays as it was', () {
    expect(currencyNameForLocale(zh, cny), '人民币');
    expect(currencyNameForLocale(const Locale('en'), cny), 'Chinese Yuan');
  });

  test('French: capitalised on its own, lower case inside a sentence', () {
    expect(currencyNameForLocale(fr, usd), 'Dollar des États-Unis');
    expect(currencyNameForLocale(fr, usd, inSentence: true), 'dollar des États-Unis');
  });

  test('a language without names falls back to English', () {
    expect(currencyNameForLocale(const Locale('de'), cny), 'Chinese Yuan');
  });

  Future<void> openPicker(WidgetTester tester, Locale locale) async {
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => pickCurrency(context, currencies: [Currency.custom, ...supportedCurrencies]),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pumpAndSettle();
  }

  testWidgets('search matches the translated name, the English one, the code and the symbol', (tester) async {
    await openPicker(tester, zh);
    for (final q in ['人民', 'Yuan', 'cny', 'CN¥']) {
      await search(tester, q);
      expect(find.text('人民币 (CNY)'), findsOneWidget, reason: q);
    }
    await search(tester, '美元');
    expect(find.text('人民币 (CNY)'), findsNothing);
  });

  // One test per language, so each opens its own picker (#287 review).
  for (final (locale, query, name) in [(zh, '自定', '自定义'), (fr, 'personnalis', 'Personnalisée')]) {
    testWidgets('$locale: Custom is found by its translated name, and by "custom" (#287 review)', (tester) async {
      await openPicker(tester, locale);
      for (final q in [query, 'custom']) {
        await search(tester, q);
        expect(find.text(name), findsOneWidget, reason: q);
      }
    });
  }

  testWidgets('the picker lists currencies in the app\'s language, Custom too', (tester) async {
    await openPicker(tester, zh);
    expect(find.text('自定义'), findsOneWidget);
    expect(find.text('人民币 (CNY)'), findsOneWidget);
  });
}
