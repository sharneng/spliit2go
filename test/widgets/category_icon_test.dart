import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:spliit2go/models/category.dart';
import 'package:spliit2go/widgets/category_icon.dart';

void main() {
  group('categoryIconData', () {
    test('maps a category to spliit-web\'s own Lucide glyph for it', () {
      expect(
        categoryIconData(const Category(id: 1, name: 'Groceries', grouping: 'Food and Drink')),
        LucideIcons.shoppingCart,
      );
      expect(
        categoryIconData(const Category(id: 2, name: 'Taxi', grouping: 'Transportation')),
        LucideIcons.carTaxiFront,
      );
      expect(
        categoryIconData(const Category(id: 3, name: 'Rent', grouping: 'Home')),
        LucideIcons.piggyBank,
      );
    });

    // Several category *names* contain a slash of their own -- confirms
    // the "<grouping>/<name>" key isn't ambiguously split/rejoined.
    test('resolves a category whose own name contains a slash', () {
      expect(
        categoryIconData(
          const Category(id: 4, name: 'Bus/Train', grouping: 'Transportation'),
        ),
        LucideIcons.train,
      );
      expect(
        categoryIconData(
          const Category(id: 5, name: 'TV/Phone/Internet', grouping: 'Utilities'),
        ),
        LucideIcons.phone,
      );
    });

    test('falls back to banknote for an unrecognized category, not a crash', () {
      expect(
        categoryIconData(const Category(id: 99, name: 'Something New', grouping: 'Other')),
        LucideIcons.banknote,
      );
    });

    test('falls back to banknote for a null category', () {
      expect(categoryIconData(null), LucideIcons.banknote);
    });
  });
}
