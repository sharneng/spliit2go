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
- **Local storage:** [drift](https://pub.dev/packages/drift) (SQLite) holds the last-synced snapshot of groups/expenses/balances, plus a `pending` flag on locally-added expenses that haven't synced yet. See `lib/db/`.
- **Sync:** `lib/sync/outbox.dart` — pending expenses are replayed against the API when connectivity returns. No merge logic: reads overwrite the local cache on each successful fetch, writes are append-only.

Full reasoning for these choices is written up in the project's `decisions/mobile-platform.md` doc.

## Status

Working end to end as of 2026-09-16: builds, runs on a physical Android device, and has been tested live against a real Spliit instance — online add/view, offline add with automatic sync on reconnect, and a cold start while offline all confirmed working. See `decisions/mobile-platform.md` in the project docs for the full testing writeup, including the bugs that first pass found and fixed.

- `SpliitClient` — fetch group/participants, fetch (paginated) expenses, fetch categories, create an expense or settlement.
- `AppDatabase` (drift) — local cache of a group's expenses *and* group/participants, with a `pending` flag for offline-created expenses.
- `Outbox` — replays pending expenses against the server once connectivity returns.
- Screens — first-run server/group settings, a group's expense list (offline-first: cache shown immediately, live fetch in the background, pull-to-refresh), and an add-expense form (evenly split among all participants; writes locally first, syncs opportunistically).

### Tests

`test/` covers the core logic without needing a device or a live server: `SpliitClient` response parsing (including both participant-reference shapes Spliit's API actually returns, per the regression noted below), `AppDatabase`'s group/expense caching, `Outbox` sync behavior, and a widget test for the add-button-stays-disabled-offline bug specifically. Run locally with:

```
flutter test --coverage
```

CI (`.github/workflows/ci.yml`) runs `flutter analyze` and this test suite on every push and PR, and uploads the coverage report as a build artifact.

Known gaps, in rough priority order:

- Balances ("who owes whom") aren't fetched or shown yet, and offline balance display needs to account for pending expenses (see `decisions/mobile-platform.md`).
- Add-expense only supports an even split across every participant — no per-person amounts, no excluding someone from a split, no settlements from the UI (the API layer supports all of these; the form doesn't expose them yet).
- Single group only — no group list/switcher.
- No retry limit or user-visible "failed to sync" state in the outbox if a pending expense keeps failing.

Tasks (1) and (2) from the original project plan — a script to exercise the API, and a Splitwise CSV importer — are done, in the sibling `splitwise2spliit` (Python) project rather than here.

## License

MIT — see `LICENSE`.
