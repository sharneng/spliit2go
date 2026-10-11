import 'package:flutter/material.dart';

import '../l10n/category_names.dart';
import '../l10n/context_l10n.dart';
import '../models/category.dart';
import 'category_icon.dart';
import 'currency_picker.dart' show searchSheetHeight;

/// Picks a category (issue #19): a sheet with a search field over the
/// categories, grouped as the server lists them, [selectedId] checked.
/// Answers null when it's closed without a pick.
Future<Category?> showCategoryPicker(
  BuildContext context, {
  required List<Category> categories,
  required int selectedId,
}) =>
    showModalBottomSheet<Category>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CategoryPicker(categories: categories, selectedId: selectedId),
    );

/// The category picker's contents (issue #19): a search field followed by
/// a scrollable, grouped list. Filtering narrows to categories whose name
/// contains the query (case-insensitive); a group with no matches under
/// the current query is hidden entirely rather than shown with an empty
/// section.
class _CategoryPicker extends StatefulWidget {
  final List<Category> categories;
  final int selectedId;

  const _CategoryPicker({required this.categories, required this.selectedId});

  @override
  State<_CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<_CategoryPicker> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Groups [categories] by [Category.grouping], preserving the order
  /// groupings first appear in -- the server's own list is already laid
  /// out with each grouping's categories adjacent, so this doesn't need
  /// to re-sort, just fold consecutive runs into sections.
  List<MapEntry<String, List<Category>>> _grouped(List<Category> categories) {
    final groups = <String, List<Category>>{};
    for (final c in categories) {
      (groups[c.grouping] ??= []).add(c);
    }
    return groups.entries.toList();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? widget.categories
        : widget.categories
            .where((c) => categoryMatchesQuery(context.appLocale, c, query))
            .toList();
    final sections = _grouped(filtered);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: searchSheetHeight(context),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: context.l10n.expenseCategorySearchLabel,
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              Expanded(
                child: sections.isEmpty
                    ? Center(child: Text(context.l10n.expenseNoMatchingCategories))
                    : ListView(
                        children: [
                          for (final section in sections) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                              child: Text(
                                localizedCategoryGrouping(context, section.key),
                                style: Theme.of(context)
                                    .textTheme
                                    .labelLarge
                                    ?.copyWith(color: Theme.of(context).colorScheme.primary),
                              ),
                            ),
                            for (final c in section.value)
                              ListTile(
                                leading: CategoryIconGlyph(category: c, size: 28),
                                title: Text(localizedCategoryName(context, c)),
                                trailing: c.id == widget.selectedId
                                    ? const Icon(Icons.check)
                                    : null,
                                onTap: () => Navigator.of(context).pop(c),
                              ),
                          ],
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
