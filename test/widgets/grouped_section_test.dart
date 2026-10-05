import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/theme.dart';
import 'package:spliit2go/widgets/grouped_section.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget section, {ThemeData? theme}) async {
    await tester.pumpWidget(MaterialApp(
      theme: theme ?? spliit2goLightTheme,
      home: Scaffold(body: ListView(children: [section])),
    ));
  }

  testWidgets('a hairline between each two rows, none before or after (#180)', (tester) async {
    await pump(
      tester,
      const GroupedSection(caption: 'Theme', children: [
        GroupedRow(title: Text('Light')),
        GroupedRow(title: Text('Dark')),
        GroupedRow(title: Text('System')),
      ]),
    );
    expect(find.byType(GroupedDivider), findsNWidgets(2));
    expect(find.text('Theme'), findsOneWidget);
    expect(find.bySemanticsLabel('Theme'), findsOneWidget);
  });

  testWidgets('the hairlines start where the section says', (tester) async {
    await pump(
      tester,
      const GroupedSection(dividerIndent: 56, children: [
        GroupedRow(leading: Icon(Icons.today), title: Text('Date')),
        GroupedRow(leading: Icon(Icons.person), title: Text('Paid by')),
      ]),
    );
    expect(tester.widget<Divider>(find.byType(Divider)).indent, 56);
  });

  testWidgets('a row that opens a screen has a chevron, on Android and iOS', (tester) async {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      await pump(
        tester,
        GroupedSection(children: [
          GroupedRow(title: const Text('About'), navigates: true, onTap: () {}),
          GroupedRow(title: const Text('Plain'), onTap: () {}),
        ]),
        theme: spliit2goLightTheme.copyWith(platform: platform),
      );
      expect(find.byIcon(Icons.chevron_right), findsOneWidget, reason: '$platform');
    }
  });

  testWidgets("a row's own trailing replaces the chevron", (tester) async {
    await pump(
      tester,
      const GroupedSection(children: [
        GroupedRow(title: Text('English'), navigates: true, trailing: Icon(Icons.check)),
      ]),
    );
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('cards stand off the page in light and dark', (tester) async {
    for (final theme in [spliit2goLightTheme, spliit2goDarkTheme]) {
      await pump(tester, const GroupedSection(children: [GroupedRow(title: Text('Row'))]),
          theme: theme);
      final context = tester.element(find.text('Row'));
      expect(GroupedSection.cardColor(context), isNot(GroupedSection.backgroundColor(context)));
    }
  });

  testWidgets("a caption's trailing goes under it when both don't fit (#183 review)",
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: spliit2goLightTheme,
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: Scaffold(
          body: ListView(children: const [
            GroupedSection(
              caption: 'Payé pour',
              captionTrailing: Text('Pourcentage'),
              children: [GroupedRow(title: Text('Alex'))],
            ),
          ]),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(find.text('Pourcentage')).dy,
        greaterThan(tester.getBottomLeft(find.text('Payé pour')).dy - 1));
  });
}
