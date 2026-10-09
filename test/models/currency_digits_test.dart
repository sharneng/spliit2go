import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/models/currency.dart';
import 'package:spliit2go/models/group.dart';

// #251: each currency's decimal places, from spliit-web's
// src/lib/currency-data.json (`decimal_digits`).
void main() {
  test('seven currencies have no decimals; the rest have two', () {
    const none = {'JPY', 'HUF', 'ISK', 'IDR', 'KRW', 'VND', 'COP'};
    for (final c in supportedCurrencies) {
      expect(c.decimalDigits, none.contains(c.code) ? 0 : 2, reason: c.code);
    }
  });

  test('a custom symbol or an unknown code has two, like spliit-web', () {
    expect(Currency.custom.decimalDigits, 2);
    expect(currencyByCode('XYZ').decimalDigits, 2);
  });

  test("a group uses its currency's", () {
    Group group(String? code) => Group(id: 'g', name: 'G', currency: '¥', currencyCode: code, participants: const []);
    expect(group('JPY').decimalDigits, 0);
    expect(group('EUR').decimalDigits, 2);
    expect(group(null).decimalDigits, 2);
    expect(group('').decimalDigits, 2);
  });
}
