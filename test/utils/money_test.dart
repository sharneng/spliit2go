import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/utils/money.dart';

void main() {
  const en = Locale('en');
  const fr = Locale('fr');
  const zh = Locale('zh', 'CN');

  // fr's currency pattern and digit grouping use no-break / narrow
  // no-break spaces; compare with those folded to a plain space so the
  // assertions read as what a person sees.
  String plain(String s) => s.replaceAll(RegExp('[  ]'), ' ');

  group('formatMoney (en)', () {
    test('formats a positive amount with the given currency symbol', () {
      expect(formatMoney(1250, '\$', locale: en), '\$12.50');
    });

    test('uses whatever symbol is passed, not just \$', () {
      expect(formatMoney(1250, '€', locale: en), '€12.50');
      expect(formatMoney(1250, '£', locale: en), '£12.50');
    });

    test('puts a single leading minus before the symbol for a negative amount', () {
      expect(formatMoney(-1250, '\$', locale: en), '-\$12.50');
      expect(formatMoney(-1250, '€', locale: en), '-€12.50');
    });

    test('formats zero without a sign', () {
      expect(formatMoney(0, '\$', locale: en), '\$0.00');
    });

    test('always shows two decimal places, even for a whole-dollar amount', () {
      expect(formatMoney(500, '\$', locale: en), '\$5.00');
    });

    test('handles amounts under a dollar', () {
      expect(formatMoney(9, '\$', locale: en), '\$0.09');
      expect(formatMoney(-9, '\$', locale: en), '-\$0.09');
    });

    test('groups thousands', () {
      expect(formatMoney(123456, '\$', locale: en), '\$1,234.56');
    });

    test('keeps a multi-character custom symbol literally', () {
      expect(formatMoney(1250, 'CA\$', locale: en), 'CA\$12.50');
    });
  });

  group('formatMoney (fr, comma decimal, symbol after the number)', () {
    test('places the symbol after the digits with a comma decimal', () {
      expect(plain(formatMoney(1250, '€', locale: fr)), '12,50 €');
    });

    test('negative amounts keep the sign before the digits', () {
      expect(plain(formatMoney(-1250, '€', locale: fr)), '-12,50 €');
    });

    test('groups thousands with a space', () {
      expect(plain(formatMoney(123456, '€', locale: fr)), '1 234,56 €');
    });

    test('a custom symbol is kept as typed, not derived from a currency code',
        () {
      expect(plain(formatMoney(1250, 'CA\$', locale: fr)), '12,50 CA\$');
      expect(plain(formatMoney(1250, 'pts', locale: fr)), '12,50 pts');
    });

    test('zero and sub-unit amounts', () {
      expect(plain(formatMoney(0, '€', locale: fr)), '0,00 €');
      expect(plain(formatMoney(9, '€', locale: fr)), '0,09 €');
    });
  });

  group('formatMoney (zh_CN)', () {
    test('symbol before the digits, dot decimal', () {
      expect(formatMoney(1250, '¥', locale: zh), '¥12.50');
    });

    test('negative amounts and custom symbols', () {
      expect(formatMoney(-1250, '¥', locale: zh), '-¥12.50');
      expect(formatMoney(123456, 'CA\$', locale: zh), 'CA\$1,234.56');
    });
  });
}
