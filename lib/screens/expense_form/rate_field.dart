import 'dart:math' show ln10, log;

import 'package:flutter/widgets.dart' show TextEditingController, VoidCallback;

import '../../models/currency_ranking.dart';

/// The exchange rate's field (#252, #261), apart from the rest of the
/// form (#289): the rate as one number with the more valuable currency
/// first (EUR/JPY = 176.84, 1 of the first in the second), the swap, a
/// rate filled in from the published ones, and the rate saved with an
/// edited expense. [value] is still 1 paid-in unit in group units, as
/// Spliit stores it.
///
/// What's in the field is one of three: a rate this form filled in
/// ([isOwn] false), the saved one ([isSaved]), or one the user typed.
class ExchangeRateField {
  ExchangeRateField({
    required this.groupCode,
    required String? paidIn,
    required this.parse,
    required String decimalSeparator,
    required this.onChanged,
  })  : _paidIn = paidIn,
        _separator = decimalSeparator {
    _paidInFirst = _rankedPaidInFirst;
  }

  /// The group's currency code.
  final String? groupCode;

  /// Parses what's typed, as the rest of the form does.
  final double? Function(String) parse;

  /// The pair's order changed without the text changing.
  final VoidCallback onChanged;

  final controller = TextEditingController();

  String? _paidIn;

  String _separator;

  /// The locale's decimal separator, which a rate is shown in.
  set decimalSeparator(String separator) => _separator = separator;

  /// [value] to 6 significant figures, as a rate is shown (#261): plain
  /// decimals, never an exponent, in the locale's separator, no trailing
  /// zeros.
  String numberText(double value) {
    final exponent = value <= 0 ? 0 : (log(value) / ln10).floor();
    var text = value.toStringAsFixed((5 - exponent).clamp(0, 20));
    if (text.contains('.')) {
      text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return text.replaceAll('.', _separator);
  }

  /// Another paid-in currency (#252): a rate belongs to a pair, so the
  /// field starts empty, in the ranking's order.
  void pairWith(String? paidIn) {
    _paidIn = paidIn;
    _autoFilledRate = _autoFilledValue = _savedRate = _swappedFrom = _baseChoice = null;
    _paidInFirst = _rankedPaidInFirst;
    controller.text = '';
  }

  // ---------------------------------------------------------------------
  // The pair's order.

  /// Units of each currency per 1 EUR: what decides which goes first.
  Map<String, double> _ranking = shippedUnitsPerEuro;

  /// The newest saved table, over the shipped one ([ExchangeRates.ranking]).
  set ranking(Map<String, double> unitsPerEuro) {
    _ranking = unitsPerEuro;
    _showInOrder();
  }

  /// The currency this device writes the pair with first, once swapped
  /// there; null to go by the ranking.
  String? _baseChoice;
  set base(String? code) {
    _baseChoice = code;
    _showInOrder();
  }

  /// Whether the paid-in currency is worth more than the group's: fewer
  /// of it to the euro. An unknown currency goes second.
  bool get _rankedPaidInFirst {
    final (paidIn, own) = (_ranking[_paidIn], _ranking[groupCode]);
    return paidIn != null && (own == null || paidIn < own);
  }

  bool get _wantsPaidInFirst => _baseChoice == null ? _rankedPaidInFirst : _baseChoice == _paidIn;

  /// The order the field is written in.
  late bool _paidInFirst;

  /// The pair, as "EUR/JPY": the first is the one that's 1.
  String get pair => _paidInFirst ? '$_paidIn/$groupCode' : '$groupCode/$_paidIn';

  /// The currency written first, which a swap makes the other one.
  String? get baseCode => _paidInFirst ? _paidIn : groupCode;

  /// A stored rate (1 paid-in unit in group units) as the field shows it,
  /// in the pair's order.
  String shownText(double stored) => numberText(_paidInFirst ? stored : 1 / stored);

  /// Tap on the pair (#261): the other currency first, and the number
  /// flipped with it. The screen remembers it for the pair.
  void swap() {
    _baseChoice = _paidInFirst ? groupCode : _paidIn;
    _flip();
    onChanged();
  }

  void _showInOrder() {
    if (_wantsPaidInFirst != _paidInFirst) _flip();
    onChanged();
  }

  /// What the last swap turned the field's text from and into: swapped
  /// back untouched, the text comes back as it was, not rounded twice.
  (String, String)? _swappedFrom;

  void _flip() {
    final text = controller.text.trim();
    final saved = isSaved;
    final auto = text.isNotEmpty && text == _autoFilledRate;
    _paidInFirst = !_paidInFirst;
    // A saved or published rate is shown afresh from its own value.
    final String next;
    if (saved) {
      next = shownText(_savedRate!);
    } else if (auto) {
      next = shownText(_autoFilledValue!);
    } else if (_swappedFrom case (final before, final after) when after == text) {
      next = before;
    } else {
      final value = parse(text);
      next = value == null || value <= 0 ? text : numberText(1 / value);
    }
    if (_autoFilledValue case final value?) _autoFilledRate = shownText(value);
    _swappedFrom = saved || auto ? null : (text, next);
    controller.text = next;
  }

  // ---------------------------------------------------------------------
  // Where the rate in the field comes from.

  /// The last rate this form filled in by itself, as shown and as its
  /// value, so a rate typed over it is never overwritten by a lookup.
  String? _autoFilledRate;
  double? _autoFilledValue;

  /// The rate saved with the expense being edited: the record, sent back
  /// as stored while the field shows it, never looked up again by itself.
  double? _savedRate;

  /// Shows [rate], saved with the expense, as the field's rate.
  void showSaved(double rate) {
    _savedRate = rate;
    controller.text = shownText(rate);
  }

  /// Counts what's typed in the field, so "Use the published rate"
  /// replaces only the rate it was asked to, not one typed while it was
  /// on its way.
  int _edits = 0;
  int get edits => _edits;

  /// The user typed in the field.
  void typed() => _edits++;

  /// The field holds a rate of the user's: typed, or the saved one.
  bool get isOwn {
    final text = controller.text.trim();
    return text.isNotEmpty && text != _autoFilledRate;
  }

  /// That rate is the one saved with the expense being edited.
  bool get isSaved => _savedRate != null && controller.text.trim() == shownText(_savedRate!);

  /// Whether the field shows [published] (stored the usual way), as the
  /// footer quotes it.
  bool shows(double published) => controller.text.trim() == shownText(published);

  /// Fills in a published [rate] looked up when the field had had
  /// [editsAtRequest] edits. Anything typed since the request wins, even
  /// a rate that happens to match the one filled in before (#255
  /// review); an empty field has nothing to lose. [force]: "Use the
  /// published rate", over a rate of the user's.
  void fill(double rate, {required bool force, required int editsAtRequest}) {
    final current = controller.text.trim();
    if (current.isEmpty || (editsAtRequest == _edits && (force || current == _autoFilledRate))) {
      _savedRate = _swappedFrom = null;
      _autoFilledValue = rate;
      controller.text = _autoFilledRate = shownText(rate);
    }
  }

  /// The rate to work with and save, 1 paid-in unit in group units: the
  /// saved one as stored while the field shows it (#261, acceptance case
  /// 3), otherwise worked out from the number shown, if it's above zero,
  /// so what's shown, saved and calculated agree.
  double? get value {
    if (isSaved) return _savedRate;
    final shown = parse(controller.text.trim());
    if (shown == null || shown <= 0) return null;
    return _paidInFirst ? shown : 1 / shown;
  }

  void dispose() => controller.dispose();
}
