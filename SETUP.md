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

## iOS

The iOS project (`ios/`, added in #79) needs Xcode. It uses the same bundle id as Android, `com.sharneng.spliit2go.spliit2go`, and targets iOS 15 or later. Plugins are integrated with Swift Package Manager, so there's no `Podfile` and no `pod install` step. To run it on a simulator:

```
open -a Simulator
flutter run
```

Don't re-run `flutter create` on this repo. If you ever do, don't commit the `pubspec.lock` it rewrites: it re-resolves every package and silently downgrades unrelated transitive ones (found in #80). A plain `flutter pub get` leaves the lockfile alone.

## Running checks locally

`scripts/run_test` runs the full check CI runs -- `dart run build_runner build`, `flutter gen-l10n`, `flutter analyze`, `flutter test --coverage`, in that order -- and logs the result to `.flutter-ci.log` (gitignored) at the repo root:

```
scripts/run_test
```

Each step is bounded by [`timeout`](https://www.gnu.org/software/coreutils/timeout) (or `gtimeout`, e.g. `brew install coreutils`) if either is on `PATH`, so a genuine hang in one step (seen once, issue #55: a Flutter-test/drift interaction left a dangling `Timer`) fails loudly in the log instead of hanging indefinitely. Without `timeout`/`gtimeout` installed, steps just run unbounded. A killed step's exit status is `124`.

An earlier version of this repo also had a `.githooks/post-commit` hook and an `fswatch` loop to run this automatically after every commit -- a workaround for an early sandboxed environment that couldn't run Flutter itself at all, and so needed a side channel to trigger a real Flutter install elsewhere. That doesn't apply to a normal local setup, Claude Code, or Codex -- all three can just run `scripts/run_test` (or the individual `flutter`/`dart` commands above) directly, so that indirection has been removed.

### Android group links (#45)

The app handles `https://spliit.app/groups/<groupId>` on launch and while running.
A joined group opens using its cache; a new group opens the Join screen with its
URL filled in. Tap Join to fetch it. Other hosts remain supported through manual
URL entry, but are not registered as Android link domains.

Automatic verified opening requires the **spliit.app domain owner** to serve
`https://spliit.app/.well-known/assetlinks.json` with the
`delegate_permission/common.handle_all_urls` relation, package name
`com.sharneng.spliit2go.spliit2go`, and the SHA-256 fingerprint of the installed
app's signing certificate. This repository cannot configure that domain. Until
that association is published, users may need to enable spliit.app under Android
Settings → Apps → spliit2go → Open by default → supported web addresses.

For device testing, substitute a real group ID and exercise both a stopped and
already-running app:

```sh
adb shell am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d 'https://spliit.app/groups/GROUP_ID' com.sharneng.spliit2go.spliit2go
```

This package-targeted command tests intent routing, not domain verification.
Also test an ordinary link tap after enabling the supported domain, cancellation
of a new-group join, repeated links, and offline opening of an existing group.
