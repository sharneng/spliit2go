import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/group_settings_screen.dart';

void main() {
  const group = Group(
    id: 'g1',
    name: 'Banff Trip',
    currency: '\$',
    participants: [
      Participant(id: 'alex', name: 'Alex'),
      Participant(id: 'bea', name: 'Bea'),
    ],
  );

  String freshGroupResponse(Map<String, dynamic> g) => jsonEncode([
        {
          'result': {
            'data': {
              'json': {'group': g},
            },
          },
        },
      ]);

  testWidgets('saving a rename posts groups.update and pops the fresh group', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    http.Request? updateRequest;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        if (req.url.toString().contains('groups.update')) {
          updateRequest = req;
          return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
        }
        // groups.get: return the renamed group as the server's truth.
        return http.Response(
          freshGroupResponse({
            'id': 'g1',
            'name': 'Renamed Trip',
            'currency': '\$',
            'participants': [
              {'id': 'alex', 'name': 'Alex'},
              {'id': 'bea', 'name': 'Bea'},
            ],
          }),
          200,
        );
      }),
    );

    Group? popped;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            popped = await Navigator.of(context).push<Group>(
              MaterialPageRoute(
                builder: (_) => GroupSettingsScreen(client: client, db: db, group: group),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Banff Trip'), 'Renamed Trip');
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(updateRequest, isNotNull);
    final sent = jsonDecode(updateRequest!.body) as Map<String, dynamic>;
    final formValues =
        (sent['0'] as Map<String, dynamic>)['json']['groupFormValues'] as Map<String, dynamic>;
    expect(formValues['name'], 'Renamed Trip');

    expect(popped, isNotNull);
    expect(popped!.name, 'Renamed Trip');
    // The fresh group should also have landed in the local cache.
    expect((await db.cachedGroup('g1'))?.name, 'Renamed Trip');
  });

  testWidgets('removing a participant then saving omits them from the request', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    http.Request? updateRequest;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        if (req.url.toString().contains('groups.update')) {
          updateRequest = req;
          return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
        }
        return http.Response(
          freshGroupResponse({
            'id': 'g1',
            'name': 'Banff Trip',
            'currency': '\$',
            'participants': [
              {'id': 'alex', 'name': 'Alex'},
            ],
          }),
          200,
        );
      }),
    );

    await tester.pumpWidget(MaterialApp(
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(updateRequest, isNotNull);
    final sent = jsonDecode(updateRequest!.body) as Map<String, dynamic>;
    final formValues =
        (sent['0'] as Map<String, dynamic>)['json']['groupFormValues'] as Map<String, dynamic>;
    expect(formValues['participants'], [
      {'id': 'bea', 'name': 'Bea'},
    ]);
  });

  testWidgets('adding a participant sends them with no id', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    http.Request? updateRequest;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        if (req.url.toString().contains('groups.update')) {
          updateRequest = req;
          return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
        }
        return http.Response(
          freshGroupResponse({
            'id': 'g1',
            'name': 'Banff Trip',
            'currency': '\$',
            'participants': [
              {'id': 'alex', 'name': 'Alex'},
              {'id': 'bea', 'name': 'Bea'},
              {'id': 'cid', 'name': 'Cid'},
            ],
          }),
          200,
        );
      }),
    );

    await tester.pumpWidget(MaterialApp(
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.person_add_outlined));
    await tester.pumpAndSettle();
    // The new row is the last TextField with no decoration label.
    await tester.enterText(find.byType(TextField).last, 'Cid');
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(updateRequest, isNotNull);
    final sent = jsonDecode(updateRequest!.body) as Map<String, dynamic>;
    final formValues =
        (sent['0'] as Map<String, dynamic>)['json']['groupFormValues'] as Map<String, dynamic>;
    expect(formValues['participants'], [
      {'id': 'alex', 'name': 'Alex'},
      {'id': 'bea', 'name': 'Bea'},
      {'name': 'Cid'},
    ]);
  });

  testWidgets('blank group name blocks save with an inline error', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    var updateCalled = false;
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async {
        if (req.url.toString().contains('groups.update')) updateCalled = true;
        return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
      }),
    );

    await tester.pumpWidget(MaterialApp(
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Banff Trip'), '');
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(updateCalled, isFalse);
    expect(find.text('Group name is required.'), findsOneWidget);
  });
}
