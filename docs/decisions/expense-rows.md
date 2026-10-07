# spliit2go: expense rows (issues #205, #207)

**Written 2026-10-06.** Kenneth set the direction in both issues and checked each step on the iOS simulator before it was committed. Neither spliit-web nor spliit-ios colors categories or shows what you lent or owe in the list, so these are this app's own choices.

## Category colors (#205)

1. **One color per category grouping**, from the group list's monogram palette, so a row's icon says what kind of expense it is. Hashing the grouping names the way group ids are hashed (Kenneth's option 1) put the seven groupings on only four of the eight colors, so each grouping is assigned one by hand (`lib/widgets/category_icon.dart`). A grouping a server adds later is hashed.
2. **Emerald is left out**, so the icons don't blend with the app's own green. It is kept for "you" (see below).
3. **A white glyph in a circle**, matching the monograms and the round add buttons. Without a known category the circle stays neutral.

## The row (#207)

Two lines, like a group's in the group list (`lib/widgets/expense_list.dart`):

- **First line:** the bold title; marks when the expense repeats, has receipts, or has notes; the amount.
- **Second line:** the date, what you lent or owe, and who paid.

4. **What you lent or owe** follows the balance math (`expenseShareCents`). If you paid, you lent the amount less your share; if someone else did, you owe your share. It is colored as Balances colors money, with an arrow out (↗) or in (↙). It is not shown when nobody is "you", when you're not in the expense, or for a reimbursement, whose italic amount already says what it is.
5. **It follows the date** rather than sitting centered. Centered, it zigzagged with the widths of the dates and names around it.
6. **Dates in the row are numeric and zero-padded** (`formatShortDate` in `lib/utils/date_format.dart`), drawn with tabular figures, so every date has the same width and what follows lines up. The order and separators are each locale's own, from CLDR (`DateFormat.yMd`), only padded: `09/10/2026` in en-US, `10/09/2026` in en-GB and French, `2026/09/10` in Chinese. A numeric date is only ambiguous to someone reading another locale's dates, so the spelled-out form (`formatDate`) stays wherever a date stands on its own, and for screen readers.
7. **Who paid sits under the amount**, at most a third of the row and cut short rather than wrapped, with "You" for you. A pending or failed expense shows its sync state there instead.
8. **Each person has a fixed color**, a dot at the row's edge so the dots line up. You are always emerald; the others take the remaining seven colors in alphabetical order by name, starting over after seven. Not the group's order: the server returns participants in no fixed order, which recolored people between refreshes. Adding someone can still move the people after them in the alphabet to the next color.
9. **A screen reader hears the row as a few short sentences, the title first** (Kenneth's suggestion, reordered). The title comes first because someone moving down the list tells rows apart by it, and most move on after the first few words. Then comes one sentence of who paid what, when, and the category's name (the icon's meaning), then what you lent or owe, the sync state, and the marks: "Dinner. Jo paid $30.00 on Oct 6, 2026, General. You owe $10.00. Repeats. Has receipts. Has notes." A reimbursement reads "paid back", which says what its italic amount shows. Each language has its own sentence templates, since French and Chinese order the words differently, and Chinese ends its sentences with 。. Each sentence ending makes the reader pause. The row stays one button that opens the details.
10. **On a narrow phone or at a large text size the row reflows rather than overflows** (Ezra's review of #208). The date and what you lent or owe are measured first and the payer gets what's left. When that leaves no room for a few letters of the payer, the date takes a line of its own, with your part and the payer on the next. On the first line the marks drop out before the title shrinks to nothing (they're still read out), and at large text sizes the title gets two lines unless a word of it wouldn't fit one. Amounts shrink rather than wrap.

## Less important content dimmed (#211)

Kenneth asked for the lists to read more quietly, on the group list and the expense list first.

1. **One dimmed color for what supports a row's title:** section headers, row captions (dates, participant counts, who paid) and their icons, the expense rows' repeat, receipts and notes marks, and the group row's 📎. It's `SpliitColors.secondaryContent`.
2. **As dim as Apple's `secondaryLabel`, not WCAG AA's 4.5:1.** Light mode is the scheme's `onSurfaceVariant` at 60%; dark mode is Apple's dark `secondaryLabel` exactly, `#EBEBF5` at 60%. How we got there:
   - We first held it to 4.5:1. Ezra's review of #212 measured section headers at 4.2:1 on the light page and lent/owe at 3.7–3.9:1, so we went to 80% and 90%.
   - Kenneth found that louder than iOS's own Settings next to it. Apple's secondary text measures 3.3–3.4:1 in light mode, so it doesn't meet 4.5:1 either.
   - WCAG 2's ratio also misjudges dark mode. APCA, the perceptual model proposed for WCAG 3, scores the dimmed dark text far lower than WCAG 2 does. Even so, Apple's dark secondary text reads well on a phone at night at about Lc 41–45. Kenneth's eye agreed with Apple rather than with either formula.
3. **With the system's Increase Contrast it's undimmed** (iOS's accessibility setting, via `MaterialApp.highContrastTheme`/`highContrastDarkTheme`): the schemes' own `onSurfaceVariant`, and lent/owe solid. That's how Apple serves people who need more contrast, rather than making everyone's default louder.
4. **Through the theme**, the list tiles' subtitle style, so captions under row titles on other screens dim too. Kenneth expected that and wanted it.
5. **Section headers are the rows' title size, bold** (16 points, weight 700), so a header still reads as one in the dimmed color.
6. **What you lent or owe keeps its green or red, at 90% opacity**, so it steps back with the caption without losing its color. Colored text reads more easily than grey at the same contrast (Kenneth: traffic-light colors).
7. **Backgrounds:**
   - Light mode's page is `surfaceContainerLow`, a step lighter than before, so the dimmed headers on it read about as well as the captions on the white cards.
   - Dark mode's page is black, like iOS's grouped screens, with cards at `surfaceContainer` (`#1B211D`, close to iOS's `#1C1C1E`).
8. The group row's 📎 dims with the row. Its waiting state became a strike-through, since a lighter grey was too close to the normal clip (see [receipts.md](receipts.md)).

Checked by Kenneth on the iOS simulator, his iPhone and a Galaxy S25.

## Lines between rows (#213)

The lines between a card's rows, everywhere in the app (`GroupedDivider`), follow iOS's Settings and One UI, which Kenneth compared side by side:

- **In light mode, the page's own color**, as if the card were cut through to the page behind it, rather than Material's `outlineVariant` grey.
- **In dark mode, the card's own color made lighter**, same hue and saturation, until it stands off the card as much as iOS's dark `separator` stands off iOS's card: 1.60:1, `#37443B` on our `#1B211D`. iOS draws its dark lines a little brighter than the card (Kenneth's screenshot); using iOS's grey itself would have broken the scheme's green tint. Kenneth compared it with dimmer versions (1.26:1 and 1.35:1) on the simulator against iOS's Settings and chose this one: in full screenshots its contrast looks the same as iOS's.
- **One point thick.** In the page's color a single device pixel all but disappears.
- **Stopping where the rows' content does**, 16 points from the card's end edge, rather than running to the edge. They still start past a row's leading icon, as before.
