import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/screens/expense_form/rate_field.dart';

// #289: the exchange rate's field on its own, without the form.
void main() {
  var changes = 0;

  ExchangeRateField field({String paidIn = 'JPY', String group = 'EUR', String separator = '.'}) {
    changes = 0;
    final f = ExchangeRateField(
      groupCode: group,
      paidIn: paidIn,
      parse: (text) => double.tryParse(text.replaceAll(separator, '.')),
      decimalSeparator: separator,
      onChanged: () => changes++,
    );
    addTearDown(f.dispose);
    return f;
  }

  test('the more valuable currency first; the value is still 1 paid-in unit in group units', () {
    final f = field();
    expect(f.pair, 'EUR/JPY');
    expect(f.baseCode, 'EUR');
    f.controller.text = '176.84';
    expect(f.value, 1 / 176.84);
    final g = field(paidIn: 'EUR', group: 'JPY')..controller.text = '176.84';
    expect((g.pair, g.value), ('EUR/JPY', 176.84));
  });

  test('nothing above zero is no rate', () {
    final f = field();
    for (final text in ['', '0', '-2', 'abc']) {
      f.controller.text = text;
      expect(f.value, isNull, reason: text);
    }
  });

  test('a fill goes into an empty or filled-in field only, unless forced', () {
    final f = field()..fill(1 / 176.84, force: false, editsAtRequest: 0);
    expect((f.controller.text, f.isOwn), ('176.84', false));
    f.fill(1 / 180, force: false, editsAtRequest: 0);
    expect(f.controller.text, '180');

    f
      ..typed()
      ..controller.text = '175';
    f.fill(1 / 176.84, force: false, editsAtRequest: f.edits);
    expect((f.controller.text, f.isOwn), ('175', true));
    f.fill(1 / 176.84, force: true, editsAtRequest: f.edits);
    expect((f.controller.text, f.isOwn), ('176.84', false));
  });

  test('a fill asked for before the user typed loses, even forced', () {
    final f = field();
    final asked = f.edits;
    f
      ..typed()
      ..controller.text = '175';
    f.fill(1 / 176.84, force: true, editsAtRequest: asked);
    expect(f.controller.text, '175');
  });

  test('a swap flips the number and says so; swapped back untouched, the text is as typed', () {
    final f = field()..controller.text = '176.84';
    f.swap();
    expect((f.pair, f.controller.text, changes), ('JPY/EUR', '0.00565483', 1));
    expect(f.value, closeTo(1 / 176.84, 1e-8));
    f.swap();
    expect((f.pair, f.controller.text), ('EUR/JPY', '176.84'));
  });

  test('the saved rate is the record: shown either way round, sent back as stored', () {
    const stored = 0.0061;
    final f = field()..showSaved(stored);
    expect((f.controller.text, f.isSaved, f.isOwn, f.value), ('163.934', true, true, stored));
    f.swap();
    expect((f.controller.text, f.isSaved, f.value), ('0.0061', true, stored));
    f.controller.text = '0.0062';
    expect((f.isSaved, f.value), (false, 0.0062));
  });

  test('the device\'s choice of base flips the field until another currency', () {
    final f = field()..fill(1 / 176.84, force: false, editsAtRequest: 0);
    f.base = 'JPY';
    expect((f.pair, f.controller.text, changes), ('JPY/EUR', '0.00565483', 1));
    f.ranking = const {'EUR': 1, 'JPY': 176};
    expect(f.pair, 'JPY/EUR');

    f.pairWith('USD');
    expect((f.pair, f.controller.text, f.isOwn), ('EUR/USD', '', false));
  });

  test('a currency the ranking doesn\'t know goes second', () {
    final f = field(paidIn: 'XYZ', group: 'EUR');
    expect(f.pair, 'EUR/XYZ');
  });

  test('a rate is 6 significant figures, in the locale\'s separator', () {
    final f = field(separator: ',');
    expect(f.numberText(176.84), '176,84');
    expect(f.numberText(0.00609756097560976), '0,00609756');
    f.showSaved(1 / 176.84);
    expect((f.controller.text, f.value), ('176,84', 1 / 176.84));
    f.decimalSeparator = '.';
    expect(f.numberText(0.5), '0.5');
  });
}
