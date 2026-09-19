import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../db/app_database.dart';
import '../l10n/context_l10n.dart';
import '../services/active_user.dart';
import '../services/group_url.dart';
import '../services/settings_service.dart';

/// Joins a group: paste the group's full URL (the same one you'd get
/// from the webapp's address bar or a share sheet, e.g.
/// spliit.app/groups/RrYePXN2GBpSMW1EPjpjH), fetch it live to confirm
/// it's real, cache it, and record it as opened. Used both for the
/// very first group on a fresh install and for adding another from
/// GroupListScreen's "+" -- see decisions/multi-group-design.md.
///
/// Used to ask for server URL and group id as two separate fields the
/// user had to split a URL to fill in themselves; now a single field
/// parsed by [parseGroupUrl], matching how both the iOS app and the
/// webapp already handle this -- see
/// github.com/sharneng/spliit2go/issues/13.
///
/// Requires connectivity: joining means confirming a real group exists
/// and caching its actual data, not just remembering an id someone
/// typed, so there's no offline path here the way add-expense has one.
class JoinGroupScreen extends StatefulWidget {
  final AppDatabase db;
  final String? initialUrl;

  /// Builds the SpliitClient to fetch the entered group with. Defaults
  /// to a real one for the entered server URL; overridable so tests can
  /// inject a client backed by http's MockClient regardless of what URL
  /// was typed -- this screen doesn't take a pre-built [SpliitClient]
  /// the way every other screen does, since the whole point here is
  /// that the server URL is whatever the user just pasted, not something
  /// known ahead of time.
  final SpliitClient Function(String serverUrl) clientFactory;

  JoinGroupScreen(
      {super.key,
      required this.db,
      this.initialUrl,
      SpliitClient Function(String)? clientFactory})
      : clientFactory = clientFactory ?? ((url) => SpliitClient(baseUrl: url));

  @override
  State<JoinGroupScreen> createState() => _JoinGroupScreenState();
}

class _JoinGroupScreenState extends State<JoinGroupScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _urlController = TextEditingController(text: widget.initialUrl);
  final _settings = SettingsService();

  bool _joining = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    if (!_formKey.currentState!.validate()) return;
    final parsed = parseGroupUrl(_urlController.text);
    if (parsed == null) {
      setState(() => _error = context.l10n.joinGroupUrlInvalid);
      return;
    }
    final serverUrl = parsed.serverUrl;
    final groupId = parsed.groupId;

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
      setState(() => _error = context.l10n.joinGroupJoinFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.joinGroupScreenTitle)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 12),
              ],
              TextFormField(
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: context.l10n.joinGroupUrlLabel,
                  helperText: context.l10n.joinGroupUrlHelper,
                ),
                keyboardType: TextInputType.url,
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? context.l10n.commonRequired
                    : null,
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
                    : Text(context.l10n.joinGroupSubmitButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
