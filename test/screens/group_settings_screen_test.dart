import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/group_settings_screen.dart';

/// A minimal expense used purely to exercise the participant-protection
/// checks (issue #46) below -- title/amount/date are arbitrary.
Expense _expenseWithSplit({
  required String id,
  required String paidBy,
  required List<ExpenseShare> paidFor,
}) =>
    Expense(
      id: id,
      groupId: 'g1',
      title: 'Dinner',
      amountCents: 1000,
      paidBy: paidBy,
      paidFor: paidFor,
      date: DateTime.utc(2026, 9, 19),
    );

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
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
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
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
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
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    // The date-span field (issue #55) pushes the participant list further
    // down than the test surface's default viewport, so the add button
    // needs an explicit scroll-into-view before it's tappable.
    await tester.ensureVisible(find.byIcon(Icons.person_add_outlined));
    await tester.tap(find.byIcon(Icons.person_add_outlined));
    await tester.pumpAndSettle();
    // The new row is the last TextField with no decoration label.
    await tester.ensureVisible(find.byType(TextField).last);
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
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Banff Trip'), '');
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(updateCalled, isFalse);
    expect(find.text('Group name is required.'), findsOneWidget);
  });

  testWidgets('a group with no currencyCode shows Custom, prefilled with its symbol (issue #23)',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => http.Response('[{"result":{"data":{"json":{}}}}]', 200)),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Custom'), findsOneWidget);
    expect(find.widgetWithText(TextField, '\$'), findsOneWidget);
  });

  testWidgets('clearing the custom currency symbol blocks save with an inline error',
      (tester) async {
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
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, '\$'), '');
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(updateCalled, isFalse);
    expect(find.text('Enter at least one character.'), findsOneWidget);
  });

  testWidgets('picking a real currency from the picker fills the symbol and sends its code',
      (tester) async {
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
            'currency': '€',
            'currencyCode': 'EUR',
            'participants': [
              {'id': 'alex', 'name': 'Alex'},
              {'id': 'bea', 'name': 'Bea'},
            ],
          }),
          200,
        );
      }),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(InputDecorator, 'Custom'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Search currency...'), 'Euro');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Euro (EUR)'));
    await tester.pumpAndSettle();

    // Custom's symbol field should be gone now that a real currency is
    // selected -- nothing left to validate as "at least one character".
    expect(find.text('Currency symbol'), findsNothing);

    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(updateRequest, isNotNull);
    final sent = jsonDecode(updateRequest!.body) as Map<String, dynamic>;
    final formValues =
        (sent['0'] as Map<String, dynamic>)['json']['groupFormValues'] as Map<String, dynamic>;
    expect(formValues['currency'], '€');
    expect(formValues['currencyCode'], 'EUR');
  });

  testWidgets('editing group information sends it in the update request', (tester) async {
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
            'information': 'Split hotel evenly.',
            'participants': [
              {'id': 'alex', 'name': 'Alex'},
              {'id': 'bea', 'name': 'Bea'},
            ],
          }),
          200,
        );
      }),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Group information'),
      'Split hotel evenly.',
    );
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(updateRequest, isNotNull);
    final sent = jsonDecode(updateRequest!.body) as Map<String, dynamic>;
    final formValues =
        (sent['0'] as Map<String, dynamic>)['json']['groupFormValues'] as Map<String, dynamic>;
    expect(formValues['information'], 'Split hotel evenly.');
  });

  // Protects participants with expenses (issue #46).

  testWidgets('disables the remove button for a participant who paid an expense', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.replaceServerExpenses('g1', [
      _expenseWithSplit(
        id: 'e1',
        paidBy: 'alex',
        paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
      ),
    ]);

    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw Exception('not used')),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    final closeButtons = tester
        .widgetList<IconButton>(
          find.ancestor(of: find.byIcon(Icons.close), matching: find.byType(IconButton)),
        )
        .toList();
    // Row order matches group.participants: alex, then bea.
    expect(closeButtons[0].onPressed, isNull);
    expect(closeButtons[1].onPressed, isNotNull);
  });

  testWidgets('also protects a participant who is only in paidFor, not paidBy', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.replaceServerExpenses('g1', [
      _expenseWithSplit(
        id: 'e1',
        paidBy: 'bea',
        paidFor: const [
          ExpenseShare(participantId: 'bea', shares: 1),
          ExpenseShare(participantId: 'alex', shares: 1),
        ],
      ),
    ]);

    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw Exception('not used')),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    final closeButtons = tester
        .widgetList<IconButton>(
          find.ancestor(of: find.byIcon(Icons.close), matching: find.byType(IconButton)),
        )
        .toList();
    expect(closeButtons[0].onPressed, isNull); // alex: in paidFor
    expect(closeButtons[1].onPressed, isNull); // bea: paidBy
  });

  testWidgets('a participant with no associated expenses can still be removed', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.replaceServerExpenses('g1', [
      _expenseWithSplit(
        id: 'e1',
        paidBy: 'alex',
        paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
      ),
    ]);
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
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    // bea (second row) has no expenses -- its remove button still works.
    // Scoped to bea's own row (rather than find.byIcon(Icons.close).at(1))
    // so it can't accidentally resolve to a different participant's
    // button after the date-span field (issue #55) pushes this row
    // below the test surface's default viewport and it needs scrolling
    // into view first.
    final beaCloseButton = find.descendant(
      of: find.ancestor(of: find.widgetWithText(TextField, 'Bea'), matching: find.byType(Row)),
      matching: find.byIcon(Icons.close),
    );
    await tester.ensureVisible(beaCloseButton);
    // TEMP DEBUG (issue #55 CI investigation) -- remove before merge.
    final beaIconButton = tester.widget<IconButton>(
      find.ancestor(of: beaCloseButton, matching: find.byType(IconButton)),
    );
    // ignore: avoid_print
    print('DEBUG bea IconButton onPressed is null: ${beaIconButton.onPressed == null}');
    await tester.tap(beaCloseButton);
    await tester.pump();
    // ignore: avoid_print
    print('DEBUG close-icon count after tap+pump: ${find.byIcon(Icons.close).evaluate().length}');
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('DEBUG close-icon count after settle: ${find.byIcon(Icons.close).evaluate().length}');
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(updateRequest, isNotNull);
    final sent = jsonDecode(updateRequest!.body) as Map<String, dynamic>;
    final formValues =
        (sent['0'] as Map<String, dynamic>)['json']['groupFormValues'] as Map<String, dynamic>;
    expect(formValues['participants'], [
      {'id': 'alex', 'name': 'Alex'},
    ]);
  });

  // Issue #55: date span shown on this screen, computed from the
  // group's cached expenses -- first expense date to last.
  // Local, date-only DateTimes -- see the comment on date_span_calculator_test.dart's
  // expense() helper: AppDatabase's drift round-trip only preserves a
  // DateTime.utc(...) fixture's calendar date on a machine at UTC+0, and
  // shifts it a day west of UTC otherwise.
  testWidgets('shows the date span computed from the earliest and latest cached expense dates',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.replaceServerExpenses('g1', [
      Expense(
        id: 'e1',
        groupId: 'g1',
        title: 'Dinner',
        amountCents: 1000,
        paidBy: 'alex',
        paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
        date: DateTime(2026, 1, 2),
      ),
      Expense(
        id: 'e2',
        groupId: 'g1',
        title: 'Hotel',
        amountCents: 5000,
        paidBy: 'alex',
        paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
        date: DateTime(2026, 6, 15),
      ),
    ]);

    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw Exception('not used')),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    expect(find.text('2026-01-02 – 2026-06-15'), findsOneWidget);
  });

  testWidgets('shows the em-dash placeholder when the group has no cached expenses',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw Exception('not used')),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupSettingsScreen(client: client, db: db, group: group),
    ));
    await tester.pumpAndSettle();

    expect(find.text('—'), findsOneWidget);
  });
}
