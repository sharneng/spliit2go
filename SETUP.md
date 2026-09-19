# Setup

This repo was scaffolded without the Flutter SDK available (no network access to fetch it in the environment that created it), so the platform folders (`android/`, `ios/`) don't exist yet. `lib/`, `pubspec.yaml`, and the docs are ready; you need to generate the platform scaffolding locally once and merge it in.

## 1. Install Flutter

Follow https://docs.flutter.dev/get-started/install for your OS, then confirm:

```
flutter doctor
```

## 2. Generate the platform folders

From a scratch directory (not this repo), so `flutter create` doesn't try to overwrite `lib/` or `pubspec.yaml`:

```
flutter create --platforms=android,ios --org com.homexu.spliit2go --project-name spliit2go /tmp/spliit2go_scaffold
```

Then copy the generated platform folders into this repo:

```
cp -r /tmp/spliit2go_scaffold/android ./android
cp -r /tmp/spliit2go_scaffold/ios ./ios
cp /tmp/spliit2go_scaffold/analysis_options.yaml ./analysis_options.yaml   # only if you want to replace the one already here
```

Leave `lib/`, `pubspec.yaml`, `README.md` as they are in this repo — don't let the scaffold's versions overwrite them.

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

## Publishing to GitHub

From this directory:

```
git remote add origin git@github.com:<your-username>/spliit2go.git
git push -u origin main
```

## Optional: local CI on every commit

`.githooks/post-commit` `touch`es `build/trigger` after every commit -- cheap enough to run from any shell that made the commit, yours or Claude's (via the device bridge on a connected folder), without needing Flutter itself in that shell. A Terminal watching that file with [fswatch](https://github.com/emcrisostomo/fswatch) (`brew install fswatch`) then runs the real build/test with your actual Flutter install. This is what lets Claude commit changes on your behalf and have them actually get built and tested, without you manually kicking anything off or relaying output back.

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

Each step inside `scripts/run_test` is bounded by [`timeout`](https://www.gnu.org/software/coreutils/timeout) (or `gtimeout`, e.g. `brew install coreutils`) if either is on `PATH` -- a genuine hang in one step (seen once, issue #55) otherwise wedges this whole loop indefinitely, since nothing watching `.flutter-ci.log` over the device bridge can detect or recover from a stuck process, only a human at this terminal can. Without `timeout`/`gtimeout` installed, steps run unbounded as before.
