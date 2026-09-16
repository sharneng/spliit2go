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
