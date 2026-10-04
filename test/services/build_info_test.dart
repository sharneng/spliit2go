import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/services/build_info.dart';

// #176: the commit the Android and iOS builds write, read over a channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sha = '2d83fa3c4b5a69788796a5b4c3d2e1f00a1b2c3d';
  const channel = MethodChannel('com.sharneng.spliit2go/build_info');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('short keeps 7 characters of the hash and any suffix', () {
    expect(const BuildCommit(sha).short, '2d83fa3');
    expect(const BuildCommit('$sha-dirty').short, '2d83fa3-dirty');
    expect(const BuildCommit('$sha?').short, '2d83fa3?');
    expect(const BuildCommit('').known, isFalse);
    expect(const BuildCommit(sha).known, isTrue);
  });

  test('loadBuildCommit reads gitCommit from the platform', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return '$sha-dirty';
    });
    expect((await loadBuildCommit()).full, '$sha-dirty');
    expect(calls, ['gitCommit']);
  });

  test('loadBuildCommit is unknown without the channel or when it fails', () async {
    expect((await loadBuildCommit()).known, isFalse);

    messenger.setMockMethodCallHandler(
        channel, (call) async => throw PlatformException(code: 'failed'));
    expect((await loadBuildCommit()).known, isFalse);

    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect((await loadBuildCommit()).known, isFalse);
  });
}
