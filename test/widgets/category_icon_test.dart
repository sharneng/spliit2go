import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/widgets/category_icon.dart';

// #205: each of the server's groupings has a color of its own.
void main() {
  test('the seven groupings each get a distinct color', () {
    const groupings = [
      'Uncategorized',
      'Entertainment',
      'Food and Drink',
      'Home',
      'Life',
      'Transportation',
      'Utilities',
    ];
    final colors = {for (final g in groupings) groupingColorIndex(g)};
    expect(colors, hasLength(groupings.length));
    expect(colors.every((i) => i >= 0 && i < 8), isTrue);
  });

  test('a grouping the server adds later still gets a color', () {
    expect(groupingColorIndex('Travel'), inInclusiveRange(0, 7));
  });
}
