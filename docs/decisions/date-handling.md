# Date/timezone handling: expenseDate is date-only, not a timestamp

**Status: fixed, `6a9b7a2` (2026-09-17).** [github.com/sharneng/spliit2go/issues/15](https://github.com/sharneng/spliit2go/issues/15).

## The question

Kenneth asked: do we actually know how the server normalizes date/time, and how are we converting it to local time? Good question to have asked before implementing more date-handling rather than after -- the existing handling turned out to be wrong in both directions, and the fix was only possible because we checked Spliit's actual source instead of guessing.

## Ground truth, verified against Spliit's own source (not guessed)

`expenseDate` is declared in Spliit's `prisma/schema.prisma` as:

```
expenseDate DateTime @default(dbgenerated("CURRENT_DATE")) @db.Date
```

`@db.Date` is Postgres's `DATE` type: a calendar date, no time-of-day, no timezone at all. Prisma still has to represent it as a JS `Date` object (JS has no bare "date" type), so it fixes the time at UTC midnight as a pure wire-format convention -- e.g. `2026-09-13T00:00:00.000Z`. Confirmed live too: fetched a real group's expenses (`groups.expenses.list`) once network access to spliit.app was allowlisted, and every `expenseDate` came back at exactly `T00:00:00.000Z`.

Spliit's own web app makes the intended handling explicit, in `src/lib/date-groups.ts`:

> `expenseDate` is a DATE column carried at UTC midnight, so it is converted with `dateOnlyToLocalDate` before classification; **parsing it directly would file it under the previous day west of UTC.**

And the actual conversion, `src/lib/utils.ts`:

```js
// Read: UTC Y/M/D -> local Date at that Y/M/D (midnight local)
export function dateOnlyToLocalDate(date: Date) {
  return new Date(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate())
}
```

And the write-side mirror, `src/app/groups/[groupId]/expenses/expense-form.tsx`:

```js
// Write: local Y/M/D -> Date fixed at UTC midnight on that Y/M/D
function getTodayForDateInput() {
  const now = new Date()
  return new Date(Date.UTC(now.getFullYear(), now.getMonth(), now.getDate()))
}
```

Neither direction is a real timezone conversion -- both just relabel the same three numbers (year, month, day) from one clock to the other. The "UTC" in the wire value is never meant to represent an actual moment in time; it's a serialization trick for a value that's fundamentally just a calendar date.

## What this client was doing wrong

Both directions, and both are real bugs affecting current data (not just future risk):

- **Read** (`group_screen.dart`): displayed `e.date.toLocal()` -- a genuine timezone conversion on a value that was never a real instant. For anyone west of UTC, this rolls the displayed date back a day. Confirmed against live data: Kenneth's "2026-09 Alaska" group (Alaska is UTC-8/9) is exactly the case this breaks.
- **Write** (`spliit_client.dart`'s `createExpense`, fed by the add-expense screen's `date: DateTime.now()` (`add_expense_screen.dart` then, `expense_screen.dart` now)): sent the actual current moment converted to UTC via `.toUtc()`, including real time-of-day. Entering an expense in the evening west of UTC can cross UTC midnight before the local calendar day changes, silently dating the expense a day late on the server.
- A third wrinkle: the local drift cache stores `DateTime` as epoch millis and reconstructs via `fromMillisecondsSinceEpoch` (local by default) on read, so the UTC-vs-local confusion got baked into the cache the first time a fetched expense round-tripped through it -- not just wherever it was displayed. The fix had to live at the parsing boundary, not the display boundary.

## Fix

Added `lib/services/date_only.dart` -- a direct port of Spliit's own `dateOnlyToLocalDate`/`getTodayForDateInput`:

- `dateOnlyFromUtcMidnight(DateTime utcMidnight)` -- reads the UTC year/month/day and rebuilds a local `DateTime` at midnight on that day. Used in `SpliitClient.fetchExpenses` wherever `expenseDate` is parsed.
- `dateOnlyToUtcMidnight(DateTime localDate)` -- reads the year/month/day off a local date (ignoring any time-of-day) and returns UTC midnight on that day. Used in `SpliitClient.createExpense` to build the outgoing `expenseDate`.
- Dropped the now-redundant `.toLocal()` in `GroupScreen`'s expense list -- `e.date` is already a correctly-decoded local calendar date by the time it reaches display code.

New tests: `date_only.dart`'s own unit tests (including a timezone-independent assertion that runs correctly regardless of the test machine's local zone), a `fetchExpenses` regression test pinning the exact calendar date, and two `createExpense` tests confirming a picked date (even at 11pm) and the no-date default both always encode as exact UTC midnight.

## Follow-up: backdating

At the time of this fix the add-expense screen had no date picker, so every expense was dated "today". That gap is closed: the expense form now has one (#16, see `expense-form-completion.md`), and it goes through `dateOnlyToUtcMidnight` like any other outgoing date.

## Standing practice going forward

Per Kenneth: for any future date-carrying field this app adds, check its actual semantics -- a real timestamp (where a true timezone conversion is correct) vs. a date-only value like this one (where it's actively wrong) -- against the schema or source before writing the parsing code, rather than assuming either way. This bug happened because the original implementation (ported from `splitwise2spliit`, which never displayed dates to a human in a different timezone) assumed "timestamp" without checking.
