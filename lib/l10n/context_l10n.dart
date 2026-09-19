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
}
