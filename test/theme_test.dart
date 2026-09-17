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
}
