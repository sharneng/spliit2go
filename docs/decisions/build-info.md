# The commit in each build

Written 2026-10-04 for [#176](https://github.com/sharneng/spliit2go/issues/176), which replaced [#174](https://github.com/sharneng/spliit2go/issues/174)'s wrapper script.

## What it's for

To tell which code a build came from, both for testing on our own phones and in bug reports. About shows the commit after the build number, `Version 1.0.0 (300 · a1b2c3d)`, and its copy button copies `Spliit2Go 1.0.0 (300 · <full hash>)`.

## What gets recorded

One string, the same on both platforms:

| Value | Meaning | About shows |
|---|---|---|
| `<full hash>` | HEAD, and no uncommitted changes to tracked files | `a1b2c3d` |
| `<full hash>-dirty` | `git diff --quiet HEAD --` exited 1 | `a1b2c3d-dirty` |
| `<full hash>?` | HEAD is known, but `git diff` failed with another exit code | `a1b2c3d?` |
| empty | No git on PATH, not a git checkout, or `rev-parse` failed | `unknown` |

The last two also print a build warning. A local build never fails over the commit, release builds included, so a source download still builds. A CI release job can require a known commit once there is one.

Untracked files don't count as changes. A `-dirty` build isn't an exact reproduction of the named commit.

## How it's built

Each platform's own build system runs `git`, so plain `flutter run` / `flutter build`, IDEs and Xcode archives all record it with no extra step:

- **Android:** `android/app/build.gradle.kts` has a `GitCommitSource` `ValueSource` that runs `git rev-parse HEAD` and `git diff --quiet HEAD --` and becomes `BuildConfig.GIT_COMMIT`. Through a `ValueSource`, git runs on every build, and HEAD and the dirty state are both inputs Gradle tracks, including under the configuration cache ([Gradle: external processes](https://docs.gradle.org/current/userguide/configuration_cache_requirements.html#config_cache:requirements:external_processes)). A missing `git` executable throws, and that's caught as empty. Gradle runs on Windows, macOS and Linux, so Android builds get the commit on all three.
- **iOS:** the Runner target's "Build Info" phase runs `ios/scripts/write_build_info.sh`, which writes `BuildInfo.plist` into the app's resources before signing. The phase declares that file as its output and has `alwaysOutOfDate = 1`, so it runs on every build, including incremental ones. It writes its own file rather than a key in the processed `Info.plist`, since Xcode runs build steps in parallel and a script could race Xcode's own writing of that file.
- **Dart:** `lib/services/build_info.dart` asks for `gitCommit` on the `com.sharneng.spliit2go/build_info` channel (`MainActivity.kt`, `AppDelegate.swift`). No channel, or any failure, is unknown.

The commit is native data, read when About opens, so a hot reload or hot restart keeps the commit of the last native build.

## The build number

The stores only see the version and build number, e.g. `1.0.0 (300)`, which still come from `pubspec.yaml`. Raise `+N` before each store upload. #174 used the commit count as the build number, through `scripts/flutter_stamped`. That wrapper didn't run on Windows and replaced the standard commands. Its counts could also go down: after a squash merge, or with a plain `flutter run` over a stamped build. On Android, `flutter run` gets past a lower build by uninstalling the app, which removes its data. The hash alone identifies the build, so the count and the script were dropped. `pubspec.yaml` moved to build 300 to stay above every stamped build (249–252 were seen), so the first plain build over one is an upgrade and keeps the app's data.

## Ruled out

- **Code generation with build_runner:** `flutter run` doesn't run it, and `.git/HEAD` isn't one of its inputs, so the hash would go stale.
- **Dart build hooks (`hook/build.dart`):** they produce native code and data assets, not Dart constants ([Dart hooks](https://dart.dev/tools/hooks)). Data assets are still experimental in Flutter 3.47.
- **A generated asset read with `rootBundle`:** the build would write the file into the source tree, which needs a committed placeholder and leaves the checkout changed after every build.
- **`--dart-define` from a wrapper:** #174's approach, replaced for the reasons above.

## Windows

None of the maintainers build on Windows. The manually run [Windows Android build](../../.github/workflows/windows-android.yml) workflow builds a debug APK on `windows-latest` and checks that the commit is in it. It passed in the #176 PR. Run it from the Actions tab after changing this, or when a Windows developer reports a problem.
