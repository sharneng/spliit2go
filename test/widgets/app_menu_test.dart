import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/theme.dart';
import 'package:spliit2go/widgets/app_menu.dart';
import 'package:spliit2go/widgets/grouped_section.dart';

// #217: one popup menu on every platform, styled after One UI's.
void main() {
  Future<void> open(WidgetTester tester, List<AppMenuItem> items,
      {ThemeData? theme, TargetPlatform platform = TargetPlatform.android}) async {
    await tester.pumpWidget(MaterialApp(
      theme: (theme ?? spliit2goLightTheme).copyWith(platform: platform),
      home: Scaffold(
          appBar: AppBar(actions: [
        AppMenuButton(icon: const Icon(Icons.sort), tooltip: 'Menu', items: items),
      ])),
    ));
    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();
  }

  List<AppMenuItem> sorts(void Function(String) picked) => [
        for (final (label, checked) in [('First', false), ('Second', true), ('Third', false)])
          AppMenuItem(label: label, checked: checked, onSelected: () => picked(label)),
      ];

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('a pick-one menu leads with the check, its labels lined up, on ${platform.name}',
        (tester) async {
      String? picked;
      await open(tester, sorts((label) => picked = label), platform: platform);
      expect(find.byType(PopupMenuItem<int>), findsNWidgets(3));
      final check = tester.getRect(find.byIcon(Icons.check));
      final second = tester.getRect(find.text('Second'));
      expect(check.right, lessThan(second.left));
      expect(check.center.dy, closeTo(second.center.dy, 1));
      expect(tester.getTopLeft(find.text('First')).dx, second.left);
      expect(tester.getTopLeft(find.text('Third')).dx, second.left);
      expect(tester.widget<Icon>(find.byIcon(Icons.check)).color,
          spliit2goLightTheme.colorScheme.primary);

      await tester.tap(find.text('Third'));
      await tester.pumpAndSettle();
      expect(picked, 'Third');
    });
  }

  testWidgets('an icon leads its label; a destructive row is red; rows are 40 tall', (tester) async {
    await open(tester, [
      AppMenuItem(label: 'Share', icon: Icons.share, onSelected: () {}),
      AppMenuItem(label: 'Remove', icon: Icons.delete, destructive: true, onSelected: () {}),
    ]);
    expect(tester.getRect(find.byIcon(Icons.share)).right,
        lessThan(tester.getRect(find.text('Share')).left));
    final red = spliit2goLightTheme.colorScheme.error;
    expect(tester.widget<Icon>(find.byIcon(Icons.delete)).color, red);
    expect(tester.widget<Text>(find.text('Remove')).style!.color, red);
    expect(tester.widget<PopupMenuItem<int>>(find.byType(PopupMenuItem<int>).first).height, 40);
  });

  test('menus: the page color in light mode, the card color in dark, with a hairline edge', () {
    final light = spliit2goLightTheme.popupMenuTheme;
    expect(light.color, spliit2goLightTheme.scaffoldBackgroundColor);
    final dark = spliit2goDarkTheme.popupMenuTheme;
    expect(dark.color, GroupedSection.cardColorOf(spliit2goDarkTheme.colorScheme));
    final edge = (dark.shape! as RoundedRectangleBorder).side;
    expect(edge.width, 0.5);
    expect(edge.color, Color.lerp(dark.color, GroupedDivider.darkColor, 0.5));
    expect(light.position, PopupMenuPosition.under);
  });

  test("dark mode's red is the amount red", () {
    expect(spliit2goDarkTheme.colorScheme.error, SpliitColors.dark.moneyNegative);
  });
}
