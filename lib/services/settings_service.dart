import 'package:shared_preferences/shared_preferences.dart';

/// Which server and group this install of the app is pointed at. There's
/// no multi-group UI yet (see README status) -- one server + one group,
/// changeable from the settings screen.
class SettingsService {
  static const _keyServerUrl = 'server_url';
  static const _keyGroupId = 'group_id';

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
}
