import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'widgets/grouped_section.dart';
import 'widgets/top_bar_buttons.dart';

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

ThemeData _appTheme(Brightness brightness, {bool highContrast = false}) {
  final dark = brightness == Brightness.dark;
  final spliitColors = switch ((dark, highContrast)) {
    (false, false) => SpliitColors.light,
    (true, false) => SpliitColors.dark,
    (false, true) => SpliitColors.lightHighContrast,
    (true, true) => SpliitColors.darkHighContrast,
  };
  final accent = dark ? _accentDark : _accentLight;
  // Seeded from the accent, with the accent itself as primary: a seeded
  // scheme alone would shift it to Material's own tone of that hue. In
  // dark mode the red of delete buttons, destructive menu rows and errors
  // is the amount red: Material's own (#FFB4AB) is a pale pink that reads
  // faint (#217, Kenneth).
  final colorScheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: brightness,
    primary: accent,
    error: dark ? SpliitColors.dark.moneyNegative : null,
  );
  final theme = ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    // The system font's own letter spacing, as native apps on iOS, stock
    // Android and One UI have it: Material 3's type scale adds up to half
    // a point between letters (0.5 on body text), which spread ours wider
    // than any of them (#231, Kenneth).
    // With the scheme, as ThemeData's own default, so text keeps its
    // onSurface color rather than pure black or white (#232 review).
    typography: Typography.material2021(
      platform: defaultTargetPlatform,
      colorScheme: colorScheme,
      englishLike: _systemLetterSpacing(Typography.englishLike2021),
      dense: _systemLetterSpacing(Typography.dense2021),
      tall: _systemLetterSpacing(Typography.tall2021),
    ),
    extensions: [spliitColors],
  );
  // One base background for every screen, its app bar, the group
  // screen's tab bar and sheets (#186 review), so nothing changes color
  // from screen to screen, nor in the strip under them that the app
  // paints in this color (main.dart). Grouped cards (GroupedSection)
  // stand a step lighter off it.
  // Black in dark mode, as iOS's grouped screens; in light mode a step
  // lighter than Material's surfaceContainer, so the dimmed section
  // headers on it read as well as the captions on the cards (#211).
  final base = dark ? Colors.black : colorScheme.surfaceContainerLow;
  // The add buttons' color, which the group screen's selected tab is
  // highlighted in too, so the bar and the button read as one set
  // (#215).
  final addColor = colorScheme.primaryContainer;
  final onAddColor = colorScheme.onPrimaryContainer;
  // Menus in the page's color in light mode, the lines' between card rows
  // too; in dark the cards', since the lines' lighter tone over a whole
  // menu left the emerald check and the red under 4.5:1 (#217, Kenneth).
  final menuColor = dark ? GroupedSection.cardColorOf(colorScheme) : base;
  return theme.copyWith(
    scaffoldBackgroundColor: base,
    // The bar keeps the page's color when content scrolls under it,
    // flat, instead of Material's darker tint and shadow (#188).
    // Back and close in a circle, as the top bar's other buttons (#228).
    actionIconTheme: ActionIconThemeData(
      // Flutter's own back icons (BackButtonIcon): on iOS the centered
      // rounded chevron, not Icons.adaptive's, which sits left in its box.
      backButtonIconBuilder: (context) => topBarCircleIcon(
          context,
          switch (Theme.of(context).platform) {
            TargetPlatform.iOS || TargetPlatform.macOS => Icons.arrow_back_ios_new_rounded,
            _ => Icons.arrow_back,
          }),
      closeButtonIconBuilder: (context) => topBarCircleIcon(context, Icons.close),
    ),
    appBarTheme: AppBarTheme(
      leadingWidth: TopBarButtons.leadingWidth,
      backgroundColor: base,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
    ),
    // Menus as One UI's pop-up menus (#217), on every platform: in
    // [menuColor], well rounded, with a soft shadow and no tint, dropping
    // below their button rather than covering it.
    popupMenuTheme: PopupMenuThemeData(
      color: menuColor,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: dark ? 0.6 : 0.25),
      // A hairline edge, so the menu reads on a page or card of nearly its
      // own color: a shade darker in light mode, and in dark a shade
      // lighter, halfway to the lines' tone between card rows, since a
      // darker edge vanishes on the black page (#217, Kenneth).
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
              width: 0.5,
              color: dark
                  ? Color.lerp(menuColor, GroupedDivider.darkColor, 0.5)!
                  : Color.alphaBlend(Colors.black.withValues(alpha: 0.08), menuColor))),
      menuPadding: const EdgeInsets.symmetric(vertical: 8),
      position: PopupMenuPosition.under,
      // 17, as iOS's body text, a step over bodyLarge's 16, so the
      // labels hold their own beside the 24pt icons.
      // Dimmed when disabled, as Material's own menu style does: the menu
      // relies on this style to dim a disabled row's label (#227 review).
      labelTextStyle: WidgetStateProperty.resolveWith((states) =>
          theme.textTheme.bodyLarge?.copyWith(
              fontSize: 17,
              letterSpacing: bodyLargeLetterSpacing,
              color: states.contains(WidgetState.disabled)
                  ? colorScheme.onSurface.withValues(alpha: 0.38)
                  : colorScheme.onSurface)),
      iconColor: colorScheme.onSurfaceVariant,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: base,
      indicatorColor: addColor,
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? onAddColor
              : colorScheme.onSurfaceVariant)),
    ),
    // In dark, sheets a step off the black page, 2/3 of the way to the
    // cards, so a sheet stands off the dimmed screen behind it and its own
    // cards still stand off it (#239). The handle dimmed, as iOS's
    // grabber.
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor:
          dark ? Color.lerp(base, GroupedSection.cardColorOf(colorScheme), 2 / 3) : base,
      dragHandleColor: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
      // And a hairline lighter edge in dark, as iOS's sheets, to mark
      // where the sheet ends; Material's own corners.
      shape: dark
          ? RoundedRectangleBorder(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.15), width: 0.5),
            )
          : null,
    ),
    // The add buttons are round, as spliit-ios's, not Material's rounded
    // square (#199).
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      shape: const CircleBorder(),
      backgroundColor: addColor,
      foregroundColor: onAddColor,
    ),
    // Captions under a row's title (dates, counts, who paid) in the
    // dimmed secondary color, a step back from the titles (#211).
    listTileTheme: ListTileThemeData(
      // Rows a step more compact than Material's (#233), nearer iOS's:
      // 4 off each default height, 52 for one line, 68 for two.
      visualDensity: const VisualDensity(vertical: -1),
      subtitleTextStyle:
          theme.textTheme.bodyMedium?.copyWith(
              color: spliitColors.secondaryContent, letterSpacing: captionLetterSpacing),
    ),
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
    required this.secondaryContent,
    required this.secondaryMoneyOpacity,
  });

  /// Owed to you.
  final Color moneyPositive;

  /// You owe.
  final Color moneyNegative;

  /// Rare by design: the occasional accent that isn't about money.
  final Color brandSecondary;

  /// The accent at a whisper, behind an empty state's icon.
  final Color brandAccentSoft;

  /// Less important text and icons, a step back from the content:
  /// section headers, row captions, marks (#211). Apple's
  /// `secondaryLabel` at its 60%, rather than WCAG AA's 4.5:1, which
  /// Apple's own secondary text doesn't meet and which read as too loud
  /// next to it (Kenneth). Undimmed with the system's Increase Contrast.
  final Color secondaryContent;

  /// How much of their color what you lent or owe keeps (#211).
  final double secondaryMoneyOpacity;

  static const light = SpliitColors(
    moneyPositive: Color(0xff047857),
    moneyNegative: Color(0xffC2334A),
    brandSecondary: Color(0xffBE185D),
    brandAccentSoft: Color(0xffECFDF5),
    // The light scheme's onSurfaceVariant at 60%.
    secondaryContent: Color(0x99404943),
    secondaryMoneyOpacity: 0.9,
  );

  static const dark = SpliitColors(
    moneyPositive: Color(0xff34D399),
    moneyNegative: Color(0xffFF8A9B),
    brandSecondary: Color(0xffEC4899),
    brandAccentSoft: Color(0x2910B981),
    // Apple's dark secondaryLabel exactly: the dark scheme's
    // onSurfaceVariant is a mid grey already, which dimmed would sit
    // well below it.
    secondaryContent: Color(0x99EBEBF5),
    secondaryMoneyOpacity: 0.9,
  );

  /// With the system's Increase Contrast: secondary content undimmed,
  /// the light and dark schemes' onSurfaceVariant.
  static final lightHighContrast = light.copyWith(
      secondaryContent: const Color(0xff404943), secondaryMoneyOpacity: 1);
  static final darkHighContrast = dark.copyWith(
      secondaryContent: const Color(0xffC0C9C1), secondaryMoneyOpacity: 1);

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
    Color? secondaryContent,
    double? secondaryMoneyOpacity,
  }) =>
      SpliitColors(
        moneyPositive: moneyPositive ?? this.moneyPositive,
        moneyNegative: moneyNegative ?? this.moneyNegative,
        brandSecondary: brandSecondary ?? this.brandSecondary,
        brandAccentSoft: brandAccentSoft ?? this.brandAccentSoft,
        secondaryContent: secondaryContent ?? this.secondaryContent,
        secondaryMoneyOpacity: secondaryMoneyOpacity ?? this.secondaryMoneyOpacity,
      );

  @override
  SpliitColors lerp(SpliitColors? other, double t) {
    if (other == null) return this;
    return SpliitColors(
      moneyPositive: Color.lerp(moneyPositive, other.moneyPositive, t)!,
      moneyNegative: Color.lerp(moneyNegative, other.moneyNegative, t)!,
      brandSecondary: Color.lerp(brandSecondary, other.brandSecondary, t)!,
      brandAccentSoft: Color.lerp(brandAccentSoft, other.brandAccentSoft, t)!,
      secondaryContent: Color.lerp(secondaryContent, other.secondaryContent, t)!,
      secondaryMoneyOpacity:
          lerpDouble(secondaryMoneyOpacity, other.secondaryMoneyOpacity, t)!,
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

/// The themes with the system's Increase Contrast on (iOS's
/// accessibility setting; MaterialApp picks them by itself): secondary
/// content undimmed (#211).
ThemeData get spliit2goLightHighContrastTheme =>
    _appTheme(Brightness.light, highContrast: true);
ThemeData get spliit2goDarkHighContrastTheme => _appTheme(Brightness.dark, highContrast: true);

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

/// Row titles' and menu labels' letter spacing, a little tighter than the
/// font's own, so long titles fit.
const bodyLargeLetterSpacing = -0.4;

/// Row captions' (dates, who paid, counts).
const captionLetterSpacing = -0.2;

/// [theme] with no letter spacing added to the font's own.
TextTheme _systemLetterSpacing(TextTheme theme) {
  TextStyle? none(TextStyle? style, [double spacing = 0]) => style?.copyWith(letterSpacing: spacing);
  return TextTheme(
    displayLarge: none(theme.displayLarge),
    displayMedium: none(theme.displayMedium),
    displaySmall: none(theme.displaySmall),
    headlineLarge: none(theme.headlineLarge),
    headlineMedium: none(theme.headlineMedium),
    headlineSmall: none(theme.headlineSmall),
    titleLarge: none(theme.titleLarge),
    titleMedium: none(theme.titleMedium),
    titleSmall: none(theme.titleSmall),
    bodyLarge: none(theme.bodyLarge, bodyLargeLetterSpacing),
    bodyMedium: none(theme.bodyMedium),
    bodySmall: none(theme.bodySmall),
    labelLarge: none(theme.labelLarge),
    labelMedium: none(theme.labelMedium),
    labelSmall: none(theme.labelSmall),
  );
}
