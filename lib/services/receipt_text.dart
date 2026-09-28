import '../models/category.dart';

/// Reading a photographed receipt's text (#125): a port of spliit-ios's
/// `ReceiptText` and `ReceiptCategories` (80b2e98,
/// Packages/SpliitKit/Sources/SpliitCore/ReceiptScan.swift), with #125's
/// rule that what the parser can't be sure of stays unset: a number
/// whose decimal separator can't be decided, a date that reads two ways,
/// a total no line names, and a currency the receipt doesn't make clear.
///
/// Pure: no plugin, no state, no clock but [today]. Latin-script
/// receipts in English and French (the languages spliit-ios reads);
/// another Latin-script receipt still gives up its total when a line
/// names it in one of them. Chinese and Japanese are #126.

/// One line of text OCR found, and where: 0…1 across the image, origin
/// at the top left (ML Kit's, unlike Vision's bottom-left).
class ReceiptTextBlock {
  final String text;
  final double minX;
  final double midY;
  final double height;
  const ReceiptTextBlock({required this.text, required this.minX, required this.midY, required this.height});
}

/// A receipt's rows, put back together from the lines OCR found.
///
/// Text recognition reads a receipt as a page, so the labels come back as
/// one block and the prices as another, and "TOTAL" ends up lines away
/// from its amount. Two runs are on one row when their vertical middles
/// are closer than half the shorter one's height (spliit-ios
/// `ReceiptText.rows`).
String receiptRows(List<ReceiptTextBlock> blocks) {
  final rows = <List<ReceiptTextBlock>>[];
  for (final block in [...blocks]..sort((a, b) => a.midY.compareTo(b.midY))) {
    final first = rows.isEmpty ? null : rows.last.first;
    if (first != null) {
      final shorter = first.height < block.height ? first.height : block.height;
      final tolerance = (shorter > 0.001 ? shorter : 0.001) / 2;
      if ((first.midY - block.midY).abs() < tolerance) {
        rows.last.add(block);
        continue;
      }
    }
    rows.add([block]);
  }
  return [
    for (final row in rows) ([...row]..sort((a, b) => a.minX.compareTo(b.minX))).map((b) => b.text).join('   '),
  ].join('\n');
}

/// A currency a receipt shows: the mark as printed, and the ISO codes it
/// can stand for ("\$" is a dozen of them).
class ReceiptCurrency {
  final String mark;
  final Set<String> codes;
  const ReceiptCurrency(this.mark, this.codes);

  /// Whether this can be the group's currency: its code, or its own
  /// symbol for a group with a custom one.
  bool couldBe({required String? groupCode, required String groupSymbol}) =>
      (groupCode != null && codes.contains(groupCode)) ||
      (groupSymbol.trim().isNotEmpty && mark == groupSymbol.trim());

  @override
  String toString() => mark;
}

/// The receipt's grand total.
class ReceiptTotal {
  /// In hundredths, as the rest of the app keeps amounts.
  final int cents;

  /// As printed, for a hint.
  final String text;

  /// The currency the receipt shows, or null when it shows none.
  final ReceiptCurrency? currency;

  /// False when the parser can't vouch for it: no line names a total (it
  /// is only the largest price), its decimal separator can't be decided
  /// ("1.234"), or the receipt shows more than one currency.
  final bool sure;

  const ReceiptTotal({required this.cents, required this.text, this.currency, required this.sure});

  /// The total with its currency, as a hint shows it.
  String get display => currency == null ? text : '${currency!.mark} $text';
}

/// What a receipt says. Every field is independent and may be missing: a
/// receipt that yields nothing is a normal outcome, not an error.
class ReceiptScan {
  final String? title;
  final ReceiptTotal? total;

  /// Only when exactly one plausible reading of the first date exists.
  final DateTime? date;

  /// The first date as printed, whether or not it could be read.
  final String? dateText;

  /// One of the server's categories.
  final int? categoryId;

  const ReceiptScan({this.title, this.total, this.date, this.dateText, this.categoryId});

  bool get isEmpty => title == null && total == null && dateText == null && categoryId == null;
}

/// Reads [transcript], rows in reading order (see [receiptRows]).
/// [categories] are the server's, so a guessed category is one this
/// group can store; [today] judges which dates are plausible.
ReceiptScan readReceipt(String transcript, {List<Category> categories = const [], required DateTime today}) {
  final lines = [
    for (final l in transcript.split('\n'))
      if (l.trim().isNotEmpty) l.trim(),
  ];
  final title = receiptMerchant(lines);
  final date = receiptDate(transcript, today: today);
  return ReceiptScan(
    title: title,
    total: receiptTotal(lines),
    date: date?.date,
    dateText: date?.text,
    categoryId: guessReceiptCategory(title, categories),
  );
}

// ---------------------------------------------------------------------------
// The total

/// Lines that name a total (folded: "À PAYER" is "a payer").
const _totalKeywords = [
  'total', 'amount due', 'balance due', 'grand total', 'to pay', //
  'montant', 'a payer', 'somme',
];

/// Lines that name a total of something else. Short on purpose: the real
/// defence is taking the largest candidate, since a subtotal, a tax and a
/// discount are all smaller than the total they belong to.
const _notATotalKeywords = [
  'sous-total', 'sous total', 'subtotal', 'sub total', 'total ht', 'total h.t', //
  'hors taxe', 'tva', 'vat', 'tip', 'pourboire', 'change', 'rendu',
];

ReceiptTotal? receiptTotal(List<String> lines) {
  final decimal = _decimalSeparator(lines);
  ReceiptAmount? best;
  String? bestLine;
  for (final line in lines) {
    if (!receiptLineNames(_totalKeywords, line) || receiptLineNames(_notATotalKeywords, line)) continue;
    for (final a in receiptAmounts(line, decimalSeparator: decimal)) {
      if (best == null || a.cents > best.cents) (best, bestLine) = (a, line);
    }
  }
  final named = best != null;
  if (!named) {
    // Nothing names a total: the largest price is a guess, offered as a
    // hint, never filled in.
    for (final line in lines) {
      for (final a in receiptAmounts(line, decimalSeparator: decimal)) {
        if (a.hasCents && (best == null || a.cents > best.cents)) (best, bestLine) = (a, line);
      }
    }
  }
  if (best == null) return null;
  final (currency, clear) = _currencyFor(bestLine!, lines);
  return ReceiptTotal(
    cents: best.cents,
    text: best.text,
    currency: currency,
    sure: named && !best.ambiguous && clear,
  );
}

/// One number on a line.
class ReceiptAmount {
  /// In hundredths. An [ambiguous] number is read as a whole number.
  final int cents;

  /// Exactly two digits behind a separator: a price, not a house number.
  final bool hasCents;

  /// One separator followed by three digits ("1.234", "1,234"): a
  /// thousand, or one and a bit. Decided by the receipt's own decimal
  /// separator when its prices show it, and ambiguous otherwise.
  final bool ambiguous;

  /// As printed.
  final String text;

  const ReceiptAmount(this.cents, {required this.hasCents, this.ambiguous = false, required this.text});
}

const _grouping = "   '’";

/// A run of digits, grouped by single spaces or apostrophes in threes
/// ("1 234,56", "1'234.50"), or joined by dots and commas. Two spaces
/// or more separate numbers: rows are joined with three.
final _number = RegExp(r"(?<![\d.,])(?:\d{1,3}(?:[   '’]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d+)*)(?!\d)");
final _percentAfter = RegExp(r'^\s*%');

/// Every number on [line], in order. A percentage isn't one: "TVA 20%"
/// offering up a 20 would outbid a small total (spliit-ios).
List<ReceiptAmount> receiptAmounts(String line, {String? decimalSeparator}) => [
      for (final m in _number.allMatches(line))
        if (!_percentAfter.hasMatch(line.substring(m.end)))
          if (_amount(m[0]!, decimalSeparator) case final a?) a,
    ];

/// The decimal separator is decided by what follows the last separator,
/// not by the phone's locale: a receipt is printed where it was printed.
ReceiptAmount? _amount(String text, String? decimalSeparator) {
  final chars = [
    for (final c in text.split(''))
      if (!_grouping.contains(c)) c,
  ];
  final digits = chars.where(_isDigit).join();
  if (digits.isEmpty) return null;
  final last = chars.lastIndexWhere((c) => c == '.' || c == ',');
  if (last < 0) return ReceiptAmount(int.parse(digits) * 100, hasCents: false, text: text);
  final fraction = chars.length - last - 1;
  if (fraction == 1 || fraction == 2) {
    final whole = chars.sublist(0, last).where(_isDigit).join();
    final cents = int.parse(whole.isEmpty ? '0' : whole) * 100 +
        int.parse(chars.sublist(last + 1).join()) * (fraction == 1 ? 10 : 1);
    return ReceiptAmount(cents, hasCents: fraction == 2, text: text);
  }
  final separators = chars.where((c) => c == '.' || c == ',').length;
  final ambiguous = fraction == 3 && separators == 1 && chars[last] == (decimalSeparator ?? chars[last]);
  return ReceiptAmount(int.parse(digits) * 100, hasCents: false, ambiguous: ambiguous, text: text);
}

/// The separator this receipt's prices use for cents, when they agree.
String? _decimalSeparator(List<String> lines) {
  final seen = <String>{};
  for (final line in lines) {
    for (final m in _number.allMatches(line)) {
      final t = m[0]!;
      final last = t.lastIndexOf(RegExp('[.,]'));
      if (last >= 0 && t.length - last - 1 == 2) seen.add(t[last]);
    }
  }
  return seen.length == 1 ? seen.single : null;
}

bool _isDigit(String c) {
  final u = c.codeUnitAt(0);
  return u >= 0x30 && u <= 0x39;
}

/// The first number in [text], or null.
int? receiptNumberCents(String text) => receiptAmounts(text).firstOrNull?.cents;

// ---------------------------------------------------------------------------
// The currency

/// Marks a receipt prints beside an amount, and what they can mean. The
/// longer ones first, so "US\$" isn't read as "\$".
final _currencyMarks = <String, Set<String>>{
  r'US$': {'USD'}, r'CA$': {'CAD'}, r'C$': {'CAD'}, r'AU$': {'AUD'}, r'A$': {'AUD'}, //
  r'NZ$': {'NZD'}, r'HK$': {'HKD'}, r'S$': {'SGD'}, r'MX$': {'MXN'}, r'R$': {'BRL'},
  r'CO$': {'COP'}, 'CN¥': {'CNY'}, 'RMB': {'CNY'},
  r'$': {'USD', 'CAD', 'AUD', 'NZD', 'HKD', 'SGD', 'MXN', 'COP'},
  '€': {'EUR'}, '£': {'GBP'}, '¥': {'JPY', 'CNY'}, '₹': {'INR'}, '₩': {'KRW'}, '₪': {'ILS'},
  '₱': {'PHP'}, '฿': {'THB'}, '₫': {'VND'}, '₺': {'TRY'}, '₽': {'RUB'},
  'Kč': {'CZK'}, 'zł': {'PLN'}, 'Ft': {'HUF'}, 'kr': {'SEK', 'NOK', 'DKK', 'ISK'},
  'Fr.': {'CHF'}, 'RM': {'MYR'}, 'Rp': {'IDR'}, 'Rs': {'INR'}, 'TL': {'TRY'},
  for (final code in _isoCodes) code: {code},
};

/// ISO codes a receipt may print. Not every currency's: some are English
/// words a shouting receipt prints too (ALL, CUP, TOP).
const _isoCodes = [
  'USD', 'EUR', 'JPY', 'GBP', 'CHF', 'CAD', 'AUD', 'NZD', 'HKD', 'SGD', 'CNY', 'SEK', //
  'NOK', 'DKK', 'ISK', 'PLN', 'CZK', 'HUF', 'RON', 'BGN', 'BRL', 'MXN', 'COP', 'INR',
  'KRW', 'THB', 'VND', 'PHP', 'IDR', 'MYR', 'ILS', 'ZAR', 'TWD', 'MKD',
];

final _currencyMark = RegExp([
  for (final m in _currencyMarks.keys.toList()..sort((a, b) => b.length - a.length))
    // A mark made of letters must stand alone: "kr" isn't "Kreme".
    RegExp(r'^[A-Za-z]').hasMatch(m)
        ? '(?<![A-Za-z])${RegExp.escape(m)}${m.endsWith('.') ? '' : '(?![A-Za-z])'}'
        : RegExp.escape(m),
].join('|'));

List<ReceiptCurrency> _marksIn(String line) => [
      for (final m in _currencyMark.allMatches(line)) ReceiptCurrency(m[0]!, _currencyMarks[m[0]!]!),
    ];

/// The currency of the total on [line]: its own line's marks, or else
/// the receipt's. Several marks count as one currency when they can mean
/// the same one ("\$" and "USD"); otherwise it's unclear (false).
(ReceiptCurrency?, bool) _currencyFor(String line, List<String> lines) {
  var marks = _marksIn(line);
  if (marks.isEmpty) {
    marks = [
      for (final l in lines)
        if (receiptAmounts(l).isNotEmpty) ..._marksIn(l),
    ];
  }
  if (marks.isEmpty) return (null, true);
  var codes = marks.first.codes;
  for (final m in marks.skip(1)) {
    codes = codes.intersection(m.codes);
  }
  if (codes.isEmpty) return (marks.first, false);
  // The most specific mark: "USD" over "\$".
  final mark = marks.reduce((a, b) => b.codes.length < a.codes.length ? b : a);
  return (ReceiptCurrency(mark.mark, codes), true);
}

// ---------------------------------------------------------------------------
// The date

/// The first date printed on a receipt and, when it has exactly one
/// plausible reading, that date.
class ReceiptDate {
  final String text;
  final DateTime? date;
  const ReceiptDate(this.text, this.date);
}

/// How far back a receipt's date can plausibly be (spliit-ios): longer
/// than anyone splits an expense over, short enough that a card expiry or
/// a copyright line doesn't date the expense to 1999.
const _plausibleAge = Duration(days: 2 * 365);

const _months = {
  'january': 1, 'janvier': 1, 'janv': 1, 'jan': 1, //
  'february': 2, 'fevrier': 2, 'fevr': 2, 'fev': 2, 'feb': 2,
  'march': 3, 'mars': 3, 'mar': 3,
  'april': 4, 'avril': 4, 'avr': 4, 'apr': 4,
  'may': 5, 'mai': 5,
  'june': 6, 'juin': 6, 'jun': 6,
  'july': 7, 'juillet': 7, 'juil': 7, 'jul': 7,
  'august': 8, 'aout': 8, 'aou': 8, 'aug': 8,
  'september': 9, 'septembre': 9, 'sept': 9, 'sep': 9,
  'october': 10, 'octobre': 10, 'oct': 10,
  'november': 11, 'novembre': 11, 'nov': 11,
  'december': 12, 'decembre': 12, 'dec': 12,
};

final _monthName = '(${(_months.keys.toList()..sort((a, b) => b.length - a.length)).join('|')})';
final _isoDate = RegExp(r'(?<!\d)(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?!\d)');
final _numericDate = RegExp(r'(?<![\d.,])(\d{1,2})([-/.])(\d{1,2})\2(\d{4}|\d{2})(?![\d])');
final _dayMonthName =
    RegExp('(?<!\\d)(\\d{1,2})(?:er)?[\\s./-]*$_monthName(?![a-z])\\.?[\\s./,-]*(\\d{4}|\\d{2})(?!\\d)');
final _monthNameDay = RegExp('(?<![a-z])$_monthName(?![a-z])\\.?\\s+(\\d{1,2}),?\\s+(\\d{4})(?!\\d)');

/// The first date in [transcript] that has a plausible reading, checked
/// against [today]. "03/04/26" is 3 April or 4 March: with both
/// plausible, it's printed but not read. A dotted date is day first.
ReceiptDate? receiptDate(String transcript, {required DateTime today}) {
  final folded = foldReceiptText(transcript);
  final found = <(int, int, List<DateTime>)>[];
  int year(String y) => y.length == 2 ? 2000 + int.parse(y) : int.parse(y);
  for (final m in _isoDate.allMatches(folded)) {
    found.add((m.start, m.end, [_date(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!))].nonNulls.toList()));
  }
  for (final m in _numericDate.allMatches(folded)) {
    final (a, b, y) = (int.parse(m[1]!), int.parse(m[3]!), year(m[4]!));
    found.add((m.start, m.end, [_date(y, b, a), if (m[2] != '.') _date(y, a, b)].nonNulls.toList()));
  }
  for (final m in _dayMonthName.allMatches(folded)) {
    found.add((m.start, m.end, [_date(year(m[3]!), _months[m[2]!]!, int.parse(m[1]!))].nonNulls.toList()));
  }
  for (final m in _monthNameDay.allMatches(folded)) {
    found.add((m.start, m.end, [_date(int.parse(m[3]!), _months[m[1]!]!, int.parse(m[2]!))].nonNulls.toList()));
  }
  found.sort((a, b) => a.$1.compareTo(b.$1));

  final day = DateTime(today.year, today.month, today.day);
  final earliest = day.subtract(_plausibleAge);
  final latest = day.add(const Duration(days: 1));
  var covered = -1;
  for (final (start, end, readings) in found) {
    if (start < covered) continue; // inside a date already looked at
    covered = end;
    final plausible = {
      for (final d in readings)
        if (!d.isBefore(earliest) && !d.isAfter(latest)) d,
    };
    if (plausible.isEmpty) continue;
    return ReceiptDate(transcript.substring(start, end), plausible.length == 1 ? plausible.single : null);
  }
  return null;
}

DateTime? _date(int y, int m, int d) {
  if (m < 1 || m > 12 || d < 1) return null;
  final date = DateTime(y, m, d);
  return date.month == m && date.day == d ? date : null;
}

// ---------------------------------------------------------------------------
// The merchant

/// Words a receipt heads itself with, which are never the shop's name.
const _notAName = [
  'receipt', 'invoice', 'tax invoice', 'customer copy', 'merchant copy', 'welcome', //
  'thank you', 'order', 'facture', 'ticket de caisse', 'recu', 'bienvenue', 'merci',
  'duplicata',
];

final _letter = RegExp(r'\p{L}', unicode: true);
final _lowercase = RegExp(r'\p{Ll}', unicode: true);

/// The shop's name: the first of the top lines that reads like one (more
/// letters than digits, not a URL or an email, not till furniture).
String? receiptMerchant(List<String> lines) {
  for (final line in lines.take(6)) {
    final folded = foldReceiptText(line);
    final letters = _letter.allMatches(line).length;
    final digits = line.split('').where(_isDigit).length;
    if (line.length > 40 || letters < 2 || letters <= digits) continue;
    if (folded.contains('@') || folded.contains('www.') || folded.contains('http')) continue;
    if (receiptLineNames(_notAName, line)) continue;
    // Receipts shout: a name printed only in capitals is capitalized; one
    // with lower case is left as its owner writes it ("eBay").
    return _lowercase.hasMatch(line) ? line : _capitalized(line);
  }
  return null;
}

String _capitalized(String line) {
  final out = StringBuffer();
  var inWord = false;
  for (final c in line.split('')) {
    final wordChar = _letter.hasMatch(c) || _isDigit(c) || c == "'" || c == '’';
    out.write(!wordChar ? c : (inWord ? c.toLowerCase() : c.toUpperCase()));
    inWord = wordChar;
  }
  return out.toString();
}

// ---------------------------------------------------------------------------
// Words

const _accents = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'æ': 'a', 'ç': 'c', //
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
  'ñ': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'œ': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ý': 'y', 'ÿ': 'y', 'ß': 's',
};

/// Case- and accent-insensitive, one character for one, so positions in
/// the folded text are positions in the original.
String foldReceiptText(String text) => text.split('').map((c) {
      final lower = c.toLowerCase();
      final one = lower.length == 1 ? lower : c;
      return _accents[one] ?? one;
    }).join();

/// Whether [line] names one of [keywords]. A one-word keyword matches a
/// whole word ("change" isn't in "exchange", "bar" isn't in "Border");
/// a phrase is matched as written (spliit-ios `names`).
bool receiptLineNames(List<String> keywords, String line) {
  final folded = foldReceiptText(line);
  final words = folded.split(RegExp(r'\P{L}+', unicode: true)).toSet();
  return keywords.any((k) => k.contains(RegExp(r'[^a-z]')) ? folded.contains(k) : words.contains(k));
}

// ---------------------------------------------------------------------------
// The category

/// A category named "Grouping/Name" or "Name", resolved against the
/// server's list; nobody's when it has none by that name.
int? matchReceiptCategory(String? name, List<Category> categories) {
  final wanted = name?.trim();
  if (wanted == null || wanted.isEmpty) return null;
  final folded = foldReceiptText(wanted);
  for (final c in categories) {
    if (foldReceiptText('${c.grouping}/${c.name}') == folded) return c.id;
  }
  for (final c in categories) {
    if (foldReceiptText(c.name) == folded) return c.id;
  }
  return null;
}

/// What the shop's name says was bought. Only the name is read, never the
/// items: a supermarket bill lists wine and coffee. Ordered: a "wine bar"
/// is a bar only after it isn't a wine shop (spliit-ios).
const _keywordsByCategory = <(String, List<String>)>[
  ('Food and Drink/Groceries', ['supermarket', 'grocery', 'groceries', 'supermarche', 'epicerie', 'hypermarche']),
  ('Food and Drink/Liquor', ['liquor', 'wines', 'spirits', 'brewery', 'cave a vin', 'caviste']),
  (
    'Food and Drink/Dining Out',
    [
      'restaurant', 'cafe', 'coffee', 'bistro', 'brasserie', 'pizzeria', 'pizza', 'bar', 'pub', //
      'diner', 'grill', 'sushi', 'burger', 'boulangerie', 'patisserie', 'traiteur', 'creperie',
    ]
  ),
  ('Transportation/Taxi', ['taxi', 'cab', 'vtc']),
  ('Transportation/Hotel', ['hotel', 'hostel', 'auberge', 'motel']),
  ('Transportation/Parking', ['parking', 'stationnement']),
  ('Transportation/Gas/Fuel', ['fuel', 'petrol', 'essence', 'gas station', 'station service']),
  ('Entertainment/Movies', ['cinema', 'cineplex', 'multiplex']),
  ('Entertainment/Entertainment', ['theatre', 'museum', 'musee', 'concert']),
  ('Life/Medical Expenses', ['pharmacy', 'pharmacie', 'clinic', 'clinique', 'hospital', 'dentist', 'dentiste']),
];

int? guessReceiptCategory(String? merchant, List<Category> categories) {
  if (merchant == null) return null;
  for (final (category, keywords) in _keywordsByCategory) {
    if (!receiptLineNames(keywords, merchant)) continue;
    if (matchReceiptCategory(category, categories) case final id?) return id;
  }
  return null;
}
