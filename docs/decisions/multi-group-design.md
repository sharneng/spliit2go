# Multi-group support: design decisions

**Status: implemented and pushed, `4556861` (2026-09-16); navigation hierarchy revised in `3700f89` (2026-09-16) per [issue #12](https://github.com/sharneng/spliit2go/issues/12) (closed).** [github.com/sharneng/spliit2go/issues/2](https://github.com/sharneng/spliit2go/issues/2) (closed). The sections below are the design as decided; "Implementation notes" at the end covers what actually happened building it, including two real bugs the new tests caught and the #12 navigation fix.

Backlog item 4 (multiple groups) was put on hold because it touches the cache schema and app-launch flow enough to need a real decision, not a guess. Decided together 2026-09-16, verified against the actual current code (`lib/services/settings_service.dart`, `lib/db/app_database.dart`, `lib/main.dart`) rather than assumed.

## Decisions

1. **Server URL is per-group, not global.** Each joined group carries its own server URL alongside its group id, so a device can have groups on Kenneth's self-hosted instance and on spliit.app (or anyone else's instance) at the same time.
2. **Active user ("who am I") is per-group, with a global default that auto-fills it.** A device-wide preferred name is kept; when a group is opened (or just joined) with no active-user choice recorded for *that* group yet, and exactly one of its participants matches the global default name, it's auto-selected and saved as that group's choice — no prompt. Otherwise (no global default yet, or no matching participant), the existing "Active user" picker prompts for that specific group, and the pick is saved per-group.
3. **Launch jumps straight to the last-used group**, not a group list — preserves today's one-tap-to-expenses flow for the common case of mostly living in one group. A switcher gets you to the full list. **Revised by #12 (see Implementation notes): this is now achieved by pushing the last-used group's screen on top of the group list right after launch, rather than by making the group screen itself the app's root/`home:`.** The one-tap-to-expenses outcome is unchanged; only how it's wired changed.

## Current state (verified from code, not assumed)

- `SettingsService`: one global `server_url`, one global `group_id`, one global `active_user_id` (SharedPreferences). `isConfigured()` is `serverUrl != null && groupId != null`.
- `AppDatabase.Groups` (schema v2): `id, name, currency, participantsJson` — already keyed by group id, no `serverUrl`/per-group settings columns yet.
- `AppDatabase.Expenses`: already keyed by `groupId` — no change needed here at all.
- `main.dart#_Root`: builds one `SpliitClient` (from the single global server URL) and one `AppDatabase` for the whole app lifetime; shows `SettingsScreen` if unconfigured, else goes straight to `GroupScreen`.
- `resolveDefaultPaidBy` (`lib/services/active_user.dart`): already a pure function taking `activeUserId` + `participants` — the per-group resolution logic below is an addition alongside it, not a replacement.

## Planned change

**Schema (v2 → v3, additive migration via `m.addColumn`, same pattern as the v1→v2 migration):**
- `Groups.serverUrl TEXT NOT NULL DEFAULT ''`
- `Groups.activeParticipantId TEXT NULL`
- `Groups.lastOpenedAt DateTime NULL`

**`SettingsService`:**
- Drops the single global `group_id` (a "joined group" is now a row in `AppDatabase.Groups`, not a SharedPreferences key).
- Keeps `server_url` only as a legacy migration source (see below), not for new joins.
- Adds `defaultActiveUserName` (String?) — the device-wide preferred display name, get/set.
- `isConfigured()` is replaced by "does `AppDatabase.Groups` have any rows" — moves from `SettingsService` to a query `_Root` makes at startup.

**New screens:**
- `GroupListScreen` — every joined group (from `AppDatabase.Groups`, ordered by `lastOpenedAt desc`), tap to open, "+" to join another, swipe/long-press to leave (deletes that group's local `Groups`/`Expenses` cache rows only — never touches the server). ~~Reachable from a switcher icon on `GroupScreen`'s AppBar.~~ **Superseded by #12: `GroupListScreen` is the app's actual root (always shown by `_Root`), and `GroupScreen` is reached by pushing on top of it — not the other way around. See Implementation notes.**
- The existing `SettingsScreen` becomes the "join a group" form (same two fields: server URL + group id), invoked from `GroupListScreen`'s "+" and from first-run. On save: `fetchGroup`, cache it with `lastOpenedAt = now` and the entered `serverUrl`, run the active-user auto-match/prompt (decision 2), then open `GroupScreen`. (Shipped as the new `JoinGroupScreen`; the old `SettingsScreen` was deleted rather than repurposed.)

**`main.dart#_Root`:**
- ~~On start, query for the `Groups` row with the max `lastOpenedAt`. Found → build a `SpliitClient` for *that row's* `serverUrl` and go straight to `GroupScreen` (decision 3). Not found (fresh install, or every group was left) → `GroupListScreen`'s empty state.~~ **Superseded by #12**: `_Root` always shows `GroupListScreen` as `home:`. On start, it still queries for the `Groups` row with the max `lastOpenedAt`; if found, it defers a `Navigator.push` of that group's `GroupScreen` until just after the list screen's first frame (`addPostFrameCallback`), so the list is always the thing being "backed to," never bypassed. Fresh install / every group left → the list's empty state, nothing pushed.
- `SpliitClient`/`Outbox` construction is built per opened group (since `serverUrl` now varies by group) — done wherever a group is opened (`_Root`'s deferred push, and `GroupListScreen` row taps).

**Active-user resolution** (replaces reading `SettingsService.activeUserId()` directly):
1. This group's cached `activeParticipantId`, if it's still a real participant → use it (same staleness check `resolveDefaultPaidBy` already does).
2. Else, if `defaultActiveUserName` is set and exactly one participant's name matches it (case-insensitive) → auto-select, persist as this group's `activeParticipantId`, use it.
3. Else → prompt (existing dialog, scoped to this group); the pick is saved as this group's `activeParticipantId`.
- Not in v1: offering to promote a first-ever pick to the new global default automatically. Small enough polish to add later if it turns out to matter; the explicit picker flow works fine without it.

**Migration from the legacy single-group state (app-level, not a drift schema migration — needs old `SettingsService` values, not just table shape):**
On first launch after this ships, if the legacy `group_id`/`server_url` keys are still set and that group's cached `Groups` row has an empty `serverUrl`: backfill `serverUrl` from the legacy key, set `lastOpenedAt = now`, copy the legacy `active_user_id` into that row's `activeParticipantId`, and set the new `defaultActiveUserName` from that participant's cached name (so groups joined afterward auto-match without ever prompting). The legacy keys are left in place afterward (dead, unused) rather than deleted — cheaper and lower-risk than a cleanup pass that isn't load-bearing.

## Still open, not blocking

- Whether "leave group" needs a confirmation step beyond swipe/long-press — resolved during implementation: yes, a confirm dialog (see Implementation notes).
- Whether the group list should show anything beyond name/currency (e.g. a cached balance summary) — still out of scope; the list stayed plain.

## Implementation notes (2026-09-16, `4556861`)

Built essentially as planned above, with a few things resolved or discovered along the way:

- **`GroupListScreen`/`JoinGroupScreen` take a `clientFactory` constructor param** (defaulting to a real `SpliitClient`), not a pre-built `client` the way every other screen does — neither screen can know the server ahead of time (it's per-group, or just-typed), so this is the seam tests use to inject a `MockClient`-backed one regardless of URL.
- **Leave group got a confirmation dialog** (swipe-to-reveal, then an "Leave group?" AlertDialog explaining it's local-only) rather than a bare swipe-to-delete — a bare swipe felt too easy to trigger by accident for something that, while low-stakes (no server data lost), still removes a group's local cache.
- **Two real bugs found by the new tests, both fixed:**
  - *Timestamp-collision flakiness*: drift's default `DateTime` column storage is second-granularity. Two `recordGroupOpened` calls made back-to-back with real `DateTime.now()` (in a fast test, or in principle a very fast real double-tap) can tie, making "most recently opened" ordering non-deterministic. Fixed by giving `recordGroupOpened` an optional `at` param for tests to pass explicit, distinct timestamps — deliberately *not* fixed by switching drift's global `storeDateTimeAsText` option, which would've changed the on-disk format for every existing `DateTime` column (including `Expenses.date`, which has real data on Kenneth's phone already) with no migration path for already-stored values.
  - *A genuine hang*: `JoinGroupScreen`'s "Join" button spun forever in a widget test. Root cause: `SettingsService.defaultActiveUserName()` awaits `SharedPreferences.getInstance()`, which never resolves in a `flutter_test` environment without `SharedPreferences.setMockInitialValues(...)` — it just hangs, it doesn't throw. This was always true, but harmless before: the old `GroupScreen` code called the equivalent legacy getter via a fire-and-forget `.then()`, never awaited by anything a test checked. The new code awaits it directly in the middle of a flow a test does await (join, and `_resolveActiveUser`), so the hang became visible as a `pumpAndSettle` timeout. Fixed by adding `SharedPreferences.setMockInitialValues({})` to every test that exercises that path (`join_group_screen_test.dart`, `group_screen_test.dart`, `group_list_screen_test.dart` — the last one navigates into `GroupScreen`).
- **`main.dart`'s startup migration isn't unit-tested** — `_Root` isn't currently testable in isolation (same as before this change; not a new gap). Worth a real-device check per the backlog's standing "what still needs Kenneth" note.

## Navigation hierarchy revision (2026-09-16, `3700f89`, issue #12)

Kenneth's initial real-device use surfaced a conceptual bug in the original navigation wiring: when a last-opened group existed, `_Root` made `GroupScreen` itself the app's `home:` (skipping the list entirely), and `GroupScreen` carried a custom "switch group" AppBar icon that pushed `GroupListScreen` on top of it. Two concrete problems followed from that: the list's auto-back-arrow led back to a specific group screen that could be invalid (nothing to back to on first install, before any group is joined) or gone (if the last-visited group was subsequently left/deleted). More fundamentally, it inverted the natural hierarchy — a group list is conceptually the level *above* an individual group, so going list → group should be "forward," not "back."

Fix: `_Root` now always shows `GroupListScreen` as `home:` (the app's one true root). The "jump to last group" behavior from decision 3 is preserved by having `_Root` push that group's `GroupScreen` on top of the list immediately after the list's first frame renders (`WidgetsBinding.instance.addPostFrameCallback`), rather than by skipping the list screen. `GroupScreen`'s custom "switch group" leading icon and its `_openGroupList()` method were removed entirely — it now relies purely on Flutter's default back arrow (automatic on any `Navigator.push`ed screen), which is always valid since `GroupScreen` is now always reached by pushing on top of the list.

Net effect: same one-tap-to-last-group experience for the common case, but the list is always the stable thing you land back on, however you got into a group screen (last-used auto-open, or tapping a row).

Verified: `flutter analyze` clean, all 68 tests still passing (no new tests needed — this was a navigation-structure change, not new behavior; `_Root` remains untested in isolation, a pre-existing limitation noted above).

## Active-user prompt (2026-09-23, issue #85)

Until #85, `GroupScreen` never actually asked (step 3 above): an unresolved group just had no active user, and a person icon in the top bar let you pick one. That icon is gone; instead:

- **Ask at most once per group, ever.** Opening a group that has never had an active user (stored `null`) and no default-name match shows "Who are you?", listing its participants plus **Nobody**. Groups with no participants aren't asked.
- **"Nobody" is stored, not `null`.** Choosing Nobody, or dismissing the dialog, stores the marker `nobodyParticipantId` (`'#nobody'`, never a real Spliit nanoid) in the existing `activeParticipantId` column, so "asked, nobody" differs from "never asked" without a schema change. A stored id whose participant has left the group is also treated as nobody (after a default-name match attempt) rather than asking again.
- **The first pick seeds the default name** — the "not in v1" item above. A fresh install never had a default name (only the legacy migration set one), so every group would otherwise ask once, including each group moved to a new device.
- **Changing it later:** with nobody set, the Stats tab's "Pick an active user…" hint is a button that opens the same picker. Changing an already-chosen person is deferred to the Stats screen cleanup (spliit-ios does it there too). The group-settings checkbox originally proposed in #83 was dropped: the active user is device-only, while group settings saves to the server.
