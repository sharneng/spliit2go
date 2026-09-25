import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/group_settings_screen.dart';

// Issue #115: the group settings form, in create mode.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  String createdResponse(String id) => jsonEncode([
        {
          'result': {
            'data': {
              'json': {'groupId': id},
            },
          },
        },
      ]);

  String groupResponse(String id, List<String> names) => jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'group': {
                  'id': id,
                  'name': 'Road trip',
                  'currency': '\$',
                  'currencyCode': 'USD',
                  'participants': [
                    for (var i = 0; i < names.length; i++) {'id': 'p$i', 'name': names[i]},
                  ],
                },
              },
            },
          },
        },
      ]);

  /// A server that creates [id] and returns it with the names it was sent.
  /// Records every request and the server each client was built for.
  ({List<http.Request> requests, List<String> servers, SpliitClient Function(String) factory})
      fakeServer({String id = 'new1', bool fail = false}) {
    final requests = <http.Request>[];
    final servers = <String>[];
    List<String> names = const [];
    SpliitClient factory(String serverUrl) {
      servers.add(serverUrl);
      return SpliitClient(
        baseUrl: serverUrl,
        httpClient: MockClient((req) async {
          requests.add(req);
          if (fail) return http.Response('boom', 500);
          if (req.url.path.endsWith('groups.create')) {
            final json = (jsonDecode(req.body)['0'] as Map)['json'] as Map;
            names = [
              for (final p in json['groupFormValues']['participants'] as List) p['name'] as String,
            ];
            return http.Response(createdResponse(id), 200);
          }
          if (req.url.path.endsWith('groups.get')) {
            return http.Response(groupResponse(id, names), 200);
          }
          return http.Response('unexpected', 500);
        }),
      );
    }

    return (requests: requests, servers: servers, factory: factory);
  }

  Map<String, dynamic> sentForm(http.Request req) =>
      ((jsonDecode(req.body)['0'] as Map)['json'] as Map)['groupFormValues']
          as Map<String, dynamic>;

  /// Pushes the create screen from a stub home, so its pop can be seen.
  Future<List<String?>> openCreate(WidgetTester tester, AppDatabase db,
      SpliitClient Function(String) factory,
      {Locale locale = const Locale('en')}) async {
    final popped = <String?>[];
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            popped.add(await Navigator.of(context).push<String>(MaterialPageRoute(
              builder: (_) => GroupSettingsScreen.create(db: db, clientFactory: factory),
            )));
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return popped;
  }

  Future<void> tapCreate(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Create'));
    await tester.pumpAndSettle();
  }

  Future<void> enterName(WidgetTester tester, String name) async {
    await tester.enterText(find.widgetWithText(TextField, 'Group name'), name);
  }

  testWidgets('opens as "Create group" with the sample participants, the region\'s currency, '
      'spliit.app, and no date span', (tester) async {
    tester.platformDispatcher.localeTestValue = const Locale('fr', 'FR');
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await openCreate(tester, db, fakeServer().factory);

    expect(find.text('Create group'), findsOneWidget);
    for (final name in ['John', 'Jane', 'Jack']) {
      expect(find.widgetWithText(TextField, name), findsOneWidget);
    }
    // The phone's region (France), not the app language, picks the currency.
    expect(find.textContaining('EUR'), findsOneWidget);
    expect(find.text('spliit.app'), findsOneWidget);
    expect(find.text('Date span'), findsNothing);
  });

  testWidgets('French sample names, as spliit-web uses', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await openCreate(tester, db, fakeServer().factory, locale: const Locale('fr'));

    for (final name in ['Jean', 'Jeanne', 'Jacques']) {
      expect(find.widgetWithText(TextField, name), findsOneWidget);
    }
  });

  testWidgets('creates on spliit.app, stores the group as joined with no expenses, and pops its id',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final server = fakeServer(id: 'new1');
    final popped = await openCreate(tester, db, server.factory);

    await enterName(tester, 'Road trip');
    await tapCreate(tester);

    expect(popped, ['new1']);
    expect(server.servers, ['https://spliit.app']);
    final create = server.requests.firstWhere((r) => r.url.path.endsWith('groups.create'));
    expect(sentForm(create)['name'], 'Road trip');
    expect(sentForm(create)['participants'], [
      {'name': 'John'},
      {'name': 'Jane'},
      {'name': 'Jack'},
    ]);

    final row = (await tester.runAsync(() => db.groupRow('new1')))!;
    expect(row.serverUrl, 'https://spliit.app');
    expect(row.lastOpenedAt, isNotNull); // in the group list
    expect(await tester.runAsync(() => db.expensesForGroup('new1')), isEmpty);
  });

  testWidgets('offers the servers this device already uses, most recent first', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    for (final (id, server, day) in [
      ('a', 'https://spliit.app', 1),
      ('b', 'https://spliit.example.com', 2),
    ]) {
      await db.cacheGroup(Group(id: id, name: id, currency: '\$', participants: const []));
      await db.recordGroupOpened(id, serverUrl: server, at: DateTime(2026, 9, day));
    }
    final server = fakeServer();
    await openCreate(tester, db, server.factory);

    // The most recently opened group's server is the default.
    expect(find.text('spliit.example.com'), findsOneWidget);
    await enterName(tester, 'Road trip');
    await tapCreate(tester);

    expect(server.servers, ['https://spliit.example.com']);
  });

  testWidgets('"Other server" takes a typed address, and refuses one that isn\'t', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final server = fakeServer();
    final popped = await openCreate(tester, db, server.factory);

    await enterName(tester, 'Road trip');
    await tester.tap(find.text('spliit.app'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other server').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Server address'), 'not a server');
    await tapCreate(tester);
    expect(find.textContaining('doesn’t look like a web address'), findsOneWidget);
    expect(server.requests, isEmpty);

    await tester.enterText(find.widgetWithText(TextField, 'Server address'), 'my.spliit.test/');
    await tapCreate(tester);
    expect(server.servers, ['https://my.spliit.test']);
    expect(popped, ['new1']);
  });

  testWidgets('checks the server\'s name rules before sending anything', (tester) async {
    // Tall enough that every participant row stays built under the error.
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final server = fakeServer();
    await openCreate(tester, db, server.factory);

    await enterName(tester, 'R');
    await tapCreate(tester);
    expect(find.text('The group name must be 2 to 50 characters.'), findsOneWidget);

    await enterName(tester, 'Road trip');
    await tester.enterText(find.widgetWithText(TextField, 'Jack'), 'John');
    await tapCreate(tester);
    expect(find.text('Two participants are named “John”. Each needs a different name.'),
        findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'John').last, 'J');
    await tapCreate(tester);
    expect(find.text('Participant names must be 2 to 50 characters.'), findsOneWidget);
    expect(server.requests, isEmpty);
  });

  testWidgets('a server failure stays on the form with the error', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final popped = await openCreate(tester, db, fakeServer(fail: true).factory);

    await enterName(tester, 'Road trip');
    await tapCreate(tester);

    expect(popped, isEmpty);
    expect(find.textContaining('Couldn’t create the group'), findsOneWidget);
    expect(await tester.runAsync(() => db.allJoinedGroups()), isEmpty);
  });
}
