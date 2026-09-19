import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/context_l10n.dart';
import '../services/date_span_calculator.dart';
import '../sync/outbox.dart';
import '../utils/date_format.dart';
import 'group_screen.dart';
import 'app_settings_screen.dart';
import 'join_group_screen.dart';

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

class _GroupListScreenState extends State<GroupListScreen> {
  List<GroupRow> _groups = [];
  bool _loading = true;

  /// Each joined group's cached first-to-last expense date (issue #55),
  /// keyed by [GroupRow.id] -- loaded alongside [_groups] rather than
  /// lazily per row, so the list doesn't kick off a burst of individual
  /// queries as it scrolls. A group missing from this map (still
  /// loading) or mapped to null (no cached expenses yet) both render
  /// via [formatDateSpan]'s own null handling.
  Map<String, DateSpan?> _dateSpans = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await widget.db.allJoinedGroups();
    final spans = <String, DateSpan?>{};
    for (final row in rows) {
      spans[row.id] = computeDateSpan(await widget.db.expensesForGroup(row.id));
    }
    if (!mounted) return;
    setState(() {
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
        title: Text(context.l10n.groupListTitle),
        actions: [
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
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: _groups.length,
      itemBuilder: (context, i) {
        final row = _groups[i];
        return Dismissible(
          key: ValueKey(row.id),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Theme.of(context).colorScheme.error,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Icon(Icons.delete_outline,
                color: Theme.of(context).colorScheme.onError),
          ),
          confirmDismiss: (_) => showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(context.l10n.groupListLeaveTitle),
              content: Text(context.l10n.groupListLeaveBody(row.name)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(context.l10n.commonCancel),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text(context.l10n.groupListLeaveConfirm),
                ),
              ],
            ),
          ),
          onDismissed: (_) => _leaveGroup(row),
          child: ListTile(
            title: Text(row.name),
            // Date span right after the currency symbol (issue #55).
            subtitle: Text('${row.currency}  ${formatDateSpan(_dateSpans[row.id])}'),
            onTap: () => _openGroup(row),
          ),
        );
      },
    );
  }
}
