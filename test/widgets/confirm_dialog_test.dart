import 'package:flutter/cupertino.dart' show CupertinoAlertDialog, CupertinoDialogAction;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/widgets/confirm_dialog.dart';

// #276: every alert in the app, in the style settled on for #272's.
void main() {
  /// Opens a dialog on [platform]; returns what it answered.
  Future<List<bool>> open(WidgetTester tester, TargetPlatform platform,
      {List<String> message = const ['First.', 'Second.'], String? action = 'Remove', bool destructive = true,
      String? cancel}) async {
    final answers = <bool>[];
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: platform),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => answers.add(await showConfirmDialog(context,
              title: 'Remove it?', message: message, action: action, destructive: destructive, cancel: cancel)),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return answers;
  }

  TextStyle? styleOf(WidgetTester tester, String text) => tester.widget<Text>(find.text(text)).style;

  group('on an iPhone', () {
    testWidgets('the system\'s buttons: Cancel semibold, a destructive action red', (tester) async {
      final answers = await open(tester, TargetPlatform.iOS);
      final actions = tester.widgetList<CupertinoDialogAction>(find.byType(CupertinoDialogAction)).toList();
      expect(actions.map((a) => (a.isDefaultAction, a.isDestructiveAction)), [(true, false), (false, true)]);
      expect(find.descendant(of: find.byType(CupertinoAlertDialog), matching: find.byType(TextButton)), findsNothing);

      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(answers, [true]);
    });

    testWidgets('the message: 15pt paragraphs, left-aligned, in the primary text color', (tester) async {
      await open(tester, TargetPlatform.iOS);
      final context = tester.element(find.text('First.'));
      for (final paragraph in ['First.', 'Second.']) {
        expect(styleOf(tester, paragraph)?.fontSize, 15);
        expect(styleOf(tester, paragraph)?.color, Theme.of(context).colorScheme.onSurface);
        expect(tester.widget<Text>(find.text(paragraph)).textAlign, TextAlign.start);
      }
      // A gap above each.
      expect(tester.getTopLeft(find.text('Second.')).dy - tester.getBottomLeft(find.text('First.')).dy, 8);
    });

    testWidgets('one that only tells has a lone OK, semibold', (tester) async {
      final answers = await open(tester, TargetPlatform.iOS, message: const [], action: null, cancel: 'OK');
      final action = tester.widget<CupertinoDialogAction>(find.byType(CupertinoDialogAction));
      expect(action.isDefaultAction, isTrue);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(answers, [false]);
    });
  });

  group('on Android', () {
    testWidgets('Material\'s buttons, a destructive action in the error color; Cancel answers false',
        (tester) async {
      final answers = await open(tester, TargetPlatform.android);
      expect(find.byType(CupertinoDialogAction), findsNothing);
      final remove = tester.widget<TextButton>(find.widgetWithText(TextButton, 'Remove'));
      final context = tester.element(find.text('Remove'));
      expect(remove.style?.foregroundColor?.resolve({}), Theme.of(context).colorScheme.error);
      // Material's message size, not the iPhone's 15pt.
      expect(styleOf(tester, 'First.')?.fontSize, isNull);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(answers, [false]);
    });

    testWidgets('an action that isn\'t destructive keeps the button color', (tester) async {
      await open(tester, TargetPlatform.android, destructive: false);
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Remove')).style, isNull);
    });
  });
}
