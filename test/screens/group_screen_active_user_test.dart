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
import 'package:spliit2go/screens/group_screen.dart';
import 'package:spliit2go/services/active_user.dart';
import 'package:spliit2go/services/settings_service.dart';
import 'package:spliit2go/sync/outbox.dart';
import 'package:spliit2go/theme.dart';
import 'package:spliit2go/widgets/active_user_sheet.dart';
import 'package:spliit2go/widgets/expense_list.dart';
import 'package:spliit2go/widgets/group_monogram.dart';
import 'package:spliit2go/widgets/grouped_section.dart';

// The one-time "Who are you?" prompt (issue #85), a sheet since #218.
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

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> openGroup(WidgetTester tester, AppDatabase db,
      {Locale locale = const Locale('en')}) async {
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw http.ClientException('offline')),
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

    // Dismissing from here changes nothing (#85); moved from the Stats
    // hint, which #103 removed.
    await tester.tap(find.widgetWithText(ListTile, 'You'));
    await tester.pumpAndSettle();
    expect(prompt, findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(await stored(db), nobodyParticipantId);

    await tester.tap(find.widgetWithText(ListTile, 'You'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(ActiveUserPicker), matching: find.text('Alex')));
    await tester.pumpAndSettle();

    expect(await stored(db), 'alex');
    expect(find.widgetWithText(ListTile, 'Nobody'), findsNothing);
    expect(find.text('You’re settled up'), findsOneWidget);
    await closeGroup(tester);
  });

  testWidgets('slides up as a sheet with no Cancel button; a drag down dismisses it (#218)',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(group);

    await openGroup(tester, db);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    await tester.fling(prompt, const Offset(0, 600), 2000);
    await tester.pumpAndSettle();
    expect(prompt, findsNothing);
    expect(await stored(db), nobodyParticipantId);
    await closeGroup(tester);
  });

  testWidgets('use-this-name starts on while no name is set; turned off, the pick sets none (#218)',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(group);

    await openGroup(tester, db);
    final remember = find.byType(Switch);
    expect(tester.widget<Switch>(remember).value, isTrue);
    expect(find.text('Groups you open or join later pick you by this name, without asking.'),
        findsOneWidget);
    await tester.tap(find.text('Use this name in new groups'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(remember).value, isFalse);

    await tester.tap(find.text('Bea'));
    await tester.pumpAndSettle();
    expect(await stored(db), 'bea');
    expect(await SettingsService().defaultActiveUserName(), isNull);
    await closeGroup(tester);
  });

  testWidgets('use-this-name starts off once a name is set; a pick keeps it, unless turned on (#218)',
      (tester) async {
    // "Kenneth" matches nobody here, so the group asks.
    SharedPreferences.setMockInitialValues({'default_active_user_name': 'Kenneth'});
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(group);

    await openGroup(tester, db);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.textContaining('Now “Kenneth”'), findsOneWidget);
    await tester.tap(find.text('Alex'));
    await tester.pumpAndSettle();
    expect(await stored(db), 'alex');
    expect(await SettingsService().defaultActiveUserName(), 'Kenneth');

    // From the You row on Balances, turned on: the name becomes Bea's.
    await tester.tap(find.text('Balance'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'You'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(ActiveUserPicker), matching: find.text('Bea')));
    await tester.pumpAndSettle();
    expect(await stored(db), 'bea');
    expect(await SettingsService().defaultActiveUserName(), 'Bea');
    await closeGroup(tester);
  });

  testWidgets('Nobody never sets the name, even with use-this-name on (#218)', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.cacheGroup(group);

    await openGroup(tester, db);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    await tester.tap(find.text('Nobody'));
    await tester.pumpAndSettle();
    expect(await SettingsService().defaultActiveUserName(), isNull);
    await closeGroup(tester);
  });

  testWidgets('monograms in the expense rows\' colors, you in emerald; the choice checked, also for screen readers (#218)',
      (tester) async {
    const participants = [
      Participant(id: 'alex', name: 'Alex'),
      Participant(id: 'bea', name: 'Bea Chan'),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: spliit2goLightTheme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(
          body: ActiveUserPicker(participants: participants, checkedId: 'bea', defaultName: 'Bea Chan')),
    ));
    await tester.pumpAndSettle();
    final colors = participantColors(participants, 'bea');
    expect(colors['bea'], monogramPalette[0]);
    final monograms = tester.widgetList<Monogram>(find.byType(Monogram)).toList();
    expect({for (final m in monograms) m.name: m.color}, {'Alex': colors['alex'], 'Bea Chan': colors['bea']});
    expect(find.text('BC'), findsOneWidget);
    // The line between the rows starts where the names do.
    final line = find.descendant(of: find.byType(GroupedSection).first, matching: find.byType(GroupedDivider));
    expect(tester.getTopLeft(line).dx + tester.widget<GroupedDivider>(line).indent,
        tester.getTopLeft(find.text('Alex')).dx);

    final check = tester.getRect(find.byIcon(Icons.check));
    expect(check.center.dy, closeTo(tester.getCenter(find.text('Bea Chan')).dy, 1));
    expect(tester.widget<Icon>(find.byIcon(Icons.check)).color, spliit2goLightTheme.colorScheme.primary);

    final handle = tester.ensureSemantics();
    expect(tester.getSemantics(find.text('Bea Chan')),
        isSemantics(hasCheckedState: true, isChecked: true, isInMutuallyExclusiveGroup: true));
    for (final other in ['Alex', 'Nobody']) {
      expect(tester.getSemantics(find.text(other)),
          isSemantics(hasCheckedState: true, isChecked: false, isInMutuallyExclusiveGroup: true));
    }
    handle.dispose();
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
        home: Scaffold(
          body: ActiveUserPicker(
            participants: const [
              Participant(id: 'alex', name: 'Alex'),
              Participant(id: 'bart', name: 'Bartholomew Montgomery-Fitzgerald'),
            ],
            checkedId: checkedId == 'bart' ? 'bart' : nobodyParticipantId,
            defaultName: 'Alex',
          ),
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
