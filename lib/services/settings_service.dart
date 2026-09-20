import 'package:flutter/material.dart';
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

  static const _keyThemeMode = 'theme_mode';
  static const _keyPreferredLocaleTag = 'preferred_locale_tag';

  Future<String?> groupListSort() async =>
      (await SharedPreferences.getInstance()).getString('group_list_sort');

  Future<void> setGroupListSort(String value) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      if (!await prefs.setString('group_list_sort', value)) {
        throw StateError('Could not save group sort');
      }
    } catch (_) {
      // The plugin updates its cache before attempting persistence. Restore
      // the persisted view so a later screen reload cannot apply a failed write.
      await prefs.reload();
      rethrow;
    }
  }

  Future<ThemeMode> themeMode() async {
    final value =
        (await SharedPreferences.getInstance()).getString(_keyThemeMode);
    return switch (value) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = mode == ThemeMode.system
        ? await prefs.remove(_keyThemeMode)
        : await prefs.setString(_keyThemeMode, mode.name);
    if (!saved) throw StateError('Could not save theme preference');
  }

  /// The explicit language override chosen in App settings (issue #51),
  /// as a tag from `appLocaleOptions` (e.g. `fr`, `zh`); null means "System
  /// default" -- follow the device locale. Device-wide and never synced to
  /// the server, same as [defaultActiveUserName]. Turning it into a
  /// `Locale` (and ignoring a tag this build doesn't know) is
  /// `localeFromTag`'s job, not this store's.
  Future<String?> preferredLocaleTag() async =>
      (await SharedPreferences.getInstance()).getString(_keyPreferredLocaleTag);

  /// Saves [tag], or clears the override when null. Throws if the write
  /// fails, like [setThemeMode], so the caller can revert what it showed.
  Future<void> setPreferredLocaleTag(String? tag) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = tag == null
        ? await prefs.remove(_keyPreferredLocaleTag)
        : await prefs.setString(_keyPreferredLocaleTag, tag);
    if (!saved) throw StateError('Could not save language preference');
  }

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
      (await SharedPreferences.getInstance())
          .getString(_keyDefaultActiveUserName);

  Future<void> setDefaultActiveUserName(String? name) async {
    final prefs = await SharedPreferences.getInstance();
    if (name == null) {
      await prefs.remove(_keyDefaultActiveUserName);
    } else {
      await prefs.setString(_keyDefaultActiveUserName, name);
    }
  }
}
