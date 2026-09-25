import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/widgets/error_message.dart';

// Issue #118: a short error on screen, with the full error and stack trace
// a tap away, copyable, so a problem seen on a phone can be reported.
void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: child)),
      ));

  testWidgets('without details it is just the message', (tester) async {
    await pump(tester, const ErrorMessage('Group name is required.'));

    expect(find.text('Group name is required.'), findsOneWidget);
    expect(find.text('Tap for details'), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('with details a tap shows the message, error and stack trace; Copy copies them all',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    final details = ErrorDetails(StateError('boom'), StackTrace.fromString('#0 main (x.dart:1)'));
    await pump(tester, ErrorMessage('Couldn’t join.', details: details));

    await tester.tap(find.text('Tap for details'));
    await tester.pumpAndSettle();

    expect(find.text('Error details'), findsOneWidget);
    final shown = tester.widget<SelectableText>(find.byType(SelectableText)).data!;
    expect(shown, contains('Couldn’t join.'));
    expect(shown, contains('Bad state: boom'));
    expect(shown, contains('#0 main (x.dart:1)'));

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, shown);
    expect(find.text('Copied'), findsOneWidget);
  });

  test('ErrorDetails.logged writes the error and trace to the debug log', () {
    final lines = <String?>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add(message);
    addTearDown(() => debugPrint = original);

    ErrorDetails.logged('Joining x', StateError('boom'), StackTrace.fromString('#0 f'));

    expect(lines.single, contains('Joining x failed: Bad state: boom'));
    expect(lines.single, contains('#0 f'));
  });
}
