# spliit2go: the Stats tab for the first release (issue #103)

**Status: implemented** in [#104](https://github.com/sharneng/spliit2go/pull/104) (closing [#103](https://github.com/sharneng/spliit2go/issues/103)), 2026-09-25.

The Stats tab had a Summary card (count, average, largest expense, active span) and a Totals card (group spending, "You paid", "Your share", and a hint to pick an active user). On a phone the Summary card overflowed: a long "largest expense" title and the date span didn't fit beside their labels. Kenneth asked for a minimal cleanup before the first release, replacing both cards with spliit-ios's single "The group" section (`StatsView.groupSection` @ `80b2e98`).

## Decisions

1. **One figure for the group.** "Total group spending", the amount large and bold, and the footer "Settling up is not spending, so reimbursements are left out of every figure here." That is true of the figure: `totalGroupSpendingCents` skips reimbursements, as spliit-web's `getTotalGroupSpending` does. As in spliit-ios, a negative total (refunds outweighing spending) reads "Total group earnings", and the amount is shown without a sign because the label already says which way.
2. **No "You" section for now.** spliit-ios follows "The group" with "You" (your spending and your share, each as a share of the group). Kenneth's call: the same numbers are already in "By participant", which is good enough for the first release; a follow-up release will polish Stats. So "You paid", "Your share" and the pick-an-active-user hint are gone, and the Stats tab no longer uses the active user at all. Picking or changing it is on the Balances tab's "You" row ([multi-group-design.md](multi-group-design.md)).
3. **"By participant" and "By category" stay, without overflow.** Their amounts were `ListTile.trailing`, which has no width limit: in French at large text a participant's share took the whole row. Each label and amount now share a line when they fit and stack, leading-aligned, when they don't, as spliit-ios's rows do at large text sizes.

Still not built, as before: charts, a monthly breakdown, recurring-spending projections and a date range. Stats is "all time" only.

## Verified

Widget tests: the group card; reimbursements left out of the total; a negative total read as earnings; a group with only settlements still shows "No expenses yet"; English and French at 2× text on a 360pt phone with the app wrapper (the French case caught the participant-row overflow). On the iOS simulator with the spliit.app group from the issue's screenshot: the same $13,071.55 total, and each participant's paid and share unchanged.
