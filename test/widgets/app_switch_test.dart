import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/widgets/app_switch.dart';

// Drawn at iOS 26's height, taking only that room; its taps reach over
// the padding around it to 48pt (Kenneth, 2026-10-13).
void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('$platform: the room it draws in, a 48pt target', (tester) async {
      var value = false;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              key: const Key('row'),
              height: 48,
              child: Center(
                child: StatefulBuilder(
                  builder: (context, setState) =>
                      AppSwitch(value: value, onChanged: (v) => setState(() => value = v)),
                ),
              ),
            ),
          ),
        ),
      ));

      expect(tester.getSize(find.byType(AppSwitch)).height, closeTo(31 * AppSwitch.scale, 0.5));

      // Near the row's top edge: above the drawn switch, in the padding.
      final row = tester.getRect(find.byKey(const Key('row')));
      await tester.tapAt(Offset(tester.getCenter(find.byType(AppSwitch)).dx, row.top + 2));
      await tester.pumpAndSettle();
      expect(value, isTrue);
    });
  }
}
