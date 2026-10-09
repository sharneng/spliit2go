# spliit2go: currency conversion and exchange rates (issues #251, #252)

Written 2026-10-09. **Status: designed, not built.** Kenneth asked for this as the last part of the UI Polished milestone: restyle the add/edit expense screen, and finish currency conversion along the way. This records the research into spliit-web and spliit-ios, and the design agreed with Kenneth: where rates come from, how they're kept on the phone, and how they can be downloaded ahead before going offline.

Sources checked: spliit-web at b73d551 (`prisma/schema.prisma`, `src/lib/schemas.ts`, `src/lib/currency-conversion.ts`, `src/lib/hooks.ts`, `expense-form.tsx`), spliit-ios at 2e25cb4 (`ExchangeRates.swift`, `ExpenseFormDraft.swift`, `ExpenseFormView.swift`, from its #32), and the Frankfurter API, probed on 2026-10-09.

## How Spliit stores a conversion

An expense has three nullable columns besides `amount`:

| Column | Meaning |
|---|---|
| `amount` | In the group's currency, in its minor units. **The only amount balances use.** |
| `originalCurrency` | The ISO code the expense was paid in. Its presence is what says "converted". |
| `originalAmount` | What was paid, in the **original currency's own minor units**. Web stored this in whole units until its PR #425, and repaired the old rows with migration `20260812213708_backfill_original_amount_minor_units`. |
| `conversionRate` | `Decimal(65,30)`: 1 whole unit of the original currency in whole units of the group's currency. A rate between whole units, so it can't be applied to the two minor-unit columns directly (below). |

The two amounts are in different minor units, so the stored values are related through each currency's number of decimal places (`groupDigits`, `originalDigits`):

```
amountMinor         = round(originalAmountMinor × rate × 10^groupDigits / 10^originalDigits)
originalAmountMinor = round(amountMinor ÷ rate × 10^originalDigits / 10^groupDigits)   (settlements)
```

For example, ¥1,000 (stored as `1000`, JPY has no decimal places) at 0.006 EUR per JPY is €6.00, stored as `600` in a euro group. `1000 × 0.006` would give `6`, which is €0.06. spliit-web works the same way: `convertToGroupCurrency` multiplies the form's whole-unit amount and rounds to the destination currency's decimal places, and only then is the result stored in minor units. spliit-ios's `convertedAmountMinorUnits` uses the first formula.

- **Only `originalCurrency` can be cleared.** The server accepts `null` for it. For `originalAmount` and `conversionRate` it rejects `null` and treats a missing field as "leave it". So an expense switched back to the group's currency keeps its old amount and rate in the database. Every reader ignores them while `originalCurrency` is null, and so must spliit2go.
- **A group with only a custom symbol can't convert:** there's no ISO code to convert to. Both apps turn the feature off there.

## What spliit-web and spliit-ios do

| | spliit-web | spliit-ios |
|---|---|---|
| Picking the currency | "Currency of expense" picker, always shown | "Paid in" row, a picker of ~159 ISO currencies |
| Group-currency total | Follows the converted amount, but **stays editable**, so it can disagree with the rate | **Calculated and read-only** during a conversion, so an expense can't be saved with a rate that doesn't explain its total |
| Rate source | Frankfurter v1, `base=<original>`, all quotes | Frankfurter v1, one pair |
| Rate field | Hidden behind "Use custom rate" | Always shown, filled in automatically, a typed rate is never overwritten |
| Rate status | "Obtained rates: X 1 = Y r", "Rates from date: …", Refresh | The quote, "— the rate on {day}" when the day differs, "Using the rate you entered", "Use the published rate" only when it would change something |
| Settlements | Reversed: the amount settled is fixed, "Amount to transfer" is calculated and read-only | Not handled |
| Shares by amount | Each share can be typed in the original currency (converted, not saved) | No |
| Original amount shown | On the expense card, and in the CSV export | Only on the form |
| Changing currency | — | Clears the rate, keeps the amount paid. Switching back keeps the converted total as the amount |
| Clearing a conversion | Leaves `originalCurrency` out, so the server keeps it | Always sends `originalCurrency`, `null` when there is none |

## Where spliit2go stood

#16 added a "Paid in other currency" checkbox with an original amount and a currency code. You typed both totals and the app worked out the rate as `amountCents / originalAmountCents`. It never looked a rate up; that was left out of scope on purpose. Researching this turned up two bugs:

- **Every currency is treated as having cents** ([#251](https://github.com/sharneng/spliit2go/issues/251)). JPY, HUF, ISK, IDR, KRW, VND and COP have none, so a ¥1,000 expense from the web shows as ¥10.00, and one added here is sent 100 times too large. The rate formula above is wrong whenever the two currencies have different numbers of decimal places. Fixed in #251: `Currency.decimalDigits` comes from currency-data.json (0 for those seven, 2 otherwise and for a custom symbol), every amount is parsed, shown and stored with it, `originalAmount` uses the paid-in currency's own, and `conversionRateFor` in `lib/utils/money.dart` derives the rate in major units, following the first formula.
- **Removing a conversion doesn't clear it:** `spliit_client.dart` leaves `originalCurrency` out when it's null. Fixed as part of [#252](https://github.com/sharneng/spliit2go/issues/252).

## The form (for #252)

- **Follow spliit-ios:** a "Paid in" row. When it differs from the group's currency, "Amount paid" and "Exchange rate" appear. The group-currency total is calculated and read-only. A line under the rate says where it comes from. A scanned receipt's total goes into "Amount paid" during a conversion.
- **Take the settlement direction from spliit-web,** in the first version. When marking a settlement as paid in another currency, the amount settled stays fixed and the amount to transfer is calculated from it with the second formula above, rounded to the original currency's decimal places. It uses the same rate, so nothing about rates or the cache changes.
- **The expense's own rate is the record.** Editing an expense shows its saved rate and never replaces it automatically. The outbox sends what was saved, and doesn't look the rate up again when it syncs. The rate cache below only ever *suggests* a rate.
- **Not in the first version:** typing each share in the original currency (web's "by amount" convenience).

The layout itself is part of the expense screen restyle.

## Where rates come from

**Frankfurter v2** (`api.frankfurter.dev/v2`): no key, open source and self-hostable, 165 currencies from many central banks. The docs say v1 stays available indefinitely, but it has only the ECB's 30 currencies, and VND, COP and MKD from our own list are missing.

### EUR is the hub for every pair

We only ever ask for a whole day's table with EUR as the base:

```
GET /v2/rates?base=EUR&date=2026-10-04                  (averaged, 165 currencies)
GET /v2/rates?base=EUR&date=2026-10-04&providers=ecb    (ECB, 30 currencies)
```

Each row says how much of a currency 1 EUR buys. Any pair is worked out from that: `rate(A→B) = perEuro[B] / perEuro[A]`, where EUR is 1. For VND→EUR that's `1 / 29263 = 0.0000341728`. For VND→USD it's `1.1279 / 29263`. Only one table is needed for any pair.

Why not ask for the pair itself, with `base=VND`? **Frankfurter rounds rates to about 5 significant figures, with a limit on decimal places,** so a small rate loses its digits:

| Asked for | Frankfurter answers | Worked out from EUR | Error |
|---|---|---|---|
| VND→EUR | `3.4e-05` | `3.41728e-05` | 0.5% (1,000,000 VND = 34.00 instead of 34.17 EUR) |
| IDR→EUR | `5.0e-05` | `5.0064e-05` | 0.13% |
| KRW→USD | `0.00075` | | up to ~0.7% |

spliit-web has this loss today, since it asks with the original currency as the base. Our rates come from the same ECB numbers without the rounding, so they won't always match web's to the last digit.

Why EUR, and not USD (where most business is) or KWD (the most valuable currency)?

- **Precision is the same for all three.** On 2026-10-07 every real currency's rate kept 5 significant figures whichever of them was the base. The smallest rates against EUR are KWD's 0.34697 and USD's 0.30884; against KWD every rate is above 1. Only gold went small enough to lose digits, and we don't offer it.
- **The ECB publishes against EUR.** `base=EUR&providers=ecb` returns the ECB's own numbers unchanged: IDR is `19974.25`, 7 significant figures. `base=USD` returns Frankfurter's recalculation, rounded again: IDR becomes `17871`, which is 19974.25 ÷ 1.1177 rounded off. We'd then divide a second time. `base=KWD&providers=ecb` returns an empty table, because the ECB doesn't publish KWD.
- **The hub is never seen.** A USD→X rate comes out the same either way; Frankfurter itself calculates `base=USD` through EUR.

### ECB first, averaged for everything else

- **If the ECB table has both currencies, use it.** Those rates are the same as spliit-web's and spliit-ios's. The averaged table can differ noticeably: on Sunday 2026-10-04, EUR→USD was 1.1279 averaged and 1.1225 from the ECB, a 0.5% difference.
- **Otherwise use the averaged table for both currencies** (Kenneth, 2026-10-09). One rate never mixes sources.
- **There's no hard-coded ECB list.** The ECB table itself says what it covers, so a change like BGN leaving when Bulgaria adopted the euro is handled automatically.

### What a day's answer contains

- **Weekends and holidays:** each currency comes with the date its rate is from. The ECB table for Sunday 10-04 is all from Friday 10-02. The averaged table mixes dates: 142 currencies from 10-04, and 23 from 10-02 or 10-03. The form says "the rate on {date}" when the date differs from the expense's date.
- **Future days:** v2 answers with an empty table (or 404 for a single pair), where v1 used to give the latest rate. So a future date is clamped to today.
- **Today:** Frankfurter's CDN caches a request dated today for 24 hours (`max-age=86400`), so it can return a half-finished day. The undated request (`/v2/rates?base=EUR`) is cached only until the next update (about 4.5 hours), so today is fetched without a date.
- **A day's answer is stable.** The same day fetched hours apart came back identical.
- **The range endpoint isn't the same thing** (`?from=…&to=…`, 14 days in one 12 KB compressed response). It returns each currency by its publication date. A single-day request calculates pegged and derived currencies such as CNH, KYD and AWG from that day's USD rate, so for 22 of 165 currencies on Sunday 10-04 the range gave different numbers. We fetch one day at a time so the answer is exactly what that day's request returns.

## The rate cache

**Global:** keyed only by day and source, not by group and not by Spliit server. Rates come straight from Frankfurter, so neither the group nor a self-hosted instance changes them. That's unlike `CachedCategories`, which is per server.

### Storage

A table in the existing drift database (`spliit2go.sqlite`, schema 18 → 19), not `shared_preferences` and not a separate file:

- **Not `shared_preferences`:** going offline needs "the newest saved day before D", and a day should be replaced in one write.
- **Not a separate file:** that adds a second connection and migration path for one table. Emptying the cache is still a single `DELETE`.

One row per day and source, since a lookup always needs a whole day. Frankfurter's repeated `base`, `date`, `quote` and `rate` keys are dropped:

```dart
/// One day of exchange rates from one source, as Frankfurter answered
/// for that day. Global: a rate depends on neither the group nor the
/// Spliit server. See docs/decisions/currency-conversion.md.
@DataClassName('RateDayRow')
class RateDays extends Table {
  /// The day asked for, yyyy-MM-dd, after clamping to today (UTC).
  TextColumn get day => text()();

  /// 'ecb' or 'averaged'.
  TextColumn get source => text()();

  /// Units of each currency per 1 EUR: {"USD":1.1279,"VND":29263,...}.
  /// {} when Frankfurter had nothing for the day, which is kept too.
  TextColumn get perEuroJson => text()();

  /// The date most of the day's rates are from (Friday, for a Sunday).
  TextColumn get publishedOn => text()();

  /// Only the currencies whose rate is from another date:
  /// {"SDG":"2026-10-03"}. Usually {}.
  TextColumn get publishedOnExceptionsJson => text()();

  /// When this answer was fetched. The day is final only once this is
  /// 3 or more days after [day] (UTC); see "When a saved day is final".
  DateTimeColumn get fetchedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {day, source};
}
```

- **Size:** Sunday 10-04 was 10.4 KB from Frankfurter for the averaged table and 1.9 KB for the ECB table. Stored, that's about 2.6 KB and 0.4 KB: around 3 KB a day for both, or about 0.5 MB for 180 days.
- **Numbers:** `jsonDecode` already gives doubles, and no rate has more than about 7 significant figures, so doubles lose nothing.
- **The rate put in the form** is rounded to 6 significant figures. That one value is what's shown, saved on the expense and used to calculate the amount, so they can't disagree.
- **Reads, not watches:** the table is read once per lookup, never `.watch()`ed, since drift re-emits on every write.

### When a saved day is final

Whether a saved day can still change depends on **when it was fetched**, not on how old the day is now. A day is **final** once it was fetched with a dated request at least 3 days after the day itself (`fetchedAt` in UTC ≥ D + 3 days). Until then it's **provisional**, however old D becomes.

For example, a table saved early on Oct 9 can still hold Oct 8's rates for some currencies. It only becomes final when Oct 9 is fetched again on Oct 12 or later. If the day were treated as final just for being three days old, that early answer would be used forever.

| Saved day D | Treated as | When it's needed online |
|---|---|---|
| Not saved | — | Fetched |
| Fetched 3 or more days after D | Final | Used as saved; never fetched again, only removed by the clean-up |
| Fetched earlier | Provisional | Used if fetched in the last 3 hours, otherwise fetched again |

- **The request:** a D in the future is clamped to today. D = today uses the undated request (latest); any other day uses a dated one. An undated answer is never final, since it's fetched on D itself.
- **Why 3 days:** some central banks publish late, and the CDN can serve a cached answer for 24 hours plus another 24 hours stale (`stale-while-revalidate=86400`).

### Looking up a rate

`rate(day, from, to, {force})` in `lib/services/exchange_rates.dart`, with a replaceable HTTP client so tests never touch the network:

1. Same currency: no rate needed.
2. Clamp the day.
3. Get the ECB day: from the cache if it's final, or provisional and fetched in the last 3 hours, and `force` isn't set; otherwise from the network. If it has both currencies, use it.
4. Otherwise get the averaged day the same way. If it has both, use it. If not, there's no published rate for the pair. The form says so, and you can type a rate.

When the network fails:

- If that day is saved, use it even if it's provisional and past its 3 hours, and mark it stale.
- Otherwise use the newest saved day before D that has both currencies. The form says "Offline: rate from {date}".
- Otherwise the rate is unavailable. Typing a rate always works.

Requests in flight are shared per day and source, so scrolling through dates doesn't fire requests side by side. The form ignores an answer to a question it's no longer asking, as spliit-ios does. **Refresh** ("Use the published rate") passes `force`.

Failures follow [error-handling.md](error-handling.md): being offline is expected and not logged. A malformed answer is logged once, and what's saved stays.

### Clean-up

At startup, days fetched more than 180 days ago are deleted, except the newest day of each source, which is kept as the offline fallback. Editing an old expense just fetches its day again.

## Downloading rates ahead, for offline use

A whole day covers every currency, so there's nothing to choose. "Ready to go offline" just means today's two tables are saved. The design follows receipts' downloading ahead ([receipts.md](receipts.md)): Kenneth's travel groups are his favorites.

**Automatically**, at most every 3 hours, in the background after a group refreshes, if the group has an ISO currency code and is either:

- a **favorite**, or
- has an expense in another currency dated within the last 30 days.

Each run fetches, for both sources:

- today's table;
- any of the past 7 days not saved yet, so last week's expenses can still be entered offline at their own day's rate;
- **every saved day that's still provisional**, whatever its age, if it was fetched more than 3 hours ago. A table saved early is replaced by the day's dated answer once that answer settles, including after several days offline, when the day may already be more than a week back.

There are never many provisional days: a run leaves only its own last 3 days provisional (6 tables), and the next run fetches them again. It's about 2 KB compressed per table, and a first run is at most 16 small requests. Data use is small enough that there's no Wi-Fi-only setting, unlike receipts (up to 5 MB each). Someone who never converts and has no favorites makes no requests at all.

**By hand:** App settings › Storage gets an **Exchange rates** row next to Receipts:

- Subtitle: "Saved for offline use: rates of Oct 9 · 165 currencies", or "None saved".
- **Update** does the same run as above, ignoring the 3 hours, and reports failure the way receipts' Retry does.

This is the "before I go offline" button; opening a favorite group while online does the same thing.

**What can't be downloaded ahead:** rates for days that haven't happened yet. Offline for a week, every expense gets the newest saved rate, labelled with its date, and you can type the rate from your card statement instead. Rates aren't changed afterwards: the rate saved on the expense is the record. Opening the expense online later offers "Use the published rate" for its own day.

## Considered and not done

- **Caching pairs instead of days:** less precise (above), a second request for every new pair, and each request reveals which currencies you use. A whole-day table doesn't.
- **Frankfurter v1:** ECB only, so no VND, COP or MKD from our own list. v2 with `providers=ecb` gives the same numbers for the ECB currencies.
- **The range endpoint for downloading ahead:** fewer requests, but different numbers for pegged currencies than the day's own answer (above).
- **One row per currency:** normal SQL, but it repeats the day and source on every row and needs an index on them. A lookup always reads a whole day anyway.
- **Looking the rate up again when an offline expense syncs:** would silently change an amount the user saved.
