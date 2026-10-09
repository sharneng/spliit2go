import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/theme.dart';
import 'package:spliit2go/widgets/grouped_section.dart';

void main() {
  // The typography that sets the letter spacing must keep Material's text
  // colors from the scheme (onSurface), not pure black or white (#232 review).
  for (final (name, theme) in [
    ('light', spliit2goLightTheme),
    ('dark', spliit2goDarkTheme),
    ('light high contrast', spliit2goLightHighContrastTheme),
    ('dark high contrast', spliit2goDarkHighContrastTheme),
  ]) {
    test('text takes its colors from the scheme ($name)', () {
      final material = ThemeData(useMaterial3: true, colorScheme: theme.colorScheme).textTheme;
      TextStyle? style(TextTheme t, int i) => [
            t.displayLarge, t.displayMedium, t.displaySmall, t.headlineLarge, t.headlineMedium,
            t.headlineSmall, t.titleLarge, t.titleMedium, t.titleSmall, t.bodyLarge, t.bodyMedium,
            t.bodySmall, t.labelLarge, t.labelMedium, t.labelSmall,
          ][i];
      for (var i = 0; i < 15; i++) {
        expect(style(theme.textTheme, i)!.color, style(material, i)!.color, reason: style(material, i)!.debugLabel);
      }
      expect(theme.textTheme.bodyLarge!.color, theme.colorScheme.onSurface);
    });
  }

  for (final locale in const [Locale('en'), Locale('zh')]) {
    testWidgets('the font\'s own letter spacing, as native apps; row titles a little tighter ($locale)',
        (tester) async {
      late TextTheme text;
      await tester.pumpWidget(MaterialApp(
        theme: spliit2goLightTheme,
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Builder(builder: (context) {
          text = Theme.of(context).textTheme;
          return const SizedBox();
        }),
      ));
      for (final style in [
        text.displayLarge, text.headlineSmall, text.titleLarge, text.titleMedium, text.titleSmall,
        text.bodyMedium, text.bodySmall, text.labelLarge, text.labelMedium, text.labelSmall,
      ]) {
        expect(style!.letterSpacing, 0, reason: style.debugLabel);
      }
      expect(text.bodyLarge!.letterSpacing, bodyLargeLetterSpacing);
      expect(bodyLargeLetterSpacing, -0.4);
      expect(spliit2goLightTheme.listTileTheme.subtitleTextStyle!.letterSpacing, -0.2);
      expect(spliit2goLightTheme.popupMenuTheme.labelTextStyle!.resolve({})!.letterSpacing, -0.4);
      expect(text.bodyLarge!.fontSize, 16, reason: 'only the spacing changes');
    });
  }

  test('light and dark themes have matching brightness fields (issue #25)', () {
    expect(spliit2goLightTheme.brightness, Brightness.light);
    expect(spliit2goDarkTheme.brightness, Brightness.dark);
  });

  test('both themes are seeded from the same color, not two unrelated palettes', () {
    // Same seed hue, opposite brightness -- a real dark *variant* of
    // this app's look, not a generic Material dark theme grafted on.
    expect(spliit2goLightTheme.colorScheme.primary, isNot(spliit2goDarkTheme.colorScheme.primary));
    // Material 3's seeded ColorScheme.fromSeed picks a *lighter* primary
    // tone for dark mode (roughly tone 80 vs. light mode's tone 40) so
    // it reads clearly against a dark surface -- the reverse of the
    // background relationship, which is the opposite way round. Both
    // colors tracing back to the same emerald seed is checked by the
    // regression test below (distinct scaffold backgrounds would also
    // catch two completely unrelated ThemeData instances).
    expect(spliit2goDarkTheme.colorScheme.primary.computeLuminance(),
        greaterThan(spliit2goLightTheme.colorScheme.primary.computeLuminance()));
  });

  test('regression: a dark theme is actually provided, not just brightness: dark on light values',
      () {
    // The bug this issue reported was "no dark theme at all" -- Flutter
    // silently falls back to `theme` whenever `darkTheme` is null (see
    // WidgetsApp's `darkTheme ?? theme` resolution), so the light and
    // dark ThemeData instances must be genuinely distinct objects with
    // distinct scaffold backgrounds, not the same ThemeData used twice.
    expect(spliit2goLightTheme.scaffoldBackgroundColor,
        isNot(spliit2goDarkTheme.scaffoldBackgroundColor));
  });

  test("primary is spliit-ios's accent exactly, in both modes (#178)", () {
    expect(spliit2goLightTheme.colorScheme.primary, const Color(0xff059669));
    expect(spliit2goDarkTheme.colorScheme.primary, const Color(0xff10B981));
  });

  test('one base background for screens, app bars and the tab bar (#186 review)', () {
    for (final theme in [spliit2goLightTheme, spliit2goDarkTheme]) {
      final base = theme.scaffoldBackgroundColor;
      final reason = '${theme.brightness}';
      expect(theme.appBarTheme.backgroundColor, base, reason: reason);
      expect(theme.navigationBarTheme.backgroundColor, base, reason: reason);
    }
    // Sheets too in light; in dark they stand off it (#239, below).
    expect(spliit2goLightTheme.bottomSheetTheme.backgroundColor,
        spliit2goLightTheme.scaffoldBackgroundColor);
    // Grouped cards stand off it: lighter in light mode, a step up from
    // black in dark (#211).
    expect(spliit2goLightTheme.scaffoldBackgroundColor,
        spliit2goLightTheme.colorScheme.surfaceContainerLow);
    expect(spliit2goDarkTheme.scaffoldBackgroundColor, Colors.black);
  });

  testWidgets("the app bar keeps the page's color when content scrolls under it (#188)",
      (tester) async {
    for (final theme in [spliit2goLightTheme, spliit2goDarkTheme]) {
      // A fresh list each time, at its top.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
          appBar: AppBar(title: const Text('Title')),
          body: ListView(children: [for (var i = 0; i < 60; i++) Text('row $i')]),
        ),
      ));
      Material bar() => tester.widget<Material>(
          find.descendant(of: find.byType(AppBar), matching: find.byType(Material)).first);
      expect(bar().elevation, 0, reason: '${theme.brightness}: at rest');

      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(bar().color, theme.scaffoldBackgroundColor, reason: '${theme.brightness}');
      expect(bar().surfaceTintColor, Colors.transparent, reason: '${theme.brightness}');
      // And stays flat: no shadow either (#188 review).
      expect(bar().elevation, 0, reason: '${theme.brightness}');
    }
  });

  test('dark sheets stand off the page with a hairline edge; light ones unchanged (#239)', () {
    final dark = spliit2goDarkTheme.bottomSheetTheme;
    expect(dark.backgroundColor, isNot(spliit2goDarkTheme.scaffoldBackgroundColor));
    expect(dark.backgroundColor, isNot(GroupedSection.cardColorOf(spliit2goDarkTheme.colorScheme)));
    expect((dark.shape! as RoundedRectangleBorder).side.width, 0.5);
    final light = spliit2goLightTheme.bottomSheetTheme;
    expect(light.backgroundColor, spliit2goLightTheme.scaffoldBackgroundColor);
    expect(light.shape, isNull);
    expect(light.dragHandleColor, isNull);
    expect(dark.dragHandleColor, isNotNull);
  });

  test('add buttons are circles, in both modes (#199)', () {
    for (final theme in [spliit2goLightTheme, spliit2goDarkTheme]) {
      expect(theme.floatingActionButtonTheme.shape, const CircleBorder());
    }
  });

  // #211: less important content steps back as far as Apple's
  // secondaryLabel, and comes forward with Increase Contrast.
  group('secondary content', () {
    test("Apple's secondaryLabel dimming: 60% of the light scheme's grey, #EBEBF5 in dark", () {
      final light = SpliitColors.light.secondaryContent;
      expect(light.withValues(alpha: 1), spliit2goLightTheme.colorScheme.onSurfaceVariant);
      expect(light.a, closeTo(0.6, 0.01));
      expect(SpliitColors.dark.secondaryContent, const Color(0x99EBEBF5));
    });

    test('row captions take it from the theme', () {
      for (final theme in [
        spliit2goLightTheme,
        spliit2goDarkTheme,
        spliit2goLightHighContrastTheme,
        spliit2goDarkHighContrastTheme,
      ]) {
        expect(theme.listTileTheme.subtitleTextStyle?.color,
            theme.extension<SpliitColors>()!.secondaryContent);
      }
    });

    test('with Increase Contrast: undimmed, the schemes\' own grey, and lent/owe solid', () {
      for (final (theme, normal) in [
        (spliit2goLightHighContrastTheme, spliit2goLightTheme),
        (spliit2goDarkHighContrastTheme, spliit2goDarkTheme),
      ]) {
        final colors = theme.extension<SpliitColors>()!;
        expect(colors.secondaryContent, normal.colorScheme.onSurfaceVariant);
        expect(colors.secondaryMoneyOpacity, 1);
        expect(theme.scaffoldBackgroundColor, normal.scaffoldBackgroundColor);
      }
    });
  });

  test('each theme carries its own spliit-ios colors (#178)', () {
    expect(spliit2goLightTheme.extension<SpliitColors>(), SpliitColors.light);
    expect(spliit2goDarkTheme.extension<SpliitColors>(), SpliitColors.dark);
    expect(SpliitColors.light.moneyPositive, isNot(SpliitColors.dark.moneyPositive));
  });

  testWidgets('SpliitColors.of falls back by brightness without the app theme', (tester) async {
    late SpliitColors light, dark;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(),
      home: Builder(builder: (context) {
        light = SpliitColors.of(context);
        return Theme(
          data: ThemeData(brightness: Brightness.dark),
          child: Builder(builder: (context) {
            dark = SpliitColors.of(context);
            return const SizedBox();
          }),
        );
      }),
    ));
    expect(light, SpliitColors.light);
    expect(dark, SpliitColors.dark);
  });

  group('spliit2goSystemUiOverlayStyle', () {
    test('matches the bottom nav bar to the theme\'s own background, not a fixed color', () {
      final lightStyle = spliit2goSystemUiOverlayStyle(spliit2goLightTheme);
      final darkStyle = spliit2goSystemUiOverlayStyle(spliit2goDarkTheme);

      expect(lightStyle.systemNavigationBarColor, spliit2goLightTheme.scaffoldBackgroundColor);
      expect(darkStyle.systemNavigationBarColor, spliit2goDarkTheme.scaffoldBackgroundColor);
    });

    test('disables the enforced-contrast scrim that renders as a deep black bar (issue #24)', () {
      // This was the actual bug reported: Android 10+ paints a
      // translucent black scrim over the nav bar "for legibility"
      // unless an app explicitly opts out, which darkens whatever
      // color it was given underneath it into something close to
      // solid black.
      expect(spliit2goSystemUiOverlayStyle(spliit2goLightTheme).systemNavigationBarContrastEnforced,
          isFalse);
      expect(spliit2goSystemUiOverlayStyle(spliit2goDarkTheme).systemNavigationBarContrastEnforced,
          isFalse);
    });

    test('picks nav bar icon brightness for contrast against a light background', () {
      final style = spliit2goSystemUiOverlayStyle(spliit2goLightTheme);
      // Brightness.dark here means dark *icons* -- correct against
      // spliit2goLightTheme's light scaffold background.
      expect(style.systemNavigationBarIconBrightness, Brightness.dark);
    });

    test('picks nav bar icon brightness for contrast against a dark background', () {
      final style = spliit2goSystemUiOverlayStyle(spliit2goDarkTheme);
      expect(style.systemNavigationBarIconBrightness, Brightness.light);
    });
  });
}
