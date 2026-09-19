// Regression probes from the review of issue #55 (commit 3c689b5).
// All three are active: the same-day-collapse probe from #56, and the
// two live-refresh probes (issue #57) now that GroupListScreen refreshes
// via RouteAware.didPopNext and GroupSettingsScreen via a single
// watchExpensesForGroup subscription.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/group_list_screen.dart';
import 'package:spliit2go/screens/group_settings_screen.dart';
import 'package:spliit2go/services/date_span_calculator.dart';
import 'package:spliit2go/utils/date_format.dart';

const group = Group(id: 'g1', name: 'Trip', currency: '€', participants: []);
Expense expense(String id, DateTime date) => Expense(
    id: id,
    groupId: 'g1',
    title: 'Coffee',
    amountCents: 100,
    paidBy: 'p1',
    paidFor: const [],
    date: date,
    pending: true);
Widget app(Widget home, {GlobalKey<NavigatorState>? key}) => MaterialApp(
    navigatorKey: key,
    // GroupListScreen subscribes to this in didChangeDependencies
    // (issue #57) -- without it registered here too, didPopNext never
    // fires in a test.
    navigatorObservers: [groupListRouteObserver],
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home);
void main() {
  late AppDatabase db;
  // The plain (non-widget) test below calls formatDateSpan directly; inside
  // a widget tree MaterialApp's localizations delegates load intl's date
  // symbols, but a bare unit test has to initialize them itself.
  setUpAll(() => initializeDateFormatting('en'));
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.cacheGroup(group);
    await db.recordGroupOpened('g1', serverUrl: 'https://example.test');
    await db.insertPending(expense('e1', DateTime(2026, 1, 2)));
  });
  tearDown(() => db.close());
  test('same calendar day with distinct pending timestamps collapses',
      () async {
    await db.insertPending(expense('e2', DateTime(2026, 1, 2, 14)));
    expect(
        formatDateSpan(computeDateSpan(await db.expensesForGroup('g1')),
            locale: const Locale('en')),
        'Jan 2, 2026');
  });
  testWidgets('list updates after a route pushed by root returns',
      (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(app(GroupListScreen(db: db), key: nav));
    await tester.pumpAndSettle();
    expect(find.text('€  Jan 2, 2026'), findsOneWidget);
    // Models _Root opening the last-used group outside the list's tap handler.
    nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) =>
            const Scaffold(body: Text('Automatically opened group'))));
    await tester.pumpAndSettle();
    await db.insertPending(expense('e2', DateTime(2026, 6, 15)));
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('€  Jan 2, 2026 – Jun 15, 2026'), findsOneWidget);
    // Same drift-stream-cancel/pending-Timer workaround GroupScreen's own
    // tests already use (group_screen_test.dart): cancelling a
    // watchExpensesForGroup subscription in dispose() schedules a
    // zero-duration Timer (drift's StreamQueryStore.markAsClosed) that
    // needs one more pump to actually fire, or flutter_test's automatic
    // end-of-test teardown trips "A Timer is still pending even after
    // the widget tree was disposed" before it gets the chance.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
  testWidgets('settings span updates when background refresh writes cache',
      (tester) async {
    final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((_) async => throw Exception('unused')));
    await tester.pumpWidget(
        app(GroupSettingsScreen(client: client, db: db, group: group)));
    await tester.pumpAndSettle();
    expect(find.text('Jan 2, 2026'), findsOneWidget);
    await db.insertPending(expense('e2', DateTime(2026, 6, 15)));
    await tester.pumpAndSettle();
    expect(find.text('Jan 2, 2026 – Jun 15, 2026'), findsOneWidget);
    // Same workaround as above -- see its comment.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
