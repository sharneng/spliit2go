import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/utils/money.dart';

void main() {
  const en = Locale('en');
  const fr = Locale('fr');
  const zh = Locale('zh');

  // fr's currency pattern and digit grouping use no-break / narrow
  // no-break spaces; compare with those folded to a plain space so the
  // assertions read as what a person sees.
  String plain(String s) => s.replaceAll(RegExp('[  ]'), ' ');

  group('formatMoney (en)', () {
    test('formats a positive amount with the given currency symbol', () {
      expect(formatMoney(1250, '\$', decimalDigits: 2, locale: en), '\$12.50');
    });

    test('uses whatever symbol is passed, not just \$', () {
      expect(formatMoney(1250, '€', decimalDigits: 2, locale: en), '€12.50');
      expect(formatMoney(1250, '£', decimalDigits: 2, locale: en), '£12.50');
    });

    test('puts a single leading minus before the symbol for a negative amount', () {
      expect(formatMoney(-1250, '\$', decimalDigits: 2, locale: en), '-\$12.50');
      expect(formatMoney(-1250, '€', decimalDigits: 2, locale: en), '-€12.50');
    });

    test('formats zero without a sign', () {
      expect(formatMoney(0, '\$', decimalDigits: 2, locale: en), '\$0.00');
    });

    test('always shows two decimal places, even for a whole-dollar amount', () {
      expect(formatMoney(500, '\$', decimalDigits: 2, locale: en), '\$5.00');
    });

    test('handles amounts under a dollar', () {
      expect(formatMoney(9, '\$', decimalDigits: 2, locale: en), '\$0.09');
      expect(formatMoney(-9, '\$', decimalDigits: 2, locale: en), '-\$0.09');
    });

    test('groups thousands', () {
      expect(formatMoney(123456, '\$', decimalDigits: 2, locale: en), '\$1,234.56');
    });

    test('keeps a multi-character custom symbol literally', () {
      expect(formatMoney(1250, 'CA\$', decimalDigits: 2, locale: en), 'CA\$12.50');
    });
  });

  group('formatMoney (fr, comma decimal, symbol after the number)', () {
    test('places the symbol after the digits with a comma decimal', () {
      expect(plain(formatMoney(1250, '€', decimalDigits: 2, locale: fr)), '12,50 €');
    });

    test('negative amounts keep the sign before the digits', () {
      expect(plain(formatMoney(-1250, '€', decimalDigits: 2, locale: fr)), '-12,50 €');
    });

    test('groups thousands with a space', () {
      expect(plain(formatMoney(123456, '€', decimalDigits: 2, locale: fr)), '1 234,56 €');
    });

    test('a custom symbol is kept as typed, not derived from a currency code',
        () {
      expect(plain(formatMoney(1250, 'CA\$', decimalDigits: 2, locale: fr)), '12,50 CA\$');
      expect(plain(formatMoney(1250, 'pts', decimalDigits: 2, locale: fr)), '12,50 pts');
    });

    test('zero and sub-unit amounts', () {
      expect(plain(formatMoney(0, '€', decimalDigits: 2, locale: fr)), '0,00 €');
      expect(plain(formatMoney(9, '€', decimalDigits: 2, locale: fr)), '0,09 €');
    });
  });

  group('formatMoney (zh)', () {
    test('symbol before the digits, dot decimal', () {
      expect(formatMoney(1250, '¥', decimalDigits: 2, locale: zh), '¥12.50');
    });

    test('negative amounts and custom symbols', () {
      expect(formatMoney(-1250, '¥', decimalDigits: 2, locale: zh), '-¥12.50');
      expect(formatMoney(123456, 'CA\$', decimalDigits: 2, locale: zh), 'CA\$1,234.56');
    });
  });

  // #251: Spliit stores each currency in its own smallest unit, 10^digits
  // to one -- spliit-web's amountAsMinorUnits / amountAsDecimal.
  group('currencies without decimals', () {
    test('formats yen as whole yen', () {
      expect(formatMoney(1000, '¥', decimalDigits: 0, locale: en), '¥1,000');
      expect(formatMoney(-1000, '¥', decimalDigits: 0, locale: en), '-¥1,000');
      expect(plain(formatMoney(150000, 'Ft', decimalDigits: 0, locale: fr)), '150 000 Ft');
    });

    test('converts typed amounts to minor units like spliit-web', () {
      expect(toMinorUnits(1000, 0), 1000);
      expect(toMinorUnits(999.6, 0), 1000);
      expect(toMinorUnits(12.5, 2), 1250);
      expect(toMinorUnits(0.29, 2), 29);
    });

    test('shows minor units as field text', () {
      expect(minorUnitsText(1000, 0), '1000');
      expect(minorUnitsText(1000, 2), '10.00');
      expect(minorUnitsText(5, 2), '0.05');
    });

    test('derives a rate in major units, whatever the two currencies\' digits', () {
      // €6.10 paid as ¥1,000.
      final yenToEuro = conversionRateFor(
          amount: 610, decimalDigits: 2, originalAmount: 1000, originalDecimalDigits: 0);
      expect(yenToEuro, closeTo(0.0061, 1e-12));
      expect((1000 * yenToEuro * 100 / 1).round(), 610);

      // ¥1,000 paid as €6.10.
      final euroToYen = conversionRateFor(
          amount: 1000, decimalDigits: 0, originalAmount: 610, originalDecimalDigits: 2);
      expect((610 * euroToYen * 1 / 100).round(), 1000);

      // \$10.00 paid as €9.20: both in cents, as before.
      expect(
          conversionRateFor(amount: 1000, decimalDigits: 2, originalAmount: 920, originalDecimalDigits: 2),
          closeTo(1000 / 920, 1e-12));
    });
  });
}
