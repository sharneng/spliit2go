import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/models/category.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';

void main() {
  group('SpliitClient.fetchCategories', () {
    test('parses categories with their grouping', () async {
      final body = jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'categories': [
                  {'id': 0, 'name': 'General', 'grouping': 'Uncategorized'},
                  {'id': 9, 'name': 'Groceries', 'grouping': 'Food and Drink'},
                ],
              },
            },
          },
        },
      ]);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response(body, 200)),
      );

      final categories = await client.fetchCategories();

      expect(categories, hasLength(2));
      expect(categories[0], isA<Category>());
      expect(categories[1].name, 'Groceries');
      expect(categories[1].grouping, 'Food and Drink');
    });

    // A server that predates the grouping column, or omits it for some
    // other reason, still gets a usable category list rather than a
    // parse failure.
    test('defaults grouping to Other when the server omits it', () async {
      final body = jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'categories': [
                  {'id': 0, 'name': 'General'},
                ],
              },
            },
          },
        },
      ]);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response(body, 200)),
      );

      final categories = await client.fetchCategories();

      expect(categories.single.grouping, 'Other');
    });
  });

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

    // Regression test for github.com/sharneng/spliit2go/issues/14: a
    // live self-hosted server sent numeric ids where spliit.app sends
    // cuid strings, and the original bare `as String` casts on
    // group/participant id threw "type 'int' is not a subtype of type
    // 'String' in type cast", crashing the whole group screen.
    test('tolerates numeric group and participant ids', () async {
      final body = jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'group': {
                  'id': 42,
                  'name': 'Banff Trip',
                  'currency': '\$',
                  'participants': [
                    {'id': 1, 'name': 'Ken'},
                    {'id': 2, 'name': 'Jenny'},
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

      final group = await client.fetchGroup('42');

      expect(group.id, '42');
      expect(group.participants.map((p) => p.id), ['1', '2']);
    });

    test('parses information and currencyCode when present (issue #23)', () async {
      final body = jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'group': {
                  'id': 'g1',
                  'name': 'Banff Trip',
                  'information': 'Split hotel evenly.',
                  'currency': '\$',
                  'currencyCode': 'USD',
                  'participants': <Map<String, dynamic>>[],
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

      expect(group.information, 'Split hotel evenly.');
      expect(group.currencyCode, 'USD');
    });

    test('information and currencyCode are null when the server omits them', () async {
      final body = jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'group': {
                  'id': 'g1',
                  'name': 'Banff Trip',
                  'currency': '\$',
                  'participants': <Map<String, dynamic>>[],
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

      expect(group.information, isNull);
      expect(group.currencyCode, isNull);
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

    // Issue #16/#17: recurrenceRule, originalAmount/originalCurrency/
    // conversionRate ("paid in a different currency") now round-trip too.
    test('parses recurrenceRule and original-currency fields', () async {
      final body = jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'expenses': [
                  {
                    'id': 'e1',
                    'title': 'Hotel',
                    'amount': 10000,
                    'paidBy': 'p1',
                    'paidFor': [
                      {'participant': 'p1', 'shares': 1},
                    ],
                    'splitMode': 'EVENLY',
                    'category': 0,
                    'notes': '',
                    'expenseDate': '2026-09-16T00:00:00.000Z',
                    'isReimbursement': false,
                    'recurrenceRule': 'MONTHLY',
                    'originalAmount': 9000,
                    'originalCurrency': 'EUR',
                    'conversionRate': 1.111,
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

      expect(expenses.first.recurrenceRule, RecurrenceRule.monthly);
      expect(expenses.first.originalAmountCents, 9000);
      expect(expenses.first.originalCurrency, 'EUR');
      expect(expenses.first.conversionRate, 1.111);
    });

    // conversionRate is a Prisma Decimal, which can come back over the
    // wire as a numeric string rather than a plain number -- tolerate
    // both rather than assume one.
    test('tolerates conversionRate sent as a numeric string', () async {
      final body = jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'expenses': [
                  {
                    'id': 'e1',
                    'title': 'Hotel',
                    'amount': 10000,
                    'paidBy': 'p1',
                    'paidFor': [
                      {'participant': 'p1', 'shares': 1},
                    ],
                    'splitMode': 'EVENLY',
                    'category': 0,
                    'notes': '',
                    'expenseDate': '2026-09-16T00:00:00.000Z',
                    'isReimbursement': false,
                    'originalAmount': 9000,
                    'originalCurrency': 'EUR',
                    'conversionRate': '1.111',
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

      expect(expenses.first.conversionRate, 1.111);
    });

    // Defaults for an expense that has none of the new fields at all --
    // a server that predates them, or a plain expense in the group's own
    // currency.
    test('defaults recurrenceRule to none and original-currency fields to null', () async {
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

      expect(expenses.first.recurrenceRule, RecurrenceRule.none);
      expect(expenses.first.originalAmountCents, isNull);
      expect(expenses.first.originalCurrency, isNull);
      expect(expenses.first.conversionRate, isNull);
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

    // Regression test for github.com/sharneng/spliit2go/issues/15:
    // expenseDate is a date-only value (Postgres @db.Date, carried at
    // UTC midnight -- see decisions/date-handling.md), not a real
    // instant. Parsing it with a true timezone conversion rolls the
    // date back a day west of UTC. This asserts the parsed date has
    // the exact year/month/day the server sent, regardless of what
    // timezone this test happens to run in.
    test('parses expenseDate as the calendar date, not a timezone-shifted instant',
        () async {
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
                    'expenseDate': '2026-09-13T00:00:00.000Z',
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

      expect(expenses.single.date, DateTime(2026, 9, 13));
    });

    // Regression test for the *actual* root cause of
    // github.com/sharneng/spliit2go/issues/14, confirmed from a real
    // device's flutter log: groups.expenses.list's `cursor` input is a
    // numeric offset on at least one real server, not the opaque cuid
    // string this client's pagination was ported assuming. Sending it
    // back stringified got a 400: "expected number, received string".
    // The cursor now has to be passed through as whatever type the
    // server sent it as -- this pins that down for a numeric cursor.
    test('round-trips a numeric nextCursor as a JSON number, not a string',
        () async {
      http.Request? secondRequest;
      var callCount = 0;
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          callCount++;
          final isFirstPage = callCount == 1;
          if (!isFirstPage) secondRequest = req;
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
                    if (isFirstPage) 'nextCursor': 10,
                  },
                },
              },
            },
          ]);
          return http.Response(body, 200);
        }),
      );

      await client.fetchExpenses('g1');

      expect(callCount, 2);
      final inputParam = secondRequest!.url.queryParameters['input']!;
      final decoded = jsonDecode(inputParam) as Map<String, dynamic>;
      final cursor = (decoded['0'] as Map<String, dynamic>)['json']['cursor'];
      expect(cursor, 10);
      expect(cursor, isA<int>());
    });

    // Same regression as fetchGroup above, for the fields fetchExpenses
    // reads: expense id, a bare-id paidBy, and the pagination cursor.
    test('tolerates a numeric expense id, paidBy id, and cursor', () async {
      final body = jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'expenses': [
                  {
                    'id': 99,
                    'title': 'Coffee',
                    'amount': 500,
                    'paidBy': 1,
                    'paidFor': [
                      {'participant': 1, 'shares': 1},
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

      expect(expenses.single.id, '99');
      expect(expenses.single.paidBy, '1');
    });

    // expenseDate as an epoch-millis number (some server configurations
    // send this instead of an ISO string) shouldn't crash DateTime
    // parsing either.
    test('tolerates expenseDate as epoch millis instead of an ISO string', () async {
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
                    'expenseDate': 1757980800000,
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

      expect(expenses.single.date, DateTime(2025, 9, 16));
    });
  });

  group('SpliitClient.fetchExpense', () {
    // The `groups.expenses.get` (singular) response shape is the raw
    // Prisma row, not the same shape `groups.expenses.list` selects --
    // `paidBy` comes back as a nested {id, name} object (a Prisma
    // belongsTo `include`) and each `paidFor` row comes back with a flat
    // `participantId` string column, not a `participant` key at all
    // (confirmed against spliit-web's src/lib/api.ts `getExpense`). This
    // fixture mirrors that real shape -- see issue #35's regression
    // below for why that distinction matters.
    test('fetches and parses a single expense by id', () async {
      http.Request? captured;
      final body = jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'expense': {
                  'id': 'e1',
                  'title': 'Hotel',
                  'amount': 10000,
                  'paidBy': {'id': 'p1', 'name': 'Alex'},
                  'paidFor': [
                    {'participantId': 'p1', 'shares': 1},
                  ],
                  'splitMode': 'EVENLY',
                  'category': 0,
                  'notes': 'note',
                  'expenseDate': '2026-09-16T00:00:00.000Z',
                  'isReimbursement': false,
                  'recurrenceRule': 'WEEKLY',
                },
              },
            },
          },
        },
      ]);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(body, 200);
        }),
      );

      final expense = await client.fetchExpense(groupId: 'g1', expenseId: 'e1');

      expect(expense.id, 'e1');
      expect(expense.title, 'Hotel');
      expect(expense.paidBy, 'p1');
      expect(expense.recurrenceRule, RecurrenceRule.weekly);
      expect(captured!.url.toString(), contains('groups.expenses.get'));
    });

    // Regression test for issue #35: before the fix, a paidFor row shaped
    // this way (the real `groups.expenses.get` shape -- see above) parsed
    // to participantId "null" for every entry, since ExpenseShare.fromJson
    // only ever looked at a `participant` key. That silently matched no
    // real participant, so ExpenseScreen's edit mode came up with every
    // "Paid for" checkbox unchecked no matter what the expense actually
    // said.
    test("parses paidFor's flat participantId column (issue #35)", () async {
      final body = jsonEncode([
        {
          'result': {
            'data': {
              'json': {
                'expense': {
                  'id': 'e1',
                  'title': 'Hotel',
                  'amount': 10000,
                  'paidBy': {'id': 'p1', 'name': 'Alex'},
                  'paidFor': [
                    {'participantId': 'p1', 'shares': 1},
                    {'participantId': 'p2', 'shares': 1},
                  ],
                  'splitMode': 'EVENLY',
                  'category': 0,
                  'notes': '',
                  'expenseDate': '2026-09-16T00:00:00.000Z',
                  'isReimbursement': false,
                  'recurrenceRule': 'NONE',
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

      final expense = await client.fetchExpense(groupId: 'g1', expenseId: 'e1');

      expect(expense.paidFor.map((s) => s.participantId).toSet(), {'p1', 'p2'});
    });

    test('throws when the expense is not found', () async {
      final body = jsonEncode([
        {
          'error': {'message': 'Expense not found', 'code': -32004},
        },
      ]);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response(body, 200)),
      );

      expect(
        () => client.fetchExpense(groupId: 'g1', expenseId: 'missing'),
        throwsA(isA<SpliitApiException>()),
      );
    });
  });

  group('SpliitClient.createExpense', () {
    // Regression test for github.com/sharneng/spliit2go/issues/15: the
    // date this sends has to be UTC midnight of the *calendar* date
    // passed in, regardless of what time-of-day is on it -- see
    // decisions/date-handling.md. The old code called .toUtc() on the
    // real instant, which could roll an evening entry west of UTC onto
    // the next day on the server. 11pm here would have failed the old
    // implementation.
    test('encodes the date as UTC midnight regardless of time-of-day', () async {
      http.Request? captured;
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
        }),
      );

      await client.createExpense(
        groupId: 'g1',
        title: 'Dinner',
        amountCents: 1000,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        date: DateTime(2026, 9, 16, 23, 0),
      );

      expect(captured, isNotNull);
      final sent = jsonDecode(captured!.body) as Map<String, dynamic>;
      final formValues =
          (sent['0'] as Map<String, dynamic>)['json']['expenseFormValues'] as Map<String, dynamic>;
      expect(formValues['expenseDate'], '2026-09-16T00:00:00.000Z');
    });

    test('defaults to today when no date is given, still at UTC midnight', () async {
      http.Request? captured;
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
        }),
      );

      await client.createExpense(
        groupId: 'g1',
        title: 'Dinner',
        amountCents: 1000,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
      );

      final sent = jsonDecode(captured!.body) as Map<String, dynamic>;
      final formValues =
          (sent['0'] as Map<String, dynamic>)['json']['expenseFormValues'] as Map<String, dynamic>;
      expect(formValues['expenseDate'], endsWith('T00:00:00.000Z'));
    });

    // Issue #16: the new fields all reach the wire, and default to a
    // shape a server with no "paid in" values on this expense expects
    // (no originalAmount/originalCurrency/conversionRate keys at all,
    // rather than sending explicit nulls).
    test('sends recurrenceRule and omits original-currency fields when unset', () async {
      http.Request? captured;
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
        }),
      );

      await client.createExpense(
        groupId: 'g1',
        title: 'Dinner',
        amountCents: 1000,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        recurrenceRule: RecurrenceRule.weekly,
      );

      final sent = jsonDecode(captured!.body) as Map<String, dynamic>;
      final formValues =
          (sent['0'] as Map<String, dynamic>)['json']['expenseFormValues'] as Map<String, dynamic>;
      expect(formValues['recurrenceRule'], 'WEEKLY');
      expect(formValues.containsKey('originalAmount'), isFalse);
      expect(formValues.containsKey('originalCurrency'), isFalse);
      expect(formValues.containsKey('conversionRate'), isFalse);
    });

    test('sends original-currency fields when paid in a different currency', () async {
      http.Request? captured;
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
        }),
      );

      await client.createExpense(
        groupId: 'g1',
        title: 'Hotel',
        amountCents: 10000,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        originalAmountCents: 9000,
        originalCurrency: 'EUR',
        conversionRate: 1.111,
      );

      final sent = jsonDecode(captured!.body) as Map<String, dynamic>;
      final formValues =
          (sent['0'] as Map<String, dynamic>)['json']['expenseFormValues'] as Map<String, dynamic>;
      expect(formValues['originalAmount'], 9000);
      expect(formValues['originalCurrency'], 'EUR');
      expect(formValues['conversionRate'], 1.111);
    });
  });

  group('SpliitClient.updateExpense', () {
    test('posts to groups.expenses.update with the expense id and form values', () async {
      http.Request? captured;
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('[{"result":{"data":{"json":{"expenseId":"e1"}}}}]', 200);
        }),
      );

      final id = await client.updateExpense(
        groupId: 'g1',
        expenseId: 'e1',
        title: 'Dinner (edited)',
        amountCents: 1500,
        paidBy: 'p1',
        paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
      );

      expect(id, 'e1');
      expect(captured!.url.toString(), contains('groups.expenses.update'));
      final sent = jsonDecode(captured!.body) as Map<String, dynamic>;
      final json = (sent['0'] as Map<String, dynamic>)['json'] as Map<String, dynamic>;
      expect(json['groupId'], 'g1');
      expect(json['expenseId'], 'e1');
      final formValues = json['expenseFormValues'] as Map<String, dynamic>;
      expect(formValues['title'], 'Dinner (edited)');
      expect(formValues['amount'], 1500);
    });

    test('throws on an embedded tRPC error', () async {
      final body = jsonEncode([
        {
          'error': {'message': 'Expense not found', 'code': -32004},
        },
      ]);
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response(body, 200)),
      );

      expect(
        () => client.updateExpense(
          groupId: 'g1',
          expenseId: 'missing',
          title: 'Dinner',
          amountCents: 1000,
          paidBy: 'p1',
          paidFor: const [ExpenseShare(participantId: 'p1', shares: 1)],
        ),
        throwsA(isA<SpliitApiException>()),
      );
    });
  });

  group('SpliitClient.updateGroup', () {
    test('sends existing participants with their id and new ones without', () async {
      http.Request? captured;
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
        }),
      );

      await client.updateGroup(
        groupId: 'g1',
        name: 'Banff Trip 2',
        currency: '€',
        participants: const [
          Participant(id: 'p1', name: 'Ken'),
          Participant(id: '', name: 'New Person'),
        ],
      );

      expect(captured, isNotNull);
      expect(captured!.url.toString(), contains('groups.update'));
      final sent = jsonDecode(captured!.body) as Map<String, dynamic>;
      final formValues =
          (sent['0'] as Map<String, dynamic>)['json']['groupFormValues'] as Map<String, dynamic>;
      expect(formValues['name'], 'Banff Trip 2');
      expect(formValues['currency'], '€');
      expect(formValues['participants'], [
        {'id': 'p1', 'name': 'Ken'},
        {'name': 'New Person'},
      ]);
    });

    test('sends information and currencyCode (issue #23)', () async {
      http.Request? captured;
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
        }),
      );

      await client.updateGroup(
        groupId: 'g1',
        name: 'Banff Trip',
        information: 'Split hotel evenly.',
        currency: '\$',
        currencyCode: 'USD',
        participants: const [Participant(id: 'p1', name: 'Ken')],
      );

      final sent = jsonDecode(captured!.body) as Map<String, dynamic>;
      final formValues =
          (sent['0'] as Map<String, dynamic>)['json']['groupFormValues'] as Map<String, dynamic>;
      expect(formValues['information'], 'Split hotel evenly.');
      expect(formValues['currencyCode'], 'USD');
    });

    test('sends empty-string information/currencyCode when omitted, not null', () async {
      // The server's groupFormSchema wants '' (not a JSON null) for "no
      // code" -- z.union([z.string().length(3)..., z.literal('')]).
      http.Request? captured;
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('[{"result":{"data":{"json":{}}}}]', 200);
        }),
      );

      await client.updateGroup(
        groupId: 'g1',
        name: 'Banff Trip',
        currency: '\$',
        participants: const [Participant(id: 'p1', name: 'Ken')],
      );

      final sent = jsonDecode(captured!.body) as Map<String, dynamic>;
      final formValues =
          (sent['0'] as Map<String, dynamic>)['json']['groupFormValues'] as Map<String, dynamic>;
      expect(formValues['information'], '');
      expect(formValues['currencyCode'], '');
    });

    test('throws on an embedded tRPC error', () async {
      final client = SpliitClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((req) async => http.Response(
              jsonEncode([
                {
                  'error': {'message': 'group not found'},
                },
              ]),
              200,
            )),
      );

      expect(
        () => client.updateGroup(
          groupId: 'missing',
          name: 'x',
          currency: '\$',
          participants: const [Participant(id: 'p1', name: 'Ken')],
        ),
        throwsA(isA<SpliitApiException>()),
      );
    });
  });
}
