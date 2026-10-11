import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/models/currency.dart';
import 'package:spliit2go/widgets/currency_picker.dart';

// #279: the search sheet opens with the keyboard up, and must stay on
// the screen.
void main() {
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => pickCurrency(context, currencies: supportedCurrencies),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  void phone(WidgetTester tester, {double keyboard = 0}) {
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding(top: 47)
      ..viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
  }

  testWidgets('with the keyboard up, its top stays below the status bar', (tester) async {
    phone(tester, keyboard: 336);
    await open(tester);
    final search = tester.getTopLeft(find.byType(TextField));
    // 75% of 800 above a 336pt keyboard would start at -136.
    expect(search.dy, greaterThan(47));
    // And it still fills the room there is, less a gap that shows it's a sheet.
    expect(search.dy, lessThan(47 + 24 + 32));
  });

  testWidgets('without the keyboard, it\'s three quarters of the screen', (tester) async {
    phone(tester);
    await open(tester);
    expect(tester.getTopLeft(find.byType(TextField)).dy, closeTo(800 * 0.25 + 16, 1));
  });
}
