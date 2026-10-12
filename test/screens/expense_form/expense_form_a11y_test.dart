import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsData;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spliit2go/api/spliit_client.dart';
import 'package:spliit2go/db/app_database.dart';
import 'package:spliit2go/l10n/app_localizations.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/expense_form/currency_card.dart';
import 'package:spliit2go/screens/expense_form/split_card.dart';
import 'package:spliit2go/screens/expense_screen.dart';
import 'package:spliit2go/services/exchange_rates.dart';
import 'package:spliit2go/sync/outbox.dart';
import 'package:spliit2go/theme.dart';
import 'package:spliit2go/widgets/grouped_section.dart';
import 'package:spliit2go/widgets/segmented_pill.dart';

// #263: the form passes Flutter's tap-target and label guidelines, for an
// expense, a converted expense and a settlement.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const lisbon = Group(
    id: 'g4',
    name: 'Lisbon',
    currency: '€',
    currencyCode: 'EUR',
    participants: [
      Participant(id: 'alex', name: 'Alex'),
      Participant(id: 'bea', name: 'Bea'),
    ],
  );

  late _FakeRates rates;

  Future<void> open(WidgetTester tester, TargetPlatform platform) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    ExchangeRates.use(rates = _FakeRates(db));
    final client = SpliitClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((req) async => throw http.ClientException('offline')),
    );
    await db.cacheGroup(lisbon);
    await tester.pumpWidget(MaterialApp(
      theme: spliit2goLightTheme.copyWith(platform: platform),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ExpenseScreen(client: client, db: db, outbox: Outbox(db, client, groupId: lisbon.id), group: lisbon),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> converted(WidgetTester tester) async {
    await tester.ensureVisible(find.widgetWithText(GroupedRow, 'Paid in'));
    await tester.tap(find.widgetWithText(GroupedRow, 'Paid in'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Search currency...'), 'Yen');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Japanese Yen (JPY)'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(CurrencyCard.amountFieldKey), '1000');
    await tester.pumpAndSettle();
  }

  Future<void> settlement(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Switch to settlement'));
    await tester.pumpAndSettle();
  }

  // A rate typed over the published one offers it back.
  Future<void> typedRate(WidgetTester tester) async {
    await converted(tester);
    await tester.enterText(find.byKey(CurrencyCard.rateFieldKey), '0.007');
    await tester.pumpAndSettle();
    expect(find.text('Use the published rate'), findsOneWidget);
  }

  Future<void> byPercent(WidgetTester tester) async {
    await tester.enterText(find.byKey(CurrencyCard.amountFieldKey), '30');
    await tester.tap(find.text('Percent'));
    await tester.pumpAndSettle();
  }

  // Each platform's own size: Android's 48, iOS's 44 (#263).
  final guidelines = {
    TargetPlatform.android: [androidTapTargetGuideline, labeledTapTargetGuideline],
    TargetPlatform.iOS: [iOSTapTargetGuideline, labeledTapTargetGuideline],
  };
  for (final MapEntry(key: platform, value: checks) in guidelines.entries) {
    for (final (name, setUpForm) in <(String, Future<void> Function(WidgetTester))>[
      ('an expense', (_) async {}),
      ('a split by percent', byPercent),
      ('a converted expense', converted),
      ('a typed rate', typedRate),
      ('a settlement', settlement),
    ]) {
      testWidgets('${platform.name}: $name meets the tap-target and label guidelines', (tester) async {
        final handle = tester.ensureSemantics();
        // A phone's width, tall enough for the whole form: nothing is cut
        // off by scrolling, which the guidelines would count as too small.
        tester.view.physicalSize = const Size(390, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await open(tester, platform);
        await setUpForm(tester);
        // Typing leaves an iPhone's ⓧ, which a screen reader doesn't see.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        for (final guideline in checks) {
          await expectLater(tester, meetsGuideline(guideline));
        }
        handle.dispose();
      });
    }
  }

  // #263: what's tappable reaches past what's drawn.
  group('larger targets', () {
    Future<void> tall(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await open(tester, TargetPlatform.android);
    }

    testWidgets('a tap on a person\'s name types their value', (tester) async {
      await tall(tester);
      await byPercent(tester);
      final name = find.descendant(of: find.byType(SplitCard), matching: find.text('Bea')).last;
      await tester.tap(name);
      await tester.pumpAndSettle();
      final field = tester.widget<EditableText>(
          find.descendant(of: find.byKey(SplitCard.valueKey('bea')), matching: find.byType(EditableText)));
      expect(field.focusNode.hasFocus, isTrue);
    });

    testWidgets('a split mode is chosen by a tap just under the pill', (tester) async {
      await tall(tester);
      final shares = tester.getRect(find.text('Shares'));
      // The pill ends 10pt under its text.
      await tester.tapAt(shares.bottomCenter + const Offset(0, 18));
      await tester.pumpAndSettle();
      expect(find.byKey(SplitCard.valueKey('bea')), findsOneWidget);
    });

    testWidgets('"Use the published rate" takes a tap just over its text, which stays in its line', (tester) async {
      await tall(tester);
      await typedRate(tester);
      final text = tester.getRect(find.text('Use the published rate'));
      final note = tester.getRect(find.textContaining('Using the rate you entered'));
      expect(text.top - note.bottom, lessThan(8), reason: 'right under the note');
      await tester.tapAt(text.topCenter - const Offset(0, 10));
      await tester.pumpAndSettle();
      expect(rates.forced, 1);
    });
  });



  // #263: a screen reader can't feel the haptic or see the scroll.
  group('a refused save', () {
    late List<String> said;

    Future<void> openForm(WidgetTester tester) async {
      said = [];
      tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility,
          (message) async {
        final event = message! as Map<Object?, Object?>;
        if (event['type'] == 'announce') said.add((event['data']! as Map<Object?, Object?>)['message']! as String);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility, null));
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await open(tester, TargetPlatform.android);
    }

    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
    }

    SemanticsData row(WidgetTester tester, Finder field) =>
        tester.getSemantics(find.ancestor(of: field, matching: find.byType(MergeSemantics)).first).getSemanticsData();

    testWidgets('says the first thing that\'s wrong', (tester) async {
      final handle = tester.ensureSemantics();
      await openForm(tester);
      await save(tester);
      expect(said, ['Required'], reason: 'the title, at the top');

      await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Lunch');
      await save(tester);
      expect(said.last, 'Enter a valid amount');
      // And it's read with the field.
      expect(row(tester, find.byKey(CurrencyCard.amountFieldKey)).label, contains('Enter a valid amount'));
      handle.dispose();
    });

    testWidgets('says what\'s wrong with the split', (tester) async {
      final handle = tester.ensureSemantics();
      await openForm(tester);
      await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Lunch');
      await byPercent(tester);
      await tester.enterText(find.byKey(SplitCard.valueKey('alex')), '40');
      await tester.enterText(find.byKey(SplitCard.valueKey('bea')), '40');
      await tester.pumpAndSettle();
      await save(tester);
      expect(said, ['Percentages must add up to 100% (20% short)']);
      handle.dispose();
    });

    testWidgets('a title\'s error is read with it', (tester) async {
      final handle = tester.ensureSemantics();
      await openForm(tester);
      await save(tester);
      final title = tester
          .getSemantics(find.descendant(of: find.widgetWithText(TextFormField, 'Title'), matching: find.byType(EditableText)))
          .getSemanticsData();
      expect([title.label, title.hint, title.value].join(' '), contains('Required'));
      handle.dispose();
    });
  });


  // #263: at large text sizes, what doesn't fit goes under or into a menu,
  // measured rather than at a set size.
  group('large text', () {
    Future<void> openAt(WidgetTester tester, double textScale) async {
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await open(tester, TargetPlatform.android);
    }

    Future<void> pick(WidgetTester tester, String mode) async {
      final menu = find.byKey(SplitCard.modeMenuKey);
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text(mode).last);
      await tester.pumpAndSettle();
    }

    testWidgets('the split modes stay a pill while their names fit', (tester) async {
      await openAt(tester, 1.2);
      expect(find.byType(SegmentedPill<SplitMode>), findsOneWidget);
      expect(find.byKey(SplitCard.modeMenuKey), findsNothing);
    });

    testWidgets('and are a menu when they don\'t, which picks one', (tester) async {
      await openAt(tester, 2);
      expect(find.byType(SegmentedPill<SplitMode>), findsNothing);
      final menu = find.byKey(SplitCard.modeMenuKey);
      expect(find.descendant(of: menu, matching: find.text('Evenly')), findsOneWidget);
      // It opens under the value, at its end, not from the row's start.
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      final arrow = tester.getRect(find.descendant(of: menu, matching: find.byIcon(Icons.arrow_drop_down)));
      final opened = tester.getRect(find.ancestor(of: find.text('Shares'), matching: find.byType(Material)).first);
      expect(opened.right, closeTo(arrow.right, 1));
      expect(opened.top, greaterThanOrEqualTo(arrow.bottom - 1));
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      await pick(tester, 'Percent');
      expect(find.descendant(of: menu, matching: find.text('Percent')), findsOneWidget);
      expect(find.byKey(SplitCard.valueKey('bea')), findsOneWidget);
    });

    testWidgets('the receipt language goes under "Scan receipt" when they don\'t fit', (tester) async {
      await openAt(tester, 1);
      expect(tester.getCenter(find.byIcon(Icons.translate)).dy, closeTo(tester.getCenter(find.text('Scan receipt')).dy, 1));
      tester.platformDispatcher.textScaleFactorTestValue = 3;
      await tester.pumpAndSettle();
      final text = tester.getRect(find.text('Scan receipt'));
      expect(tester.getTopLeft(find.byIcon(Icons.translate)).dy, greaterThan(text.bottom));
      // One line, not a word broken over three, with its icon.
      expect(text.height, lessThan(2 * 3 * 16));
      expect(tester.getCenter(find.byIcon(Icons.document_scanner_outlined)).dy, closeTo(text.center.dy, 1));
    });

    testWidgets('a long title wraps, and stays one line of text', (tester) async {
      await openAt(tester, 2);
      final title = find.widgetWithText(TextFormField, 'Title');
      final oneLine = tester.getSize(title).height;
      await tester.enterText(title, 'Dinner at the very long named restaurant\nby the sea');
      await tester.pumpAndSettle();
      expect(tester.getSize(title).height, greaterThan(oneLine));
      expect(tester.widget<TextFormField>(title).controller!.text, 'Dinner at the very long named restaurant by the sea');
    });

    testWidgets('the form meets the guidelines at twice the text size', (tester) async {
      final handle = tester.ensureSemantics();
      await openAt(tester, 2);
      await tester.enterText(find.byKey(CurrencyCard.amountFieldKey), '30');
      await pick(tester, 'Percent');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      for (final guideline in [androidTapTargetGuideline, labeledTapTargetGuideline]) {
        await expectLater(tester, meetsGuideline(guideline));
      }
      handle.dispose();
    });
  });

  // #263: one element a row, each saying what it does.
  testWidgets('Repeat is a button with its value; the receipt language one with its name', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester, TargetPlatform.iOS);
    final repeat = tester.getSemantics(find.text('Repeat')).getSemanticsData();
    expect((repeat.label, repeat.tooltip, repeat.flagsCollection.isButton), ('Repeat\nNever', '', true));
    final language = tester.getSemantics(find.byIcon(Icons.translate)).getSemanticsData();
    expect((language.label, language.tooltip, language.flagsCollection.isButton),
        ('English, Français and other Latin-script languages', 'Receipt language', true));
    expect(tester.getSemantics(find.text('Scan receipt')).getSemanticsData().tooltip, '');
    handle.dispose();
  });

}

class _FakeRates extends ExchangeRates {
  _FakeRates(super.db);

  int forced = 0;

  @override
  Future<ExchangeRate> rate(DateTime date, String from, String to, {bool force = false}) async {
    if (force) forced++;
    return ExchangeRate(rate: 0.0061, publishedOn: DateTime.utc(2026, 10, 1), source: RateSource.ecb, offline: false);
  }
}
