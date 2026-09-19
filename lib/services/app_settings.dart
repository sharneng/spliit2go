import 'package:flutter/material.dart';

import '../l10n/app_locales.dart';
import 'settings_service.dart';

/// Device-wide preferences shared by the app root and settings route.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._service, this._themeMode, this._locale);

  final SettingsService _service;
  ThemeMode _themeMode;
  Locale? _locale;
  bool _saving = false;

  ThemeMode get themeMode => _themeMode;

  /// The language override chosen in App settings (issue #51); null means
  /// "System default" -- follow the device locale.
  Locale? get locale => _locale;

  bool get saving => _saving;

  static Future<AppSettings> load(SettingsService service) async =>
      AppSettings._(
        service,
        await service.themeMode(),
        localeFromTag(await service.preferredLocaleTag()),
      );

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

  /// Switches the app's language to [locale], or back to following the
  /// device when null. Applies immediately (listeners are notified before
  /// the write finishes, so the UI updates without waiting on disk), and
  /// reverts and rethrows if persisting fails -- same contract as
  /// [setThemeMode].
  Future<void> setLocale(Locale? locale) async {
    if (_saving || locale == _locale) return;
    final previous = _locale;
    _locale = locale;
    _saving = true;
    notifyListeners();
    try {
      await _service.setPreferredLocaleTag(tagFromLocale(locale));
    } catch (_) {
      _locale = previous;
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
