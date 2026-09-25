# spliit2go: expense search (issue #39)

**Status: implemented and merged** in [#98](https://github.com/sharneng/spliit2go/pull/98) (closing [#39](https://github.com/sharneng/spliit2go/issues/39)), 2026-09-24.

The search button in the group screen's bottom bar (on every tab, since [#84](https://github.com/sharneng/spliit2go/issues/84)) showed a "coming soon" message. It now opens a search screen. The behavior was checked against upstream source first (spliit-ios `ExpenseSearchView.swift` and `GroupDetailModel.swift` @ `80b2e98`; spliit-web `src/lib/api.ts` @ `cc79621`).

## Decisions

1. **Titles only, ignoring case.** That is all Spliit matches: `getGroupExpenses` filters on `title: { contains: filter, mode: 'insensitive' }`, and spliit-ios searches through that filter ("No expense here has “…” in its title"). Notes, payer, category and amount are not searched. Surrounding whitespace in the query is ignored, and an empty field is not a search: it shows a "Search this group" prompt rather than every expense.
2. **On the device, not on the server.** spliit-ios sends each query to the server, debounced. This app already caches every expense in the group (`fetchExpenses` pages through all of them), so filtering the local cache covers the same ground, works offline, finds pending and failed expenses too, and needs no debounce. `searchExpenses` in `lib/services/expense_search.dart`.
3. **Its own screen, like spliit-ios's search tab**, not a filter over the Expenses tab: pushed from the bottom bar, with the field in the app bar and focused on open, a Clear button, and Back to return to the same tab. The results watch the local database, so an edit or delete made from a result shows straight away, and such a change triggers the group screen's usual sync and refresh.
4. **Results look like the Expenses tab.** The same date sections and rows, moved into a shared `ExpenseDateList` (`lib/widgets/expense_list.dart`), and a tap opens the same details sheet.

## Verified

Widget tests cover the matching rules and the screen (focus, live filtering including a pending expense, no-match text, Clear, results following a database delete, opening a result). On the iOS simulator with a real spliit.app group: case-insensitive Latin and Chinese queries, no-match, Clear, the details sheet, and Back. The on-screen keyboard opened on entry there; dragging the results to dismiss it couldn't be checked on the simulator. Kenneth then tested on a physical device and reported the keyboard works as expected ([#98 comment](https://github.com/sharneng/spliit2go/pull/98#issuecomment-5819258210)).
