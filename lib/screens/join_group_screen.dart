import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../services/active_user.dart';
import '../services/settings_service.dart';

/// Joins a group: enter a server URL and group id (same convention as
/// the splitwise2spliit import script -- group id is the last path
/// segment of the group's URL, e.g.
/// spliit.app/groups/RrYePXN2GBpSMW1EPjpjH -> RrYePXN2GBpSMW1EPjpjH),
/// fetch it live to confirm it's real, cache it, and record it as
/// opened. Used both for the very first group on a fresh install and
/// for adding another from GroupListScreen's "+" -- see
/// decisions/multi-group-design.md.
///
/// Requires connectivity: joining means confirming a real group exists
/// and caching its actual data, not just remembering an id someone
/// typed, so there's no offline path here the way add-expense has one.
class JoinGroupScreen extends StatefulWidget {
  final AppDatabase db;

  /// Builds the SpliitClient to fetch the entered group with. Defaults
  /// to a real one for the entered server URL; overridable so tests can
  /// inject a client backed by http's MockClient regardless of what URL
  /// was typed -- this screen doesn't take a pre-built [SpliitClient]
  /// the way every other screen does, since the whole point here is
  /// that the server URL is whatever the user just typed, not something
  /// known ahead of time.
  final SpliitClient Function(String serverUrl) clientFactory;

  JoinGroupScreen({super.key, required this.db, SpliitClient Function(String)? clientFactory})
      : clientFactory = clientFactory ?? ((url) => SpliitClient(baseUrl: url));

  @override
  State<JoinGroupScreen> createState() => _JoinGroupScreenState();
}

class _JoinGroupScreenState extends State<JoinGroupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController(text: 'https://spliit.app');
  final _groupController = TextEditingController();
  final _settings = SettingsService();

  bool _joining = false;
  String? _error;

  @override
  void dispose() {
    _serverController.dispose();
    _groupController.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    if (!_formKey.currentState!.validate()) return;
    final serverUrl = _serverController.text.trim();
    final groupId = _groupController.text.trim();

    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      final client = widget.clientFactory(serverUrl);
      final group = await client.fetchGroup(groupId);
      await widget.db.cacheGroup(group);
      await widget.db.recordGroupOpened(group.id, serverUrl: serverUrl);

      // Seed this group's active participant the same way GroupScreen
      // resolves it on open, so it's not left unresolved right after
      // joining -- see resolveActiveParticipant.
      final defaultName = await _settings.defaultActiveUserName();
      final resolution = resolveActiveParticipant(
        storedActiveParticipantId: null,
        defaultActiveUserName: defaultName,
        participants: group.participants,
      );
      if (resolution case ActiveParticipantAutoMatched(:final participantId)) {
        await widget.db.setActiveParticipant(group.id, participantId);
      }

      if (!mounted) return;
      Navigator.of(context).pop(group.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = "Couldn't join: $e");
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join a group')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 12),
              ],
              TextFormField(
                controller: _serverController,
                decoration: const InputDecoration(labelText: 'Server URL'),
                validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _groupController,
                decoration: const InputDecoration(
                  labelText: 'Group ID',
                  helperText: 'Last segment of the group URL',
                ),
                validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _joining ? null : _join,
                child: _joining
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Join'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
