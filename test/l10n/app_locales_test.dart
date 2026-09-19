import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/l10n/app_locales.dart';

void main() {
  test('every picker option round-trips through its persisted tag', () {
    for (final option in appLocaleOptions) {
      expect(localeFromTag(option.tag), option.locale);
      expect(tagFromLocale(option.locale), option.tag);
    }
  });

  test('no override (null) maps to and from a null tag', () {
    expect(localeFromTag(null), isNull);
    expect(tagFromLocale(null), isNull);
  });

  test('a tag this build does not know is treated as no override', () {
    expect(localeFromTag('xx'), isNull);
    expect(localeFromTag(''), isNull);
    // Traditional Chinese isn't shipped yet -- a stale/foreign tag must
    // not strand the app in an unsupported language.
    expect(localeFromTag('zh-TW'), isNull);
  });

  test('a locale that is not a picker option has no tag', () {
    expect(tagFromLocale(const Locale('de')), isNull);
  });

  test('every picker option has a matching generated ARB locale', () {
    // Guards the "each entry needs an app_<locale>.arb" rule in
    // app_locales.dart: a picker option Flutter can't localize would
    // silently show another language.
    for (final option in appLocaleOptions) {
      expect(AppLocalizations.supportedLocales, contains(option.locale),
          reason: '${option.tag} has no app_*.arb');
    }
  });

  test('Simplified Chinese is filed as zh_CN, not bare zh', () {
    expect(AppLocalizations.supportedLocales,
        contains(const Locale('zh', 'CN')));
  });
}
