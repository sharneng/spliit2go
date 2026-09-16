import 'package:flutter/material.dart';

import 'api/spliit_client.dart';
import 'db/app_database.dart';
import 'db/connection.dart';
import 'screens/group_list_screen.dart';
import 'screens/group_screen.dart';
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

/// Decides what to show on launch: straight into the most-recently-
/// opened group (decisions/multi-group-design.md, decision 3) if
/// there's one, or the group list otherwise -- after a one-time
/// migration that folds a legacy single-group install's SettingsService
/// values into the new AppDatabase-backed joined-groups list. Owns the
/// AppDatabase instance (the one long-lived object every screen
/// shares) -- there's no DI framework, just one screen graph.
class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  final _db = AppDatabase(openConnection());

  bool _checked = false;
  GroupRow? _lastGroup;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await _migrateLegacySingleGroup();
    final last = await _db.mostRecentlyOpenedGroup();
    if (!mounted) return;
    setState(() {
      _lastGroup = last;
      _checked = true;
    });
  }

  /// One-time migration for an install that predates multi-group
  /// support: folds the old single global server_url/group_id/
  /// active_user_id (SettingsService) into this group's now-per-group
  /// AppDatabase.Groups row, and seeds the new device-wide
  /// defaultActiveUserName from that participant's cached name so
  /// groups joined from here on auto-match without prompting. A no-op
  /// for any install that never had those legacy keys -- including
  /// every fresh install from here on -- and idempotent (checks
  /// `serverUrl.isNotEmpty` so it only runs once even though it's
  /// called on every launch). See decisions/multi-group-design.md.
  Future<void> _migrateLegacySingleGroup() async {
    final settings = SettingsService();
    final legacyGroupId = await settings.legacyGroupId();
    final legacyServerUrl = await settings.legacyServerUrl();
    if (legacyGroupId == null || legacyServerUrl == null) return;

    final row = await _db.groupRow(legacyGroupId);
    if (row == null || row.serverUrl.isNotEmpty) {
      // Either this group was never successfully cached before the
      // update (rare -- would mean the old app never got past a first,
      // failed sync -- nothing to migrate, the user just rejoins), or
      // this has already run in an earlier launch.
      return;
    }

    await _db.recordGroupOpened(legacyGroupId, serverUrl: legacyServerUrl);

    final legacyActiveUserId = await settings.legacyActiveUserId();
    if (legacyActiveUserId == null) return;
    await _db.setActiveParticipant(legacyGroupId, legacyActiveUserId);

    final cachedGroup = await _db.cachedGroup(legacyGroupId);
    String? name;
    for (final p in cachedGroup?.participants ?? const []) {
      if (p.id == legacyActiveUserId) {
        name = p.name;
        break;
      }
    }
    if (name != null) {
      await settings.setDefaultActiveUserName(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final lastGroup = _lastGroup;
    if (lastGroup == null) {
      return GroupListScreen(db: _db);
    }
    final client = SpliitClient(baseUrl: lastGroup.serverUrl);
    final outbox = Outbox(_db, client);
    return GroupScreen(client: client, db: _db, outbox: outbox, groupId: lastGroup.id);
  }
}
