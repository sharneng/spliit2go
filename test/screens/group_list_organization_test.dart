import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/screens/group_list_screen.dart';
import 'package:spliit2go/services/settings_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<AppDatabase> seed() async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    for (final id in ['Alpha', 'Beta']) {
      await db.cacheGroup(Group(
          id: id,
          name: id,
          currency: r'$',
          createdAt: DateTime.utc(2025, id == 'Alpha' ? 2 : 1),
          participants: const [Participant(id: 'p', name: 'Person')]));
      await db.recordGroupOpened(id,
          serverUrl: 'https://example.test',
          at: DateTime.utc(2026, id == 'Alpha' ? 1 : 2));
    }
    return db;
  }

  Future<void> pump(WidgetTester tester, AppDatabase db,
      {Locale locale = const Locale('en'), double scale = 1}) async {
    await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: GroupListScreen(db: db)));
    await tester.pumpAndSettle();
  }

  Future<void> action(WidgetTester tester, String group, String label) async {
    await tester.longPress(find.text(group));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, label));
    await tester.pumpAndSettle();
  }

  testWidgets('long press organizes groups exclusively and restores favorites',
      (tester) async {
    final db = await seed();
    await pump(tester, db);
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Favorites'), findsNothing);
    await action(tester, 'Alpha', 'Favorite');
    expect(find.text('Favorites'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Alpha')).dy,
        lessThan(tester.getTopLeft(find.text('Beta')).dy));
    await action(tester, 'Alpha', 'Archive');
    expect(find.text('Favorites'), findsNothing);
    expect(find.text('Archived'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect((await db.mostRecentlyOpenedGroup())!.id, 'Beta');
    await action(tester, 'Alpha', 'Unarchive');
    expect(find.text('Favorites'), findsOneWidget);
    expect(find.text('Archived'), findsNothing);
    await action(tester, 'Alpha', 'Unfavorite');
    expect(find.text('Favorites'), findsNothing);
  });
  testWidgets('remove requires confirmation and cancel preserves group',
      (tester) async {
    final db = await seed();
    await pump(tester, db);
    await action(tester, 'Alpha', 'Remove');
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(await db.groupRow('Alpha'), isNotNull);
    await action(tester, 'Alpha', 'Remove');
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(await db.groupRow('Alpha'), isNull);
  });
  testWidgets('shared sort selection persists after screen recreation',
      (tester) async {
    final db = await seed();
    await pump(tester, db);
    expect(tester.getTopLeft(find.text('Beta')).dy,
        lessThan(tester.getTopLeft(find.text('Alpha')).dy));
    await tester.tap(find.byTooltip('Sort groups'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Creation date'));
    await tester.pumpAndSettle();
    expect(await SettingsService().groupListSort(), 'created');
    expect(tester.getTopLeft(find.text('Alpha')).dy,
        lessThan(tester.getTopLeft(find.text('Beta')).dy));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await pump(tester, db);
    expect(tester.getTopLeft(find.text('Alpha')).dy,
        lessThan(tester.getTopLeft(find.text('Beta')).dy));
  });
  for (final locale in [
    const Locale('en'),
    const Locale('fr'),
    const Locale('zh')
  ]) {
    testWidgets('narrow layout with large text in $locale', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = await seed();
      await db.cacheGroup(const Group(
          id: 'Alpha',
          name: 'A very long group name for our holiday together',
          currency: r'$',
          participants: [Participant(id: 'p', name: 'Person')]));
      await db.replaceServerExpenses('Alpha', [
        for (final year in [2025, 2026])
          Expense(
              id: '$year',
              groupId: 'Alpha',
              title: 'Trip',
              amountCents: 100,
              paidBy: 'p',
              paidFor: const [],
              date: DateTime(year, 12, 31)),
      ]);
      await pump(tester, db, locale: locale, scale: 1.5);
      expect(find.text('SPLIIT2GO'), findsOneWidget);
      expect(find.text(r'$'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
