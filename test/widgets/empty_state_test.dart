import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/theme.dart';
import 'package:spliit2go/widgets/empty_state.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget body, {double textScale = 1}) async {
    await tester.pumpWidget(MaterialApp(
      theme: spliit2goLightTheme,
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(body: body),
      ),
    ));
  }

  testWidgets('an icon sits in a tile tinted with the soft accent (#179)', (tester) async {
    await pump(tester,
        const EmptyState(icon: Icons.history, title: 'No activity', description: 'Why'));

    final tile = tester.widget<Container>(
        find.ancestor(of: find.byIcon(Icons.history), matching: find.byType(Container)).first);
    expect((tile.decoration! as BoxDecoration).color, SpliitColors.light.brandAccentSoft);
    expect(tester.widget<Icon>(find.byIcon(Icons.history)).color,
        spliit2goLightTheme.colorScheme.primary);
    expect(find.text('No activity'), findsOneWidget);
    expect(find.text('Why'), findsOneWidget);
  });

  testWidgets('the logo form shows the app logo, not an icon tile', (tester) async {
    await pump(tester, const EmptyState.logo(title: 'No groups yet.'));
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(Icon), findsNothing);
  });

  testWidgets('at the largest text the actions can still be scrolled to', (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pump(
      tester,
      EmptyState(
        icon: Icons.search,
        title: 'A title long enough to wrap over several lines',
        description: 'A description that, at this size, runs well past the bottom of the '
            'screen, so the button under it starts out of sight.',
        actions: [FilledButton(onPressed: () {}, child: const Text('Join'))],
      ),
      textScale: 3,
    );

    await tester.ensureVisible(find.text('Join'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Join'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('inside a list, it lays out as a plain column', (tester) async {
    await pump(tester,
        ListView(children: const [EmptyState(icon: Icons.scale, title: 'No expenses yet.')]));
    expect(find.text('No expenses yet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a RefreshIndicator around it can still be pulled', (tester) async {
    var refreshed = false;
    await pump(
      tester,
      RefreshIndicator(
        onRefresh: () async => refreshed = true,
        child: const EmptyState(icon: Icons.receipt, title: 'No expenses yet.'),
      ),
    );
    await tester.fling(find.text('No expenses yet.'), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();
    expect(refreshed, isTrue);
  });
}
