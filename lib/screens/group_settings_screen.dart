import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/context_l10n.dart';
import '../models/currency.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../services/date_span_calculator.dart';
import '../services/group_url.dart';
import '../services/settings_service.dart';
import '../utils/date_format.dart';
import '../widgets/currency_picker.dart';
import 'join_group_screen.dart' show cacheJoinedGroup;

/// Group settings: rename the group, add or change its notes, change its
/// currency, and add, rename, or remove participants -- mirrors the web
/// app's Information/Settings tab.
///
/// Spliit has no per-field or per-participant endpoint (see
/// [SpliitClient.updateGroup]), so this screen edits everything
/// together and sends the full desired state back in one call on Save,
/// rather than syncing each field change as it happens.
///
/// Unlike adding an expense, this doesn't go through the outbox --
/// group-settings edits aren't currently queued for offline sync, so
/// Save requires connectivity and surfaces an error inline if it fails.
/// On success, the (possibly server-assigned) fresh group is re-fetched,
/// cached locally, and returned to the caller via Navigator.pop so
/// GroupScreen can adopt it without a separate reload.
///
/// [GroupSettingsScreen.create] reuses the same form to create a group
/// (issue #115), like spliit-ios's shared group editor: plus a server
/// picker, since a group stays on the server it's made on; minus the date
/// span. On success it caches the new group as joined and pops its id.
class GroupSettingsScreen extends StatefulWidget {
  /// Null when creating: the client is built for the chosen server.
  final SpliitClient? client;
  final AppDatabase db;

  /// The group being edited, or null when creating one.
  final Group? group;

  /// Builds the client for the chosen server when creating; tests inject
  /// a MockClient-backed one, as for JoinGroupScreen.
  final SpliitClient Function(String serverUrl) clientFactory;

  GroupSettingsScreen({
    super.key,
    required SpliitClient this.client,
    required this.db,
    required Group this.group,
  }) : clientFactory = ((url) => SpliitClient(baseUrl: url));

  GroupSettingsScreen.create({
    super.key,
    required this.db,
    SpliitClient Function(String serverUrl)? clientFactory,
  })  : client = null,
        group = null,
        clientFactory = clientFactory ?? ((url) => SpliitClient(baseUrl: url));

  @override
  State<GroupSettingsScreen> createState() => _GroupSettingsScreenState();
}

/// One participant row's editable state. [id] is the server id for an
/// existing participant, or '' for a row added in this session that
/// hasn't been saved yet -- see [SpliitClient.updateGroup].
class _ParticipantRow {
  final String id;
  final TextEditingController controller;

  _ParticipantRow({required this.id, required String name})
      : controller = TextEditingController(text: name);
}

/// Where a new group goes when nothing else says: spliit-web's own
/// instance.
const defaultServerUrl = 'https://spliit.app';

class _GroupSettingsScreenState extends State<GroupSettingsScreen> {
  bool get _creating => widget.group == null;

  late final _nameController = TextEditingController(text: widget.group?.name ?? '');
  late final _informationController =
      TextEditingController(text: widget.group?.information ?? '');

  /// The picked currency. A group whose [Group.currencyCode] isn't one
  /// of Spliit's known codes -- including every group that predates
  /// issue #23 -- comes in as [Currency.custom], same as the web app's
  /// own group-form.tsx: it's the *code* that decides "known currency",
  /// not whether [Group.currency]'s symbol happens to match one.
  ///
  /// A new group starts in the phone region's currency (see
  /// [defaultCurrencyFor]), set in [didChangeDependencies].
  late Currency _selectedCurrency = currencyByCode(widget.group?.currencyCode);

  /// Only used -- and only shown -- while [_selectedCurrency] is
  /// [Currency.custom]. Seeded from the group's current symbol so
  /// editing a custom-currency group doesn't blank it out.
  late final _customSymbolController =
      TextEditingController(text: widget.group?.currency ?? '');

  /// A new group starts with spliit-web's and spliit-ios's three sample
  /// names, localized as spliit-web does, filled in by
  /// [didChangeDependencies] (they need the locale).
  late final List<_ParticipantRow> _participants = [
    for (final p in widget.group?.participants ?? const <Participant>[])
      _ParticipantRow(id: p.id, name: p.name),
  ];
  bool _seeded = false;

  /// Creating only: servers this device already has groups on, most
  /// recently opened first, then spliit.app if it isn't one of them.
  List<String> _servers = const [defaultServerUrl];

  /// Creating only: the picked server, or null for "Other server", typed
  /// into [_otherServerController].
  String? _server = defaultServerUrl;
  final _otherServerController = TextEditingController();

  bool _saving = false;
  String? _error;

  /// Participant ids (from [Group.participants]) that have at least one
  /// associated expense (paidBy or paidFor) in this group's local cache
  /// (issue #46) -- populated from [AppDatabase.expensesForGroup] rather
  /// than a live fetch, matching this screen's existing offline-first
  /// posture (everything else it shows -- name, currency, participant
  /// list -- comes from the same local cache too). A participant in
  /// this set can't be removed: doing so would corrupt group history
  /// and balance calculations for expenses that still reference them,
  /// since Spliit's server has no participant-merge/reassignment story.
  ///
  /// Deliberately checked against the *cache*, not a live fetch: this
  /// screen already works offline for everything else, and a stale
  /// cache under-protecting (an expense synced elsewhere, not yet
  /// pulled down here) is no worse than the pre-#46 behavior of not
  /// checking at all -- whereas requiring connectivity just to open
  /// group settings would be a regression. [_save] is the last line of
  /// defense regardless (see its own check), independent of whether
  /// this set is complete.
  Set<String> _participantIdsWithExpenses = {};

  /// First-to-last expense date across the group's cached expenses
  /// (issue #55) -- computed from the same [AppDatabase.watchExpensesForGroup]
  /// subscription as [_participantIdsWithExpenses] rather than a second
  /// query, and null until the first emission (or if the group has no
  /// cached expenses at all).
  DateSpan? _dateSpan;

  /// Live, not one-shot (issue #57): this screen can be left open while
  /// a background refresh (GroupScreen's own watchExpensesForGroup
  /// subscription driving replaceServerExpenses) or another synced
  /// expense writes new rows into the cache, and both
  /// [_participantIdsWithExpenses] and [_dateSpan] need to follow that.
  /// Mirrors GroupScreen's own single-subscription
  /// watchExpensesForGroup().listen(...) + cancel-in-dispose pattern
  /// exactly (issue #47) -- unlike the GroupListScreen side of #55's
  /// review, which needed one subscription *per joined group* and hit a
  /// "Timer is still pending" leak, this screen only ever needs one
  /// subscription for its own single group, same as GroupScreen's
  /// already-working code.
  StreamSubscription<List<ExpenseRow>>? _expensesSub;

  @override
  void initState() {
    super.initState();
    if (_creating) {
      _loadServers();
      return;
    }
    _expensesSub =
        widget.db.watchExpensesForGroup(widget.group!.id).listen((rows) {
      if (!mounted) return;
      final ids = <String>{};
      for (final row in rows) {
        ids.add(row.paidBy);
        for (final share in jsonDecode(row.paidForJson) as List) {
          ids.add(ExpenseShare.fromJson(share as Map<String, dynamic>).participantId);
        }
      }
      setState(() {
        _participantIdsWithExpenses = ids;
        _dateSpan = computeDateSpan(rows);
      });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_creating || _seeded) return;
    _seeded = true;
    final l10n = context.l10n;
    _selectedCurrency =
        defaultCurrencyFor(View.of(context).platformDispatcher.locale);
    _customSymbolController.text = _selectedCurrency.symbol;
    _participants.addAll([
      for (final name in [
        l10n.createGroupSampleParticipant1,
        l10n.createGroupSampleParticipant2,
        l10n.createGroupSampleParticipant3,
      ])
        _ParticipantRow(id: '', name: name),
    ]);
  }

  Future<void> _loadServers() async {
    final seen = <String>{};
    final servers = [
      for (final row in await widget.db.allJoinedGroups())
        if (row.serverUrl.isNotEmpty && seen.add(row.serverUrl)) row.serverUrl,
      if (!seen.contains(defaultServerUrl)) defaultServerUrl,
    ];
    if (!mounted) return;
    setState(() {
      _servers = servers;
      _server = servers.first;
    });
  }

  @override
  void dispose() {
    _expensesSub?.cancel();
    _otherServerController.dispose();
    _nameController.dispose();
    _informationController.dispose();
    _customSymbolController.dispose();
    for (final p in _participants) {
      p.controller.dispose();
    }
    super.dispose();
  }

  void _addParticipant() {
    setState(() => _participants.add(_ParticipantRow(id: '', name: '')));
  }

  /// True once the watchExpensesForGroup subscription above would actually block
  /// removing this row -- i.e. it's an existing (not newly-added, empty
  /// [_ParticipantRow.id]) participant with at least one associated
  /// expense in the cache (issue #46).
  bool _hasExpenses(_ParticipantRow row) =>
      row.id.isNotEmpty && _participantIdsWithExpenses.contains(row.id);

  void _removeParticipant(int index) {
    if (_hasExpenses(_participants[index])) return;
    setState(() {
      _participants.removeAt(index).controller.dispose();
    });
  }

  Future<void> _pickCurrency() async {
    final picked = await pickCurrency(
      context,
      currencies: [Currency.custom, ...supportedCurrencies],
      selectedCode: _selectedCurrency.code,
    );
    if (picked == null) return;
    setState(() {
      _selectedCurrency = picked;
      // Mirrors the web app's onValueChange handler in group-form.tsx:
      // picking a real currency fills the symbol field for you; picking
      // Custom leaves whatever the user already typed alone.
      if (picked.code.isNotEmpty) _customSymbolController.text = picked.symbol;
    });
  }

  /// The first problem with the form, or null. The server's
  /// groupFormSchema limits (spliit-web `src/lib/schemas.ts`): name and
  /// participant names 2 to 50 characters, at least one participant, no
  /// two with the same name. Checked here so the message is ours rather
  /// than the server's raw validation error.
  String? _problem(String name, bool isCustom, String currencySymbol, List<String> names) {
    final l10n = context.l10n;
    if (name.isEmpty) return l10n.groupSettingsNameRequired;
    if (name.length < 2 || name.length > 50) return l10n.groupSettingsNameLength;
    if (isCustom && currencySymbol.isEmpty) return l10n.groupSettingsSymbolRequired;
    if (names.isEmpty) return l10n.groupSettingsNeedParticipant;
    if (names.any((n) => n.isEmpty)) return l10n.groupSettingsParticipantNameRequired;
    if (names.any((n) => n.length < 2 || n.length > 50)) {
      return l10n.groupSettingsParticipantNameLength;
    }
    final seen = <String>{};
    for (final n in names) {
      if (!seen.add(n)) return l10n.groupSettingsDuplicateParticipant(n);
    }
    return null;
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final information = _informationController.text.trim();
    final isCustom = _selectedCurrency.code.isEmpty;
    final currencySymbol = isCustom ? _customSymbolController.text.trim() : _selectedCurrency.symbol;
    final names = [for (final p in _participants) p.controller.text.trim()];

    final problem = _problem(name, isCustom, currencySymbol, names);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    if (_creating) return _create(name, information, isCustom, currencySymbol, names);

    // Belt-and-braces alongside the disabled remove button (issue #46):
    // the button already stops this in the UI, but _save is the one
    // place that actually knows the request about to go out, so it's
    // the backstop against any path that skips the button (a future
    // bulk-edit UI, a bug in _hasExpenses, ...).
    final group = widget.group!;
    final removedIds = {for (final p in group.participants) p.id}
        .difference({for (final p in _participants) p.id});
    if (removedIds.any(_participantIdsWithExpenses.contains)) {
      setState(() => _error = context.l10n.groupSettingsCantRemoveHasExpenses);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final client = widget.client!;
      await client.updateGroup(
        groupId: group.id,
        name: name,
        information: information,
        currency: currencySymbol,
        currencyCode: isCustom ? null : _selectedCurrency.code,
        participants: [
          for (var i = 0; i < _participants.length; i++)
            Participant(id: _participants[i].id, name: names[i]),
        ],
      );
      final fresh = await client.fetchGroup(group.id);
      await widget.db.cacheGroup(fresh);
      if (!mounted) return;
      Navigator.of(context).pop(fresh);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = context.l10n.groupSettingsSaveFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Creates the group on the chosen server, then stores it exactly as a
  /// join does (cacheJoinedGroup), with no expenses yet, and pops its id.
  /// Its participants' ids come from the server, so it's fetched back
  /// first. Needs a connection, like joining.
  Future<void> _create(String name, String information, bool isCustom,
      String currencySymbol, List<String> names) async {
    final serverUrl = _server ?? normalizeServerUrl(_otherServerController.text);
    if (serverUrl == null) {
      setState(() => _error = context.l10n.createGroupServerInvalid);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final client = widget.clientFactory(serverUrl);
      final groupId = await client.createGroup(
        name: name,
        information: information,
        currency: currencySymbol,
        currencyCode: isCustom ? null : _selectedCurrency.code,
        participantNames: names,
      );
      final group = await client.fetchGroup(groupId);
      await cacheJoinedGroup(
        db: widget.db,
        group: group,
        expenses: const [],
        serverUrl: serverUrl,
        settings: SettingsService(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(group.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = context.l10n.createGroupFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _serverField(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String?>(
          initialValue: _server,
          isExpanded: true,
          // The currency row's text style, rather than the dropdown's
          // heavier default, so the two read as a pair.
          style: Theme.of(context).textTheme.bodyLarge,
          decoration: InputDecoration(
            labelText: l10n.createGroupServerLabel,
            helperText: l10n.createGroupServerHelper,
            helperMaxLines: 3,
          ),
          items: [
            for (final url in _servers)
              DropdownMenuItem(
                  value: url,
                  child: Text(serverDisplayName(url), overflow: TextOverflow.ellipsis)),
            DropdownMenuItem(value: null, child: Text(l10n.createGroupServerOther)),
          ],
          onChanged: (value) => setState(() => _server = value),
        ),
        if (_server == null) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _otherServerController,
            decoration: InputDecoration(
              labelText: l10n.createGroupServerAddressLabel,
              hintText: 'spliit.example.com',
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isCustom = _selectedCurrency.code.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(_creating ? context.l10n.createGroupTitle : context.l10n.groupSettingsTitle),
        actions: [
          _saving
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.check),
                  tooltip: _creating
                      ? context.l10n.createGroupSubmitTooltip
                      : context.l10n.groupSettingsSaveTooltip,
                  onPressed: _save,
                ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _nameController,
            decoration: InputDecoration(labelText: context.l10n.groupSettingsNameLabel),
          ),
          const SizedBox(height: 12),
          InkWell(
            onTap: _pickCurrency,
            child: InputDecorator(
              decoration: InputDecoration(labelText: context.l10n.groupSettingsCurrencyLabel),
              child: Row(
                children: [
                  if (_selectedCurrency.flagEmoji.isNotEmpty) ...[
                    Text(_selectedCurrency.flagEmoji, style: const TextStyle(fontSize: 18)),
                    const SizedBox(width: 8),
                  ],
                  Expanded(child: Text(_selectedCurrency.toString())),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
          if (isCustom) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _customSymbolController,
              decoration: InputDecoration(
                labelText: context.l10n.groupSettingsSymbolLabel,
                hintText: context.l10n.groupSettingsSymbolHint,
                helperText: context.l10n.groupSettingsSymbolHelper,
              ),
              maxLength: 5,
            ),
          ],
          const SizedBox(height: 12),
          // Creating: where the group is made, in place of the date span a
          // new group doesn't have yet.
          if (_creating)
            _serverField(context)
          else
            // Read-only -- the date span is derived entirely from cached
            // expense dates (issue #55), there's nothing here to edit.
            InputDecorator(
              decoration: InputDecoration(labelText: context.l10n.groupSettingsDateSpanLabel),
              child: Text(formatDateSpan(_dateSpan, locale: context.appLocale)),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _informationController,
            decoration: InputDecoration(
              labelText: context.l10n.groupSettingsInfoLabel,
              hintText: context.l10n.groupSettingsInfoHint,
              alignLabelWithHint: true,
            ),
            minLines: 2,
            maxLines: 6,
            maxLength: 10000,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(context.l10n.groupSettingsParticipantsHeading,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.person_add_outlined),
                tooltip: context.l10n.groupSettingsAddParticipantTooltip,
                onPressed: _addParticipant,
              ),
            ],
          ),
          for (var i = 0; i < _participants.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _participants[i].controller,
                      decoration: const InputDecoration(isDense: true),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    // Disabled rather than hidden (issue #46) -- still
                    // visible where every other participant's remove
                    // button is, but greyed out and inert, so a
                    // participant with expenses reads as "protected"
                    // rather than as a row that's simply missing a
                    // control.
                    tooltip: _hasExpenses(_participants[i])
                        ? context.l10n.groupSettingsCantRemoveTooltip
                        : context.l10n.groupSettingsRemoveTooltip,
                    onPressed:
                        _hasExpenses(_participants[i]) ? null : () => _removeParticipant(i),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
