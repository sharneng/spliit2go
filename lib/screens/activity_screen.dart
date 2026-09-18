import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../models/activity.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../sync/outbox.dart';
import 'expense_screen.dart';

/// The group's server-side activity log (issue #26) -- who changed what
/// and when. Read-only and **online-only**: unlike expenses, activity
/// entries aren't cached locally or queued offline, since there's
/// nothing to add from this device -- it's purely a view of history the
/// server already recorded. One of GroupScreen's four tabs (issue #38).
///
/// Paginates via [SpliitClient.fetchActivities] the same way the web
/// app's infinite-scroll list does (newest first, 20 per page), but as
/// an explicit "Load more" row rather than a scroll listener -- simpler
/// to test deterministically, and this list is typically short enough
/// that the extra tap isn't a real cost.
class ActivityScreen extends StatefulWidget {
  final SpliitClient client;
  final AppDatabase db;
  final Outbox outbox;
  final Group group;

  /// See BalancesScreen's own doc comment on its identical field --
  /// same reasoning (issue #38): true embeds just the content, with no
  /// Scaffold/AppBar of its own, for use as one of GroupScreen's tab
  /// bodies.
  final bool embedded;

  const ActivityScreen({
    super.key,
    required this.client,
    required this.db,
    required this.outbox,
    required this.group,
    this.embedded = false,
  });

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  final List<Activity> _activities = [];
  int _cursor = 0;
  bool _hasMore = true;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.client.fetchActivities(groupId: widget.group.id, cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _activities.addAll(page.activities);
        _hasMore = page.hasMore;
        _cursor = page.nextCursor;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = "Couldn't load activity: $e");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Mirrors the web app's fallback in activity-item.tsx's useSummary:
  /// a participant who's since been removed from the group (or was
  /// never resolvable) shows as "Someone" rather than a blank or an id.
  String _participantName(String? id) {
    if (id == null) return 'Someone';
    for (final p in widget.group.participants) {
      if (p.id == id) return p.name;
    }
    return 'Someone';
  }

  /// Plain-text equivalents of messages/en-US.json's Activity section
  /// (settingsModified/expenseCreated/expenseUpdated/expenseDeleted) --
  /// same wording, minus the rich bold/italic markup the web app adds.
  String _summary(Activity a) {
    final name = _participantName(a.participantId);
    switch (a.activityType) {
      case ActivityType.updateGroup:
        return 'Group settings were modified by $name.';
      case ActivityType.createExpense:
        return 'Expense "${a.data ?? ''}" created by $name.';
      case ActivityType.updateExpense:
        return 'Expense "${a.data ?? ''}" updated by $name.';
      case ActivityType.deleteExpense:
        return 'Expense "${a.data ?? ''}" deleted by $name.';
    }
  }

  /// A simplified version of the web app's 9-bucket relative grouping
  /// (today/yesterday/earlier this week/last week/.../older) -- Today
  /// and Yesterday get the same special-casing, everything else is
  /// just its calendar date. Good enough to break up a long list
  /// without the added complexity of replicating week/month bucketing
  /// (including locale-specific week-start) that the web app needed a
  /// whole date-groups.ts helper for.
  String _dateHeader(DateTime t) {
    final now = DateTime.now();
    final day = DateTime(t.year, t.month, t.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Opens the activity's expense for editing -- same fetch-fresh-first
  /// pattern as GroupScreen._openEditExpense, for the same reason (no
  /// server-side conflict prevention on edits, see ExpenseScreen's doc
  /// comment). A no-op if the expense has since been deleted
  /// ([Activity.expenseExists] false) or is missing an id.
  Future<void> _openExpense(Activity a) async {
    if (!a.expenseExists || a.expenseId == null) return;
    late final Expense fresh;
    try {
      fresh = await widget.client.fetchExpense(groupId: widget.group.id, expenseId: a.expenseId!);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Opening this expense needs a connection.')),
      );
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExpenseScreen(
          client: widget.client,
          db: widget.db,
          outbox: widget.outbox,
          group: widget.group,
          existingExpense: fresh,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = _body();
    if (widget.embedded) return body;
    return Scaffold(appBar: AppBar(title: const Text('Activity')), body: body);
  }

  Widget _body() {
    if (_activities.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_activities.isEmpty && _error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              TextButton(onPressed: _loadMore, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_activities.isEmpty) {
      return const Center(child: Text('There is not yet any activity in your group.'));
    }

    // Flattened header+item rows, computed fresh whenever the list
    // changes -- simpler than tracking header positions incrementally
    // as pages arrive, and this list is never long enough for that to
    // matter.
    final rows = <Object>[];
    String? lastHeader;
    for (final a in _activities) {
      final header = _dateHeader(a.time);
      if (header != lastHeader) {
        rows.add(header);
        lastHeader = header;
      }
      rows.add(a);
    }

    return ListView.builder(
      itemCount: rows.length + 1, // +1 for the footer (load more / error / done)
      itemBuilder: (context, i) {
        if (i == rows.length) return _footer();
        final row = rows[i];
        if (row is String) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              row,
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          );
        }
        final a = row as Activity;
        return ListTile(
          title: Text(_summary(a)),
          subtitle: Text(_formatTime(a.time)),
          trailing: a.expenseExists ? const Icon(Icons.chevron_right) : null,
          onTap: a.expenseExists ? () => _openExpense(a) : null,
        );
      },
    );
  }

  Widget _footer() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            TextButton(onPressed: _loadMore, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_hasMore) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(child: TextButton(onPressed: _loadMore, child: const Text('Load more'))),
      );
    }
    return const SizedBox(height: 16);
  }
}
