import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/l10n/context_l10n.dart';
import 'package:spliit2go/widgets/group_row_actions.dart';

void main() {
  for (final direction in [-1.0, 1.0]) {
    for (final reverse in [false, true]) {
      testWidgets(
          'halfway swipe $direction reverses=$reverse with boundary haptics',
          (tester) async {
        final haptics = <MethodCall>[];
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') haptics.add(call);
          return null;
        });
        addTearDown(() => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null));
        final actions = <int>[];
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
              width: 320,
              child: GroupRowActions(
                actions: [
                  for (var i = 0; i < 3; i++)
                    GroupRowAction(
                        label: ['Favorite', 'Archive', 'Remove'][i],
                        icon: Icons.star,
                        onSelected: () => actions.add(i))
                ],
                builder: (_, __) =>
                    const SizedBox(height: 80, child: Text('Row')),
              )),
        ))));
        final gesture = await tester.startGesture(const Offset(160, 40));
        await gesture.moveBy(Offset(direction * 25, 0));
        await tester.pump();
        await gesture.moveBy(Offset(direction * 175, 0));
        await tester.pump();
        expect(actions, isEmpty);
        expect(haptics, hasLength(1));
        if (reverse) {
          await gesture.moveBy(Offset(-direction * 70, 0));
          await tester.pump();
          expect(haptics, hasLength(2));
        }
        await gesture.up();
        await tester.pumpAndSettle();
        expect(actions, reverse ? isEmpty : equals([direction > 0 ? 0 : 1]));
        // Retraction/opening animations must not add haptics or actions.
        expect(haptics, hasLength(reverse ? 2 : 1));
        expect(
            haptics.every(
                (c) => c.arguments == 'HapticFeedbackType.mediumImpact'),
            isTrue);
        expect(tester.takeException(), isNull);
      });
    }
  }
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
