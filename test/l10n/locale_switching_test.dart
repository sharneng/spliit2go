import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/l10n/context_l10n.dart';
import 'package:spliit2go/main.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/app_settings_screen.dart';
import 'package:spliit2go/screens/group_screen.dart';
import 'package:spliit2go/services/app_settings.dart';
import 'package:spliit2go/services/settings_service.dart';
import 'package:spliit2go/sync/outbox.dart';
import 'package:spliit2go/utils/money.dart';

// Issue #51's end-to-end i18n checks: the language picker, live switching,
// persistence, fallback, and that formatters follow the *resolved app*
// locale (which can differ from the device's).
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppSettings> loadSettings(WidgetTester tester) async {
    final settings = await AppSettings.load(SettingsService());
    addTearDown(settings.dispose);
    return settings;
  }

  Future<void> pumpSettingsApp(WidgetTester tester, AppSettings settings) async {
    await tester.pumpWidget(
        Spliit2GoApp(settings: settings, home: const AppSettingsScreen()));
    await tester.pumpAndSettle();
  }

  void setDeviceLocales(WidgetTester tester, List<Locale> locales) {
    tester.platformDispatcher.localesTestValue = locales;
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  }

  group('language picker', () {
    testWidgets('switches the whole UI live, persists, and can return to system default',
        (tester) async {
      final settings = await loadSettings(tester);
      await pumpSettingsApp(tester, settings);
      expect(find.text('App settings'), findsOneWidget);
      expect(find.text('Language'), findsOneWidget);

      await tester.tap(find.text('Français'));
      await tester.pumpAndSettle();
      expect(find.text("Paramètres de l'application"), findsOneWidget);
      expect(find.text('App settings'), findsNothing);
      expect(await SettingsService().preferredLocaleTag(), 'fr');

      await tester.tap(find.text('简体中文'));
      await tester.pumpAndSettle();
      expect(find.text('应用设置'), findsOneWidget);
      expect(await SettingsService().preferredLocaleTag(), 'zh-CN');

      // "System default" in the current (Chinese) UI; the test device is
      // English, so clearing the override returns to English.
      await tester.tap(find.text('系统默认'));
      await tester.pumpAndSettle();
      expect(find.text('App settings'), findsOneWidget);
      expect(await SettingsService().preferredLocaleTag(), isNull);
    });

    testWidgets('the current choice is checked, and System default is checked initially',
        (tester) async {
      final settings = await loadSettings(tester);
      await pumpSettingsApp(tester, settings);

      Finder checkOn(String label) => find.descendant(
          of: find.widgetWithText(ListTile, label),
          matching: find.byIcon(Icons.check));

      expect(checkOn('System default'), findsOneWidget);
      expect(checkOn('Français'), findsNothing);

      await tester.tap(find.text('Français'));
      await tester.pumpAndSettle();
      expect(checkOn('Français'), findsOneWidget);
      expect(checkOn('Par défaut du système'), findsNothing);
    });

    testWidgets('a saved choice is applied at startup', (tester) async {
      SharedPreferences.setMockInitialValues({'preferred_locale_tag': 'fr'});
      final settings = await loadSettings(tester);
      await pumpSettingsApp(tester, settings);
      expect(find.text("Paramètres de l'application"), findsOneWidget);
    });

    testWidgets('a saved tag this build does not know falls back to the device locale',
        (tester) async {
      SharedPreferences.setMockInitialValues({'preferred_locale_tag': 'xx'});
      final settings = await loadSettings(tester);
      await pumpSettingsApp(tester, settings);
      expect(find.text('App settings'), findsOneWidget);
    });
  });

  group('device locale resolution with no override', () {
    testWidgets('a supported device language is used', (tester) async {
      setDeviceLocales(tester, const [Locale('fr', 'CA')]);
      await pumpSettingsApp(tester, await loadSettings(tester));
      expect(find.text("Paramètres de l'application"), findsOneWidget);
    });

    testWidgets('a Traditional-Chinese device falls back to the Simplified strings',
        (tester) async {
      setDeviceLocales(tester, const [Locale('zh', 'TW')]);
      await pumpSettingsApp(tester, await loadSettings(tester));
      expect(find.text('应用设置'), findsOneWidget);
    });

    testWidgets('an unsupported device language falls back to English',
        (tester) async {
      setDeviceLocales(tester, const [Locale('de', 'DE')]);
      await pumpSettingsApp(tester, await loadSettings(tester));
      expect(find.text('App settings'), findsOneWidget);
    });

    testWidgets('an explicit override wins over the device locale', (tester) async {
      setDeviceLocales(tester, const [Locale('fr', 'FR')]);
      SharedPreferences.setMockInitialValues({'preferred_locale_tag': 'zh-CN'});
      await pumpSettingsApp(tester, await loadSettings(tester));
      expect(find.text('应用设置'), findsOneWidget);
    });
  });

  group('formatters follow the resolved app locale, not the device locale', () {
    testWidgets('money and its position track the picker live', (tester) async {
      // Device is French, app starts on its explicit English override.
      setDeviceLocales(tester, const [Locale('fr', 'FR')]);
      SharedPreferences.setMockInitialValues({'preferred_locale_tag': 'en'});
      final settings = await loadSettings(tester);
      await tester.pumpWidget(Spliit2GoApp(
        settings: settings,
        home: Builder(
          builder: (context) =>
              Text(formatMoney(-123456, '€', locale: context.appLocale)),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('-€1,234.56'), findsOneWidget);

      await settings.setLocale(const Locale('fr'));
      await tester.pumpAndSettle();
      final shown =
          tester.widget<Text>(find.byType(Text)).data!.replaceAll(RegExp('[  ]'), ' ');
      expect(shown, '-1 234,56 €');
    });
  });

  group('French / Chinese root destinations', () {
    // gemineng's suggestion on #37: pump with a non-en locale and assert
    // the root destination labels render translated, not English.
    Future<void> pumpGroupScreen(WidgetTester tester, Locale locale) async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.cacheGroup(const Group(
        id: 'g1',
        name: 'Banff Trip',
        currency: '\$',
        participants: [Participant(id: 'p1', name: 'Ken')],
      ));
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw Exception('offline')),
      );
      final outbox = Outbox(db, client, groupId: 'g1');
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: GroupScreen(client: client, db: db, outbox: outbox, groupId: 'g1'),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> flush(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    }

    testWidgets('French', (tester) async {
      await pumpGroupScreen(tester, const Locale('fr'));
      expect(find.text('Dépenses'), findsWidgets);
      expect(find.text('Équilibres'), findsWidgets);
      expect(find.text('Statistiques'), findsWidgets);
      expect(find.text('Expenses'), findsNothing);
      expect(find.text('Balance'), findsNothing);
      expect(find.text('Stats'), findsNothing);
      await flush(tester);
    });

    testWidgets('Simplified Chinese', (tester) async {
      await pumpGroupScreen(tester, const Locale('zh', 'CN'));
      expect(find.text('消费'), findsWidgets);
      expect(find.text('余额'), findsWidgets);
      expect(find.text('统计'), findsWidgets);
      expect(find.text('Expenses'), findsNothing);
      await flush(tester);
    });
  });
}
