import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

/// `context.l10n.xxx` in place of the more verbose
/// `AppLocalizations.of(context)` at every call site (issue #37 phase
/// 1, per gemineng's suggestion in that issue's discussion).
/// `AppLocalizations.of` returns non-nullable here (see l10n.yaml's
/// `nullable-getter: false`) -- it asserts rather than returning null
/// if a [BuildContext] has no [Localizations] ancestor, which never
/// happens in this app: every route is built under [MaterialApp]'s own
/// `localizationsDelegates`/`supportedLocales` (see main.dart).
extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);

  /// The resolved app locale -- the language override from App settings if
  /// there is one, otherwise the device's (issue #51). Every money/date
  /// formatter call takes this as a required argument (never the device
  /// locale, and never a separately-tracked global like
  /// `Intl.defaultLocale`), so a live language switch reaches all of them.
  Locale get appLocale => Localizations.localeOf(this);
}
