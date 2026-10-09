/// Parses a decimal the user typed or pasted (an expense amount, or a
/// shares/percentage/split-amount field), accepting `,` or `.` as the
/// decimal separator whatever the device's locale (#37), and a pasted
/// amount as it's written elsewhere (#238): "$1,234.56", "1 234,56 €",
/// "CHF 1'234.50".
///
/// The decision follows the receipt scanner's (`receiptAmounts`):
/// - a currency symbol or code before or after the number is dropped,
///   and so are spaces and apostrophes grouping it; any other text
///   ("1.2k", "12abc") makes it invalid, not a different amount;
/// - a leading or trailing separator is the decimal one (".5", "12.");
/// - with both separators, the last is the decimal one ("1.234,56");
/// - one separator repeated groups thousands ("1,234,567");
/// - one separator followed by other than three digits is the decimal
///   one ("12,5", "12.50");
/// - only "1,234" is truly ambiguous, and [decimalSeparator], the
///   locale's, decides it: 1.234 in French, 1234 in English.
///
/// Returns null for anything that still isn't a number, a group of the
/// wrong size ("1,23,4") among them (same contract as [double.tryParse]).
double? parseFlexibleDecimal(String input, {String decimalSeparator = '.'}) {
  final text = input
      .replaceAll(_currencyAround, '')
      .replaceAll(_grouping, '');
  final match = _number.firstMatch(text);
  if (match == null) return null;
  final sign = match[1]!;
  final body = match[2]!;
  // ".5" and "12.", typed as ever: never grouping, even ",234".
  if (_edgeDecimal.hasMatch(body)) {
    return double.parse('${sign}0${body.replaceAll(',', '.')}0');
  }
  final separators = [
    for (var i = 0; i < body.length; i++)
      if (body[i] == '.' || body[i] == ',') i,
  ];
  if (separators.isEmpty) return double.parse('$sign$body');
  final last = separators.last;
  final kinds = {for (final i in separators) body[i]};
  final int? decimalAt;
  if (kinds.length == 2) {
    // The last one is the decimal separator, and it appears only once.
    if (separators.where((i) => body[i] == body[last]).length > 1) return null;
    decimalAt = last;
  } else if (separators.length > 1) {
    decimalAt = null;
  } else {
    final fraction = body.length - last - 1;
    decimalAt = fraction != 3 || body[last] == decimalSeparator || last > 3 ? last : null;
  }
  final whole = decimalAt == null ? body : body.substring(0, decimalAt);
  final groups = whole.split(RegExp('[.,]'));
  if (groups.length > 1 &&
      (groups.first.length > 3 || groups.skip(1).any((g) => g.length != 3))) {
    return null;
  }
  final fraction = decimalAt == null ? '' : '.${body.substring(decimalAt + 1)}';
  return double.parse('$sign${groups.join()}$fraction');
}

/// Spaces (no-break and narrow no-break too, as French groups with) and
/// apostrophes (as Swiss) between the digits.
final _grouping = RegExp("[\\s  '’]");

/// A currency before or after the number: a symbol ("$", "€"), one with
/// a country's letters ("US$", "HK$"), or an ISO code ("CHF", "JPY ¥").
final _currencyAround = RegExp(
    r'^\s*(?:[A-Z]{3}\s*\p{Sc}?|[A-Z]{1,2}\p{Sc}|\p{Sc})\s*|\s*(?:\p{Sc}?\s*[A-Z]{3}|\p{Sc})\s*$',
    unicode: true);

/// An optional minus, then digits joined by dots and commas, or with a
/// single separator before or after them.
final _number = RegExp(r'^(-?)(\d+(?:[.,]\d+)*|[.,]\d+|\d+[.,])$');

/// A lone separator at either end: the decimal one.
final _edgeDecimal = RegExp(r'^[.,]\d+$|^\d+[.,]$');
