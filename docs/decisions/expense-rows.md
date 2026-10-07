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

1. **One dimmed color for what supports a row's title:** section headers, row captions (dates, participant counts, who paid) and their icons, and the expense rows' repeat, receipts and notes marks. It's `ColorScheme.secondaryContent`, `onSurfaceVariant` at 80%, so small text keeps WCAG's 4.5:1 on the cards and on the page around them, where the section headers sit. It was first 75%, which Ezra's review of #212 measured at 4.2:1 for the headers on the light page.
2. **Through the theme**, the list tiles' subtitle style, so captions under row titles on other screens dim too. Kenneth expected that and wanted it.
3. **What you lent or owe keeps its green or red, at 90% opacity**, so it steps back with the caption without losing its color. 80% put its 12-point text at 3.7–3.9:1 on the light cards (#212 review).
4. The group row's 📎 dims with the row; its waiting state became a strike-through, since a lighter grey was too close to it (see [receipts.md](receipts.md)).

Checked by Kenneth on the iOS simulator and on a Galaxy S25.
