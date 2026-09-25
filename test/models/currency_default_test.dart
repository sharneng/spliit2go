import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/models/currency.dart';

// Issue #115: a new group starts in the phone region's currency when
// Spliit supports it, otherwise US dollars.
void main() {
  test('uses the region\'s currency', () {
    expect(defaultCurrencyFor(const Locale('en', 'US')).code, 'USD');
    expect(defaultCurrencyFor(const Locale('fr', 'FR')).code, 'EUR');
    expect(defaultCurrencyFor(const Locale('en', 'GB')).code, 'GBP');
    expect(defaultCurrencyFor(const Locale('zh', 'CN')).code, 'CNY');
    expect(defaultCurrencyFor(const Locale('fr', 'CA')).code, 'CAD');
  });

  test('the region decides, not the language', () {
    expect(defaultCurrencyFor(const Locale('en', 'JP')).code, 'JPY');
  });

  test('euro countries, including Bulgaria since 2026', () {
    expect(defaultCurrencyFor(const Locale('de', 'DE')).code, 'EUR');
    expect(defaultCurrencyFor(const Locale('bg', 'BG')).code, 'EUR');
    expect(defaultCurrencyFor(const Locale('de', 'LI')).code, 'CHF');
  });

  test('falls back to US dollars for an unsupported region', () {
    expect(defaultCurrencyFor(const Locale('ar', 'EG')).code, 'USD');
  });

  test('falls back to US dollars without a region', () {
    expect(defaultCurrencyFor(const Locale('fr')).code, 'USD');
  });
}
