import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/widgets/bottom_inset.dart';

void main() {
  testWidgets('adds the bottom safe-area inset to the padding (#197)', (tester) async {
    late EdgeInsets padding;
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(padding: EdgeInsets.only(top: 50, bottom: 34)),
      child: Builder(builder: (context) {
        padding = withBottomInset(context, const EdgeInsets.only(top: 16, bottom: 88));
        return const SizedBox();
      }),
    ));
    expect(padding, const EdgeInsets.only(top: 16, bottom: 88 + 34));
  });

  group('a screen\'s body ends above the system\'s bottom bar, as the group list', () {
    Future<(Rect, double)> body(WidgetTester tester, double inset, {TargetPlatform platform = TargetPlatform.android}) async {
      late double childInset;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: platform),
        home: MediaQuery(
          data: MediaQueryData(size: const Size(800, 600), padding: EdgeInsets.only(bottom: inset)),
          child: AboveBottomBar(
            child: Builder(builder: (context) {
              childInset = MediaQuery.paddingOf(context).bottom;
              return const SizedBox.expand(key: Key('body'));
            }),
          ),
        ),
      ));
      return (tester.getRect(find.byKey(const Key('body'))), childInset);
    }

    testWidgets('Android\'s buttons: above them, and the body doesn\'t pad for them again', (tester) async {
      final (rect, childInset) = await body(tester, 48);
      expect(rect.bottom, 600 - 48);
      expect(childInset, 0);
    });

    testWidgets('an iPhone\'s home indicator: where the group screen\'s tab bar ends', (tester) async {
      final (rect, _) = await body(tester, 34, platform: TargetPlatform.iOS);
      expect(rect.bottom, 600 - (34 - 14));
    });

    testWidgets('no bar (or the keyboard up): to the edge', (tester) async {
      final (rect, _) = await body(tester, 0);
      expect(rect.bottom, 600);
    });
  });
}
