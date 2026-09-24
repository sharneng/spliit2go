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
import '../widgets/expense_list.dart';
import 'expense_details_sheet.dart';
import 'expense_search_screen.dart';
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
      final generation = widget.db.expensesGeneration(widget.groupId);
      final group = await widget.client.fetchGroup(widget.groupId);
      final fresh = await widget.client.fetchExpenses(widget.groupId);
      await widget.db.cacheGroup(group);
      // Skipped if an edit or delete landed while this was fetching (#90).
      await widget.db.replaceServerExpenses(widget.groupId, fresh,
          fetchedAtGeneration: generation);
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
      bottomNavigationBar: _bottomBar(context),
    );
  }

  static const _searchSlotWidth = 64.0;

  /// The tabs plus a separate round search button at the right end, on
  /// every tab, like spliit-ios (issue #84) -- search opens its own
  /// screen rather than being a tab.
  Widget _bottomBar(BuildContext context) {
    final labels = [
      context.l10n.groupScreenTabExpenses,
      context.l10n.groupScreenTabBalance,
      context.l10n.groupScreenTabStats,
      context.l10n.groupScreenTabActivities,
    ];
    return ColoredBox(
      color: NavigationBarTheme.of(context).backgroundColor ??
          Theme.of(context).colorScheme.surfaceContainer,
      // spliit2goAppBuilder already removes these insets app-wide; this
      // keeps the whole row (search included) inside them on its own too.
      child: SafeArea(
        top: false,
        child: LayoutBuilder(builder: (context, constraints) {
          final tabWidth =
              (constraints.maxWidth - _searchSlotWidth) / labels.length;
          return Row(
            children: [
              Expanded(
                child: NavigationBar(
                  selectedIndex: _tabIndex,
                  onDestinationSelected: (i) => setState(() => _tabIndex = i),
                  // Hidden labels stay available as each tab's tooltip.
                  labelBehavior: _labelsFit(context, labels, tabWidth)
                      ? NavigationDestinationLabelBehavior.alwaysShow
                      : NavigationDestinationLabelBehavior.alwaysHide,
                  destinations: [
                    NavigationDestination(
                      icon: const Icon(Icons.receipt_long_outlined),
                      selectedIcon: const Icon(Icons.receipt_long),
                      label: labels[0],
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.account_balance_wallet_outlined),
                      selectedIcon: const Icon(Icons.account_balance_wallet),
                      label: labels[1],
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.bar_chart_outlined),
                      selectedIcon: const Icon(Icons.bar_chart),
                      label: labels[2],
                    ),
                    NavigationDestination(
                        icon: const Icon(Icons.history), label: labels[3]),
                  ],
                ),
              ),
              SizedBox(
                width: _searchSlotWidth,
                child: Center(
                  heightFactor: 1,
                  child: IconButton.filledTonal(
                    icon: const Icon(Icons.search),
                    tooltip: context.l10n.groupScreenSearchTooltip,
                    onPressed: _group == null ? null : _openSearch,
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  /// NavigationBar never ellipsizes a label: one too wide for its tab
  /// wraps mid-word ("Statistiq/ues" in French on a narrow phone), so
  /// labels are measured up front and hidden if any doesn't fit.
  bool _labelsFit(BuildContext context, List<String> labels, double tabWidth) {
    final style = NavigationBarTheme.of(context)
            .labelTextStyle
            ?.resolve({WidgetState.selected}) ??
        Theme.of(context).textTheme.labelMedium;
    // NavigationBar caps label text scaling at 1.3 (its private
    // _kMaxLabelTextScaleFactor); measure the same way.
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      if (width > tabWidth - 8) return false;
    }
    return true;
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
          onPickActiveUser: () => _pickActiveUser(firstAsk: false),
          embedded: true,
        );
      case 3:
        return ActivityScreen(
          key: ValueKey('activity-${_group!.id}'),
          client: widget.client,
          db: widget.db,
          outbox: widget.outbox,
          group: _group!,
          categories: _categories,
          activeUserId: _activeUserId,
          onExpensesChanged: _syncThenRefresh,
          embedded: true,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  /// Opens search (issue #39) over this group's cached expenses.
  Future<void> _openSearch() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ExpenseSearchScreen(
          group: _group!,
          db: widget.db,
          client: widget.client,
          outbox: widget.outbox,
          categories: _categories,
          activeUserId: _activeUserId,
          onExpensesChanged: _syncThenRefresh,
        ),
      ),
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
    return ExpenseDateList(
      expenses: _expenses,
      currency: _group?.currency ?? '\$',
      categoryFor: _categoryFor,
      onTap: _openExpenseDetails,
    );
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

  /// Opens [e]'s details sheet (issue #90) -- view first, with Edit,
  /// Retry and Discard inside it (see showExpenseDetails). An edit saved
  /// there, or a failed expense requeued, gets synced and refreshed.
  Future<void> _openExpenseDetails(Expense e) async {
    final group = _group;
    if (group == null) return;
    final changed = await showExpenseDetails(
      context,
      expenseId: e.id,
      group: group,
      db: widget.db,
      client: widget.client,
      outbox: widget.outbox,
      categories: _categories,
      activeUserId: _activeUserId,
    );
    if (changed && mounted) _syncThenRefresh();
  }

  /// Resolves who "you" are in *this* group -- see resolveActiveParticipant
  /// and decisions/multi-group-design.md, decision 2. Called after every
  /// db-backed cache/refresh update to [_group] (via [_groupSub]) rather
  /// than being threaded through each individual load path (issue #47):
  /// participants can change, and this group's own stored choice or the
  /// device's default name might newly apply. Asks "Who are you?" at
  /// most once per group, ever (issue #85): the answer, even a dismissal,
  /// is stored, so later resolutions never land on NeedsPrompt again.
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
      case ActiveParticipantNobody():
        if (mounted) setState(() => _activeUserId = null);
      case ActiveParticipantNeedsPrompt():
        await _askWhoYouAre();
    }
  }

  // Every group emission (refresh, sync) re-resolves. One landing after
  // the dialog closes but before its answer is saved would otherwise ask
  // again.
  bool _asked = false;

  Future<void> _askWhoYouAre() async {
    if (_asked || !mounted || _group!.participants.isEmpty) return;
    // Not while anything is on top, including the dialog itself; a later
    // emission or visit asks instead.
    if (ModalRoute.of(context)?.isCurrent == false) return;
    _asked = true;
    await _pickActiveUser(firstAsk: true);
  }

  /// Which participant "you" are on this device, for *this* group --
  /// see [_resolveActiveUser] above. Mirrors the web app's own
  /// per-device setting; there's no account system to tie it to
  /// anything more meaningful than "the last person picked for this
  /// group, on this phone". On the first ask, dismissing counts as
  /// "Nobody" so it's never asked again; from Stats it changes nothing.
  Future<void> _pickActiveUser({required bool firstAsk}) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => ActiveUserPicker(
        participants: _group!.participants,
        checkedId: firstAsk ? null : _activeUserId ?? nobodyParticipantId,
      ),
    );
    if (selected == null && !firstAsk) return;
    final stored = selected ?? nobodyParticipantId;
    await widget.db.setActiveParticipant(widget.groupId, stored);
    final newId = stored == nobodyParticipantId ? null : stored;
    // A new device never has a default name, so seed it from the first
    // pick: later groups with that name then match without asking.
    if (newId != null && await _settings.defaultActiveUserName() == null) {
      final picked = _group!.participants.where((p) => p.id == newId);
      if (picked.isNotEmpty) {
        await _settings.setDefaultActiveUserName(picked.first.name);
      }
    }
    if (mounted) setState(() => _activeUserId = newId);
  }
}

/// The "Who are you?" dialog: pops a participant's id, or
/// [nobodyParticipantId] for "Nobody" (listed last).
class ActiveUserPicker extends StatelessWidget {
  const ActiveUserPicker({super.key, required this.participants, this.checkedId});

  final List<Participant> participants;

  /// The option to show checked: a participant's id, [nobodyParticipantId],
  /// or null for none.
  final String? checkedId;

  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      title: Text(context.l10n.groupScreenActiveUserDialogTitle),
      children: [
        for (final p in participants) _option(context, p.id, p.name),
        _option(context, nobodyParticipantId, context.l10n.groupScreenActiveUserNone),
      ],
    );
  }

  Widget _option(BuildContext context, String id, String label) {
    return SimpleDialogOption(
      onPressed: () => Navigator.of(context).pop(id),
      child: Row(
        children: [
          if (checkedId == id) ...[
            const Icon(Icons.check, size: 18),
            const SizedBox(width: 8),
          ],
          // Flexible so a long label wraps at large text sizes.
          Flexible(child: Text(label)),
        ],
      ),
    );
  }
}
