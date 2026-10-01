# spliit2go: the logo and app icon (issue #106)

**Status: implemented** in the PR for [#106](https://github.com/sharneng/spliit2go/issues/106), 2026-09-25.

Until now the app shipped Flutter's default launcher icon and borrowed Spliit's logo for the group list header. Spliit2Go now has its own logo, a plane flying across a banknote, so the app no longer uses Spliit's logo (and no longer needs its notice).

## Which design

Ezra first designed two versions, "serious" (flat) and "playful" (outlined, with a speed trail), and the app shipped the serious one on white.

**Redesign (2026-10-01).** Spliit2Go stays an unofficial app next to Spliit's own, with its own name and logo, but Ken found the first logo's colors neither elegant nor in keeping with Spliit's look. He supplied the same plane-and-banknote idea in softer colors: a coral plane over a mint banknote, on a pale teal background. Both versions are in `branding/`:

- `spliit2go-logo.png` (transparent) is the source for every size, including the header logo in the app.
- `spliit2go-icon.png` is the same logo on the solid background chosen for icons, `#A2E0D5`. The script builds the icons from the transparent logo on that color rather than from this file, so every platform's framing stays the script's; the two match to within a fraction of a color step.

The first designs were removed from `branding/` with the redesign; they're in git history.

## How it's framed

- **Android keeps the art in its safe circle.** Android's adaptive icon has to keep its art inside the central 66 dp circle of a 108 dp layer, because each phone crops the icon to its own shape.
- **The square icons leave a 10% margin.** The design's own margins made the iOS icon look small next to other apps, but filling it as much as Android's circle put the plane's nose and tail on the edges of the rounded icon (seen on the iOS 26 home screen). The art reaches 40% of the width from the center, and the store icons match.
- **Solid background, no transparency.** The App Store rejects an icon with an alpha channel; iOS rounds the corners itself. The square icons (iOS, pre-Android 8, the stores) are the logo on `#A2E0D5`.
- **Android's adaptive icon has three layers:** the background is the color `#A2E0D5` (`@color/ic_launcher_background`), not an image, so it scales and parallaxes cleanly; the foreground is the transparent logo; and the monochrome layer is what Android 13+ tints when the user turns on themed icons. A themed icon keeps only the layer's shape, so the script makes the plane and the banknote's dark green details solid and cuts out the plane's window, stripe and engine, the light trail between plane and banknote, and the banknote's light green. Without those cuts the plane and the banknote would merge into one blob.
- **The header logo is cropped to the art.** At 28 pt there's no room for margins, and it's transparent so it sits on the header in light and dark mode. It has 1x, 2x and 3x versions, so it isn't scaled down at run time.

## How it's generated

`scripts/make_icons.py` (Python with Pillow) writes every size from the source art: the sizes iOS's `Contents.json` lists, Android's launcher icons and adaptive icon layers, the header logo, and the two store icons. `flutter_launcher_icons` would do the same, but adding it downgraded an unrelated dev dependency (`cli_util` 0.5.2 to 0.4.2), and the list of sizes is short. See SETUP.md, "App icon".

Not done yet: a logo on the launch screen.
