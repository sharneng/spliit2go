import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/context_l10n.dart';
import '../models/activity.dart';
import '../models/category.dart';
import '../models/group.dart';
import '../services/activity_date_group.dart';
import '../services/expense_date_group.dart' show firstWeekdayFor;
import '../sync/outbox.dart';
import '../utils/date_format.dart';
import '../widgets/section_heading.dart';
import 'expense_details_sheet.dart';

/// The group's server-side activity log (issue #26) -- who changed what
/// and when. Read-only and **online-only**: unlike expenses, activity
/// entries aren't cached locally or queued offline, since there's
/// nothing to add from this device -- it's purely a view of history the
/// server already recorded. One of GroupScreen's four tabs (issue #38).
///
/// Paginates via [SpliitClient.fetchActivities] the way the web app's
/// infinite-scroll list does (newest first, 20 per page): the next page
/// loads as the list nears its end, with no button (issue #91). Split
/// into the web's and spliit-ios's nine date sections, in local time.
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

  /// For the expense details sheet an entry opens (issue #90): category
  /// names and who "you" are, both from GroupScreen, which already has
  /// them.
  final List<Category> categories;
  final String? activeUserId;

  /// Called after an expense opened from here was edited, so GroupScreen
  /// can sync and refresh its cached expenses.
  final VoidCallback? onExpensesChanged;

  /// The current local time, and the conversion of a server moment to
  /// the phone's local time. Overridable so tests can pin a time zone: a
  /// test machine running in UTC wouldn't prove the conversion.
  @visibleForTesting
  final DateTime Function() now;
  @visibleForTesting
  final DateTime Function(DateTime) toLocal;

  const ActivityScreen({
    super.key,
    required this.client,
    required this.db,
    required this.outbox,
    required this.group,
    this.embedded = false,
    this.categories = const [],
    this.activeUserId,
    this.onExpensesChanged,
    this.now = DateTime.now,
    this.toLocal = _systemLocalTime,
  });

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

DateTime _systemLocalTime(DateTime t) => t.toLocal();

class _ActivityScreenState extends State<ActivityScreen> {
  final List<Activity> _activities = [];
  final Set<String> _seenIds = {};
  final _scroll = ScrollController();
  int _cursor = 0;
  bool _hasMore = true;
  bool _loading = false;
  String? _error;

  /// Bumped by [_reload], so a page still loading from before it can't
  /// land in the fresh list.
  int _generation = 0;

  /// How close to the end of the list, in pixels, the next page starts
  /// loading -- early enough that it's usually there before it's needed.
  static const _prefetchExtent = 400.0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    _loadMore();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Fetches the next page. One request at a time; the cursor only moves
  /// on success, so Retry asks for the same page again.
  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final generation = _generation;
    try {
      final page = await widget.client.fetchActivities(groupId: widget.group.id, cursor: _cursor);
      if (!mounted || generation != _generation) return;
      setState(() {
        // Pages can overlap when the log changes between requests. The
        // cursor still comes from the server, not from this count.
        _activities.addAll(page.activities.where((a) => _seenIds.add(a.id)));
        // A page that doesn't move the cursor would request itself forever.
        _hasMore = page.hasMore && page.nextCursor > _cursor;
        _cursor = page.nextCursor;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = context.l10n.activityLoadFailed(e.toString()));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        // A page too short to fill the screen never produces a scroll
        // event, so check again once it's laid out.
        WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
      }
    }
  }

  /// Loads the next page once the list nears its end or can't scroll
  /// yet. Never after a failure: that waits for the Retry button.
  void _maybeLoadMore() {
    if (!mounted || _loading || !_hasMore || _error != null) return;
    if (!_scroll.hasClients) {
      // No list on screen yet because the pages so far were empty.
      if (_activities.isEmpty) _loadMore();
      return;
    }
    if (_scroll.position.extentAfter < _prefetchExtent) _loadMore();
  }

  /// Mirrors the web app's fallback in activity-item.tsx's useSummary:
  /// a participant who's since been removed from the group (or was
  /// never resolvable) shows as "Someone" rather than a blank or an id.
  String _participantName(String? id) {
    if (id == null) return context.l10n.activitySomeone;
    for (final p in widget.group.participants) {
      if (p.id == id) return p.name;
    }
    return context.l10n.activitySomeone;
  }

  /// Plain-text equivalents of messages/en-US.json's Activity section
  /// (settingsModified/expenseCreated/expenseUpdated/expenseDeleted) --
  /// same wording, minus the rich bold/italic markup the web app adds.
  String _summary(Activity a) {
    final name = _participantName(a.participantId);
    switch (a.activityType) {
      case ActivityType.updateGroup:
        return context.l10n.activityGroupSettingsModified(name);
      case ActivityType.createExpense:
        return context.l10n.activityExpenseCreated(a.data ?? '', name);
      case ActivityType.updateExpense:
        return context.l10n.activityExpenseUpdated(a.data ?? '', name);
      case ActivityType.deleteExpense:
        return context.l10n.activityExpenseDeleted(a.data ?? '', name);
    }
  }

  String _sectionTitle(ActivityDateGroup group) {
    final l10n = context.l10n;
    return switch (group) {
      ActivityDateGroup.today => l10n.activityToday,
      ActivityDateGroup.yesterday => l10n.activityYesterday,
      ActivityDateGroup.earlierThisWeek => l10n.dateSectionEarlierThisWeek,
      ActivityDateGroup.lastWeek => l10n.dateSectionLastWeek,
      ActivityDateGroup.earlierThisMonth => l10n.dateSectionEarlierThisMonth,
      ActivityDateGroup.lastMonth => l10n.dateSectionLastMonth,
      ActivityDateGroup.earlierThisYear => l10n.dateSectionEarlierThisYear,
      ActivityDateGroup.lastYear => l10n.dateSectionLastYear,
      ActivityDateGroup.older => l10n.dateSectionOlder,
    };
  }

  /// Opens the activity's expense in the details sheet (issue #90). The
  /// cache may not have it yet, so the sheet fetches it from the server
  /// when it doesn't. A no-op if the expense has since been deleted
  /// ([Activity.expenseExists] false) or is missing an id.
  Future<void> _openExpense(Activity a) async {
    if (!a.expenseExists || a.expenseId == null) return;
    final changed = await showExpenseDetails(
      context,
      expenseId: a.expenseId!,
      group: widget.group,
      db: widget.db,
      client: widget.client,
      outbox: widget.outbox,
      categories: widget.categories,
      activeUserId: widget.activeUserId,
      fetchIfMissing: true,
    );
    if (!changed || !mounted) return;
    widget.onExpensesChanged?.call();
    // The change is now in the log itself.
    _reload();
  }

  /// Starts the log over from its newest page.
  void _reload() {
    setState(() {
      _generation++;
      _activities.clear();
      _seenIds.clear();
      _cursor = 0;
      _hasMore = true;
      _error = null;
    });
    _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    final body = _body();
    if (widget.embedded) return body;
    return Scaffold(appBar: AppBar(title: Text(context.l10n.activityTitle)), body: body);
  }

  Widget _body() {
    if (_activities.isEmpty) {
      if (_error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                TextButton(onPressed: _loadMore, child: Text(context.l10n.commonRetry)),
              ],
            ),
          ),
        );
      }
      if (_loading || _hasMore) return const Center(child: CircularProgressIndicator());
      return Center(child: Text(context.l10n.activityEmpty));
    }

    // The whole loaded log is grouped on every build, so a section that
    // continues onto the next page keeps a single heading.
    final sections = groupActivitiesByDate(
      _activities,
      now: widget.now(),
      firstWeekday: firstWeekdayFor(View.of(context).platformDispatcher.locale),
      toLocal: widget.toLocal,
    );
    final rows = <Object>[
      for (final (group, activities) in sections) ...[
        group,
        for (final a in activities) (a, group.needsDate),
      ],
    ];

    return ListView.builder(
      controller: _scroll,
      itemCount: rows.length + 1, // +1 for the footer (loading / error)
      itemBuilder: (context, i) {
        if (i == rows.length) return _footer();
        final row = rows[i];
        if (row is ActivityDateGroup) return SectionHeading(_sectionTitle(row));
        final (a, needsDate) = row as (Activity, bool);
        final local = widget.toLocal(a.time);
        final locale = context.appLocale;
        return ListTile(
          title: Text(_summary(a)),
          subtitle: Text(needsDate
              ? formatDateTime(local, locale: locale)
              : formatTimeOfDay(local, locale: locale)),
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
            TextButton(onPressed: _loadMore, child: Text(context.l10n.commonRetry)),
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
    return const SizedBox(height: 16);
  }
}
