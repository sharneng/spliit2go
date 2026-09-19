import 'package:flutter/widgets.dart';

/// One language the app-settings language picker offers (issue #51).
class AppLocaleOption {
  const AppLocaleOption(this.tag, this.locale, this.nativeName);

  /// The string persisted in `SettingsService` for this choice.
  final String tag;

  final Locale locale;

  /// The language's own name for itself, shown as-is in every UI language
  /// so someone who ended up in a language they can't read can still find
  /// theirs. Deliberately not in the ARB files.
  final String nativeName;
}

/// Every language the picker offers, in display order. Keep in step with
/// the ARB files in lib/l10n: each entry here needs a matching
/// `app_<locale>.arb`, or `AppLocalizations.supportedLocales` won't
/// contain it and Flutter will silently resolve to another language.
///
/// Chinese ships as Simplified only (`app_zh_CN.arb`). A device set to a
/// Traditional-script locale (`zh_TW`, `zh_HK`, `zh_Hant`) is not offered
/// its own option; Flutter's default locale resolution falls it back to
/// this Simplified entry by language-only matching, which is better than
/// English for a Chinese reader. Adding `app_zh_TW.arb` later is a new
/// sibling file plus one entry here -- no rename.
const List<AppLocaleOption> appLocaleOptions = [
  AppLocaleOption('en', Locale('en'), 'English'),
  AppLocaleOption('fr', Locale('fr'), 'Français'),
  AppLocaleOption('zh-CN', Locale('zh', 'CN'), '简体中文'),
];

/// The locale a persisted [tag] stands for, or null ("System default") for
/// no override -- including a tag this build doesn't know (say, written by
/// a newer version, or a locale that was later dropped), so a stale value
/// can never strand the app in an unsupported language.
Locale? localeFromTag(String? tag) {
  for (final option in appLocaleOptions) {
    if (option.tag == tag) return option.locale;
  }
  return null;
}

/// The tag to persist for [locale]; null for no override.
String? tagFromLocale(Locale? locale) {
  if (locale == null) return null;
  for (final option in appLocaleOptions) {
    if (option.locale == locale) return option.tag;
  }
  return null;
}
