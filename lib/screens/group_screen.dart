import 'dart:async';

import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/context_l10n.dart';
import '../models/category.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../services/active_user.dart';
import '../services/settings_service.dart';
import '../sync/outbox.dart';
import '../utils/date_format.dart';
import '../utils/money.dart';
import '../widgets/category_icon.dart';
import 'expense_screen.dart';
import 'activity_screen.dart';
import 'balances_screen.dart';
import 'group_settings_screen.dart';
import 'stats_screen.dart';

/// A single group's expenses, offline-first -- reached by pushing on top
/// of GroupListScreen (the app's actual root; see main.dart and
/// decisions/multi-group-design.md), which is what gives this screen a
/// normal, always-valid back arrow back to the list.
///
/// On load, shows whatever's cached locally immediately, then tries a live
/// fetch in the background and replaces the cache on success. Pending
/// (offline-added, not yet synced) expenses always show regardless of
/// connectivity, badged as unsynced, since they're never touched by the
/// server-fetch overwrite -- see AppDatabase.replaceServerExpenses.
class GroupScreen extends StatefulWidget {
  final SpliitClient client;
  final AppDatabase db;
  final Outbox outbox;
  final String groupId;

  const GroupScreen({
    super.key,
    required this.client,
    required this.db,
    required this.outbox,
    required this.groupId,
  });

  @override
  State<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends State<GroupScreen> {
  final _settings = SettingsService();

  Group? _group;
  List<Expense> _expenses = [];
  bool _loading = true;
  String? _error;
  String? _activeUserId;

  // Live db subscriptions (issue #47) -- replace the old imperative
  // "write, then explicitly re-query" pattern: once subscribed here,
  // every local write anywhere (a live refresh's replaceServerExpenses/
  // cacheGroup, an offline insertPending, a sync-failure retry/delete,
  // GroupSettingsScreen's own save...) shows up automatically, without
  // this screen needing to know which specific write just happened or
  // remembering to reload after each one.
  StreamSubscription<Group?>? _groupSub;
  StreamSubscription<List<ExpenseRow>>? _expensesSub;

  // Which of the four bottom-nav tabs is showing (issue #38 -- replaces
  // the old design where Balances/Stats/Activity were each a full
  // pushed screen reached from an AppBar icon, which by the fourth icon
  // left no room for the group's own name). 0 = Expenses, matching this
  // screen's original default (and only) content.
  int _tabIndex = 0;

  // Falls back to just "General" (Spliit's own default, id 0) until/unless
  // a live categories.list succeeds -- same fallback expense_screen.dart
  // uses, and for the same reason: offline or a slow first load shouldn't
  // block the expense list from rendering at all, just from resolving
  // real category icons (issue #28) until the fetch completes. Every
  // expense not in [_categories] yet shows the same fallback banknote
  // glyph (see categoryIconData's own default) rather than a blank or
  // crashing lookup.
  List<Category> _categories = const [
    Category(id: 0, name: 'General', grouping: 'Uncategorized'),
  ];

  @override
  void initState() {
    super.initState();
    _groupSub = widget.db.watchCachedGroup(widget.groupId).listen((group) {
      if (!mounted) return;
      setState(() => _group = group);
      // Participants (or which one's remembered as "you") may have
      // changed along with the group -- re-resolve on every emission,
      // same as the old code did after both the initial cache load and
      // every live refresh.
      _resolveActiveUser();
    });
    _expensesSub = widget.db.watchExpensesForGroup(widget.groupId).listen((rows) {
      if (!mounted) return;
      setState(() => _expenses = rows.map(widget.db.rowToExpense).toList());
    });
    _refresh();
    _loadCategories();
    // Guarded: connectivity_plus's platform channel isn't set up in every
    // environment (widget tests being the immediate reason this got
    // added, but a misconfigured platform is a real possibility too).
    // Losing this listener only means sync falls back to pull-to-refresh
    // and the right-after-adding trigger, rather than crashing the screen.
    try {
      Connectivity().onConnectivityChanged.listen(
        (results) {
          if (!results.contains(ConnectivityResult.none)) {
            _syncThenRefresh();
          }
        },
        onError: (_) {},
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _groupSub?.cancel();
    _expensesSub?.cancel();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    try {
      final cats = await widget.client.fetchCategories();
      if (!mounted || cats.isEmpty) return;
      setState(() => _categories = cats);
    } catch (_) {
      // Offline or the server's unreachable -- keep the General-only
      // fallback so the list still renders (with generic icons) without
      // connectivity.
    }
  }

  /// The [Category] behind an expense's [Expense.category] id, or a
  /// synthesized placeholder if this device hasn't fetched a name for
  /// it yet -- same on-demand-placeholder approach as expense_screen.dart's
  /// own [_selectedCategory] getter, so an unresolved id still renders a
  /// (generic) icon instead of crashing the list.
  Category _categoryFor(int id) => _categories.firstWhere(
        (c) => c.id == id,
        orElse: () => Category(id: id, name: 'Category $id', grouping: 'Other'),
      );

  /// Fetches the group + its expenses live and writes them to the local
  /// db. Deliberately doesn't touch [_group]/[_expenses] itself anymore
  /// (issue #47) -- [_groupSub]/[_expensesSub] pick up [cacheGroup]'s and
  /// [replaceServerExpenses]'s writes on their own and update those
  /// fields via setState.
  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final group = await widget.client.fetchGroup(widget.groupId);
      final fresh = await widget.client.fetchExpenses(widget.groupId);
      await widget.db.cacheGroup(group);
      await widget.db.replaceServerExpenses(widget.groupId, fresh);
      if (!mounted) return;
      setState(() => _error = null);
    } catch (e, st) {
      // Offline or the server's unreachable -- fine, we already loaded
      // whatever's cached. Only surface an error if we have nothing at
      // all to show.
      //
      // The on-screen message is deliberately just e.toString() (no
      // stack trace -- too noisy for a phone screen), but the full
      // trace goes to debugPrint so it shows up in `flutter run`'s
      // terminal / `flutter logs`, since a bare exception message
      // alone isn't enough to tell a real "we're offline" from a real
      // parsing bug apart -- see github.com/sharneng/spliit2go/issues/14.
      debugPrint('GroupScreen._refresh failed for group ${widget.groupId}: $e\n$st');
      if (_expenses.isEmpty) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _syncThenRefresh() async {
    // No need to reload from the local cache first anymore (issue #47)
    // -- the outbox's own db writes (markSynced, etc.) already reach
    // [_expensesSub] on their own, synchronously with the write, so
    // there's no gap for _refresh's live fetch below to race against.
    await widget.outbox.flush();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_group?.name ?? 'spliit2go'),
        actions: [
          // Only on the Expenses tab -- there's nothing to search on the
          // other three, same reasoning spliit-ios's own search tab
          // uses (it only ever searches expenses). Just a placeholder
          // for now (issue #38 explicitly deferred the real search
          // feature to issue #39): tapping it says so rather than doing
          // nothing with no feedback at all.
          if (_tabIndex == 0)
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: context.l10n.groupScreenSearchTooltip,
              onPressed: _group == null ? null : _searchPlaceholder,
            ),
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: context.l10n.groupScreenActiveUserTooltip,
            onPressed: _group == null ? null : _pickActiveUser,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: context.l10n.groupScreenSettingsTooltip,
            onPressed: _group == null ? null : _openGroupSettings,
          ),
        ],
      ),
      body: _tabBody(),
      // Adding an expense is only meaningful from the Expenses tab --
      // matches spliit-ios's own toolbarContent, which shows its "Add
      // expense" button only `if tab == .expenses`.
      floatingActionButton: _tabIndex == 0
          ? FloatingActionButton(
              onPressed: _group == null ? null : _openAddExpense,
              child: const Icon(Icons.add),
            )
          : null,
      // Balances/Stats/Activity used to each be a full screen reached by
      // pushing on top of this one from an AppBar icon (issue #38) --
      // by the fourth icon, those buttons left no room for the group's
      // own name in the title bar. Now they're tabs of this same
      // screen, spliit-ios style (GroupDetailView.swift's own TabView:
      // Expenses/Balances/Stats, plus a fourth tab -- Information there,
      // Activities here, per what was actually asked for in this issue).
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.receipt_long_outlined),
            selectedIcon: const Icon(Icons.receipt_long),
            label: context.l10n.groupScreenTabExpenses,
          ),
          NavigationDestination(
            icon: const Icon(Icons.account_balance_wallet_outlined),
            selectedIcon: const Icon(Icons.account_balance_wallet),
            label: context.l10n.groupScreenTabBalance,
          ),
          NavigationDestination(
            icon: const Icon(Icons.bar_chart_outlined),
            selectedIcon: const Icon(Icons.bar_chart),
            label: context.l10n.groupScreenTabStats,
          ),
          NavigationDestination(
              icon: const Icon(Icons.history), label: context.l10n.groupScreenTabActivities),
        ],
      ),
    );
  }

  /// This tab's content, resolved fresh on every switch rather than kept
  /// alive offscreen (no IndexedStack) -- deliberately: it's what
  /// Balances/Stats/Activity already did as pushed screens (each one's
  /// own initState reloaded from the local cache on every visit), and
  /// keeping that "always current when you look at it" behavior across
  /// the push-to-tab conversion mattered more here than preserving
  /// scroll position across tab switches. Each embedded screen watches
  /// the same local db cache directly (issue #47), so no explicit
  /// reload wiring between tabs is needed any more either.
  Widget _tabBody() {
    if (_group == null) {
      return _tabIndex == 0 ? RefreshIndicator(onRefresh: _refresh, child: _body()) : const SizedBox.shrink();
    }
    switch (_tabIndex) {
      case 0:
        return RefreshIndicator(onRefresh: _refresh, child: _body());
      case 1:
        return BalancesScreen(
          key: ValueKey('balances-${_group!.id}'),
          client: widget.client,
          db: widget.db,
          outbox: widget.outbox,
          group: _group!,
          embedded: true,
        );
      case 2:
        return StatsScreen(
          key: ValueKey('stats-${_group!.id}'),
          client: widget.client,
          db: widget.db,
          outbox: widget.outbox,
          group: _group!,
          activeUserId: _activeUserId,
          embedded: true,
        );
      case 3:
        return ActivityScreen(
          key: ValueKey('activity-${_group!.id}'),
          client: widget.client,
          db: widget.db,
          outbox: widget.outbox,
          group: _group!,
          embedded: true,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  /// Issue #38 explicitly scoped the real search feature to a separate
  /// issue (#39) -- this button exists now so the affordance is in
  /// place, but tapping it just says so instead of silently doing
  /// nothing.
  void _searchPlaceholder() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.groupScreenSearchComingSoon)),
    );
  }

  Widget _body() {
    if (_expenses.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_expenses.isEmpty && _error != null) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Icon(Icons.cloud_off, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Center(child: Text(context.l10n.groupScreenServerError(_error!))),
        ],
      );
    }
    if (_expenses.isEmpty) {
      return Center(child: Text(context.l10n.commonNoExpensesYet));
    }
    return ListView.builder(
      itemCount: _expenses.length,
      itemBuilder: (context, i) {
        final e = _expenses[i];
        return ListTile(
          leading: CategoryIconGlyph(category: _categoryFor(e.category)),
          title: Text(e.title),
          // e.date is already a date-only value (year/month/day of the
          // calendar day the expense happened on, not a real instant --
          // see lib/services/date_only.dart) -- no .toLocal() here,
          // that would perform a real timezone conversion on a value
          // that was never one, and roll the date back a day west of
          // UTC. See decisions/date-handling.md.
          subtitle: Text(formatDate(e.date, locale: context.appLocale)),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(formatMoney(e.amountCents, _group?.currency ?? '\$',
                  locale: context.appLocale)),
              if (e.syncFailed)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline,
                        size: 13, color: Theme.of(context).colorScheme.error),
                    const SizedBox(width: 2),
                    Text(context.l10n.groupScreenSyncFailed,
                        style: TextStyle(
                            fontSize: 11, color: Theme.of(context).colorScheme.error)),
                  ],
                )
              else if (e.pending)
                Text(context.l10n.groupScreenSyncing, style: const TextStyle(fontSize: 11)),
            ],
          ),
          // Pending (offline-added, not-yet-synced) rows have no server
          // id to fetch or edit yet -- and no connectivity story for
          // editing an in-flight create -- so editing is only offered
          // once an expense has actually synced. A sync-failed row is a
          // special case of pending (issue #44): tapping it offers
          // retry/delete instead of doing nothing, since it needs a
          // person's attention rather than silently waiting for a flush
          // that will never come (the outbox has already given up on
          // it -- see Outbox.flush's own doc comment).
          onTap: e.syncFailed
              ? () => _showSyncFailureOptions(e)
              : (e.pending ? null : () => _openEditExpense(e)),
        );
      },
    );
  }

  /// Retry/delete for a sync-failed expense (issue #44). Deliberately
  /// doesn't offer "edit" -- this app is explicitly scoped to offline
  /// *view + add* only, never offline edit (decisions/mobile-platform.md),
  /// and a sync-failed row is still just a pending, never-reached-the-
  /// server row; editing it in place would be exactly the offline-edit
  /// feature that decision rules out. Retry re-queues it for the outbox;
  /// Delete discards it locally without ever having synced.
  Future<void> _showSyncFailureOptions(Expense e) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
              title: Text(context.l10n.groupScreenSyncFailureTitle),
              subtitle: e.lastError == null
                  ? null
                  : Text(e.lastError!, maxLines: 3, overflow: TextOverflow.ellipsis),
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: Text(context.l10n.commonRetry),
              onTap: () => Navigator.of(context).pop('retry'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(context.l10n.commonDelete),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'retry':
        // No _loadFromCache() call needed (issue #47) -- [_expensesSub]
        // already reflects retrySyncFailure's write by the time this
        // await returns.
        await widget.db.retrySyncFailure(e.id);
        await _syncThenRefresh();
      case 'delete':
        await widget.db.deleteFailedExpense(e.id);
    }
  }

  /// Opens group settings (rename, currency, participants).
  /// [GroupSettingsScreen] writes any change straight to the local db
  /// via [AppDatabase.cacheGroup] before it pops (issue #47) -- so
  /// [_groupSub] already carries the update back to [_group] by the
  /// time this returns, and there's nothing left for this method to
  /// adopt from the popped result the way it used to.
  Future<void> _openGroupSettings() async {
    await Navigator.of(context).push<Group>(
      MaterialPageRoute(
        builder: (_) => GroupSettingsScreen(
          client: widget.client,
          db: widget.db,
          group: _group!,
        ),
      ),
    );
  }

  Future<void> _openAddExpense() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ExpenseScreen(
          client: widget.client,
          db: widget.db,
          outbox: widget.outbox,
          group: _group!,
          initialPaidBy: _activeUserId,
        ),
      ),
    );
    if (added == true) {
      // ExpenseScreen's own save already wrote the pending row via
      // insertPending, which [_expensesSub] has already picked up by
      // now (issue #47) -- just kick off a sync.
      _syncThenRefresh();
    }
  }

  /// Opens the edit flow for [e] (issue #17) -- online-only, matching
  /// ExpenseScreen's edit mode (see its class doc comment for why:
  /// Spliit's server has no conflict-prevention for edits at all).
  ///
  /// Fetches the expense fresh via [SpliitClient.fetchExpense] first,
  /// rather than editing the possibly-stale locally cached [e] directly --
  /// the smallest mitigation available for that missing server-side
  /// protection is keeping the window between "what's shown" and "what's
  /// on the server" as short as possible. If that fetch fails (most
  /// commonly: offline), editing is refused with an explicit message
  /// instead of silently falling back to the stale cached copy.
  Future<void> _openEditExpense(Expense e) async {
    late final Expense fresh;
    try {
      fresh = await widget.client.fetchExpense(groupId: widget.groupId, expenseId: e.id);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.groupScreenEditNeedsConnection)),
      );
      return;
    }
    if (!mounted) return;

    final edited = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ExpenseScreen(
          client: widget.client,
          db: widget.db,
          outbox: widget.outbox,
          group: _group!,
          existingExpense: fresh,
        ),
      ),
    );
    if (edited == true) {
      _syncThenRefresh();
    }
  }

  /// Resolves who "you" are in *this* group -- see resolveActiveParticipant
  /// and decisions/multi-group-design.md, decision 2. Called after every
  /// db-backed cache/refresh update to [_group] (via [_groupSub]) rather
  /// than being threaded through each individual load path (issue #47):
  /// participants can change, and this group's own stored choice or the
  /// device's default name might newly apply. Never prompts on its own:
  /// an unresolved result just leaves [_activeUserId] null, same as
  /// "nothing set yet" always meant -- resolveDefaultPaidBy in
  /// add-expense already falls back to the first participant, and the
  /// person icon still lets you pick explicitly.
  Future<void> _resolveActiveUser() async {
    if (_group == null) return;
    final row = await widget.db.groupRow(widget.groupId);
    final defaultName = await _settings.defaultActiveUserName();
    final resolution = resolveActiveParticipant(
      storedActiveParticipantId: row?.activeParticipantId,
      defaultActiveUserName: defaultName,
      participants: _group!.participants,
    );
    switch (resolution) {
      case ActiveParticipantAlreadySet(:final participantId):
        if (mounted) setState(() => _activeUserId = participantId);
      case ActiveParticipantAutoMatched(:final participantId):
        await widget.db.setActiveParticipant(widget.groupId, participantId);
        if (mounted) setState(() => _activeUserId = participantId);
      case ActiveParticipantNeedsPrompt():
        break;
    }
  }

  /// Which participant "you" are on this device, for *this* group --
  /// see [_resolveActiveUser] above. Mirrors the web app's own
  /// per-device setting; there's no account system to tie it to
  /// anything more meaningful than "the last person picked for this
  /// group, on this phone".
  // showDialog returns null both when the dialog is dismissed without a
  // choice (tap outside, back button) *and* if "None" popped a literal
  // null -- those need to mean different things (dismiss = no change,
  // "None" = explicitly clear it), so "None" pops this sentinel instead
  // and null is only ever "dismissed, do nothing".
  static const _noneSentinel = '';

  Future<void> _pickActiveUser() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(context.l10n.groupScreenActiveUserDialogTitle),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(_noneSentinel),
            child: Row(
              children: [
                if (_activeUserId == null) const Icon(Icons.check, size: 18),
                if (_activeUserId == null) const SizedBox(width: 8),
                Text(context.l10n.groupScreenActiveUserNone),
              ],
            ),
          ),
          for (final p in _group!.participants)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(p.id),
              child: Row(
                children: [
                  if (_activeUserId == p.id) const Icon(Icons.check, size: 18),
                  if (_activeUserId == p.id) const SizedBox(width: 8),
                  Text(p.name),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null) return; // dismissed without choosing
    final newId = selected == _noneSentinel ? null : selected;
    if (newId == _activeUserId) return;
    await widget.db.setActiveParticipant(widget.groupId, newId);
    if (mounted) setState(() => _activeUserId = newId);
  }
}
