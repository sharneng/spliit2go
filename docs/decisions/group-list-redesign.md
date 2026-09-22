# spliit2go: group list redesign (issues #68, #71, #73, #74, #75)

**Status: implemented and merged** -- layout/sections/sort in [#69](https://github.com/sharneng/spliit2go/pull/69) (2026-09-20, closing #68), swipe/menu interactions in [#72](https://github.com/sharneng/spliit2go/pull/72) (2026-09-21, closing #71), and two device-testing follow-ups: haptic strength (#73) and title casing (#74). A full-swipe visual/crash bug found afterward was fixed in [#76](https://github.com/sharneng/spliit2go/pull/76) (closing #75).

Kenneth attached screenshots of spliit-ios's group-listing screen to [#68](https://github.com/sharneng/spliit2go/issues/68), judging it more elegant than spliit2go's plain list, and asked for it as a redesign target: sections, colored monograms, participant count, a divider, and a sort control. Ezra (`shargpt`) reviewed the ask before implementation and raised several behaviors the screenshots alone didn't settle -- device-local vs. shared favorite/archive state, what date "last update" sorting should mean, whether archived groups should still auto-reopen -- which Kenneth then resolved directly in the issue thread. That exchange is the real design record; this doc summarizes it against what actually shipped.

## Design decisions (from #68's review thread)

1. **Favorite/archive are device-local, not group state.** They're per-participant preferences, so they can't be shared group data, and organizing a group this way doesn't change the group itself in any other respect.
2. **A group appears in exactly one section:** Archived, Favorite, or Active, in that precedence order if more than one flag were ever true at once (see Schema below -- this precedence rule was also a real migration decision, not just a display rule).
3. **One persisted sort choice, applied within every section** (not a separate order per section) -- first expense date, last expense date, group creation date, or last opened, always descending, missing dates sorted last, ties broken by id for stability. Kenneth explicitly opted out of ascending/descending and per-section ordering as unnecessary complexity for the group counts this app deals with.
4. **Creation date is the server's real `Group.createdAt`, not the local join date.** Ezra verified this against spliit-web's own source (`recent-group-list-card.tsx`, `prisma/schema.prisma`, commit `cc79621`) before implementation started: the web app displays the server timestamp, not anything client-local, and `groups.get` already returns it. spliit2go's client previously discarded this field entirely and had to start caching it, with existing cached rows staying null until their next refresh rather than backfilling a fabricated value. The row itself keeps showing the expense date span, as before -- creation date is only a sort option, not a display change.
5. **Archived groups are excluded from the startup auto-reopen** (`AppDatabase.mostRecentlyOpenedGroup` filters out `organization == archived`) but stay reachable by opening the Archived section directly.
6. **Monogram colors and initials are ported from spliit-ios's own algorithm** (hash-based palette index, first letter of up to two words) for visual parity between the two apps -- see `lib/widgets/group_monogram.dart` and the attribution in `THIRD_PARTY_NOTICES.md`.
7. **The visible participant count is bare** (an icon plus `3`, no "participants" text) to save space, but a localized "N participants" label is retained for screen readers.

## Interactions (#71, PR #72)

A follow-up issue, agreed by Kenneth, Nate, and Ezra in the #69 PR review, added swipe gestures and an anchored menu on top of the #69 layout:

- **Swipe right** reveals Favorite/Unfavorite; **swipe left** reveals Archive/Unarchive and Remove (`lib/widgets/group_row_actions.dart`).
- **A full swipe past the halfway threshold** executes Favorite or Archive directly, native-iOS/Gmail-style. **Remove is deliberately never reachable by a full swipe** -- it always needs an explicit tap on the revealed action, then a confirmation dialog, because removing a group (even though it's local-only) is a step up in consequence from reorganizing it.
- **Long-press a row, or tap its monogram,** opens the same three actions as a menu anchored near the touch point, rather than a bottom sheet -- Kenneth asked for the monogram-tap affordance specifically because it was "low cost" once the anchored menu already existed for long-press.
- Confirmation for Remove uses an adaptive dialog: Cupertino actions on Apple platforms, Material elsewhere.
- Haptic feedback fires once on crossing the halfway swipe threshold outward and once crossing back, not on the automatic open/close animations.

## Data model / schema

`GroupOrganization` (`lib/models/group_organization.dart`) is a single three-value enum (`active`, `favorite`, `archived`), stored as one text-enum column -- not two independent booleans. That single-column design replaced an interim two-boolean shape (`is_favorite`/`is_archived`) that existed only in pre-release builds of PR #69 while it was still under review, never in a released version.

Schema is now v9 (`lib/db/app_database.dart`): `Groups.createdAt` (nullable, populated from `groups.get` on refresh) and `Groups.organization` (default `active`) are both new. The `onUpgrade` migration has to handle two starting shapes because of that interim boolean design: a `from < 9` install released as v7 just gets the two new columns added directly; the narrower `from == 8` case (someone who'd installed an interim PR build with the two boolean columns) additionally converts whichever flags were set into the corresponding `organization` value -- archived wins if both were somehow set, matching decision 2 above -- and then drops the obsolete boolean columns via `alterTable`.

## Bugs and non-bugs found along the way

- **#73, "missing haptic feedback" -- not actually a bug.** Kenneth found the swipe-threshold haptics imperceptible on a real device during testing. Investigation traced the actual gesture/controller path rather than assuming, and confirmed the feedback call really was firing; Kenneth then found the real cause himself -- concurrent phone-speaker vibration masks the haptic motor's already-weak pulse. Fixed by increasing haptic strength, not by changing the underlying gesture-tracking logic.
- **#74:** the header read "SPLIIT2GO" (all caps) instead of "Spliit2Go", inconsistent with the project's own name and spliit-ios's casing. One-line fix.
- **#75/#76:** the first full-swipe implementation didn't really dismiss the row -- it vetoed `flutter_slidable`'s own dismissal (`confirmDismiss` returning `false`) specifically to avoid a `flutter_slidable` runtime assertion ("A dismissed Slidable widget is still part of the tree"), which produced a visible bounce-back instead of a real slide-out. The fix let the dismissal actually complete and re-keys the row unconditionally afterward, via a local per-row "dismiss generation" counter that bumps regardless of whether the underlying favorite/archive write succeeds -- rather than a key derived from `organization`, which only changes on a successful write. That closed both the visual bug and a follow-on crash risk: a failed write previously could leave an already-dismissed `Slidable` element in the tree with an unchanged key, which then threw the exact same assertion on the next unrelated list rebuild. See the review thread on #76 for the full trace through `flutter_slidable`'s source and the regression test that reproduces it.

## Not done / open

- VoiceOver/TalkBack walkthroughs of the swipe and menu interactions were called out in PR #72 as a manual follow-up check, not confirmed done as of this writing.
- PR #69's initial layout merged without physical-device verification; Kenneth's subsequent real-device pass is what drove #71/#72/#73 in the first place.
