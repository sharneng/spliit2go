import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/services/receipt_downloader.dart';
import 'package:spliit2go/widgets/caption_icon.dart';
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

  Icon clip(WidgetTester tester) => tester.widget<Icon>(find.byIcon(LucideIcons.paperclip));

  testWidgets('nothing for a group that isn\'t shown', (tester) async {
    await pump(tester, const ReceiptDownloadStatus());
    expect(find.byIcon(LucideIcons.paperclip), findsNothing);
  });

  testWidgets('solid when done; the progress says all are available offline', (tester) async {
    await pump(tester, const ReceiptDownloadStatus(shown: true, total: 3, available: 3));

    expect(find.byKey(ReceiptDownloadIndicator.blinking), findsNothing);
    expect(clip(tester).color, isNull);
    await tester.tap(find.byIcon(LucideIcons.paperclip));
    await tester.pumpAndSettle();
    expect(find.text('All receipts available offline'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('blinking while downloading, with its progress', (tester) async {
    await pump(tester,
        const ReceiptDownloadStatus(shown: true, running: true, total: 40, available: 12));

    expect(find.byKey(ReceiptDownloadIndicator.blinking), findsOneWidget);
    await tester.tap(find.byIcon(LucideIcons.paperclip));
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
    await tester.tap(find.byIcon(LucideIcons.paperclip));
    await tester.pumpAndSettle();
    expect(find.text('38 of 40 receipts available offline'), findsOneWidget);
    expect(find.text("Some receipts couldn't be downloaded."), findsOneWidget);
    expect(find.text('Tap for details'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(retries, 1);
  });

  testWidgets('waiting for Wi-Fi isn\'t an error: struck through, not red, and it says why',
      (tester) async {
    await pump(
        tester,
        const ReceiptDownloadStatus(
            shown: true, total: 5, available: 0, problem: ReceiptDownloadProblem.waitingForWifi));

    // Struck through: not red, and not plain either, since they aren't all here.
    expect(clip(tester).color,
        isNot(Theme.of(tester.element(find.byType(Scaffold))).colorScheme.error));
    expect(find.byKey(ReceiptDownloadIndicator.struckThrough), findsOneWidget);
    await tester.tap(find.byIcon(LucideIcons.paperclip));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for Wi-Fi: nothing downloads over mobile data.'), findsOneWidget);
    expect(find.text('Tap for details'), findsNothing);
  });

  testWidgets('not enough space says what to do', (tester) async {
    await pump(
        tester,
        const ReceiptDownloadStatus(
            shown: true, total: 5, available: 2, problem: ReceiptDownloadProblem.noSpace));

    await tester.tap(find.byIcon(LucideIcons.paperclip));
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
    await tester.tap(find.byIcon(LucideIcons.paperclip));
    await tester.pumpAndSettle();
    expect(find.text('Receipts may be out of date'), findsOneWidget);
    expect(find.text('All receipts available offline'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
  });

  // #209: the state is said, not only shown by color.
  testWidgets('a screen reader hears the state after the name', (tester) async {
    await pump(tester,
        const ReceiptDownloadStatus(
            shown: true, total: 5, available: 2, problem: ReceiptDownloadProblem.waitingForWifi));
    final data = tester.getSemantics(find.byType(IconButton)).getSemanticsData();
    expect(data.tooltip, 'Receipts offline');
    expect(data.value,
        '2 of 5 receipts available offline. Waiting for Wi-Fi: nothing downloads over mobile data.');
  });

  group('in a group row (#209)', () {
    late ReceiptRowClip clip;

    Future<void> pumpRow(WidgetTester tester, ReceiptDownloadStatus s,
        {double scale = 1, double maxRowSize = double.infinity}) async {
      status = ValueNotifier(s);
      retries = 0;
      clip = ReceiptRowClip();
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery.withClampedTextScaling(
          minScaleFactor: scale,
          maxScaleFactor: scale,
          child: Scaffold(
            body: Stack(children: [
              ListTile(
                title: Row(children: [
                  const Expanded(child: Text('Banff Trip')),
                  ReceiptDownloadIndicator(
                      row: clip,
                      status: status,
                      onRetry: () => retries++,
                      maxRowSize: maxRowSize),
                ]),
                subtitle: const Text('Sep 16, 2026'),
              ),
              Positioned(
                  top: 0,
                  left: 0,
                  child: ReceiptDownloadTapArea(
                      row: clip, status: status, onRetry: () => retries++)),
            ]),
          ),
        ),
      ));
      await tester.pump();
    }

    const done = ReceiptDownloadStatus(shown: true, total: 3, available: 3);

    testWidgets('a target a margin past the clip, centered on it, the row no taller',
        (tester) async {
      await pumpRow(tester, done);
      final clipBox = tester.getRect(find.byIcon(LucideIcons.paperclip));
      final target = tester.getRect(find.byType(InkResponse));
      expect(target.size,
          const Size.square(titleMarkBaseSize + 2 * ReceiptDownloadTapArea.margin));
      expect((target.center - clipBox.center).distance, lessThan(0.01));
      expect(tester.getSize(find.byType(ListTile)).height, 72);

      // A tap past the clip's own box, inside the margin.
      await tester.tapAt(clipBox.bottomCenter + const Offset(0, ReceiptDownloadTapArea.margin - 2));
      await tester.pumpAndSettle();
      expect(find.text('All receipts available offline'), findsOneWidget);
    });

    testWidgets('a tap past the margin isn\'t the clip\'s', (tester) async {
      await pumpRow(tester, done);
      final clipBox = tester.getRect(find.byIcon(LucideIcons.paperclip));
      await tester.tapAt(clipBox.bottomCenter + const Offset(0, ReceiptDownloadTapArea.margin + 4));
      await tester.pumpAndSettle();
      expect(find.text('All receipts available offline'), findsNothing);
    });

    testWidgets('the target grows with the text size', (tester) async {
      await pumpRow(tester, done, scale: 2);
      expect(tester.getSize(find.byType(InkResponse)),
          const Size.square(titleMarkBaseSize * 2 + 2 * ReceiptDownloadTapArea.margin));
    });

    // #212 review (Ezra): a clip capped to leave the name room keeps a
    // target its own size, not the text size's.
    testWidgets('a capped clip\'s target is the capped clip plus the margin', (tester) async {
      await pumpRow(tester, done, scale: 3, maxRowSize: 5);
      final clipBox = tester.getRect(find.byIcon(LucideIcons.paperclip));
      expect(clipBox.width, titleMarkBaseSize);
      final target = tester.getRect(find.byType(InkResponse));
      expect(target.size, const Size.square(titleMarkBaseSize + 2 * ReceiptDownloadTapArea.margin));
      expect((target.center - clipBox.center).distance, lessThan(0.01));

      await tester.tapAt(clipBox.centerLeft - const Offset(ReceiptDownloadTapArea.margin + 4, 0));
      await tester.pumpAndSettle();
      expect(find.text('All receipts available offline'), findsNothing);
    });

    testWidgets('one button for a screen reader, with the state', (tester) async {
      await pumpRow(tester, done);
      final data = tester.getSemantics(find.byType(InkResponse)).getSemanticsData();
      expect(data.label, 'Receipts offline');
      expect(data.value, 'All receipts available offline.');
      expect(data.flagsCollection.isButton, isTrue);
    });

    testWidgets('the expense rows\' marks\' size, growing and shrinking with the text',
        (tester) async {
      await pumpRow(tester, done);
      final normal = tester.getSize(find.byIcon(LucideIcons.paperclip)).width;
      expect(normal, titleMarkBaseSize);
      await pumpRow(tester, done, scale: 0.8);
      expect(tester.getSize(find.byIcon(LucideIcons.paperclip)).width, closeTo(normal * 0.8, 0.01));
      await pumpRow(tester, done, scale: 2);
      expect(tester.getSize(find.byIcon(LucideIcons.paperclip)).width, closeTo(normal * 2, 0.01));
    });

    testWidgets('grows only as far as the title leaves room, never below its usual size',
        (tester) async {
      await pumpRow(tester, done);
      final normal = tester.getSize(find.byIcon(LucideIcons.paperclip)).width;
      await pumpRow(tester, done, scale: 3, maxRowSize: 30);
      expect(tester.getSize(find.byIcon(LucideIcons.paperclip)).width, 30);
      await pumpRow(tester, done, scale: 3, maxRowSize: 5);
      expect(tester.getSize(find.byIcon(LucideIcons.paperclip)).width, closeTo(normal, 0.01));
    });

    testWidgets('nothing to tap while the clip isn\'t shown', (tester) async {
      await pumpRow(tester, const ReceiptDownloadStatus());
      expect(find.byType(InkResponse), findsNothing);
    });
  });
}
