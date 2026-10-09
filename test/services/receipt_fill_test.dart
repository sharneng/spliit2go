import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/services/receipt_fill.dart';
import 'package:spliit2go/services/receipt_text.dart';

// Issue #125: a scan's suggestions never overwrite the user, and what the
// parser isn't sure of is a hint, never a value.
void main() {
  ReceiptFormState form({
    bool titleEmpty = true,
    bool amountEmpty = true,
    bool dateChosen = false,
    bool categoryChosen = false,
    String? code = 'EUR',
    String symbol = '€',
  }) =>
      ReceiptFormState(
        titleEmpty: titleEmpty,
        amountEmpty: amountEmpty,
        dateChosen: dateChosen,
        categoryChosen: categoryChosen,
        currencyCode: code,
        currencySymbol: symbol,
      );

  const euro = ReceiptCurrency('€', {'EUR'});
  final scan = ReceiptScan(
    title: 'Café Du Coin',
    total: const ReceiptTotal(cents: 1595, text: '15,95', sure: true),
    date: DateTime(2025, 3, 14),
    dateText: '14/03/2025',
    categoryId: 8,
  );

  test('an empty form is filled in, with no hints', () {
    final fill = receiptFill(scan, form());
    expect((fill.title, fill.amountCents, fill.date, fill.categoryId), ('Café Du Coin', 1595, DateTime(2025, 3, 14), 8));
    expect([fill.titleHint, fill.amountHint, fill.dateHint, fill.categoryHint], everyElement(isNull));
    expect(fill.filledAny, isTrue);
  });

  test('what the user filled or chose is left alone, and the receipt\'s is a hint', () {
    final fill = receiptFill(
        scan, form(titleEmpty: false, amountEmpty: false, dateChosen: true, categoryChosen: true));
    expect([fill.title, fill.amountCents, fill.date, fill.categoryId], everyElement(isNull));
    expect((fill.titleHint, fill.amountHint, fill.dateHint, fill.categoryHint),
        ('Café Du Coin', '15,95', '14/03/2025', 8));
    expect(fill.filledAny, isFalse);
  });

  test('the group\'s currency, or none shown, fills the amount', () {
    ReceiptScan withTotal(ReceiptCurrency? c) =>
        ReceiptScan(total: ReceiptTotal(cents: 1595, text: '15,95', currency: c, sure: true));
    expect(receiptFill(withTotal(euro), form()).amountCents, 1595);
    expect(receiptFill(withTotal(null), form()).amountCents, 1595);
    // A group with a custom symbol and no code.
    expect(receiptFill(withTotal(euro), form(code: null, symbol: '€')).amountCents, 1595);
  });

  test('another currency is never put in the group\'s: a hint with its mark', () {
    final fill = receiptFill(
        const ReceiptScan(total: ReceiptTotal(cents: 1595, text: '15,95', currency: euro, sure: true)),
        form(code: 'USD', symbol: r'$'));
    expect((fill.amountCents, fill.amountHint), (null, '€ 15,95'));
  });

  // #147 review (Ezra), through the parser: a USD receipt in a EUR group.
  test('a currency declared on its own line keeps the total out of the amount', () {
    final scan = readReceipt('CORNER CAFE\nCurrency: USD\nTOTAL 19.62', today: DateTime(2026, 9, 27));
    final fill = receiptFill(scan, form());
    expect((fill.amountCents, fill.amountHint), (null, 'USD 19.62'));
  });

  test('paid in yen, a euro total is only a hint, and a yen total fills it (#252)', () {
    const euros = ReceiptScan(total: ReceiptTotal(cents: 1595, text: '15,95', currency: euro, sure: true));
    expect(receiptFill(euros, form(code: 'JPY', symbol: '¥')).amountCents, isNull);
    const yen = ReceiptScan(
        total: ReceiptTotal(cents: 100000, text: '1,000', currency: ReceiptCurrency('¥', {'JPY', 'CNY'}), sure: true));
    expect(receiptFill(yen, form(code: 'JPY', symbol: '¥')).amountCents, 100000);
  });

  test('a total the parser isn\'t sure of is only a hint', () {
    final fill = receiptFill(const ReceiptScan(total: ReceiptTotal(cents: 123400, text: '1.234', sure: false)), form());
    expect((fill.amountCents, fill.amountHint), (null, '1.234'));
  });

  test('a date that reads two ways is only a hint', () {
    final fill = receiptFill(const ReceiptScan(dateText: '03/04/25'), form());
    expect((fill.date, fill.dateHint), (null, '03/04/25'));
  });
}
