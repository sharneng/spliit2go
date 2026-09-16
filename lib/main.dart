import 'package:flutter/material.dart';

import 'api/spliit_client.dart';
import 'db/app_database.dart';
import 'db/connection.dart';
import 'screens/group_screen.dart';
import 'screens/settings_screen.dart';
import 'services/settings_service.dart';
import 'sync/outbox.dart';

void main() {
  runApp(const Spliit2GoApp());
}

class Spliit2GoApp extends StatelessWidget {
  const Spliit2GoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'spliit2go',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const _Root(),
    );
  }
}

/// Decides between the settings screen (first run, or nothing configured
/// yet) and the group screen, and owns the long-lived objects (db, api
/// client, outbox) that both the group screen and add-expense screen
/// share. Kept deliberately simple (no DI framework) -- there's exactly
/// one screen graph in this app so far.
class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  final _settings = SettingsService();
  final _db = AppDatabase(openConnection());

  String? _serverUrl;
  String? _groupId;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final serverUrl = await _settings.serverUrl();
    final groupId = await _settings.groupId();
    setState(() {
      _serverUrl = serverUrl;
      _groupId = groupId;
      _checked = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_serverUrl == null || _groupId == null) {
      return SettingsScreen(
        initialServerUrl: _serverUrl,
        initialGroupId: _groupId,
        onSaved: (serverUrl, groupId) {
          setState(() {
            _serverUrl = serverUrl;
            _groupId = groupId;
          });
        },
      );
    }

    final client = SpliitClient(baseUrl: _serverUrl!);
    final outbox = Outbox(_db, client);
    return GroupScreen(client: client, db: _db, outbox: outbox, groupId: _groupId!);
  }
}
