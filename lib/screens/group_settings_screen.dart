import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/context_l10n.dart';
import '../models/currency.dart';
import '../models/expense.dart';
import '../models/group.dart';
import '../widgets/currency_picker.dart';

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
class GroupSettingsScreen extends StatefulWidget {
  final SpliitClient client;
  final AppDatabase db;
  final Group group;

  const GroupSettingsScreen({
    super.key,
    required this.client,
    required this.db,
    required this.group,
  });

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

class _GroupSettingsScreenState extends State<GroupSettingsScreen> {
  late final _nameController = TextEditingController(text: widget.group.name);
  late final _informationController =
      TextEditingController(text: widget.group.information ?? '');

  /// The picked currency. A group whose [Group.currencyCode] isn't one
  /// of Spliit's known codes -- including every group that predates
  /// issue #23 -- comes in as [Currency.custom], same as the web app's
  /// own group-form.tsx: it's the *code* that decides "known currency",
  /// not whether [Group.currency]'s symbol happens to match one.
  late Currency _selectedCurrency = currencyByCode(widget.group.currencyCode);

  /// Only used -- and only shown -- while [_selectedCurrency] is
  /// [Currency.custom]. Seeded from the group's current symbol so
  /// editing a custom-currency group doesn't blank it out.
  late final _customSymbolController = TextEditingController(text: widget.group.currency);

  late final List<_ParticipantRow> _participants = [
    for (final p in widget.group.participants) _ParticipantRow(id: p.id, name: p.name),
  ];

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

  @override
  void initState() {
    super.initState();
    _loadParticipantsWithExpenses();
  }

  Future<void> _loadParticipantsWithExpenses() async {
    final rows = await widget.db.expensesForGroup(widget.group.id);
    final ids = <String>{};
    for (final row in rows) {
      ids.add(row.paidBy);
      for (final share in jsonDecode(row.paidForJson) as List) {
        ids.add(ExpenseShare.fromJson(share as Map<String, dynamic>).participantId);
      }
    }
    if (!mounted) return;
    setState(() => _participantIdsWithExpenses = ids);
  }

  @override
  void dispose() {
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

  /// True once [_loadParticipantsWithExpenses] would actually block
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

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final information = _informationController.text.trim();
    final isCustom = _selectedCurrency.code.isEmpty;
    final currencySymbol = isCustom ? _customSymbolController.text.trim() : _selectedCurrency.symbol;
    final names = [for (final p in _participants) p.controller.text.trim()];

    if (name.isEmpty) {
      setState(() => _error = context.l10n.groupSettingsNameRequired);
      return;
    }
    if (isCustom && currencySymbol.isEmpty) {
      setState(() => _error = context.l10n.groupSettingsSymbolRequired);
      return;
    }
    if (names.isEmpty) {
      setState(() => _error = context.l10n.groupSettingsNeedParticipant);
      return;
    }
    if (names.any((n) => n.isEmpty)) {
      setState(() => _error = context.l10n.groupSettingsParticipantNameRequired);
      return;
    }
    // Belt-and-braces alongside the disabled remove button (issue #46):
    // the button already stops this in the UI, but _save is the one
    // place that actually knows the request about to go out, so it's
    // the backstop against any path that skips the button (a future
    // bulk-edit UI, a bug in _hasExpenses, ...).
    final removedIds = {for (final p in widget.group.participants) p.id}
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
      await widget.client.updateGroup(
        groupId: widget.group.id,
        name: name,
        information: information,
        currency: currencySymbol,
        currencyCode: isCustom ? null : _selectedCurrency.code,
        participants: [
          for (var i = 0; i < _participants.length; i++)
            Participant(id: _participants[i].id, name: names[i]),
        ],
      );
      final fresh = await widget.client.fetchGroup(widget.group.id);
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

  @override
  Widget build(BuildContext context) {
    final isCustom = _selectedCurrency.code.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.groupSettingsTitle),
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
                  tooltip: context.l10n.groupSettingsSaveTooltip,
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
