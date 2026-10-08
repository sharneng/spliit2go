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
   - The web app's terms: Paid by, Paid for, the split modes, Reimbursement.
8. **How colors are matched to iOS.** When we follow an iOS color on our green-tinted palette, we don't copy Apple's value. We measure its contrast against its own background, then lighten or darken our color, keeping its hue, until it reaches the same contrast. The dark row line ([#213](https://github.com/sharneng/spliit2go/issues/213)) was set this way. Kenneth judges the result on a phone, next to iOS's own screens.
9. **One popup menu on both platforms, styled after One UI's** ([#217](https://github.com/sharneng/spliit2go/issues/217)). Kenneth tried two iPhone-only menus and turned both down. Flutter's iOS pull-down menu (`CupertinoMenuAnchor`) is far from iOS 26's glass menus. Material's `MenuAnchor` made translucent showed the content behind it without iOS's blur, and imitating the blur would look clumsy. `MenuAnchor` adds nothing these short menus need.
   - The menu is a themed `PopupMenuButton` or `showMenu` (`popupMenuTheme`). Its rows come from `lib/widgets/app_menu.dart`.
   - **Color:** the page's color in light mode, the card's in dark. The dark row lines' tone (#37443B) over a whole menu left the emerald check and the red under 4.5:1.
   - **Edge:** a 0.5pt hairline. In light mode it's a shade darker than the menu. In dark mode it's a shade lighter (#29322C), halfway to the row lines' tone, because a darker edge vanished on the black page.
   - **Shape and placement:** 24pt corners, a soft shadow, no tint, dropping below its button.
   - **Rows:** 40pt tall, labels at 17pt beside 24pt icons. Icons lead; in a menu that picks one, the emerald check leads instead, and the other rows keep that room so the labels line up.
10. **Dark mode's red is the amount red, #FF8A9B** ([#217](https://github.com/sharneng/spliit2go/issues/217)). It's used for delete buttons, destructive menu rows and errors. Material's #FFB4AB is a pale pink that read faint.

The layout of particular screens is in their own records: [group-list-redesign.md](group-list-redesign.md), [expense-rows.md](expense-rows.md), [stats-screen.md](stats-screen.md) and [receipts.md](receipts.md).

## Still open

1. **Android Material You** (colors taken from the wallpaper) is deliberately not used, so the brand colors stay fixed. This still needs confirming as a decision.
2. **Android's high-contrast text** doesn't affect our dimmed colors yet. Flutter doesn't expose it, so it would need a platform channel or a plugin.
