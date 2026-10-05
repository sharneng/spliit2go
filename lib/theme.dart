import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared iOS-compatible identity colors; see THIRD_PARTY_NOTICES.md.
const monogramPalette = <Color>[
  Color(0xff059669),
  Color(0xff0891B2),
  Color(0xff6366F1),
  Color(0xffBE185D),
  Color(0xffEA580C),
  Color(0xffCA8A04),
  Color(0xff4D7C0F),
  Color(0xff7C3AED),
];

/// The green of the "Spliit" wordmark in spliit-ios (its `Logo` image,
/// sampled), used for the "Spliit2Go" title on the group list.
const spliitWordmarkGreen = Color(0xff56BC9C);

/// spliit-ios's `AccentColor`: emerald, lightened for dark mode (#178).
const _accentLight = Color(0xff059669);
const _accentDark = Color(0xff10B981);

ThemeData _appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final accent = dark ? _accentDark : _accentLight;
  // Seeded from the accent, with the accent itself as primary: a seeded
  // scheme alone would shift it to Material's own tone of that hue.
  final colorScheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: brightness,
    primary: accent,
  );
  final theme = ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    extensions: [dark ? SpliitColors.dark : SpliitColors.light],
  );
  return theme.copyWith(
    dividerTheme: DividerThemeData(
      color: theme.colorScheme.outlineVariant,
      thickness: 1,
    ),
  );
}

/// The colors spliit-ios adds on top of the system palette (its
/// `Palette.swift`; see THIRD_PARTY_NOTICES.md): the money axis and two
/// brand accents. Everything else comes from the color scheme.
@immutable
class SpliitColors extends ThemeExtension<SpliitColors> {
  const SpliitColors({
    required this.moneyPositive,
    required this.moneyNegative,
    required this.brandSecondary,
    required this.brandAccentSoft,
  });

  /// Owed to you.
  final Color moneyPositive;

  /// You owe.
  final Color moneyNegative;

  /// Rare by design: the occasional accent that isn't about money.
  final Color brandSecondary;

  /// The accent at a whisper, behind an empty state's icon.
  final Color brandAccentSoft;

  static const light = SpliitColors(
    moneyPositive: Color(0xff047857),
    moneyNegative: Color(0xffC2334A),
    brandSecondary: Color(0xffBE185D),
    brandAccentSoft: Color(0xffECFDF5),
  );

  static const dark = SpliitColors(
    moneyPositive: Color(0xff34D399),
    moneyNegative: Color(0xffFF8A9B),
    brandSecondary: Color(0xffEC4899),
    brandAccentSoft: Color(0x2910B981),
  );

  /// The app theme's colors, or the defaults for the ambient brightness
  /// where the theme has none (a test's bare MaterialApp).
  static SpliitColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<SpliitColors>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  SpliitColors copyWith({
    Color? moneyPositive,
    Color? moneyNegative,
    Color? brandSecondary,
    Color? brandAccentSoft,
  }) =>
      SpliitColors(
        moneyPositive: moneyPositive ?? this.moneyPositive,
        moneyNegative: moneyNegative ?? this.moneyNegative,
        brandSecondary: brandSecondary ?? this.brandSecondary,
        brandAccentSoft: brandAccentSoft ?? this.brandAccentSoft,
      );

  @override
  SpliitColors lerp(SpliitColors? other, double t) {
    if (other == null) return this;
    return SpliitColors(
      moneyPositive: Color.lerp(moneyPositive, other.moneyPositive, t)!,
      moneyNegative: Color.lerp(moneyNegative, other.moneyNegative, t)!,
      brandSecondary: Color.lerp(brandSecondary, other.brandSecondary, t)!,
      brandAccentSoft: Color.lerp(brandAccentSoft, other.brandAccentSoft, t)!,
    );
  }
}

/// spliit2go's light theme -- Material 3, seeded from spliit-ios's
/// emerald accent.
/// Paired with [spliit2goDarkTheme] below so the app actually has
/// something to switch to when the system is in dark mode (issue #25;
/// see the doc comment on [Spliit2GoApp]'s `MaterialApp` for why a
/// `darkTheme` was the whole bug).
ThemeData get spliit2goLightTheme => _appTheme(Brightness.light);

/// spliit2go's dark theme -- same Material 3 + emerald seed as
/// [spliit2goLightTheme], opposite [Brightness.dark], so system dark
/// mode gets a genuinely dark version of this app's own look rather
/// than a generic Material dark theme.
ThemeData get spliit2goDarkTheme => _appTheme(Brightness.dark);

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
      ThemeData.estimateBrightnessForColor(theme.scaffoldBackgroundColor) ==
          Brightness.light;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: navBarIsLight ? Brightness.dark : Brightness.light,
    statusBarBrightness: navBarIsLight ? Brightness.light : Brightness.dark,
    systemNavigationBarColor: theme.scaffoldBackgroundColor,
    systemNavigationBarIconBrightness:
        navBarIsLight ? Brightness.dark : Brightness.light,
    systemNavigationBarDividerColor: Colors.transparent,
    // Without this, Android 10+ paints a translucent scrim over
    // whatever color we ask for "for legibility" -- which is exactly
    // the deep-black look reported, since our chosen color gets
    // darkened underneath it.
    systemNavigationBarContrastEnforced: false,
  );
}
