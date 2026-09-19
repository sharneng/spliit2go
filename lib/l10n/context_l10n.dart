import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

/// `context.l10n.xxx` in place of the more verbose
/// `AppLocalizations.of(context)!.xxx` at every call site (issue #37
/// phase 1, per gemineng's suggestion in that issue's discussion). The
/// `!` is safe here the same way it is at every other call site: every
/// route in this app is built under [MaterialApp]'s own
/// `localizationsDelegates`/`supportedLocales` (see main.dart), so
/// `AppLocalizations.of` never actually returns null in a real screen
/// -- it's nullable only because the generated accessor has to account
/// for a [BuildContext] with no [Localizations] ancestor at all, which
/// doesn't happen here.
extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this)!;
}
