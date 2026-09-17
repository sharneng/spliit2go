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
