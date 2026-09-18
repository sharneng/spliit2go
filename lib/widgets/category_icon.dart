import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../models/category.dart';

/// The glyph that stands for an expense category (issue #28), grounded
/// in spliit-web's own map rather than guessed: `category-icon.tsx`
/// (`src/app/groups/[groupId]/expenses/category-icon.tsx`) maps every
/// server category to a Lucide icon, keyed `"<grouping>/<name>"`, with
/// a banknote as the fallback for anything unmapped. [LucideIcons] is a
/// 1:1 Flutter port of the same icon set (same names, same glyphs), so
/// this is the exact icon spliit-web itself shows for each category --
/// not an approximation with Material icons.
///
/// spliit-ios's own equivalent (`Shared/ExpenseCategoryIcon.swift`)
/// re-maps the same keys to SF Symbols instead, since SF Symbols don't
/// exist on Android -- Lucide, being cross-platform and what the web app
/// itself actually uses, is the closer match for this app.
///
/// A category the server adds later (or a self-hosted instance's custom
/// category) falls through to [LucideIcons.banknote], exactly as it does
/// on spliit-web -- never crashes, never shows a blank glyph.
IconData categoryIconData(Category? category) {
  if (category == null) return LucideIcons.banknote;
  return _icons['${category.grouping}/${category.name}'] ?? LucideIcons.banknote;
}

/// Keyed exactly as spliit-web keys it -- several category *names*
/// contain a slash of their own ("Bus/Train", "Gas/Fuel", "Heat/Gas",
/// "TV/Phone/Internet"), which is why this is a flat string key rather
/// than a pair.
const Map<String, IconData> _icons = {
  'Uncategorized/General': LucideIcons.banknote,
  'Uncategorized/Payment': LucideIcons.banknote,
  'Entertainment/Entertainment': LucideIcons.ferrisWheel,
  'Entertainment/Games': LucideIcons.dices,
  'Entertainment/Movies': LucideIcons.clapperboard,
  'Entertainment/Music': LucideIcons.music,
  'Entertainment/Sports': LucideIcons.dumbbell,
  'Food and Drink/Food and Drink': LucideIcons.utensils,
  'Food and Drink/Dining Out': LucideIcons.martini,
  'Food and Drink/Groceries': LucideIcons.shoppingCart,
  'Food and Drink/Liquor': LucideIcons.wine,
  'Home/Home': LucideIcons.house,
  'Home/Electronics': LucideIcons.plug,
  'Home/Furniture': LucideIcons.armchair,
  'Home/Household Supplies': LucideIcons.lamp,
  'Home/Maintenance': LucideIcons.wrench,
  'Home/Mortgage': LucideIcons.landmark,
  'Home/Pets': LucideIcons.cat,
  'Home/Rent': LucideIcons.piggyBank,
  'Home/Services': LucideIcons.wrench,
  'Life/Childcare': LucideIcons.baby,
  'Life/Clothing': LucideIcons.shirt,
  'Life/Donation': LucideIcons.handHelping,
  'Life/Education': LucideIcons.libraryBig,
  'Life/Gifts': LucideIcons.gift,
  'Life/Insurance': LucideIcons.landmark,
  'Life/Medical Expenses': LucideIcons.stethoscope,
  'Life/Taxes': LucideIcons.banknote,
  'Transportation/Transportation': LucideIcons.bus,
  'Transportation/Bicycle': LucideIcons.bike,
  'Transportation/Bus/Train': LucideIcons.train,
  'Transportation/Car': LucideIcons.car,
  'Transportation/Gas/Fuel': LucideIcons.fuel,
  'Transportation/Hotel': LucideIcons.hotel,
  'Transportation/Parking': LucideIcons.parkingMeter,
  'Transportation/Plane': LucideIcons.plane,
  'Transportation/Taxi': LucideIcons.carTaxiFront,
  'Utilities/Utilities': LucideIcons.banknote,
  'Utilities/Cleaning': LucideIcons.eraser,
  'Utilities/Electricity': LucideIcons.plugZap,
  'Utilities/Heat/Gas': LucideIcons.thermometerSun,
  'Utilities/Trash': LucideIcons.trash,
  'Utilities/TV/Phone/Internet': LucideIcons.phone,
  'Utilities/Water': LucideIcons.cupSoda,
};

/// A category's glyph in a rounded "slot" -- the treatment spliit-ios's
/// own `CategoryIcon` view uses to lead an expense row
/// (`Spliit/Views/DesignSystem/CategoryIcon.swift`): a neutral (not
/// tinted) fill, so the icon doesn't compete with the amount for
/// attention, and a glyph sized to about half the slot. Ported to this
/// app's Material theming rather than iOS's `tertiarySystemFill` --
/// [ColorScheme.surfaceContainerHighest]/[ColorScheme.onSurfaceVariant]
/// is Material's own equivalent "quiet, neutral chip" pairing.
///
/// Used both as the expense list's leading icon (issue #28's "group
/// screen" ask, `size` defaulting to spliit-ios's own 34) and, at a
/// smaller size, inline in the expense form's category field and picker
/// rows (this app's "expense screen" ask).
class CategoryIconGlyph extends StatelessWidget {
  final Category? category;
  final double size;

  const CategoryIconGlyph({super.key, required this.category, this.size = 34});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(size * 0.24),
      ),
      child: Icon(categoryIconData(category), size: size * 0.55, color: colors.onSurfaceVariant),
    );
  }
}
