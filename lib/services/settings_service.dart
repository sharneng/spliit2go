import 'package:shared_preferences/shared_preferences.dart';

/// Device-wide settings, plus read-only access to the single
/// server/group/active-user values this app used to store before
/// multi-group support (backlog #4, see decisions/multi-group-design.md)
/// -- kept only so main.dart's one-time startup migration can read them
/// and fold them into the new AppDatabase-backed joined-groups list.
/// Nothing writes the legacy keys anymore; a fresh install simply never
/// has them, and the migration is a no-op for it.
class SettingsService {
  static const _keyServerUrl = 'server_url';
  static const _keyGroupId = 'group_id';
  static const _keyActiveUserId = 'active_user_id';
  static const _keyDefaultActiveUserName = 'default_active_user_name';

  /// Legacy single-group server URL -- see class doc. Read-only; only
  /// main.dart's startup migration reads this.
  Future<String?> legacyServerUrl() async =>
      (await SharedPreferences.getInstance()).getString(_keyServerUrl);

  /// Legacy single-group id -- see class doc.
  Future<String?> legacyGroupId() async =>
      (await SharedPreferences.getInstance()).getString(_keyGroupId);

  /// Legacy single global active-user id -- see class doc. Superseded by
  /// AppDatabase's per-group `activeParticipantId` plus
  /// [defaultActiveUserName] below.
  Future<String?> legacyActiveUserId() async =>
      (await SharedPreferences.getInstance()).getString(_keyActiveUserId);

  /// The device-wide preferred display name used to auto-match a newly
  /// opened or joined group's active participant without prompting --
  /// see [resolveActiveParticipant] in lib/services/active_user.dart and
  /// decisions/multi-group-design.md, decision 2. Never synced to the
  /// server; purely a local convenience, same as the per-group choice it
  /// helps seed.
  Future<String?> defaultActiveUserName() async =>
      (await SharedPreferences.getInstance()).getString(_keyDefaultActiveUserName);

  Future<void> setDefaultActiveUserName(String? name) async {
    final prefs = await SharedPreferences.getInstance();
    if (name == null) {
      await prefs.remove(_keyDefaultActiveUserName);
    } else {
      await prefs.setString(_keyDefaultActiveUserName, name);
    }
  }
}
