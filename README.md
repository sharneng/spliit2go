# spliit2go

An unofficial, offline-capable mobile client for [Spliit](https://github.com/spliit-app/spliit), the open-source Splitwise alternative. Built with Flutter, Android first, with iOS to follow from the same codebase.

## Why

Spliit has an official [iOS app](https://github.com/spliit-app/spliit-ios) but no Android client, and its offline support is limited to receipt scanning. spliit2go fills both gaps: a real Android client, with offline view of your groups/expenses and the ability to add an expense while offline, queued for sync as soon as you're back online.

## Scope

- **View, offline:** groups, expenses, and balances are cached locally and available with no connection.
- **Add, offline:** new expenses can be created while offline; they're queued locally and synced to the server automatically once connectivity returns.
- **No offline edit:** editing or deleting an expense requires connectivity. This keeps the sync model simple — appends only, no conflict resolution — which fits how expense-splitting apps are actually used.

## Architecture

- **API:** Spliit's backend exposes tRPC only (no REST layer), at `{baseURL}/api/trpc` with the superjson transformer. Rather than importing Spliit's server-side types for end-to-end type inference, `lib/api/spliit_client.dart` talks to it as plain HTTP+JSON and maps responses into this app's own DTOs (`lib/models/`). This keeps the client decoupled from Spliit's internal schema — an upstream change breaks one mapping function here, not the whole app.
- **Local storage:** [drift](https://pub.dev/packages/drift) (SQLite) holds the last-synced snapshot of groups/expenses/balances, plus a `pending` flag on locally-added expenses that haven't synced yet. See `lib/db/`.
- **Sync:** `lib/sync/outbox.dart` — pending expenses are replayed against the API when connectivity returns. No merge logic: reads overwrite the local cache on each successful fetch, writes are append-only.

Full reasoning for these choices is written up in the project's `decisions/mobile-platform.md` doc.

## Status

Early scaffold. Not yet functional — see `SETUP.md` for what's needed to get a running build, and the repo issues for the current task list:

1. Script to exercise the Spliit API (add an expense) — validates the client before the app depends on it.
2. Splitwise export importer, built on (1).
3. Android app (this repo).
4. Offline view/add support (this repo).

## License

MIT — see `LICENSE`.
