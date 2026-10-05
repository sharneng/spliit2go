import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the haptics played from here to the end of the test, as
/// `HapticFeedback.vibrate`'s type argument (`HapticFeedbackType.…`).
/// Other platform-channel calls are answered with null, as they are
/// with no handler.
List<String> recordHaptics(WidgetTester tester) {
  final played = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') played.add(call.arguments as String);
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return played;
}
