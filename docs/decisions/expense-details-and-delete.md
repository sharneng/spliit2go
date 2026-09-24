# spliit2go: expense details, delete, and activity attribution (issues #90, #92)

**Status: implemented and merged** — activity attribution in [#93](https://github.com/sharneng/spliit2go/pull/93) (closing [#92](https://github.com/sharneng/spliit2go/issues/92)), the details sheet in [#95](https://github.com/sharneng/spliit2go/pull/95) and Delete in [#96](https://github.com/sharneng/spliit2go/pull/96) (closing [#90](https://github.com/sharneng/spliit2go/issues/90)), 2026-09-23/24.

Kenneth's point in [#90](https://github.com/sharneng/spliit2go/issues/90): tapping an expense opened the edit form, but once an expense is right, people tap it to *look*, not to change it. So a tap now opens a details sheet, and editing is an explicit action from there. The scope, including adding server-side Delete (which didn't exist anywhere in the app), was settled on #90 between Kenneth, Ezra and Juno before implementation.

## Decisions

1. **View from the cache, so it works offline.** The local cache already holds every field the sheet shows, and per-person amounts come from `expenseShareCents`, the same math as Balances and Stats, so the three can't disagree. Before, tapping an expense offline showed nothing but "editing needs a connection".
2. **One sheet for the expense list and the Activity tab** (`lib/screens/expense_details_sheet.dart`, `showExpenseDetails`), owning Edit, Delete, Retry and Discard, so neither screen duplicates them. From Activity, an expense the phone hasn't cached is fetched from the server, with "no longer available" (tRPC `NOT_FOUND`), "needs a connection" and a retryable failure shown in the sheet. Cached data isn't refreshed in the background while the sheet is open (Kenneth: not worth it for now).
3. **What the sheet offers depends on the expense's state:**

   | State | Actions |
   |---|---|
   | Synced | Edit (fetches fresh first, then opens the existing form) and Delete |
   | Pending | View only, until it reaches the server |
   | Sync failed | Retry and Discard (this replaced the old separate Retry/Delete sheet) |

4. **Offline rules separate server changes from local ones** (Kenneth on #90). Edit and Delete change data on the server, so they're disabled while the phone reports no connection, with the reason shown *inside* the sheet (a SnackBar would be hidden behind it). Retry and Discard only touch this device's copy of an expense that never reached the server, so they stay available offline; Discard is the only way to clear a failed sync without a connection.
5. **Delete is server-first.** It asks for confirmation (naming the expense, and saying it's deleted for everyone and can't be undone), deletes on the server, and only then removes the local copy. It isn't queued offline, consistent with [mobile-platform.md](mobile-platform.md)'s view-and-add-only offline scope.
6. **"Already gone" counts as deleted.** Upstream `deleteExpense` (`src/lib/api.ts` @ `cc79621`) logs the activity and then deletes, outside a transaction, and errors if the expense is already gone. So a retry after a lost response fails even though the first attempt worked, and logs a second "deleted" entry. The app double-checks a failed delete with `fetchExpense` and treats `NOT_FOUND` as success.
7. **A refresh can't undo this device's own edit or delete.** A refresh downloads the whole list, then overwrites the cache, so one that was already downloading when you deleted would write the expense back (and one downloading during an edit would briefly revert it). `AppDatabase` keeps a per-group counter (`expensesGeneration`), bumped by a delete and a saved edit; `replaceServerExpenses(..., fetchedAtGeneration:)` skips its write if the counter moved while it was fetching. The check and the delete's bump both run inside drift transactions, so they can't interleave. The counter is in memory only: it guards refreshes in flight, which never outlive the process.
8. **Changes are credited to the active user in Spliit's activity log** (#92). The client used to send the literal `'None'` for every create and update, so nothing from spliit2go was attributed. It now sends the group's active participant, or `'None'` when there isn't one, as spliit-web does. "Nobody" (`'#nobody'`, see [multi-group-design.md](multi-group-design.md)) and anyone no longer in the group are never sent; upstream `Activity.participantId` is a plain string, not a foreign key, so a stale id couldn't fail a write anyway.
9. **An offline-added expense is credited to whoever added it**, not whoever is the active user when it finally syncs. The active user is captured when the expense is added, stored on the pending row (`expenses.added_by_participant_id`, schema 11), and sent by the outbox on replay. Rows queued before that change sync unattributed.

## Bugs found in review

Both were found by Ezra reproducing the flow with the real app wrapper, and both are about the sheet closing itself at the wrong moment:

- **#95: a late callback after dismissal closed the screen underneath.** Tapping outside, swiping or Back pops the sheet directly, and the sheet stays mounted through its closing animation. An Edit fetch finishing in that window popped again, taking the group screen with it. `mounted` can't tell; the sheet now only pops while its route is active.
- **#96: the Delete confirmation made the sheet look dismissed.** The #95 fix first checked "is the sheet's route current", but a dialog on top also makes it non-current without dismissing it. If a refresh removed the expense while the confirmation was up, the sheet stopped responding: Cancel left a deleted expense on screen, and confirming spun forever. `_close` now tells *dismissed* (route no longer active: do nothing) from *covered* (active, not current: defer the close until the dialog ends, then close without sending the delete).

Also found while building Delete: drift re-emits a watched query on every write to its table, not only when that row changes. So a sheet showing an uncached expense re-fetched it from the server on every unrelated refresh; it now fetches once.

## Not done / open

- Not verified on a device against a live server: that Spliit's activity log shows the name, and the Delete flow end to end.
- If the sheet is dismissed while Retry's local write is in flight (milliseconds), the expense is still requeued but syncs at the next trigger rather than immediately.
