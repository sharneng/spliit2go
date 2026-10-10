import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/models/default_split.dart';
import 'package:spliit2go/models/expense.dart';
import 'package:spliit2go/models/group.dart';
import 'package:spliit2go/screens/expense_form/expense_form_model.dart';

// #258: the add/edit expense form's state and arithmetic, without widgets.
void main() {
  const people = [
    Participant(id: 'alex', name: 'Alex'),
    Participant(id: 'bea', name: 'Bea'),
    Participant(id: 'cy', name: 'Cy'),
  ];
  const euros = Group(id: 'g', name: 'Lisbon', currency: '€', currencyCode: 'EUR', participants: people);
  const yen = Group(id: 'g', name: 'Kyoto', currency: '¥', currencyCode: 'JPY', participants: people);
  const custom = Group(id: 'g', name: 'Camp', currency: 'pts', participants: people);

  ExpenseFormModel model(Group group, {Expense? existing, Expense? draft, String? paidBy}) {
    final m = ExpenseFormModel(group: group, existing: existing, draft: draft, activeUserId: paidBy);
    addTearDown(m.dispose);
    return m;
  }

  Expense expense({
    int amount = 1000,
    SplitMode mode = SplitMode.evenly,
    List<ExpenseShare> paidFor = const [
      ExpenseShare(participantId: 'alex', shares: 100),
      ExpenseShare(participantId: 'bea', shares: 100),
    ],
    bool settlement = false,
    int? originalAmount,
    String? originalCurrency,
    double? rate,
  }) =>
      Expense(
        id: 'e1',
        groupId: 'g',
        title: 'Ramen',
        amountCents: amount,
        paidBy: 'alex',
        paidFor: paidFor,
        splitMode: mode,
        category: 8,
        date: DateTime.utc(2026, 10, 1),
        isSettlement: settlement,
        originalAmountCents: originalAmount,
        originalCurrency: originalCurrency,
        conversionRate: rate,
      );

  group('a new expense', () {
    test('starts with everyone, evenly, paid by the active user', () {
      final m = model(euros, paidBy: 'bea');
      expect(m.paidBy, 'bea');
      expect(m.splitMode, SplitMode.evenly);
      expect(m.includedParticipants.map((p) => p.id), ['alex', 'bea', 'cy']);
      expect(m.paidIn, 'EUR');
      expect(m.converting, isFalse);
      expect(m.amount, isNull);
    });

    test('notifies on typing and on every choice', () {
      final m = model(euros);
      var notified = 0;
      m.addListener(() => notified++);
      m.titleController.text = 'Lunch';
      m.paidBy = 'cy';
      m.splitMode = SplitMode.byShares;
      m.setIncluded('cy', false);
      m.setDate(DateTime(2026, 10, 2));
      expect(notified, 5);
      expect(m.dateChosen, isTrue);
    });

    test('a remembered split applies only while it fits the group', () {
      final m = model(euros);
      m.applyDefaultSplit(const DefaultSplit(splitMode: SplitMode.byShares, shares: {'alex': 200, 'bea': 150}));
      expect(m.splitMode, SplitMode.byShares);
      expect(m.includedParticipants.map((p) => p.id), ['alex', 'bea']);
      expect(m.splitControllers['alex']!.text, '2');
      expect(m.splitControllers['bea']!.text, '1.5');

      final other = model(euros);
      other.applyDefaultSplit(const DefaultSplit(splitMode: SplitMode.byShares, shares: {'zed': 100}));
      expect(other.splitMode, SplitMode.evenly);
    });
  });

  group('amounts in each currency\'s own decimal places (#251)', () {
    test('cents for a euro, whole yen', () {
      final m = model(euros)..amountController.text = '12.34';
      expect(m.amount, 1234);
      final y = model(yen)..amountController.text = '1,000';
      expect(y.amount, 1000);
    });

    test('an amount that rounds to nothing isn\'t positive (#254)', () {
      final m = model(yen);
      expect(m.isPositiveAmount('0.4', 0), isFalse);
      expect(m.isPositiveAmount('1', 0), isTrue);
      expect(m.isPositiveAmount('0.004', 2), isFalse);
    });

    test('the locale\'s separator decides only "1,234" (#238)', () {
      final m = model(euros);
      expect(m.parseDecimal('1,234'), 1234);
      m.decimalSeparator = ',';
      expect(m.parseDecimal('1,234'), 1.234);
      expect(m.parseDecimal('12,50'), 12.5);
    });
  });

  group('conversion (#252)', () {
    test('only a group with an ISO code converts', () {
      final m = model(custom);
      expect(m.hasGroupCurrencyCode, isFalse);
      expect(m.choosePaidIn('JPY'), isTrue);
      expect(m.converting, isFalse);
    });

    test('an expense\'s amount is worked out from the amount paid at the rate', () {
      final m = model(euros)..choosePaidIn('JPY')
        // Written as #252 typed it: 1 yen in euros (#261 shows EUR/JPY).
        ..rateBase = 'JPY';
      expect(m.converting, isTrue);
      expect((m.originalDigits, m.paidInSymbol), (0, '¥'));
      m.originalAmountController.text = '1000';
      expect(m.amount, isNull); // no rate yet
      m.rateController.text = '0.0061';
      expect(m.amount, 610);
      final amounts = m.amountsToSave()!;
      expect((amounts.amount, amounts.originalAmount, amounts.originalCurrency, amounts.conversionRate),
          (610, 1000, 'JPY', 0.0061));
    });

    test('a settlement\'s amount is its To amounts, converted (#262)', () {
      final m = model(euros)
        ..setSettlement(true, title: 'Settlement')
        ..choosePaidIn('JPY')
        // Written as #252 typed it: 1 yen in euros (#261 shows EUR/JPY).
        ..rateBase = 'JPY'
        ..rateController.text = '0.0061';
      m.splitControllers['bea']!.text = '1000';
      expect((m.settlementTotal, m.amount), (1000, 610));
    });

    test('a conversion that rounds to nothing can\'t be saved, until an amount changes', () {
      final m = model(euros)
        ..choosePaidIn('JPY')
        // Written as #252 typed it: 1 yen in euros (#261 shows EUR/JPY).
        ..rateBase = 'JPY'
        ..originalAmountController.text = '1'
        ..rateController.text = '0.001';
      expect(m.amountsToSave(), isNull);
      expect(m.convertedAmountInvalid, isTrue);
      m.titleController.text = 'Gum';
      expect(m.convertedAmountInvalid, isTrue);
      m.originalAmountController.text = '100';
      expect(m.convertedAmountInvalid, isFalse);
      expect(m.amountsToSave()!.amount, 10);
    });

    test('back to the group\'s currency keeps the total and drops the rate', () {
      final m = model(euros)
        ..choosePaidIn('JPY')
        // Written as #252 typed it: 1 yen in euros (#261 shows EUR/JPY).
        ..rateBase = 'JPY'
        ..originalAmountController.text = '1000'
        ..rateController.text = '0.0061';
      expect(m.choosePaidIn('JPY'), isFalse);
      m.choosePaidIn('EUR');
      expect((m.converting, m.amountController.text, m.rateController.text), (false, '6.10', ''));
      expect(m.amountsToSave()!.originalCurrency, isNull);
    });

    test('a published rate fills an empty or auto-filled field, never a typed one', () {
      final m = model(euros)..choosePaidIn('JPY')
        // Written as #252 typed it: 1 yen in euros (#261 shows EUR/JPY).
        ..rateBase = 'JPY';
      expect(m.wantsRate(), isTrue);
      m.fillRate(0.0061, force: false, editsAtRequest: m.rateEdits);
      expect((m.rateController.text, m.rateIsOwn), ('0.0061', false));

      // Another day's rate replaces the auto-filled one.
      m.fillRate(0.0062, force: false, editsAtRequest: m.rateEdits);
      expect(m.rateController.text, '0.0062');

      m.rateTyped();
      m.rateController.text = '0.006';
      expect((m.rateIsOwn, m.rateIsSaved, m.wantsRate(), m.wantsRate(force: true)), (true, false, false, true));
      m.fillRate(0.0063, force: false, editsAtRequest: m.rateEdits);
      expect(m.rateController.text, '0.006');
      m.fillRate(0.0063, force: true, editsAtRequest: m.rateEdits);
      expect(m.rateController.text, '0.0063');
    });

    test('a rate typed while a lookup is on its way wins, whatever it is (#255 review)', () {
      final m = model(euros)..choosePaidIn('JPY')
        // Written as #252 typed it: 1 yen in euros (#261 shows EUR/JPY).
        ..rateBase = 'JPY';
      m.fillRate(0.0061, force: false, editsAtRequest: m.rateEdits);
      final asked = m.rateEdits;
      m.rateTyped();
      m.rateController.text = '0.0061'; // the auto-filled rate, typed back
      m.fillRate(0.0062, force: true, editsAtRequest: asked);
      expect(m.rateController.text, '0.0061');

      // An empty field has nothing to lose.
      m.rateTyped();
      m.rateController.text = '';
      m.fillRate(0.0062, force: true, editsAtRequest: asked);
      expect(m.rateController.text, '0.0062');
    });

    test('a rate shows in 6 significant figures, no exponent, in the locale\'s separator (#261)', () {
      final m = model(euros);
      expect(m.rateNumberText(0.00609756097560976), '0.00609756');
      expect(m.rateNumberText(163.934426), '163.934');
      expect(m.rateNumberText(176.84), '176.84');
      expect(m.rateNumberText(12345678), '12345678');
      m.decimalSeparator = ',';
      expect(m.rateNumberText(0.0061), '0,0061');
    });
  });

  group('editing a conversion keeps what was saved (#255)', () {
    // spliit-web lets its total differ from 1000 × 0.0061 = 610.
    final saved = expense(
      amount: 615,
      mode: SplitMode.byAmount,
      paidFor: const [ExpenseShare(participantId: 'alex', shares: 315), ExpenseShare(participantId: 'bea', shares: 300)],
      originalAmount: 1000,
      originalCurrency: 'JPY',
      rate: 0.0061,
    );

    test('shows the saved rate, once the separator is known', () {
      final m = model(euros, existing: saved)..rateBase = 'JPY';
      expect(m.rateController.text, '');
      m.decimalSeparator = '.';
      expect((m.rateController.text, m.rateIsSaved, m.wantsRate()), ('0.0061', true, false));
    });

    test('keeps the saved total while its inputs read as saved', () {
      final m = model(euros, existing: saved)..rateBase = 'JPY'..decimalSeparator = '.';
      expect(m.conversionUnchanged, isTrue);
      expect(m.amount, 615);
      expect(m.splitProblem(), isNull);
      m.titleController.text = 'Ramen and gyoza';
      expect(m.amountsToSave()!.amount, 615);

      m.originalAmountController.text = '2000';
      expect(m.amount, 1220);
      m.originalAmountController.text = '1000';
      expect(m.amount, 615);

      m.rateTyped();
      m.rateController.text = '0.0062';
      expect(m.amount, 620);
    });

    test('a draft is worked out afresh', () {
      final m = model(euros, draft: saved)..decimalSeparator = '.';
      expect(m.conversionUnchanged, isFalse);
      expect(m.amount, 610);
    });

    test('a settlement keeps its saved amounts and split while untouched (#262)', () {
      final m = model(euros,
          existing: expense(
              amount: 610,
              settlement: true,
              paidFor: const [ExpenseShare(participantId: 'bea', shares: 100)],
              originalAmount: 1001,
              originalCurrency: 'JPY',
              rate: 0.0061))
        ..rateBase = 'JPY'
        ..decimalSeparator = '.';
      expect(m.splitControllers['bea']!.text, '1001');
      m.titleController.text = 'Paid back';
      expect((m.amount, m.amountsToSave()!.originalAmount, m.splitModeToSave), (610, 1001, SplitMode.evenly));
      expect(m.paidFor()!.single.shares, 100);

      m.splitControllers['bea']!.text = '1002';
      expect((m.amount, m.splitModeToSave), (611, SplitMode.byAmount));
      expect(m.paidFor()!.single.shares, 611);
    });

    test('a removed conversion\'s leftovers don\'t count without its currency', () {
      final m = model(euros, existing: expense(originalAmount: 1000, rate: 0.0061))..decimalSeparator = '.';
      expect((m.converting, m.rateController.text), (false, ''));
    });
  });

  group('the rate, the more valuable currency first (#261)', () {
    test('by the ranking: EUR/JPY into a euro group, and into a yen group', () {
      final m = model(euros)..choosePaidIn('JPY');
      expect((m.ratePair, m.rateBaseCode), ('EUR/JPY', 'EUR'));
      m.fillRate(1 / 176.84, force: false, editsAtRequest: m.rateEdits);
      expect(m.rateController.text, '176.84');
      m.amountController.text = '';
      m.originalAmountController.text = '1000';
      expect(m.amount, 565);

      final y = model(yen)..choosePaidIn('EUR');
      expect(y.ratePair, 'EUR/JPY');
      y.fillRate(176.84, force: false, editsAtRequest: y.rateEdits);
      expect((y.rateController.text, y.rate), ('176.84', 176.84));
    });

    test('a currency the ranking doesn\'t know goes second', () {
      final m = model(euros)
        ..ranking = const {'EUR': 1}
        ..choosePaidIn('JPY');
      expect(m.ratePair, 'EUR/JPY');
    });

    test('a swap flips the number; swapped back untouched, it\'s as it was', () {
      final m = model(euros)..choosePaidIn('JPY');
      m.rateTyped();
      m.rateController.text = '177';
      m.swapRatePair();
      expect((m.ratePair, m.rateBaseCode, m.rateController.text), ('JPY/EUR', 'JPY', '0.00564972'));
      expect(m.rate, 0.00564972);
      m.swapRatePair();
      expect((m.ratePair, m.rateController.text), ('EUR/JPY', '177'));
    });

    test('a published rate is shown afresh from its value either way round', () {
      final m = model(euros)..choosePaidIn('JPY');
      m.fillRate(0.00565, force: false, editsAtRequest: m.rateEdits);
      expect(m.rateController.text, '176.991');
      m.swapRatePair();
      expect((m.rateController.text, m.rateIsOwn), ('0.00565', false));
      expect(m.rate, 0.00565);
    });

    test('the device\'s choice for the pair wins over the ranking, until another currency', () {
      final m = model(euros)
        ..choosePaidIn('JPY')
        ..rateBase = 'JPY';
      expect(m.ratePair, 'JPY/EUR');
      m.choosePaidIn('USD');
      expect(m.ratePair, 'EUR/USD');
    });

    test('a saved rate is sent back as stored while untouched (acceptance case 3)', () {
      final m = model(euros, existing: expense(amount: 565, originalAmount: 1000, originalCurrency: 'JPY', rate: 0.00565))
        ..decimalSeparator = '.';
      expect((m.ratePair, m.rateController.text, m.rateIsSaved), ('EUR/JPY', '176.991', true));
      expect(m.rate, 0.00565);
      m.titleController.text = 'Ramen and gyoza';
      expect(m.amountsToSave()!.conversionRate, 0.00565);
      // Swapped there and back, it's still the saved rate.
      m.swapRatePair();
      expect((m.rateController.text, m.rate), ('0.00565', 0.00565));
      m.swapRatePair();
      expect(m.rate, 0.00565);
      // Typed over, it's worked out from what's shown.
      m.rateTyped();
      m.rateController.text = '177';
      expect(m.rate, 1 / 177);
    });
  });

  group('a converted expense split by amount, in the paid-in currency (#261)', () {
    final saved = Expense(
      id: 'e1',
      groupId: 'g',
      title: 'Wine',
      amountCents: 1001,
      paidBy: 'alex',
      paidFor: const [ExpenseShare(participantId: 'alex', shares: 500), ExpenseShare(participantId: 'bea', shares: 501)],
      splitMode: SplitMode.byAmount,
      category: 8,
      date: DateTime.utc(2026, 10, 1),
      originalAmountCents: 566,
      originalCurrency: 'EUR',
      conversionRate: 176.84,
    );

    test('shows each amount in euros, and a title-only edit keeps the yen (acceptance case 2)', () {
      final m = model(yen, existing: saved)..decimalSeparator = '.';
      expect((m.splitTotal, m.splitDigits, m.splitSymbol), (566, 2, '€'));
      expect([m.splitControllers['alex']!.text, m.splitControllers['bea']!.text], ['2.83', '2.83']);
      expect(m.splitProblem(), isNull);
      m.titleController.text = 'Red wine';
      expect(m.paidFor()!.map((s) => s.shares), [500, 501]);
    });

    test('changed, the yen are shared out in proportion and add up', () {
      final m = model(yen, existing: saved)..decimalSeparator = '.';
      m.splitControllers['alex']!.text = '1.66';
      m.splitControllers['bea']!.text = '4';
      expect(m.splitProblem(), isNull);
      final shares = m.paidFor()!.map((s) => s.shares).toList();
      expect(shares, [294, 707]);
      expect(shares.fold(0, (a, b) => a + b), m.amount);
    });

    test('they must add up to the amount paid, said in euros', () {
      final m = model(yen, existing: saved)..decimalSeparator = '.';
      m.splitControllers['bea']!.text = '2.80';
      expect(m.unallocated(), closeTo(0.03, 1e-9));
      expect(m.splitProblem(), isA<AmountsDontAddUp>().having((p) => p.difference, 'difference', 3));
    });
  });

  group('editing fills every field', () {
    test('shares and percentages back from hundredths, amounts in the group\'s digits', () {
      final shares = model(euros,
          existing: expense(mode: SplitMode.byShares, paidFor: const [
            ExpenseShare(participantId: 'alex', shares: 150),
            ExpenseShare(participantId: 'cy', shares: 100),
          ]));
      expect(shares.includedParticipants.map((p) => p.id), ['alex', 'cy']);
      expect((shares.splitControllers['alex']!.text, shares.splitControllers['cy']!.text), ('1.5', '1'));
      // Not in it: no value, so not included (#260).
      expect(shares.splitControllers['bea']!.text, '');

      final amounts = model(yen,
          existing: expense(mode: SplitMode.byAmount, paidFor: const [
            ExpenseShare(participantId: 'alex', shares: 600),
            ExpenseShare(participantId: 'bea', shares: 400),
          ]));
      expect((amounts.amountController.text, amounts.splitControllers['alex']!.text), ('1000', '600'));
    });

    test('evenly\'s stored 100s come back as 1 (#34)', () {
      final m = model(euros, existing: expense());
      expect(m.splitControllers['alex']!.text, '1');
      expect((m.titleController.text, m.paidBy, m.category, m.date), ('Ramen', 'alex', 8, DateTime.utc(2026, 10, 1)));
    });
  });

  group('the split', () {
    test('evenly: everyone included gets an equal part, the extra cent to someone', () {
      final m = model(euros)..amountController.text = '10';
      expect(m.livePreviewAmounts()!.values.fold<int>(0, (a, b) => a + b), 1000);
      expect(m.paidFor()!.map((s) => (s.participantId, s.shares)), [('alex', 1), ('bea', 1), ('cy', 1)]);
    });

    test('nobody included is a problem', () {
      final m = model(euros)..toggleSelectAll();
      expect(m.allIncluded, isFalse);
      expect(m.splitProblem(), isA<NoOneIncluded>());
      expect(m.paidFor(), isNull);
      m.toggleSelectAll();
      expect(m.allIncluded, isTrue);
    });

    test('shares: decimals x100, and one that isn\'t a number names who', () {
      final m = model(euros)
        ..amountController.text = '10'
        ..splitMode = SplitMode.byShares;
      m.splitControllers['cy']!.text = '';
      m.splitControllers['alex']!.text = '1.5';
      m.splitControllers['bea']!.text = 'x';
      expect((m.splitProblem() as InvalidValue).participant.id, 'bea');
      expect(m.showsLivePreview, isFalse);
      m.splitControllers['bea']!.text = '0.5';
      expect(m.paidFor()!.map((s) => s.shares), [150, 50]);
      expect(m.livePreviewAmounts(), {'alex': 750, 'bea': 250});
    });

    test('percent: must come to exactly 100, in basis points', () {
      final m = model(euros)
        ..amountController.text = '10'
        ..splitMode = SplitMode.byPercentage;
      for (final p in people) {
        m.splitControllers[p.id]!.text = '33.33';
      }
      expect((m.splitProblem() as PercentagesDontAddUp).totalBasisPoints, 9999);
      expect(m.unallocated(), closeTo(0.01, 1e-9));
      expect(m.showsLivePreview, isFalse);
      m.splitControllers['cy']!.text = '33.34';
      expect(m.splitProblem(), isNull);
      expect(m.paidFor()!.map((s) => s.shares), [3333, 3333, 3334]);
      expect(m.showsLivePreview, isTrue);
    });

    test('amount: must add up to the total, in the group\'s digits', () {
      final m = model(yen)
        ..amountController.text = '1000'
        ..splitMode = SplitMode.byAmount;
      m.splitControllers['cy']!.text = '';
      m.splitControllers['alex']!.text = '600';
      m.splitControllers['bea']!.text = '300';
      expect((m.splitProblem() as AmountsDontAddUp).difference, 100);
      expect(m.unallocated(), 100);
      expect(m.showsLivePreview, isFalse);
      m.splitControllers['bea']!.text = '400';
      expect(m.paidFor()!.map((s) => s.shares), [600, 400]);
    });

    test('a converted expense\'s amounts are in yen; the calculated total is shared out (#261)', () {
      final m = model(euros)
        ..choosePaidIn('JPY')
        // Written as #252 typed it: 1 yen in euros (#261 shows EUR/JPY).
        ..rateBase = 'JPY'
        ..originalAmountController.text = '1000'
        ..rateController.text = '0.0061'
        ..splitMode = SplitMode.byAmount;
      m.splitControllers['cy']!.text = '0';
      m.splitControllers['alex']!.text = '500';
      m.splitControllers['bea']!.text = '500';
      expect(m.splitProblem(), isNull);
      expect(m.paidFor()!.map((s) => s.shares), [305, 305]);
    });

    test('a settlement shows no live preview', () {
      final m = model(euros)
        ..amountController.text = '10'
        ..setSettlement(true, title: 'Settlement');
      expect(m.livePreviewAmounts(), isNull);
    });
  });

  group('switching modes keeps who\'s included (#260)', () {
    List<String> values(ExpenseFormModel m) => [for (final p in people) m.splitControllers[p.id]!.text];

    test('from Evenly: 1 share, equal percentages, equal amounts; the rest empty', () {
      final m = model(euros)
        ..amountController.text = '10'
        ..setIncluded('bea', false);
      m.splitMode = SplitMode.byShares;
      expect(values(m), ['1', '', '1']);
      expect(m.includedParticipants.map((p) => p.id), ['alex', 'cy']);
      m.splitMode = SplitMode.evenly;
      m.setIncluded('bea', true);
      m.splitMode = SplitMode.byPercentage;
      // The basis point left over goes to the first.
      expect(values(m), ['33.34', '33.33', '33.33']);
      expect(m.splitProblem(), isNull);
      m.splitMode = SplitMode.evenly;
      m.splitMode = SplitMode.byAmount;
      expect(values(m), ['3.34', '3.33', '3.33']);
      expect(m.splitProblem(), isNull);
    });

    test('in the locale\'s separator', () {
      final m = model(euros)
        ..decimalSeparator = ','
        ..amountController.text = '10'
        ..splitMode = SplitMode.byAmount;
      expect(values(m), ['3,34', '3,33', '3,33']);
      expect(m.splitProblem(), isNull);
    });

    test('Amount with no total yet is empty, and back in Evenly the checks stay', () {
      final m = model(euros)
        ..setIncluded('cy', false)
        ..splitMode = SplitMode.byAmount;
      expect(values(m), ['', '', '']);
      m.splitMode = SplitMode.evenly;
      expect(m.includedParticipants.map((p) => p.id), ['alex', 'bea']);
    });

    test('back to Evenly, anyone above 0 is checked', () {
      final m = model(euros)..splitMode = SplitMode.byShares;
      m.splitControllers['alex']!.text = '0';
      m.splitControllers['bea']!.text = '';
      m.splitControllers['cy']!.text = '2';
      expect(m.includedParticipants.map((p) => p.id), ['cy']);
      m.splitMode = SplitMode.evenly;
      expect(m.includedParticipants.map((p) => p.id), ['cy']);
      m.splitMode = SplitMode.byShares;
      expect(values(m), ['', '', '1']);
    });

    test('there and back is no change; a value typed on the way still is (#266)', () {
      final m = model(euros)..amountController.text = '10';
      m.markUnchanged();
      m.splitMode = SplitMode.byShares;
      expect(m.hasChanges, isTrue);
      m.splitMode = SplitMode.evenly;
      expect(m.hasChanges, isFalse);

      m.splitMode = SplitMode.byShares;
      m.splitControllers['cy']!.text = '';
      m.splitMode = SplitMode.evenly;
      expect(m.hasChanges, isTrue, reason: 'cy is no longer included');
    });

    test('tells listeners once', () {
      final m = model(euros)..amountController.text = '10';
      var notified = 0;
      m.addListener(() => notified++);
      m.splitMode = SplitMode.byAmount;
      expect(notified, 1);
    });
  });

  group('changes, for "Discard changes?" (#259)', () {
    test('typing, picking and choosing are changes; undoing them isn\'t', () {
      final m = model(euros);
      expect(m.hasChanges, isFalse);
      m.titleController.text = 'Lunch';
      expect(m.hasChanges, isTrue);
      m.titleController.text = '';
      expect(m.hasChanges, isFalse);
      m.setSettlement(true, title: 'Settlement');
      expect(m.hasChanges, isTrue);
      m.setSettlement(false, title: 'Settlement');
      expect(m.hasChanges, isFalse);
      m.setIncluded('cy', false);
      expect(m.hasChanges, isTrue);
    });

    test('a remembered split and an edit\'s saved rate are where the form starts', () {
      final m = model(euros)
        ..applyDefaultSplit(const DefaultSplit(splitMode: SplitMode.byShares, shares: {'alex': 200, 'bea': 100}));
      expect(m.hasChanges, isFalse);

      final edit = model(euros, existing: expense(originalAmount: 1000, originalCurrency: 'JPY', rate: 0.0061))
        ..rateBase = 'JPY'
        ..decimalSeparator = '.';
      expect((edit.rateController.text, edit.hasChanges), ('0.0061', false));
      edit.rateTyped();
      edit.rateController.text = '0.0062';
      expect(edit.hasChanges, isTrue);
    });

    test('a published rate filled in isn\'t the user\'s change; picking the currency is', () {
      final m = model(euros)..choosePaidIn('JPY')
        // Written as #252 typed it: 1 yen in euros (#261 shows EUR/JPY).
        ..rateBase = 'JPY';
      expect(m.hasChanges, isTrue);
      m.markUnchanged();
      m.fillRate(0.0061, force: false, editsAtRequest: m.rateEdits);
      expect(m.hasChanges, isFalse);
    });
  });

  group('a settlement (#262)', () {
    // Bob owes Alice ¥1,000; Balances' "Mark as paid" opens this.
    final markAsPaid = Expense(
      id: '',
      groupId: 'g',
      title: 'Bea paid Alex',
      amountCents: 1000,
      paidBy: 'bea',
      paidFor: const [ExpenseShare(participantId: 'alex', shares: 1)],
      splitMode: SplitMode.evenly,
      date: DateTime.utc(2026, 10, 1),
      isSettlement: true,
    );

    test('Mark as paid saves the balance exactly, until a To amount is typed (acceptance case 1)', () {
      final m = model(yen, draft: markAsPaid)..decimalSeparator = '.';
      expect((m.splitMode, m.splitControllers['alex']!.text, m.amount), (SplitMode.byAmount, '1000', 1000));

      m.choosePaidIn('EUR');
      expect((m.splitControllers['alex']!.text, m.amount), ('', 1000));
      m.fillRate(176.84, force: false, editsAtRequest: m.rateEdits);
      expect(m.rateController.text, '176.84');
      expect(m.splitControllers['alex']!.text, '5.65');
      expect(m.splitProblem(), isNull);
      final saved = m.amountsToSave()!;
      expect((saved.amount, saved.originalAmount), (1000, 565));
      expect(m.paidFor()!.map((s) => (s.participantId, s.shares)), [('alex', 1000)]);

      // Another rate fills it in again.
      m.rateTyped();
      m.rateController.text = '180';
      expect((m.splitControllers['alex']!.text, m.amount), ('5.56', 1000));
      m.rateController.text = '176.84';

      // Typed, the forward conversion takes over.
      m.splitControllers['alex']!.text = '5.66';
      expect((m.amount, m.amountsToSave()!.originalAmount), (1001, 566));
      expect(m.paidFor()!.single.shares, 1001);
    });

    test('adding a recipient ends Mark as paid\'s balance too', () {
      final m = model(yen, draft: markAsPaid)..decimalSeparator = '.';
      m.splitControllers['cy']!.text = '500';
      expect((m.amount, m.settlementTotal), (1500, 1500));
      expect(m.paidFor()!.map((s) => s.shares), [1000, 500]);
    });

    test('several recipients, converted: the shares add up to the amount exactly', () {
      final m = model(euros)
        ..setSettlement(true, title: 'Settlement')
        ..choosePaidIn('JPY')
        ..rateBase = 'JPY'
        ..rateController.text = '0.0061';
      m.splitControllers['alex']!.text = '3000';
      m.splitControllers['bea']!.text = '1001';
      expect((m.settlementTotal, m.amount), (4001, 2441));
      final shares = m.paidFor()!.map((s) => s.shares).toList();
      expect(shares, [1830, 611]);
      expect(shares.fold(0, (a, b) => a + b), 2441);
    });

    test('To amounts moved between people are worked out afresh, though the sum is the same (#271 review)', () {
      final m = model(euros,
          existing: expense(
              amount: 615,
              settlement: true,
              mode: SplitMode.byAmount,
              paidFor: const [ExpenseShare(participantId: 'alex', shares: 300), ExpenseShare(participantId: 'bea', shares: 315)],
              originalAmount: 1000,
              originalCurrency: 'JPY',
              rate: 0.0061))
        ..rateBase = 'JPY'
        ..decimalSeparator = '.';
      expect(m.amount, 615);
      m.splitControllers['alex']!.text = '400';
      m.splitControllers['bea']!.text = '600';
      expect(m.amountsToSave()!.amount, 610);
      expect(m.paidFor()!.map((s) => s.shares), [244, 366]);
    });

    test('a corrected To amount clears "rounds to nothing" (#271 review)', () {
      final m = model(euros)
        ..setSettlement(true, title: 'Settlement')
        ..choosePaidIn('JPY')
        ..rateBase = 'JPY'
        ..rateController.text = '0.001';
      m.splitControllers['alex']!.text = '1';
      expect(m.amountsToSave(), isNull);
      expect(m.convertedAmountInvalid, isTrue);
      m.splitControllers['alex']!.text = '1000';
      expect(m.convertedAmountInvalid, isFalse);
      expect(m.amountsToSave()!.amount, 100);
    });

    test('a recipient\'s amount must be at least a smallest unit; someone must have one', () {
      final m = model(euros)..setSettlement(true, title: 'Settlement');
      expect(m.splitProblem(), isA<NoOneIncluded>());
      m.splitControllers['alex']!.text = '0.001';
      expect(m.splitProblem(), isA<InvalidValue>());
      m.splitControllers['alex']!.text = '5';
      expect((m.splitProblem(), m.amount, m.unallocated()), (null, 500, null));
    });

    test('switching there and back brings the split and an untouched title back', () {
      final m = model(euros)..splitMode = SplitMode.byShares;
      m.splitControllers['alex']!.text = '2';
      m.setSettlement(true, title: 'Settlement');
      expect((m.titleController.text, m.splitMode, m.includedParticipants.length), ('Settlement', SplitMode.byAmount, 0));
      m.splitControllers['bea']!.text = '7';
      m.setSettlement(false, title: 'Settlement');
      expect((m.titleController.text, m.splitMode, m.splitControllers['alex']!.text), ('', SplitMode.byShares, '2'));
      m.setSettlement(true, title: 'Settlement');
      expect(m.splitControllers['bea']!.text, '7');

      // A title typed over it stays.
      m.titleController.text = 'Paid back';
      m.setSettlement(false, title: 'Settlement');
      expect(m.titleController.text, 'Paid back');
    });

    test('an edited settlement switched to an expense splits evenly between its recipients', () {
      final m = model(euros,
          existing: expense(
              amount: 900,
              settlement: true,
              mode: SplitMode.byAmount,
              paidFor: const [ExpenseShare(participantId: 'bea', shares: 600), ExpenseShare(participantId: 'cy', shares: 300)]));
      m.setSettlement(false, title: 'Settlement');
      expect((m.splitMode, m.includedParticipants.map((p) => p.id).join(','), m.amountController.text),
          (SplitMode.evenly, 'bea,cy', '9.00'));
    });
  });

  group('a settlement\'s category (#259)', () {
    test('a new one is a Payment, whatever was picked; switching back brings the pick back', () {
      final m = model(euros)..setCategory(8);
      m.setSettlement(true, title: 'Settlement');
      expect(m.categoryToSave, ExpenseFormModel.paymentCategoryId);
      m.setSettlement(false, title: 'Settlement');
      expect(m.categoryToSave, 8);
    });

    test('an edit never changes it', () {
      final settlement = model(euros, existing: expense(settlement: true));
      expect(settlement.categoryToSave, 8);
      final switched = model(euros, existing: expense())..setSettlement(true, title: 'Settlement');
      expect(switched.categoryToSave, 8);
    });
  });

  test('trimTrailingZeros', () {
    expect([trimTrailingZeros(1.5), trimTrailingZeros(2), trimTrailingZeros(33.333)], ['1.5', '2', '33.33']);
  });
}
