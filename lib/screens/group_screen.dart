import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../services/active_user.dart';
import '../services/settings_service.dart';
import '../sync/outbox.dart';
import 'add_expense_screen.dart';
import 'balances_screen.dart';
import 'group_settings_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _loadGroupFromCache();
    _loadFromCache();
    _refresh();
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

  /// Loads whatever group info (name, participants) was cached from the
  /// last successful fetchGroup(), if any. This is what lets the add
  /// button work on a cold, offline start -- without it, [_group] only
  /// ever came from a live fetchGroup() in [_refresh], which throws when
  /// offline and leaves it null (and the add button disabled) forever,
  /// even though the expense list loads fine from its own cache.
  Future<void> _loadGroupFromCache() async {
    final cached = await widget.db.cachedGroup(widget.groupId);
    if (!mounted || cached == null) return;
    setState(() => _group = cached);
    await _resolveActiveUser();
  }

  Future<void> _loadFromCache() async {
    final rows = await widget.db.expensesForGroup(widget.groupId);
    if (!mounted) return;
    setState(() => _expenses = rows.map(widget.db.rowToExpense).toList());
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final group = await widget.client.fetchGroup(widget.groupId);
      final fresh = await widget.client.fetchExpenses(widget.groupId);
      await widget.db.cacheGroup(group);
      await widget.db.replaceServerExpenses(widget.groupId, fresh);
      if (!mounted) return;
      setState(() {
        _group = group;
        _error = null;
      });
      await _loadFromCache();
      await _resolveActiveUser();
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
    final synced = await widget.outbox.flush();
    // Reload from the local cache first, regardless of what happens next --
    // the outbox already deleted any newly-synced rows from the local db,
    // so this alone clears their "syncing..." badge even if the live
    // refresh below fails (e.g. a transient server error unrelated to the
    // sync itself). Without this, a refresh failure could leave a
    // genuinely-synced expense stuck showing as pending.
    if (synced > 0) await _loadFromCache();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_group?.name ?? 'spliit2go'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'Active user',
            onPressed: _group == null ? null : _pickActiveUser,
          ),
          IconButton(
            icon: const Icon(Icons.account_balance_wallet_outlined),
            tooltip: 'Balances',
            onPressed: _group == null ? null : _openBalances,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Group settings',
            onPressed: _group == null ? null : _openGroupSettings,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _body(),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _group == null ? null : _openAddExpense,
        child: const Icon(Icons.add),
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
          Center(child: Text('Couldn\'t reach the server: $_error')),
        ],
      );
    }
    if (_expenses.isEmpty) {
      return const Center(child: Text('No expenses yet.'));
    }
    return ListView.builder(
      itemCount: _expenses.length,
      itemBuilder: (context, i) {
        final e = _expenses[i];
        return ListTile(
          title: Text(e.title),
          subtitle: Text('${e.date.toLocal()}'.split(' ').first),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('\$${(e.amountCents / 100).toStringAsFixed(2)}'),
              if (e.pending)
                const Text('syncing…', style: TextStyle(fontSize: 11)),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openBalances() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BalancesScreen(
          client: widget.client,
          db: widget.db,
          outbox: widget.outbox,
          group: _group!,
        ),
      ),
    );
    // A settlement marked as paid on the balances screen is a new
    // (possibly still-pending) expense -- reflect it in this screen's
    // list too once we're back.
    await _loadFromCache();
  }

  /// Opens group settings (rename, currency, participants). Unlike the
  /// balances screen, GroupSettingsScreen returns the fresh [Group]
  /// straight from Navigator.pop on a successful save (or null if
  /// nothing changed / the user backed out), so this can just adopt it
  /// directly instead of re-reading the cache.
  Future<void> _openGroupSettings() async {
    final updated = await Navigator.of(context).push<Group>(
      MaterialPageRoute(
        builder: (_) => GroupSettingsScreen(
          client: widget.client,
          db: widget.db,
          group: _group!,
        ),
      ),
    );
    if (updated != null && mounted) {
      setState(() => _group = updated);
    }
  }

  Future<void> _openAddExpense() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AddExpenseScreen(
          client: widget.client,
          db: widget.db,
          outbox: widget.outbox,
          group: _group!,
          initialPaidBy: _activeUserId,
        ),
      ),
    );
    if (added == true) {
      await _loadFromCache();
      _syncThenRefresh();
    }
  }

  /// Resolves who "you" are in *this* group -- see resolveActiveParticipant
  /// and decisions/multi-group-design.md, decision 2. Called after every
  /// successful cache load and live refresh (participants can change,
  /// and this group's own stored choice or the device's default name
  /// might newly apply). Never prompts on its own: an unresolved result
  /// just leaves [_activeUserId] null, same as "nothing set yet" always
  /// meant -- resolveDefaultPaidBy in add-expense already falls back to
  /// the first participant, and the person icon still lets you pick
  /// explicitly.
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
        title: const Text('Active user'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(_noneSentinel),
            child: Row(
              children: [
                if (_activeUserId == null) const Icon(Icons.check, size: 18),
                if (_activeUserId == null) const SizedBox(width: 8),
                const Text('None'),
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
