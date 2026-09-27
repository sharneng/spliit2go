/// One entry from Spliit's `categories.list` -- id, display name, and
/// which [grouping] it's filed under (e.g. "Food and Drink", "Home",
/// "Transportation"). The server's list is already grouped/ordered
/// sensibly (same grouping's categories are adjacent), so callers that
/// want a grouped picker (issue #19) don't need to re-sort, just fold
/// consecutive same-grouping entries into sections.
class Category {
  final int id;
  final String name;
  final String grouping;

  const Category({required this.id, required this.name, required this.grouping});

  factory Category.fromJson(Map<String, dynamic> json) => Category(
        id: (json['id'] as num).round(),
        name: json['name'] as String,
        // A server predating the grouping column, or one that omits it
        // for some reason, still gets a usable (if flat) picker rather
        // than a crash -- falls back to a single catch-all section.
        grouping: json['grouping'] as String? ?? 'Other',
      );
}

/// The categories every Spliit instance starts with (#132): seeded by
/// its migrations with fixed ids, so "Groceries" is 9 on spliit.app and
/// on a self-hosted instance alike (spliit-ios relies on the same,
/// `CategoryEntity.swift`). Used for a server whose own list this device
/// hasn't read yet, so the picker works offline from the first launch.
///
/// Spliit cc796210, in `categories.list`'s order (by id):
/// prisma/migrations/20240108194443_add_categories and
/// 20250308000000_add_category_donation (43, Donation, filed under Life).
const spliitSeedCategories = <Category>[
  Category(id: 0, grouping: 'Uncategorized', name: 'General'),
  Category(id: 1, grouping: 'Uncategorized', name: 'Payment'),
  Category(id: 2, grouping: 'Entertainment', name: 'Entertainment'),
  Category(id: 3, grouping: 'Entertainment', name: 'Games'),
  Category(id: 4, grouping: 'Entertainment', name: 'Movies'),
  Category(id: 5, grouping: 'Entertainment', name: 'Music'),
  Category(id: 6, grouping: 'Entertainment', name: 'Sports'),
  Category(id: 7, grouping: 'Food and Drink', name: 'Food and Drink'),
  Category(id: 8, grouping: 'Food and Drink', name: 'Dining Out'),
  Category(id: 9, grouping: 'Food and Drink', name: 'Groceries'),
  Category(id: 10, grouping: 'Food and Drink', name: 'Liquor'),
  Category(id: 11, grouping: 'Home', name: 'Home'),
  Category(id: 12, grouping: 'Home', name: 'Electronics'),
  Category(id: 13, grouping: 'Home', name: 'Furniture'),
  Category(id: 14, grouping: 'Home', name: 'Household Supplies'),
  Category(id: 15, grouping: 'Home', name: 'Maintenance'),
  Category(id: 16, grouping: 'Home', name: 'Mortgage'),
  Category(id: 17, grouping: 'Home', name: 'Pets'),
  Category(id: 18, grouping: 'Home', name: 'Rent'),
  Category(id: 19, grouping: 'Home', name: 'Services'),
  Category(id: 20, grouping: 'Life', name: 'Childcare'),
  Category(id: 21, grouping: 'Life', name: 'Clothing'),
  Category(id: 22, grouping: 'Life', name: 'Education'),
  Category(id: 23, grouping: 'Life', name: 'Gifts'),
  Category(id: 24, grouping: 'Life', name: 'Insurance'),
  Category(id: 25, grouping: 'Life', name: 'Medical Expenses'),
  Category(id: 26, grouping: 'Life', name: 'Taxes'),
  Category(id: 27, grouping: 'Transportation', name: 'Transportation'),
  Category(id: 28, grouping: 'Transportation', name: 'Bicycle'),
  Category(id: 29, grouping: 'Transportation', name: 'Bus/Train'),
  Category(id: 30, grouping: 'Transportation', name: 'Car'),
  Category(id: 31, grouping: 'Transportation', name: 'Gas/Fuel'),
  Category(id: 32, grouping: 'Transportation', name: 'Hotel'),
  Category(id: 33, grouping: 'Transportation', name: 'Parking'),
  Category(id: 34, grouping: 'Transportation', name: 'Plane'),
  Category(id: 35, grouping: 'Transportation', name: 'Taxi'),
  Category(id: 36, grouping: 'Utilities', name: 'Utilities'),
  Category(id: 37, grouping: 'Utilities', name: 'Cleaning'),
  Category(id: 38, grouping: 'Utilities', name: 'Electricity'),
  Category(id: 39, grouping: 'Utilities', name: 'Heat/Gas'),
  Category(id: 40, grouping: 'Utilities', name: 'Trash'),
  Category(id: 41, grouping: 'Utilities', name: 'TV/Phone/Internet'),
  Category(id: 42, grouping: 'Utilities', name: 'Water'),
  Category(id: 43, grouping: 'Life', name: 'Donation'),
];
