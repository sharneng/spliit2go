import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';

void main() {
  group('SpliitClient.fetchGroup', () {
    test('parses a group with participants', () async {
      final body = jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'group': {
                  'id': 'g1',
                  'name': 'Banff Trip',
                  'currency': '\$',
                  'participants': [
                    {'id': 'p1', 'name': 'Ken'},
                    {'id': 'p2', 'name': 'Jenny'},
                  ],
                },
              },
            },
          },
        },
      ]);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response(body, 200)),
      );

      final group = await client.fetchGroup('g1');

      expect(group.name, 'Banff Trip');
      expect(group.participants, hasLength(2));
      expect(group.participants.map((p) => p.name), containsAll(['Ken', 'Jenny']));
    });
  });

  group('SpliitClient.fetchExpenses', () {
    // Regression test for the real bug found testing against a live
    // server on 2026-09-16: groups.expenses.list returns paidBy and each
    // paidFor entry's participant as an expanded {id, name} object, not
    // the bare id string the create-expense payload sends. The original
    // parser assumed the write shape applied to reads too, and threw
    // "type _Map<String, dynamic> is not a subtype of type 'String'".
    test('parses paidBy and paidFor as expanded participant objects', () async {
      final body = jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'expenses': [
                  {
                    'id': 'e1',
                    'title': 'Coffee',
                    'amount': 500,
                    'paidBy': {'id': 'p1', 'name': 'Ken'},
                    'paidFor': [
                      {
                        'participant': {'id': 'p1', 'name': 'Ken'},
                        'shares': 1,
                      },
                      {
                        'participant': {'id': 'p2', 'name': 'Jenny'},
                        'shares': 1,
                      },
                    ],
                    'splitMode': 'EVENLY',
                    'category': 0,
                    'notes': '',
                    'expenseDate': '2026-09-16T00:00:00.000Z',
                    'isReimbursement': false,
                  },
                ],
                'hasMore': false,
              },
            },
          },
        },
      ]);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response(body, 200)),
      );

      final expenses = await client.fetchExpenses('g1');

      expect(expenses, hasLength(1));
      expect(expenses.first.paidBy, 'p1');
      expect(expenses.first.paidFor.map((s) => s.participantId), ['p1', 'p2']);
    });

    // The client also has to tolerate the flatter shape -- a bare id
    // string -- since that's what we send on create, and nothing
    // guarantees every server version/endpoint expands it the same way.
    test('also parses paidBy and paidFor as bare id strings', () async {
      final body = jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'expenses': [
                  {
                    'id': 'e1',
                    'title': 'Coffee',
                    'amount': 500,
                    'paidBy': 'p1',
                    'paidFor': [
                      {'participant': 'p1', 'shares': 1},
                    ],
                    'expenseDate': '2026-09-16T00:00:00.000Z',
                  },
                ],
                'hasMore': false,
              },
            },
          },
        },
      ]);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response(body, 200)),
      );

      final expenses = await client.fetchExpenses('g1');

      expect(expenses.first.paidBy, 'p1');
      expect(expenses.first.paidFor.single.participantId, 'p1');
    });

    test('follows pagination via hasMore/nextCursor', () async {
      var callCount = 0;
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          callCount++;
          final isFirstPage = !req.url.toString().contains('cursor');
          final body = jsonEncode([
            {
              'result': {
                'data': {
                  'json': {
                    'expenses': [
                      {
                        'id': isFirstPage ? 'e1' : 'e2',
                        'title': 'Item',
                        'amount': 100,
                        'paidBy': 'p1',
                        'paidFor': [
                          {'participant': 'p1', 'shares': 1},
                        ],
                        'expenseDate': '2026-09-16T00:00:00.000Z',
                      },
                    ],
                    'hasMore': isFirstPage,
                    if (isFirstPage) 'nextCursor': 'page2',
                  },
                },
              },
            },
          ]);
          return http.Response(body, 200);
        }),
      );

      final expenses = await client.fetchExpenses('g1');

      expect(callCount, 2);
      expect(expenses.map((e) => e.id), ['e1', 'e2']);
    });
  });
}
