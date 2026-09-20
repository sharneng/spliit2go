# spliit2go: completing the add/edit expense form (issues #16, #17)

Kenneth assigned #16 ("Complete add expense screen with all additional fields") and #17 ("Edit expense function") together, 2026-09-16, as related work to do one after another or combined. Handled combined, since #17 explicitly reuses #16's screen. Every field below was verified against Spliit's actual server contract (`prisma/schema.prisma`, `src/lib/schemas.ts`'s `expenseFormSchema`, the `groups.expenses.{create,update,get}` tRPC procedures, `src/lib/currency-conversion.ts`) rather than assumed — continuing the practice Kenneth asked for after the date-handling bug (#15): "In the future implement of date, we should always clarify that."

## #16: fields added

Add-expense already had Title, Amount, Category, Paid by, Paid for, Split mode. Added:

- **Date** — a tappable field opening `showDatePicker`, defaulting to today for new expenses and to the expense's own date when editing.
- **"Paid in" a different currency** — a checkbox that reveals an original-amount + currency-code pair. On save, `conversionRate` is computed client-side as `groupAmountCents / originalAmountCents`, matching Spliit's own convention (`groupAmount = originalAmount * conversionRate`, from `currency-conversion.ts`). Live exchange-rate auto-fetching (the web app's `useCurrencyRate`, an external API call) is out of scope — this app never calls out for a rate, only computes one from what the user typed.
- **"This is a reimbursement"** — a checkbox wired straight to the existing `isReimbursement` field (previously only settable via the balances screen's "mark as paid" flow, never directly).
- **"Save as default splitting options"** — sent on every create/update call (`saveDefaultSplittingOptions` in `expenseFormValues`) but **not** persisted anywhere locally: it's a form-only action flag on Spliit's side, not a column on the `Expense` Prisma model. Storing it locally would have been a fabricated field.
- **Expense Recurrence** — a `RecurrenceRule` enum (`none/daily/weekly/monthly`) mirroring Spliit's own enum, sent through unchanged. No client-side scheduling logic needed — recurrence is entirely server-driven.
- **Notes** — a multiline text field, capped at 5000 characters to match Spliit's own `EXPENSE_NOTES_MAX`.

### Deliberately not implemented: Attach documents

Spliit's document upload needs a presigned-S3-upload flow (`next-s3-upload`, 5MB/file cap) — a genuinely separate subsystem, not a form field. Two reasons to defer rather than half-build it:

1. It needs real infrastructure config (an S3 bucket + presign endpoint) that may or may not even be set up on Kenneth's self-hosted instance — unverified.
2. This app's offline-add path has no story for it at all: if a user picks a file while offline, what happens to it until the outbox replays the create? Building the picker without answering that would ship something that silently breaks offline.

The form shows a disabled "Attach documents – not yet supported in this app" row instead of omitting the field silently, so the gap reads as deliberate rather than missed. As of 2026-09-20 that is still the case.

## #17: edit expense

Reuses the add-expense screen (`AddExpenseScreen` then, `ExpenseScreen` now) via an optional `existingExpense` parameter — identical fields, identical validation, branching only in `_save()` (new expense → local pending row + outbox; edit → direct online call).

**Online-only, by design.** Per `mobile-platform.md`'s view+add-only offline scope, there's no offline-edit queueing path. `GroupScreen` fetches the tapped expense fresh via a new `SpliitClient.fetchExpense` immediately before opening the edit screen; if that fails (most commonly: offline), editing is refused with an explicit message rather than falling back to editing a possibly-stale cached copy. A still-pending (not yet synced) expense isn't tappable at all — there's no server id to fetch or edit yet.

### Explicit finding: no server-side conflict prevention

Kenneth asked directly: "Check the API to see if edit expense has any conflict prevention. Typically implemented with a last update time at the server side need to match when you save to avoid overriding somebody else's change."

**Answer: there is none.** Verified against the actual upstream source, not inferred:

- The `Expense` Prisma model (`prisma/schema.prisma`) has no `updatedAt` or version column at all — only `createdAt`.
- `groups.expenses.update`'s tRPC input schema (`update.procedure.ts`) is `{ expenseId, groupId, expenseFormValues, participantId? }` — no last-modified or version parameter of any kind.

The write is genuinely last-write-wins on the server: if two people edit the same expense around the same time, the second `updateExpense` call silently overwrites the first — no error, no warning, nothing to detect it happened. This is a real limitation of the upstream service, not something this app can fully fix client-side.

**Client-side mitigation (not a guarantee):** fetch the expense fresh immediately before opening the edit form, rather than editing the locally cached copy. This narrows the staleness window to roughly "however long the user spends filling out the edit form," but does nothing about two people opening the edit screen within that window. Documented prominently in code (`SpliitClient.updateExpense`'s doc comment, `ExpenseScreen`'s class doc comment) so this limitation stays visible to whoever touches this code next, rather than being rediscovered the hard way.

## Data model / API changes

- `Expense` gained `recurrenceRule`, `originalAmountCents`, `originalCurrency`, `conversionRate` — all optional/defaulted, no breaking change to existing callers.
- `AppDatabase` schema bumped v3→v4 (four new nullable/defaulted `Expenses` columns via `addColumn`, same additive-migration pattern as v2 and v3).
- `SpliitClient`: `createExpense` extended with the new optional params; new `fetchExpense(groupId, expenseId)` (via `groups.expenses.get`) and `updateExpense(...)` (via `groups.expenses.update`); both create and update now share one `_expenseFormValues()` builder instead of duplicating the payload shape.
- `Outbox.flush()` passes the new fields through on replay, so an expense with recurrence/original-currency set while offline doesn't lose them on sync.

## Found along the way, filed separately: byPercentage wire-format bug

While verifying field shapes against `expenseFormSchema`, found that Spliit's server expects `SplitMode.BY_PERCENTAGE` shares to sum to **10000** (percentage × 100), not 100 — this app currently sends raw 0-100 values. That means every real by-percentage expense this app creates or edits would fail server-side validation. Deliberately **not fixed here** to keep this change scoped to #16/#17; filed as [issue #18](https://github.com/sharneng/spliit2go/issues/18) instead (since closed).
