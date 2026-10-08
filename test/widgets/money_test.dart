import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/theme.dart';
import 'package:spliit2go/widgets/money.dart';

void main() {
  Future<TextStyle> styleOf(WidgetTester tester, Money money,
      {ThemeData? theme}) async {
    await tester.pumpWidget(MaterialApp(
      theme: theme ?? spliit2goLightTheme,
      home: Scaffold(body: money),
    ));
    // MaterialApp animates between themes.
    await tester.pumpAndSettle();
    return tester.widget<Text>(find.text(money.value)).style!;
  }

  testWidgets('tabular, semibold and uncolored by default (#178)', (tester) async {
    final style = await styleOf(tester, const Money('\$12.34'));
    expect(style.fontFeatures, contains(const FontFeature.tabularFigures()));
    expect(style.fontWeight, FontWeight.w600);
    expect(style.fontStyle, isNot(FontStyle.italic));
    expect(style.color, spliit2goLightTheme.textTheme.bodyLarge!.color);
    // A step tighter than the row titles around it.
    expect(style.letterSpacing, -0.4);
  });

  testWidgets('sizes come from the text theme, so they follow text scaling',
      (tester) async {
    // The theme as widgets see it, with the type scale's sizes merged in.
    await tester.pumpWidget(MaterialApp(theme: spliit2goLightTheme, home: const SizedBox()));
    final text = Theme.of(tester.element(find.byType(SizedBox))).textTheme;
    for (final (size, expected) in [
      (MoneySize.hero, text.headlineMedium),
      (MoneySize.lead, text.titleLarge),
      (MoneySize.row, text.bodyLarge),
      (MoneySize.support, text.bodySmall),
    ]) {
      final style = await styleOf(tester, Money('\$1.00', size: size));
      expect(style.fontSize, expected!.fontSize, reason: '$size');
    }
  });

  testWidgets('a balance is colored by its direction, in light and dark',
      (tester) async {
    for (final (theme, colors) in [
      (spliit2goLightTheme, SpliitColors.light),
      (spliit2goDarkTheme, SpliitColors.dark),
    ]) {
      expect((await styleOf(tester, Money('\$5.00', sign: MoneySign.ofBalance(500)),
                  theme: theme))
              .color,
          colors.moneyPositive);
      expect((await styleOf(tester, Money('-\$5.00', sign: MoneySign.ofBalance(-500)),
                  theme: theme))
              .color,
          colors.moneyNegative);
      expect((await styleOf(tester, Money('\$0.00', sign: MoneySign.ofBalance(0)),
                  theme: theme))
              .color,
          theme.colorScheme.onSurfaceVariant);
    }
  });

  testWidgets('a reimbursement reads as an aside: regular and italic', (tester) async {
    final style =
        await styleOf(tester, const Money('\$8.00', isReimbursement: true));
    expect(style.fontWeight, FontWeight.w400);
    expect(style.fontStyle, FontStyle.italic);
  });

  testWidgets('in a stretched column it keeps its own width, at the start (#179)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: spliit2goLightTheme,
      home: const Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [Money('\$100.00', size: MoneySize.hero)],
        ),
      ),
    ));
    expect(tester.getTopLeft(find.text('\$100.00')).dx, 0);
  });

  testWidgets('a changed amount fades to its new value, then only the new one is left',
      (tester) async {
    Future<void> show(String value) => tester.pumpWidget(MaterialApp(
          theme: spliit2goLightTheme,
          home: Scaffold(body: Money(value)),
        ));
    await show('\$1.00');
    await show('\$2.00');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('\$1.00'), findsOneWidget); // still fading out
    await tester.pumpAndSettle();
    expect(find.text('\$1.00'), findsNothing);
    expect(find.text('\$2.00'), findsOneWidget);
  });
}
