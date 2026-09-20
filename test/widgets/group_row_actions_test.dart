import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/l10n/context_l10n.dart';
import 'package:spliit2go/widgets/group_row_actions.dart';

void main() {
  for (final locale in [
    const Locale('en'),
    const Locale('fr'),
    const Locale('zh')
  ]) {
    for (final edge in ['topLeft', 'bottomRight']) {
      testWidgets('anchored menu fits $edge at large text in $locale',
          (tester) async {
        tester.view.physicalSize = const Size(320, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var selected = false;
        await tester.pumpWidget(MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!),
            home: Scaffold(
                body: Builder(
                    builder: (context) => Align(
                          alignment: edge == 'topLeft'
                              ? Alignment.topCenter
                              : Alignment.bottomCenter,
                          child: GroupRowActions(
                              actions: [
                                GroupRowAction(
                                    label: context.l10n.groupListUnfavorite,
                                    icon: Icons.star_border,
                                    onSelected: () => selected = true),
                                GroupRowAction(
                                    label: context.l10n.groupListUnarchive,
                                    icon: Icons.unarchive,
                                    onSelected: () {}),
                                GroupRowAction(
                                    label: context.l10n.groupListRemove,
                                    icon: Icons.delete,
                                    destructive: true,
                                    onSelected: () {}),
                              ],
                              builder: (context, openMenu) => GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onLongPress: openMenu,
                                  child: const SizedBox(
                                      width: 320,
                                      height: 80,
                                      child: Text('Group')))),
                        )))));
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
            edge == 'topLeft' ? const Offset(10, 20) : const Offset(310, 580));
        await tester.pump(const Duration(milliseconds: 600));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.byType(PopupMenuItem<int>), findsNWidgets(3));
        final first = tester.getRect(find.byType(PopupMenuItem<int>).first);
        final last = tester.getRect(find.byType(PopupMenuItem<int>).last);
        expect(first.left, greaterThanOrEqualTo(0));
        expect(first.right, lessThanOrEqualTo(320));
        expect(first.top, greaterThanOrEqualTo(0));
        expect(last.bottom, lessThanOrEqualTo(600));
        if (edge == 'topLeft') expect(first.top, lessThan(100));
        if (edge == 'bottomRight') expect(last.bottom, greaterThan(400));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byType(PopupMenuItem<int>).first);
        await tester.pumpAndSettle();
        expect(selected, isTrue);
        // Revealed controls must also fit narrow rows with enlarged labels.
        await tester.drag(find.text('Group'), const Offset(-250, 0));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
