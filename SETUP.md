# Setup

## 1. Clone

```
git clone https://github.com/sharneng/spliit2go.git
cd spliit2go
```

`android/` is already committed. `ios/` isn't set up yet -- see "Adding iOS" below for when that work starts.

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

## 5. Run

```
flutter run
```

Point `SpliitClient` (see `lib/api/spliit_client.dart`) at your self-hosted Spliit instance's base URL — there's a placeholder constant at the top of the file.

## Adding iOS

There's no `ios/` folder yet. Generate one from a scratch directory (not this repo), so `flutter create` doesn't try to overwrite `lib/` or `pubspec.yaml`:

```
flutter create --platforms=ios --org com.homexu.spliit2go --project-name spliit2go /tmp/spliit2go_scaffold
```

Then copy just the generated `ios/` folder into this repo:

```
cp -r /tmp/spliit2go_scaffold/ios ./ios
```

Leave `lib/`, `pubspec.yaml`, `android/`, and the docs as they are — don't let the scaffold's versions overwrite them.

## Optional: local CI on every commit

`.githooks/post-commit` `touch`es `build/trigger` after every commit -- cheap enough to run from any shell that made the commit without needing Flutter itself in that shell. A Terminal watching that file with [fswatch](https://github.com/emcrisostomo/fswatch) (`brew install fswatch`) then runs the real build/test with your actual Flutter install. This is what lets an agent working in a shell without Flutter on its `PATH` commit changes and have them actually get built and tested, without you manually kicking anything off or relaying output back.

One-time setup per clone:

```
git config core.hooksPath .githooks
mkdir -p build && touch build/trigger   # fswatch needs the path to exist first
```

Then, in a Terminal tab (where `flutter doctor` already works), leave this running while you're working on this project:

```
fswatch -o build/trigger | while read; do scripts/run_test; done
```

Each trigger runs `flutter analyze` + `flutter test --coverage` once and overwrites `.flutter-ci.log` (gitignored) at the repo root. Stop the loop with Ctrl-C or by closing the tab. `scripts/run_test` can also be run by hand any time.

Each step inside `scripts/run_test` is bounded by [`timeout`](https://www.gnu.org/software/coreutils/timeout) (or `gtimeout`, e.g. `brew install coreutils`) if either is on `PATH` -- a genuine hang in one step (seen once, issue #55) otherwise wedges this whole loop indefinitely, since nothing watching `.flutter-ci.log` from outside that process can detect or recover from a stuck one, only a human at this terminal can. Without `timeout`/`gtimeout` installed, steps run unbounded as before.

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
