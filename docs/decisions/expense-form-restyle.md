# spliit2go: restyling the add/edit expense screen

Written 2026-10-09. **Status: agreed with Kenneth; being built** ([#256](https://github.com/sharneng/spliit2go/issues/256)). Step 1 ([#258](https://github.com/sharneng/spliit2go/issues/258)) is done: the form's state and arithmetic are in `ExpenseFormModel` (`lib/screens/expense_form/expense_form_model.dart`), with no visual change. Step 2 ([#259](https://github.com/sharneng/spliit2go/issues/259)) is built: ✕, the kind button and ✓, and the scan, "what it was for", notes and receipts cards (`ReceiptScanCard`, `ReceiptsCard`). Step 3 ([#260](https://github.com/sharneng/spliit2go/issues/260)) is built: Paid by as a row with the participant sheet (`lib/widgets/participant_sheet.dart`, whose rows "Who are you?" shares), and Paid for as `SplitCard` (`lib/screens/expense_form/split_card.dart`). The last part of the UI Polished milestone, after currency conversion ([#251](https://github.com/sharneng/spliit2go/issues/251), [#252](https://github.com/sharneng/spliit2go/issues/252)). The form still predates the rest of the app's look: a single column of Material fields with a Save button at the bottom.

## Goals (Kenneth)

1. Save moves to the top bar, as a ✓.
2. Category and "is a settlement" move up. A new settlement's category is Payment, and other parts of the screen change for a settlement too.
3. Monograms for people.
4. Inset groups.

## Principles

- **Look like this app, not like spliit-ios.** Reuse what the app already does:
  - group settings: ✓ in `TopBarButtons`, borderless fields on `GroupedSection` cards;
  - the expense details sheet: `Monogram`s in `participantColors`, "(you)" naming;
  - "Who are you?" (`ActiveUserSheet`): picking a participant by monogram;
  - App settings: `GroupedRow`s for choices.

  spliit-ios is a reference for behaviour, not for layout.
- **Every input is always visible.** Nothing sits behind an extra tap: no "More" card, no collapsed sections. Rows appear and disappear only when what they mean appears or disappears, such as the exchange rate when paying in another currency.
- **Inputs before results.** Things you type come first, things the form works out come after them, in the order they're derived. That's why the currency comes before the amounts typed in it, and totals come after the amounts they add up.
- **No control that means nothing.** A field that has no meaning in the current context is hidden, not disabled: a settlement's category, the checkboxes outside an even split.

## Top bar

- **✕ on the left closes** (Kenneth, 2026-10-09). Adding or editing an expense is a task you finish or abandon, not a screen you navigate through. If anything was changed, it asks "Discard changes?" first. Today it only asks when there's an unsent receipt.
- **The title says what's being added or edited,** left-aligned as on the app's other screens: "New expense", "New settlement", "Edit expense", "Edit settlement". "Mark as paid" opens as "New settlement".
- **A button beside ✓ switches between Expense and Settlement in one tap** (Kenneth, 2026-10-10, on a device). Its icon is the kind it switches to: the payment icon on an expense ("Switch to settlement"), the receipt icon on a settlement ("Switch to expense"). It shares ✓'s capsule. Tried first and dropped: a title menu ("New expense ▾", whose arrow is easy to miss) and a capsule switch in the title's place (which costs the title, so New vs Edit is lost).
- **✓ on the right saves.** It's the same `TopBarButtons` circle and saving spinner as group settings. The Save button at the bottom goes.
- **When a save is refused:**
  - a field that doesn't validate keeps its error inline, under its row, and the list scrolls to the first one;
  - a failed save shows its error at the top of the list, and the list scrolls up to it.

## The cards

Rows are `GroupedRow`s with a label and a value, or borderless fields on the card. A row that opens a screen gets ›; a row that opens a sheet or menu doesn't (`GroupedRow`'s rule, #186). Amounts use the tabular `moneyInput` style, right-aligned.

### Expense

```
 (✕)  New expense                (⇄ ✓)
 ┌───────────────────────────────────┐
 │ ⎙  Scan receipt              文 EN │   new expenses only
 └───────────────────────────────────┘
   Point the camera at a receipt…
 ┌───────────────────────────────────┐
 │ What was it for?                  │
 │───────────────────────────────────│
 │ 🍽  Category        Restaurants  › │
 │───────────────────────────────────│
 │ Date                  Oct 9, 2026 │
 │───────────────────────────────────│
 │ Repeat                    Never ▾ │
 └───────────────────────────────────┘
 ┌───────────────────────────────────┐
 │ Paid in              US Dollar  › │   only for a group with an ISO code
 │───────────────────────────────────│
 │ Amount                   $ 20.00  │
 └───────────────────────────────────┘
 ┌───────────────────────────────────┐
 │ Paid by          (A) Alice (you)  │   opens the participant sheet
 └───────────────────────────────────┘
   Paid for                  Select none   Evenly only
 ┌───────────────────────────────────┐
 │ [ Evenly | Shares | Percent | Amount ]
 │───────────────────────────────────│
 │ ☑ (A) Alice (you)          $10.00 │
 │ ☑ (B) Bob                  $10.00 │
 │ ☐ (C) Carol                       │
 │───────────────────────────────────│
 │ Save as default split        ( ○) │
 └───────────────────────────────────┘
   Split evenly between 2.             red when it doesn't add up
   Notes
 ┌───────────────────────────────────┐
 │ Anything worth remembering?       │
 └───────────────────────────────────┘
   Receipts
 ┌───────────────────────────────────┐
 │ ＋ Add photo                       │
 └───────────────────────────────────┘
```

Paid in another currency, the currency card follows the order of the conversion: what was paid, at what rate, and what that comes to.

```
 ┌───────────────────────────────────┐
 │ Paid in           Japanese Yen  › │
 │───────────────────────────────────│
 │ Amount                  ¥ 12,000  │   typed, in the paid-in currency
 │───────────────────────────────────│
 │ EUR/JPY ⇄             [ 176.84 ]  │   the exchange rate; tap EUR/JPY to swap
 │───────────────────────────────────│
 │ In euros                  €67.86  │   worked out; not a field
 └───────────────────────────────────┘
   EUR/JPY 176.84 is the published rate on Oct 8.
   Use the published rate
```

### Paid for: checkboxes only where they mean something

Kenneth, 2026-10-09: a checkbox only means something for an even split. In every other mode, 0 is the same as not included.

- **Evenly:** no checkboxes either (Kenneth, 2026-10-10, on a device: they were ugly next to the dimming). A tap on a person includes them or leaves them out, and someone left out is dimmed as in the other modes. To a screen reader, each row is still checked or not. The amount it comes to is beside each included one. **Select all / Select none** in the caption.
- **Shares, Percent, Amount:** no checkboxes. Each row has the person's value. An empty or 0 value means not included, and that row's name is dimmed. Shares and Percent also show the amount each comes to, under the value as spliit-ios does, so the name keeps the row's width. From 130% text size, the value and amount go under the name. No Select all / none: there's nothing to select.
- **Switching modes keeps who's included:**
  - from Evenly, included people get 1 share, an equal percentage, or an equal amount (largest-remainder rounding), and the others get empty;
  - back to Evenly, anyone with a value above 0 is checked.

```
   Paid for
 ┌───────────────────────────────────┐
 │ [ Evenly | Shares | Percent | Amount ]
 │───────────────────────────────────│
 │ (A) Alice (you)            [ 2 ]  │
 │                           $13.33  │
 │ (B) Bob                    [ 1 ]  │
 │                            $6.67  │
 │ (C) Carol                  [   ]  │   dimmed: not included
 └───────────────────────────────────┘
   3 shares.
```

### Settlement

```
 (✕)  New settlement             (⇄ ✓)
 ┌───────────────────────────────────┐
 │ Settlement                        │   filled in if the title was empty
 │───────────────────────────────────│
 │ Date                  Oct 9, 2026 │   no Category: see below
 │───────────────────────────────────│
 │ Repeat                    Never ▾ │
 └───────────────────────────────────┘
 ┌───────────────────────────────────┐
 │ Paid in           Japanese Yen  › │
 │───────────────────────────────────│
 │ EUR/JPY ⇄             [ 176.84 ]  │   only when converting
 └───────────────────────────────────┘
   EUR/JPY 176.84 is the published rate on Oct 8.
 ┌───────────────────────────────────┐
 │ From                     (B) Bob  │
 └───────────────────────────────────┘
   To
 ┌───────────────────────────────────┐
 │ (A) Alice (you)          ¥ 8,000  │
 │ (C) Carol                ¥ 4,000  │
 │ (D) Dan                  ¥        │   dimmed: not included
 │───────────────────────────────────│
 │ Total                   ¥ 12,000  │   sum of the above
 │ In euros                  €67.86  │   only when converting
 └───────────────────────────────────┘
   Bob paid Alice ¥8,000 and Carol ¥4,000.
   Notes …   Receipts …
```

### What a settlement changes

| | Expense | Settlement |
|---|---|---|
| Category | Any | **Hidden** (below) |
| Who paid | "Paid by" | "From" |
| Who it's for | "Paid for": the 4 split modes, Save as default split | **"To": several recipients allowed, amounts only** (Kenneth, 2026-10-09). No split control, no default split. Rows as in the Amount mode |
| The amount | Typed in the currency card | **The sum of the "To" amounts,** then converted (below). There's no Amount field |
| Footer | The split's remainder | The sentence: "Bob paid Alice ¥8,000 and Carol ¥4,000." |
| Title | Required | "Settlement" filled in if it was empty, and cleared again on switching back if untouched |
| Scan receipt | New expenses | Hidden |
| Repeat, Notes, Receipts | Shown | Shown |

### A settlement's category

Kenneth, 2026-10-09: a category means nothing for a settlement, so the row is hidden, and the rule takes no code beyond that:

- **A settlement created here is saved with Payment** (category 1). That's applied when saving, not when switching, so the category you'd picked comes back if you switch back to Expense before saving.
- **Editing never changes the category.** An existing settlement keeps whatever it has, hidden. An expense switched to Settlement while editing keeps its category too. Switching by mistake and back must not cost anything, and a hidden category isn't worth the code to change it.

## How amounts are worked out

Kenneth, 2026-10-09: a settlement's "To" list adds up to the amount paid, which is converted to the amount. An expense split by amount works the same way when it's converted.

```
Settlement:          To amounts ──sum──▶ originalAmount ──convert──▶ amount
Expense, converted:  Amount (typed) = originalAmount ──convert──▶ amount
                     (by amount: each person's amount typed in the paid-in currency,
                      adding up to the typed Amount)
```

- **Typed amounts are in the paid-in currency:** a settlement's "To" amounts, and an expense's per-person amounts when split by amount. Not converting, the paid-in currency is the group's, and nothing changes from today.
- **`amount = round(originalAmount × rate × 10^groupDigits / 10^originalDigits)`**, as in [currency-conversion.md](currency-conversion.md).
- **Shares are stored in the group currency's minor units,** as Spliit stores them, and must add up to `amount` exactly. Converting each person on their own and rounding could miss by a cent. So the converted `amount` is shared out in proportion to the typed amounts, with the largest-remainder rounding already in `lib/services/expense_shares.dart`. One function, used for both the settlement and the expense.
- **Opening an existing one** shows each person's amount in the paid-in currency: `originalAmount` shared out in proportion to the stored shares, with the same rounding, so they add up to `originalAmount` exactly. That's for display only: what's saved is decided by the rule below.

### What's saved stays saved until its inputs change

Ezra's review of #257: converting into the paid-in currency for display and back again for saving doesn't always give back what was there, because each way rounds. A title-only edit, or a "Mark as paid" nobody typed into, mustn't move money. So, extending #255's rule (an edited conversion keeps its saved amounts while the currency, rate, amount paid and settlement flag are as saved):

- **A value worked out from others is saved as it already stands while none of the inputs it comes from has changed.** "Changed" means the field reads differently from when the form opened. Typing a value and back doesn't count, as in #255.

  | Saved value | Kept while these read as they did when the form opened |
  |---|---|
  | `amount`, `originalAmount` | Paid in, the rate, the typed Amount or the "To" amounts, the settlement switch |
  | Each person's share | The above, plus the split mode, who's included, and each person's value |
  | `conversionRate` | Paid in, the rate field, and its swap. The rate is shown as a rounded inverse, so it's only worked out from the field once the field is changed |

  Title, category, date, repeat, Paid by / From, notes and receipts are inputs to none of them.
- **Once one of the inputs changes,** everything that depends on it is worked out afresh from what's on screen, as described above. That includes the rows nobody touched: their shares can shift by a minor unit, which is the rounding of the amounts that are now there.
- **"Mark as paid" settles the balance exactly.** The balance is what's being settled, so it's kept as the group-currency `amount` and the recipient's share. Paid in the group's currency, the "To" amount is the balance. Paid in another currency, the "To" amount is filled in with the balance converted into that currency (balance ÷ rate, rounded), and changing the currency or the rate fills it in again, while `amount` stays the balance. Once you type a "To" amount or add a recipient, the forward conversion takes over. The saved `originalAmount × rate` can then differ from `amount` by the rounding, which Spliit already allows (#255).

  This replaces #252's reversed settlement direction, where the group-currency amount was fixed and the amount to transfer was worked out from it.

**Acceptance cases** (Ezra's examples), as model tests in step 1 or wherever the behaviour lands:

1. **Mark as paid, converted.** JPY group, Bob owes Alice ¥1,000, paid in EUR at `EUR/JPY = 176.84`.
   - Prefilled: To Alice €5.65.
   - Saved untouched: `amount` 1000, Alice's share 1000, `originalAmount` 565. Forward conversion would give ¥999 and leave ¥1 owed.
   - Typing €5.66 instead: `amount` = round(566 × 176.84 / 100) = 1001.
2. **Unequal shares that look equal.** JPY expense, `amount` 1001, `originalAmount` 566 (EUR cents), rate 176.84, split by amount with stored shares [500, 501].
   - Opening it shows [€2.83, €2.83].
   - A title-only edit saves [500, 501] unchanged. Forward allocation would make it a tie and could swap who owes the extra yen.
   - Changing either amount re-allocates both.
3. **A rate from the web.** Stored `conversionRate` 0.00565 shows as `EUR/JPY = 176.991`. Saving with the rate field untouched sends 0.00565, not 1 / 176.991.

## The exchange rate, as one number

Kenneth, 2026-10-09: `JPY 1 = EUR 0.0056547` doesn't read naturally. A rate reads best as one number of 1 or more, the way people know it: "176 yen to the euro".

- **Written the way banks and card statements write it: `EUR/JPY = 176.84`.** In that notation the first currency is the one that's 1, and the number is what it's worth in the second. So the more valuable currency goes first:
  - `EUR/JPY = 176.84`
  - `GBP/EUR = 1.1599`
  - `EUR/VND = 29,263`

  `JPY/EUR = 176.84` would read as "1 yen is 176.84 euros" to anyone who has read a rate before.
- **The order comes from a currency ranking.** A list of every currency by value (euros per unit) ships with the app, built once from a Frankfurter table. Whenever a new rate table is saved, the ranking is redone from it, so it stays right as currencies move. The ranking is used even when no rate for the pair is known, offline with nothing saved.
- **Tap `EUR/JPY` to swap** to `JPY/EUR = 0.0056548`. The number flips with it (1 ÷ the number, 6 significant figures). The swap is remembered on this device for that pair, in both directions, and it wins over the ranking from then on.
- **One rate field, and the footer is only for reference.** The field is the rate that's used, in the order shown. It's filled in with the published rate, and you can overwrite it with any value. The footer shows the published rate for the date in the same order, and says when the field differs from it, with "Use the published rate" to put it back.
- **What's stored doesn't change:** `conversionRate` is still 1 paid-in unit in group units, so `1 / 176.84` here, or the number itself when the paid-in currency comes first. The shown number is rounded to 6 significant figures when it's filled in. Saving and the amounts use the rate worked out from that same number, so what's shown, saved and calculated agree. A saved rate is the exception: it's sent back as stored until the field is changed (see [What's saved stays saved](#whats-saved-stays-saved-until-its-inputs-change)). This replaces #252's rounding of the stored rate to 6 significant figures.
- **The server can hold it:** `conversionRate` is `DECIMAL(65,30)` in PostgreSQL (Prisma `Decimal?`), 30 digits after the point. It reaches the server through a JavaScript number, so a write keeps about 15 significant digits. `1 / 176.84` = `0.00565483…` fits easily, and reading it back shows `176.84` again.
- **An expense saved with a rate from the web** (for example `0.00565`) shows as `EUR/JPY = 176.991`.

## Visual cards and code

`expense_screen.dart` is about 1,900 lines. Which inputs go on which card is a matter of what's read together. Which code builds them is a matter of how complex they are. The two don't have to match one to one:

| Card on screen | Inputs | Built by |
|---|---|---|
| Top bar | ✕, the title, the Expense/Settlement button, ✓ | **The screen itself** |
| Scan receipt (new expenses) | Scan button, receipt language; status in the footer | **`ReceiptScanCard`**: the scan's state machine moves out of the screen |
| What it was for | Title, Category (expenses), Date, Repeat | **The screen itself:** simple inputs, a few lines each. The category picker screen stays where it is |
| Currency | Paid in, the amount (expense), the rate and its swap, the converted amount; rate status and "Use the published rate" in the footer | **`CurrencyCard`**: the rate lookup, its states, the currency ranking, the swap and the status text move out of the screen |
| Paid by / From | One participant | **A row in the screen** opening **`showParticipantSheet`**, reused for both. The sheet's rows (`ChoiceRow`) are also "Who are you?"'s |
| Paid for / To | Split control, participant rows with their values, Select all/none (Evenly), Save as default split, a settlement's totals; remainder or sentence in the footer | **`SplitCard`**: one widget for both, settlement mode being "amounts only, with totals". It reads who's included from `ExpenseFormModel` (in Evenly the checks, otherwise a value other than 0), so a settlement mode is the Amount rows without the mode control and default split |
| Notes | Notes | **The screen itself** |
| Receipts | Photos | **`ReceiptsCard`**: the existing `ReceiptAttachmentsField` (`lib/widgets/receipt_attachments.dart`), restyled as a card |

- **State and arithmetic** move from the widget's `State` into a plain `ExpenseFormModel` (a `ChangeNotifier`): what's typed, the derived amounts, conversion, shares and validation. The cards read and write it, and it can be unit-tested without building widgets. The screen keeps the top bar, saving, the outbox and navigation.
- **Files:** the new widgets go in `lib/screens/expense_form/`, since only this screen uses them. The participant sheet goes in `lib/widgets/`, next to `active_user_sheet.dart`, whose rows it shares.
- **Order of the work:** first extract the model and the cards keeping today's look, so the tests stay green. Then restyle, so each step is reviewable.

## Accessibility: a fast follow, not part of this

Kenneth, 2026-10-09: don't make everyone pay for accessibility. The split control stays a 4-way segmented control, one tap. A follow-up issue will make it switch to a menu **only when the segments don't fit** (large text, narrow screens), measured, not by a fixed text size. Label-and-value rows stacking at large text sizes, and screen-reader labels per row, go in the same follow-up.

## Decisions so far

| Date | Decision |
|---|---|
| 2026-10-09 | ✕ closes, ✓ saves, in the top bar |
| 2026-10-09 | The screen title is the Expense/Settlement switch, as a menu |
| 2026-10-10 | Replaced, after trying it and a capsule switch on a device: a plain left-aligned title, and a button beside ✓ whose icon is the kind it switches to. A settlement hides Scan receipt, which can't read one |
| 2026-10-09 | A settlement's category is hidden. A settlement created here is saved with Payment. Editing never changes the category, whether it was already a settlement or is switched to one |
| 2026-10-09 | Settlements can have several recipients, amounts only |
| 2026-10-10 | Paid for has no checkboxes in any mode: in Evenly a tap includes or leaves out, and the left-out are dimmed. A row's amount goes under its value, and at large text the value under the name |
| 2026-10-09 | A settlement's amount is the sum of its "To" amounts, converted to the group's currency. A converted expense split by amount takes per-person amounts in the paid-in currency too |
| 2026-10-09 | "Mark as paid" in another currency keeps the balance as the amount until a "To" amount is typed, then works like any typed amount (Ezra's review) |
| 2026-10-09 | Saved amounts, shares and rate stay as saved until an input they come from changes (extends #255; Ezra's review) |
| 2026-10-09 | Checkboxes only in Evenly. In other modes, and in "To", empty or 0 means not included |
| 2026-10-09 | The exchange rate is one number, the more valuable currency first: `EUR/JPY = 176.84`. The order comes from a bundled currency ranking, redone from each new rate table. Tap the pair to swap, remembered per pair |
| 2026-10-09 | One rate field, prefilled from the published rate and freely editable. The footer shows the published rate for reference. |
| 2026-10-09 | The split control stays segmented. The menu, only when it doesn't fit, is a fast follow |
| 2026-10-09 | No collapsed or "More" areas. Cards are visual groups, separate from how the code is split |
| 2026-10-09 | Follow the app's own patterns, not spliit-ios's layout |

## Open questions

1. ~~The title menu~~ Decided 2026-10-10: a button beside ✓ (see "Top bar").
