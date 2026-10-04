import 'package:flutter/services.dart';

/// The commit the app was built from (#176), as the Android and iOS builds
/// write it: the full hash, with "-dirty" when tracked files had
/// uncommitted changes, or "?" when git couldn't tell; empty without git.
/// It comes from the last native build, so a hot reload or restart keeps
/// it. See docs/decisions/build-info.md.
class BuildCommit {
  const BuildCommit(this.full);

  final String full;

  bool get known => full.isNotEmpty;

  /// The hash cut to 7 characters, with any suffix kept, e.g. "a1b2c3d-dirty".
  String get short {
    final hash = RegExp('^[0-9a-f]*').stringMatch(full)!;
    return hash.length <= 7 ? full : hash.substring(0, 7) + full.substring(hash.length);
  }
}

const _channel = MethodChannel('com.sharneng.spliit2go/build_info');

/// Reads the commit from the platform; unknown if it can't.
Future<BuildCommit> loadBuildCommit() async {
  try {
    return BuildCommit(await _channel.invokeMethod<String>('gitCommit') ?? '');
  } catch (_) {
    // No channel (tests, other platforms) or a failure: shown as unknown.
    return const BuildCommit('');
  }
}
