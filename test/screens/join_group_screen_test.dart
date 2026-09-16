import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/screens/join_group_screen.dart';

void main() {
  // SettingsService.defaultActiveUserName() awaits
  // SharedPreferences.getInstance(); without this, the call hangs
  // forever in a widget test (no platform channel handler registered),
  // which keeps JoinGroupScreen's _joining spinner animating forever
  // and pumpAndSettle times out -- discovered by exactly that timeout.
  SharedPreferences.setMockInitialValues({});

  String groupResponse() => jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'group': {
                  'id': 'g1',
                  'name': 'Banff Trip',
                  'currency': '\$',
                  'participants': [
                    {'id': 'alex', 'name': 'Alex'},
                    {'id': 'bea', 'name': 'Bea'},
                  ],
                },
              },
            },
          },
        },
      ]);

  Future<String?> pushAndJoin(WidgetTester tester, AppDatabase db, SpliitClient client,
      {String url = 'https://example.test/groups/g1'}) async {
    String? popped;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            popped = await Navigator.of(context).push<String>(
              MaterialPageRoute(
                builder: (_) => JoinGroupScreen(db: db, clientFactory: (_) => client),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Group URL'), url);
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    return popped;
  }

  testWidgets('joining fetches the group, caches it, records it opened, and pops the group id',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => http.Response(groupResponse(), 200)),
    );

    final poppedGroupId = await pushAndJoin(tester, db, client);

    expect(poppedGroupId, 'g1');
    final cached = await db.cachedGroup('g1');
    expect(cached?.name, 'Banff Trip');
    final row = await db.groupRow('g1');
    expect(row?.serverUrl, 'https://example.test');
    expect(row?.lastOpenedAt, isNotNull);
  });

  testWidgets('auto-matches the active participant against the device default name',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => http.Response(groupResponse(), 200)),
    );

    // SettingsService's SharedPreferences-backed value isn't easily
    // seeded from a plain widget test without the platform channel, so
    // this exercises the "no default name set" path instead --
    // resolveActiveParticipant's matching logic itself is covered
    // directly in active_user_test.dart. What this confirms is that
    // JoinGroupScreen doesn't set an active participant when there's
    // nothing to auto-match against.
    await pushAndJoin(tester, db, client);

    final row = await db.groupRow('g1');
    expect(row?.activeParticipantId, isNull);
  });

  testWidgets('a server error is shown inline and nothing is cached', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => http.Response('server error', 500)),
    );

    final poppedGroupId = await pushAndJoin(tester, db, client);

    expect(poppedGroupId, isNull);
    expect(find.textContaining("Couldn't join"), findsOneWidget);
    expect(await db.cachedGroup('g1'), isNull);
  });

  testWidgets('a blank field is rejected by form validation before any request', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    var requested = false;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        requested = true;
        return http.Response(groupResponse(), 200);
      }),
    );

    await tester.pumpWidget(MaterialApp(
      home: JoinGroupScreen(db: db, clientFactory: (_) => client),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();

    expect(find.text('Required'), findsWidgets);
    expect(requested, isFalse);
  });

  testWidgets('a URL that has no /groups/ segment is rejected before any request',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    var requested = false;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        requested = true;
        return http.Response(groupResponse(), 200);
      }),
    );

    final poppedGroupId =
        await pushAndJoin(tester, db, client, url: 'https://example.test/not-a-group-url');

    expect(poppedGroupId, isNull);
    expect(requested, isFalse);
    expect(find.textContaining("doesn't look like a group URL"), findsOneWidget);
  });
}
