# spliit2go: expense categories offline (issue #132)

Written 2026-09-27.

## The bug

Offline, the expense form's category picker had only General. Each screen read `categories.list` from the server every time it opened, and fell back to General when that failed. The list's category icons and the Stats tab's category names had the same gap: offline they showed the generic banknote and "Category 9". Kenneth found it testing on a phone; before #133, the failure was one of about 180 log lines in a passing test run.

## What it does now

- **Each server's list is kept on the device** (`CachedCategories`, schema 14), keyed by server URL, because categories belong to a Spliit instance, not to a group. A successful read replaces the list whole, in the server's order. An empty answer isn't kept.
- **Until a server's list has been read, the app uses Spliit's seeded categories** (`spliitSeedCategories`, ids 0 to 43). Spliit creates them in its migrations with fixed ids (upstream cc796210: `20240108194443_add_categories`, and `20250308000000_add_category_donation` for Donation). So "Groceries" is 9 on spliit.app and on a self-hosted instance alike; spliit-ios relies on the same (`CategoryEntity.swift`, 80b2e98). So the picker is complete offline from the very first launch, not only after a first online visit.
- **Read once per app run per server** (`CategoryStore.refresh`). Categories almost never change: Spliit has added one since 2024. A failed read is tried again on the next group refresh, including the one when the connection comes back. Reads at the same time share one request.
- **Failures follow #119.** Offline is expected and not logged. Anything else, such as a malformed answer, is logged once, and what's on the device stays.
- **Where it's used.** The group screen and Stats follow the stored list, so they update when a read lands. The expense form, which is short-lived, reads the stored list, asks the server, then reads the list again, rather than keeping a query open.

## Not solved

- **An instance whose categories differ from the seeded ones.** Before its list is first read, the picker offers the seeded ones. An id the instance doesn't have would be refused when the expense syncs, and the outbox would mark it failed with Retry or Discard. That needs an instance that changed Spliit's seeded data, and it ends once the app has read that instance's list online.
- **spliit-ios doesn't keep categories;** it asks the instance each time. spliit2go is offline-first, so it does.
