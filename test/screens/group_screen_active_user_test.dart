import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/group_screen.dart';
import 'package:spliit2go/services/active_user.dart';
import 'package:spliit2go/services/settings_service.dart';
import 'package:spliit2go/sync/outbox.dart';

// The one-time "Who are you?" prompt (issue #85).
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
  final prompt = find.text('Who are you?');
  const statsHint = 'Pick an active user to see your personal totals.';

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> openGroup(WidgetTester tester, AppDatabase db,
      {Locale locale = const Locale('en')}) async {
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw Exception('offline')),
    );
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: GroupScreen(
          client: client, db: db, outbox: Outbox(db, client, groupId: 'g1'), groupId: 'g1'),
    ));
    await tester.pumpAndSettle();
  }

  // Disposes GroupScreen and drains drift's watch-stream timer -- see
  // group_screen_test.dart's first test (issue #47).
  Future<void> closeGroup(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<String?> stored(AppDatabase db) async =>
      (await db.groupRow('g1'))?.activeParticipantId;

  Expense coffee() => Expense(
        id: 'e1',
        groupId: 'g1',
        title: 'Coffee',
        amountCents: 500,
        paidBy: 'alex',
        paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
        date: DateTime.utc(2026, 9, 16),
      );

  // A narrow phone at double system text size (#87 review).
  void useNarrowLargeText(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  testWidgets('asks once for a group never asked before; a pick is saved and seeds the default name',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(group);

    await openGroup(tester, db);
    expect(find.byIcon(Icons.person_outline), findsNothing);
    expect(prompt, findsOneWidget);
    expect(find.text('Nobody'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Nobody')).dy,
        greaterThan(tester.getTopLeft(find.text('Bea')).dy),
        reason: 'the way out goes after the participants, not above them');

    await tester.tap(find.text('Bea'));
    await tester.pumpAndSettle();
    expect(prompt, findsNothing);
    expect(await stored(db), 'bea');
    expect(await SettingsService().defaultActiveUserName(), 'Bea');

    await closeGroup(tester);
    await openGroup(tester, db);
    expect(prompt, findsNothing);
    await closeGroup(tester);
  });

  testWidgets('does not ask when the device default name matches a participant', (tester) async {
    SharedPreferences.setMockInitialValues({'default_active_user_name': 'alex'});
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(group);

    await openGroup(tester, db);
    expect(prompt, findsNothing);
    expect(await stored(db), 'alex');
    await closeGroup(tester);
  });

  testWidgets('Nobody is remembered: never asked again, and the default name stays unset',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(group);

    await openGroup(tester, db);
    await tester.tap(find.text('Nobody'));
    await tester.pumpAndSettle();
    expect(await stored(db), nobodyParticipantId);
    expect(await SettingsService().defaultActiveUserName(), isNull);

    await closeGroup(tester);
    await openGroup(tester, db);
    expect(prompt, findsNothing);
    await closeGroup(tester);
  });

  testWidgets('dismissing the prompt counts as Nobody', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(group);

    await openGroup(tester, db);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(prompt, findsNothing);
    expect(await stored(db), nobodyParticipantId);

    await closeGroup(tester);
    await openGroup(tester, db);
    expect(prompt, findsNothing);
    await closeGroup(tester);
  });

  testWidgets('a refresh neither stacks a second prompt nor brings it back after answering',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(group);

    await openGroup(tester, db);
    expect(prompt, findsOneWidget);
    await db.cacheGroup(const Group(
        id: 'g1', name: 'Banff Trip (renamed)', currency: '\$', participants: [
      Participant(id: 'alex', name: 'Alex'),
      Participant(id: 'bea', name: 'Bea'),
    ]));
    await tester.pumpAndSettle();
    expect(prompt, findsOneWidget);

    await tester.tap(find.text('Alex'));
    await tester.pumpAndSettle();
    await db.cacheGroup(group);
    await tester.pumpAndSettle();
    expect(prompt, findsNothing);
    expect(await stored(db), 'alex');
    await closeGroup(tester);
  });

  testWidgets('does not ask for a group with no participants', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(const Group(id: 'g1', name: 'Empty', currency: '\$', participants: []));

    await openGroup(tester, db);
    expect(prompt, findsNothing);
    expect(await stored(db), isNull);
    await closeGroup(tester);
  });

  testWidgets('does not ask again when the chosen participant has left the group', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(group);
    await db.setActiveParticipant('g1', 'someone-who-left');

    await openGroup(tester, db);
    expect(prompt, findsNothing);
    await closeGroup(tester);
  });

  testWidgets('with nobody set, the Stats hint opens the picker; dismissing it there changes nothing',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(group);
    await db.setActiveParticipant('g1', nobodyParticipantId);
    // Stats shows an empty state, without the hint, until there's an expense.
    await db.replaceServerExpenses('g1', [coffee()]);

    await openGroup(tester, db);
    await tester.tap(find.text('Stats'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(statsHint));
    await tester.pumpAndSettle();
    expect(prompt, findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(await stored(db), nobodyParticipantId);

    await tester.tap(find.text(statsHint));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(SimpleDialog), matching: find.text('Alex')));
    await tester.pumpAndSettle();
    expect(await stored(db), 'alex');
    expect(find.text(statsHint), findsNothing);
    await closeGroup(tester);
  });

  testWidgets('the You row on Balances changes who you are, and the section follows (#99)',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(group);
    await db.setActiveParticipant('g1', nobodyParticipantId);

    await openGroup(tester, db);
    await tester.tap(find.text('Balance'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Nobody'), findsOneWidget);

    await tester.tap(find.widgetWithText(ListTile, 'You'));
    await tester.pumpAndSettle();
    expect(prompt, findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(SimpleDialog), matching: find.text('Alex')));
    await tester.pumpAndSettle();

    expect(await stored(db), 'alex');
    expect(find.widgetWithText(ListTile, 'Nobody'), findsNothing);
    expect(find.text('You’re settled up'), findsOneWidget);
    await closeGroup(tester);
  });

  testWidgets('French at double text size on a narrow phone: the prompt wraps long labels (#87 review)',
      (tester) async {
    useNarrowLargeText(tester);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(const Group(id: 'g1', name: 'Banff', currency: '\$', participants: [
      Participant(id: 'alex', name: 'Alex'),
      Participant(id: 'bart', name: 'Bartholomew Montgomery-Fitzgerald'),
    ]));

    await openGroup(tester, db, locale: const Locale('fr'));
    expect(find.text('Qui êtes-vous ?'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.text('Je ne suis pas dans la liste')).right,
        lessThanOrEqualTo(360));
    await closeGroup(tester);
  });

  // The Stats button shows the same picker with the current choice
  // checked. Rendered directly: at this size the Stats tab behind it has
  // its own, separate layout overflow.
  for (final checkedId in [nobodyParticipantId, 'bart']) {
    testWidgets('French at double text size on a narrow phone: the picker with "$checkedId" checked fits (#87 review)',
        (tester) async {
      useNarrowLargeText(tester);
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('fr'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ActiveUserPicker(
          participants: const [
            Participant(id: 'alex', name: 'Alex'),
            Participant(id: 'bart', name: 'Bartholomew Montgomery-Fitzgerald'),
          ],
          checkedId: checkedId,
        ),
      ));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.check), findsOneWidget);
      for (final label in ['Je ne suis pas dans la liste', 'Bartholomew Montgomery-Fitzgerald']) {
        expect(tester.getRect(find.text(label)).right, lessThanOrEqualTo(360));
      }
    });
  }
}
