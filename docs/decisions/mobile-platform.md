# Mobile client: platform decision

**Decided:** Flutter (Dart). Build the Android app first; the same codebase can target iOS later since Flutter is cross-platform, unlike the current native effort.

**Project name:** `spliit2go` — [github.com/sharneng/spliit2go](https://github.com/sharneng/spliit2go). "2go" signals the offline/on-the-go angle that's the point of the app; distinct enough from `spliit-ios`/`spliit-mobile`/`spliit-web` and from the unrelated "Spliiit" App Store app.

## Context

Spliit's web app is Next.js + Prisma + Postgres. The API is tRPC only — no REST layer — served at `{baseURL}/api/trpc` with the superjson transformer, using tRPC's batch wire format for every call (even single, non-batched requests).

Existing mobile efforts in the Spliit ecosystem:
- [spliit-mobile](https://github.com/spliit-app/spliit-mobile) — the original Expo/React Native app, iOS-only, private beta. Since superseded.
- [spliit-ios](https://github.com/spliit-app/spliit-ios) — the current official app, a native SwiftUI rewrite that replaced the RN version. No offline support beyond an offline receipt-scanning feature; no stated Android plans or timeline.
- [spliit-native](https://github.com/kegelmeier/spliit-native) — an unofficial native iPhone/iPad/Mac client.
- No official or community Android app exists.

## Why Flutter over the alternatives

- **React Native/Expo** was the natural tRPC-native choice (TypeScript can import the server's `AppRouter` type for end-to-end type inference), and it's also what the upstream project already tried and moved away from for iOS. More importantly, we decided *against* leaning on tRPC's type inference at all — tightly coupling the client to the live server types would prevent server and client from evolving independently, especially since Spliit is a fast-moving OSS project we don't control. That removes RN's main technical edge here.
- **Kotlin Multiplatform** was the other native-leaning option (Kotlin is close to Java), but requires maintaining two UI layers (Compose + SwiftUI) for a solo dev, versus Flutter's one codebase for both platforms.
- **Flutter** wins on: single codebase for Android now and iOS later, Dart's syntactic closeness to Java, mature AI-assisted tooling, and a solid offline/local-storage ecosystem (drift/sqflite) that fits the sync model below. It fills a real gap — Android has no client at all, and iOS's native app has no offline roadmap.

## API approach — verified, not guessed

Talk to tRPC as plain HTTP+JSON (not generated/inferred types), mapping responses into our own DTOs (`Expense`, `Group`, `Participant`, `Category`) so an upstream schema change breaks one mapping function, not the whole app.

The wire format was originally ported from a separate sibling project, **`splitwise2spliit`** (Python) — a working Splitwise-CSV-to-Spliit importer built and run end-to-end against a live instance before spliit2go's Dart client was written. Since then it's been exercised directly, live, from the Flutter app itself (see Testing below), which surfaced a couple of real shape differences between what the Python client needed and what this app needed:
- Every call (query or mutation) uses tRPC's batch format: `?batch=1` plus an `input`/body shaped like `{"0": {"json": {...}}}`; responses are always a JSON array, unwrapped as `resp[0]['result']['data']['json']`.
- `expenseDate` needs a superjson `meta` entry (`{"values": {"expenseFormValues.expenseDate": ["Date"]}}`) or the server parses it as a plain string.
- `groups.expenses.list` paginates (~10/page); a full fetch follows `hasMore`/`nextCursor`.
- Expense creation is nested under `expenseFormValues` (title, amount, paidBy, paidFor, splitMode, category, isReimbursement, notes, documents), not a flat payload.
- **Found only once actually reading responses in the app:** `paidBy` and each `paidFor` entry's `participant`, which we *send* as bare id strings on create, come back from `groups.expenses.list` as expanded `{id, name, ...}` objects. The Python importer never hit this because it only ever wrote expenses, never parsed them back. The Dart client now accepts either shape rather than assuming one — deliberately, since this is exactly the kind of upstream internal we don't want the client bound to.

## Offline scope and sync model

Explicitly scoped to **view + add only** — no offline edit. This matches how splitting apps actually get used and avoids needing a real conflict-resolution engine:

- **Read side:** local cache (drift/SQLite) is a last-synced snapshot of both expenses *and* the group/participants (added after a real bug — see Testing), overwritten on each successful fetch — no merging.
- **Write side:** expenses added offline get a local uuid and a `pending` flag, shown in the UI immediately, and are POSTed via `createExpense` once connectivity returns (`Outbox.flush`, triggered on reconnect and after adding). No conflict resolution needed since we only ever replay appends, never reconcile two versions of the same record.
- **Balances (resolved since):** "who owes whom" is computed client-side from the cached expense list, pending expenses included, so it is correct offline and reflects a queued expense immediately (see `lib/services/balance_calculator.dart`).

## Testing — first real run, 2026-09-16

Set up Flutter + Android Studio locally and ran the app end to end against a live Spliit instance and a physical Android device (wireless-debugging, not an emulator). Everything below was tested and confirmed working after fixing what it found:

- Online: add an expense from the app, confirmed it appears on the web app; add from web, pull-to-refresh shows it in the app.
- Offline: add an expense with connectivity off, shows immediately with a "syncing…" badge; reconnecting triggers automatic sync (via the connectivity-change listener, no manual refresh needed) and the badge clears.
- Cold start while offline: force-quit and relaunch with no connectivity — cached expense list loads correctly.

Bugs found and fixed along the way (all in this repo now, see git log): a `whereSamePrimaryKey` misuse on a delete statement (that method's for updates); the `paidBy`/`paidFor` object-vs-string shape mismatch noted above; a case where a live-refresh failure right after a successful sync could leave an already-synced expense stuck showing "syncing…" (fixed by reloading the local cache unconditionally after any outbox flush, not only after a successful live refresh); and the big one — the `Groups` table existed in the schema since the very first scaffold but was never actually used, so a cold offline start had no cached group/participants and the add button stayed permanently disabled, since it depends on `_group` being non-null and nothing had ever set it offline. Fixed by actually caching group+participants locally (with a schema migration, since this added a column to an existing table) and loading that cache on start alongside the expense list.

Also hit, unrelated to app logic: a currently-open Flutter bug where Android SDK Command-line Tools v23+ breaks `flutter doctor --android-licenses` (replaced `sdkmanager` with a new deprecated-facing `android` CLI) — worked around by installing Command-line Tools v22.0 instead. See [flutter/flutter#191558](https://github.com/flutter/flutter/issues/191558) if this surfaces again on a future machine setup.

## CI and automated tests — 2026-09-16

After the live-testing pass above, all four bugs it found were encoded as regression tests, plus baseline coverage of the API client and pagination, so future changes don't need a physical device and a live server to catch the same class of mistake:

- `test/api/spliit_client_test.dart` — `fetchGroup` parsing, `fetchExpenses` parsing both the expanded-object and bare-id-string shapes of `paidBy`/`paidFor`, and pagination via `hasMore`/`nextCursor`. Uses `http`'s `MockClient`, no network or server needed.
- `test/db/app_database_test.dart` — drift `NativeDatabase.memory()` tests for `cacheGroup`/`cachedGroup` round-trip and overwrite, and `insertPending`/`replaceServerExpenses` (confirms a pending/unsynced row survives a server refresh, and that a second refresh drops stale server rows).
- `test/sync/outbox_test.dart` — `Outbox.flush()` on success, on server failure (row stays pending), and across multiple pending rows.
- `test/screens/group_screen_test.dart` — widget tests, the direct regression test for the disabled-add-button bug: add button is enabled on a cold offline start when the group was previously cached, and stays disabled offline when nothing has ever been cached.

`.github/workflows/ci.yml` runs `flutter analyze` and `flutter test --coverage` (via `subosito/flutter-action@v2`) on every push and PR, summarizes coverage with `lcov`, and uploads `coverage/lcov.info` as a build artifact. `group_screen.dart`'s connectivity-change listener was also wrapped in try/catch so it degrades gracefully in the widget-test environment, where `connectivity_plus`'s platform channel isn't available.

That suite was pushed and runs in CI (`.github/workflows/ci.yml`) and locally via `scripts/run_test`; it has grown well beyond the four files listed above.

## Status

This is a decision record as of 2026-09-16, when the app first ran end to end against a live instance. Everything listed here as a gap at that time (balances, uneven splits, multiple groups, an outbox retry limit) has since shipped. Current feature status lives in the [README](../../README.md); open work is in the GitHub issue tracker and project board.

The two original companion tasks, a script to add an expense via the API and a Splitwise CSV importer, live in the sibling `splitwise2spliit` (Python) project, not this repo.
