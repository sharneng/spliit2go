# spliit2go: the dev and prod apps (issue #219)

**Status: implemented** in the PR closing [#219](https://github.com/sharneng/spliit2go/issues/219), 2026-10-07. This is the design agreed on the issue, combining Juno's and Ezra's proposals with Kenneth's choices.

Once the store version was installed on the team's phones, every development build replaced it, and switching back meant uninstalling and installing again. The two now install side by side.

## Decisions

1. **Two build flavors, `dev` and `prod`, with `dev` as the default.**

   | | `dev` (default) | `prod` |
   |---|---|---|
   | App id, Android and iOS | `com.sharneng.spliit2go.dev` | `com.sharneng.spliit2go` |
   | Name under the icon | Spliit2Go Dev | Spliit2Go |

   - `flutter: default-flavor: dev` in `pubspec.yaml` sets the default. Plain `flutter run` and `flutter build`, IDEs and the `dev` scheme in Xcode all make the dev app, in any build mode.
   - Flavor and build mode are separate choices: a release-mode dev app can be tested on a phone without replacing the installed store app. That matters because some bugs only show in release builds (#125's ML Kit crash).
   - `prod` is the real app, for store uploads and for APKs given to people. It's asked for in the command (`--flavor prod`) or with the `prod` scheme.
   - The dev app has no separate icon: Kenneth found the name enough.
2. **Android:** `dev` and `prod` product flavors in `android/app/build.gradle.kts`.
   - `dev` adds `.dev` to the app id, and each flavor sets `app_name`, which the manifest's label uses.
   - The Kotlin `namespace` and the method channel names (`com.sharneng.spliit2go/...`) are unchanged: they're code names, not the app id.
3. **iOS:** one Runner target, with shared `dev` and `prod` schemes and `Debug-`, `Release-` and `Profile-` configurations for each.
   - Each configuration sets `PRODUCT_BUNDLE_IDENTIFIER` and `APP_DISPLAY_NAME`, which `Info.plist` uses for both of its names.
   - The old `Runner` scheme is gone, since Flutter builds a flavor's scheme.
   - Swift Package Manager integration and the Flutter prepare step carry over in both schemes.
   - Automatic signing registers the dev id under the existing team.
4. **Signing by flavor, not build mode** ([#220](https://github.com/sharneng/spliit2go/pull/220) review):
   - Dev is always signed with the debug key, in debug, profile and release, whether or not the upload key is there.
   - If dev releases took the upload key, switching between `flutter run` and `flutter run --release` would change the signer. Android can't update an app to a different signer, so Flutter would uninstall the dev app with its data.
   - Only prod releases take the upload key.
5. **Guard rails, so a dev build can't be mistaken for the real app:**
   - A prod release build fails without the upload key (`android/key.properties`); before, it fell back to the debug key without a word.
   - Gradle refuses a dev Play bundle. Asked for by name (`flutter build appbundle`), it fails before anything builds. Reached through an aggregate task such as `bundleDebug`, the tasks that make a dev bundle stop before they run, so no `.aab` is written.
   - `scripts/check_android_flavors`, run in CI, checks the signing and the bundle guard, using a throwaway upload key. CI runs it on every push to main, but on a pull request only when it changes `android/`, `pubspec.yaml`, `pubspec.lock`, the script or the CI workflow. Run on every PR it finished about two minutes after the other checks (PRs #220 to #229), and Dart-only changes can't break it.
   - If a dev build reaches a store anyway, the store rejects it, because no app is registered under the dev id.
6. **Group links stay in both apps.** On Android 12 and later, unverified links (#110) open in an app only once "Open by default" is turned on for it. So everyday use turns it on for the prod app only, and dev links are tested with a package-targeted `adb` command, or by pasting the link into the dev app. Taking the handler out of dev would have left no way to test a tapped link there.
7. **Separate local data, shared server data.**
   - Each app keeps its own database, receipt cache and settings, and the dev app starts empty.
   - Both apps edit the same groups on the server, so testing in the dev app uses the demo group or test groups (SETUP.md, "Run").

## Rejected

- **A dev id for debug builds only.** It needs no switch, but release builds tested on a phone would still replace the store app.
- **A git-ignored marker file that makes a build dev.** The build's identity would depend on hidden machine state: Android and iOS would each need their own home-made check, and a stale or missing file would change which app a build makes without the command showing it.

## Where

- `pubspec.yaml`: the `default-flavor` setting.
- `android/app/build.gradle.kts`: the flavors, signing by flavor, and both guards.
- `scripts/check_android_flavors`, run by `.github/workflows/ci.yml`: the Android checks.
- `ios/Runner.xcodeproj`: the configurations and the `dev`/`prod` schemes.
- `ios/Runner/Info.plist`: the app names.
- `.github/workflows/windows-android.yml`: now checks `app-dev-debug.apk`.
- The commands are in SETUP.md: "App identity", "Release build (Android)", "Release build (iOS)", and "Android group links".
