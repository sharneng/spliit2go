import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/main.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/screens/group_list_screen.dart';
import 'package:spliit2go/screens/group_screen.dart';
import 'package:spliit2go/screens/join_group_screen.dart';

void main() {
  late AppDatabase db;
  late StreamController<Uri> links;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    links = StreamController<Uri>();
  });
  tearDown(() async {
    await links.close();
    await db.close();
  });

  Future<void> mount(WidgetTester tester,
      {Future<Uri?>? initial, SpliitClient? client}) async {
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [groupListRouteObserver],
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppRoot(
          db: db,
          links: links.stream,
          initialLink: initial,
          clientFactory: (url) =>
              client ??
              SpliitClient(
                  baseUrl: url,
                  httpClient:
                      MockClient((_) async => throw Exception('offline')))),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets(
      'cold link takes precedence over last-used group and prefills join',
      (tester) async {
    await db.cacheGroup(const Group(
        id: 'old', name: 'Old trip', currency: '€', participants: []));
    await db.recordGroupOpened('old', serverUrl: 'https://spliit.app');
    await mount(tester,
        initial: Future.value(Uri.parse('https://spliit.app/groups/new')));
    expect(find.byType(JoinGroupScreen), findsOneWidget);
    expect(find.byType(GroupScreen), findsNothing);
    expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        'https://spliit.app/groups/new');
    await dispose(tester);
  });

  testWidgets('duplicate warm links open just one route', (tester) async {
    await mount(tester, initial: Future.value(null));
    // Warm delivery can repeat the launch event; it must not stack a second join.
    final uri = Uri.parse('https://spliit.app/groups/new');
    links.add(uri);
    links.add(uri);
    await tester.pumpAndSettle();
    expect(find.byType(JoinGroupScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(JoinGroupScreen), findsNothing);
    expect(find.byType(GroupListScreen), findsOneWidget);
    await dispose(tester);
  });

  testWidgets('stream link received during startup is retained',
      (tester) async {
    final initial = Completer<Uri?>();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppRoot(db: db, links: links.stream, initialLink: initial.future),
    ));
    links.add(Uri.parse('https://spliit.app/groups/new'));
    await tester.pump();
    initial.complete(Uri.parse('https://spliit.app/groups/new'));
    await tester.pumpAndSettle();
    expect(find.byType(JoinGroupScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(JoinGroupScreen), findsNothing);
    await dispose(tester);
  });

  testWidgets(
      'unrelated and malformed links are ignored; valid warm link still works',
      (tester) async {
    await mount(tester);
    for (final url in [
      'https://evil.test/groups/g1',
      'http://spliit.app/groups/g1',
      'https://spliit.app/groups/',
      'https://spliit.app/about',
      'https://spliit.app:8443/groups/g1'
    ]) {
      links.add(Uri.parse(url));
    }
    links.addError(Exception('invalid platform event'));
    await tester.pumpAndSettle();
    expect(find.byType(JoinGroupScreen), findsNothing);
    links.add(Uri.parse('https://spliit.app/groups/new/expenses'));
    await tester.pumpAndSettle();
    expect(find.byType(JoinGroupScreen), findsOneWidget);
    await dispose(tester);
  });

  testWidgets(
      'new link joins and opens the fetched group; back returns to list',
      (tester) async {
    await mount(tester,
        initial: Future.value(Uri.parse('https://spliit.app/groups/new')),
        client: _JoinClient());
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    expect(find.byType(GroupScreen), findsOneWidget);
    expect(find.byType(JoinGroupScreen), findsNothing);
    expect((await db.groupRow('new'))?.serverUrl, 'https://spliit.app');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(GroupListScreen), findsOneWidget);
    expect(find.text('New trip'), findsOneWidget);
    await dispose(tester);
  });

  testWidgets('joined group opens offline directly without join',
      (tester) async {
    await db.cacheGroup(
        const Group(id: 'g1', name: 'Trip', currency: '€', participants: []));
    await db.recordGroupOpened('g1', serverUrl: 'https://spliit.app');
    await mount(tester,
        initial: Future.value(Uri.parse('https://spliit.app/groups/g1')));
    expect(find.byType(GroupScreen), findsOneWidget);
    expect(find.byType(JoinGroupScreen), findsNothing);
    await dispose(tester);
  });
}

class _JoinClient extends SpliitClient {
  _JoinClient() : super(baseUrl: 'https://spliit.app');

  @override
  Future<Group> fetchGroup(String groupId) async => Group(
      id: groupId, name: 'New trip', currency: '€', participants: const []);

  @override
  Future<List<Expense>> fetchExpenses(String groupId) async => [];
}
