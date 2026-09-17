/// Helpers for Spliit's "date-only" fields -- currently just an
/// expense's `expenseDate` -- which the server stores as a Postgres
/// `DATE` column (Prisma's `expenseDate DateTime @db.Date`): no
/// time-of-day, no timezone, just a calendar date.
///
/// Verified against Spliit's own source, not guessed -- see
/// decisions/date-handling.md for the full writeup and sources. Prisma
/// still has to represent a `DATE` value as a JS `Date`, so it fixes
/// the time at UTC midnight (e.g. `2026-09-13T00:00:00.000Z`) purely as
/// a wire-format convention. Spliit's own web app makes the intended
/// handling explicit in `src/lib/date-groups.ts`:
///
/// > `expenseDate` is a DATE column carried at UTC midnight, so it is
/// > converted with `dateOnlyToLocalDate` before classification;
/// > parsing it directly would file it under the previous day west of
/// > UTC.
///
/// These two functions are a direct port of that conversion
/// (`dateOnlyToLocalDate`) and its write-side mirror
/// (`getTodayForDateInput`, `src/app/groups/[groupId]/expenses/
/// expense-form.tsx`) -- read the UTC year/month/day as the literal
/// calendar date, and vice versa on write. Neither direction is a real
/// timezone conversion (that's exactly what NOT to do here); both are
/// just relabeling the same three numbers from one clock to another.
///
/// **When adding any new date-carrying field**, don't assume this
/// same handling applies -- check whether the field is genuinely a
/// point in time (a timestamp, where a real timezone conversion is
/// correct) or a date-only value like this one (where it isn't) before
/// writing the parsing code, the same way this one was checked against
/// the actual Prisma schema rather than assumed.
library;

/// Reads a date-only value received from the server: takes the UTC
/// year/month/day off [utcMidnight] and rebuilds a *local* [DateTime]
/// at midnight on that same calendar day.
///
/// Deliberately not `.toLocal()`, which performs a real timezone
/// conversion and rolls the date back a day for anyone west of UTC --
/// e.g. `2026-09-13T00:00:00Z` read with `.toLocal()` in a UTC-8 zone
/// becomes 2026-09-12, one day earlier than intended.
DateTime dateOnlyFromUtcMidnight(DateTime utcMidnight) {
  return DateTime(utcMidnight.year, utcMidnight.month, utcMidnight.day);
}

/// Encodes a date-only value to send to the server: takes the
/// year/month/day off [localDate] -- as they'd read on a wall calendar,
/// regardless of what timezone [localDate] itself carries -- and
/// returns a [DateTime] fixed at UTC midnight on that same calendar
/// day, the wire encoding `expenseDate` expects.
///
/// Deliberately not `.toUtc()`, which performs a real timezone
/// conversion on the actual current moment (including time-of-day) --
/// e.g. picking "today" at 8pm in a UTC-8 zone would convert to 4am
/// UTC *tomorrow*, silently dating the expense a day late on the
/// server.
DateTime dateOnlyToUtcMidnight(DateTime localDate) {
  return DateTime.utc(localDate.year, localDate.month, localDate.day);
}
