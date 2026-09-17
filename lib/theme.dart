import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// spliit2go's light theme -- Material 3, seeded from [Colors.teal].
/// Paired with [spliit2goDarkTheme] below so the app actually has
/// something to switch to when the system is in dark mode (issue #25;
/// see the doc comment on [Spliit2GoApp]'s `MaterialApp` for why a
/// `darkTheme` was the whole bug).
ThemeData get spliit2goLightTheme => ThemeData(
      useMaterial3: true,
      colorSchemeSeed: Colors.teal,
      brightness: Brightness.light,
    );

/// spliit2go's dark theme -- same Material 3 + teal seed as
/// [spliit2goLightTheme], opposite [Brightness.dark], so system dark
/// mode gets a genuinely dark version of this app's own look rather
/// than a generic Material dark theme.
ThemeData get spliit2goDarkTheme => ThemeData(
      useMaterial3: true,
      colorSchemeSeed: Colors.teal,
      brightness: Brightness.dark,
    );

/// The system status/navigation bar styling for the given [theme]'s
/// current brightness -- issue #24 follow-up: without this, Android
/// draws the bottom gesture/nav bar as an opaque near-black scrim (its
/// "enforced contrast" background, meant for apps that never set a
/// color at all) instead of blending with the app underneath it, the
/// way most well-behaved edge-to-edge apps look. Matches the nav bar to
/// [ThemeData.scaffoldBackgroundColor] -- what a screen's own content
/// actually shows through to -- rather than a fixed color, so it stays
/// correct across both [spliit2goLightTheme] and [spliit2goDarkTheme]
/// and if that background ever changes.
///
/// Note: on a device targeting Android API 35+ (this app's default,
/// since Flutter's own build config doesn't override targetSdk),
/// `systemNavigationBarColor`/`systemNavigationBarContrastEnforced`
/// below are effectively no-ops -- `Window.setNavigationBarColor` is
/// documented as doing nothing once an app targets API 35, since
/// edge-to-edge (an always-transparent system nav bar) stops being
/// optional at that point. They're kept here anyway for whatever
/// pre-35 devices this app still runs on; the fix that actually matters
/// on a current device is main.dart's Container backdrop, which paints
/// Flutter-side content behind the now-unconditionally-transparent bar
/// instead of trying to recolor the bar itself.
///
/// The status bar fields here mostly just document intent -- every
/// screen in this app has an `AppBar`, and `AppBar` sets its own nested
/// `AnnotatedRegion` for the status bar that wins over this ancestor
/// one (Flutter resolves each `SystemUiOverlayStyle` field from the
/// nearest region that sets it, not the nearest region overall). They
/// still matter as the fallback for the brief window before the first
/// screen's `AppBar` mounts, and for any future screen that doesn't use
/// one.
SystemUiOverlayStyle spliit2goSystemUiOverlayStyle(ThemeData theme) {
  final navBarIsLight =
      ThemeData.estimateBrightnessForColor(theme.scaffoldBackgroundColor) == Brightness.light;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: navBarIsLight ? Brightness.dark : Brightness.light,
    statusBarBrightness: navBarIsLight ? Brightness.light : Brightness.dark,
    systemNavigationBarColor: theme.scaffoldBackgroundColor,
    systemNavigationBarIconBrightness: navBarIsLight ? Brightness.dark : Brightness.light,
    systemNavigationBarDividerColor: Colors.transparent,
    // Without this, Android 10+ paints a translucent scrim over
    // whatever color we ask for "for legibility" -- which is exactly
    // the deep-black look reported, since our chosen color gets
    // darkened underneath it.
    systemNavigationBarContrastEnforced: false,
  );
}
