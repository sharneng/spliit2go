# Setup

## 1. Clone

```
git clone https://github.com/sharneng/spliit2go.git
cd spliit2go
```

Both platform folders, `android/` and `ios/`, are committed.

## 2. Install Flutter

Follow https://docs.flutter.dev/get-started/install for your OS, then confirm:

```
flutter doctor
```

## 3. Install dependencies

```
flutter pub get
```

## 4. Generate drift's code

The local database (`lib/db/`) uses drift, which needs codegen for the `.g.dart` files:

```
dart run build_runner build --delete-conflicting-outputs
```

## 5. Generate localization code

The app's strings (`lib/l10n/app_*.arb`) are compiled to a generated `AppLocalizations` class by `flutter gen-l10n` (config in `l10n.yaml`, triggered automatically by `pubspec.yaml`'s `flutter.generate: true`). `flutter run`/`flutter test`/`flutter build` all run this for you as part of their own build, but `flutter analyze` does not — so if you run analyze (or open the project in an editor) before ever running or testing the app, generate it explicitly first or every file importing `app_localizations.dart` fails with "target of URI doesn't exist":

```
flutter gen-l10n
```

## 6. Run

```
flutter run
```

There's no server to configure in code. In the app, tap **+** and paste a group's link from Spliit, e.g. `https://spliit.app/groups/<groupId>` or the same link on your own instance; each group remembers its own server.

## App identity

Both platforms use the app id `com.sharneng.spliit2go` and the display name **Spliit2Go**; the version comes from `pubspec.yaml` (`1.0.0+1` is version 1.0.0, build 1). Every store upload needs a higher build number. The id is permanent once the app is published. Before #105 the id was `com.sharneng.spliit2go.spliit2go`: a build from before then is a different app to the phone, so it installs alongside the new one with its own data. Uninstall it, or re-join your groups in the new one.

### App icon

The icon and the group list's header logo come from the art in `branding/` (#106): `spliit2go-logo.png`, the logo on a transparent background, is the source for all of them, and the icons put it on the background color `BACKGROUND` in the script (`#A2E0D5`, taken from `spliit2go-icon.png`, the same logo on its background). To change the icon, replace those and run:

```
python3 scripts/make_icons.py
```

It needs Pillow (`pip install pillow`) and rewrites every size: iOS's `AppIcon.appiconset`, Android's launcher icons and the adaptive icon's three layers (background color, foreground, and the monochrome layer for Android 13+ themed icons), the 28 pt header logo in `assets/`, and the store icons in `branding/store/` (1024 for App Store Connect, 512 for Google Play). Commit what it writes. `branding/` isn't bundled with the app.

## Release build (Android)

Google Play takes an app bundle (`.aab`) signed with an **upload key** (#107). With Play App Signing, which Play Console enables on the first upload, Google keeps the key that signs what users install; the upload key only proves an upload came from you, and Google can reset it if it's lost. Losing it still blocks updates until they do, so back up the keystore and its password somewhere safe outside the repo.

Create the keystore once, outside the repo (`keytool` comes with Android Studio's JDK, in `Contents/jbr/Contents/Home/bin`):

```
keytool -genkeypair -v -keystore ~/keys/spliit2go-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Then point the build at it in `android/key.properties`:

```
storeFile=/Users/<you>/keys/spliit2go-upload.jks
storePassword=<the keystore password>
keyAlias=upload
keyPassword=<the key password; the same one unless you set another>
```

`storeFile` is an absolute path, or relative to `android/`. `key.properties`, `*.jks` and `*.keystore` are gitignored; never commit them. Then build:

```
flutter build appbundle --release
```

The bundle is `build/app/outputs/bundle/release/app-release.aab`. Raise the build number in `pubspec.yaml` before each upload (see App identity above). To check which key signed it:

```
keytool -printcert -jarfile build/app/outputs/bundle/release/app-release.aab
```

Without `key.properties`, release builds are signed with the debug key, so anyone can still build and run one (`flutter run --release`); Play rejects those. Release builds shrink the code with R8, which debug builds don't, so try a release build on a phone before uploading: #125's ML Kit crash only happened in release (`android/app/proguard-rules.pro`).

The target API level comes from Flutter (`flutter.targetSdkVersion`, 36 with Flutter 3.47), which meets Play's rule for new apps and updates from 31 August 2026 (API 36). A newer rule would need it pinned in `android/app/build.gradle.kts`.

## iOS

The iOS project (`ios/`, added in #79) needs Xcode. It uses the same bundle id as Android, `com.sharneng.spliit2go`, targets iOS 15 or later, and is iPhone only (#105). Plugins are integrated with Swift Package Manager, so there's no `Podfile` and no `pod install` step. Receipt scanning (#125) is Android only: ML Kit is called from `android/app` (`ReceiptScanChannel.kt`), not through the pub.dev plugins, which would bring CocoaPods back. To run it on a simulator:

```
open -a Simulator
flutter run
```

Don't re-run `flutter create` on this repo. If you ever do, don't commit the `pubspec.lock` it rewrites: it re-resolves every package and silently downgrades unrelated transitive ones (found in #80). A plain `flutter pub get` leaves the lockfile alone.

## Diagnosing errors on a device

An unexpected error (a malformed response, a database failure, anything the app doesn't know how to explain) shows a short message with **Tap for details** under it, or a **Details** button on a snack bar: the operation, the error and the stack trace, selectable, with a **Copy** button, so it can be pasted into an issue without a debugger attached. The same text goes once to the debug log (`flutter run`, `flutter logs`, Xcode's console, or `adb logcat`). Known situations, such as a link to a group that doesn't exist or no connection, just explain themselves, with no details and no log. The policy is in [docs/decisions/error-handling.md](docs/decisions/error-handling.md) (#118, #119).

## Running checks locally

`scripts/run_test` runs the full check CI runs -- `dart run build_runner build`, `flutter gen-l10n`, `flutter analyze`, `flutter test --coverage`, in that order -- and prints each step's output:

```
scripts/run_test
```

Every step runs even if an earlier one failed. The script exits `0` only if all of them passed; otherwise it exits `1`, and its last line names the failed steps with their exit status, e.g. `FAILED: test:1` (#135). To keep a log, redirect it; `.flutter-ci.log` at the repo root is gitignored for this:

```
scripts/run_test > .flutter-ci.log 2>&1
```

Each step is bounded by [`timeout`](https://www.gnu.org/software/coreutils/timeout) (or `gtimeout`, e.g. `brew install coreutils`) if either is on `PATH`, so a genuine hang in one step (seen once, issue #55: a Flutter-test/drift interaction left a dangling `Timer`) fails loudly instead of hanging indefinitely. The tests get 120 seconds: the suite takes about 80 on a busy machine. Without `timeout`/`gtimeout` installed, steps just run unbounded. A timed-out step's exit status is `124`.

An earlier version of this repo also had a `.githooks/post-commit` hook and an `fswatch` loop to run this automatically after every commit -- a workaround for an early sandboxed environment that couldn't run Flutter itself at all, and so needed a side channel to trigger a real Flutter install elsewhere. That doesn't apply to a normal local setup, Claude Code, or Codex -- all three can just run `scripts/run_test` (or the individual `flutter`/`dart` commands above) directly, so that indirection has been removed.

### Android group links (#45)

The app handles `https://spliit.app/groups/<groupId>` on launch and while running.
A joined group opens using its cache; a new group opens the Join screen with its
URL filled in. Tap Join to fetch it. Other hosts remain supported through manual
URL entry, but are not registered as Android link domains.

The links aren't verified, and the manifest doesn't ask Android to try
(no `android:autoVerify`, #110). Verification needs the **spliit.app domain
owner** to serve `https://spliit.app/.well-known/assetlinks.json` with the
`delegate_permission/common.handle_all_urls` relation, package name
`com.sharneng.spliit2go`, and the SHA-256 fingerprint of the app's signing
certificate (Play App Signing's, for store installs). This repository can't
configure that domain, so on Android 12 and later a spliit.app link opens in
the browser until the user turns it on once: Settings → Apps → Spliit2Go →
Open by default → Add link → spliit.app. Android 11 and earlier ask which app
to use instead. If spliit.app ever publishes the file (it
could come up in spliit-app/spliit#658), add `android:autoVerify="true"` back to the intent
filter. Store listings shouldn't promise that links open the app.

To turn the link on or off from the command line, e.g. on an emulator:

```sh
adb shell pm set-app-links-user-selection --user 0 --package com.sharneng.spliit2go true spliit.app
adb shell pm get-app-links --user 0 com.sharneng.spliit2go
```

For device testing, substitute a real group ID and exercise both a stopped and
already-running app:

```sh
adb shell am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d 'https://spliit.app/groups/GROUP_ID' com.sharneng.spliit2go
```

This package-targeted command tests the app's routing. Without the package name,
the same command goes where a tapped link would: the browser, or the app once
spliit.app is turned on. Also test cancellation
of a new-group join, repeated links, and offline opening of an existing group.
