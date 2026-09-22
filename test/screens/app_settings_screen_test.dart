import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/main.dart';
import 'package:spliit2go/screens/app_settings_screen.dart';
import 'package:spliit2go/screens/group_list_screen.dart';
import 'package:spliit2go/screens/join_group_screen.dart';
import 'package:spliit2go/services/app_settings.dart';
import 'package:spliit2go/services/settings_service.dart';

class FailingSettingsService extends SettingsService {
  @override
  Future<void> setThemeMode(ThemeMode mode) async =>
      throw StateError('disk unavailable');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
      'settings switches theme live, follows system, and preserves navigation',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final settings = await AppSettings.load(SettingsService());
    addTearDown(settings.dispose);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
        Spliit2GoApp(settings: settings, home: GroupListScreen(db: db)));
    await tester.pumpAndSettle();

    expect(
        find.descendant(
            of: find.byType(AppBar), matching: find.byIcon(Icons.add)),
        findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    await tester.tap(find.byTooltip('App settings'));
    await tester.pumpAndSettle();

    Brightness brightness() =>
        Theme.of(tester.element(find.text('Theme'))).brightness;
    expect(brightness(), Brightness.light);
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.dark);
    expect(await SettingsService().themeMode(), ThemeMode.dark);
    expect(find.byType(AppSettingsScreen), findsOneWidget);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.light);
    expect(await SettingsService().themeMode(), ThemeMode.light);

    await tester.tap(find.text('Follow System'));
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.dark);
    expect(await SettingsService().themeMode(), ThemeMode.system);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.light);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Spliit2Go'), findsOneWidget);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.byType(JoinGroupScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('restores dark mode when a fresh app starts', (tester) async {
    await SettingsService().setThemeMode(ThemeMode.dark);
    final settings = await AppSettings.load(SettingsService());
    addTearDown(settings.dispose);
    await tester.pumpWidget(
        Spliit2GoApp(settings: settings, home: const AppSettingsScreen()));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.text('Theme'))).brightness,
        Brightness.dark);
    final dark = tester.widget<ListTile>(find.widgetWithText(ListTile, 'Dark'));
    expect(dark.selected, isTrue);
  });

  testWidgets('failed persistence restores selection and reports error',
      (tester) async {
    final settings = await AppSettings.load(FailingSettingsService());
    addTearDown(settings.dispose);
    await tester.pumpWidget(
        Spliit2GoApp(settings: settings, home: const AppSettingsScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.system);
    expect(find.text('Could not save your setting. Please try again.'),
        findsOneWidget);
  });

  test('unknown stored theme falls back to system', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': 'future-mode'});
    expect(await SettingsService().themeMode(), ThemeMode.system);
  });
}
