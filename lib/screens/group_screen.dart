import 'dart:async';

import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/context_l10n.dart';
import '../models/category.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../services/active_user.dart';
import '../services/category_store.dart';
import '../services/group_url.dart';
import '../services/settings_service.dart';
import '../sync/outbox.dart';
import '../widgets/expense_list.dart';
import '../widgets/bottom_inset.dart';
import 'expense_details_sheet.dart';
import 'expense_search_screen.dart';
import 'expense_screen.dart';
import 'activity_screen.dart';
import 'balances_screen.dart';
import 'group_settings_screen.dart';
import 'stats_screen.dart';
import '../widgets/error_message.dart';
import '../services/error_reporting.dart';
import '../services/receipt_cache.dart';
import '../services/receipt_downloader.dart';
import '../widgets/receipt_download_indicator.dart';
import '../widgets/empty_state.dart';
import '../widgets/grouped_section.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../app_name.dart';
import '../widgets/app_menu.dart';
import '../widgets/top_bar_buttons.dart';
import '../widgets/active_user_sheet.dart';

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

  /// Opens the system share sheet for a group's link (issue #3); tests
  /// inject a recorder instead of the platform plugin.
  final Future<void> Function(Uri link, String? subject) shareLink;

  /// The platform's connectivity changes; tests inject their own.
  final Stream<List<ConnectivityResult>>? connectivityChanges;

  const GroupScreen({
    super.key,
    required this.client,
    required this.db,
    required this.outbox,
    required this.groupId,
    this.shareLink = shareWithSystemSheet,
    @visibleForTesting this.connectivityChanges,
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
  String? _errorDiagnostics;
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

  /// Cancelled with the screen: left running, reconnecting after the
  /// group was closed synced and refreshed a screen that was gone.
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  // Which of the four bottom-nav tabs is showing (issue #38 -- replaces
  // the old design where Balances/Stats/Activity were each a full
  // pushed screen reached from an AppBar icon, which by the fourth icon
  // left no room for the group's own name). 0 = Expenses, matching this
  // screen's original default (and only) content.
  int _tabIndex = 0;

  // The server's list as last read, or Spliit's seeded one until this
  // device has read it (#132), so the list shows real category icons
  // (issue #28) offline too. An id in neither still gets the fallback
  // banknote glyph (see categoryIconData's own default).
  List<Category> _categories = spliitSeedCategories;
  StreamSubscription<List<Category>>? _categoriesSub;

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
    _categoriesSub = CategoryStore.of(widget.db).watch(widget.client).listen((cats) {
      if (mounted) setState(() => _categories = cats);
    });
    _refresh();
    // Guarded: connectivity_plus's platform channel isn't set up in every
    // environment (widget tests being the immediate reason this got
    // added, but a misconfigured platform is a real possibility too).
    // Losing this listener only means sync falls back to pull-to-refresh
    // and the right-after-adding trigger, rather than crashing the screen.
    try {
      _connectivitySub =
          (widget.connectivityChanges ?? Connectivity().onConnectivityChanged).listen(
        (results) {
          if (!results.contains(ConnectivityResult.none)) {
            _syncThenRefresh();
          }
        },
        onError: (Object e, StackTrace st) =>
            ErrorReporter.instance.report(e, st, operation: 'Watching connectivity'),
      );
    } catch (e, st) {
      // No plugin here (widget tests) is expected; anything else isn't.
      if (!isMissingPlugin(e)) {
        ErrorReporter.instance.report(e, st, operation: 'Watching connectivity');
      }
    }
  }

  @override
  void dispose() {
    _groupSub?.cancel();
    _expensesSub?.cancel();
    _categoriesSub?.cancel();
    _connectivitySub?.cancel();
    super.dispose();
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
    // Called after awaits elsewhere (a sync first): the screen may have
    // closed meanwhile.
    if (!mounted) return;
    setState(() => _loading = true);
    // Once per run; again on the next refresh if it didn't get through.
    unawaited(CategoryStore.of(widget.db).refresh(widget.client));
    try {
      final generation = widget.db.expensesGeneration(widget.groupId);
      final group = await widget.client.fetchGroup(widget.groupId);
      final fresh = await widget.client.fetchExpenses(widget.groupId);
      await widget.db.cacheGroup(group);
      // Skipped if an edit or delete landed while this was fetching (#90).
      await widget.db.replaceServerExpenses(widget.groupId, fresh,
          fetchedAtGeneration: generation);
      // Receipt files the refresh stopped referring to (#123).
      unawaited(ReceiptCache.of(widget.db).sweep());
      // A favorite's receipts, ahead for offline (#127); in the
      // background, so the refresh doesn't wait.
      unawaited(ReceiptDownloader.of(widget.db).run(widget.groupId, widget.client));
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
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Refreshing group ${widget.groupId}');
      if (_expenses.isEmpty && mounted) {
        setState(() {
          _error = errorMessageFor(context, error,
              unexpected: context.l10n.groupScreenServerError,
              userMessage: (e) =>
                  e is GroupNotFoundException ? context.l10n.groupScreenGroupGone : null);
          _errorDiagnostics = error.diagnostics;
        });
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
        title: Text(_group?.name ?? appName),
        // A meatballs menu, like spliit-ios's group toolbar (issue #3):
        // group settings, and sharing the group's link. Room for more
        // later (a QR code).
        actions: [
          ReceiptDownloadIndicator(
            status: ReceiptDownloader.of(widget.db).status(widget.groupId),
            onRetry: () =>
                unawaited(ReceiptDownloader.of(widget.db).run(widget.groupId, widget.client)),
          ),
          TopBarButtons(children: [
          AppMenuButton(
            icon: const Icon(Icons.more_horiz),
            tooltip: context.l10n.groupScreenMenuTooltip,
            items: [
              AppMenuItem(
                label: context.l10n.groupScreenMenuSettings,
                icon: Icons.settings_outlined,
                enabled: _group != null,
                onSelected: _openGroupSettings,
              ),
              AppMenuItem(
                label: context.l10n.groupScreenMenuShare,
                icon: Icons.adaptive.share,
                onSelected: _shareGroup,
              ),
            ],
          ),
          ]),
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

  /// The bar's distance from the screen's sides, as the cards' (#197).
  static const _barInset = GroupedSection.inset;

  /// The tabs, and Search at the end, in a rounded bar floating off the
  /// screen's edges, like spliit-ios's (#197). The list stops above it,
  /// through the rounded clip's curve (#193), rather than scrolling behind
  /// it (#198 review). Search opens its own screen rather than being a tab
  /// (#84), so it's never the selected one.
  Widget _bottomBar(BuildContext context) {
    final labels = [
      context.l10n.groupScreenTabExpenses,
      context.l10n.groupScreenTabBalance,
      context.l10n.groupScreenTabStats,
      context.l10n.groupScreenTabActivities,
      context.l10n.groupScreenSearchTooltip,
    ];
    final scheme = Theme.of(context).colorScheme;
    final insets = MediaQuery.paddingOf(context);
    return Padding(
      // 12 above it: the list's rounded end stands off the bar.
      padding: EdgeInsets.fromLTRB(insets.left + _barInset, 12, insets.right + _barInset,
          bottomBarGap(context)),
      child: Material(
        // The cards' color, so it reads as one of them (#215), lifted
        // off the page by a shadow.
        color: GroupedSection.cardColor(context),
        elevation: 3,
        shadowColor: scheme.shadow,
        surfaceTintColor: Colors.transparent,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        // The bar is already placed clear of every inset, so NavigationBar
        // mustn't pad itself again (it would add the status bar's).
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          removeBottom: true,
          removeLeft: true,
          removeRight: true,
          // Off the rounded ends, so the end tabs sit well inside the curve.
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LayoutBuilder(builder: (context, constraints) {
            final tabWidth = constraints.maxWidth / labels.length;
            return NavigationBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              height: 68,
              selectedIndex: _tabIndex,
              onDestinationSelected: (i) {
                if (i == labels.length - 1) {
                  _openSearch();
                } else {
                  setState(() => _tabIndex = i);
                }
              },
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
                NavigationDestination(icon: const Icon(Icons.history), label: labels[3]),
                NavigationDestination(
                  icon: const Icon(Icons.search),
                  label: labels[4],
                  enabled: _group != null,
                ),
              ],
            );
          }),
          ),
        ),
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
          activeUserId: _activeUserId,
          onPickActiveUser: () => _pickActiveUser(firstAsk: false),
          embedded: true,
        );
      case 2:
        return StatsScreen(
          key: ValueKey('stats-${_group!.id}'),
          client: widget.client,
          db: widget.db,
          outbox: widget.outbox,
          group: _group!,
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
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ErrorMessage(_error!,
                  diagnostics: _errorDiagnostics, textAlign: TextAlign.center),
            ),
          ),
        ],
      );
    }
    if (_expenses.isEmpty) {
      return EmptyState(icon: LucideIcons.receiptText, title: context.l10n.commonNoExpensesYet);
    }
    return ExpenseDateList(
      expenses: _expenses,
      currency: _group?.currency ?? '\$',
      decimalDigits: _group?.decimalDigits ?? 2,
      categoryFor: _categoryFor,
      participants: _group?.participants ?? const [],
      activeUserId: _activeUserId,
      onTap: _openExpenseDetails,
      // Clear of the add button, as the group list is.
      bottomPadding: 88,
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

  /// Shares `<server>/groups/<id>` (issue #3): the link the web app gives
  /// out, on this group's own server, so it opens for anyone, in a browser
  /// or in the app. Works offline: it only needs what this screen was
  /// opened with.
  Future<void> _shareGroup() =>
      widget.shareLink(groupShareLink(widget.client.baseUrl, widget.groupId), _group?.name);

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
    final defaultName = await _settings.defaultActiveUserName();
    if (!mounted) return;
    final choice = await showActiveUserSheet(
      context,
      participants: _group!.participants,
      checkedId: firstAsk ? null : _activeUserId ?? nobodyParticipantId,
      defaultName: defaultName,
    );
    if (choice == null && !firstAsk) return;
    final stored = choice?.participantId ?? nobodyParticipantId;
    await widget.db.setActiveParticipant(widget.groupId, stored);
    final newId = stored == nobodyParticipantId ? null : stored;
    // The device's default name picks you in groups opened later; the
    // sheet asks whether this pick sets it, on by default only while it's
    // unset (#218).
    if (newId != null && choice!.rememberName) {
      final picked = _group!.participants.where((p) => p.id == newId);
      if (picked.isNotEmpty) {
        await _settings.setDefaultActiveUserName(picked.first.name);
      }
    }
    if (mounted) setState(() => _activeUserId = newId);
  }
}

/// The platform share sheet, via share_plus: the link as a URL, so iOS
/// shows the page's preview; Android shares it as text. The group's name
/// goes along as the subject, for email and the like.
Future<void> shareWithSystemSheet(Uri link, String? subject) async {
  await SharePlus.instance.share(ShareParams(uri: link, subject: subject));
}

