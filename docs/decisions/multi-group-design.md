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
- **Changing it later:** with nobody set, the Stats tab's "Pick an active user…" hint was a button that opened the same picker. Changing an already-chosen person was deferred at the time; [#99](https://github.com/sharneng/spliit2go/issues/99) added it on the Balances tab (next section), and [#103](https://github.com/sharneng/spliit2go/issues/103) then removed the Stats hint, leaving Balances as the one place to pick or change it ([stats-screen.md](stats-screen.md)). The group-settings checkbox originally proposed in #83 was dropped: the active user is device-only, while group settings saves to the server.

## "You" on the Balances tab (2026-09-24, issue #99)

Kenneth asked for spliit-ios's "You" section on Balances (`BalancesView.youSection` @ `80b2e98`; spliit-web has none). Merged in [#101](https://github.com/sharneng/spliit2go/pull/101). It is also where the active user is changed: until then, once someone was picked there was no way to change it. Since #103 it is the only place to pick one after the first prompt.

- **Someone picked:** "You are owed" / "You owe" / "You’re settled up", then the amount **unsigned**, green when owed and in the error color when owing. As in spliit-ios, the sentence carries the direction, so a sign would say it twice. The amount is the on-device balance (`computeBalances`, pending expenses included), the same figure as that person's row below. Their row reads "Name (you)".
- **A "You · Name" row opens the same "Who are you?" picker** (`_pickActiveUser(firstAsk: false)`, so dismissing changes nothing). With nobody picked, only this row shows ("You · Nobody"), with spliit-ios's line on why to pick.
- **No "Say who you are" state.** spliit-ios has a third label for a group never asked. Here the prompt above stores Nobody even when dismissed, so the only unanswered group is one whose prompt hasn't shown yet; it shows "Nobody" too.
- **"Nobody" in the row is its own short string** (Personne / 无): the picker's French and Chinese wording ("Je ne suis pas dans la liste", "我不在名单中") is too long for a row value.
- **The name wraps beside the label** rather than sitting in `ListTile.trailing`, which has no width limit: a long name at large text took the whole row (Ezra, #101 review; regression test in `balances_screen_test.dart`).

## Creating a group (2026-09-25, issue #115)

The Join screen has a "Create a new group" button (Kenneth's ask on #115), which opens the group settings form in create mode, like spliit-ios's shared group editor (`GroupFormView` / `CreateGroupView` @ `80b2e98`). It calls `groups.create` (spliit-web `create.procedure.ts` @ `cc796210`), which takes the same form values as `groups.update` and returns the new group's id.

- **A server picker**, since a group stays on the server it's made on: the servers this device already has groups on, most recently opened first, then spliit.app if it isn't one of them, then "Other server" for a typed address (`https` added if missing). The default is the most recently opened group's server, or spliit.app on a fresh install. spliit-ios offers the same list.
- **Pre-filled like upstream:** the three sample participants spliit-web and spliit-ios start with (John, Jane, Jack; Jean, Jeanne, Jacques in French, as spliit-web translates them), and the phone region's currency (spliit-ios; spliit-web defaults to USD, which is the fallback here for a region Spliit has no currency for).
- **Stored exactly like a join** (`cacheJoinedGroup`): the group is fetched back for its server-assigned participant ids, cached with no expenses, and marked opened, so it's in the list and viewable offline; the active participant is auto-matched against the device's default name as on join, and otherwise "Who are you?" asks on first open, as for any group.
- **The server's name rules are checked on the phone,** in create and edit alike: group and participant names 2 to 50 characters, no two participants with the same name (spliit-web `groupFormSchema`). Before, only empty names were caught and anything else came back as the server's raw validation error.
- Creating needs a connection, like joining; a failure keeps the form open with the error.
- **A created group is never created twice** (Ezra, #116 review). Once `groups.create` succeeds the group exists, so if loading it back fails, the form keeps its id and server, locks the fields, shows its link (selectable, so it isn't lost if the user leaves), and Create retries only the load. Spliit has no way to pass a client-made group id, which would make create itself safe to retry; the server mints it (`randomId()` in `createGroup`).

## Sharing a group (2026-09-25, issue #3)

Kenneth asked to follow spliit-ios's group toolbar: a ⋯ menu where the settings button was, with **Group settings** (a settings icon, rather than spliit-ios's "Edit group" with a pencil) and **Share group** (`GroupDetailView` @ `80b2e98`). A QR code is out of scope for the first release and can join the same menu later.

- **The link is `<server>/groups/<id>`,** on the group's own server: the link spliit-ios shares and spliit-web gives out, so it opens for anyone, in a browser or in this app (paste it into Join), and `parseGroupUrl` reads it back (`groupShareLink` in `lib/services/group_url.dart`).
- **The system share sheet,** via the `share_plus` plugin: the link goes as a URL, so iOS shows the page's preview, with the group's name as the subject; Android shares it as text.
- **Works offline and before the group has loaded:** it only needs the group's id and server. Group settings stays disabled until the group is loaded, as the old button was.

## Group links pasted from messages (2026-09-25, issue #118)

Joining on Android failed with "type 'Null' is not a subtype of type 'Map<String, dynamic>'". Spliit answers a group id it doesn't have with `{group: null}`, not an error (checked on spliit.app), and `fetchGroup` cast that straight to a map. The most likely way a good link became a bad id is text around it: a link at the end of a sentence kept its "." in the id, and a subject in front of the link ("Road trip https://…") became part of the server address.

- `fetchGroup` throws `GroupNotFoundException` for an explicit `{group: null}`, and Join says "No group with that link was found on <server>".
- `parseGroupUrl` takes the first `http(s)://` link out of surrounding text (or the word holding `/groups/` when there's no scheme), and ends the id at the first character a Spliit id can't contain (nanoids: letters, digits, `_`, `-`).
- A missing group is a user error: guidance only, no log or details. Only the explicit `{group: null}` means missing; any other shape is a malformed response. Kenneth's question about seeing full errors on the phone became an app-wide policy: see [error-handling.md](error-handling.md).

