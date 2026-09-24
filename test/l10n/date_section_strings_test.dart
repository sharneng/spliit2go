import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/l10n/app_localizations.dart';

// Issue #91: Kenneth's final Chinese headings. The expense list and the
// activity log share these strings, so this covers both screens.
void main() {
  test('Chinese date-section headings', () {
    final zh = lookupAppLocalizations(const Locale('zh'));
    expect(
      [
        zh.activityToday,
        zh.activityYesterday,
        zh.dateSectionEarlierThisWeek,
        zh.dateSectionLastWeek,
        zh.dateSectionEarlierThisMonth,
        zh.dateSectionLastMonth,
        zh.dateSectionEarlierThisYear,
        zh.dateSectionLastYear,
        zh.dateSectionOlder,
      ],
      ['今天', '昨天', '本周前期', '上周', '本月初', '上个月', '今年初', '去年', '更早'],
    );
  });

  test('French week headings', () {
    final fr = lookupAppLocalizations(const Locale('fr'));
    expect(fr.dateSectionEarlierThisWeek, 'Plus tôt cette semaine');
    expect(fr.dateSectionLastWeek, 'La semaine dernière');
  });
}
