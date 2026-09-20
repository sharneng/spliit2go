# spliit2go: "Paid for" / split UX spec (issue #29)

**Status: implemented** in [#30](https://github.com/sharneng/spliit2go/issues/30) (2026-09-18, commits `5f4298a..91d92f7`). The text below is the spec as agreed; "What spliit2go does today" describes the screen *before* that change.

Kenneth attached four screenshots from spliit-ios's "Paid for" screen to [issue #29](https://github.com/sharneng/spliit2go/issues/29) (one per split mode: Evenly, Shares, Percent, Amount), judging it a better experience than both spliit-web and spliit2go's current one, and asked for a requirement spec to review and agree on **before** implementation starts. This doc is that spec, as agreed before any code was written.

The screenshots alone left several behaviors ambiguous (exact default values, exactly when the live \$ preview appears, what "Save as default split" actually does). Since spliit-ios (`spliit-app/spliit-ios`) is public, this spec is grounded in its actual source — `Packages/SpliitKit/Sources/SpliitCore/ExpenseFormDraft.swift`, `DefaultSplit.swift`, `ExpenseShares.swift`, and `Spliit/Views/ExpenseFormView.swift` — rather than inferred from four static images.

## What spliit2go does today

`lib/screens/expense_screen.dart`'s "Paid for" section: a `DropdownButtonFormField` for split mode, a `CheckboxListTile` per participant with a plain `TextField` for shares/percentage/amount when not evenly, and validation that only runs when Save is pressed (`_buildPaidFor`, which sets `_splitError` and refuses to save on the first problem it finds). No live per-row \$ preview, no "select all/none" shortcut, no running "X still to allocate" feedback while typing, and the existing "Save as default splitting options" checkbox only ever gets sent to the server (which ignores it) — it has no local effect at all.

## Proposed spec

### 1. Split-mode selector

Replace the dropdown with a 4-way segmented control: **Evenly | Shares | Percent | Amount** (Material's `SegmentedButton<SplitMode>` is the natural fit). Same four `SplitMode` values as today — no model change.

### 2. Section header: "Select all" / "Select none"

A single toggle link at the top-right of the "Paid for" section, next to the section label. Label is **"Select none"** while every participant is currently included, and **"Select all"** otherwise — i.e. it always offers the opposite of the current state, never both as separate controls (spliit-ios's own reasoning: "with everyone already in the split, 'select all' has nothing left to do"). Tapping it sets every participant's included flag to the opposite of whatever `allParticipantsIncluded` currently is. It does **not** touch anyone's typed value — a participant excluded by "Select none" keeps whatever shares/percent/amount they'd typed, so re-including them (individually, or via "Select all") brings their number back rather than resetting it.

### 3. Per-participant row

Leading checkbox (checkmark-circle style, not a plain Material checkbox) + name. While a participant is included, a trailing value column appears:

- **Evenly** — no input at all; just the computed \$ amount once it's ready (see §4). There's nothing to type in this mode.
- **Shares** — a numeric field (decimal keypad) with a "shares" unit label beside it, and the computed \$ amount beneath it once ready.
- **Percent** — a numeric field with a "%" unit label. Computed \$ amount beneath it, but **only** once the entered percentages sum to exactly 100 (see §4) — this is a real difference from Shares, not a UI inconsistency: shares are a free ratio (any positive numbers work), percentages have to land on 100 before they mean a specific amount.
- **Amount** — a numeric field with the group's currency symbol as the unit label. **No** computed \$ amount beneath it — the field the user types *is* the amount, so echoing it back would be redundant.

### 4. When the live \$-per-participant preview appears

Ported from `ExpenseFormDraft.showsShareAmounts`: shown when the expense is not a reimbursement, the split mode is not Amount, and either the mode is Evenly, or every included participant's typed value is a positive number — **and**, for Percent specifically, the percentages currently sum to exactly 100 (Shares has no such sum requirement; any positive ratio is valid and shows immediately). The amounts themselves use the same floor-plus-largest-remainder apportionment spliit2go already has in `lib/services/expense_shares.dart` (shared with Balances and Stats) — this spec doesn't change that math, only when/where it's displayed live instead of only after Save.

### 5. Default field values

Every participant's Shares/Percent/Amount field starts at the literal text **"1"** (not a computed even split, not blank) — confirmed directly from `ParticipantShareDraft`'s default (`valueText: String = "1"`). This is why the screenshots show "1 shares" / "1 %" / "1 \$" per row on a \$123 expense rather than something like "41.00" — it's a fixed starting point the user is expected to overwrite, not a smart guess. (This is superseded by a remembered default split when one applies — see §7.)

### 6. Footer line under the participant list

One line, single priority order (ported from `splitFooter`):

1. If Save has already been attempted and this section has a blocking problem (no participants selected; a share isn't a number; a share isn't positive; percentages don't sum to 100; amounts don't sum to the total) — show that problem's message, in red.
2. Else, if there's a nonzero amount still to allocate (Percent and Amount modes only — Evenly and Shares have no such concept and always skip to step 3): **"X% still to allocate."** / **"\$X.XX still to allocate."**, or, if they've gone over, **"X% over 100%."** / **"\$X.XX over the total."**
3. Else, the mode's static explanation: "Everyone selected pays an equal part." (Evenly) / "Give anyone paying a larger part more shares." (Shares) / "Percentages must add up to 100." (Percent) / "Amounts must add up to the expense total." (Amount).

This turns validation from "only checked at Save, one error at a time" into a running total the user watches while typing, with the exact same wording spliit-ios uses (worth keeping verbatim for consistency across the two apps, pending Kenneth's OK — see open questions).

### 7. "Save as default split" — a real behavior change, not just a reposition

The toggle moves into the "Paid for" section itself (bottom of the participant list), and stops being a no-op. Today, spliit2go already sends `saveDefaultSplittingOptions` to the server on every save — and the server ignores it, which turns out to be correct behavior to keep: spliit-ios's own doc comment on `DefaultSplit` confirms the tRPC procedures never read that flag; it exists only for whichever browser set it. What spliit-ios adds **on top** is a purely local, per-device, per-group memory:

- Shown for every split mode except when the expense is a reimbursement (a reimbursement is a one-off, not representative of the group's normal expenses).
- Only takes effect **after** a save actually succeeds — a split remembered from a save the server rejected would wrongly go on prefilling future expenses.
- What's remembered: the split mode, plus — for Shares and Percent — the exact per-participant values keyed by participant id. An Evenly split that covers literally everyone is remembered as "no shares data, just evenly" (so a newly-added participant is naturally included later, rather than left out). An Evenly split that *excludes* someone is remembered with that explicit membership. Amount is never remembered — one purchase's dollar amounts mean nothing for the next expense.
- Applied when starting a **new** (not edit) expense in that group afterward: pre-selects the split mode and pre-fills each participant's included flag and value. If the remembered split names a participant no longer in the group, the whole remembered split is discarded for that draft (falls back to plain "everyone, evenly") rather than silently dropping just that name — a stale default should never quietly leave someone out of a real expense.

This needs new local storage spliit2go doesn't have today. Proposed approach: two new nullable columns on the existing `AppDatabase.Groups` table (same place `serverUrl` / `activeParticipantId` already live per-group) — a `defaultSplitMode` text column and a `defaultSplitShares` column holding a JSON-encoded `{participantId: shareValue}` map (null for Evenly-covers-everyone or Amount). A small additive schema bump, consistent with how `serverUrl`/`activeParticipantId`/`lastOpenedAt` and later `information`/`currencyCode` were each added.

## What this does and doesn't touch

**Reused as-is:** the split-mode enum, the `ExpenseShare` wire model, and the apportionment math in `expense_shares.dart` — this is a UI and validation-flow rework of the existing "Paid for" section, not a rewrite of how splits are calculated or sent.

**New:** the segmented control, the live footer/validation wiring (recomputed on every keystroke instead of only at Save), the per-row live \$ preview, and the local "remembered default split" feature (new DB columns + read-on-new-expense / write-on-successful-save logic).

**Unchanged:** wire format, `SpliitClient.createExpense`/`updateExpense` payload shape (`saveDefaultSplittingOptions` is already sent and already correctly ignored by the server).

## Open questions (resolved: Kenneth approved the spec as written on #29)

1. OK to add the two new local-only `Groups` columns for the remembered default split? It's a genuinely new feature (today's checkbox does nothing locally), not just a UI tidy-up.
2. Any objection to a Material `SegmentedButton` replacing the current dropdown for split mode?
3. OK to port spliit-ios's exact copy verbatim ("Everyone selected pays an equal part.", "X% still to allocate.", etc.) rather than writing new wording, so the two apps read the same way?
4. This spec applies to both create *and* edit (spliit2go already shares one screen, `ExpenseScreen`, for both) — confirm that's intended, i.e. editing an expense should also get the live footer/select-all/preview treatment, not just adding a new one.
5. Scope as one PR or split further? My suggestion is one PR — the segmented control, live footer, and per-row preview are all reworking the same section together and are awkward to land independently — but the remembered-default-split piece (§7) is more separable if you'd rather review it on its own.

Resolved: approved on #29 ("spec is good!") and implemented in #30.
