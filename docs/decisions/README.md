# Decision records

Why spliit2go is built the way it is. These are point-in-time records: each says when it was written, and the code and the issue tracker win if they disagree. Current feature status is in the [top-level README](../../README.md).

| Document | Covers |
|---|---|
| [mobile-platform.md](mobile-platform.md) | Why Flutter, the tRPC-as-plain-HTTP approach, the offline scope (view and add only), and the first live test |
| [multi-group-design.md](multi-group-design.md) | Per-group server URL and active user, the group list as the app root, asking "Who are you?" once per group, the "You" section on Balances where it can be changed, creating a group, and sharing its link ([#2](https://github.com/sharneng/spliit2go/issues/2), [#12](https://github.com/sharneng/spliit2go/issues/12), [#85](https://github.com/sharneng/spliit2go/issues/85), [#99](https://github.com/sharneng/spliit2go/issues/99), [#115](https://github.com/sharneng/spliit2go/issues/115), [#3](https://github.com/sharneng/spliit2go/issues/3)) |
| [date-handling.md](date-handling.md) | `expenseDate` is a calendar date, not an instant, and how it is read and written ([#15](https://github.com/sharneng/spliit2go/issues/15)) |
| [expense-form-completion.md](expense-form-completion.md) | The full add and edit expense form, and why Spliit has no edit-conflict protection ([#16](https://github.com/sharneng/spliit2go/issues/16), [#17](https://github.com/sharneng/spliit2go/issues/17)) |
| [paid-for-split-ux-spec.md](paid-for-split-ux-spec.md) | The "Paid for" split rework and the remembered default split ([#29](https://github.com/sharneng/spliit2go/issues/29), [#30](https://github.com/sharneng/spliit2go/issues/30)) |
| [group-list-redesign.md](group-list-redesign.md) | Favorites/Active/Archived sections, sort, swipe and menu actions, and the full-swipe dismissal fix ([#68](https://github.com/sharneng/spliit2go/issues/68), [#71](https://github.com/sharneng/spliit2go/issues/71), [#75](https://github.com/sharneng/spliit2go/issues/75)) |
| [date-sections.md](date-sections.md) | Date sections in the expense list and the activity log, matching spliit-web and spliit-ios; week start by region; same-day order ([#88](https://github.com/sharneng/spliit2go/issues/88), [#91](https://github.com/sharneng/spliit2go/issues/91)) |
| [expense-details-and-delete.md](expense-details-and-delete.md) | Tap to view an expense (offline too), actions by sync state, server-first Delete, the refresh guard, and crediting changes to the active user ([#90](https://github.com/sharneng/spliit2go/issues/90), [#92](https://github.com/sharneng/spliit2go/issues/92)) |
| [expense-search.md](expense-search.md) | Searching a group's expenses by title, on the device rather than the server ([#39](https://github.com/sharneng/spliit2go/issues/39)) |
| [stats-screen.md](stats-screen.md) | The Stats tab for the first release: one "The group" total instead of Summary and Totals, no "You" section yet, rows that stack instead of overflowing ([#103](https://github.com/sharneng/spliit2go/issues/103)) |
