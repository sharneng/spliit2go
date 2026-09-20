import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/models/group_organization.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/screens/group_list_screen.dart';
import 'package:spliit2go/widgets/group_monogram.dart';
import 'package:spliit2go/services/settings_service.dart';

class _FailingSortStore extends InMemorySharedPreferencesStore {
  _FailingSortStore(this.throwsError)
      : super.withData({'flutter.group_list_sort': 'lastOpened'});
  final bool throwsError;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (throwsError) throw StateError('disk unavailable');
    return false;
  }
}

class _DelayedSettings extends SettingsService {
  final write = Completer<void>();
  int reads = 0;
  @override
  Future<String?> groupListSort() async {
    reads++;
    return 'lastOpened';
  }

  @override
  Future<void> setGroupListSort(String value) => write.future;
}

class _DelayedRemovalDatabase extends AppDatabase {
  _DelayedRemovalDatabase() : super(NativeDatabase.memory());
  final removal = Completer<void>();
  int reads = 0;
  @override
  Future<List<GroupRow>> allJoinedGroups() {
    reads++;
    return super.allJoinedGroups();
  }

  @override
  Future<void> leaveGroup(String id) async {
    await removal.future;
    await super.leaveGroup(id);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<AppDatabase> seed({AppDatabase? database}) async {
    final db = database ?? AppDatabase(NativeDatabase.memory());
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
      {Locale locale = const Locale('en'),
      double scale = 1,
      SettingsService? settings,
      TargetPlatform? platform}) async {
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: platform),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: GroupListScreen(db: db, settings: settings)));
    await tester.pumpAndSettle();
  }

  Future<void> action(WidgetTester tester, String group, String label) async {
    await tester.longPress(find.text(group));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<int>, label));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'long press switches exclusive states; unarchive returns to Active',
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
    expect(find.text('Favorites'), findsNothing);
    expect(
        (await db.groupRow('Alpha'))!.organization, GroupOrganization.active);
    expect(find.text('Archived'), findsNothing);
    await action(tester, 'Alpha', 'Favorite');
    await action(tester, 'Alpha', 'Unfavorite');
    expect(find.text('Favorites'), findsNothing);
    await action(tester, 'Alpha', 'Archive');
    await action(tester, 'Alpha', 'Favorite');
    expect(find.text('Archived'), findsNothing);
    expect(
        (await db.groupRow('Alpha'))!.organization, GroupOrganization.favorite);
  });
  for (final throwsError in [false, true]) {
    testWidgets(
        'failed sort save preserves selection, order, and reload ($throwsError)',
        (tester) async {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = _FailingSortStore(throwsError);
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      final db = await seed();
      await pump(tester, db);
      await tester.tap(find.byTooltip('Sort groups'));
      await tester.pumpAndSettle();
      await tester.tap(find.ancestor(
          of: find.text('Creation date'),
          matching: find
              .byWidgetPredicate((widget) => widget is CheckedPopupMenuItem)));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(tester.getTopLeft(find.text('Beta')).dy,
          lessThan(tester.getTopLeft(find.text('Alpha')).dy));
      await tester.tap(find.byTooltip('Sort groups'));
      await tester.pumpAndSettle();
      final checked = tester.widgetList<CheckedPopupMenuItem>(
          find.byWidgetPredicate((widget) => widget is CheckedPopupMenuItem));
      expect(checked.where((item) => item.checked).single.child,
          isA<Text>().having((text) => text.data, 'selection', 'Last opened'));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      // Reopening must not pick up a failed write from the plugin's cache.
      await pump(tester, db);
      expect(await SettingsService().groupListSort(), 'lastOpened');
      expect(tester.getTopLeft(find.text('Beta')).dy,
          lessThan(tester.getTopLeft(find.text('Alpha')).dy));
    });
  }

  testWidgets('sort completing after disposal causes no reload or UI access',
      (tester) async {
    final settings = _DelayedSettings();
    final db = await seed();
    await pump(tester, db, settings: settings);
    await tester.tap(find.byTooltip('Sort groups'));
    await tester.pumpAndSettle();
    await tester.tap(find.ancestor(
        of: find.text('Creation date'),
        matching: find
            .byWidgetPredicate((widget) => widget is CheckedPopupMenuItem)));
    await tester.pumpAndSettle();
    final reads = settings.reads;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    settings.write.complete();
    await tester.pumpAndSettle();
    expect(settings.reads, reads);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'swipe removal finishing after disposal avoids another database read',
      (tester) async {
    final db = _DelayedRemovalDatabase();
    await seed(database: db);
    await pump(tester, db);
    await tester.drag(find.text('Alpha'), const Offset(-400, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CustomSlidableAction, 'Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();
    final reads = db.reads;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    db.removal.complete();
    await tester.pumpAndSettle();
    expect(await db.groupRow('Alpha'), isNull);
    expect(db.reads, reads);
    expect(tester.takeException(), isNull);
  });

  testWidgets('monogram tap opens anchored actions without opening the group',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final db = await seed();
    await pump(tester, db);
    final before = (await db.groupRow('Alpha'))!.lastOpenedAt;
    expect(find.bySemanticsLabel('Actions for Alpha'), findsOneWidget);
    await tester.tap(
        find.byWidgetPredicate((w) => w is GroupMonogram && w.id == 'Alpha'));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<int>), findsNWidgets(3));
    expect(find.byType(BottomSheet), findsNothing);
    expect((await db.groupRow('Alpha'))!.lastOpenedAt, before);
    await tester.tap(find.widgetWithText(PopupMenuItem<int>, 'Favorite'));
    await tester.pumpAndSettle();
    expect(
        (await db.groupRow('Alpha'))!.organization, GroupOrganization.favorite);
    semantics.dispose();
  });

  testWidgets(
      'swipe actions support all organization transitions and preserve pending expenses',
      (tester) async {
    final db = await seed();
    await db.insertPending(Expense(
        id: 'pending',
        groupId: 'Alpha',
        title: 'Offline',
        amountCents: 100,
        paidBy: 'p',
        paidFor: const [],
        pending: true,
        date: DateTime(2026)));
    await pump(tester, db);
    Future<void> swipe(String label, bool start) async {
      await tester.drag(find.text('Alpha'), Offset(start ? 200 : -400, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CustomSlidableAction, label));
      await tester.pumpAndSettle();
    }

    for (final step in [
      ('Favorite', true, GroupOrganization.favorite),
      ('Unfavorite', true, GroupOrganization.active),
      ('Archive', false, GroupOrganization.archived),
      ('Unarchive', false, GroupOrganization.active),
      ('Archive', false, GroupOrganization.archived),
      ('Favorite', true, GroupOrganization.favorite),
    ]) {
      await swipe(step.$1, step.$2);
      expect((await db.groupRow('Alpha'))!.organization, step.$3);
    }
    expect(await db.pendingExpensesForGroup('Alpha'), hasLength(1));
  });

  testWidgets('full swipes toggle organization without removing the group',
      (tester) async {
    final db = await seed();
    await pump(tester, db);
    for (final step in [
      (760.0, GroupOrganization.favorite),
      (760.0, GroupOrganization.active),
      (-760.0, GroupOrganization.archived),
      (-760.0, GroupOrganization.active),
    ]) {
      final gesture =
          await tester.startGesture(tester.getCenter(find.text('Alpha')));
      await gesture.moveBy(Offset(step.$1.sign * 30, 0));
      await tester.pump();
      await gesture.moveBy(Offset(step.$1 - step.$1.sign * 30, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect((await db.groupRow('Alpha'))!.organization, step.$2);
      expect(find.byWidgetPredicate((w) => w is AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('menu width is consistent across organization states',
      (tester) async {
    final db = await seed();
    await pump(tester, db);
    final widths = <double>[];
    for (final organization in GroupOrganization.values) {
      await db.setGroupOrganization('Alpha', organization);
      await tester.pumpWidget(const SizedBox());
      await pump(tester, db);
      await tester.longPress(find.text('Alpha'));
      await tester.pumpAndSettle();
      widths.add(tester.getSize(find.byType(PopupMenuItem<int>).first).width);
      await tester.tapAt(const Offset(790, 590));
      await tester.pumpAndSettle();
    }
    expect(widths.toSet(), hasLength(1));
    expect(widths.first, greaterThanOrEqualTo(280));
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
        'removal uses adaptive confirmation and cancel is safe on $platform',
        (tester) async {
      final db = await seed();
      await pump(tester, db, platform: platform);
      await action(tester, 'Alpha', 'Remove');
      if (platform == TargetPlatform.iOS) {
        expect(find.byType(CupertinoAlertDialog), findsOneWidget);
        final remove = tester.widget<CupertinoDialogAction>(
            find.widgetWithText(CupertinoDialogAction, 'Remove'));
        expect(remove.isDestructiveAction, isTrue);
        await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Cancel'));
      } else {
        expect(find.byWidgetPredicate((w) => w is AlertDialog), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      }
      await tester.pumpAndSettle();
      expect(await db.groupRow('Alpha'), isNotNull);
      await action(tester, 'Alpha', 'Remove');
      await tester.tap(find.widgetWithText(
          platform == TargetPlatform.iOS ? CupertinoDialogAction : TextButton,
          'Remove'));
      await tester.pumpAndSettle();
      expect(await db.groupRow('Alpha'), isNull);
    });
  }

  testWidgets(
      'all archived groups remain visible with working unarchive actions',
      (tester) async {
    final db = await seed();
    for (final id in ['Alpha', 'Beta']) {
      await db.setGroupOrganization(id, GroupOrganization.archived);
    }
    await pump(tester, db);
    expect(find.text('Archived'), findsOneWidget);
    expect(find.text('Active'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    await action(tester, 'Alpha', 'Unarchive');
    expect(find.text('Active'), findsOneWidget);
  });

  testWidgets('remove requires confirmation and cancel preserves group',
      (tester) async {
    final db = await seed();
    await pump(tester, db);
    await action(tester, 'Alpha', 'Remove');
    expect(find.byWidgetPredicate((w) => w is AlertDialog), findsOneWidget);
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
    await tester.tap(find.ancestor(
        of: find.text('Creation date'),
        matching: find
            .byWidgetPredicate((widget) => widget is CheckedPopupMenuItem)));
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
