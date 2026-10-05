import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/utils/haptics.dart';

import '../support/haptics.dart';

void main() {
  testWidgets('each outcome plays its own native haptic (#179)', (tester) async {
    final played = recordHaptics(tester);
    await Haptics.saved();
    await Haptics.refused();
    await Haptics.deleted();
    expect(played, [
      'HapticFeedbackType.successNotification',
      'HapticFeedbackType.errorNotification',
      'HapticFeedbackType.lightImpact',
    ]);
  });
}
