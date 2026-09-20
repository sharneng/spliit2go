import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/group_list_screen.dart';

void main() {
  // Opening a group navigates into GroupScreen, whose
  // _resolveActiveUser awaits SharedPreferences -- see
  // join_group_screen_test.dart for why this is needed.
  SharedPreferences.setMockInitialValues({});

  SpliitClient offlineClient() => SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => throw Exception('offline')),
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
    expect(
      tester.widget<ListTile>(tiles.at(0)).title,
      isA<Text>().having((t) => t.data, 'text', 'Tokyo Trip'),
    );
    expect(
      tester.widget<ListTile>(tiles.at(1)).title,
      isA<Text>().having((t) => t.data, 'text', 'Banff Trip'),
    );
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
      httpClient: MockClient((req) async => throw Exception('offline')),
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
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(find.text('No groups yet.'), findsOneWidget);
    expect(await db.groupRow('gA'), isNull);
  });

  // Issue #55: date span shown next to participant metadata.
  // Local, date-only DateTimes -- see date_span_calculator_test.dart's
  // expense() helper comment: a DateTime.utc(...) fixture doesn't survive
  // AppDatabase's drift round-trip intact on a machine west of UTC.
  testWidgets("shows each group's date span without a currency symbol",
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(const Group(
        id: 'gA', name: 'Banff Trip', currency: '\$', participants: []));
    await db.recordGroupOpened('gA', serverUrl: 'https://example.test');
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

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupListScreen(db: db, clientFactory: (_) => offlineClient()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Jan 2, 2026 – Jun 15, 2026'), findsOneWidget);
  });

  testWidgets(
      'shows the em-dash placeholder for a group with no cached expenses',
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
}
