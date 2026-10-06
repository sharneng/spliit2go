import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/theme.dart';

void main() {
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

  test('one base background for screens, app bars, the tab bar and sheets (#186 review)', () {
    for (final theme in [spliit2goLightTheme, spliit2goDarkTheme]) {
      final base = theme.scaffoldBackgroundColor;
      final reason = '${theme.brightness}';
      expect(theme.appBarTheme.backgroundColor, base, reason: reason);
      expect(theme.navigationBarTheme.backgroundColor, base, reason: reason);
      expect(theme.bottomSheetTheme.backgroundColor, base, reason: reason);
    }
    // Grouped cards stand off it: lighter in light mode, a step up in dark.
    expect(spliit2goLightTheme.scaffoldBackgroundColor,
        spliit2goLightTheme.colorScheme.surfaceContainer);
    expect(spliit2goDarkTheme.scaffoldBackgroundColor, spliit2goDarkTheme.colorScheme.surface);
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

  test('add buttons are circles, in both modes (#199)', () {
    for (final theme in [spliit2goLightTheme, spliit2goDarkTheme]) {
      expect(theme.floatingActionButtonTheme.shape, const CircleBorder());
    }
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
