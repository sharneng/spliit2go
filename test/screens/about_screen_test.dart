import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/app_name.dart';
import 'package:spliit2go/legal/upstream_licenses.dart';
import 'package:spliit2go/main.dart';
import 'package:spliit2go/screens/about_screen.dart';
import 'package:spliit2go/screens/app_settings_screen.dart';
import 'package:spliit2go/services/build_info.dart';
import 'package:spliit2go/services/app_settings.dart';
import 'package:spliit2go/services/settings_service.dart';

// #109: the About screen, its "unofficial client" notice, its links, and
// Spliit's and spliit-ios's notices on the licenses page.
void main() {
  setUp(() {
    // The real loader, through App settings: a build without a commit.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.sharneng.spliit2go/build_info'), (call) async => '');
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Spliit2Go',
      packageName: 'com.sharneng.spliit2go',
      version: '1.2.3',
      buildNumber: '45',
      buildSignature: '',
    );
  });

  Future<void> pumpAbout(WidgetTester tester,
      {Locale? locale, LinkOpener? openLink, BuildCommit commit = const BuildCommit('')}) async {
    final settings = await AppSettings.load(SettingsService());
    addTearDown(settings.dispose);
    if (locale != null) await settings.setLocale(locale);
    await tester.pumpWidget(Spliit2GoApp(
        settings: settings,
        home: openLink == null
            ? AboutScreen(loadCommit: () async => commit)
            : AboutScreen(openLink: openLink, loadCommit: () async => commit)));
    await tester.pumpAndSettle();
  }

  testWidgets('App settings opens About, with the version and the notice', (tester) async {
    final settings = await AppSettings.load(SettingsService());
    addTearDown(settings.dispose);
    await tester.pumpWidget(Spliit2GoApp(settings: settings, home: const AppSettingsScreen()));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('About Spliit2Go'), 200);
    // All of it, not just its top edge, so the tap lands on it.
    await tester.ensureVisible(find.text('About Spliit2Go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About Spliit2Go'));
    await tester.pumpAndSettle();

    expect(find.byType(AboutScreen), findsOneWidget);
    expect(find.text(appName), findsOneWidget);
    expect(find.text('Version 1.2.3 (45 · unknown)'), findsOneWidget);
    expect(find.byTooltip('Copy version and commit'), findsNothing);
    expect(
        find.text('An unofficial, community-made client for Spliit. '
            "It isn't affiliated with or endorsed by the Spliit project."),
        findsOneWidget);
  });

  testWidgets('the notice and version in French and Chinese', (tester) async {
    await pumpAbout(tester, locale: const Locale('fr'));
    expect(find.text('À propos'), findsOneWidget);
    expect(find.textContaining('Un client Spliit non officiel'), findsOneWidget);
    expect(find.text('Version 1.2.3 (45 · inconnu)'), findsOneWidget);

    await pumpAbout(tester, locale: const Locale('zh'));
    expect(find.text('关于'), findsOneWidget);
    expect(find.textContaining('非官方 Spliit 客户端'), findsOneWidget);
    expect(find.text('版本 1.2.3（45 · 未知）'), findsOneWidget);
  });

  // #176: the commit the Android or iOS build wrote, shortened, with a
  // button that copies it in full.
  const sha = '2d83fa3c4b5a69788796a5b4c3d2e1f00a1b2c3d';

  testWidgets('the short commit follows the build number, and Copy copies it all',
      (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() =>
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await pumpAbout(tester, commit: const BuildCommit('$sha-dirty'));
    expect(find.text('Version 1.2.3 (45 · 2d83fa3-dirty)'), findsOneWidget);

    await tester.tap(find.byTooltip('Copy version and commit'));
    await tester.pump();
    expect(copied, ['$appName 1.2.3 (45 · $sha-dirty)']);
    expect(find.text('Version and commit copied'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpAbout(tester, commit: const BuildCommit(sha), locale: const Locale('zh'));
    expect(find.text('版本 1.2.3（45 · 2d83fa3）'), findsOneWidget);
  });

  testWidgets('the version shows before the commit has loaded', (tester) async {
    final settings = await AppSettings.load(SettingsService());
    addTearDown(settings.dispose);
    final commit = Completer<BuildCommit>();
    await tester.pumpWidget(Spliit2GoApp(
        settings: settings, home: AboutScreen(loadCommit: () => commit.future)));
    await tester.pumpAndSettle();
    expect(find.text('Version 1.2.3 (45)'), findsOneWidget);

    commit.complete(const BuildCommit(sha));
    await tester.pumpAndSettle();
    expect(find.text('Version 1.2.3 (45 · 2d83fa3)'), findsOneWidget);
  });

  testWidgets('each link opens its page', (tester) async {
    final opened = <Uri>[];
    await pumpAbout(tester, openLink: (url) async {
      opened.add(url);
      return true;
    });

    for (final title in ['Spliit', 'Source code', 'Help and feedback', 'Privacy policy']) {
      await tester.ensureVisible(find.widgetWithText(ListTile, title));
      await tester.tap(find.widgetWithText(ListTile, title));
      await tester.pump();
    }
    expect(opened, [
      Uri.parse('https://spliit.app'),
      Uri.parse('https://github.com/sharneng/spliit2go'),
      Uri.parse('https://github.com/sharneng/spliit2go/issues'),
      Uri.parse('https://github.com/sharneng/spliit2go/blob/main/docs/privacy.md'),
    ]);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a link nothing can open says so', (tester) async {
    await pumpAbout(tester, openLink: (_) async => false);
    await tester.ensureVisible(find.widgetWithText(ListTile, 'Source code'));
    await tester.tap(find.widgetWithText(ListTile, 'Source code'));
    await tester.pump();
    expect(find.text("Couldn't open https://github.com/sharneng/spliit2go."), findsOneWidget);
  });

  testWidgets('Open-source licenses opens the licenses page', (tester) async {
    await pumpAbout(tester);
    await tester.scrollUntilVisible(find.text('Open-source licenses'), 200);
    await tester.tap(find.text('Open-source licenses'));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
  });

  test("Spliit's and spliit-ios's MIT notices are registered once", () async {
    registerUpstreamLicenses();
    registerUpstreamLicenses();
    final entries = await LicenseRegistry.licenses
        .where((e) => e.packages.any((p) => p == 'Spliit' || p == 'spliit-ios'))
        .toList();
    String text(LicenseEntry e) => e.paragraphs.map((p) => p.text).join('\n');
    expect(entries.map((e) => e.packages.single), ['Spliit', 'spliit-ios']);
    expect(text(entries[0]), contains('Copyright (c) 2023 Sebastien Castiel'));
    expect(text(entries[1]), contains('Copyright (c) 2026 Sebastien Castiel'));
    expect(text(entries[0]),
        contains('this permission notice (including the next paragraph) shall be included'));
    expect(text(entries[1]), contains('this permission notice shall be included'));
    for (final e in entries) {
      expect(text(e), contains('THE SOFTWARE IS PROVIDED "AS IS"'));
    }
  });
}
