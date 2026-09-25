import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/services/error_reporting.dart';
import 'package:spliit2go/widgets/error_message.dart';

// Issue #118, #119 review: the presentation side of the error policy.
void main() {
  Widget app(Widget home, {GlobalKey<NavigatorState>? navigatorKey, ErrorReporter? reporter}) =>
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        navigatorKey: navigatorKey,
        builder: reporter == null
            ? null
            : (context, child) => UncaughtErrorPresenter(
                reporter: reporter, navigatorKey: navigatorKey!, child: child!),
        home: Scaffold(body: Center(child: home)),
      );

  testWidgets('without diagnostics: just the message, selectable, nothing to tap', (tester) async {
    await tester.pumpWidget(app(const ErrorMessage('No group with that link.')));

    expect(find.widgetWithText(SelectableText, 'No group with that link.'), findsOneWidget);
    expect(find.text('Tap for details'), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('with diagnostics: a tap shows message and diagnostics; Copy copies them', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(app(const ErrorMessage("Couldn't join the group.",
        diagnostics: 'Joining x failed.\n\nBad state: boom\n\n#0 main (x.dart:1)')));
    await tester.tap(find.text('Tap for details'));
    await tester.pumpAndSettle();

    final shown = tester.widget<SelectableText>(find.byType(SelectableText)).data!;
    expect(shown, startsWith("Couldn't join the group."));
    expect(shown, contains('Bad state: boom'));
    expect(shown, contains('#0 main (x.dart:1)'));
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, shown);
  });

  testWidgets('a snack bar error offers Details only when there are diagnostics', (tester) async {
    await tester.pumpWidget(app(Builder(
      builder: (context) => Column(mainAxisSize: MainAxisSize.min, children: [
        TextButton(
            onPressed: () => showErrorSnackBar(context, 'Could not save.'),
            child: const Text('plain')),
        TextButton(
            onPressed: () => showErrorSnackBar(context, 'Could not save.', diagnostics: 'disk full'),
            child: const Text('unexpected')),
      ]),
    )));

    await tester.tap(find.text('plain'));
    await tester.pump();
    expect(find.text('Could not save.'), findsOneWidget);
    expect(find.text('Details'), findsNothing);

    ScaffoldMessenger.of(tester.element(find.text('plain'))).clearSnackBars();
    await tester.pumpAndSettle();
    await tester.tap(find.text('unexpected'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.textContaining('disk full'), findsOneWidget);
  });

  testWidgets('an uncaught error shows after the frame as a snack bar, with Details', (tester) async {
    final reporter = ErrorReporter();
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(app(const Text('home'), navigatorKey: navigatorKey, reporter: reporter));

    reporter.reportUncaught(StateError('nobody caught me'), StackTrace.current,
        operation: 'Unhandled async error');
    expect(find.text('Something went wrong.'), findsNothing); // not mid-frame
    await tester.pump();
    await tester.pump();
    expect(find.text('Something went wrong.'), findsOneWidget);

    await tester.pumpAndSettle();
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('Error details'), findsOneWidget);
    expect(find.textContaining('nobody caught me'), findsOneWidget);
  });
}
