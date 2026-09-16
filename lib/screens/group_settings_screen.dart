import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../models/group.dart';

/// Group settings: rename the group, change its currency, and add,
/// rename, or remove participants -- mirrors the web app's
/// Information/Settings tab.
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
  late final _currencyController = TextEditingController(text: widget.group.currency);
  late final List<_ParticipantRow> _participants = [
    for (final p in widget.group.participants) _ParticipantRow(id: p.id, name: p.name),
  ];

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _currencyController.dispose();
    for (final p in _participants) {
      p.controller.dispose();
    }
    super.dispose();
  }

  void _addParticipant() {
    setState(() => _participants.add(_ParticipantRow(id: '', name: '')));
  }

  void _removeParticipant(int index) {
    setState(() {
      _participants.removeAt(index).controller.dispose();
    });
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final currency = _currencyController.text.trim();
    final names = [for (final p in _participants) p.controller.text.trim()];

    if (name.isEmpty) {
      setState(() => _error = 'Group name is required.');
      return;
    }
    if (currency.isEmpty) {
      setState(() => _error = 'Currency is required.');
      return;
    }
    if (names.isEmpty) {
      setState(() => _error = 'At least one participant is required.');
      return;
    }
    if (names.any((n) => n.isEmpty)) {
      setState(() => _error = 'Every participant needs a name.');
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
        currency: currency,
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
      setState(() => _error = "Couldn't save: $e");
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Group settings'),
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
                  tooltip: 'Save',
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
            decoration: const InputDecoration(labelText: 'Group name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _currencyController,
            decoration: const InputDecoration(labelText: 'Currency'),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              const Text('Participants', style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.person_add_outlined),
                tooltip: 'Add participant',
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
                    tooltip: 'Remove',
                    onPressed: () => _removeParticipant(i),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
