import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/theme.dart';
import 'package:spliit2go/widgets/top_bar_buttons.dart';

// #228: top bar buttons on a card, as iOS 26's toolbars.
void main() {
  const width = 400.0;

  Future<void> pumpBar(WidgetTester tester, List<Widget> buttons,
      {TargetPlatform platform = TargetPlatform.iOS, ThemeData? base}) async {
    tester.view.physicalSize = const Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = (base ?? spliit2goLightTheme).copyWith(platform: platform);
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: const Scaffold(body: Text('first')),
    ));
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Second'), actions: [TopBarButtons(children: buttons)]),
      ),
    ));
    await tester.pumpAndSettle();
  }

  // The card around [inside]: lifted, unlike the IconButtons' own
  // capsule-shaped Material, which can sit inside or around it.
  Finder card(Finder inside) => find.ancestor(
      of: inside,
      matching: find.byWidgetPredicate(
          (w) => w is Material && w.shape is StadiumBorder && (w.elevation) > 0));
  Rect cardOf(WidgetTester tester, Finder inside) => tester.getRect(card(inside));

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('one button in a 44pt circle, 16 from the edge; back in the same circle (${platform.name})',
        (tester) async {
      await pumpBar(tester, [IconButton(icon: const Icon(Icons.more_horiz), onPressed: () {})],
          platform: platform);
      final more = cardOf(tester, find.byIcon(Icons.more_horiz));
      expect(more.size, const Size.square(44));
      expect(width - more.right, 16);

      final chevron = platform == TargetPlatform.iOS ? Icons.arrow_back_ios_new_rounded : Icons.arrow_back;
      final back = cardOf(tester, find.byIcon(chevron));
      expect(back.size, const Size.square(44), reason: 'not squashed by the back button\'s padding');
      expect(back.left, 16);
      expect(back.center.dy, more.center.dy);
      expect(tester.getCenter(find.byIcon(chevron)), back.center);

      expect(tester.widget<Material>(card(find.byIcon(Icons.more_horiz))).elevation, 1,
          reason: 'a hint of lift, lighter than the tab bar');
    });
  }

  testWidgets('several buttons share one capsule', (tester) async {
    await pumpBar(tester, [
      IconButton(icon: const Icon(Icons.sort), onPressed: () {}),
      IconButton(icon: const Icon(Icons.settings), onPressed: () {}),
    ]);
    final capsule = cardOf(tester, find.byIcon(Icons.sort));
    expect(cardOf(tester, find.byIcon(Icons.settings)), capsule);
    expect(capsule.size, const Size(88, 44));
    expect(width - capsule.right, 16);
  });

  testWidgets('a hairline lighter edge in dark, where a shadow can\'t show; none in light (#239)',
      (tester) async {
    BorderSide edge() =>
        (tester.widget<Material>(card(find.byIcon(Icons.more_horiz))).shape! as StadiumBorder).side;
    final more = [IconButton(icon: const Icon(Icons.more_horiz), onPressed: () {})];
    await pumpBar(tester, more);
    expect(edge(), BorderSide.none);
    await pumpBar(tester, more, base: spliit2goDarkTheme);
    expect(edge().width, 0.5);
  });
}
