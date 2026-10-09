import 'receipt_text.dart';

/// The expense form as a scan finds it: what the user has already filled
/// in or chosen, when the scan finishes rather than when it started.
class ReceiptFormState {
  final bool titleEmpty;

  /// Whether the field the total goes in is empty: the amount, or during
  /// a conversion "Amount paid" (#252).
  final bool amountEmpty;
  final bool dateChosen;
  final bool categoryChosen;

  /// That field's currency: the group's, or during a conversion the one
  /// it was paid in (#252). A total in another currency is only a hint.
  final String? currencyCode;
  final String currencySymbol;

  const ReceiptFormState({
    required this.titleEmpty,
    required this.amountEmpty,
    required this.dateChosen,
    required this.categoryChosen,
    required this.currencyCode,
    required this.currencySymbol,
  });
}

/// What a scan puts in the form, and what it only shows beside a field.
class ReceiptFill {
  final String? title;
  final int? amountCents;
  final DateTime? date;
  final int? categoryId;

  /// As printed on the receipt, shown under a field the scan didn't fill.
  final String? titleHint;
  final String? amountHint;
  final String? dateHint;
  final int? categoryHint;

  const ReceiptFill({
    this.title,
    this.amountCents,
    this.date,
    this.categoryId,
    this.titleHint,
    this.amountHint,
    this.dateHint,
    this.categoryHint,
  });

  bool get filledAny => title != null || amountCents != null || date != null || categoryId != null;
}

/// Suggestions only (#125): a field the user filled or chose is never
/// overwritten, whenever the scan finishes; what the receipt says for it
/// becomes a hint. What the parser isn't sure of is a hint too, never a
/// value: a total no line names, one whose separator can't be decided,
/// and a date that reads two ways. A total is put in the amount only when
/// the receipt shows no currency or one that can be the group's.
ReceiptFill receiptFill(ReceiptScan scan, ReceiptFormState form) {
  final title = scan.title;
  final total = scan.total;
  final fillsTotal = total != null &&
      total.sure &&
      form.amountEmpty &&
      (total.currency?.couldBe(groupCode: form.currencyCode, groupSymbol: form.currencySymbol) ?? true);
  final fillsDate = scan.date != null && !form.dateChosen;
  final category = scan.categoryId;
  return ReceiptFill(
    title: form.titleEmpty ? title : null,
    titleHint: form.titleEmpty ? null : title,
    amountCents: fillsTotal ? total.cents : null,
    amountHint: fillsTotal ? null : total?.display,
    date: fillsDate ? scan.date : null,
    dateHint: fillsDate ? null : scan.dateText,
    categoryId: form.categoryChosen ? null : category,
    categoryHint: form.categoryChosen ? category : null,
  );
}
