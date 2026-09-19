import 'package:flutter/material.dart';

import 'settings_service.dart';

/// Device-wide preferences shared by the app root and settings route.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._service, this._themeMode);

  final SettingsService _service;
  ThemeMode _themeMode;
  bool _saving = false;

  ThemeMode get themeMode => _themeMode;
  bool get saving => _saving;

  static Future<AppSettings> load(SettingsService service) async =>
      AppSettings._(service, await service.themeMode());

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_saving || mode == _themeMode) return;
    final previous = _themeMode;
    _themeMode = mode;
    _saving = true;
    notifyListeners();
    try {
      await _service.setThemeMode(mode);
    } catch (_) {
      _themeMode = previous;
      rethrow;
    } finally {
      _saving = false;
      notifyListeners();
    }
  }
}

class AppSettingsScope extends InheritedNotifier<AppSettings> {
  const AppSettingsScope(
      {super.key, required super.notifier, required super.child});

  static AppSettings of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppSettingsScope>()!.notifier!;
}
