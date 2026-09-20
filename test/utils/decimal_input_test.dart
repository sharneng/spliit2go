import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/utils/decimal_input.dart';

void main() {
  group('parseFlexibleDecimal', () {
    for (final input in ['12,50', '12.50', ' 12,5 ']) {
      test('accepts "$input" as 12.5', () {
        expect(parseFlexibleDecimal(input), 12.5);
      });
    }
    for (final input in ['', '   ', 'garbage', '1,234.56']) {
      test('rejects "$input"', () {
        expect(parseFlexibleDecimal(input), isNull);
      });
    }
  });
}
