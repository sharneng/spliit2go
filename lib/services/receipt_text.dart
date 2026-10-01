import 'dart:math' as math;

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
/// names it in one of them. Chinese and Japanese (#153) are this app's
/// own: spliit-ios reads neither. Their text comes from the model the
/// user picked for the receipt, and full-width characters are read as
/// their ASCII selves first.

/// One line of text OCR found, and where: 0…1 across the image, origin
/// at the top left (ML Kit's, unlike Vision's bottom-left).
class ReceiptTextBlock {
  final String text;
  final double minX;
  final double midY;
  final double height;
  const ReceiptTextBlock({required this.text, required this.minX, required this.midY, required this.height});
}

/// A line as OCR found it (#153): its box in the image's pixels, and its
/// own corners, clockwise from its top left, when OCR gives them.
class ReceiptOcrLine {
  final String text;
  final double left, top, right, bottom;
  final List<double>? corners;
  const ReceiptOcrLine(this.text,
      {required this.left, required this.top, required this.right, required this.bottom, this.corners});
}

/// [lines] as [ReceiptTextBlock]s, straightened (#153). A photographed
/// receipt is tilted, and curls: a price on the right sits higher or lower
/// than its label on the left, enough to land on the wrong row (a Costco
/// receipt, Kenneth's, sloped 11° at the top and 6° lower down). Each line
/// is placed where it meets the left edge along the slope of the lines
/// around it (the width-weighted median of its eight nearest), and its
/// height is its own, not its box's, which grows with the tilt.
List<ReceiptTextBlock> receiptTextBlocks(List<ReceiptOcrLine> lines, {required double width, required double height}) {
  final shapes = [
    for (final l in lines)
      if (l.corners case final c? when c.length == 8 && c[2] != c[0])
        (
          line: l,
          x: (c[0] + c[2] + c[4] + c[6]) / 4,
          y: (c[1] + c[3] + c[5] + c[7]) / 4,
          slope: (c[3] - c[1]) / (c[2] - c[0]),
          weight: (c[2] - c[0]).abs(),
          height: _distance(c[0], c[1], c[6], c[7]),
        )
      else
        (
          line: l,
          x: (l.left + l.right) / 2,
          y: (l.top + l.bottom) / 2,
          slope: 0.0,
          weight: 0.0,
          height: l.bottom - l.top,
        ),
  ];
  return [
    for (final s in shapes)
      ReceiptTextBlock(
        text: s.line.text,
        minX: s.line.left / width,
        midY: (s.y - s.x * _localSlope(s.y, shapes)) / height,
        height: s.height / height,
      ),
  ];
}

double _distance(double x0, double y0, double x1, double y1) {
  final (dx, dy) = (x1 - x0, y1 - y0);
  return math.sqrt(dx * dx + dy * dy);
}

double _localSlope(double y, List<({ReceiptOcrLine line, double x, double y, double slope, double weight, double height})> shapes) {
  final near = ([...shapes]..sort((a, b) => (a.y - y).abs().compareTo((b.y - y).abs()))).take(8).where((s) => s.weight > 0).toList()
    ..sort((a, b) => a.slope.compareTo(b.slope));
  final total = near.fold(0.0, (sum, s) => sum + s.weight);
  var seen = 0.0;
  for (final s in near) {
    seen += s.weight;
    if (seen >= total / 2) return s.slope;
  }
  return 0;
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

  /// The total with its currency, as a hint shows it: "1,234円" and
  /// "58.50元", as they're printed, and "€ 15,95".
  String get display => switch (currency?.mark) {
        null => text,
        final mark when _suffixMarks.contains(mark) => '$text$mark',
        final mark => '$mark $text',
      };
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
  transcript = receiptHalfWidth(transcript);
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

/// Lines that name a total (folded: "À PAYER" is "a payer"). Chinese and
/// Japanese words match anywhere in the line: they aren't spaced into
/// words. Not 实收, お預り or 实付: that's the cash handed over, often
/// more (some tills print 实付 for it), and a total the parser was sure of
/// is only worth filling in when it's right.
const _totalKeywords = [
  'total', 'amount due', 'balance due', 'grand total', 'to pay', //
  'montant', 'a payer', 'somme',
  '合计', '总计', '總計', '合計', '总额', '總額', '应付', '應付', '应收', '應收',
  'お会計', 'ご請求', 'お支払金額', 'お買上計', '総額', '総計',
  // OCR misreads of 合計 seen on real receipts (Kenneth's Costco one).
  '言計',
];

/// Lines that name a total of something else. Short on purpose: the real
/// defence is taking the largest candidate, since a subtotal, a tax and a
/// discount are all smaller than the total they belong to.
const _notATotalKeywords = [
  'sous-total', 'sous total', 'subtotal', 'sub total', 'total ht', 'total h.t', //
  'hors taxe', 'tva', 'vat', 'tip', 'pourboire', 'change', 'rendu',
  '小计', '小計', '找零', '找赎', '找贖', 'お釣', 'おつり', '釣銭',
];

ReceiptTotal? receiptTotal(List<String> lines) {
  final decimal = _decimalSeparator(lines);
  ReceiptAmount? best;
  String? bestLine;
  for (final namesTotal in [_namesTotal, _mayNameTotal]) {
    for (final line in lines) {
      if (!namesTotal(line) || receiptLineNames(_notATotalKeywords, line)) continue;
      for (final a in receiptAmounts(line, decimalSeparator: decimal)) {
        if (best == null || a.cents > best.cents) (best, bestLine) = (a, line);
      }
    }
    if (best != null) break;
  }
  // Only a keyword makes the total sure: a …計 label is a hint.
  final named = best != null && _namesTotal(bestLine!);
  if (best == null) {
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
  // Yen and won have no cents, so with no price showing a decimal
  // separator, "1,234" in one is a thousand (#153).
  final ambiguous = best.ambiguous &&
      !(decimal == null && best.text.contains(',') && (currency?.codes.any(_noCents.contains) ?? false));
  return ReceiptTotal(
    cents: best.cents,
    text: best.text,
    currency: currency,
    sure: named && !ambiguous && clear,
  );
}

const _noCents = {'JPY', 'KRW'};

bool _namesTotal(String line) => receiptLineNames(_totalKeywords, line);

/// A Chinese or Japanese label of two characters ending in 計, other than
/// 小計: maybe 合計 misread in a way not yet seen, but maybe an item,
/// 時計 (a watch) or 設計 (design), so it's only a hint (Ezra, #157).
bool _mayNameTotal(String line) {
  final label = _cjkLabel.firstMatch(line.trim());
  return label != null && label[1] != '小';
}

final _cjkLabel = RegExp(r'^(\p{Script=Han})\s*計(?![\p{L}])', unicode: true);

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

/// Marks printed after the amount.
const _suffixMarks = {'円', '元'};

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
  '円': {'JPY'}, '人民币': {'CNY'}, '人民幣': {'CNY'}, '元': {'CNY', 'TWD'},
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
        // 元 is a currency only right after an amount: in 元気 it isn't.
        : m == '元'
            ? r'(?<=\d ?)元'
            : RegExp.escape(m),
].join('|'));

List<ReceiptCurrency> _marksIn(String line) => [
      for (final m in _currencyMark.allMatches(line)) ReceiptCurrency(m[0]!, _currencyMarks[m[0]!]!),
    ];

/// Lines that say what currency the receipt is in.
const _currencyKeywords = ['currency', 'devise', 'monnaie', 'prices in', 'prix en', 'amounts in', 'montants en'];

/// A mark with a currency sign in it ("€", "US\$"), which nothing else
/// on a receipt looks like; a code or "kr" needs context.
final _currencySign = RegExp('[\$€£¥₹₩₪₱฿₫₺₽円元]|人民[币幣]');

/// The marks on [line] that mean a currency: every sign, and a code only
/// beside an amount, on a line that declares the currency ("Currency:
/// USD", #147 review), or alone on its line. "THE USD LOUNGE" has none.
List<ReceiptCurrency> _currencyMarksOn(String line) {
  final marks = _marksIn(line);
  if (marks.isEmpty) return marks;
  final context = receiptAmounts(line).isNotEmpty ||
      receiptLineNames(_currencyKeywords, line) ||
      marks.length == 1 && line.replaceAll(RegExp(r'[\s:.\-*]'), '') == marks.single.mark.replaceAll('.', '');
  return [
    for (final m in marks)
      if (context || _currencySign.hasMatch(m.mark)) m,
  ];
}

/// The currency of the total on [line]: its own line's marks, or else
/// the receipt's. Several marks count as one currency when they can mean
/// the same one ("\$" and "USD"); otherwise it's unclear (false).
(ReceiptCurrency?, bool) _currencyFor(String line, List<String> lines) {
  var marks = _marksIn(line);
  if (marks.isEmpty) {
    marks = [for (final l in lines) ..._currencyMarksOn(l)];
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
/// A time may follow with no space: OCR drops it ("2026-09-2018:42", #153).
final _isoDate = RegExp(r'(?<!\d)(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:(?!\d)|(?=\d{1,2}:\d{2}))');
final _numericDate = RegExp(r'(?<![\d.,])(\d{1,2})([-/.])(\d{1,2})\2(\d{4}|\d{2})(?![\d])');
final _dayMonthName =
    RegExp('(?<!\\d)(\\d{1,2})(?:er)?[\\s./-]*$_monthName(?![a-z])\\.?[\\s./,-]*(\\d{4}|\\d{2})(?!\\d)');
final _monthNameDay = RegExp('(?<![a-z])$_monthName(?![a-z])\\.?\\s+(\\d{1,2}),?\\s+(\\d{4})(?!\\d)');

/// 2026年9月28日, the Chinese and Japanese way (#153), and Japan's era:
/// 令和8年 is 2026 (令和元年, its first, 2019).
final _yearMonthDay = RegExp(r'(?<!\d)(\d{4}|\d{2})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日');
final _reiwaDate = RegExp(r'令和\s*(\d{1,2}|元)\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日');

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
  for (final m in _yearMonthDay.allMatches(folded)) {
    found.add((m.start, m.end, [_date(year(m[1]!), int.parse(m[2]!), int.parse(m[3]!))].nonNulls.toList()));
  }
  for (final m in _reiwaDate.allMatches(folded)) {
    final reiwa = m[1] == '元' ? 1 : int.parse(m[1]!);
    found.add((m.start, m.end, [_date(2018 + reiwa, int.parse(m[2]!), int.parse(m[3]!))].nonNulls.toList()));
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
  '收据', '收據', '发票', '發票', '小票', '欢迎', '歡迎', '谢谢', '謝謝', '顾客联', '顧客聯',
  '領収', 'レシート', 'いらっしゃいませ', 'ありがとう', 'お買上', '御買上', '控え',
];

/// Chinese and Japanese letters, which have no case.
final _cjk = RegExp(r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]', unicode: true);

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
    // with lower case is left as its owner writes it ("eBay"), and so is
    // a Chinese or Japanese one ("ローソン ABC店").
    return _lowercase.hasMatch(line) || _cjk.hasMatch(line) ? line : _capitalized(line);
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

/// Full-width letters, digits and punctuation ("１，２３４", "合計：") as
/// their ASCII selves, "￥" as "¥" and the ideographic space as a space
/// (#153), one character for one.
String receiptHalfWidth(String text) => String.fromCharCodes(text.runes.map((c) => switch (c) {
      >= 0xFF01 && <= 0xFF5E => c - 0xFEE0,
      0xFFE5 => 0xA5,
      0x3000 => 0x20,
      _ => c,
    }));

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
  // Receipts space labels out ("合 計"): a Chinese or Japanese keyword is
  // matched with the spaces taken out (#153).
  final unspaced = folded.replaceAll(RegExp(r'\s+'), '');
  return keywords.any((k) => _cjk.hasMatch(k)
      ? unspaced.contains(k)
      : k.contains(RegExp(r'[^a-z]'))
          ? folded.contains(k)
          : words.contains(k));
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
  (
    'Food and Drink/Groceries',
    ['supermarket', 'grocery', 'groceries', 'supermarche', 'epicerie', 'hypermarche', '超市', '超级市场', '超級市場', 'スーパー']
  ),
  // Not 酒屋: it's in 居酒屋, a pub.
  ('Food and Drink/Liquor', ['liquor', 'wines', 'spirits', 'brewery', 'cave a vin', 'caviste', '酒行']),
  (
    'Food and Drink/Dining Out',
    [
      'restaurant', 'cafe', 'coffee', 'bistro', 'brasserie', 'pizzeria', 'pizza', 'bar', 'pub', //
      'diner', 'grill', 'sushi', 'burger', 'boulangerie', 'patisserie', 'traiteur', 'creperie',
      '餐厅', '餐廳', '酒家', '咖啡', '茶餐厅', '茶餐廳', '火锅', '火鍋', '面馆', '麵館', '食堂', //
      'レストラン', 'カフェ', '珈琲', '喫茶', '居酒屋', '寿司', '鮨', 'ラーメン', '焼肉', '食堂',
    ]
  ),
  ('Transportation/Taxi', ['taxi', 'cab', 'vtc', '出租车', '出租車', '的士', '计程车', '計程車', 'タクシー']),
  // 酒店 is a hotel in Chinese; 饭店 can be either, so neither list has it.
  (
    'Transportation/Hotel',
    ['hotel', 'hostel', 'auberge', 'motel', '酒店', '宾馆', '賓館', '旅馆', '旅館', '民宿', 'ホテル']
  ),
  ('Transportation/Parking', ['parking', 'stationnement', '停车', '停車', '駐車', 'パーキング']),
  (
    'Transportation/Gas/Fuel',
    ['fuel', 'petrol', 'essence', 'gas station', 'station service', '加油站', '石油', '石化', 'ガソリン', 'ガスステーション']
  ),
  ('Entertainment/Movies', ['cinema', 'cineplex', 'multiplex', '电影', '電影', '影城', '影院', '映画', 'シネマ']),
  (
    'Entertainment/Entertainment',
    ['theatre', 'museum', 'musee', 'concert', '博物馆', '博物館', '美术馆', '美術館', '剧院', '劇場']
  ),
  (
    'Life/Medical Expenses',
    [
      'pharmacy', 'pharmacie', 'clinic', 'clinique', 'hospital', 'dentist', 'dentiste', //
      '药店', '藥店', '药房', '藥房', '医院', '醫院', '诊所', '診所', '薬局', '病院', 'クリニック', '歯科',
    ]
  ),
];

int? guessReceiptCategory(String? merchant, List<Category> categories) {
  if (merchant == null) return null;
  for (final (category, keywords) in _keywordsByCategory) {
    if (!receiptLineNames(keywords, merchant)) continue;
    if (matchReceiptCategory(category, categories) case final id?) return id;
  }
  return null;
}
