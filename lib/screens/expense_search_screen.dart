import 'dart:async';

import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/context_l10n.dart';
import '../models/category.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../services/expense_search.dart';
import '../sync/outbox.dart';
import '../widgets/expense_list.dart';
import 'expense_details_sheet.dart';

/// Searches a group's expenses by title (issue #39), from the search
/// button in GroupScreen's bottom bar.
///
/// Its own screen, like spliit-ios's search tab (ExpenseSearchView), which
/// keeps its results apart from the expense list rather than narrowing it.
/// Unlike spliit-ios it doesn't ask the server: it filters the local cache
/// as you type (see [searchExpenses]), watched live so an edit or delete
/// made from a result shows here straight away.
class ExpenseSearchScreen extends StatefulWidget {
  const ExpenseSearchScreen({
    super.key,
    required this.group,
    required this.db,
    required this.client,
    required this.outbox,
    this.categories = const [],
    this.activeUserId,
    this.onExpensesChanged,
  });

  final Group group;
  final AppDatabase db;
  final SpliitClient client;
  final Outbox outbox;
  final List<Category> categories;
  final String? activeUserId;

  /// Called when an expense opened from the results was edited, deleted,
  /// requeued or discarded, so the group screen can sync and refresh.
  final VoidCallback? onExpensesChanged;

  @override
  State<ExpenseSearchScreen> createState() => _ExpenseSearchScreenState();
}

class _ExpenseSearchScreenState extends State<ExpenseSearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  List<Expense> _expenses = const [];
  StreamSubscription<List<ExpenseRow>>? _expensesSub;

  @override
  void initState() {
    super.initState();
    _expensesSub = widget.db.watchExpensesForGroup(widget.group.id).listen((rows) {
      if (!mounted) return;
      setState(() => _expenses = rows.map(widget.db.rowToExpense).toList());
    });
  }

  @override
  void dispose() {
    _expensesSub?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Category _categoryFor(int id) => widget.categories.firstWhere(
        (c) => c.id == id,
        orElse: () => Category(id: id, name: 'Category $id', grouping: 'Other'),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          focusNode: _focus,
          autofocus: true,
          autocorrect: false,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: l10n.expenseSearchHint,
            border: InputBorder.none,
          ),
          onChanged: (_) => setState(() {}),
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: l10n.expenseSearchClear,
              onPressed: () {
                _controller.clear();
                _focus.requestFocus();
                setState(() {});
              },
            ),
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final l10n = context.l10n;
    final query = _controller.text.trim();
    if (query.isEmpty) {
      return _message(context, l10n.expenseSearchPromptTitle, l10n.expenseSearchPromptBody);
    }
    final matches = searchExpenses(_expenses, query);
    if (matches.isEmpty) {
      return _message(
          context, l10n.expenseSearchNoMatchesTitle, l10n.expenseSearchNoMatchesBody(query));
    }
    return ExpenseDateList(
      expenses: matches,
      currency: widget.group.currency,
      categoryFor: _categoryFor,
      onTap: _openExpenseDetails,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    );
  }

  Widget _message(BuildContext context, String title, String body) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(body,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Future<void> _openExpenseDetails(Expense e) async {
    // The keyboard would otherwise sit over the sheet.
    _focus.unfocus();
    final changed = await showExpenseDetails(
      context,
      expenseId: e.id,
      group: widget.group,
      db: widget.db,
      client: widget.client,
      outbox: widget.outbox,
      categories: widget.categories,
      activeUserId: widget.activeUserId,
    );
    if (changed && mounted) widget.onExpensesChanged?.call();
  }
}
