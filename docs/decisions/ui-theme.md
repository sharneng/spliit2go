# spliit2go: the UI theme (issue #11)

**Status: in progress.** This index was written 2026-10-07. [#11](https://github.com/sharneng/spliit2go/issues/11) stays open until the items under "Still open" are settled.

The theme wasn't decided all at once. It was settled piece by piece, in focused issues. This page gathers those decisions in one place and links to the records that explain each one.

## Decisions

1. **One Material 3 codebase that feels native on both platforms.**
   - There's no separate Cupertino widget tree (no `flutter_platform_widgets`).
   - Dialogs are adaptive, so they show as iOS-style alerts on iPhone. Scrolling, page transitions, back gestures and text selection follow each platform automatically.
2. **iOS-style grouped layout on both platforms**, which Samsung's One UI shares:
   - Rounded inset cards on one page background, for settings screens and for the group, expense and activity lists (`GroupedSection`, [#180](https://github.com/sharneng/spliit2go/issues/180), [#185](https://github.com/sharneng/spliit2go/issues/185), [#186](https://github.com/sharneng/spliit2go/issues/186), [#195](https://github.com/sharneng/spliit2go/issues/195)).
   - Lines between rows: in light mode the page's color, in dark mode a little brighter than the card. They're a point thick and stop where the content does ([#213](https://github.com/sharneng/spliit2go/issues/213), [expense-rows.md](expense-rows.md)).
   - A flat app bar that keeps the page's color while content scrolls under it ([#188](https://github.com/sharneng/spliit2go/issues/188)).
3. **spliit-ios's colors** ([#178](https://github.com/sharneng/spliit2go/issues/178)):
   - Its emerald accent as the primary color, lightened in dark mode.
   - Its money colors: green for what you're owed, red for what you owe.
   - Each participant has a fixed color, with you always in emerald ([#207](https://github.com/sharneng/spliit2go/issues/207), [expense-rows.md](expense-rows.md)).
4. **Page and cards** ([#211](https://github.com/sharneng/spliit2go/issues/211)):
   - Light mode: the page is `surfaceContainerLow` and the cards are a step lighter.
   - Dark mode: the page is black, as iOS's grouped screens, and the cards are `surfaceContainer` (`#1B211D`, close to iOS's `#1C1C1E`).
   - Screens, app bars and sheets all share the page's color ([#186](https://github.com/sharneng/spliit2go/issues/186) review).
5. **The group screen's tab bar is a card floating off the screen's edges** ([#197](https://github.com/sharneng/spliit2go/issues/197)):
   - Since [#215](https://github.com/sharneng/spliit2go/issues/215) it's in the cards' color, lifted by a shadow.
   - Its selected tab is highlighted in the add button's color (`primaryContainer`), so the bar and the button read as one set.
   - The add buttons are round ([#199](https://github.com/sharneng/spliit2go/issues/199)).
6. **Less important content is dimmed to Apple's `secondaryLabel` levels, not WCAG AA's 4.5:1** ([#211](https://github.com/sharneng/spliit2go/issues/211), [expense-rows.md](expense-rows.md)).
   - This covers section headers, captions and marks. Apple's own secondary text is about 3.3:1; next to iOS's Settings, the 4.5:1 version looked louder than the system.
   - The system's Increase Contrast undims it (`highContrastTheme`).
   - Section headers are the row title's size, in bold.
7. **Lucide icons and the web app's words**, so spliit.app users find their way ([#205](https://github.com/sharneng/spliit2go/issues/205), [expense-rows.md](expense-rows.md)):
   - Lucide icons for categories, marks and captions, as on spliit.app; categories are colored by their grouping.
   - The web app's terms: Paid by, Paid for, the split modes. Except settlement, not the web's "reimbursement" ([#242](https://github.com/sharneng/spliit2go/issues/242)): native speakers find it the accurate word for paying back within a group, and spliit-ios already moved off it. Only the API keeps `isReimbursement`, which `spliit_client.dart` maps at the edge.
8. **How colors are matched to iOS.** When we follow an iOS color on our green-tinted palette, we don't copy Apple's value. We measure its contrast against its own background, then lighten or darken our color, keeping its hue, until it reaches the same contrast. The dark row line ([#213](https://github.com/sharneng/spliit2go/issues/213)) was set this way. Kenneth judges the result on a phone, next to iOS's own screens.
9. **One popup menu on both platforms, styled after One UI's** ([#217](https://github.com/sharneng/spliit2go/issues/217)). Kenneth tried two iPhone-only menus and turned both down. Flutter's iOS pull-down menu (`CupertinoMenuAnchor`) is far from iOS 26's glass menus. Material's `MenuAnchor` made translucent showed the content behind it without iOS's blur, and imitating the blur would look clumsy. `MenuAnchor` adds nothing these short menus need.
   - The menu is a themed `PopupMenuButton` or `showMenu` (`popupMenuTheme`). Its rows come from `lib/widgets/app_menu.dart`.
   - **Color:** the page's color in light mode, the card's in dark. The dark row lines' tone (#37443B) over a whole menu left the emerald check and the red under 4.5:1.
   - **Edge:** a 0.5pt hairline. In light mode it's a shade darker than the menu. In dark mode it's a shade lighter (#29322C), halfway to the row lines' tone, because a darker edge vanished on the black page.
   - **Shape and placement:** 24pt corners, a soft shadow, no tint, dropping below its button.
   - **Rows:** 40pt tall, labels at 17pt beside 24pt icons. Icons lead; in a menu that picks one, the emerald check leads instead, and the other rows keep that room so the labels line up.
10. **Dark mode's red is the amount red, #FF8A9B** ([#217](https://github.com/sharneng/spliit2go/issues/217)). It's used for delete buttons, destructive menu rows and errors. Material's #FFB4AB is a pale pink that read faint.
11. **Letter spacing: the system font's own, a little tighter where text runs long.** ([#231](https://github.com/sharneng/spliit2go/issues/231)) Material 3's type scale adds up to half a point between letters: +0.5 on body text, +0.25 on 14pt text. That spread our text wider than native iOS, stock Android and One UI, whose own font is the widest of the three. So `theme.dart` sets every text style to the font's own spacing. Three are tighter, so long titles and names fit:
    - Row titles and menu labels (`bodyLarge`): −0.4.
    - Row captions (dates, who paid, counts): −0.2.
    - Amounts: −0.4.

    Kenneth tuned these on the simulator against spliit-ios and on the emulator (2026-10-08). The settlement title's italic stays the font's own; Flutter can't change its angle except by slanting the drawn text, which Kenneth decided against.
12. **Top bar buttons on a card, as iOS 26's toolbars, on both platforms** ([#228](https://github.com/sharneng/spliit2go/issues/228)). A single button gets a 44pt circle; several share one capsule, as the group list's sort and app settings do. They're in the cards' color with a light shadow (elevation 1, lighter than the tab bar's 3), 16pt from the screen's edges like the cards (`lib/widgets/top_bar_buttons.dart`). The back and close buttons get the same circle from the theme (`actionIconTheme`), with Flutter's own back icons. On iOS that's the centered rounded chevron, not `Icons.adaptive`'s, which sits left of center. Kenneth compared it with spliit-ios 2.6.1 on the simulator and checked it on the emulator (2026-10-08).
   - Expense search's clear button stays bare: it belongs to the search field, as on iOS.
   - The receipt-download indicator sits beside the group screen's ••• circle. It only shows while receipts download.
13. **List rows a step more compact than Material's, one-line card rows at 48pt** ([#233](https://github.com/sharneng/spliit2go/issues/233)). Material's list row minimums are 56pt for one line and 72pt for two, roomier than iOS's 44pt. Kenneth compared against iOS's defaults and chose vertical density -1 for every list row (`listTileTheme.visualDensity`), which takes 4pt off each: 52pt and 68pt. One-line rows in a card (`GroupedRow` without a caption) go further, to 48pt (`GroupedRow.oneLineMinHeight`).
14. **Sheets in dark mode stand off the screen behind them** ([#239](https://github.com/sharneng/spliit2go/issues/239), Kenneth on devices). In the page's black, a slide-up sheet's top edge disappeared against the dimmed screen behind it; spliit-ios's sheets are lighter than the page. So in dark mode, sheets are 2/3 of the way from the black page to the card color. Halfway wasn't enough, and the cards inside still stand a step lighter. They also get a hairline edge (0.5pt, white at 15%) around the top and corners. The handle is dimmed to the secondary icon color at 40%, as iOS's grabber. Light mode is unchanged. This is all in `bottomSheetTheme`, so it covers every sheet. The top bar's button cards (`topBarCard`) get the same edge in dark: their shadow lifts them in light mode but can't show on black, least of all in a sheet.
   - **Why not just a minimum height:** `ListTile.minTileHeight` replaces the defaults for every line count. A 44pt minimum also shrank the two-line expense and group rows to their roughly 60pt of content, because Material's 72pt two-line minimum had been holding them up. Density keeps Material's own sizes, only smaller, so the custom minimum is limited to one-line card rows.
   - **The density is on list rows only:** buttons, checkboxes and other controls keep their default density.

The layout of particular screens is in their own records: [group-list-redesign.md](group-list-redesign.md), [expense-rows.md](expense-rows.md), [stats-screen.md](stats-screen.md) and [receipts.md](receipts.md).

## Still open

1. **Android Material You** (colors taken from the wallpaper) is deliberately not used, so the brand colors stay fixed. This still needs confirming as a decision.
2. **Android's high-contrast text** doesn't affect our dimmed colors yet. Flutter doesn't expose it, so it would need a platform channel or a plugin.
