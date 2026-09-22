# spliit2go

[![CI](https://github.com/sharneng/spliit2go/actions/workflows/ci.yml/badge.svg)](https://github.com/sharneng/spliit2go/actions/workflows/ci.yml)

An unofficial, offline-capable mobile client for [Spliit](https://github.com/spliit-app/spliit), the open-source Splitwise alternative. Built with Flutter, Android first, with iOS to follow from the same codebase.

## Why

Spliit has an official [iOS app](https://github.com/spliit-app/spliit-ios) but no Android client, and its offline support is limited to receipt scanning. spliit2go fills both gaps: a real Android client, with offline view of your groups/expenses and the ability to add an expense while offline, queued for sync as soon as you're back online.

## Scope

- **View, offline:** groups, expenses, and balances are cached locally and available with no connection.
- **Add, offline:** new expenses can be created while offline; they're queued locally and synced to the server automatically once connectivity returns.
- **No offline edit:** editing or deleting an expense requires connectivity. This keeps the sync model simple — appends only, no conflict resolution — which fits how expense-splitting apps are actually used.

## Architecture

- **API:** Spliit's backend exposes tRPC only (no REST layer), at `{baseURL}/api/trpc` with the superjson transformer, using tRPC's batch wire format for every call. Rather than importing Spliit's server-side types for end-to-end type inference, `lib/api/spliit_client.dart` talks to it as plain HTTP+JSON and maps responses into this app's own DTOs (`lib/models/`). This keeps the client decoupled from Spliit's internal schema — an upstream change breaks one mapping function here, not the whole app. The request/response shapes are ported from [splitwise2spliit](../splitwise2spliit)'s Python client, which has already exercised this API end-to-end (group fetch, paginated expense list, expense create with even/uneven splits and settlements) importing real Splitwise data — not guessed from the server source alone.
- **Local storage:** [drift](https://pub.dev/packages/drift) (SQLite) holds the last-synced snapshot of groups and expenses, plus a `pending` flag on locally-added expenses that haven't synced yet. See `lib/db/`. Balances aren't stored — they're computed on-device from the cached expenses each time (`lib/services/balance_calculator.dart`), which is what keeps them correct offline and inclusive of pending ones.
- **Sync:** `lib/sync/outbox.dart` — pending expenses are replayed against the API when connectivity returns. No merge logic: reads overwrite the local cache on each successful fetch, writes are append-only.

Full reasoning for these choices, and for other design calls (multiple groups, date handling, the expense form, the split UX), is in [`docs/decisions/`](docs/decisions/README.md).

## Features

- **Groups:** join by server URL and group id, or by opening a spliit.app group link (Android App Links). Each group keeps its own server URL and active user, so groups on different Spliit instances can coexist; the list shows each group's date span and is sortable (first/last expense date, creation date, last opened). The list is organized into Favorites, Active, and Archived sections (hidden when empty); swipe a row for Favorite/Archive/Remove actions, or long-press (or tap the monogram) for the same actions as a menu. A full swipe favorites or archives a group outright, native-style; Remove always needs an explicit tap and confirmation, and only removes the group from this device, never the server.
- **Expenses:** offline-first list (cache first, live fetch in the background, pull-to-refresh). Add and edit with all four split modes (evenly, shares, percentage, amount), per-participant live amount preview, categories with search, date, a different "paid in" currency, reimbursements, recurrence, notes, and a remembered per-group default split. Expenses added offline show a pending badge and sync automatically on reconnect; the outbox stops retrying an expense the server rejects and marks it failed.
- **Balances:** who owes whom, computed on-device from the cached expenses (so it works offline and includes pending ones), with one-tap "mark as paid" reimbursements.
- **Stats and Activity:** spending totals per participant and per category; the group's activity feed (online only).
- **Group settings:** rename the group, change its currency, add, rename, or remove participants (online only).
- **App settings:** light, dark, or system theme; language.
- **Languages:** English, French, and Simplified Chinese, with locale-aware amounts and dates, switchable in the app without a restart.

## Status

An early, usable Android client, tested on a physical device against a real self-hosted Spliit instance. iOS builds from the same codebase but has not been set up. Feature and bug work is tracked in [GitHub issues](https://github.com/sharneng/spliit2go/issues) and the project board, which are the source of truth for what is done and what is next.

Not built yet:

- Receipt attachments and AI receipt scan ([#5](https://github.com/sharneng/spliit2go/issues/5)); the expense form shows a disabled "Attach documents" row.
- Share link / invite ([#3](https://github.com/sharneng/spliit2go/issues/3)), QR scanning when joining ([#41](https://github.com/sharneng/spliit2go/issues/41)).
- CSV/JSON export ([#7](https://github.com/sharneng/spliit2go/issues/7)).
- Expense search on the Expenses tab ([#39](https://github.com/sharneng/spliit2go/issues/39)).
- Stats charts, projections, and a date-range selector; Stats is "all time" only.
- More languages and right-to-left support ([#64](https://github.com/sharneng/spliit2go/issues/64), [#65](https://github.com/sharneng/spliit2go/issues/65)).

## Tests

`test/` covers the core logic and the screens without needing a device or a live server: `SpliitClient` response parsing, `AppDatabase` caching and migrations, `Outbox` sync behavior, the balance and stats calculators, formatting and localization, and widget tests for each screen. Run locally with:

```
flutter test --coverage
```

CI (`.github/workflows/ci.yml`) runs `flutter analyze` and this test suite on every push and PR, and uploads the coverage report as a build artifact. See [SETUP.md](SETUP.md) to run the same checks locally (`scripts/run_test`).

## License

MIT — see `LICENSE`.
