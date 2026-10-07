import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../models/group_organization.dart';
import '../l10n/context_l10n.dart';
import '../services/date_span_calculator.dart';
import '../services/group_list_order.dart';
import '../services/settings_service.dart';
import '../widgets/group_monogram.dart';
import '../widgets/group_row_actions.dart';
import '../sync/outbox.dart';
import '../theme.dart';
import '../utils/date_format.dart';
import '../utils/spoken.dart';
import 'group_screen.dart';
import 'app_settings_screen.dart';
import 'join_group_screen.dart';
import '../services/error_reporting.dart';
import '../services/receipt_cache.dart';
import '../services/receipt_downloader.dart';
import '../widgets/receipt_download_indicator.dart';
import '../widgets/error_message.dart';
import '../widgets/empty_state.dart';
import '../widgets/grouped_section.dart';
import '../utils/haptics.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../widgets/caption_icon.dart';

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
  final SettingsService settings;

  /// Builds the SpliitClient for a tapped group's own serverUrl.
  /// Defaults to a real one; overridable so tests can inject a client
  /// backed by http's MockClient -- same reasoning as
  /// JoinGroupScreen.clientFactory.
  final SpliitClient Function(String serverUrl) clientFactory;

  GroupListScreen(
      {super.key,
      required this.db,
      SpliitClient Function(String)? clientFactory,
      SettingsService? settings})
      : clientFactory = clientFactory ?? ((url) => SpliitClient(baseUrl: url)),
        settings = settings ?? SettingsService();

  @override
  State<GroupListScreen> createState() => _GroupListScreenState();
}

class _GroupListScreenState extends State<GroupListScreen> with RouteAware {
  List<GroupRow> _groups = [];
  bool _loading = true;
  GroupListSort _sort = GroupListSort.lastOpened;
  SettingsService get _settings => widget.settings;
  int _loadVersion = 0;
  final Map<String, int> _dismissVersions = {};

  /// Each joined group's cached first-to-last expense date (issue #55),
  /// keyed by [GroupRow.id] -- loaded alongside [_groups] rather than
  /// lazily per row, so the list doesn't kick off a burst of individual
  /// queries as it scrolls. A group missing from this map (still
  /// loading) or mapped to null (no cached expenses yet) both show '—'
  /// under an expense-date sort.
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
    if (!mounted) return;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Image.asset('assets/spliit2go-logo.png',
              width: 32, height: 32, excludeFromSemantics: true),
          const SizedBox(width: 8),
          const Flexible(
              child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('Spliit2Go',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: spliitWordmarkGreen)))),
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
              MaterialPageRoute(
                  builder: (_) => AppSettingsScreen(receipts: ReceiptCache.of(widget.db))),
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
      return EmptyState.logo(
        title: context.l10n.groupListEmpty,
        actions: [
          FilledButton(
              onPressed: _joinAnother,
              child: Text(context.l10n.groupListEmptyJoinButton)),
        ],
      );
    }
    final sorted = [..._groups]
      ..sort((a, b) => compareGroupRows(a, b, _sort, _dateSpans));
    final sections = [
      (
        context.l10n.groupListFavorites,
        sorted
            .where((g) => g.organization == GroupOrganization.favorite)
            .toList()
      ),
      (
        context.l10n.groupListActive,
        sorted.where((g) => g.organization == GroupOrganization.active).toList()
      ),
      (
        context.l10n.groupListArchived,
        sorted
            .where((g) => g.organization == GroupOrganization.archived)
            .toList()
      ),
    ];
    // The list stops above the gesture bar or navigation buttons (the home
    // indicator on iPhone), through the rounded clip's curve, as the group
    // screen's list stops above its tab bar, rather than scrolling under
    // them to the screen's edge (#222).
    return SlidableAutoCloseBehavior(
        child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
        child: GroupedScrollClip(
        child: ListView(
      // Room at the end for the last row to scroll clear of the add button.
      padding: const EdgeInsets.only(top: 16, bottom: 88),
      children: [
        for (final (caption, groups) in sections)
          if (groups.isNotEmpty) ...[
            GroupedCaption(caption, margin: GroupedCaption.listMargin),
            for (var i = 0; i < groups.length; i++)
              // The card, not the row, so a swipe slides the row within it.
              GroupedItem(
                key: ValueKey(groups[i].id),
                first: i == 0,
                last: i == groups.length - 1,
                // Past the monogram, under the name.
                dividerIndent: 80,
                child: _groupTile(groups[i]),
              ),
          ],
      ],
    ))));
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
    } catch (e, st) {
      _showSaveError(e, st, 'Saving the group list sort');
    }
  }

  /// Local storage failures have no expected cause: logged, with details
  /// behind the snack bar (#119 review).
  void _showSaveError(Object e, StackTrace st, String operation) {
    final error = ErrorReporter.instance.report(e, st, operation: operation);
    if (!mounted) return;
    showErrorSnackBar(context, context.l10n.appSettingsSaveError,
        diagnostics: error.diagnostics);
  }

  Future<bool> _confirmRemove(GroupRow row) async =>
      await showAdaptiveDialog<bool>(
        context: context,
        builder: (context) => AlertDialog.adaptive(
          title: Text(context.l10n.groupListRemove),
          content: Text(context.l10n.groupListLeaveBody(row.name)),
          actions: _removeDialogActions(context),
        ),
      ) ??
      false;

  List<Widget> _removeDialogActions(BuildContext dialogContext) {
    final platform = Theme.of(dialogContext).platform;
    final cupertino =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
    if (cupertino) {
      return [
        CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(dialogContext.l10n.commonCancel)),
        CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(dialogContext.l10n.groupListRemove)),
      ];
    }
    return [
      TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(dialogContext.l10n.commonCancel)),
      TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error),
          child: Text(dialogContext.l10n.groupListRemove)),
    ];
  }

  Future<void> _performGroupAction(GroupRow row, String action) async {
    if (!mounted) return;
    _dismissVersions[row.id] = (_dismissVersions[row.id] ?? 0) + 1;
    try {
      switch (action) {
        case 'favorite':
          final favorite = row.organization != GroupOrganization.favorite;
          await widget.db.setGroupOrganization(
              row.id, favorite ? GroupOrganization.favorite : GroupOrganization.active);
          // A favorite's receipts download ahead for offline (#127).
          await _favoriteChanged(row, favorite);
        case 'archive':
          await widget.db.setGroupOrganization(
              row.id,
              row.organization == GroupOrganization.archived
                  ? GroupOrganization.active
                  : GroupOrganization.archived);
          // Archiving a favorite ends it being one.
          if (row.organization == GroupOrganization.favorite) await _favoriteChanged(row, false);
        case 'remove':
          if (!await _confirmRemove(row)) return;
          ReceiptDownloader.of(widget.db).removed(row.id);
          await widget.db.leaveGroup(row.id);
          unawaited(Haptics.deleted());
          unawaited(ReceiptCache.of(widget.db).sweep());
      }
    } catch (e, st) {
      _showSaveError(e, st, 'Updating group ${row.id}');
    } finally {
      if (mounted) await _load(); // Always rebuild with the fresh key
    }
  }

  Future<void> _favoriteChanged(GroupRow row, bool favorite) async {
    final downloads = ReceiptDownloader.of(widget.db);
    if (favorite) {
      unawaited(downloads.run(row.id, widget.clientFactory(row.serverUrl)));
    } else {
      await downloads.unfavorited(row.id);
    }
  }

  /// [row]'s [groupSortDate], or '—' while it has none (#201). Expense
  /// dates are date-only values shown as they are; creation and last
  /// opened are real moments, shown on the local calendar.
  String _sortDateText(GroupRow row) {
    final date = groupSortDate(row, _sort, _dateSpans);
    if (date == null) return '—';
    final local = switch (_sort) {
      GroupListSort.firstExpense || GroupListSort.lastExpense => date,
      GroupListSort.created || GroupListSort.lastOpened => date.toLocal(),
    };
    return formatDate(local, locale: context.appLocale);
  }

  static const _nameStyle = TextStyle(fontWeight: FontWeight.w600);

  /// [row]'s date as a screen reader says it: what the date is, since a
  /// listener can't glance at the sort menu (#209). Nothing for a moment
  /// the group doesn't have.
  String? _spokenSortDate(GroupRow row) {
    final l10n = context.l10n;
    final date = groupSortDate(row, _sort, _dateSpans);
    if (date == null) {
      return switch (_sort) {
        GroupListSort.firstExpense || GroupListSort.lastExpense => l10n.groupListSpokenNoExpenses,
        GroupListSort.created || GroupListSort.lastOpened => null,
      };
    }
    final text = _sortDateText(row);
    return switch (_sort) {
      GroupListSort.firstExpense => l10n.groupListSpokenFirstExpense(text),
      GroupListSort.lastExpense => l10n.groupListSpokenLastExpense(text),
      GroupListSort.created => l10n.groupListSpokenCreated(text),
      GroupListSort.lastOpened => l10n.groupListSpokenOpened(text),
    };
  }

  Widget _groupTile(GroupRow row) {
    final count = (jsonDecode(row.participantsJson) as List).length;
    final downloads = ReceiptDownloader.of(widget.db);
    void retryDownloads() =>
        unawaited(downloads.run(row.id, widget.clientFactory(row.serverUrl)));
    final actions = [
      GroupRowAction(
          label: row.organization == GroupOrganization.favorite
              ? context.l10n.groupListUnfavorite
              : context.l10n.groupListFavorite,
          icon: row.organization == GroupOrganization.favorite
              ? Icons.star_border
              : Icons.star,
          onSelected: () => _performGroupAction(row, 'favorite')),
      GroupRowAction(
          label: row.organization == GroupOrganization.archived
              ? context.l10n.groupListUnarchive
              : context.l10n.groupListArchive,
          icon: row.organization == GroupOrganization.archived
              ? Icons.unarchive_outlined
              : Icons.archive_outlined,
          onSelected: () => _performGroupAction(row, 'archive')),
      GroupRowAction(
          label: context.l10n.groupListRemove,
          icon: Icons.delete_outline,
          destructive: true,
          onSelected: () => _performGroupAction(row, 'remove')),
    ];
    final spokenDate = _spokenSortDate(row);
    final spoken = spokenSentences([
      row.name,
      if (spokenDate != null) spokenDate,
      context.l10n.groupListParticipantCount(count),
    ], context.l10n.spokenSentenceEnd);
    // The clip and its tap area, laid over the row (#209).
    final clip = ReceiptRowClip();
    return GroupRowActions(
      // Guarantees a fresh widget identity whenever onDismissed runs:
      key: ValueKey('${row.id}_${_dismissVersions[row.id] ?? 0}'),
      actions: actions,
      builder: (context, openMenu) => Stack(children: [
        ListTile(
          // A tighter gap before the chevron (#201 review); the monogram's
          // padding keeps the name at 80.
          horizontalTitleGap: 8,
          leading: Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: Semantics(
              button: true,
              label: context.l10n.groupListActions(row.name),
              child: Tooltip(
                  message: context.l10n.groupListActions(row.name),
                  child: InkResponse(
                      onTap: openMenu,
                      radius: 24,
                      child: SizedBox(
                          width: 48,
                          height: 48,
                          child: Center(
                              child:
                                  GroupMonogram(id: row.id, name: row.name))))))),
          // The clip and the date sit at the right edge, next to the
          // chevron (#201 review).
          title: Semantics(
            // Read as sentences, the date named (#209). The swipe actions
            // are the screen reader's actions too, rather than only behind
            // the monogram's menu.
            label: spoken,
            customSemanticsActions: {
              for (final action in actions)
                CustomSemanticsAction(label: action.label): action.onSelected,
            },
            excludeSemantics: true,
            child: LayoutBuilder(builder: (context, constraints) {
              // The clip grows with the text size only as far as leaves the
              // name's longest word a line of its own (#209).
              final style = DefaultTextStyle.of(context).style.merge(_nameStyle);
              final longestWord = row.name
                  .split(' ')
                  .map((word) => (TextPainter(
                          text: TextSpan(text: word, style: style),
                          textDirection: Directionality.of(context),
                          textScaler: MediaQuery.textScalerOf(context),
                          maxLines: 1)
                        ..layout())
                      .width)
                  .fold(0.0, (a, b) => a > b ? a : b);
              return Row(children: [
                // Bold, like a list title on iOS (#201 review).
                Expanded(child: Text(row.name, style: _nameStyle)),
                // A favorite's receipts offline (#127).
                ReceiptDownloadIndicator(
                  row: clip,
                  status: downloads.status(row.id),
                  onRetry: retryDownloads,
                  maxRowSize: constraints.maxWidth - longestWord - 1,
                ),
              ]);
            }),
          ),
          subtitle: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LayoutBuilder(
                  builder: (context, constraints) =>
                      _caption(context, constraints.maxWidth, _sortDateText(row), count)),
            ),
          ),
          // Opens the group's screen (#186 review).
          trailing: GroupedRow.chevron(context),
          onTap: () => _openGroup(row),
          onLongPress: openMenu,
        ),
        Positioned(
          top: 0,
          left: 0,
          child: ReceiptDownloadTapArea(
              row: clip, status: downloads.status(row.id), onRetry: retryDownloads),
        ),
      ]),
    );
  }

  /// The date the list is sorted by, not the first-to-last span, which
  /// didn't fit (#201); the count at the right edge, under the clip,
  /// number first (#201 review). When both don't fit one line (a large
  /// text size), the date gets its own and the count goes under it,
  /// still at the edge; the date is never broken, only shrunk (#209).
  Widget _caption(BuildContext context, double maxWidth, String dateText, int count) {
    final style = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    double widthOf(String text) => (TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: Directionality.of(context),
            textScaler: scaler,
            maxLines: 1)
          ..layout())
        .width;
    final icon = captionIconSize(context);
    final fits = icon + 4 + widthOf(dateText) + 12 + widthOf('$count') + 4 + icon <= maxWidth;
    final date = Row(mainAxisSize: MainAxisSize.min, children: [
      const CaptionIcon(LucideIcons.calendar),
      const SizedBox(width: 4),
      Flexible(
          child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(dateText, maxLines: 1, softWrap: false))),
    ]);
    final people = Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$count'),
      const SizedBox(width: 4),
      const CaptionIcon(LucideIcons.users),
    ]);
    if (fits) {
      return Row(children: [Expanded(child: date), const SizedBox(width: 12), people]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Align(alignment: AlignmentDirectional.centerStart, child: date),
      const SizedBox(height: 2),
      Align(alignment: AlignmentDirectional.centerEnd, child: people),
    ]);
  }
}
