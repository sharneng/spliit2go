import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/context_l10n.dart';
import '../services/date_span_calculator.dart';
import '../services/group_list_order.dart';
import '../services/settings_service.dart';
import '../widgets/group_monogram.dart';
import '../sync/outbox.dart';
import '../utils/date_format.dart';
import 'group_screen.dart';
import 'app_settings_screen.dart';
import 'join_group_screen.dart';

/// Registered as a `MaterialApp.navigatorObservers` entry (main.dart) so
/// [_GroupListScreenState] can hear about routes pushed *on top of* it by
/// something other than its own [_openGroup] -- specifically _Root's own
/// auto-open-last-group push (main.dart#_Root) -- and refresh when
/// popping back reveals this screen again (issue #57). A one-shot
/// [_load] alone only ever re-ran after *this* screen's own row taps.
final RouteObserver<PageRoute<void>> groupListRouteObserver =
    RouteObserver<PageRoute<void>>();

/// Every group this device has joined -- the app's true root (see
/// main.dart#_Root), always reachable via GroupScreen's normal back
/// arrow, rather than something GroupScreen pushes you into. "Launch
/// straight into the last-used group" (decisions/multi-group-design.md,
/// decision 3) is done by _Root pushing that group's GroupScreen on top
/// of this screen right after it mounts -- not by skipping this screen
/// -- specifically so there's always a real group to back out *to*, even
/// right after a fresh install or after leaving the group you were just
/// viewing (github.com/sharneng/spliit2go/issues/12).
///
/// Each row builds its own SpliitClient/Outbox from that group's own
/// cached server URL when opened -- multi-group support means the
/// server is per-group now, not a single app-wide value, so this screen
/// deliberately doesn't hold one client for everything.
class GroupListScreen extends StatefulWidget {
  final AppDatabase db;

  /// Builds the SpliitClient for a tapped group's own serverUrl.
  /// Defaults to a real one; overridable so tests can inject a client
  /// backed by http's MockClient -- same reasoning as
  /// JoinGroupScreen.clientFactory.
  final SpliitClient Function(String serverUrl) clientFactory;

  GroupListScreen(
      {super.key,
      required this.db,
      SpliitClient Function(String)? clientFactory})
      : clientFactory = clientFactory ?? ((url) => SpliitClient(baseUrl: url));

  @override
  State<GroupListScreen> createState() => _GroupListScreenState();
}

class _GroupListScreenState extends State<GroupListScreen> with RouteAware {
  List<GroupRow> _groups = [];
  bool _loading = true;
  GroupListSort _sort = GroupListSort.lastOpened;
  final _settings = SettingsService();
  int _loadVersion = 0;

  /// Each joined group's cached first-to-last expense date (issue #55),
  /// keyed by [GroupRow.id] -- loaded alongside [_groups] rather than
  /// lazily per row, so the list doesn't kick off a burst of individual
  /// queries as it scrolls. A group missing from this map (still
  /// loading) or mapped to null (no cached expenses yet) both render
  /// via [formatDateSpan]'s own null handling.
  Map<String, DateSpan?> _dateSpans = {};

  /// Still a one-shot fetch, not a live subscription -- issue #57's
  /// review found that AppDatabase.watchExpensesForGroup wired up one
  /// subscription per joined group here caused "A Timer is still
  /// pending even after the widget tree was disposed" test failures and
  /// an actual hang in the local CI loop, in ways not pinned down well
  /// enough to ship. [didPopNext] below covers the staleness case that
  /// motivated it (a route pushed on top of this screen by something
  /// other than [_openGroup]) without needing a live stream at all.
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) {
      groupListRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    groupListRouteObserver.unsubscribe(this);
    super.dispose();
  }

  /// [RouteAware]: fires when a route pushed on top of this one (by
  /// anything -- _Root's own auto-open push, this screen's own
  /// [_openGroup], anything else) is popped and this screen becomes the
  /// top route again. Refreshes so a date span changed while that other
  /// route was in front (issue #57) isn't left stale.
  @override
  void didPopNext() {
    _load();
  }

  Future<void> _load() async {
    final version = ++_loadVersion;
    final sort = groupListSortFromTag(await _settings.groupListSort());
    final rows = await widget.db.allJoinedGroups();
    final spans = <String, DateSpan?>{};
    for (final row in rows) {
      spans[row.id] = computeDateSpan(await widget.db.expensesForGroup(row.id));
    }
    if (!mounted || version != _loadVersion) return;
    setState(() {
      _sort = sort;
      _groups = rows;
      _dateSpans = spans;
      _loading = false;
    });
  }

  Future<void> _openGroup(GroupRow row) async {
    await widget.db.recordGroupOpened(row.id, serverUrl: row.serverUrl);
    final client = widget.clientFactory(row.serverUrl);
    final outbox = Outbox(widget.db, client, groupId: row.id);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GroupScreen(
            client: client, db: widget.db, outbox: outbox, groupId: row.id),
      ),
    );
    await _load();
  }

  Future<void> _joinAnother() async {
    final joinedId = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => JoinGroupScreen(db: widget.db)),
    );
    if (joinedId != null) {
      await _load();
    }
  }

  Future<void> _leaveGroup(GroupRow row) async {
    await widget.db.leaveGroup(row.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Image.asset('assets/spliit-logo.png',
              width: 28, height: 28, excludeFromSemantics: true),
          const SizedBox(width: 8),
          const Flexible(
              child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('SPLIIT2GO',
                      style: TextStyle(fontWeight: FontWeight.w700)))),
        ]),
        actions: [
          PopupMenuButton<GroupListSort>(
            tooltip: context.l10n.groupListSort,
            icon: const Icon(Icons.sort),
            initialValue: _sort,
            onSelected: _setSort,
            itemBuilder: (context) => [
              for (final sort in GroupListSort.values)
                CheckedPopupMenuItem(
                    value: sort,
                    checked: sort == _sort,
                    child: Text(_sortLabel(sort))),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: context.l10n.appSettingsTitle,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AppSettingsScreen()),
            ),
          ),
        ],
      ),
      body: _body(context),
      floatingActionButton: FloatingActionButton(
        onPressed: _joinAnother,
        tooltip: context.l10n.groupListJoinTooltip,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_groups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(context.l10n.groupListEmpty),
              const SizedBox(height: 12),
              FilledButton(
                  onPressed: _joinAnother,
                  child: Text(context.l10n.groupListEmptyJoinButton)),
            ],
          ),
        ),
      );
    }
    final sorted = [..._groups]
      ..sort((a, b) => compareGroupRows(a, b, _sort, _dateSpans));
    final sections = [
      (
        context.l10n.groupListFavorites,
        sorted.where((g) => g.isFavorite && !g.isArchived).toList()
      ),
      (
        context.l10n.groupListActive,
        sorted.where((g) => !g.isFavorite && !g.isArchived).toList()
      ),
      (
        context.l10n.groupListArchived,
        sorted.where((g) => g.isArchived).toList()
      ),
    ];
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        for (final section in sections)
          if (section.$2.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(section.$1,
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            for (var i = 0; i < section.$2.length; i++) ...[
              _groupTile(section.$2[i]),
              if (i < section.$2.length - 1)
                const Divider(height: 1, indent: 72, endIndent: 16),
            ],
          ],
      ],
    );
  }

  String _sortLabel(GroupListSort sort) => switch (sort) {
        GroupListSort.firstExpense => context.l10n.groupListSortFirst,
        GroupListSort.lastExpense => context.l10n.groupListSortLast,
        GroupListSort.created => context.l10n.groupListSortCreated,
        GroupListSort.lastOpened => context.l10n.groupListSortOpened,
      };

  Future<void> _setSort(GroupListSort sort) async {
    try {
      await _settings.setGroupListSort(sort.name);
      if (mounted) await _load();
    } catch (_) {
      _showSaveError();
    }
  }

  void _showSaveError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.appSettingsSaveError)));
  }

  Future<bool> _confirmRemove(GroupRow row) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.groupListRemove),
          content: Text(context.l10n.groupListLeaveBody(row.name)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(context.l10n.commonCancel)),
            TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error),
                child: Text(context.l10n.groupListRemove)),
          ],
        ),
      ) ??
      false;

  Future<void> _showGroupMenu(GroupRow row) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
          child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
              leading: Icon(row.isFavorite ? Icons.star_border : Icons.star),
              title: Text(row.isFavorite
                  ? context.l10n.groupListUnfavorite
                  : context.l10n.groupListFavorite),
              onTap: () => Navigator.pop(context, 'favorite')),
          ListTile(
              leading: Icon(row.isArchived
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined),
              title: Text(row.isArchived
                  ? context.l10n.groupListUnarchive
                  : context.l10n.groupListArchive),
              onTap: () => Navigator.pop(context, 'archive')),
          ListTile(
              leading: const Icon(Icons.delete_outline),
              textColor: Theme.of(context).colorScheme.error,
              iconColor: Theme.of(context).colorScheme.error,
              title: Text(context.l10n.groupListRemove),
              onTap: () => Navigator.pop(context, 'remove')),
        ],
      )),
    );
    if (!mounted || action == null) return;
    try {
      switch (action) {
        case 'favorite':
          await widget.db
              .setGroupOrganization(row.id, favorite: !row.isFavorite);
        case 'archive':
          await widget.db
              .setGroupOrganization(row.id, archived: !row.isArchived);
        case 'remove':
          if (!await _confirmRemove(row)) return;
          await widget.db.leaveGroup(row.id);
      }
      if (mounted) await _load();
    } catch (_) {
      _showSaveError();
    }
  }

  Widget _groupTile(GroupRow row) {
    final count = (jsonDecode(row.participantsJson) as List).length;
    return Dismissible(
      key: ValueKey(row.id),
      direction: DismissDirection.endToStart,
      background: Container(
          color: Theme.of(context).colorScheme.error,
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Icon(Icons.delete_outline,
              color: Theme.of(context).colorScheme.onError)),
      confirmDismiss: (_) => _confirmRemove(row),
      onDismissed: (_) => _leaveGroup(row),
      child: ListTile(
        leading: GroupMonogram(id: row.id, name: row.name),
        title: Text(row.name),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(spacing: 12, runSpacing: 4, children: [
            Semantics(
                label: context.l10n.groupListParticipantCount(count),
                excludeSemantics: true,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.people_outline, size: 14),
                  const SizedBox(width: 4),
                  Text('$count'),
                ])),
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.calendar_today_outlined, size: 14),
              const SizedBox(width: 4),
              Flexible(
                  child: Text(formatDateSpan(_dateSpans[row.id],
                      locale: context.appLocale))),
            ]),
          ]),
        ),
        onTap: () => _openGroup(row),
        onLongPress: () => _showGroupMenu(row),
      ),
    );
  }
}
