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

This runs the **dev** app, Spliit2Go Dev (see App identity below). It installs beside the real app instead of replacing it, but it edits the same groups on the server, so test with the [demo group](https://spliit.app/groups/Lh7eRlfTFBoa_DVEL7mxO) or a test group of your own, not a real one.

## App identity

There are two apps, as build flavors (#219, [docs/decisions/app-flavors.md](docs/decisions/app-flavors.md)):

| Flavor | App id, Android and iOS | Name |
|---|---|---|
| `dev`, the default | `com.sharneng.spliit2go.dev` | **Spliit2Go Dev** |
| `prod` | `com.sharneng.spliit2go` | **Spliit2Go** |

Plain `flutter run` and `flutter build`, in any build mode, make the dev app (`default-flavor` in `pubspec.yaml`), so it installs beside the store version on the same phone, with its own data. `prod` is the real app: the store uploads and any APK given to people. Build it by adding `--flavor prod`, or in Xcode with the `prod` scheme. Each app keeps its own local data (groups joined, cached expenses and receipts, settings), so the dev app starts empty.

The version comes from `pubspec.yaml` (`1.0.0+300` is version 1.0.0, build 300; it starts at 300 to stay above #174's builds, which were numbered by commit count). Every store upload needs a higher build number.

Every Android and iOS build also records the commit it was built from, and About shows it after the build number: `Version 1.0.0 (300 · a1b2c3d)`, with `-dirty` when tracked files had uncommitted changes (#176). The copy button next to it copies the version with the full hash, for bug reports. Gradle (`android/app/build.gradle.kts`) and an Xcode build phase (`ios/scripts/write_build_info.sh`) run `git` themselves, so plain `flutter run` and `flutter build`, an IDE, or an archive from Xcode all include it. Without git (a source download, or no `git` on PATH), the build warns and About shows `unknown`. The commit comes from the last Android or iOS build, so a hot reload or hot restart keeps the old one. The stores don't see it: they get `1.0.0 (300)`. Details are in [docs/decisions/build-info.md](docs/decisions/build-info.md).

The prod id is permanent once the app is published. Before #105 the id was `com.sharneng.spliit2go.spliit2go`: a build from before then is a different app to the phone, so it installs alongside the new one with its own data. Uninstall it, or re-join your groups in the new one.

### App icon

The icon and the group list's header logo come from the art in `branding/` (#106): `spliit2go-logo.png`, the logo on a transparent background, is the source for all of them, `BACKGROUND` in the script is the teal of `spliit2go-icon.png` (`#A2E0D5`, the same logo on its background), and the icons and the header logo sit on lighter versions of it: `ICON_BACKGROUND` (`#D0F0EA`, half way to white) and `HEADER_BACKGROUND` (`#B9E8E0`, a quarter of the way). To change the icon, replace those and run:

```
python3 scripts/make_icons.py
```

It needs Pillow (`pip install pillow`) and rewrites every size: iOS's `AppIcon.appiconset`, Android's launcher icons and the adaptive icon's three layers (background color, foreground, and the monochrome layer for Android 13+ themed icons), the 32 pt header logo in `assets/`, and the store icons in `branding/store/` (1024 for App Store Connect, 512 for Google Play). Commit what it writes. `branding/` isn't bundled with the app.

The store listings' screenshots, feature graphic and text are in `branding/store/` too (#112); its README says how the screenshots were taken. After new raw captures or caption changes, rebuild the framed images with `python3 scripts/make_store_assets.py` (also Pillow).

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

`storeFile` is an absolute path, or relative to `android/`. `key.properties`, `*.jks` and `*.keystore` are gitignored; never commit them. Then build the prod app:

```
flutter build appbundle --release --flavor prod
```

The bundle is `build/app/outputs/bundle/prodRelease/app-prod-release.aab`. Flutter's own "Built" line can name an older bundle still in `build/` from before #219 (`bundle/release/app-release.aab`); upload the one at this path. Raise the build number in `pubspec.yaml` before each upload (see App identity above). To check which key signed it:

```
keytool -printcert -jarfile build/app/outputs/bundle/prodRelease/app-prod-release.aab
```

An APK to give out directly is built the same way, `flutter build apk --release --flavor prod`, at `build/app/outputs/flutter-apk/app-prod-release.apk`.

A prod release build needs `key.properties` and fails without it, so what people install is never signed with the debug key. Dev release builds use the upload key when it's there and the debug key otherwise, so anyone can still build and run one (`flutter run --release`). Bundles are prod only: `flutter build appbundle` without `--flavor prod` fails rather than make a dev bundle that could be uploaded by mistake. Release builds shrink the code with R8, which debug builds don't, so try a release build on a phone before uploading: #125's ML Kit crash only happened in release (`android/app/proguard-rules.pro`).

The target API level comes from Flutter (`flutter.targetSdkVersion`, 36 with Flutter 3.47), which meets Play's rule for new apps and updates from 31 August 2026 (API 36). A newer rule would need it pinned in `android/app/build.gradle.kts`.

## iOS

The iOS project (`ios/`, added in #79) needs Xcode. It uses the same bundle ids as Android, `com.sharneng.spliit2go.dev` for dev and `com.sharneng.spliit2go` for prod (see App identity above), with a `dev` and a `prod` scheme and Debug, Release and Profile configurations for each (`Debug-dev`, `Release-prod`, and so on). It targets iOS 16 or later, and is iPhone only (#105). Plugins are integrated with Swift Package Manager, so there's no `Podfile` and no `pod install` step. Receipt scanning uses Apple's VisionKit and Vision on the iPhone (#155, `ios/Runner/ReceiptScanChannel.swift`) and ML Kit on Android (#125, `ReceiptScanChannel.kt`), each called from the app rather than through pub.dev plugins, which would bring CocoaPods back. To run it on a simulator:

```
open -a Simulator
flutter run
```

Don't re-run `flutter create` on this repo. If you ever do, don't commit the `pubspec.lock` it rewrites: it re-resolves every package and silently downgrades unrelated transitive ones (found in #80). A plain `flutter pub get` leaves the lockfile alone.

## Release build (iOS)

App Store Connect takes an archive signed by the Apple Developer team (#108). Signing is automatic: Xcode makes and renews the certificate and provisioning profile once a team is set.

1. In Xcode (`open ios/Runner.xcworkspace`), signed in with the developer account under Settings → Accounts, select the Runner target → Signing & Capabilities → Team. This writes `DEVELOPMENT_TEAM` (the team's 10-character id, which isn't secret) into `ios/Runner.xcodeproj/project.pbxproj`; commit it.
2. Create the app in App Store Connect with bundle id `com.sharneng.spliit2go` (#150).
3. Raise the build number in `pubspec.yaml` (see App identity above), then build:

```
flutter build ipa --release --flavor prod
```

   To archive from Xcode instead, choose the **prod** scheme, then Product → Archive.
4. Upload `build/ios/ipa/*.ipa` with Apple's Transporter app, or open `build/ios/archive/Runner.xcarchive` in Xcode's Organizer and choose Distribute App. It shows in TestFlight after Apple processes it.

Without a team, `flutter build ipa --release --flavor prod --no-codesign` still checks that the release archive builds (no `.ipa`). A dev upload would be refused, since App Store Connect has no app with the dev id.

Already set for upload:
- **Export compliance:** `ITSAppUsesNonExemptEncryption` is false in `ios/Runner/Info.plist`, since the app only uses the system's HTTPS. App Store Connect doesn't ask about encryption on each upload.
- **Privacy manifest:** `ios/Runner/PrivacyInfo.xcprivacy` declares no tracking and no collected data, plus the required-reason APIs in the app's own executable, which includes the plugins (statically linked Swift packages): package_info_plus reads the app bundle's dates, and shared_preferences uses UserDefaults. A manifest covers only its own bundle, so each framework in `Runner.app/Frameworks` needs its own; the app's can't stand in for it. That's why SQLite on iOS is the system's (the `hooks:` section in `pubspec.yaml`): a bundled copy is a framework without a manifest (#108). If Apple's email after an upload lists a missing API declaration (ITMS-91053), check which binary it names:
  - `Runner`: add the declaration to the app's manifest.
  - A framework: it needs a manifest inside that framework. Update or replace the package that brings it, rather than adding the declaration to the app's manifest.

  To see what a build calls, run `nm -u` on `Runner.app/Runner` and on the binaries in `Runner.app/Frameworks` of `build/ios/archive/Runner.xcarchive`, and check which frameworks contain a `PrivacyInfo.xcprivacy`.

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

Both the dev and the prod app handle the links (#219). For everyday use turn
Open by default on for **Spliit2Go** only, so a tapped link goes to the real
app; test links in the dev app with the package-targeted command below and
`com.sharneng.spliit2go.dev`, or by pasting the link into it.

To turn the link on or off from the command line, e.g. on an emulator (the prod
app; add `.dev` to both package names for the dev one):

```sh
adb shell pm set-app-links-user-selection --user 0 --package com.sharneng.spliit2go true spliit.app
adb shell pm get-app-links --user 0 com.sharneng.spliit2go
```

For device testing, substitute a real group ID and exercise both a stopped and
already-running app (`com.sharneng.spliit2go.dev` for the dev app):

```sh
adb shell am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d 'https://spliit.app/groups/GROUP_ID' com.sharneng.spliit2go
```

This package-targeted command tests the app's routing. Without the package name,
the same command goes where a tapped link would: the browser, or the app once
spliit.app is turned on. Also test cancellation
of a new-group join, repeated links, and offline opening of an existing group.
