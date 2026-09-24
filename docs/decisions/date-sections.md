# spliit2go: date sections in the expense list and the activity log (issues #88, #91)

**Status: implemented and merged** — the expense list in [#89](https://github.com/sharneng/spliit2go/pull/89) (closing [#88](https://github.com/sharneng/spliit2go/issues/88)), the activity log in [#94](https://github.com/sharneng/spliit2go/pull/94) (closing [#91](https://github.com/sharneng/spliit2go/issues/91)), both 2026-09-24.

Both lists used to be one long run of rows. spliit-web and spliit-ios split them into date sections ("This week", "Last month", ...), and Kenneth asked for the same, matching their behavior rather than inventing new rules. The rules were read from source before implementation (spliit-ios `ExpenseDateGroup.swift` and `ActivityDateGroup.swift` @ `80b2e98`; spliit-web `src/lib/date-groups.ts` and `activity-list.tsx` @ `cc79621`), written up on #88 and #91, and agreed there with Kenneth and Ezra.

## The sections

**Expenses: seven** (`lib/services/expense_date_group.dart`). **Activity: nine** (`lib/services/activity_date_group.dart`), finer at the recent end, because most of a log is from the last day or two, where "This week" would be the whole screen.

| Expenses | Activity |
|---|---|
| Upcoming (after today) | Today (also any future time) |
| This week | Yesterday |
| Earlier this month | Earlier this week |
| Last month | Last week |
| Earlier this year | Earlier this month |
| Last year | Last month |
| Older | Earlier this year |
| | Last year |
| | Older |

- **First match wins**, checked top to bottom against today. So a week that crosses a month boundary stays "This week", and in January, last December is "Last month" and "Last year" covers only January to November.
- **Empty sections are skipped.**
- The two rule sets are **two small pure functions, not one configurable framework** (Ezra's call on #91): they differ enough that a shared abstraction would be harder to read than either on its own.

## Decisions

1. **An expense date is a calendar date; an activity time is a moment.** The expense list groups by the stored calendar date (see [date-handling.md](date-handling.md)), ignoring any time of day an offline-added expense carries. That avoids a spliit-ios bug that files expenses a day early west of UTC. Activity times stay exact instants in the model and are converted with `toLocal()` where they're grouped and shown, with the same local value for the section and the row. Before #91 they were shown and grouped in UTC, so an edit at 22:30 in New York appeared as "02:30" under the next day. The shared `formatDate` was deliberately left alone: converting every input there would break expense dates.
2. **The week starts where the phone's region says** (Kenneth, #88): Sunday for `en_US`, Monday for `en_GB` or `fr_FR`, decided by region, not language. A locale with no region falls back to its language's default, then Monday, as spliit-web does. `firstWeekdayFor`, shared by both lists.
3. **Day arithmetic uses calendar dates, not durations** (Ezra, #91). A local day spanning a daylight-saving change is 23 or 25 hours long, so "Yesterday" can't be `difference().inDays == 1`. Both lists build their boundaries with calendar constructors: the expense list on local dates, and the activity log on UTC dates made from each moment's local date. "Now" is read once per grouping pass.
4. **Same-day expenses: newest created first** (Kenneth, #88), matching Spliit's own `expenseDate desc, createdAt desc`. This needed the server's `createdAt`, which the client used to discard: it's now parsed from `groups.expenses.list`/`get` and cached in a new nullable `expenses.created_at` column (schema 10). An expense added offline carries the device's time until a refresh brings the server's; rows cached before the change sort last in their day until the group is refreshed.
5. **Headings aren't sticky** (Kenneth, #88), styled like spliit-ios: small, bold, uppercase and muted, so they read as dividers. Screen readers get them in normal case, as headings. One shared `SectionHeading` widget.
6. **Rows under Today and Yesterday show only the time;** elsewhere in the activity log, date and time, since those headings name a span of days.
7. **The activity log loads as you scroll** (Kenneth, #91), with no "Load more" button: the next page starts within 400 px of the end, one request at a time; a failure keeps what's loaded and shows an inline Retry.
8. **Translations:** headings reuse spliit-web's en/fr wording; Kenneth supplied the final Chinese on #91, applied to both lists.
