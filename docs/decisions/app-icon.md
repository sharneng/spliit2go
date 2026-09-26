# spliit2go: the logo and app icon (issue #106)

**Status: implemented** in the PR for [#106](https://github.com/sharneng/spliit2go/issues/106), 2026-09-25.

Until now the app shipped Flutter's default launcher icon and borrowed Spliit's logo for the group list header. Spliit2Go now has its own logo, a plane flying across a banknote, so the app no longer uses Spliit's logo (and no longer needs its notice).

## Which design

Ezra designed two versions (both in `branding/`):

- **Serious** (flat, no outlines): the logo everywhere in the app and on the stores. It stays clean at icon and browser sizes, down to 16 px.
- **Playful** (outlined, with a speed trail): for marketing material only, such as a store banner. It isn't used in the app.

`spliit2go-logo-serious.png` (transparent) is the source for every size; `spliit2go-logo-serious-white.png` is the same design on white as delivered, kept for reference.

## How it's framed

- **Android keeps the art in its safe circle.** Android's adaptive icon has to keep its art inside the central 66 dp circle of a 108 dp layer, because each phone crops the icon to its own shape.
- **The square icons leave a 10% margin.** The design's own margins made the iOS icon look small next to other apps, but filling it as much as Android's circle put the plane's nose and tail on the edges of the rounded icon (seen on the iOS 26 home screen). The art reaches 40% of the width from the center, and the store icons match.
- **White background, no transparency.** The App Store rejects an icon with an alpha channel; iOS rounds the corners itself. Android's adaptive icon is the transparent logo over a white background layer.
- **The header logo is cropped to the art.** At 28 pt there's no room for margins, and it's transparent so it sits on the header in light and dark mode. It has 1x, 2x and 3x versions, so it isn't scaled down at run time.

## How it's generated

`scripts/make_icons.py` (Python with Pillow) writes every size from the source art: the sizes iOS's `Contents.json` lists, Android's launcher icons and adaptive icon layers, the header logo, and the two store icons. `flutter_launcher_icons` would do the same, but adding it downgraded an unrelated dev dependency (`cli_util` 0.5.2 to 0.4.2), and the list of sizes is short. See SETUP.md, "App icon".

Not done yet: Android 13's themed (monochrome) icon, and a logo on the launch screen.
