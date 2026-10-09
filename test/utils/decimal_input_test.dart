import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/utils/decimal_input.dart';

void main() {
  group('parseFlexibleDecimal', () {
    for (final input in ['12,50', '12.50', ' 12,5 ', '12.5']) {
      test('accepts "$input" as 12.5', () {
        expect(parseFlexibleDecimal(input), 12.5);
      });
    }
    for (final input in ['', '   ', 'garbage', '1,23,4', '12abc34', '1.234.5,6,7', '1,2.34,5']) {
      test('rejects "$input"', () {
        expect(parseFlexibleDecimal(input), isNull);
      });
    }
  });

  // #238: an amount pasted as it's written elsewhere.
  group('pasted amounts', () {
    for (final (input, value) in [
      ('1,234.56', 1234.56),
      ('1.234,56', 1234.56),
      (r'$1,234.56', 1234.56),
      (r'US$ 1,234.56', 1234.56),
      ('1 234,56 €', 1234.56),
      ('1\u00a0234,56\u00a0€', 1234.56),
      ('1\u202f234,56', 1234.56),
      ("CHF 1'234.50", 1234.5),
      ('JPY ¥20,000', 20000.0),
      ('1,234,567', 1234567.0),
      ('1.234.567,8', 1234567.8),
      ('-12,50', -12.5),
      ('0.3333', 0.3333),
      ('1234,567', 1234.567),
    ]) {
      test('"$input" is $value', () {
        expect(parseFlexibleDecimal(input), value);
      });
    }

    test('only "1,234" is ambiguous, and the locale decides it', () {
      expect(parseFlexibleDecimal('1,234'), 1234);
      expect(parseFlexibleDecimal('1.234'), 1.234);
      expect(parseFlexibleDecimal('1,234', decimalSeparator: ','), 1.234);
      expect(parseFlexibleDecimal('1.234', decimalSeparator: ','), 1234);
    });
  });
}
