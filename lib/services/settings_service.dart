import 'package:shared_preferences/shared_preferences.dart';

/// Which server and group this install of the app is pointed at. There's
/// no multi-group UI yet (see README status) -- one server + one group,
/// changeable from the settings screen.
class SettingsService {
  static const _keyServerUrl = 'server_url';
  static const _keyGroupId = 'group_id';
  static const _keyActiveUserId = 'active_user_id';

  Future<String?> serverUrl() async =>
      (await SharedPreferences.getInstance()).getString(_keyServerUrl);

  Future<String?> groupId() async =>
      (await SharedPreferences.getInstance()).getString(_keyGroupId);

  Future<void> save({required String serverUrl, required String groupId}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyServerUrl, serverUrl);
    await prefs.setString(_keyGroupId, groupId);
  }

  Future<bool> isConfigured() async =>
      (await serverUrl()) != null && (await groupId()) != null;

  /// Which participant this device defaults "Paid by" to -- purely a
  /// local convenience (mirrors the web app's own per-device "Active
  /// user" setting), never synced to the server. Resolving it against a
  /// group's actual participants (it may be stale, or unset) is
  /// [resolveDefaultPaidBy] in lib/services/active_user.dart, kept
  /// separate so that logic is testable without SharedPreferences.
  Future<String?> activeUserId() async =>
      (await SharedPreferences.getInstance()).getString(_keyActiveUserId);

  Future<void> setActiveUserId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_keyActiveUserId);
    } else {
      await prefs.setString(_keyActiveUserId, id);
    }
  }
}
