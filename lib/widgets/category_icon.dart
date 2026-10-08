import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../models/category.dart';
import '../theme.dart';
import 'group_monogram.dart';
import 'grouped_section.dart';

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

/// [grouping]'s place in [monogramPalette] (#205). Hashing the names
/// would put the seven groupings on only four colors, so each has its
/// own; one a server adds later is hashed like a group id.
int groupingColorIndex(String grouping) =>
    _groupingColors[grouping] ?? groupColorIndex(grouping);

const Map<String, int> _groupingColors = {
  'Uncategorized': 2, // indigo
  'Entertainment': 7, // violet
  'Food and Drink': 4, // orange
  'Home': 6, // olive
  'Life': 3, // pink
  'Transportation': 1, // cyan
  'Utilities': 5, // amber
};

/// A category's glyph in a circle, like the group list's monograms
/// (spliit-ios's own `CategoryIcon` uses a rounded square), with a glyph
/// sized to about half the circle.
///
/// The slot is tinted by the category's grouping (#205), from the group
/// list's monogram colors: each of the server's seven groupings has its
/// own (see [_groupingColors]), so every category of a grouping shares
/// one color. With no category known it stays neutral.
///
/// Used both as the expense list's leading icon (issue #28's "group
/// screen" ask, `size` defaulting to spliit-ios's own 34) and, at a
/// smaller size, inline in the expense form's category field and picker
/// rows (this app's "expense screen" ask).
///
/// A reimbursement isn't an expense, so its icon is its own (#224): the
/// Uncategorized banknote whatever its category, in the app's emerald on
/// the color of the lines between rows: the page's color in light mode,
/// and in dark the lighter tone that stands off the card (the page's
/// near-black would sink into it).
class CategoryIconGlyph extends StatelessWidget {
  final Category? category;
  final double size;
  final bool isReimbursement;

  const CategoryIconGlyph(
      {super.key, required this.category, this.size = 34, this.isReimbursement = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    if (isReimbursement) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: GroupedDivider.colorOf(context), shape: BoxShape.circle),
        child: Icon(LucideIcons.banknote, size: size * 0.55, color: colors.primary),
      );
    }
    final grouping = category?.grouping;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: grouping == null
            ? colors.surfaceContainerHighest
            : monogramPalette[groupingColorIndex(grouping)],
        shape: BoxShape.circle,
      ),
      child: Icon(categoryIconData(category),
          size: size * 0.55, color: grouping == null ? colors.onSurfaceVariant : Colors.white),
    );
  }
}
