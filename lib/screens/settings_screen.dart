import 'package:flutter/material.dart';

import '../services/settings_service.dart';

/// First-run (and later, re-editable) setup: which server, which group.
/// Group id is the last path segment of the group's URL, e.g.
/// spliit.app/groups/RrYePXN2GBpSMW1EPjpjH -> RrYePXN2GBpSMW1EPjpjH --
/// same convention as the splitwise2spliit import script.
class SettingsScreen extends StatefulWidget {
  final void Function(String serverUrl, String groupId) onSaved;
  final String? initialServerUrl;
  final String? initialGroupId;

  const SettingsScreen({
    super.key,
    required this.onSaved,
    this.initialServerUrl,
    this.initialGroupId,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _serverController =
      TextEditingController(text: widget.initialServerUrl ?? 'https://spliit.app');
  late final _groupController = TextEditingController(text: widget.initialGroupId ?? '');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to Spliit')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _serverController,
                decoration: const InputDecoration(labelText: 'Server URL'),
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _groupController,
                decoration: const InputDecoration(
                  labelText: 'Group ID',
                  helperText: 'Last segment of the group URL',
                ),
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () {
                  if (_formKey.currentState!.validate()) {
                    final serverUrl = _serverController.text.trim();
                    final groupId = _groupController.text.trim();
                    SettingsService().save(serverUrl: serverUrl, groupId: groupId);
                    widget.onSaved(serverUrl, groupId);
                  }
                },
                child: const Text('Connect'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
