import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:spliit2go/models/group_organization.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/group_list_screen.dart';
import 'package:spliit2go/widgets/grouped_section.dart';
import '../support/haptics.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:spliit2go/services/group_list_order.dart';

void main() {
  // Opening a group navigates into GroupScreen, whose
  // _resolveActiveUser awaits SharedPreferences -- see
  // join_group_screen_test.dart for why this is needed.
  SharedPreferences.setMockInitialValues({});

  SpliitClient offlineClient() => SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw http.ClientException('offline')),
      );

  testWidgets('shows an empty state with a join button when nothing is joined',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupListScreen(db: db, clientFactory: (_) => offlineClient()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('No groups yet.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Join a group'), findsOneWidget);
  });

  testWidgets('lists joined groups most-recently-opened first', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(const Group(
        id: 'gA', name: 'Banff Trip', currency: '\$', participants: []));
    await db.cacheGroup(const Group(
        id: 'gB', name: 'Tokyo Trip', currency: '¥', participants: []));
    // Explicit, distinct timestamps -- drift's DateTime storage is
    // second-granularity, so two real DateTime.now() calls made
    // back-to-back here could otherwise tie and make this flaky.
    await db.recordGroupOpened('gA',
        serverUrl: 'https://example.test',
        at: DateTime.utc(2026, 9, 16, 10, 0, 0));
    await db.recordGroupOpened('gB',
        serverUrl: 'https://example.test',
        at: DateTime.utc(2026, 9, 16, 10, 0, 1));

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupListScreen(db: db, clientFactory: (_) => offlineClient()),
    ));
    await tester.pumpAndSettle();

    final tiles = find.byType(ListTile);
    expect(tiles, findsNWidgets(2));
    expect(find.descendant(of: tiles.at(0), matching: find.text('Tokyo Trip')),
        findsOneWidget);
    expect(find.descendant(of: tiles.at(1), matching: find.text('Banff Trip')),
        findsOneWidget);
  });

  testWidgets('each section is a grouped card, hairlines under the names (#185)',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    for (final (id, name) in [('gA', 'Banff Trip'), ('gB', 'Tokyo Trip')]) {
      await db.cacheGroup(Group(id: id, name: name, currency: '\$', participants: const []));
      await db.recordGroupOpened(id, serverUrl: 'https://example.test');
    }

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupListScreen(db: db, clientFactory: (_) => offlineClient()),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(GroupedItem), findsNWidgets(2));
    expect(find.widgetWithText(GroupedCaption, 'Active'), findsOneWidget);
    final divider = find.byType(Divider);
    expect(divider, findsOneWidget, reason: 'between the two rows only');
    final second = find.ancestor(of: divider, matching: find.byType(GroupedItem));
    final name = find.descendant(
        of: second, matching: find.byWidgetPredicate((w) => w is Text && w.data!.endsWith('Trip')));
    expect(tester.widget<Divider>(divider).indent,
        tester.getTopLeft(name).dx - tester.getTopLeft(divider).dx);
    // Each row opens the group's screen, so has a chevron (#186 review).
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));
  });

  testWidgets('a cached-but-never-opened group does not show in the list',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(const Group(
        id: 'gA', name: 'Banff Trip', currency: '\$', participants: []));

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupListScreen(db: db, clientFactory: (_) => offlineClient()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('No groups yet.'), findsOneWidget);
  });

  testWidgets('tapping a group opens it and records the visit', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(const Group(
        id: 'gA', name: 'Banff Trip', currency: '\$', participants: []));
    await db.recordGroupOpened('gA', serverUrl: 'https://example.test');
    final before = (await db.groupRow('gA'))!.lastOpenedAt!;

    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw http.ClientException('offline')),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupListScreen(db: db, clientFactory: (_) => client),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Banff Trip'));
    await tester.pumpAndSettle();

    // Landed on GroupScreen (offline, but the group was already cached).
    expect(find.text('Banff Trip'), findsWidgets);
    final after = (await db.groupRow('gA'))!.lastOpenedAt!;
    expect(after.isAfter(before) || after.isAtSameMomentAs(before), isTrue);
    // Drift's watch() stream (issue #47) schedules an internal
    // debounce/reconnect Timer when a subscriber cancels, which
    // happens when this widget is disposed (here: navigating into
    // GroupScreen, which uses it). flutter_test's automatic end-of-test
    // teardown doesn't give that Timer a chance to fire before its "no
    // pending timers" invariant check, so we force disposal ourselves
    // here and pump once more to drain it.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('leaving a group via dismiss removes it after confirmation',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(const Group(
        id: 'gA', name: 'Banff Trip', currency: '\$', participants: []));
    await db.recordGroupOpened('gA', serverUrl: 'https://example.test');

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupListScreen(db: db, clientFactory: (_) => offlineClient()),
    ));
    await tester.pumpAndSettle();

    await tester.drag(find.text('Banff Trip'), const Offset(-400, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CustomSlidableAction, 'Remove'));
    await tester.pumpAndSettle();

    expect(find.byWidgetPredicate((w) => w is AlertDialog), findsOneWidget);
    final haptics = recordHaptics(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(haptics, ['HapticFeedbackType.lightImpact']); // #179
    expect(find.text('No groups yet.'), findsOneWidget);
    expect(await db.groupRow('gA'), isNull);
  });

  // Issue #55 showed the first-to-last span beside the participant count;
  // #201 shows only the date the list is sorted by, which fits.
  // Local, date-only DateTimes -- see date_span_calculator_test.dart's
  // expense() helper comment: a DateTime.utc(...) fixture doesn't survive
  // AppDatabase's drift round-trip intact on a machine west of UTC.
  testWidgets('shows the one date each sort orders by (#201)',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(Group(
        id: 'gA',
        name: 'Banff Trip',
        currency: '\$',
        participants: const [],
        createdAt: DateTime(2026, 4, 5, 12)));
    await db.recordGroupOpened('gA',
        serverUrl: 'https://example.test', at: DateTime(2026, 9, 3, 12));
    await db.replaceServerExpenses('gA', [
      Expense(
        id: 'e1',
        groupId: 'gA',
        title: 'Coffee',
        amountCents: 500,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        date: DateTime(2026, 1, 2),
      ),
      Expense(
        id: 'e2',
        groupId: 'gA',
        title: 'Hotel',
        amountCents: 5000,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        date: DateTime(2026, 6, 15),
      ),
    ]);

    for (final (sort, shown) in [
      (GroupListSort.firstExpense, 'Jan 2, 2026'),
      (GroupListSort.lastExpense, 'Jun 15, 2026'),
      (GroupListSort.created, 'Apr 5, 2026'),
      (GroupListSort.lastOpened, 'Sep 3, 2026'),
    ]) {
      SharedPreferences.setMockInitialValues({'group_list_sort': sort.name});
      await tester.pumpWidget(MaterialApp(
        key: ValueKey(sort),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: GroupListScreen(db: db, clientFactory: (_) => offlineClient()),
      ));
      await tester.pumpAndSettle();

      expect(find.text(shown), findsOneWidget, reason: sort.name);
      expect(find.textContaining('–'), findsNothing);
      // The date at the start, under the name; the count at the end,
      // number before icon (#201 review).
      expect(tester.getTopLeft(find.byIcon(LucideIcons.calendar)).dx,
          tester.getTopLeft(find.text('Banff Trip')).dx);
      expect(tester.getTopRight(find.byIcon(LucideIcons.users)).dx,
          tester.getTopRight(find.text('Banff Trip')).dx);
      expect(tester.getTopRight(find.text('0')).dx,
          lessThan(tester.getTopLeft(find.byIcon(LucideIcons.users)).dx));
      expect(tester.widget<Text>(find.text('Banff Trip')).style?.fontWeight,
          FontWeight.w600);
      // 8 to the chevron, not ListTile's 16; the name still starts at 80.
      expect(
          tester.getTopLeft(find.byIcon(Icons.chevron_right)).dx -
              tester.getTopRight(find.byIcon(LucideIcons.users)).dx,
          8);
      expect(
          tester.getTopLeft(find.text('Banff Trip')).dx -
              tester.getTopLeft(find.byType(ListTile)).dx,
          80);
    }
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('caption icons are sized from the caption text and grow with it (#180)',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(const Group(
        id: 'gA', name: 'Banff Trip', currency: '\$', participants: []));
    await db.recordGroupOpened('gA', serverUrl: 'https://example.test');

    Future<double> iconSize(double textScale) async {
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!),
        home: GroupListScreen(db: db, clientFactory: (_) => offlineClient()),
      ));
      await tester.pumpAndSettle();
      expect(find.byIcon(LucideIcons.calendar), findsOneWidget);
      return tester.widget<Icon>(find.byIcon(LucideIcons.users)).size!;
    }

    final normal = await iconSize(1);
    expect(normal, greaterThan(14)); // was a fixed 14 px
    expect(await iconSize(2), closeTo(normal * 2, 0.01));
  });

  testWidgets(
      'shows the em-dash placeholder for a group with no cached expenses',
      (tester) async {
    SharedPreferences.setMockInitialValues({'group_list_sort': 'lastExpense'});
    addTearDown(() => SharedPreferences.setMockInitialValues({}));
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(const Group(
        id: 'gA', name: 'Banff Trip', currency: '\$', participants: []));
    await db.recordGroupOpened('gA', serverUrl: 'https://example.test');

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupListScreen(db: db, clientFactory: (_) => offlineClient()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('cancelling the leave confirmation keeps the group',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(const Group(
        id: 'gA', name: 'Banff Trip', currency: '\$', participants: []));
    await db.recordGroupOpened('gA', serverUrl: 'https://example.test');

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupListScreen(db: db, clientFactory: (_) => offlineClient()),
    ));
    await tester.pumpAndSettle();

    await tester.drag(find.text('Banff Trip'), const Offset(-400, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CustomSlidableAction, 'Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Banff Trip'), findsOneWidget);
    expect(await db.groupRow('gA'), isNotNull);
  });

  // #209: a screen reader hears what the date is, and gets the swipe
  // actions as its own; at large text sizes the date isn't broken.
  group('accessibility (#209)', () {
    Future<AppDatabase> oneGroup(WidgetTester tester,
        {GroupListSort sort = GroupListSort.lastOpened, double scale = 1}) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.cacheGroup(const Group(id: 'gA', name: 'Banff Trip', currency: '\$', participants: [
        Participant(id: 'a', name: 'A'),
        Participant(id: 'b', name: 'B'),
        Participant(id: 'c', name: 'C'),
      ]));
      await db.recordGroupOpened('gA',
          serverUrl: 'https://example.test', at: DateTime(2026, 9, 3, 12));
      SharedPreferences.setMockInitialValues({'group_list_sort': sort.name});
      await tester.pumpWidget(MaterialApp(
        key: ValueKey((sort, scale)),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        navigatorObservers: [groupListRouteObserver],
        home: MediaQuery.withClampedTextScaling(
            minScaleFactor: scale,
            maxScaleFactor: scale,
            child: GroupListScreen(db: db, clientFactory: (_) => offlineClient())),
      ));
      await tester.pumpAndSettle();
      return db;
    }

    Future<void> dispose(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    }

    SemanticsData row(WidgetTester tester) =>
        tester.getSemantics(find.byType(ListTile)).getSemanticsData();

    testWidgets('the row is read as sentences, the date named', (tester) async {
      await oneGroup(tester);
      expect(row(tester).label, 'Banff Trip. Last opened Sep 3, 2026. 3 participants.');
      await dispose(tester);

      await oneGroup(tester, sort: GroupListSort.lastExpense);
      expect(row(tester).label, 'Banff Trip. No expenses yet. 3 participants.');
      await dispose(tester);
    });

    testWidgets('favorite, archive and remove are screen-reader actions', (tester) async {
      final db = await oneGroup(tester);
      final data = row(tester);
      final labels = [
        for (final id in data.customSemanticsActionIds!)
          CustomSemanticsAction.getAction(id)!.label,
      ];
      expect(labels, ['Favorite', 'Archive', 'Remove']);

      final favorite = data.customSemanticsActionIds!.first;
      tester.renderObject(find.byType(ListTile)).owner!.semanticsOwner!.performAction(
          tester.getSemantics(find.byType(ListTile)).id, SemanticsAction.customAction, favorite);
      await tester.pumpAndSettle();
      expect((await db.groupRow('gA'))!.organization, GroupOrganization.favorite);
      await dispose(tester);
    });

    for (final width in [320.0, 390.0]) {
      for (final scale in [1.0, 2.0, 3.0]) {
        testWidgets('fits ${width.toInt()} wide, text at ${scale}x', (tester) async {
          tester.view.physicalSize = Size(width * 3, 2400 * 3);
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.reset);
          await oneGroup(tester, scale: scale);
          expect(tester.takeException(), isNull);

          // The date on one line, the count inside the row.
          final date = tester.renderObject<RenderParagraph>(find.text('Sep 3, 2026'));
          expect(date.size.height, lessThan(scale * 14 * 1.6), reason: 'the date wrapped');
          final tile = tester.getRect(find.byType(ListTile));
          final people = tester.getRect(find.byIcon(LucideIcons.users));
          expect(tile.contains(people.bottomRight - const Offset(1, 1)), isTrue);
          await dispose(tester);
        });
      }
    }
  });
}
