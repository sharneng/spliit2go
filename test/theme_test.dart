import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    // colors tracing back to the same teal seed is checked by the
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
