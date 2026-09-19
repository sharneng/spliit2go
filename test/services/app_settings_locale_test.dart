import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/services/app_settings.dart';
import 'package:spliit2go/services/settings_service.dart';

class _FailingLocaleSave extends SettingsService {
  @override
  Future<void> setPreferredLocaleTag(String? tag) async =>
      throw StateError('disk unavailable');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults to no override (follow the device)', () async {
    final settings = await AppSettings.load(SettingsService());
    addTearDown(settings.dispose);
    expect(settings.locale, isNull);
  });

  test('loads a persisted override at startup', () async {
    SharedPreferences.setMockInitialValues({'preferred_locale_tag': 'zh'});
    final settings = await AppSettings.load(SettingsService());
    addTearDown(settings.dispose);
    expect(settings.locale, const Locale('zh'));
  });

  test('ignores a persisted tag this build does not know', () async {
    SharedPreferences.setMockInitialValues({'preferred_locale_tag': 'klingon'});
    final settings = await AppSettings.load(SettingsService());
    addTearDown(settings.dispose);
    expect(settings.locale, isNull);
  });

  test('setLocale applies, notifies, and persists', () async {
    final settings = await AppSettings.load(SettingsService());
    addTearDown(settings.dispose);
    var notified = 0;
    settings.addListener(() => notified++);

    await settings.setLocale(const Locale('fr'));

    expect(settings.locale, const Locale('fr'));
    expect(notified, greaterThan(0));
    expect(await SettingsService().preferredLocaleTag(), 'fr');
    // A fresh load (i.e. a restart) reads the same choice back.
    final reloaded = await AppSettings.load(SettingsService());
    addTearDown(reloaded.dispose);
    expect(reloaded.locale, const Locale('fr'));
  });

  test('setLocale(null) clears the override', () async {
    SharedPreferences.setMockInitialValues({'preferred_locale_tag': 'fr'});
    final settings = await AppSettings.load(SettingsService());
    addTearDown(settings.dispose);

    await settings.setLocale(null);

    expect(settings.locale, isNull);
    expect(await SettingsService().preferredLocaleTag(), isNull);
  });

  test('a failed save reverts the choice and rethrows', () async {
    final settings = await AppSettings.load(_FailingLocaleSave());
    addTearDown(settings.dispose);

    await expectLater(
        settings.setLocale(const Locale('fr')), throwsA(isA<StateError>()));

    expect(settings.locale, isNull);
    expect(settings.saving, isFalse);
  });
}
