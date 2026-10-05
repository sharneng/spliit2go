import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/main.dart';
import 'package:spliit2go/theme.dart';
import 'package:spliit2go/widgets/bottom_inset_fill.dart';

// #186 review: a screen whose bottom isn't the plain background continues
// into the strip behind the home indicator / Android's nav bar, which the
// app's SafeArea otherwise leaves in the backdrop's color.
void main() {
  const inset = 34.0;
  const color = Color(0xffff0000);

  Future<void> pump(WidgetTester tester, Widget home, {double bottom = inset}) async {
    tester.view.padding = FakeViewPadding(bottom: bottom * tester.view.devicePixelRatio);
    tester.view.viewPadding = FakeViewPadding(bottom: bottom * tester.view.devicePixelRatio);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: spliit2goLightTheme,
      builder: spliit2goAppBuilder,
      home: home,
    ));
  }

  RenderObject fill(WidgetTester tester) => tester.renderObject(
      find.descendant(of: find.byType(BottomInsetFill), matching: find.byType(CustomPaint)));

  testWidgets('the app passes the inset its SafeArea takes away down to screens', (tester) async {
    late double seen;
    await pump(tester, Builder(builder: (context) {
      seen = AppBottomInset.of(context);
      return const SizedBox();
    }));
    expect(seen, inset);
  });

  testWidgets("a screen's fill covers the strip under it, full width", (tester) async {
    await pump(tester, const Scaffold(bottomNavigationBar: BottomInsetFill.bar(color: color)));
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final box = fill(tester) as RenderBox;
    // The bar takes no space; the strip starts where the screen ends.
    expect(box.size.height, 0);
    expect(box.localToGlobal(Offset.zero).dy,
        tester.view.physicalSize.height / tester.view.devicePixelRatio - inset);
    expect(fill(tester), paints..rect(rect: Rect.fromLTWH(0, 0, width, inset), color: color));
  });

  testWidgets('no inset, nothing painted', (tester) async {
    await pump(tester, const Scaffold(bottomNavigationBar: BottomInsetFill.bar(color: color)),
        bottom: 0);
    expect(fill(tester), paintsNothing);
  });
}
