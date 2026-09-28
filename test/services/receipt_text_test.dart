import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/models/category.dart';
import 'package:spliit2go/services/receipt_text.dart';

// Issue #125: spliit-ios's ReceiptScanTests (80b2e98), ported, and the
// rules #125 adds for what the parser can't be sure of.
void main() {
  final today = DateTime(2025, 3, 20);

  /// A till receipt of the usual shape: a name, an address, the items,
  /// and the subtotal / tax / total at the bottom (spliit-ios).
  const receipt = '''
CAFÉ DU COIN
12 rue de la Paix
75002 Paris
01 42 61 00 00

14/03/2025  13:42

Café                 3,50
Croissant            2,40
Sandwich             8,60
SOUS-TOTAL          14,50
TVA 10%              1,45
TOTAL               15,95
CARTE               15,95''';

  ReceiptScan read(String text, {List<Category> categories = const []}) =>
      readReceipt(text, categories: categories, today: today);

  group('reading a receipt', () {
    test('the total is the total, not the subtotal or the tax', () {
      final total = read(receipt).total!;
      expect((total.cents, total.sure, total.currency), (1595, true, null));
    });

    test('the merchant is the line above the address', () {
      expect(read(receipt).title, 'Café Du Coin');
    });

    test('the date is the one printed on it', () {
      final scan = read(receipt);
      expect((scan.date, scan.dateText), (DateTime(2025, 3, 14), '14/03/2025'));
    });

    test('a date far outside the plausible window is ignored', () {
      expect(receiptDate('© 1999 Some Company 01/01/1999', today: today), isNull);
      expect(receiptDate('Valid until 12/2038', today: today), isNull);
      expect(receiptDate('Expires 01/01/2038', today: today), isNull);
    });

    test('nothing readable is nothing found, not a wrong answer', () {
      expect(read('').isEmpty, isTrue);
      expect(read('¬¬¬ ### ¬¬¬').isEmpty, isTrue);
    });

    test('an English receipt reads the same as a French one', () {
      final scan = read('''
THE CORNER PUB
42 Long Street

Subtotal        \$18.00
Sales Tax        \$1.62
Amount Due      \$19.62''');
      expect(scan.total!.cents, 1962);
      expect(scan.total!.currency!.mark, r'$');
      expect(scan.title, 'The Corner Pub');
    });
  });

  group('numbers', () {
    // Which separator is the decimal point is decided by the receipt, not
    // the phone: a French bill read on an American phone is still 15.95.
    for (final (printed, cents, hasCents) in [
      ('15,95', 1595, true),
      ('15.95', 1595, true),
      ('1 234,56', 123456, true),
      ('1,234.56', 123456, true),
      ('1.234,56', 123456, true),
      ("1'234.50", 123450, true),
      ('12', 1200, false),
      ('1.000.000', 100000000, false),
      ('3,5', 350, false),
    ]) {
      test('$printed is read as printed', () {
        final a = receiptAmounts(printed).single;
        expect((a.cents, a.hasCents, a.ambiguous), (cents, hasCents, false));
      });
    }

    test('a line gives up every number on it, in order', () {
      expect([for (final a in receiptAmounts('TOTAL 3 items    15,95')) a.cents], [300, 1595]);
      expect([for (final a in receiptAmounts('12 rue de la Paix')) a.cents], [1200]);
      expect(receiptAmounts('no numbers here'), isEmpty);
    });

    test('numbers a row puts side by side stay two numbers', () {
      // Rows are joined with three spaces; a quantity isn't a thousand.
      expect([for (final a in receiptAmounts('Café   2   7,00')) a.cents], [200, 700]);
    });

    test('the largest of the lines that name a total wins', () {
      expect(receiptTotal(['TOTAL TAX      1.45', 'TOTAL (incl. tax)   15.95', 'CASH   20.00'])!.cents, 1595);
    });

    test('a percentage is not an amount', () {
      expect([for (final a in receiptAmounts('TVA 20%   1,45')) a.cents], [145]);
      expect(receiptAmounts('Service 12,5 %'), isEmpty);
      expect(receiptTotal(['TOTAL TVA 20%  1,45', 'TOTAL  8,70'])!.cents, 870);
    });

    test('a keyword matches a word, not a fragment of one', () {
      expect(receiptTotal(['TOTAL EXCHANGE  15,95'])!.cents, 1595);
      expect(receiptMerchant(['Border Cafe']), 'Border Cafe');
    });
  });

  group('what the parser is not sure of (#125)', () {
    test('a total no line names is only a guess: offered, not sure', () {
      // 75002 is a postcode and 12 a house number: neither has cents.
      final total = receiptTotal(['Chez Nous', '12 rue de la Paix', '75002 Paris', 'Café 3,50', 'Repas 24,00'])!;
      expect((total.cents, total.sure), (2400, false));
    });

    test('1.234 alone can be a thousand or one and a bit: not sure', () {
      for (final printed in ['1.234', '1,234']) {
        final total = receiptTotal(['TOTAL  $printed'])!;
        expect((total.text, total.sure), (printed, false), reason: printed);
      }
    });

    test('the receipt\'s own prices decide it', () {
      // Cents after a comma: the dot groups thousands.
      final total = receiptTotal(['Hotel 2 nights  1.180,00', 'Taxe de séjour  54,00', 'TOTAL  1.234'])!;
      expect((total.cents, total.sure), (123400, true));
      // Cents after a dot, and a dot here: three decimals, or a typo.
      expect(receiptTotal(['Wine  12.50', 'TOTAL  1.234'])!.sure, isFalse);
    });

    test('an ambiguous number that could be the largest makes the total unsure', () {
      final total = receiptTotal(['TOTAL POINTS  1,234', 'TOTAL  15,95'])!;
      expect((total.cents, total.sure), (123400, false));
    });

    test('one that is smaller either way doesn\'t matter', () {
      final total = receiptTotal(['TOTAL  1,234', 'TOTAL  1.595,00'])!;
      expect((total.cents, total.sure), (159500, true));
    });

    test('03/04/25 reads two ways: printed, not read', () {
      final date = receiptDate('Date 03/04/25 10:12', today: DateTime(2025, 6, 1))!;
      expect((date.text, date.date), ('03/04/25', null));
    });

    test('a day past 12 decides it, and so does the plausible window', () {
      expect(receiptDate('03/14/25', today: today)!.date, DateTime(2025, 3, 14));
      // 4 March, or 3 April: April is still to come on 20 March.
      expect(receiptDate('03/04/25', today: today)!.date, DateTime(2025, 3, 4));
      // A dotted date is day first.
      expect(receiptDate('03.04.2025', today: DateTime(2025, 6, 1))!.date, DateTime(2025, 4, 3));
      expect(receiptDate('2025-03-04', today: today)!.date, DateTime(2025, 3, 4));
    });

    test('dates with month names, in English and French', () {
      for (final printed in ['14 Mar 2025', '14 mars 2025', 'Mar 14, 2025', '14-MAR-25', '14 MARS 2025', '1er mars 2025']) {
        expect(receiptDate('Le $printed à 13:42', today: today)?.text, printed, reason: printed);
      }
      expect(receiptDate('14 février 2025', today: today)!.date, DateTime(2025, 2, 14));
      expect(receiptDate('1er mars 2025', today: today)!.date, DateTime(2025, 3, 1));
    });

    test('a time or a phone number is not a date', () {
      expect(receiptDate('13:42  01 42 61 00 00', today: today), isNull);
    });

    test('a currency on the total\'s line', () {
      expect(receiptTotal(['TOTAL  15,95 €'])!.currency!.codes, {'EUR'});
      expect(receiptTotal(['TOTAL EUR 15,95'])!.currency!.codes, {'EUR'});
      expect(receiptTotal(['Total: ¥1,595'])!.currency!.codes, {'JPY', 'CNY'});
      expect(receiptTotal(['TOTAL  CHF 12.50'])!.currency!.codes, {'CHF'});
      expect(receiptTotal(['TOTAL  US\$ 12.50'])!.currency!.codes, {'USD'});
    });

    test('elsewhere on the receipt when the total\'s line shows none', () {
      final total = receiptTotal(['Coffee  € 3,50', 'TOTAL  3,50'])!;
      expect((total.currency!.mark, total.sure), ('€', true));
      // Marks that can mean one currency are one currency.
      expect(receiptTotal(['Coffee  \$3.50', 'TOTAL USD 3.50'])!.currency!.codes, {'USD'});
    });

    // #147 review (Ezra): a currency on a line of its own was ignored, and
    // the total went into a EUR group's amount as euros.
    test('a currency declared on a line of its own', () {
      for (final line in ['Currency: USD', 'Devise : USD', 'USD', 'Prices in USD']) {
        final total = receiptTotal(['CORNER CAFE', line, 'TOTAL 19.62'])!;
        expect(total.currency?.codes, {'USD'}, reason: line);
      }
      expect(receiptTotal(['CORNER CAFE', '€', 'TOTAL 19,62'])!.currency?.codes, {'EUR'});
    });

    test('a code in ordinary words is not a currency', () {
      expect(receiptTotal(['THE USD LOUNGE', 'TOTAL 19.62'])!.currency, isNull);
    });

    test('two currencies make it unclear, so not sure', () {
      final total = receiptTotal(['Coffee  € 3,50', 'Cake  £ 2,00', 'TOTAL  5,50'])!;
      expect(total.sure, isFalse);
    });

    test('a word is not a currency', () {
      expect(receiptTotal(['CUP OF TEA  2,50', 'TOTAL  2,50'])!.currency, isNull);
      expect(receiptTotal(['Krispy Kreme  2,50', 'TOTAL  2,50'])!.currency, isNull);
    });

    test('whether it could be the group\'s currency', () {
      const dollar = ReceiptCurrency(r'$', {'USD', 'CAD'});
      expect(dollar.couldBe(groupCode: 'CAD', groupSymbol: r'CA$'), isTrue);
      expect(dollar.couldBe(groupCode: 'EUR', groupSymbol: '€'), isFalse);
      // A custom currency has only its symbol.
      expect(const ReceiptCurrency('€', {'EUR'}).couldBe(groupCode: null, groupSymbol: '€'), isTrue);
    });
  });

  group('the merchant line', () {
    test('till furniture is not the name of the shop', () {
      expect(receiptMerchant(['*** CUSTOMER COPY ***', 'Chez Nous']), 'Chez Nous');
      expect(receiptMerchant(['TAX INVOICE', 'MARKET HALL']), 'Market Hall');
      expect(receiptMerchant(['www.shop.example', 'Shop']), 'Shop');
      expect(receiptMerchant(['1234567890', 'Shop']), 'Shop');
    });

    test('a name that isn\'t shouted is left alone', () {
      expect(receiptMerchant(['eBay']), 'eBay');
      expect(receiptMerchant(['CAFE ROSE']), 'Cafe Rose');
      expect(receiptMerchant(["MCDONALD'S"]), "Mcdonald's");
    });
  });

  group('rows', () {
    /// spliit-ios's recording of what Vision returned for its sample
    /// receipt, turned to ML Kit's top-left origin: the labels come back
    /// as one column and the prices as another.
    final blocks = [
      ('CAFE DU COIN', 0.0492, 0.9229, 0.0417),
      ('12 rue de la Paix', 0.0515, 0.8531, 0.0438),
      ('75002 Paris', 0.0515, 0.7844, 0.0438),
      ('2026-08-26', 0.0515, 0.6438, 0.0417),
      ('Cafe', 0.0489, 0.5033, 0.0417),
      ('3,50', 0.5948, 0.4974, 0.0604),
      ('Croissant', 0.0514, 0.4360, 0.0458),
      ('2,40', 0.5949, 0.4273, 0.0583),
      ('Sandwich', 0.0515, 0.3656, 0.0438),
      ('8,60', 0.5928, 0.3573, 0.0604),
      ('SOUS-TOTAL', 0.0515, 0.2250, 0.0375),
      ('TVA 10%', 0.0491, 0.1556, 0.0396),
      ('TOTAL', 0.0492, 0.0856, 0.0417),
      ('14,50', 0.5591, 0.2191, 0.0583),
      ('1,45', 0.5947, 0.1488, 0.0583),
      ('15,95', 0.5592, 0.0784, 0.0604),
    ].map((b) => ReceiptTextBlock(text: b.$1, minX: b.$2, midY: 1 - b.$3, height: b.$4)).toList();

    test('a price ends up on the same row as its label', () {
      expect(receiptRows(blocks), '''
CAFE DU COIN
12 rue de la Paix
75002 Paris
2026-08-26
Cafe   3,50
Croissant   2,40
Sandwich   8,60
SOUS-TOTAL   14,50
TVA 10%   1,45
TOTAL   15,95''');
    });

    test('rebuilding the rows is what makes the total the total', () {
      // Added by hand, on the blank row above the subtotal (spliit-ios).
      final tendered = [
        const ReceiptTextBlock(text: 'CASH', minX: 0.0515, midY: 1 - 0.2950, height: 0.0400),
        const ReceiptTextBlock(text: '20,00', minX: 0.5590, midY: 1 - 0.2890, height: 0.0580),
      ];
      final all = [...blocks, ...tendered];
      final byRows = readReceipt(receiptRows(all), today: DateTime(2026, 9, 1)).total!;
      expect((byRows.cents, byRows.sure), (1595, true));
      // Read in the order OCR gave them, no line names a total and a
      // number: only the largest price, and not sure.
      final raw = readReceipt(all.map((b) => b.text).join('\n'), today: DateTime(2026, 9, 1)).total!;
      expect((raw.cents, raw.sure), (2000, false));
    });
  });

  test('what ML Kit returned for a receipt, on the Android emulator', () {
    // Recorded through the app's own channel (ReceiptScanChannel.kt) from
    // a receipt drawn on a 720x1100 canvas, not a photo: the labels came
    // back as one column and the prices as another, as with Vision.
    final blocks = [
      ('BOULANGERIE DUPONT', 0.1694, 0.0545, 0.0255),
      ('8 avenue des Ternes', 0.2389, 0.1064, 0.0200),
      ('75017 Paris', 0.3500, 0.1464, 0.0218),
      ('Tel 01 45 72 00 00', 0.2389, 0.1873, 0.0218),
      ('Le 14/03/2025 a 08:12', 0.0736, 0.2518, 0.0200),
      ('Baguette', 0.0722, 0.3186, 0.0264),
      ('Croissant x2', 0.0722, 0.3600, 0.0218),
      ('Tarte citron', 0.0708, 0.4055, 0.0255),
      ('SOUS-TOTAL', 0.0722, 0.4700, 0.0200),
      ('CB', 0.0722, 0.6064, 0.0200),
      ('TVA 5,5%', 0.0722, 0.5173, 0.0236),
      ('TOTAL EUR', 0.0722, 0.5609, 0.0200),
      ('1,30', 0.7278, 0.3173, 0.0236),
      ('2,60', 0.7250, 0.3627, 0.0236),
      ('4,90', 0.7236, 0.4064, 0.0255),
      ('8,80', 0.7250, 0.4718, 0.0236),
      ('0,46', 0.7250, 0.5173, 0.0236),
      ('8,80', 0.7250, 0.5623, 0.0227),
      ('8,80', 0.7250, 0.6082, 0.0236),
      ('Merci de votre visite', 0.2111, 0.6873, 0.0218),
    ].map((b) => ReceiptTextBlock(text: b.$1, minX: b.$2, midY: b.$3, height: b.$4)).toList();

    final rows = receiptRows(blocks);
    expect(rows.split('\n').sublist(5, 12), [
      'Baguette   1,30',
      'Croissant x2   2,60',
      'Tarte citron   4,90',
      'SOUS-TOTAL   8,80',
      'TVA 5,5%   0,46',
      'TOTAL EUR   8,80',
      'CB   8,80',
    ]);
    final scan = readReceipt(rows, categories: spliitSeedCategories, today: today);
    expect((scan.title, scan.total!.cents, scan.total!.sure, scan.date, scan.categoryId),
        ('Boulangerie Dupont', 880, true, DateTime(2025, 3, 14), 8));
    expect(scan.total!.currency!.codes, {'EUR'});
  });

  group('the category', () {
    const categories = [
      Category(id: 0, grouping: 'Uncategorized', name: 'General'),
      Category(id: 8, grouping: 'Food and Drink', name: 'Dining Out'),
      Category(id: 9, grouping: 'Food and Drink', name: 'Groceries'),
      Category(id: 35, grouping: 'Transportation', name: 'Taxi'),
      Category(id: 31, grouping: 'Transportation', name: 'Gas/Fuel'),
    ];

    test('matched by either half of its name, however it is cased', () {
      expect(matchReceiptCategory('Dining Out', categories), 8);
      expect(matchReceiptCategory('Food and Drink/Dining Out', categories), 8);
      expect(matchReceiptCategory('dining out', categories), 8);
      expect(matchReceiptCategory('Transportation/Gas/Fuel', categories), 31);
    });

    test('a category nobody has is nobody\'s', () {
      expect(matchReceiptCategory('Spaceship Fuel', categories), isNull);
      expect(matchReceiptCategory('', categories), isNull);
      expect(matchReceiptCategory(null, categories), isNull);
    });

    test('guessed from the shop\'s own name', () {
      expect(read('CAFÉ DU COIN\n12 rue\nTOTAL 4,00', categories: categories).categoryId, 8);
      expect(read('SUPERMARCHÉ EXPRESS\nTOTAL 40,00', categories: categories).categoryId, 9);
      expect(read('TAXI PARISIEN\nTOTAL 22,00', categories: categories).categoryId, 35);
      expect(read('STATION SERVICE TOTAL\nTOTAL 60,00', categories: categories).categoryId, 31);
    });

    test('the items are not read for it', () {
      expect(read('MARKET HALL\n15 High Street\n\nCoffee 3.00\nPizza 8.00\nTOTAL 11.00', categories: categories).categoryId,
          isNull);
    });

    test('one the server doesn\'t have is left unset', () {
      expect(read('CAFÉ DU COIN\nTOTAL 4,00', categories: [categories.first]).categoryId, isNull);
    });

    test('Spliit\'s seeded categories have every one guessed', () {
      expect(read('SUPERMARCHÉ EXPRESS\nTOTAL 40,00', categories: spliitSeedCategories).categoryId, 9);
      expect(read('PHARMACIE CENTRALE\nTOTAL 9,00', categories: spliitSeedCategories).categoryId, 25);
    });
  });
}
