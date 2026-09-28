import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/services/receipt_downloader.dart';
import 'package:spliit2go/widgets/receipt_download_indicator.dart';

// Issue #127: a favorite group's 📎 (Kenneth): blinking while downloading,
// red after an error, solid when done; tapping shows the progress.
void main() {
  late ValueNotifier<ReceiptDownloadStatus> status;
  late int retries;

  Future<void> pump(WidgetTester tester, ReceiptDownloadStatus s) async {
    status = ValueNotifier(s);
    retries = 0;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        appBar: AppBar(actions: [
          ReceiptDownloadIndicator(status: status, onRetry: () => retries++),
        ]),
      ),
    ));
    await tester.pump();
  }

  Icon clip(WidgetTester tester) => tester.widget<Icon>(find.byIcon(Icons.attach_file));

  testWidgets('nothing for a group that isn\'t shown', (tester) async {
    await pump(tester, const ReceiptDownloadStatus());
    expect(find.byIcon(Icons.attach_file), findsNothing);
  });

  testWidgets('solid when done; the progress says all are available offline', (tester) async {
    await pump(tester, const ReceiptDownloadStatus(shown: true, total: 3, available: 3));

    expect(find.byKey(ReceiptDownloadIndicator.blinking), findsNothing);
    expect(clip(tester).color, isNull);
    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pumpAndSettle();
    expect(find.text('All receipts available offline'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('blinking while downloading, with its progress', (tester) async {
    await pump(tester,
        const ReceiptDownloadStatus(shown: true, running: true, total: 40, available: 12));

    expect(find.byKey(ReceiptDownloadIndicator.blinking), findsOneWidget);
    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Downloading receipts: 12 of 40'), findsOneWidget);

    // Done while the progress is open: it follows.
    status.value = const ReceiptDownloadStatus(shown: true, total: 40, available: 40);
    await tester.pump();
    expect(find.text('All receipts available offline'), findsOneWidget);
  });

  testWidgets('red after an error; the progress gives the reason, details and Retry', (tester) async {
    await pump(
        tester,
        const ReceiptDownloadStatus(
            shown: true,
            total: 40,
            available: 38,
            problem: ReceiptDownloadProblem.failed,
            diagnostics: 'Downloading receipt x failed.'));

    expect(clip(tester).color, Theme.of(tester.element(find.byType(Scaffold))).colorScheme.error);
    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pumpAndSettle();
    expect(find.text('38 of 40 receipts available offline'), findsOneWidget);
    expect(find.text("Some receipts couldn't be downloaded."), findsOneWidget);
    expect(find.text('Tap for details'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(retries, 1);
  });

  testWidgets('waiting for Wi-Fi isn\'t an error: dimmed, not red, and it says why', (tester) async {
    await pump(
        tester,
        const ReceiptDownloadStatus(
            shown: true, total: 5, available: 0, problem: ReceiptDownloadProblem.waitingForWifi));

    // Dimmed: not red, and not solid either, since they aren't all here.
    expect(clip(tester).color, Theme.of(tester.element(find.byType(Scaffold))).disabledColor);
    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for Wi-Fi: nothing downloads over mobile data.'), findsOneWidget);
    expect(find.text('Tap for details'), findsNothing);
  });

  testWidgets('not enough space says what to do', (tester) async {
    await pump(
        tester,
        const ReceiptDownloadStatus(
            shown: true, total: 5, available: 2, problem: ReceiptDownloadProblem.noSpace));

    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pumpAndSettle();
    expect(find.textContaining('raise the receipt storage limit'), findsOneWidget);
  });

  // #144 review (Ezra): the counts adding up isn't enough after a check
  // that stopped short.
  testWidgets('all counted but the last check failed: red, "may be out of date", Retry',
      (tester) async {
    await pump(
        tester,
        const ReceiptDownloadStatus(
            shown: true,
            total: 3,
            available: 3,
            problem: ReceiptDownloadProblem.failed,
            diagnostics: 'Reading receipts of expense e1 failed.'));

    expect(clip(tester).color, Theme.of(tester.element(find.byType(Scaffold))).colorScheme.error);
    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pumpAndSettle();
    expect(find.text('Receipts may be out of date'), findsOneWidget);
    expect(find.text('All receipts available offline'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
  });
}
