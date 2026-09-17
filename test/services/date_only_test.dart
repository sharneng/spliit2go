import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/services/date_only.dart';

void main() {
  group('dateOnlyFromUtcMidnight', () {
    test('reads the UTC year/month/day, not a timezone-converted one', () {
      // The whole point: this has to give the same calendar date no
      // matter what timezone the machine running the test is in --
      // dateOnlyFromUtcMidnight doesn't look at the local offset at
      // all, unlike the .toLocal() this replaces (which would give a
      // different answer depending where the test runs).
      final result = dateOnlyFromUtcMidnight(DateTime.utc(2026, 9, 13));

      expect(result.year, 2026);
      expect(result.month, 9);
      expect(result.day, 13);
      expect(result.isUtc, isFalse);
    });

    test('is unaffected by a non-midnight time-of-day on the input', () {
      // Real server responses are always exact UTC midnight, but this
      // shouldn't silently produce a wrong day even if one weren't --
      // it only ever looks at year/month/day, so a stray time
      // component can't roll it over.
      final result = dateOnlyFromUtcMidnight(DateTime.utc(2026, 9, 13, 23, 59, 59));
      expect(result, DateTime(2026, 9, 13));
    });
  });

  group('dateOnlyToUtcMidnight', () {
    test('encodes the year/month/day as UTC midnight, dropping any time-of-day', () {
      // This is the actual regression this whole fix is about: picking
      // "today" in the evening, west of UTC, used to get converted with
      // .toUtc() and could land on the *next* UTC calendar day. Here,
      // 11pm shouldn't change which day gets sent.
      final result = dateOnlyToUtcMidnight(DateTime(2026, 9, 16, 23, 0));

      expect(result, DateTime.utc(2026, 9, 16));
      expect(result.isUtc, isTrue);
    });

    test('round-trips through dateOnlyFromUtcMidnight back to the same calendar date', () {
      final sent = dateOnlyToUtcMidnight(DateTime(2026, 9, 16, 8, 30));
      final readBack = dateOnlyFromUtcMidnight(sent);

      expect(readBack, DateTime(2026, 9, 16));
    });
  });
}
