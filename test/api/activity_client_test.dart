import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/models/activity.dart';

void main() {
  group('ActivityType.fromWire', () {
    test('parses every known wire value', () {
      expect(ActivityType.fromWire('UPDATE_GROUP'), ActivityType.updateGroup);
      expect(ActivityType.fromWire('CREATE_EXPENSE'), ActivityType.createExpense);
      expect(ActivityType.fromWire('UPDATE_EXPENSE'), ActivityType.updateExpense);
      expect(ActivityType.fromWire('DELETE_EXPENSE'), ActivityType.deleteExpense);
    });

    test('falls back to updateGroup for an unrecognized value', () {
      expect(ActivityType.fromWire('SOMETHING_NEW'), ActivityType.updateGroup);
    });
  });

  group('SpliitClient.fetchActivities', () {
    test('parses activities, pagination, and expenseExists', () async {
      final body = jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'activities': [
                  {
                    'id': 'a1',
                    'time': '2026-09-01T12:00:00.000Z',
                    'activityType': 'CREATE_EXPENSE',
                    'participantId': 'p1',
                    'expenseId': 'e1',
                    'data': 'Groceries',
                    'expense': {'id': 'e1'},
                  },
                  {
                    'id': 'a2',
                    'time': '2026-09-01T09:00:00.000Z',
                    'activityType': 'DELETE_EXPENSE',
                    'participantId': 'p1',
                    'expenseId': 'e2',
                    'data': 'Old dinner',
                    'expense': null,
                  },
                  {
                    'id': 'a3',
                    'time': '2026-08-31T08:00:00.000Z',
                    'activityType': 'UPDATE_GROUP',
                    'participantId': null,
                    'expenseId': null,
                    'data': null,
                  },
                ],
                'hasMore': true,
                'nextCursor': 3,
              },
            },
          },
        },
      ]);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response(body, 200)),
      );

      final page = await client.fetchActivities(groupId: 'g1');

      expect(page.activities, hasLength(3));
      expect(page.hasMore, isTrue);
      expect(page.nextCursor, 3);

      final created = page.activities[0];
      expect(created.activityType, ActivityType.createExpense);
      expect(created.expenseId, 'e1');
      expect(created.expenseExists, isTrue);

      final deleted = page.activities[1];
      expect(deleted.activityType, ActivityType.deleteExpense);
      // The server omits the nested expense once it's gone, even though
      // expenseId is still present -- expenseExists reflects that, not
      // just whether expenseId is non-null.
      expect(deleted.expenseExists, isFalse);

      final groupUpdate = page.activities[2];
      expect(groupUpdate.activityType, ActivityType.updateGroup);
      expect(groupUpdate.participantId, isNull);
      expect(groupUpdate.expenseId, isNull);
      expect(groupUpdate.expenseExists, isFalse);
    });

    test('a missing expenseId also means expenseExists is false', () async {
      final body = jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'activities': [
                  {
                    'id': 'a1',
                    'time': '2026-09-01T12:00:00.000Z',
                    'activityType': 'UPDATE_GROUP',
                    'participantId': 'p1',
                    'expenseId': null,
                    'data': null,
                    'expense': null,
                  },
                ],
                'hasMore': false,
                'nextCursor': 1,
              },
            },
          },
        },
      ]);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response(body, 200)),
      );

      final page = await client.fetchActivities(groupId: 'g1');

      expect(page.activities.single.expenseExists, isFalse);
      expect(page.hasMore, isFalse);
    });
  });
}
