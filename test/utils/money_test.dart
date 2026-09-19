import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/utils/money.dart';

void main() {
  group('formatMoney', () {
    test('formats a positive amount with the given currency symbol', () {
      expect(formatMoney(1250, '\$'), '\$12.50');
    });

    test('uses whatever symbol is passed, not just \$', () {
      expect(formatMoney(1250, '€'), '€12.50');
      expect(formatMoney(1250, '£'), '£12.50');
    });

    test('puts a single leading minus before the symbol for a negative amount', () {
      expect(formatMoney(-1250, '\$'), '-\$12.50');
      expect(formatMoney(-1250, '€'), '-€12.50');
    });

    test('formats zero without a sign', () {
      expect(formatMoney(0, '\$'), '\$0.00');
    });

    test('always shows two decimal places, even for a whole-dollar amount', () {
      expect(formatMoney(500, '\$'), '\$5.00');
    });

    test('handles amounts under a dollar', () {
      expect(formatMoney(9, '\$'), '\$0.09');
      expect(formatMoney(-9, '\$'), '-\$0.09');
    });
  });
}
